-- arpeggii v1.3
--
-- dual arps      



local util = require 'util'

-- ------------------------------------------------------------------
-- constants
-- ------------------------------------------------------------------

-- default until the actual connected device reports its real size (see
-- sync_grid_dims below) -- 16x8 (grid 128) is just the most common case
-- to assume before that first report comes in. both get reassigned in
-- place (not shadowed by a new local) whenever the device changes, so
-- every function below that closes over these two sees the live value.
local GRID_W = 16
local GRID_H = 8

-- k1 + a grid row sets a note's "play every N laps" divisor. all GRID_H
-- rows are divisor rows: y = 1 (top) is the highest divisor, y = GRID_H
-- (bottom) is divisor 1 (see lap_divisor_for_y / y_for_lap_divisor).
-- reassigned alongside GRID_H in sync_grid_dims, for the same reason.
local MAX_LAP_DIVISOR = GRID_H
local MODULO_INDICATOR_LVL = 2
local BOTTOM_ROW_ANCHOR_LVL = 9

-- a step whose effective velocity is exactly 0 (true silence, whether
-- reached by a bottom-row tap or by e3 nudging it all the way down)
-- draws at the same brightness as an ordinary column's body/bar rows
-- (see the "else" branch of draw_arp_grid below) -- it no longer gets
-- its own dimmer treatment, since that dimness is needed instead to set
-- a literally-muted step apart (see MUTED_STEP_LVL below).
local ZERO_VEL_LVL = 3
local ZERO_VEL_PLAYHEAD_LVL = 6

-- a step that's literally muted (layer.muted -- the bottom-row toggle
-- that removes it from the traversal entirely, see step_playable) draws
-- dimmer than everything else on the grid, including the vel-0 marker
-- above, so the two read as distinct: vel-0 still takes its turn in the
-- sequence and plays at silence, while a muted step is skipped over
-- outright. these are the old ZERO_VEL_LVL/ZERO_VEL_PLAYHEAD_LVL values,
-- reused here now that vel-0 no longer needs them.
local MUTED_STEP_LVL = 2
local MUTED_STEP_PLAYHEAD_LVL = 5

-- fuzz is never allowed to push a note's velocity down past this
-- multiple of vel_fuzz itself -- see fuzz_velocity below.
local FUZZ_SILENT_FLOOR_MULT = 2

-- beat values are in "clock.sync" units where 1.0 == a quarter note
local DIVISIONS = {
  {name = "1/32",  beat = 1/8},
  {name = "1/16t", beat = 1/6},
  {name = "1/16",  beat = 1/4},
  {name = "1/8t",  beat = 1/3},
  {name = "1/8",   beat = 1/2},
  {name = "1/4t",  beat = 2/3},
  {name = "1/4",   beat = 1},
  {name = "1/2",   beat = 2},
  {name = "1/1",   beat = 4},
}

-- "chord" removed from rotation for now -- may come back later. the rest
-- of the chord-mode code is untouched (and effectively dead) below;
-- this is the only line that actually keeps the mode encoder from ever
-- landing on it.
local ARP_MODES = {"off", "up", "down", "updn", "dnup", "rand", "order", "ord.pp", "thru"} -- was: ..., "chord", "thru"

local LAYER_NAMES = {"A", "B"}

-- global swing, affects both layers identically. set via the "swing" param.
local SWING_MIN = 50.2
local SWING_MAX = 75.0
local SWING_STEP = 0.2
local SWING_MAX_STEPS = math.floor((SWING_MAX - SWING_MIN) / SWING_STEP + 0.5) + 1
local swing_steps = 0
local function swing_percent()
  if swing_steps == 0 then return nil end
  return SWING_MIN + (swing_steps - 1) * SWING_STEP
end

-- ------------------------------------------------------------------
-- state
-- ------------------------------------------------------------------

local g = grid.connect()

-- each layer has its own in/out midi device+channel (layer.in_port /
-- out_port hold the connected vport objects). a norns vport is
-- shared/cached per device index, so two layers on the same input device
-- would stomp each other's .event handler if set directly. in_handlers
-- tracks one shared handler per device instead, fanning messages out
-- to every layer currently pointed at it (see refresh_midi_in_routing).
local in_handlers = {} -- [device_index] = true while a handler is attached

-- if both layers share an output channel, they can land on the same note, 
-- causing voice drops or other issues. collision_mode picks how a clash resolves:
--   "merge": second layer joins the note already sounding; note-off only fires once every requester has released it.
--   "skip": second layer's note-on is swallowed; the first layer's note plays through untouched.
--   "none": no handling, original overlapping on/on/off/off behaviour.
local collision_mode = "merge"

-- whether a brand-new note (see sync_lap_columns) claims its starting
-- lap_divisor/lap_mode off the front of the lap-memory pool, rather than
-- the plain default (divisor 1, silent). the pool itself always stays
-- live either way: a note's settings are pushed onto it the moment it
-- leaves the sequence for good (see prune_vel_mute_state). this flag
-- only gates whether a new note ever claims from it.
local lap_memory_on = false

-- what k1+e3 (rotation) does to the six lap-mechanism fields relative to
-- the notes themselves (see apply_rotation):
--   "note+lap" (default): notes and their lap fields shift together,
--     since the fields are keyed by note id.
--   "note only": notes rotate as usual, but the fields are re-pinned
--     back to their pre-rotation columns, so lap behavior stays put.
--   "lap only": notes freeze in place; the fields migrate among the
--     frozen column order instead.
local rotation_mode = "note_lap"

-- which gesture a k1+bottom row long press triggers
local k1_priority = "replace"

-- whether a pending note-replace gesture silences its anchor step while
-- it waits for the next note-on ("mute", default -- see the vel_override
-- line in start_replace) or leaves it playing at its normal velocity the
-- whole time ("none"), same as a pending insert's anchor already does.
-- purely cosmetic/audible either way -- try_consume_replace always
-- overwrites vel_override with the incoming note's own velocity once the
-- gesture resolves, regardless of this setting.
local pending_replace_mode = "mute"

-- whether the hold/sticky toggles (k1+k2, k1+k3) are live, layer-only
-- settings that phrase save/recall never touches ("per_layer", default), or
-- part of each phrase's own saved content ("per_phrase"). the toggles
-- themselves always stay per-layer and apply immediately either way.
local hold_sticky_mode = "per_layer"

local voice_refcount = {}  -- used in "merge" mode: [key] = overlap count
local voice_active = {}    -- used in "skip" mode: [key] = true while sounding

-- keyed by output device too, not just channel+note: otherwise two
-- layers on the same channel+note but different physical devices would
-- be treated as one colliding voice even though they can never collide.
local function voice_key(device, ch, note)
  return device .. ":" .. ch .. ":" .. note
end

-- returns a handle {owned, ch, port, device, mode} that callers must
-- pass back into voice_off unchanged, rather than re-reading live
-- layer/collision state at release time. layer.out_channel/out_port/
-- out_device and collision_mode are all mutable and can change mid-note,
-- since a held note or arp gate spans real time between on and off. if
-- voice_off read them live instead, a channel/device change mid-note
-- would strand the original note stuck on, and a collision_mode change
-- would release a note under rules its note-on never agreed to (e.g.
-- leaving voice_refcount stranded nonzero). snapshotting everything here
-- closes both races.
-- .owned: true if this call is responsible for the note sounding, i.e.
-- its voice_off call should actually turn it off or decrement it.
-- .ch/.port/.device: frozen at the moment of this call, since each
-- layer can target a different device.
-- .mode: the collision_mode in effect when this note-on was decided.
local function voice_on(device, port, ch, note, vel)
  local mode = collision_mode

  if mode == "none" then
    port:note_on(note, vel, ch)
    return {owned = true, ch = ch, port = port, device = device, mode = mode}
  end

  local key = voice_key(device, ch, note)

  if mode == "skip" then
    if voice_active[key] then
      -- another layer already has this exact device+channel+note
      -- sounding; swallow this hit entirely rather than retrigger it
      return {owned = false, ch = ch, port = port, device = device, mode = mode}
    end
    voice_active[key] = true
    port:note_on(note, vel, ch)
    return {owned = true, ch = ch, port = port, device = device, mode = mode}
  end

  -- "merge"
  local count = voice_refcount[key] or 0
  voice_refcount[key] = count + 1
  if count == 0 then
    port:note_on(note, vel, ch)
  end
  -- count > 0: another layer already has this exact device+channel+note
  -- sounding, so we do note send a second note-on as this causes dropouts
  return {owned = true, ch = ch, port = port, device = device, mode = mode}
end

-- `handle` is whatever voice_on returned for the matching
-- note-on (see the comment there). a nil handle is a no-op.
local function voice_off(handle, note)
  if not handle then return end

  local ch = handle.ch
  local port = handle.port
  local device = handle.device
  local mode = handle.mode -- frozen at note-on time, not live collision_mode

  if mode == "none" then
    port:note_off(note, 0, ch)
    return
  end

  local key = voice_key(device, ch, note)

  if mode == "skip" then
    if not handle.owned then return end
    voice_active[key] = nil
    port:note_off(note, 0, ch)
    return
  end

  -- "merge"
  local count = (voice_refcount[key] or 1) - 1
  if count <= 0 then
    voice_refcount[key] = nil
    port:note_off(note, 0, ch)
  else
    -- another layer is still holding this device+channel+note; let it
    -- keep sounding and defer the real note-off to whichever release is last
    voice_refcount[key] = count
  end
end

local k1_down = false
local active_layer = 1 -- 1 = A, 2 = B

-- shared by both gestures below
local MOMENTARY_LONG_PRESS_TIME = 0.36

-- state for k2's momentary-flip-back gesture (see key() below): k2_down
-- gates k3 out for as long as it's true; the other two only mean
-- anything while k2_down is true, and are rearmed on every plain k2 press.
local k2_down = false
local k2_momentary_armed = false -- true only for a plain (no k1) press
local k2_press_time = nil

-- mirrored for k3: k3_down gates k2 out, and a long-press-then-release
-- momentarily flips to the phrase view and back.
local k3_down = false
local k3_momentary_armed = false
local k3_press_time = nil

-- "main" = the arp view. "pattern" = the phrase grid
local view_mode = "main"

-- randomisation applied to velocity (see fuzz_velocity). 0 = off.
local vel_fuzz = 0

-- "press": randomness rolled once on grid press, sticks for that step.
-- "all": a fresh value is rolled every time the arp triggers that step.
local fuzz_mode = "press"

-- gate length as a % of each step's division length. applies to both
-- layers. menu-capped at 95, and further clamped per-note in arp_clock
-- so a swing-delayed onset can't push the note past the next step (see
-- MAX_NOTE_SPAN_FRACTION there). 
local gate_length_pct = 50

-- redraw_grid only paints into the in-memory led buffer and flags it
-- dirty; the actual serial flush happens in grid_refresh_loop at a
-- capped rate, so rapid input can't outrun the grid's refresh.
local grid_dirty = false
local GRID_REFRESH_HZ = 60
local grid_refresh_clock_id

local function grid_refresh_loop()
  while true do
    clock.sleep(1 / GRID_REFRESH_HZ)
    if grid_dirty then
      g:refresh()
      grid_dirty = false
    end
  end
end

-- forward declared: defined in the grid section below, so
-- rebuild_sequence can trigger an immediate repaint on note changes.
local redraw_grid

-- forward declared: note_on (earlier) intercepts an incoming note meant
-- to complete a pending replace, before treating it as a normal note-on.
local abort_replace
local try_consume_replace

-- same pattern, for the k1 + long-press note-insert gesture.
local abort_insert
local try_consume_insert

-- forward declared so try_consume_insert can finalize a note bumped off
-- the right edge.
local delete_instance

-- forward declared: defined after arp_clock below, so recall_layer
-- (earlier) can also use it -- see the restart_arp_clock comment at its
-- definition for why a division change needs this at all.
local restart_arp_clock

-- every note-on gets its own instance id, independent of pitch, so two
-- instances of the same pitch (e.g. a retrigger while hold is on) are
-- editable independently rather than sharing state.
local next_instance_id = 1
local function new_instance_id()
  local id = next_instance_id
  next_instance_id = next_instance_id + 1
  return id
end

-- lap-memory pool: a FIFO queue of {divisor, mode, invert}, independent
-- of any instance id, so it survives a note instance disappearing
-- entirely. a value enters the pool only when a note leaves the
-- sequence for good (see prune_vel_mute_state), and leaves the pool
-- only when a new note claims it (see sync_lap_columns). it always
-- reflects the settings of recently-departed notes, in the order they
-- departed, whether or not any note is on the grid right now.
local function default_lap_pool()
  return {}
end

-- deep-copies a lap pool, or produces an empty one if buf is nil or not
-- a table (e.g. a saved phrase with no pool field, or a fixed GRID_W-slot
-- array instead of a queue; either way, that data still works fine as the
-- initial contents of the queue). used any time a pool crosses into or
-- out of persisted storage, so a saved snapshot never ends up sharing a
-- live table with layer.lap_pool and getting silently mutated by later
-- play.
local function copy_lap_pool(buf)
  local out = {}
  if type(buf) == "table" then
    for _, b in ipairs(buf) do
      table.insert(out, {
        divisor = (b and b.divisor) or 1,
        mode = (b and b.mode) or "silent",
        invert = (b and b.invert) or false,
      })
    end
  end
  return out
end

local function new_layer_state(division_idx, out_channel)
  return {
    held = {},              -- currently physically held notes, press order: {note, vel, ch, id}
    latched = {},           -- frozen copy used while hold is on

    vel_override = {},      -- [instance_id] = 0-127, persists per press instance
    muted = {},             -- [instance_id] = true/false, persists per press instance
    lap_divisor = {},       -- [instance_id] = 1-MAX_LAP_DIVISOR, persists per press
                             -- instance. absent/1 = plays every lap. set via k1 +
                             -- grid rows 2-7; see lap_divisor_for_y below.
    lap_anchor = {},        -- [instance_id] = raw_lap_count at the moment this
                             -- note took on its current divisor > 1, so on_lap
                             -- checks (raw_lap_count - lap_anchor) % divisor and
                             -- a fresh divisor pick counts laps from zero rather
                             -- than inheriting the shared counter's phase. reset
                             -- to nil (via reset_lap_state) when divisor -> 1.
    lap_stamp = {},          -- [instance_id] = raw_lap value step_playable last
                             -- tested this entry against (see step_playable).
                             -- kept separate from raw_lap_count so the lap-grid
                             -- display stays in lockstep with this note's own
                             -- last on-lap check, not the shared counter.
    lap_mode = {},           -- [instance_id] = "skip" or absent (= "silent").
                             -- "silent": plays at vel 0 on an off-lap, still
                             -- takes a traversal step. "skip": jumps over it
                             -- entirely. toggled by re-pressing the note's
                             -- selected lap row; see main_grid_key below.
    lap_invert = {},         -- [instance_id] = true/false. false/absent: plays
                             -- on laps that are a multiple of the divisor
                             -- ("every Nth lap"). true: plays every other lap
                             -- instead. toggled by holding the selected lap row
                             -- past LONG_PRESS_TIME; see main_grid_key below.
    note_octave_lap = {},   -- [instance_id] = 0-based octave lap, private counter
                             -- for any note with lap_divisor > 1. absent = in
                             -- sync with the shared layer.lap. advances by one
                             -- whenever this note actually lands on-lap (see
                             -- arp_clock); cleared when divisor or octave span
                             -- changes.
    lap_pool = default_lap_pool(), -- FIFO queue of {divisor, mode, invert}, the
                             -- "lap memory" register (see sync_lap_columns/
                             -- prune_vel_mute_state). survives note instances
                             -- coming and going.
    cap_evicted = {},       -- [instance_id] = true, set by enforce_cap when it
                             -- drops an id for being over the GRID_W cap (not a
                             -- genuine release/delete), so prune_vel_mute_state
                             -- knows not to feed that eviction into lap_pool.
    chord_flash = {},       -- [instance_id] = true while this note's most recent
                             -- chord-mode firing is within its onset+gate window.
                             -- display-only, since chord mode has no single
                             -- traveling playhead column. set/cleared in
                             -- arp_clock's chord branch.
    lap_synced = {},        -- [instance_id] = true once this id has had its one
                             -- shot at claiming a lap_pool entry (sync_lap_columns).
                             -- kept separate from lap_divisor since an untouched
                             -- note and a brand-new note both read lap_divisor
                             -- == nil.
    replace_pending = nil,  -- {id, prev_vel_override} while a k1+top-row note
                             -- replace gesture is waiting for its next note-on.
    replace_pulse_token = 0, -- bumped on replace_pending start/stop so a stale
                             -- pulse animation coroutine knows to quit
    replace_pulse_clock_id = nil, -- pulse coroutine's clock id; cancelled by
                             -- abort_replace/cleanup

    insert_pending = nil,   -- {id} while a k1+top-row long-press note-insert
                             -- gesture is waiting for its next note-on. `id` is
                             -- the anchor entry, same shape as replace_pending.
                             -- behaves like a replace while pending, minus
                             -- silencing the anchor note (see try_consume_insert).
    insert_pulse_token = 0, -- bumped on insert_pending start/stop
    insert_pulse_clock_id = nil, -- pulse coroutine's clock id; cancelled by
                             -- abort_insert/cleanup

    gesture_wave_dir = -1,  -- 1 = wave travels down, -1 = up. shared by
                             -- whichever of replace/insert is pending (see
                             -- gesture_wave_level); only flip_pending_gesture
                             -- ever inverts this -- a fresh (non-flip) gesture
                             -- leaves it exactly as it was.

    sequence = {},          -- computed playback order: list of {note, base_note, vel}
    step = 0,               -- current playhead index into sequence
    repeat_count = 0,       -- ratchet counter
    lap = 0,                -- current octave lap, 0-indexed, wraps at octave_lap_count(layer)
    step_note_lap = nil,    -- octave-lap the current step's divisor>1 note plays
                             -- at, decided once per landing and reused by every
                             -- repeat/ratchet of it (see arp_clock).
    raw_lap_count = 0,      -- unbounded lap count, used only to test lap_divisor
                             -- (see arp_clock); unlike `lap`, never wraps.
    direction = 1,          -- 1 or -1, used for updn/dnup ping-pong stepping
    random_pick_count = 0,  -- used only in random mode, approximates lap boundaries

    division_idx = division_idx,
    mode_idx = 2,           -- default up (index 1 is "off")
    frozen_mode = "up",     -- last non-thru mode; preserves traversal style
                             -- (bounce vs linear) while frozen in thru
    octave_span = 0,        -- -1..3. 0..3 = laps up, -1 = flat one-octave-down
                             -- transpose, no iteration
    repeats = 1,            -- 1-4, ratchet hits per step
    rotation = 0,           -- k1+e3: rotates which held note lands in column 1
    lap_rotation = 0,       -- display-only HUD counter for k1+e3 while
                             -- rotation_mode == "lap_only" (rotation itself
                             -- freezes in that mode, see apply_rotation);
                             -- never read by the actual lap migration math.

    hold = true,
    sticky = false,  -- default: latched notes track exactly what's held

    out_channel = out_channel, -- midi output channel for this layer
    in_channel = 0,             -- midi input channel filter, 0 = omni/all; set
                                 -- via params:bang() below

    out_device = nil,          -- midi output device index; set via the "layer
                                 -- X out device" param action (params:bang())
    out_port = nil,            -- the connected vport for out_device, kept in
                                 -- sync with it by that same action

    in_device = nil,           -- midi input device index; set via the "layer
                                 -- X in device" param action (params:bang()).
                                 -- see refresh_midi_in_routing for how this and
                                 -- in_channel combine across shared devices

    clock_id = nil,

    loaded_slot = nil,      -- pattern-view: index of the slot last saved/recalled, for highlighting

    passthru_owned = {},    -- [note] = stack of voice_on handles, one per
                             -- currently-open passthrough note-on for that
                             -- note number. a single handle isn't enough since
                             -- omni input (in_channel = 0) can see the same
                             -- note arrive twice on different channels with no
                             -- note-off between; note_off pops LIFO on release.
  }
end

-- both layers default to 1/16, hold on, sticky off, channel 2;
-- params:bang() below sets the real channel/device defaults
local layers = {
  new_layer_state(3, 2),
  new_layer_state(3, 2),
}

local function active()
  return layers[active_layer]
end

-- ------------------------------------------------------------------
-- pattern storage (save/recall grid)
-- ------------------------------------------------------------------

-- patterns[layer_num][slot_index] = snapshot table, or nil if empty.
-- 64 slots per layer, indexed 1-64 (row-major across the layer's
-- 4-row half of the grid: slot = (row_within_half - 1) * GRID_W + col).
local patterns = {{}, {}}

local function patterns_path()
  return norns.state.data .. "gridarp_patterns.data"
end

local function save_patterns_to_disk()
  tab.save(patterns, patterns_path())
end

local function load_patterns_from_disk()
  local ok, loaded = pcall(tab.load, patterns_path())
  if ok and loaded then
    patterns = loaded
  end
end

local function last_session_patterns_path()
  return norns.state.data .. "gridarp_patterns_last_session.data"
end

local function save_last_session_patterns_to_disk()
  tab.save(patterns, last_session_patterns_path())
end

local function load_last_session_patterns_from_disk()
  local ok, loaded = pcall(tab.load, last_session_patterns_path())
  if ok and loaded then
    patterns = loaded
  end
end

-- ------------------------------------------------------------------
-- autosave (PSET slots, same convention as andr-ew's ndls script:
-- https://github.com/andr-ew/ndls)
-- ------------------------------------------------------------------

-- slot 1 ("default") is what always loads at launch, regardless of the
-- "autosave" param. slot 2 ("last session") is a full snapshot written
-- unconditionally on every exit, recoverable via "load last session" or
-- PARAMETERS > PSET > 02 even with autosave off. "autosave" only gates
-- whether cleanup() also overwrites slot 1; see cleanup() below.
local PSET_DEFAULT_SLOT = 1
local PSET_LAST_SESSION_SLOT = 2

-- mirrored by the "autosave" param's action below; read by cleanup()
-- to decide whether to overwrite the default pset slot on exit.
local autosave_on = true

-- ------------------------------------------------------------------
-- helpers
-- ------------------------------------------------------------------

local function find_held_index(layer, note)
  for i, n in ipairs(layer.held) do
    if n.note == note then return i end
  end
  return nil
end

local function active_notes(layer)
  return layer.hold and layer.latched or layer.held
end

-- drop oldest notes (FIFO) once the held/latched set exceeds the grid width.
--
-- this is a forced eviction, not a real release or delete: the note wasn't
-- let go by the player, it just got pushed out because the buffer is full
-- (classic case: hold+sticky at a full 16, where every new keystroke evicts
-- the oldest in the same rebuild that added it). that distinction matters
-- for lap memory. prune_vel_mute_state (called right after this, in
-- force_rebuild_sequence) harvests a departed note's lap settings into
-- layer.lap_pool so a later note can inherit them. if cap evictions fed
-- that pool too, the note that just caused the eviction could immediately
-- claim the entry its own arrival created, an endless self-feeding loop
-- under steady 1-in/1-out pressure. marking evicted ids here lets
-- prune_vel_mute_state skip them for the pool specifically, while still
-- clearing their state normally like any other departure.
local function enforce_cap(layer, list)
  while #list > GRID_W do
    local dropped = table.remove(list, 1)
    layer.cap_evicted[dropped.id] = true
  end
end

local function build_pool(layer)
  local src = active_notes(layer)
  local pool = {}
  for _, n in ipairs(src) do
    table.insert(pool, {note = n.note, base_note = n.note, vel = n.vel, id = n.id})
  end
  return pool
end

local function order_pool(layer, pool)
  local mode = ARP_MODES[layer.mode_idx]
  if mode == "thru" then
    -- thru has no ordering of its own; use whatever mode was active
    -- before freezing (same substitution step_index/next_unmuted_step
    -- already do for playback traversal)
    mode = layer.frozen_mode
  end
  local out = {}

  if mode == "off" then
    -- off mode bypasses the arp engine for new notes (see note_on's raw
    -- passthrough branch), but the grid should still show whatever's
    -- currently held -- only the playhead itself goes away (see
    -- arp_clock, which skips stepping/firing entirely while off). so
    -- off keeps press order, same as order/ord.pp/chord below, rather
    -- than returning an empty sequence.
    out = pool

  elseif mode == "order" or mode == "ord.pp" or mode == "chord" then
    -- chord has no traversal order of its own either: every note sounds
    -- together regardless of column order, so like order/ord.pp it just
    -- keeps press order. rotate still reorders this cosmetically; it
    -- just has no audible effect in chord mode
    out = pool

  elseif mode == "up" or mode == "updn" then
    -- updn's bounce comes from step_index's traversal, not a different
    -- sort here. table.sort isn't stable, so same-pitch notes would
    -- otherwise reshuffle relative to each other on every rebuild; ties
    -- are broken by original pool (press) order below.
    out = {table.unpack(pool)}
    for i, n in ipairs(out) do n._pool_idx = i end
    table.sort(out, function(a, b)
      if a.note ~= b.note then return a.note < b.note end
      return a._pool_idx < b._pool_idx
    end)

  elseif mode == "down" or mode == "dnup" then
    -- mirrored; see the up/updn branch above for the tiebreaker.
    out = {table.unpack(pool)}
    for i, n in ipairs(out) do n._pool_idx = i end
    table.sort(out, function(a, b)
      if a.note ~= b.note then return a.note > b.note end
      return a._pool_idx < b._pool_idx
    end)

  elseif mode == "rand" then
    -- display order stays stable (press order) so grid columns don't
    -- jump around; the actual random note choice happens per-step in
    -- next_unmuted_step, not here
    out = pool
  end

  return out
end

local function rotate_sequence(seq, amount)
  local n = #seq
  if n == 0 then return seq end
  amount = amount % n
  if amount == 0 then return seq end
  local rotated = {}
  for i = 1, n do
    local src_idx = ((i - 1 + amount) % n) + 1
    rotated[i] = seq[src_idx]
  end
  return rotated
end

local function reset_playhead(layer)
  layer.step = 0
  layer.repeat_count = 0
  layer.lap = 0
  layer.raw_lap_count = 0
  layer.direction = 1
  layer.random_pick_count = 0
end

local function octave_lap_count(layer)
  if layer.octave_span < 0 then return 1 end
  return layer.octave_span + 1
end

-- `lap` defaults to the layer's shared counter, but arp_clock can pass a
-- specific value so a divisor>1 note voices against its own private
-- octave counter instead.
local function octave_lap_semitones(layer, lap)
  if layer.octave_span < 0 then return -12 end
  return (lap or layer.lap) * 12
end

-- clears vel_override/muted/lap_divisor entries whose instance id no
-- longer exists in held or latched (released, not just muted). ids are
-- never reused, so without this they'd accumulate forever. runs on every
-- sequence rebuild.
--
-- also the only place a value enters layer.lap_pool: right before a
-- departing id's lap fields are cleared, its settings are pushed onto the
-- pool so a future note can inherit them (see sync_lap_columns). reads
-- layer.sequence rather than pairs(layer.lap_divisor), whose order is
-- unspecified, so notes departing in the same rebuild are harvested in
-- their last known left-to-right order. layer.sequence is still the
-- pre-rebuild array here; force_rebuild_sequence hasn't overwritten it yet.
--
-- an id delete_instance already removed is skipped on purpose: a manual
-- delete discards its lap settings rather than banking them. an id
-- enforce_cap just dropped (layer.cap_evicted[id]) is skipped for the
-- same reason: a forced cap eviction isn't a real release, so feeding it
-- to the pool would let a new note claim the settings of the note its own
-- arrival just pushed out (see enforce_cap). cap_evicted is cleared at
-- the end of this function since it only describes the current cycle.
local function prune_vel_mute_state(layer)
  local valid = {}
  for _, n in ipairs(layer.held) do valid[n.id] = true end
  for _, n in ipairs(layer.latched) do valid[n.id] = true end

  for _, entry in ipairs(layer.sequence) do
    local id = entry.id
    if not valid[id] and layer.lap_divisor[id] ~= nil and not layer.cap_evicted[id] then
      table.insert(layer.lap_pool, {
        divisor = layer.lap_divisor[id],
        mode = layer.lap_mode[id] or "silent",
        invert = layer.lap_invert[id] or false,
      })
    end
  end

  for id, _ in pairs(layer.vel_override) do
    if not valid[id] then layer.vel_override[id] = nil end
  end
  for id, _ in pairs(layer.muted) do
    if not valid[id] then layer.muted[id] = nil end
  end
  for id, _ in pairs(layer.lap_divisor) do
    if not valid[id] then layer.lap_divisor[id] = nil end
  end
  for id, _ in pairs(layer.lap_anchor) do
    if not valid[id] then layer.lap_anchor[id] = nil end
  end
  for id, _ in pairs(layer.lap_mode) do
    if not valid[id] then layer.lap_mode[id] = nil end
  end
  for id, _ in pairs(layer.lap_invert) do
    if not valid[id] then layer.lap_invert[id] = nil end
  end
  for id, _ in pairs(layer.note_octave_lap) do
    if not valid[id] then layer.note_octave_lap[id] = nil end
  end
  for id, _ in pairs(layer.lap_synced) do
    if not valid[id] then layer.lap_synced[id] = nil end
  end
  for id, _ in pairs(layer.chord_flash) do
    if not valid[id] then layer.chord_flash[id] = nil end
  end

  layer.cap_evicted = {}
end

-- hands out lap memory to newly-arrived notes. call any time
-- layer.sequence's column layout has just been finalized (full rebuild,
-- rotation, or insert splice).
--
-- for each occupied column, left to right: only when lap_memory_on, and
-- only for an id that's never been through this function before, pop the
-- oldest entry off layer.lap_pool and stamp it onto the new instance.
-- eligibility is tracked via lap_synced rather than "lap_divisor == nil",
-- since an ordinary untouched note reads identically to a brand-new one.
-- lap_synced[id] is set true regardless of whether the pool had anything
-- to give, so a miss permanently ends this id's eligibility.
--
-- does not write anything back into the pool here: values only enter it
-- when a note departs for good (prune_vel_mute_state). a note merely
-- passing through a different column this rebuild must not overwrite
-- that column's memoized entry.
--
-- note-insert opts its new instance out of claiming: try_consume_insert
-- stamps lap_synced true itself before calling this.
local function sync_lap_columns(layer)
  if not lap_memory_on then return end
  for _, entry in ipairs(layer.sequence) do
    local id = entry.id
    if not layer.lap_synced[id] then
      layer.lap_synced[id] = true
      local claimed = table.remove(layer.lap_pool, 1)
      if claimed then
        layer.lap_divisor[id] = util.clamp(claimed.divisor or 1, 1, MAX_LAP_DIVISOR)
        -- starts on-lap counting from now, same as a fresh divisor pick
        -- (see lap_anchor above); harmless even when divisor is 1.
        layer.lap_anchor[id] = layer.raw_lap_count
        -- clear any stamp left from a stale claim against the old anchor
        layer.lap_stamp[id] = nil
        if claimed.mode == "skip" then
          layer.lap_mode[id] = "skip"
        end
        if claimed.invert then
          layer.lap_invert[id] = true
        end
      end
    end
  end
end

-- does the actual pool/order/cap/rotate work, regardless of mode. normal
-- calls go through rebuild_sequence below, which skips this while frozen
-- in thru. recall_layer calls this directly, since a recalled thru
-- snapshot needs the sequence populated from scratch.
local function force_rebuild_sequence(layer)
  enforce_cap(layer, active_notes(layer))
  prune_vel_mute_state(layer)

  local pool = build_pool(layer)
  local seq = order_pool(layer, pool)

  -- safety net: enforce_cap above should already guarantee this fits,
  -- but trim defensively in case of an edge case
  if #seq > GRID_W then
    for i = #seq, GRID_W + 1, -1 do
      table.remove(seq, i)
    end
  end

  layer.base_sequence = seq -- unrotated, cached so rotation alone is cheap
  -- negated: layer.rotation counts the same direction as the encoder/
  -- display, so this flip keeps the actual grid rotation unchanged
  seq = rotate_sequence(seq, -layer.rotation)

  layer.sequence = seq
  if layer.step > #layer.sequence then
    reset_playhead(layer)
  end

  sync_lap_columns(layer)

  -- the grid only ever shows the active layer, and only in the main view
  if view_mode == "main" and layer == active() then
    redraw_grid()
  end
end

local function rebuild_sequence(layer)
  if ARP_MODES[layer.mode_idx] == "thru" then
    -- thru mode: the arp is frozen as entered
    -- keyboard input no longer touches held/latched (see
    -- note_on/note_off), and any other control that would normally
    -- trigger a rebuild here is a no-op too, nothing regenerates the
    -- sequence until you leave thru mode.
    return
  end

  force_rebuild_sequence(layer)
end

-- lightweight path for k1+e3: rotation doesn't change which notes are
-- in the arp or how they're ordered, just re-slices the cached
-- pre-rotation sequence instead of re-running build_pool/order_pool.
local function snapshot_lap_fields(layer, id)
  return {
    lap_divisor = layer.lap_divisor[id],
    lap_anchor = layer.lap_anchor[id],
    lap_stamp = layer.lap_stamp[id],
    lap_mode = layer.lap_mode[id],
    lap_invert = layer.lap_invert[id],
    note_octave_lap = layer.note_octave_lap[id],
  }
end

local function restore_lap_fields(layer, id, snap)
  layer.lap_divisor[id] = snap.lap_divisor
  layer.lap_anchor[id] = snap.lap_anchor
  layer.lap_stamp[id] = snap.lap_stamp
  layer.lap_mode[id] = snap.lap_mode
  layer.lap_invert[id] = snap.lap_invert
  layer.note_octave_lap[id] = snap.note_octave_lap
end

local function apply_rotation(layer, d)
  if rotation_mode == "lap_only" then
    -- notes freeze in this mode: layer.sequence is left alone, and the
    -- six lap fields migrate among the current column order instead,
    -- shifted by d, so lap behaviour sweeps across columns on its own.
    local n = #layer.sequence
    if n > 0 then
      local by_col = {}
      for x = 1, n do
        by_col[x] = snapshot_lap_fields(layer, layer.sequence[x].id)
      end
      for x = 1, n do
        local src = by_col[((x - 1 - d) % n) + 1]
        restore_lap_fields(layer, layer.sequence[x].id, src)
      end
    end
    sync_lap_columns(layer)
    if view_mode == "main" and layer == active() then
      redraw_grid()
    end
    return
  end

  -- "note+lap" and "note only" both still rotate the notes exactly as
  -- always; negated for the same reason as force_rebuild_sequence above.
  local old_seq = layer.sequence
  local seq = rotate_sequence(layer.base_sequence or {}, -layer.rotation)

  if rotation_mode == "note_only" and old_seq and #old_seq == #seq and #seq > 0 then
    -- re-pin the six fields back onto their pre-rotation columns (zero
    -- shift relative to columns, in contrast to the "lap only" shift-by-d
    -- above) so lap behavior stays put while the notes rotate through it.
    local by_col = {}
    for x = 1, #old_seq do
      by_col[x] = snapshot_lap_fields(layer, old_seq[x].id)
    end
    for x = 1, #seq do
      restore_lap_fields(layer, seq[x].id, by_col[x])
    end
  end
  -- "note+lap": no migration at all. lap fields are keyed by id, so
  -- they ride along with their note automatically as it moves, which is
  -- the coupled behavior this mode wants.

  layer.sequence = seq
  if layer.step > #layer.sequence then
    reset_playhead(layer)
  end

  sync_lap_columns(layer)

  if view_mode == "main" and layer == active() then
    redraw_grid()
  end
end

local function effective_velocity(layer, entry)
  if not entry then return 0 end
  return util.clamp(layer.vel_override[entry.id] or entry.vel, 0, 127)
end

-- e3: nudges every currently active note's velocity by a flat amount.
-- writes straight into vel_override (the same store the grid edits use)
local function nudge_all_velocities(layer, delta)
  for _, n in ipairs(active_notes(layer)) do
    local current = layer.vel_override[n.id] or n.vel
    layer.vel_override[n.id] = util.clamp(current + delta, 0, 127)
  end
  if view_mode == "main" and layer == active() then
    redraw_grid()
  end
end

-- velocity already at the 127 ceiling can only swing downward
-- so it gets a range of just vel_fuzz instead of vel_fuzz * 2.
local function fuzz_velocity(vel)
  if vel_fuzz == 0 or vel <= 0 then return vel end
  -- notes at or below this floor are left exact: without this, a quiet
  -- but intentionally nonzero note could get randomly fuzzed all the way
  -- down to 0, which in "press" mode would even get written into
  -- vel_override as a hard, permanent 0 -- indistinguishable from a
  -- deliberate bottom-row mute (see vel_for_row and ZERO_VEL_LVL above).
  if vel < vel_fuzz * FUZZ_SILENT_FLOOR_MULT then return vel end
  if vel >= 127 then
    return util.clamp(vel + math.random(-vel_fuzz, 0), 0, 127)
  end
  return util.clamp(vel + math.random(-vel_fuzz, vel_fuzz), 0, 127)
end

-- top row (1) = 127 (loudest), bottom row (GRID_H) = 0 (silent). bottom
-- row stays a hard, exact anchor with no fuzz, since it's meant as a
-- true "silent" marker rather than a quantized velocity. every other row,
-- including the 127 top row, gets wobbled by fuzz_velocity above so
-- repeated taps on the same row don't always land on the identical
-- number. wobble is only rolled here at all when fuzz_mode == "press";
-- in "all" mode the exact quantized value is stored instead, and the
-- wobble is rolled fresh on every arp trigger (see arp_clock below).
local function vel_for_row(y)
  local base = util.round(util.linlin(1, GRID_H, 127, 0, y))
  if y == GRID_H or fuzz_mode ~= "press" then
    return base
  end
  return fuzz_velocity(base)
end

local function row_for_vel(vel)
  return util.clamp(util.round(util.linlin(0, 127, GRID_H, 1, vel)), 1, GRID_H)
end

-- maps a k1+grid-row press (y = 1..GRID_H) to a lap divisor
-- (1..MAX_LAP_DIVISOR) and back, for the lap-select grid overlay. y =
-- GRID_H (bottom row) is divisor 1 (play every lap, the default; also
-- where the insert/replace long-press lives, see main_grid_key below);
-- y = 1 (top row) is divisor MAX_LAP_DIVISOR (play every Nth lap).
local function lap_divisor_for_y(y)
  return GRID_H - y + 1
end

local function y_for_lap_divisor(divisor)
  return GRID_H - divisor + 1
end

-- ------------------------------------------------------------------
-- pattern save / recall
-- ------------------------------------------------------------------

-- flattens a layer's live state into a plain, serializable table. notes
-- are stored as {note, vel, muted} only, no instance ids, since ids
-- are meant to be process-unique and shouldn't be persisted/reloaded as
-- literal numbers. vel is the fully resolved (post-override) velocity,
-- so a recalled slot sounds exactly like what was saved.
local function capture_layer(layer)
  local notes = {}
  for _, n in ipairs(active_notes(layer)) do
    table.insert(notes, {
      note = n.note,
      vel = effective_velocity(layer, n),
      muted = layer.muted[n.id] or false,
      lap_divisor = layer.lap_divisor[n.id] or 1,
      lap_mode = layer.lap_mode[n.id] or "silent",
      lap_invert = layer.lap_invert[n.id] or false,
    })
  end

  local snapshot = {
    division_idx = layer.division_idx,
    mode_idx = layer.mode_idx,
    frozen_mode = layer.frozen_mode,
    octave_span = layer.octave_span,
    repeats = layer.repeats,
    rotation = layer.rotation,
    lap_rotation = layer.lap_rotation,
    -- swing is a global params-menu setting, never per-layer/per-phrase
    -- content, so it's never captured here regardless of hold_sticky_mode.
    --
    -- hold/sticky are always captured here regardless of hold_sticky_mode:
    -- capturing is cheap and keeps this data around even when saving in
    -- "per_layer" mode. it's recall_layer that actually decides whether to
    -- apply them, based on hold_sticky_mode at recall time, so switching
    -- modes later doesn't silently strand or fabricate this info either way.
    hold = layer.hold,
    sticky = layer.sticky,
    notes = notes,
    -- the lap-memory pool, independent of how many notes this phrase
    -- itself has (see sync_lap_columns/prune_vel_mute_state/lap_pool
    -- above). always captured, same as hold/sticky, regardless of
    -- whether "lap memory" happens to be on right now.
    lap_pool = copy_lap_pool(layer.lap_pool),
  }

  return snapshot
end

-- forward-declared: recall_layer below needs to call this, but its real
-- definition lives further down (it depends on note_off, which in turn
-- depends on things defined between here and there). lua locals aren't
-- hoisted, so without this stub, recall_layer's reference to
-- release_all_held_notes would resolve as a global (nil) instead of an
-- upvalue and error at call time. the assignment near note_off's
-- definition below fills this in for real; by the time recall_layer is
-- actually CALLED (well after the whole file has loaded), it's pointing
-- at the real function.
local release_all_held_notes

-- replaces a layer's entire live state with a saved snapshot. whatever
-- was held/latched before is dumped, and every field falls back to a
-- sane default if missing, so an older/legacy snapshot (e.g. saved
-- before a field got renamed) can't crash this on recall.
local function recall_layer(layer, snapshot)
  -- release whatever's live on this layer before any snapshot field is
  -- applied below, critically before layer.mode_idx gets overwritten.
  -- release_all_held_notes decides how to release (passthru voice_off vs
  -- arp-path note_off) by reading the layer's CURRENT mode_idx. if that
  -- already reflected the incoming phrase's mode instead of the outgoing
  -- one, a note that was actually a live off/thru passthrough voice would
  -- be evaluated against the new mode, skip the passthru_owned release
  -- path, and never get its note-off: a real MIDI note stuck on
  -- indefinitely, since wiping layer.held/latched below (which this
  -- function always does) discards the bookkeeping without ever touching
  -- the actual sounding voice. calling this first, against the pre-recall
  -- mode/state, is what makes recall_layer safe to call while notes are
  -- still physically held, whatever mode the layer is leaving or entering.
  release_all_held_notes(layer)

  local old_division_idx = layer.division_idx
  layer.division_idx = snapshot.division_idx or layer.division_idx
  if layer.division_idx ~= old_division_idx then
    -- same staleness fix as the encoder path -- see restart_arp_clock's
    -- comment. layer.clock_id is always already set by the time a phrase
    -- can be recalled (this only fires from a grid press at runtime,
    -- never during init), so the guard inside restart_arp_clock is just
    -- belt-and-suspenders here.
    restart_arp_clock(layer)
  end
  layer.mode_idx = snapshot.mode_idx or layer.mode_idx
  layer.frozen_mode = snapshot.frozen_mode or "up"
  layer.octave_span = util.clamp(snapshot.octave_span or 0, -1, 3)
  layer.repeats = util.clamp(snapshot.repeats or 1, 1, 4)
  -- restored from the snapshot, same as every other saved field
  layer.rotation = snapshot.rotation or 0
  layer.lap_rotation = snapshot.lap_rotation or 0

  -- notes recalled below always land in layer.latched regardless of mode.
  -- if hold ends up off, either because this phrase's own saved hold was
  -- off ("per_phrase" mode) or because that's simply the layer's current
  -- live setting ("per_layer" mode), active_notes falls back to layer.held
  -- (live keys) instead, so the arp stays silent here until something's
  -- actually held again.
  if hold_sticky_mode == "per_phrase" then
    -- restore exactly as saved. old snapshots saved before this field
    -- existed fall back to true/false, matching pre-existing behavior.
    if snapshot.hold == nil then layer.hold = true else layer.hold = snapshot.hold end
    if snapshot.sticky == nil then layer.sticky = false else layer.sticky = snapshot.sticky end
  end
  -- "per_layer": hold/sticky are live per-layer settings that phrase
  -- recall never touches; leave them exactly as they already were.

  layer.held = {}
  layer.latched = {}
  layer.vel_override = {}
  layer.muted = {}
  layer.lap_divisor = {}
  -- left unstamped (nil = anchor 0) for every recalled note below on
  -- purpose: reset_playhead further down already zeroes raw_lap_count
  -- back to 0 for this recall, so "anchor 0" is already correct without
  -- stamping anything here first.
  layer.lap_anchor = {}
  layer.lap_stamp = {}
  layer.lap_mode = {}
  layer.lap_invert = {}
  layer.lap_synced = {}
  layer.cap_evicted = {}
  -- not part of the saved snapshot: every recalled note is "newly added"
  -- from the pool's point of view, so it starts in sync with the shared
  -- lap counter, same as any other fresh note.
  layer.note_octave_lap = {}
  -- restored independently of the notes below: a phrase saved with
  -- only a few notes held still carries whatever else was queued up in
  -- the pool at save time. falls back to an empty pool if neither field
  -- is present; copy_lap_pool also accepts the fixed-size lap_buffer
  -- field as an alternate source for the pool's initial contents.
  layer.lap_pool = copy_lap_pool(snapshot.lap_pool or snapshot.lap_buffer)

  for _, sn in ipairs(snapshot.notes or {}) do
    local id = new_instance_id()
    table.insert(layer.latched, {note = sn.note, vel = sn.vel, ch = nil, id = id})
    if sn.muted then
      layer.muted[id] = true
    end
    -- always stamped explicitly, even at the default divisor of 1: every
    -- other reader already treats `layer.lap_divisor[id] or 1` identically
    -- to an explicit 1, so this changes nothing there.
    layer.lap_divisor[id] = util.clamp(sn.lap_divisor or 1, 1, MAX_LAP_DIVISOR)
    -- a recalled note must read as "already had its turn" so it can never
    -- steal a pool entry meant for whatever note comes in next, overwriting
    -- what was actually saved for it. lap_synced is what sync_lap_columns'
    -- claim check keys off, not lap_divisor (see sync_lap_columns).
    layer.lap_synced[id] = true
    if sn.lap_mode == "skip" then
      layer.lap_mode[id] = "skip"
    end
    if sn.lap_invert then
      layer.lap_invert[id] = true
    end
  end

  reset_playhead(layer)
  force_rebuild_sequence(layer)
end

-- ------------------------------------------------------------------
-- midi in
-- ------------------------------------------------------------------

-- resolves which layer(s) a given incoming message (on device_idx, channel
-- ch) should reach. first narrows to layers actually pointed at this
-- device -- a layer whose "in device" is set to something else never sees
-- this message at all, regardless of its channel setting.
--
-- among the layers that ARE on this device: if there's only one, it gets
-- the message whenever its channel matches (0 = all). if both layers
-- share this device, the original single-midi_in ambiguity is still
-- there; when they're also set to the same channel (including both
-- "all") there's no way to tell them apart, so behaviour falls back to
-- whichever layer is currently active (k2). only when
-- two same-device layers are on genuinely different channels does this
-- open up: each independently accepts whatever matches its own channel.
local function layers_for_device_channel(device_idx, ch)
  local candidates = {}
  for _, layer in ipairs(layers) do
    if layer.in_device == device_idx then
      table.insert(candidates, layer)
    end
  end

  if #candidates == 0 then
    return {}
  end

  if #candidates == 1 then
    local layer = candidates[1]
    if layer.in_channel == 0 or layer.in_channel == ch then
      return {layer}
    end
    return {}
  end

  if candidates[1].in_channel == candidates[2].in_channel then
    return {active()}
  end

  local targets = {}
  for _, layer in ipairs(candidates) do
    if layer.in_channel == 0 or layer.in_channel == ch then
      table.insert(targets, layer)
    end
  end
  return targets
end

-- remembers which layer(s) each currently-held note landed on,
-- so its eventual note-off goes to the right place, not
-- whatever layers_for_device_channel resolves to at release time. those
-- can differ: with both channels set to "all" on a shared device,
-- layers_for_device_channel just returns whichever layer is active RIGHT
-- NOW, and flipping the active layer (k2) while a note is still
-- physically held would otherwise mean the note-off lands on the newly
-- active layer while the note-on had landed on the old one, leaving a
-- phantom entry in the old layer's `held` that nothing can ever clear,
-- not even turning hold off (hold only reconciles the currently active
-- layer's own state).
-- keyed by "device:channel:note" (device included since the same
-- channel+note can now arrive independently from two different input
-- devices at once, one per layer) so the same note number can be
-- legitimately held on multiple device/channel/layer combos at once
-- under the differing-device/differing-channel routing above.
local note_targets = {}

local function note_target_key(device_idx, ch, note)
  return device_idx .. ":" .. ch .. ":" .. note
end

local function note_on(layer, note, vel, ch)
  -- true only if nothing was held at all before this note -- i.e. this
  -- note starts a genuinely fresh arp, not an add to one already in
  -- progress. used below to reset rotation only on an actual wipe.
  local starting_fresh = (#layer.held == 0)

  -- a pending note-replace gesture (k1 + long-press on the lap screen's
  -- divisor-1 row) claims the
  -- next incoming note, regardless of mode -- even in off/thru,
  -- which would otherwise pass this straight through below. the note is
  -- absorbed entirely: it retunes the pending column instead of sounding
  -- on its own or adding a new column/passthrough note.
  if try_consume_insert(layer, note, vel, ch) then
    return
  end

  if try_consume_replace(layer, note, vel, ch) then
    return
  end

  if ARP_MODES[layer.mode_idx] == "off" or ARP_MODES[layer.mode_idx] == "thru" then
    -- off: raw passthrough, arp engine never sees this note at all.
    -- thru: same passthrough, but the arp keeps looping whatever it
    -- already had (held/latched are frozen, untouched by this branch)
    -- pushed onto a stack, not just assigned - see the passthru_owned
    -- field comment above for why a single slot per note isn't safe here
    local handle = voice_on(layer.out_device, layer.out_port, layer.out_channel, note, vel)
    layer.passthru_owned[note] = layer.passthru_owned[note] or {}
    table.insert(layer.passthru_owned[note], handle)
    return
  end

  local held_idx = find_held_index(layer, note)
  local id
  if held_idx then
    -- refresh this held note's velocity to the new keystroke
    id = layer.held[held_idx].id
    layer.held[held_idx].vel = vel
    layer.vel_override[id] = nil
  else
    id = new_instance_id()
    table.insert(layer.held, {note = note, vel = vel, ch = ch, id = id})
  end

  if layer.hold then
    if layer.sticky then
      if not held_idx then
        table.insert(layer.latched, {note = note, vel = vel, ch = ch, id = id})
      end
    else
      -- this does not reset the playhead
      layer.latched = {}
      for _, n in ipairs(layer.held) do
        table.insert(layer.latched, n)
      end
    end
  end

  if starting_fresh and (not layer.hold or not layer.sticky) then
    -- this note started from a totally empty held set. with hold off,
    -- or hold on with sticky off (which resyncs latched to held on
    -- every note-on), that means the active note set really was just
    -- wiped, old rotation has no relationship to what's about to
    -- exist now. excludes hold+sticky both on: there, latched never
    -- drops anything regardless of physical release, so held being
    -- momentarily empty doesn't mean the arp itself was ever wiped.
    layer.rotation = 0
    layer.lap_rotation = 0
    -- per-note lap divisors belonged to the old note set, not this new
    -- one, but they're deliberately not wiped here: the upcoming
    -- rebuild_sequence -> prune_vel_mute_state call below will find
    -- every old id no longer valid (held/latched now only reflect this
    -- new note) and route their settings into layer.lap_pool in the
    -- correct left-to-right order (still readable off the current,
    -- not-yet-overwritten layer.sequence) before clearing them,  same
    -- path any other departure takes. wiping them here directly, before
    -- that can happen, would just discard them instead.
  end

  rebuild_sequence(layer)
  if layer == active() then
    redraw() -- screen: oct/rep/rot/etc. reflect the new note count immediately,
             -- not just whenever the next key/enc press happens to fire one
  end
end

local function note_off(layer, note)
  -- routed by where this note actually landed at note-on time, not by
  -- whatever mode the layer is in right now. those can differ:
  -- layer.mode_idx can change (encoder, or a phrase recall) while a note
  -- is still physically held, since nothing about changing mode touches
  -- notes already in flight. checking layer.passthru_owned directly
  -- mirrors exactly which branch note_on took for this specific note,
  -- so the release always matches the note-on regardless of any mode
  -- change in between:
  --   - held in off/thru, mode since changed to a real arp mode: still
  --     found here and released correctly, rather than falling through
  --     to find_held_index (where it was never registered) and leaking
  --     the voice_on'd note as permanently stuck.
  --   - held in a real arp mode, mode since changed to off/thru: not
  --     found here (this note was never in passthru_owned), so it falls
  --     through to the held-path below exactly as it would have if the
  --     mode had never changed.
  -- popped LIFO, one handle per note-off -- see the passthru_owned field
  -- comment above for why this is a stack rather than a single slot
  local stack = layer.passthru_owned[note]
  if stack and #stack > 0 then
    local handle = table.remove(stack)
    if #stack == 0 then
      layer.passthru_owned[note] = nil
    end
    voice_off(handle, note)
    return
  end

  local idx = find_held_index(layer, note)
  if idx then
    local id = layer.held[idx].id
    table.remove(layer.held, idx)
    if layer.replace_pending and layer.replace_pending.id == id and not layer.hold then
      -- hold is off, so this note is about to vanish from the arp
      -- entirely once rebuild_sequence runs below, abort rather than leave
      -- the gesture pointing at a step that no longer exists
      abort_replace(layer)
    end
    if layer.insert_pending and layer.insert_pending.id == id and not layer.hold then
      -- same reasoning as the replace case above: the note this insert
      -- is anchored to is about to vanish, so abort rather than leave
      -- the gesture pointing at a step that no longer exists
      abort_insert(layer)
    end
  end

  if not layer.hold then
    rebuild_sequence(layer)
    if layer == active() then
      redraw() -- screen: same reasoning as note_on
    end
  end
  -- while hold is on, note-off does not touch layer.latched at all;
  -- latched notes persist regardless of physical release. the only way
  -- to clear them is toggling hold off (see set_hold)
end

-- called when a "layer X in device" param changes (see its action below).
-- switching that layer's input device detaches it from whatever's still
-- physically held on the OLD device -- its eventual note-off will never
-- reach this script again, since nothing is listening to that port for
-- this layer anymore. without this, those notes would stay marked as
-- held/sounding forever: a phantom "still held" entry nothing can ever
-- clear (hold off: the arp keeps looping a note nobody's pressing
-- anymore; hold on: it pollutes held bookkeeping like
-- find_held_index/enforce_cap indefinitely, even though what's actually
-- playing, i.e. latched, is unaffected), and in off/thru mode a real
-- MIDI voice left stuck on with no note-off ever coming to release it.
--
-- treats every currently-held note on `only_layer` (or on both layers,
-- if only_layer is omitted -- e.g. from cleanup()) exactly as if it had
-- just been physically released: passthrough notes get a real voice-off
-- sent immediately, and arp-tracked notes go through the normal
-- note_off path, which (per its own hold-on/hold-off rules) either
-- drops them from the live sequence (hold off) or simply stops treating
-- them as physically down while leaving whatever's latched untouched
-- (hold on) -- same as a real release would do in either case.
--
-- sweeps BOTH layer.passthru_owned and layer.held unconditionally,
-- rather than picking one based on the layer's current mode. current
-- mode is the wrong test here for exactly the same reason it was wrong
-- inside note_off itself (see that function's comment): mode can change
-- while notes are still physically down, so at the moment this runs
-- there can be live entries in EITHER structure regardless of what
-- ARP_MODES[layer.mode_idx] says right now. note_off already resolves
-- each note correctly by checking passthru_owned first, so routing
-- every note number from both structures through it (rather than
-- special-casing passthru release here) means this can't go stale the
-- same way again even if note_off's own resolution logic changes later.
-- fills in the forward declaration above (see that comment for why this
-- can't just be `local function` here).
release_all_held_notes = function(only_layer)
  for _, layer in ipairs(layers) do
    if not only_layer or layer == only_layer then
      -- collect first: note_off mutates layer.held (table.remove) and
      -- layer.passthru_owned (sets entries nil) as it runs, so iterating
      -- either directly while calling it would skip entries
      local notes_to_release = {}
      for _, n in ipairs(layer.held) do table.insert(notes_to_release, n.note) end
      -- one entry per stacked handle, not just once per distinct note
      -- number -- passthru_owned[note] can hold more than one open
      -- handle at once (see its field comment), and note_off only pops
      -- a single handle per call, so this needs to queue #stack releases
      -- to fully drain it
      for note, stack in pairs(layer.passthru_owned) do
        for _ = 1, #stack do
          table.insert(notes_to_release, note)
        end
      end
      for _, note in ipairs(notes_to_release) do
        note_off(layer, note)
      end
    end
  end

  -- note_targets (declared above, used by midi_event) only ever holds an
  -- entry for a note that's had a note-on but no matching note-off yet --
  -- every note-off clears its own key. we've just synthesized that
  -- release for everything currently held on the affected layer(s)
  -- above, so any key whose target list includes one of those layers is
  -- now stale; drop just those rather than the whole table, so an
  -- unaffected layer's in-flight bookkeeping survives a device switch on
  -- the other layer.
  for key, targets in pairs(note_targets) do
    local stale = false
    for _, layer in ipairs(targets) do
      if not only_layer or layer == only_layer then stale = true end
    end
    if stale then note_targets[key] = nil end
  end
end

-- builds the single event handler shared by every layer currently
-- pointed at device_idx (see in_handlers / refresh_midi_in_routing
-- above/below for why it's one handler per device rather than one per
-- layer). closes over device_idx so layers_for_device_channel and
-- note_target_key always resolve against the device this handler is
-- actually attached to.
local function make_midi_handler(device_idx)
  return function(data)
    local msg = midi.to_msg(data)
    if msg.type == "note_on" and msg.vel > 0 then
      local targets = layers_for_device_channel(device_idx, msg.ch)
      note_targets[note_target_key(device_idx, msg.ch, msg.note)] = targets
      for _, layer in ipairs(targets) do
        note_on(layer, msg.note, msg.vel, msg.ch)
      end
    elseif msg.type == "note_off" or (msg.type == "note_on" and msg.vel == 0) then
      local key = note_target_key(device_idx, msg.ch, msg.note)
      -- fall back to a fresh resolve if we somehow never saw the
      -- matching note-on (e.g. script loaded mid-note) -- better than
      -- silently dropping the release entirely
      local targets = note_targets[key] or layers_for_device_channel(device_idx, msg.ch)
      note_targets[key] = nil
      for _, layer in ipairs(targets) do
        note_off(layer, msg.note)
      end
    elseif msg.type == "cc" then
      -- same dispatch as notes above: gated to active() if both layers
      -- on this device share a channel, otherwise sent to each layer
      -- whose channel matches (0 = all), independent of which one's
      -- active. each layer sends out on its OWN out_port/out_channel,
      -- since the two layers can output to different devices too.
      for _, layer in ipairs(layers_for_device_channel(device_idx, msg.ch)) do
        layer.out_port:cc(msg.cc, msg.val, layer.out_channel)
      end
    elseif msg.type == "pitchbend" then
      for _, layer in ipairs(layers_for_device_channel(device_idx, msg.ch)) do
        layer.out_port:pitchbend(msg.val, layer.out_channel)
      end
    end
  end
end

-- re-attaches midi input handlers so they match each layer's current
-- in_device. called once at init (via params:bang()) and again every
-- time a "layer X in device" param action fires.
--
-- a norns vport is cached per device index -- midi.connect(n) always
-- hands back the same underlying object for a given n -- so this can't
-- just set .event directly per layer: if both layers pointed at the same
-- device each set their own handler, the second call would silently
-- clobber the first. instead there's exactly one handler attached per
-- device index actually in use (see make_midi_handler), and any device
-- no longer claimed by either layer gets its handler detached so this
-- script stops listening to it.
local function refresh_midi_in_routing()
  local wanted = {}
  for _, layer in ipairs(layers) do
    if layer.in_device then wanted[layer.in_device] = true end
  end

  for idx in pairs(in_handlers) do
    if not wanted[idx] then
      midi.connect(idx).event = nil
      in_handlers[idx] = nil
    end
  end

  for idx in pairs(wanted) do
    if not in_handlers[idx] then
      local port = midi.connect(idx)
      port.event = make_midi_handler(idx)
      in_handlers[idx] = true
    end
  end
end

-- shared formatter for all four device-selector params below: shows the
-- plain index alongside whatever name norns currently has for that
-- vport, e.g. "2: iConnectMIDI4+ A", falling back to "none" for an
-- unpatched slot. read live off midi.vports each time the param is
-- displayed, so it stays accurate across hotplug/repatch without needing
-- the param's options redefined.
local function midi_device_formatter(param)
  local v = param:get()
  local vport = midi.vports[v]
  local name = (vport and vport.name) or "none"
  return v .. ": " .. name
end

-- ------------------------------------------------------------------
-- hold / sticky toggles
-- ------------------------------------------------------------------

local function set_hold(layer, v)
  layer.hold = v
  if v then
    layer.latched = {}
    for _, n in ipairs(layer.held) do table.insert(layer.latched, n) end
  elseif ARP_MODES[layer.mode_idx] == "thru" then
    -- thru mode has no live note tracking to fall back to (held/latched
    -- are frozen, untouched by the keyboard the whole time you've been
    -- frozen), so releasing hold here means "let it go", not "revert to
    -- live". clear held/latched and force the frozen sequence to actually
    -- clear too, bypassing rebuild_sequence's normal thru-mode no-op.
    --
    -- deliberately does NOT also clear vel_override/muted/lap_divisor/
    -- lap_mode/lap_invert/note_octave_lap here: force_rebuild_sequence
    -- below calls prune_vel_mute_state, which already clears all of
    -- those for every id no longer in held/latched -- but only AFTER
    -- harvesting each departing note's still-populated lap_divisor/
    -- lap_mode/lap_invert into layer.lap_pool (see prune_vel_mute_state).
    -- clearing lap_divisor/lap_mode here first would blank that data out
    -- before prune_vel_mute_state ever gets to read it, so every note let
    -- go this way would silently skip the lap-memory pool instead of
    -- being banked into it like every other departure path.
    layer.held = {}
    layer.latched = {}
    reset_playhead(layer)
    force_rebuild_sequence(layer)
    return
  end
  rebuild_sequence(layer)
end

-- ------------------------------------------------------------------
-- grid
-- ------------------------------------------------------------------

-- mode_idx resolved through "thru", which just keeps replaying whatever
-- frozen_mode was active before it froze -- same substitution needed
-- anywhere a layer's actual playback behavior matters (arp_clock,
-- next_unmuted_step, and the grid draw functions below, since chord
-- mode changes what the playhead indicator means).
local function effective_mode_of(layer)
  local mode = ARP_MODES[layer.mode_idx]
  if mode == "thru" then
    mode = layer.frozen_mode
  end
  return mode
end

-- brightness for the pulsing column of a pending replace or insert
-- gesture: a single soft wave of brightness that ripples continuously
-- through the column, looping -- every row always has some light (never
-- drops to a hard floor or flat pulse), it's just brighter where the
-- wave crest currently sits and dimmer where the trough is, with the
-- whole shape sliding smoothly and wrapping seamlessly at the ends. one
-- full cosine cycle spans the whole column height, so there's exactly
-- one crest and one trough visible at any moment (same idea as buoys'
-- tide lighting: a continuously graded brightness field rather than
-- discrete on/off steps).
--
-- dir controls travel direction: 1 flows downward, -1 flows upward.
-- replace and insert render identically otherwise -- the only visual
-- difference between the two gestures is this shared direction, which
-- flip_pending_gesture inverts each time a column is toggled from one
-- gesture type to the other (see layer.gesture_wave_dir).
local REPLACE_WAVE_LO = 2 -- brightness at the wave's trough
local REPLACE_WAVE_HI = 12 -- brightness at the wave's crest
local REPLACE_WAVE_PERIOD = 1.3 -- seconds for the crest to travel the full column before looping
local function gesture_wave_level(row_pos, dir)
  -- row_pos/GRID_H maps this row to its position within one cosine
  -- cycle; subtracting (dir * time/period) continuously shifts that
  -- cycle along the column as time passes -- negating dir just runs the
  -- shift the other way -- and cosine's own periodicity handles the
  -- wrap at either end for free, with no seam to special-case
  local phase = 2 * math.pi * (row_pos / GRID_H - dir * (util.time() % REPLACE_WAVE_PERIOD) / REPLACE_WAVE_PERIOD)
  local eased = (1 + math.cos(phase)) / 2 -- 0..1, 1 at the crest, 0 at the trough
  return util.round(REPLACE_WAVE_LO + eased * (REPLACE_WAVE_HI - REPLACE_WAVE_LO))
end

-- shared by draw_arp_grid/draw_lap_grid below: if entry has a pending
-- note-insert or note-replace gesture, paints its whole column with the
-- flowing wave (see gesture_wave_level above) and returns true. returns
-- false, painting nothing, when nothing's pending for this entry --
-- callers fall through to their own normal per-column rendering in that
-- case.
local function draw_pending_pulse(x, layer, entry)
  if layer.insert_pending and layer.insert_pending.id == entry.id then
    -- note-insert pending: this note's column shows the wave, and --
    -- unlike replace -- the anchor note itself stays fully audible at
    -- its normal velocity the whole time (see start_insert); a new
    -- column is spliced in beside it once the next incoming note lands
    -- (see try_consume_insert)
    for y = 1, GRID_H do
      g:led(x, y, gesture_wave_level(y - 1, layer.gesture_wave_dir))
    end
    return true
  elseif layer.replace_pending and layer.replace_pending.id == entry.id then
    -- note-replace pending: the whole column shows the same wave, and
    -- -- under the default "pending_replace" = "mute" -- silenced (see
    -- try_consume_replace/vel_override below) until the next incoming
    -- note lands; under "none" it keeps playing at its normal velocity
    -- the whole time instead, same as insert's anchor above (see
    -- start_replace's pending_replace_mode check)
    for y = 1, GRID_H do
      g:led(x, y, gesture_wave_level(y - 1, layer.gesture_wave_dir))
    end
    return true
  end
  return false
end

local function draw_arp_grid()
  local layer = active()
  local is_chord = (effective_mode_of(layer) == "chord")
  g:all(0)
  for x = 1, #layer.sequence do
    local entry = layer.sequence[x]
    -- chord mode has no single traveling playhead column -- every note
    -- fires independently on whatever ticks it's eligible for (see
    -- arp_clock's chord branch), so playhead status here is "did this
    -- note actually fire and is it still within
    -- its audible window" (chord_flash), timed to the note's own gate
    -- length rather than tied to a fictional moving position. a muted
    -- note is never marked chord_flash (it never fires), so it falls
    -- straight through to the same dim single-dot treatment as always.
    local is_playhead
    if is_chord then
      is_playhead = layer.chord_flash[entry.id] == true
    else
      is_playhead = (x == layer.step)
    end

    if draw_pending_pulse(x, layer, entry) then
      -- handled: column pulsed, nothing else to draw for it
    elseif layer.muted[entry.id] then
      -- disabled step: single point at the bottom, no bar -- dimmer than
      -- the vel-0 marker below so a truly-skipped step reads as distinct
      -- from a merely silent one (see MUTED_STEP_LVL above)
      g:led(x, GRID_H, is_playhead and MUTED_STEP_PLAYHEAD_LVL or MUTED_STEP_LVL)
    else
      local vel = effective_velocity(layer, entry)
      local row = row_for_vel(vel)
      for y = row, GRID_H do
        local lvl
        if y == row then
          if vel <= 0 then
            -- true silence: dimmer than any other bottom-row step so
            -- it reads as distinct from a merely quiet (but nonzero)
            -- note that also happens to round down to row GRID_H
            lvl = is_playhead and ZERO_VEL_PLAYHEAD_LVL or ZERO_VEL_LVL
          else
            lvl = is_playhead and 15 or 10
          end
        else
          lvl = is_playhead and 6 or 3
        end
        g:led(x, y, lvl)
      end
    end
  end
  grid_dirty = true -- actual hardware flush happens in grid_refresh_loop, rate-capped
end

-- shown instead of the normal arp view for as long as k1 is held (see
-- redraw_grid below): one column per note currently in the arp, with a
-- single marker on whichever row matches that note's current lap divisor
-- (defaulting to row y = GRID_H, divisor 1 = every lap). divisor rows
-- span the whole grid (y = 1..GRID_H, see lap_divisor_for_y/
-- y_for_lap_divisor above)
--
-- three brightness tiers: dim (6) is "skip" mode, bright (10) is
-- "silent"/mute mode (the default) -- named so neither one is confused
-- with the playhead's brightness. max (15) is reserved entirely for the
-- playhead.
--
-- for a divisor-1 note the playhead is a single dot on the bottom row.
-- for a divisor>1 note it climbs: on the lap right
-- after this note fires it starts at the bottom (y = GRID_H, as far from
-- the divisor row as it gets), then moves one row closer to the divisor
-- row on each subsequent off-lap, arriving exactly on the divisor row
-- itself (y = divisor_y, where that row's own button sits) on the lap it
-- actually fires -- see the playhead_row calc below, which is just "how
-- many laps until raw_lap_count % divisor hits 0", read as rows of
-- distance from divisor_y. this climbs toward divisor_y regardless of
-- lap_invert -- invert only changes which rows the divisor logic below
-- lights up as "selected", not where this note's own divisor button
-- physically sits, and the climb is about reaching that button, not
-- about eligibility.
--
-- it's purely a display overlay on top of whatever that row's normal
-- lit/unlit divisor state would be, and doesn't change what pressing
-- any row does (still divisor 1, still the insert/replace long-press
-- row -- see main_grid_key).
--
-- a pending note-replace/note-insert overrides all of that for its own
-- column, same as in draw_arp_grid: the whole column pulses instead of
-- showing the lap markers. this is what lets a gesture started with k1
-- held stay visible (still pulsing, on the right column) for as long as
-- k1 stays down -- see redraw_grid below, which no longer has to choose
-- between the two views on the gesture's behalf.
local function draw_lap_grid()
  local layer = active()
  local is_chord = (effective_mode_of(layer) == "chord")
  g:all(0)
  for x = 1, #layer.sequence do
    local entry = layer.sequence[x]
    -- same substitution as draw_arp_grid: chord has no traveling
    -- playhead column, so "is this the currently-playing column" becomes
    -- "did this specific note just fire and is it still in its audible
    -- window" (chord_flash) instead of "is this where x==layer.step
    -- happens to be". the divisor-row math just below is untouched --
    -- lap_stamp is refreshed every tick for every entry in chord mode
    -- (see arp_clock), so phase is already current and lands on
    -- divisor_y exactly when chord_flash is true, same as it always has.
    local is_playhead
    if is_chord then
      is_playhead = layer.chord_flash[entry.id] == true
    else
      is_playhead = (x == layer.step)
    end

    if draw_pending_pulse(x, layer, entry) then
      -- handled: column pulsed, nothing else to draw for it
    else
      -- rows 1..GRID_H are the lap-divisor rows (1..MAX_LAP_DIVISOR, see
      -- lap_divisor_for_y/y_for_lap_divisor above). not inverted: only
      -- the selected divisor's row lights up. inverted: flip that --
      -- every OTHER lap row lights up and the selected one goes dark, so
      -- "every Nth lap except this one" reads as a hole punched in an
      -- otherwise-lit column rather than a single lit row. either way,
      -- mute vs skip still reads off brightness alone (dimmer = skip,
      -- brighter = silent/mute), applied to whichever row(s) end up lit.
      local divisor = util.clamp(layer.lap_divisor[entry.id] or 1, 1, MAX_LAP_DIVISOR)
      local divisor_y = y_for_lap_divisor(divisor)
      local is_skip = (layer.lap_mode[entry.id] == "skip")
      local lvl = is_skip and 6 or 9
      local is_invert = layer.lap_invert[entry.id]

      -- distance (in rows) from divisor_y down to GRID_H is exactly
      -- divisor - 1, matching the divisor - 1 off-laps between firings
      -- 1:1 -- so "laps until this note next fires" maps directly onto
      -- "rows until the playhead reaches divisor_y" with no rounding.
      -- phase is counted from this note's own lap_anchor (see lap_anchor
      -- above), same as every actual on_lap check in arp_clock/
      -- step_playable -- otherwise this climb would show a stale phase
      -- left over from whatever the shared counter was doing before this
      -- note's divisor was last set, instead of the phase it's actually
      -- about to fire on. computed unconditionally (not just under
      -- is_playhead) because the skip-mode dim fill below needs it too,
      -- on laps this column isn't actually the live step.
      local anchor = layer.lap_anchor[entry.id] or 0
      -- lap_stamp, not raw_lap_count directly -- the shared counter can
      -- advance on ticks that never actually test this entry (its turn
      -- in the traversal search just hasn't come up yet), which would
      -- otherwise show this column as "due" before it's genuinely been
      -- evaluated. falls back to raw_lap_count for a note that's never
      -- had a traversal turn yet (e.g. divisor 1, or freshly placed).
      local raw_for_phase = layer.lap_stamp[entry.id] or layer.raw_lap_count
      local phase = (divisor > 1) and ((raw_for_phase - anchor) % divisor) or 0
      local playhead_row = nil
      if is_playhead then
        -- no divisor > 1 guard needed here: the formula already works
        -- fine at divisor 1 too. phase is forced to 0 above, so
        -- laps_until_fire is always 0 and playhead_row lands on divisor_y
        -- (GRID_H) every time, which is exactly the single dot on the
        -- bottom row described above.
        local laps_until_fire = (divisor - phase) % divisor
        playhead_row = divisor_y + laps_until_fire
      end

      for row_y = 1, GRID_H do
        if playhead_row and row_y == playhead_row then
          -- playhead overlay: always wins for this column/row,
          -- regardless of whether it's also lit/unlit by the divisor
          -- logic below, or the bottom-row anchor -- max brightness, so
          -- it's unambiguous at a glance which column is currently
          -- playing and how close it is to its next on-lap.
          g:led(x, row_y, 15)
        elseif row_y == GRID_H then
          -- experimental: bottom row is a fixed visual anchor,
          -- independent of this column's divisor/skip/invert state (see
          -- BOTTOM_ROW_ANCHOR_LVL above) -- none of the lit/trail/
          -- background logic below gets a say over this row anymore.
          -- only the playhead overlay above can still override it.
          g:led(x, row_y, BOTTOM_ROW_ANCHOR_LVL)
        else
          -- explicit if/else rather than the `and/or` idiom -- `lit` can
          -- be false here, and `a and false or b` silently falls through
          -- to `b` instead of yielding `false`.
          local lit
          if is_invert then
            lit = (row_y ~= divisor_y)
          else
            lit = (row_y == divisor_y)
          end
          if lit then
            g:led(x, row_y, lvl)
          elseif (not is_invert) and divisor > 1 and row_y > divisor_y then
            -- not inverted, so this row is part of the trail below the
            -- selected divisor row rather than competing with invert's own
            -- every-other-row lighting for the same rows.
            --
            -- silent mode always lands here every single lap (see
            -- step_playable -- it never removes the step from the arp's
            -- traversal, only zeroes velocity at the point of firing), so
            -- the live playhead reliably visits and climbs this trail on
            -- its own -- the whole trail can just stay lit as a static
            -- backdrop for that climb.
            --
            -- skip mode is different: it removes this column from the
            -- traversal entirely on every off-lap pass (see step_playable
            -- again), so the live playhead only ever visits it on the rare
            -- on-lap pass and never gets a chance to climb through here.
            -- rather than a static trail with nothing to climb, fill it in
            -- one row at a time, from the bottom up, one more row per lap
            -- since this note's last on-lap moment -- so the same "how
            -- close to firing" information is still visible continuously,
            -- just as a growing fill instead of a moving dot. phase
            -- already resets to 0 (empty fill) the moment it fires, and
            -- counts back up to divisor - 1 (full trail) right before the
            -- next firing, in lockstep with the actual on-lap timing.
            if is_skip then
              if row_y >= (GRID_H - phase + 1) then
                -- lvl, not MODULO_INDICATOR_LVL: the fill needs to read as
                -- distinct from the still-dim unlit background below, and
                -- lvl is already 6 for skip mode -- using
                -- MODULO_INDICATOR_LVL (2) here made the fill invisible
                -- against itself, since the trail underneath is drawn at
                -- that same level.
                g:led(x, row_y, lvl)
              else
                -- MODULO_INDICATOR_LVL, not 0 -- this row hasn't been
                -- filled in yet, but it's still part of a divisor>1 trail
                -- and should read as a dim backdrop (matching the non-skip
                -- trail just below), not go fully dark. fully dark reads as
                -- "no trail here at all", which is wrong for a column that
                -- does have one.
                g:led(x, row_y, MODULO_INDICATOR_LVL)
              end
            else
              g:led(x, row_y, MODULO_INDICATOR_LVL)
            end
          else
            g:led(x, row_y, 0)
          end
        end
      end
    end
  end
  grid_dirty = true
end

redraw_grid = function()
  -- k1 held always means the lap-select view, gesture pending or not --
  -- draw_lap_grid knows how to show a pending column's pulse itself now
  -- (same as draw_arp_grid), so there's nothing left for this to
  -- arbitrate: holding/releasing k1 just flips between the two views,
  -- same as ever, without touching or interrupting whatever's pending.
  if k1_down then
    draw_lap_grid()
  else
    draw_arp_grid()
  end
end

-- cancels a pending note-replace gesture. on abort (success == false or
-- omitted) the column's velocity override is restored to what
-- it was before the gesture started. on success (called from try_consume_replace,
-- which has already set the new velocity itself) it clears the
-- pending state without touching vel_override again.
abort_replace = function(layer, success)
  if not layer.replace_pending then return end
  if not success then
    layer.vel_override[layer.replace_pending.id] = layer.replace_pending.prev_vel_override
  end
  layer.replace_pending = nil
  layer.replace_pulse_token = layer.replace_pulse_token + 1 -- belt-and-suspenders: still bumped
                                                              -- in case anything else checks it
  if layer.replace_pulse_clock_id then
    clock.cancel(layer.replace_pulse_clock_id)
    layer.replace_pulse_clock_id = nil
  end
  if view_mode == "main" and layer == active() then
    redraw_grid()
  end
end

-- shared by start_replace/start_insert below: the entry either call was
-- armed against may no longer be in the sequence at all -- e.g. a grid
-- long-press timer armed before a k1+k2 (hold toggle) or k1+k3 (sticky
-- toggle) rebuilt the sequence out from under it. without this guard,
-- *_pending would get set on an id that appears nowhere in
-- layer.sequence, so the pulsing column never shows up but the pending
-- state still silently eats the next note played.
local function entry_still_in_sequence(layer, id)
  for _, e in ipairs(layer.sequence) do
    if e.id == id then return true end
  end
  return false
end

-- starts (or cancels, or re-targets) a note-replace gesture for the
-- given sequence entry. repeating the gesture on the same column aborts
-- it; targeting a different column aborts whichever one was pending
-- first, then starts a fresh one on the new column -- only one column
-- can be pending at a time.
local function start_replace(layer, entry)
  if not entry_still_in_sequence(layer, entry.id) then return end

  if layer.replace_pending then
    local was_same = (layer.replace_pending.id == entry.id)
    abort_replace(layer)
    if was_same then return end
  end

  -- mutually exclusive with a pending insert -- only one gesture at a time
  if layer.insert_pending then
    abort_insert(layer)
  end

  layer.replace_pending = {id = entry.id, prev_vel_override = layer.vel_override[entry.id]}
  -- prev_vel_override is captured unconditionally above regardless of
  -- pending_replace_mode, so abort_replace's restore is always a no-op
  -- correct thing to do even under "none" (there's nothing to undo, but
  -- setting it back to what it already was is harmless) -- and so this
  -- setting can safely be flipped mid-gesture without leaving anything
  -- stuck.
  if pending_replace_mode == "mute" then
    layer.vel_override[entry.id] = 0 -- silence, same treatment as vel=0 (see arp_clock)
  end
  layer.replace_pulse_token = layer.replace_pulse_token + 1
  local token = layer.replace_pulse_token
  redraw_grid()

  -- clock id captured and stored so abort_replace/cleanup can cancel it
  -- directly, rather than only relying on the token check below to let
  -- it wind down on its own -- an uncancelled clock left running past
  -- script cleanup (e.g. a replace still pending at reload/stop time)
  -- can leave a dangling coroutine behind.
  --
  -- 0.05s (20Hz): a hard two-level blink would still read fine sampled
  -- at 10Hz, but the moving comet needs the finer sampling to actually
  -- look like continuous motion rather than visibly stepping between
  -- brightness levels or row positions -- same rate insert's pulse
  -- already redraws at.
  layer.replace_pulse_clock_id = clock.run(function()
    while layer.replace_pulse_token == token do
      if view_mode == "main" and layer == active() then
        redraw_grid()
      end
      clock.sleep(0.05)
    end
  end)
end

-- cancels a pending note-insert gesture. nothing was ever spliced into
-- layer.sequence for this (see start_insert below), so there's nothing
-- to remove or restore -- clearing the pending state and stopping the
-- pulse is all that's needed.
abort_insert = function(layer)
  if not layer.insert_pending then return end
  layer.insert_pending = nil
  layer.insert_pulse_token = layer.insert_pulse_token + 1
  if layer.insert_pulse_clock_id then
    clock.cancel(layer.insert_pulse_clock_id)
    layer.insert_pulse_clock_id = nil
  end

  if view_mode == "main" and layer == active() then
    redraw_grid()
  end
end

-- starts (or cancels, or re-targets) a note-insert gesture anchored on
-- the given sequence entry. while pending, this behaves exactly like a
-- replace -- the anchor entry itself is marked pending and pulses in
-- place, layer.sequence is untouched -- except the anchor note is left
-- audible rather than silenced. nothing is spliced in until a note
-- actually arrives (see try_consume_insert), which is also where the
-- new column's final position gets resolved, so there's no longer a
-- stale-index window between "gesture starts" and "gesture resolves"
-- for retargeting to trip over.
local function start_insert(layer, entry)
  if not entry_still_in_sequence(layer, entry.id) then return end

  if layer.insert_pending then
    local was_same = (layer.insert_pending.id == entry.id)
    abort_insert(layer)
    if was_same then return end
  end

  -- mutually exclusive with a pending replace -- only one gesture at a time
  if layer.replace_pending then
    abort_replace(layer)
  end

  layer.insert_pending = {id = entry.id}
  layer.insert_pulse_token = layer.insert_pulse_token + 1
  local token = layer.insert_pulse_token
  redraw_grid()

  layer.insert_pulse_clock_id = clock.run(function()
    while layer.insert_pulse_token == token do
      if view_mode == "main" and layer == active() then
        redraw_grid()
      end
      clock.sleep(0.05)
    end
  end)
end

-- flips whichever gesture (replace or insert) is currently pending on
-- this exact entry to the other type -- calling the *other* type's
-- start_* is what makes this a flip rather than a cancel: each start_*
-- aborts whatever's pending (restoring vel_override if it was a
-- replace) and then arms its own pending state on the same entry, so
-- replace<->insert swaps cleanly with the anchor note staying put.
-- shared by two press handlers below that both reach this same flip --
-- k1+bottom-row (while k1 is held) and a plain bottom-row re-press
-- (without k1, once a gesture is already pending on this column) --
-- since the flip itself doesn't care which gesture triggered it, only
-- what's currently pending on this entry. returns true if this entry
-- had something pending (and it just got flipped), false if it didn't,
-- so callers know whether to fall through to their own next check.
local function flip_pending_gesture(layer, entry)
  if layer.replace_pending and layer.replace_pending.id == entry.id then
    layer.gesture_wave_dir = -layer.gesture_wave_dir
    start_insert(layer, entry)
    return true
  end
  if layer.insert_pending and layer.insert_pending.id == entry.id then
    layer.gesture_wave_dir = -layer.gesture_wave_dir
    start_replace(layer, entry)
    return true
  end
  return false
end

-- moves whichever gesture (replace or insert) is currently pending onto
-- a new anchor entry, preserving its type -- the opposite axis from
-- flip_pending_gesture above, which keeps the anchor but swaps type.
-- calling that *same* type's start_* with the new entry is enough to
-- move it: start_replace/start_insert already abort whatever's
-- currently pending (restoring the old anchor's vel_override if it was
-- a replace) before arming their own pending state on whichever entry
-- they're given, so pointing that call at a different entry than the
-- one currently pending is exactly what "move" means -- no separate
-- move-specific bookkeeping needed. only call this once the caller has
-- already ruled out entry being the column that's already pending
-- (that's a same-column re-press, handled by flip_pending_gesture
-- instead, not a move); calling this on the already-pending entry would
-- hit start_*'s own "re-press same column" branch and cancel the
-- gesture outright rather than move it, which is somebody else's job to
-- avoid, not this function's. returns true if something was pending
-- (and just got moved here), false if nothing was pending at all, so
-- callers know whether to fall through to their own next check.
local function move_pending_gesture(layer, entry)
  if layer.replace_pending then
    start_replace(layer, entry)
    return true
  end
  if layer.insert_pending then
    start_insert(layer, entry)
    return true
  end
  return false
end

-- updates the pitch/velocity of whichever sequence entry has this id,
-- without touching the array's order. layer.sequence and
-- layer.base_sequence share the same underlying entry objects (rotation
-- just reorders references, see rotate_sequence), so mutating via
-- layer.sequence covers both.
local function update_entry_note_inplace(layer, id, note, vel)
  for _, entry in ipairs(layer.sequence) do
    if entry.id == id then
      entry.note = note
      entry.base_note = note
      entry.vel = vel
      return
    end
  end
end

-- if a replace is pending on this layer, this incoming note completes
-- it: the pending column's underlying note is retuned to this pitch in
-- place (wherever its instance lives, held and/or latched), and it takes
-- on this note's velocity, overriding whatever was there before,
-- including the silence set in start_replace.
-- returns true if it consumed the note, false if there was nothing
-- pending (so the caller should fall through to normal note_on handling).
try_consume_replace = function(layer, note, vel, ch)
  if not layer.replace_pending then return false end

  local id = layer.replace_pending.id
  for _, n in ipairs(layer.held) do
    if n.id == id then n.note = note; n.vel = vel; n.ch = ch end
  end
  for _, n in ipairs(layer.latched) do
    if n.id == id then n.note = note; n.vel = vel; n.ch = ch end
  end
  layer.vel_override[id] = nil -- the new vel above is what plays now, same as a normal retrigger

  -- update the entry already sitting in the sequence in place, rather
  -- than doing a full rebuild. the new note lands in the same
  -- column it's replacing. a future rebuild triggered for an unrelated
  -- reason (a new note, a mode change, etc.) will still do a normal
  -- full sort as usual
  update_entry_note_inplace(layer, id, note, vel)

  abort_replace(layer, true) -- clears pending/stops the pulse and repaints

  return true
end

-- if a note-insert is pending on this layer, this incoming note completes
-- it: a genuine new held/latched entry is created for it, and spliced
-- into layer.sequence immediately to the left of the anchor entry --
-- pushing the anchor and everything right of it over by one column. the
-- anchor's own column is resolved fresh, right here, against the
-- sequence as it stands at this exact moment, rather than anything
-- decided back when the gesture started -- so it's always accurate even
-- if the sequence changed while this was pending.
--
-- if the arp was already full (GRID_W columns), this push bumps a note
-- off the right edge entirely -- there's no pending state left to
-- restore it from later, so it's genuinely dropped: its real
-- held/latched entry is removed for good via delete_instance.
--
-- returns true if it consumed the note, false if there was nothing
-- pending (so the caller should fall through to normal note_on handling).
try_consume_insert = function(layer, note, vel, ch)
  if not layer.insert_pending then return false end

  local anchor_id = layer.insert_pending.id

  layer.insert_pending = nil
  layer.insert_pulse_token = layer.insert_pulse_token + 1
  if layer.insert_pulse_clock_id then
    clock.cancel(layer.insert_pulse_clock_id)
    layer.insert_pulse_clock_id = nil
  end

  local idx
  for i, e in ipairs(layer.sequence) do
    if e.id == anchor_id then idx = i break end
  end
  if not idx then
    -- anchor vanished from under us -- shouldn't normally happen (the
    -- note_off guard above aborts this gesture the moment its anchor
    -- note releases), but fall through safely rather than dropping the
    -- incoming note on the floor with no visible reason
    if view_mode == "main" and layer == active() then
      redraw_grid()
    end
    return false
  end

  local id = new_instance_id()
  table.insert(layer.held, {note = note, vel = vel, ch = ch, id = id})
  if layer.hold then
    table.insert(layer.latched, {note = note, vel = vel, ch = ch, id = id})
  end

  -- insert is a genuinely new note with fresh lap settings, never a
  -- lap-memory readback -- stamped explicitly (rather than left absent)
  -- so sync_lap_columns' seed step below reads this id as "already had
  -- its turn" and leaves it alone. every other note's own lap_divisor/
  -- lap_mode simply rides along with its id as it shifts column, same
  -- as it always has. (lap_divisor itself is left absent/default here
  -- deliberately -- lap_synced alone is what opts it out of claiming
  -- now; see sync_lap_columns.)
  layer.lap_synced[id] = true

  table.insert(layer.sequence, idx, {note = note, base_note = note, vel = vel, id = id})

  if #layer.sequence > GRID_W then
    local overflow = table.remove(layer.sequence, GRID_W + 1)
    delete_instance(layer, overflow.id)
  end

  if layer.step > #layer.sequence then
    reset_playhead(layer)
  end

  sync_lap_columns(layer)

  if view_mode == "main" and layer == active() then
    redraw_grid()
  end

  return true
end

-- shared tap-vs-hold threshold for two gestures below: a plain
-- bottom-row press (a tap mutes, a repeated tap on an already-muted step
-- flips it to true skip, a hold deletes the step outright) and a
-- k1+top-row press (note-replace vs. note-insert, depends on
-- "k1 priority", see k1_priority above)
local LONG_PRESS_TIME = 0.36 -- seconds
local key_state = {} -- key_state[x] = {y = , long_fired = }

-- k1+ bottom press fully removes a note instance from the arp -- a
-- deliberate discard, distinct from an ordinary release (physical
-- key-up, or hold turning off). that distinction matters for lap
-- memory: a normal release still goes through prune_vel_mute_state
-- below, which banks the departing note's lap_divisor/lap_mode/
-- lap_invert into layer.lap_pool so a future note can inherit them
-- (see that function's comment) -- the idea being the note might come
-- back, so its settings are worth remembering. a delete is the
-- opposite: the person explicitly told this note to go away, so its
-- lap settings should go away with it, not get handed off to
-- whatever's queued up next. this function never touches layer.lap_pool
-- for that reason -- not an oversight, and NOT a bug to "fix" by making
-- it match prune_vel_mute_state (this has been tried before and
-- reverted). the splice below (removing this id from layer.sequence
-- directly, ahead of the caller's own rebuild_sequence) is part of how
-- that's enforced: prune_vel_mute_state can only harvest an id it still
-- finds in layer.sequence, so splicing it out here first is what keeps
-- a deleted note's settings from being harvested at all.
delete_instance = function(layer, id)
  for i = #layer.held, 1, -1 do
    if layer.held[i].id == id then table.remove(layer.held, i) end
  end
  for i = #layer.latched, 1, -1 do
    if layer.latched[i].id == id then table.remove(layer.latched, i) end
  end
  layer.vel_override[id] = nil
  layer.muted[id] = nil
  layer.note_octave_lap[id] = nil

  -- also splice this id's column directly out of the live sequence,
  -- rather than relying solely on the caller's rebuild_sequence call
  -- right after this -- that rebuild deliberately no-ops while frozen
  -- in thru mode (see the thru guard in rebuild_sequence above), which
  -- would otherwise leave a deleted note fully gone from held/latched
  -- but still visibly/audibly present in the frozen sequence until you
  -- eventually leave thru. removing it here directly means delete takes
  -- effect immediately in every mode, matching every other per-note
  -- edit (mute, lap divisor, velocity), which already read live off
  -- entry.id rather than needing a rebuild at all. NOT a no-op outside
  -- of thru, despite the caller's rebuild_sequence overwriting
  -- layer.sequence wholesale right after anyway -- this splice runs
  -- first, so it's also what keeps prune_vel_mute_state (called from
  -- that same rebuild) from ever seeing this id in layer.sequence and
  -- harvesting it into layer.lap_pool -- see the discard-vs-release
  -- comment above.
  for i, e in ipairs(layer.sequence) do
    if e.id == id then
      table.remove(layer.sequence, i)
      break
    end
  end
  if layer.step > #layer.sequence then
    reset_playhead(layer)
  end
  if view_mode == "main" and layer == active() then
    redraw_grid()
  end
end

-- cycles this note's lap_mode between "silent" (nil, the default) and
-- "skip" -- shared by the short-tap release handler and the long-press
-- handler below (once modulo/invert is already on, a long press reaches
-- this same cycle instead of toggling invert back off).
local function cycle_lap_mode(layer, id)
  if layer.lap_mode[id] == nil then
    layer.lap_mode[id] = "skip"
  else
    layer.lap_mode[id] = nil
  end
end

-- lap_mode a fresh pick (or a divisor-1 reset, see below) lands on --
-- just pulled out so both places that need "the default" share one spot.
local function default_lap_mode()
  return nil
end

-- resets this note's mode/invert to their shared default (mode -> nil/
-- silent, invert -> false). used whenever
-- this column lands on (or repeat-presses) divisor 1 specifically: at
-- divisor 1 there's no off-lap for mode or invert to mean anything about
-- (it plays every single lap regardless), so picking divisor 1, or a
-- repeat press there -- short or long -- reasserts this default instead
-- of cycling/toggling either axis or leaving whatever this column's
-- toggles happened to be carrying over from a previous divisor, rather
-- than leaving a stale mode/invert sitting on a row that can't actually
-- express them. any other divisor pick (2..MAX_LAP_DIVISOR) leaves
-- mode/invert untouched -- see the k1+lap-row press handler below.
local function reset_lap_state(layer, id)
  layer.lap_mode[id] = default_lap_mode()
  layer.lap_invert[id] = false
  -- divisor 1 has no on-lap/off-lap distinction for anything to anchor
  -- against, so clear this note's anchor back to nil (= 0) here too --
  -- the next genuine divisor pick (see main_grid_key) re-stamps it fresh,
  -- rather than this note silently carrying over whatever lap phase its
  -- previous divisor happened to leave behind.
  layer.lap_anchor[id] = nil
end

local function main_grid_key(x, y, z)
  local layer = active()
  local entry = layer.sequence[x]
  if not entry then
    -- empty column -- no note lives here at all, so there's no entry to
    -- move or flip a gesture onto (unlike the other "press elsewhere"
    -- paths below, which can retarget a pending gesture onto whatever
    -- real note got pressed): a press here always aborts outright,
    -- including a bottom-row press, regardless of what's pending.
    if z == 1 and (layer.replace_pending or layer.insert_pending) then
      abort_replace(layer)
      abort_insert(layer)
      redraw_grid()
    end
    return
  end

  if z == 1 then
    if k1_down then
      -- k1 + the divisor-1 row (y = GRID_H, bottom): pressing this again
      -- on the exact column that already has a gesture pending --
      -- replace OR insert -- flips it straight to the other gesture type
      -- instead of cancelling (see flip_pending_gesture above). there's
      -- no tap/hold ambiguity left to resolve on a re-press (the column
      -- is already committed to a gesture), so this fires immediately
      -- with no timer, and repeated taps just keep flipping back and
      -- forth indefinitely. the same flip is also reachable without k1
      -- (see the plain bottom-row handler further down) -- insert/replace
      -- itself is still only ever *started* by a k1+long-press on this
      -- same row (see the long-press timer below); there's no tap/hold
      -- split on which gesture a fresh k1 press reaches, since a fresh
      -- k1 tap on this row is dedicated to plain divisor-1 selection
      -- instead.
      if y == GRID_H and flip_pending_gesture(layer, entry) then
        key_state[x] = nil
        return
      end

      -- same row, but on some *other* column than the one currently
      -- pending: moves the gesture here instead of flipping its type
      -- (see move_pending_gesture above), same immediate no-timer
      -- re-press behavior as the flip case just above. also reachable
      -- without k1 -- see the plain bottom-row handler further down.
      if y == GRID_H and move_pending_gesture(layer, entry) then
        key_state[x] = nil
        return
      end

      -- k1 + any row: sets this note's lap divisor -- how many laps of
      -- the arp pass between this note's triggers. the grid switches to
      -- a dedicated lap-select view for as long as k1 is held (see
      -- draw_lap_grid/redraw_grid below), so the row pressed here is
      -- visually confirmed there.
      --
      -- while a replace or insert is pending anywhere on this layer, a
      -- press on any row OTHER than the divisor-1 row is discarded
      -- outright: it aborts the gesture and does nothing else -- no
      -- divisor change, no mode toggle. this holds regardless of which
      -- column got pressed or which view happens to be up; "pending" is
      -- a layer-wide state, not a per-view one, so lap and arp presses
      -- are held to the same rule. the divisor-1 row is exempt because
      -- it's also where insert/replace itself lives: a press there on
      -- the pending column flips gesture type, and a press there on a
      -- *different* column moves the gesture there instead (both
      -- handled above) -- so by the time this check runs, "pending" here
      -- only ever means a row other than the divisor-1 row got pressed.
      if y ~= GRID_H and (layer.replace_pending or layer.insert_pending) then
        abort_replace(layer)
        abort_insert(layer)
        redraw_grid()
        return
      end

      -- picking a genuinely different row than this note's current
      -- divisor is deferred to release/long-press-fire for every row,
      -- not just the divisor-1 row: committing the new divisor
      -- immediately on press would mean a long press meant to enable
      -- modulo/invert on a brand-new divisor flashes that divisor on
      -- (fully lit, un-inverted) for the whole LONG_PRESS_TIME window
      -- before invert then toggles it, since the commit and the
      -- invert-toggle would happen at two different times. holding off
      -- the divisor commit itself until the press
      -- resolves -- short tap or long press -- means there's nothing to
      -- flash prematurely: a short tap commits divisor only (see the
      -- ks.fresh_pick branch down there), a long press commits divisor
      -- and flips invert together, in the same redraw, same as the
      -- divisor-1 row's already-deferred commit above.
      --
      -- mode and invert are left exactly as they were on this column,
      -- though -- switching (say) divisor 3 -> 4 keeps whatever
      -- skip/modulo combo was already dialed in here instead of snapping
      -- it back to default; a column's toggles are meant to survive a
      -- divisor change, not get wiped by one. the one exception is
      -- picking divisor 1 itself: there's no off-lap for mode or invert
      -- to mean anything about there (it plays every single lap
      -- regardless), so landing on divisor 1 always resets both to their
      -- shared default, discarding whatever this column had before --
      -- see reset_lap_state below.
      local new_divisor = util.clamp(lap_divisor_for_y(y), 1, MAX_LAP_DIVISOR)
      local fresh_pick = layer.lap_divisor[entry.id] ~= new_divisor

      -- same row as this note's current divisor (whether it was already
      -- selected coming in, or was just selected above on this very
      -- press): now there's a genuine tap/hold ambiguity, same shape as
      -- the divisor-1 row's insert/replace and the main screen's bottom
      -- row mute/skip. release before LONG_PRESS_TIME reaches the
      -- short-tap outcome (see the release branch below); hold past it
      -- reaches the one below. only on a genuine repeat press
      -- (fresh_pick false) -- a fresh pick's own tap is dedicated to picking the divisor itself
      -- and does nothing further here, whether or not that pick happened
      -- to reset mode/invert above; cycling only ever applies to a
      -- genuine repeat press on a row that was already selected.
      --
      -- the two gestures are deliberately independent axes: short tap
      -- always cycles mode (mute/skip) and never touches modulo/invert;
      -- long press always toggles modulo/invert and never touches mode.
      -- neither one's outcome depends on the other's current state, so
      -- what a press does is always predictable from the gesture alone
      -- -- except at divisor 1, see below.
      local my_state = {y = y, k1_lap = true, long_fired = false, id = entry.id, fresh_pick = fresh_pick}
      key_state[x] = my_state
      clock.run(function()
        clock.sleep(LONG_PRESS_TIME)
        -- identity check, not just a field/id match: key_state[x] may
        -- have been overwritten by a later press on this same column
        -- (e.g. rapid short-taps across adjacent lap rows) since this
        -- timer was scheduled. checking ks.id == entry.id alone isn't
        -- enough to rule that out -- a later press on the very same
        -- column is on the very same entry.id too. without comparing
        -- table identity, this now-stale timer would find that newer
        -- press's table still sitting there with long_fired still false
        -- and wrongly fire the long-press (modulo/invert) outcome on it,
        -- even though that newer press was only ever a short tap.
        if key_state[x] == my_state and not my_state.long_fired then
          my_state.long_fired = true
          -- invert is a no-op at divisor 1 -- step_playable/arp_clock's
          -- on_lap/inverted check only ever applies when divisor > 1, so
          -- toggling it here would leave lap_invert true with nothing to
          -- show for it audibly, while draw_lap_grid would still draw it
          -- as if it mattered. divisor 1 is also where insert/replace
          -- lives, so a long press there starts a gesture (which one
          -- depends on k1_priority) rather than touching mode/invert at
          -- all. every other divisor's long press just toggles invert.
          --
          -- checked against the row itself (y == GRID_H), not against
          -- layer.lap_divisor[entry.id] -- on a fresh pick, that value
          -- hasn't been written yet (see the deferred-apply comment in
          -- the press handler above), so reading it here would still
          -- show the note's *previous* divisor and wrongly fall through
          -- to the invert toggle below.
          if y == GRID_H then
            if k1_priority == "insert" then
              start_insert(layer, entry)
            else
              start_replace(layer, entry)
            end
            return
          else
            if my_state.fresh_pick then
              -- deferred divisor commit, general-row counterpart of the
              -- divisor-1 row's deferred commit above: this long press
              -- confirms modulo should apply to the newly picked divisor,
              -- so commit it now, in the same breath as the invert
              -- toggle just below, rather than back at press-time -- see
              -- the deferred-apply comment further up. new_divisor is the
              -- same local computed in the press handler above; this
              -- closure still sees it.
              layer.lap_divisor[entry.id] = new_divisor
              layer.lap_anchor[entry.id] = layer.raw_lap_count
              layer.lap_stamp[entry.id] = nil
              layer.note_octave_lap[entry.id] = nil
            end
            layer.lap_invert[entry.id] = not layer.lap_invert[entry.id]
          end
          -- same reasoning as the divisor-pick branch above -- sync now,
          -- don't wait for a rebuild that may never see this column again
          sync_lap_columns(layer)
          redraw_grid()
        end
      end)
      return
    end

    -- same flip as the k1+bottom-row case above, but reachable without
    -- holding k1: once a gesture is started (which still always takes a
    -- k1+long-press -- see above), a plain bottom-row tap on that exact
    -- pending column flips it to the other gesture type too, same as
    -- holding k1 would. this has to be checked before the generic
    -- "any press while pending aborts" rule just below, since it's the
    -- one exception to that rule -- same relationship the k1_down
    -- version of this flip has with its own copy of that rule.
    if y == GRID_H and flip_pending_gesture(layer, entry) then
      key_state[x] = nil
      return
    end

    -- same move as the k1+bottom-row case above, also reachable without
    -- k1: a plain bottom-row tap on some *other* column than the one
    -- currently pending moves the gesture here instead of flipping its
    -- type (see move_pending_gesture above). checked before the generic
    -- abort rule just below for the same reason the flip case is -- this
    -- is the other exception to it.
    if y == GRID_H and move_pending_gesture(layer, entry) then
      key_state[x] = nil
      return
    end

    -- while a replace or insert is pending anywhere on this layer, any
    -- other press is discarded outright, same rule as the k1+lap-row
    -- case above: it aborts the gesture and does nothing else -- no
    -- velocity set, no re-enable, no mute/skip timer armed. this is
    -- everything left once the two bottom-row exceptions above (flip on
    -- the pending column, move on any other column) have already had
    -- their turn -- any row other than the bottom row, on any column.
    if layer.replace_pending or layer.insert_pending then
      abort_replace(layer)
      abort_insert(layer)
      redraw_grid()
      return
    end

    -- captured before the vel/mute reset just below touches either of
    -- them: true if this step was already muted (vel 0, not skipped)
    -- at the moment of this press. used to tell a fresh mute-tap apart
    -- from a repeated one -- see the release handler below.
    local already_muted = (y == GRID_H) and layer.vel_override[entry.id] == 0
      and not layer.muted[entry.id]

    local my_state = {y = y, long_fired = false, already_muted = already_muted}
    key_state[x] = my_state

    -- applied immediately on press: set this step's velocity, and
    -- re-enable it if it was disabled. a held bottom-row press may
    -- still turn into a mute toggle below, but the velocity/re-enable
    -- takes effect right away rather than waiting on release.
    layer.vel_override[entry.id] = vel_for_row(y)
    if layer.muted[entry.id] then
      layer.muted[entry.id] = false
    end
    redraw_grid()

    if y == GRID_H then
      clock.run(function()
        clock.sleep(LONG_PRESS_TIME)
        -- identity check, not just a field match: key_state[x] may have
        -- been overwritten by a later press on this same column (e.g. a
        -- quick tap-release-tap between the bottom row and an adjacent
        -- row) since this timer was scheduled. without this check, this
        -- now-stale timer would find that newer press's table still
        -- sitting there with long_fired still false and wrongly fire the
        -- delete on it.
        if key_state[x] == my_state and not my_state.long_fired then
          my_state.long_fired = true
          -- long-press on the bottom row deletes this step entirely, not
          -- just skips it. unconditional abort here, same rule used
          -- everywhere else in this file: any action other than
          -- continuing the gesture itself should cancel a pending
          -- replace/insert. rebuild_sequence redraws on its own (guarded
          -- to main view, same as everywhere else it's called), so no
          -- redraw_grid() needed here.
          --
          -- skip is reachable instead via a repeated short tap on an
          -- already-muted step (see ks.already_muted in the release
          -- handler below), not via a long press here.
          abort_replace(layer)
          abort_insert(layer)
          delete_instance(layer, entry.id)
          rebuild_sequence(layer)
        end
      end)
    end
  else
    local ks = key_state[x]
    if ks and ks.k1_lap and not ks.long_fired and ks.fresh_pick and ks.y == GRID_H then
      -- a fresh pick on the divisor-1 row, released before LONG_PRESS_TIME:
      -- confirms this was a short tap rather than the insert/replace long
      -- press, so it's now safe to actually commit the divisor-1 pick
      -- that was deferred in the press handler above (see the comment
      -- there).
      layer.lap_divisor[entry.id] = 1
      reset_lap_state(layer, entry.id)
      layer.note_octave_lap[entry.id] = nil
      sync_lap_columns(layer)
      redraw_grid()
    end
    if ks and ks.k1_lap and not ks.long_fired and ks.fresh_pick and ks.y ~= GRID_H then
      -- a fresh pick on any other row, released before LONG_PRESS_TIME:
      -- confirms this was a short tap rather than the long press that
      -- would've paired this divisor with invert, so commit just the
      -- divisor now, with mode/invert left exactly as they already were
      -- on this column -- same deferred-commit idea as the divisor-1 row
      -- above, now applied to every row so nothing flashes on briefly at
      -- press-time before a long press has a chance to also flip invert
      -- (see the deferred-apply comment in the press handler above).
      local new_divisor = util.clamp(lap_divisor_for_y(ks.y), 1, MAX_LAP_DIVISOR)
      layer.lap_divisor[entry.id] = new_divisor
      layer.lap_anchor[entry.id] = layer.raw_lap_count
      layer.lap_stamp[entry.id] = nil
      layer.note_octave_lap[entry.id] = nil
      sync_lap_columns(layer)
      redraw_grid()
    end
    if ks and ks.k1_lap and not ks.long_fired and not ks.fresh_pick then
      -- released before LONG_PRESS_TIME on the already-selected lap
      -- row: a short tap. skipped entirely when this press was itself
      -- the fresh pick (ks.fresh_pick) -- a fresh pick's tap is handled
      -- by one of the two branches just above instead, and has nothing
      -- further to do here.
      --
      -- a short tap always cycles mode (mute/skip) and never touches
      -- modulo/invert -- see the long-press handler above for the other
      -- half of this pair. divisor 1 is the one exception: neither axis
      -- means anything there (see the long-press handler's comment), so
      -- a short tap resets to the shared default instead of cycling.
      local divisor = layer.lap_divisor[entry.id] or 1
      if divisor <= 1 then
        reset_lap_state(layer, entry.id)
      else
        cycle_lap_mode(layer, entry.id)
      end
      -- same reasoning as the divisor-pick/invert edits above -- this
      -- doesn't touch the sequence's column layout, so nothing else would
      -- ever mirror it into the buffer before this column potentially
      -- disappears on release
      sync_lap_columns(layer)
      redraw_grid()
    end
    if ks and ks.y == GRID_H and not ks.long_fired and ks.already_muted then
      -- released before LONG_PRESS_TIME elapsed on the bottom row. a
      -- short tap normally just re-applies mute (already done on press,
      -- nothing left to do here). but if the step was already muted
      -- going into this press, that would be a no-op tap -- so,
      -- mirroring the k1+top-row repeated-tap flip between
      -- insert/replace, treat a repeated tap on an already-muted step as
      -- a request for the other state and flip it straight to skip
      -- instead. a step that was already skipped doesn't hit this
      -- branch: the press-time unmute above already brought it back to
      -- plain mute, which is the desired no-op.
      layer.muted[entry.id] = true
      redraw_grid()
    end
    key_state[x] = nil
  end
end

-- ------------------------------------------------------------------
-- pattern view (save / recall grid)
-- ------------------------------------------------------------------

-- left half of the grid = layer a's slots, right half = layer b's.
-- slot index within a layer's half is row-major: (row - 1) * half_w +
-- col_in_half. computed fresh each call, not cached at load time, since
-- GRID_W itself can change underneath this if the connected device does
-- (see sync_grid_dims) -- a stale cached half-width would split the
-- grid at the wrong column, or leave column 5-8 dead on an 8-wide device
-- if this were still using a half-width baked in from a 16-wide one.
local function pattern_half_w()
  return math.floor(GRID_W / 2)
end

local function layer_num_for_col(x)
  return (x <= pattern_half_w()) and 1 or 2
end

local function slot_index_for_xy(x, y)
  local half_w = pattern_half_w()
  local col_in_half = (x <= half_w) and x or (x - half_w)
  return (y - 1) * half_w + col_in_half
end

local function draw_pattern_grid()
  g:all(0)
  for y = 1, GRID_H do
    for x = 1, GRID_W do
      local layer_num = layer_num_for_col(x)
      local layer = layers[layer_num]
      local idx = slot_index_for_xy(x, y)
      local snapshot = patterns[layer_num][idx]
      local occupied = snapshot ~= nil
      -- a saved slot with an empty notes list (settings-only snapshot,
      -- e.g. for live-performance recall of division/mode/octave/etc
      -- with nothing actually sounding) reads dimmer than one that has
      -- notes, at both the loaded and unloaded brightness tiers, so the
      -- grid still shows at a glance which slots will actually play
      -- something vs just reconfigure the layer.
      local has_notes = occupied and snapshot.notes and #snapshot.notes > 0
      local lvl
      if idx == layer.loaded_slot then
        lvl = has_notes and 15 or 9
      elseif occupied then
        lvl = has_notes and 4 or 2
      else
        lvl = 1
      end
      g:led(x, y, lvl)
    end
  end
  grid_dirty = true
end

-- wipes every saved phrase slot on both layers -- wired to the "clear all
-- phrases" trigger param below. also drops each layer's loaded_slot
-- highlight, since whatever it was pointing at no longer exists, and
-- repaints the pattern grid immediately if that's the view currently
-- showing rather than waiting for the next key press to reveal it's empty.
local function clear_all_patterns()
  patterns = {{}, {}}
  for _, layer in ipairs(layers) do
    layer.loaded_slot = nil
  end
  save_patterns_to_disk()
  if view_mode == "pattern" then
    draw_pattern_grid()
  end
end

-- debounce per half to prevent ghost presses from my dodgy neotrellis
local PATTERN_DEBOUNCE = 0.08 -- seconds
local last_pattern_press_time = {0, 0}

local function pattern_grid_key(x, y, z)
  if z ~= 1 then return end

  local layer_num = layer_num_for_col(x)

  local now = util.time()
  if now - last_pattern_press_time[layer_num] < PATTERN_DEBOUNCE then return end
  last_pattern_press_time[layer_num] = now

  local layer = layers[layer_num]
  local idx = slot_index_for_xy(x, y)
  local occupied = patterns[layer_num][idx] ~= nil

  if k1_down then
    if occupied then
      patterns[layer_num][idx] = nil
      if layer.loaded_slot == idx then
        layer.loaded_slot = nil
      end
      save_patterns_to_disk()
      draw_pattern_grid()
    end
    return
  end

  if occupied then
    active_layer = layer_num
    key_state = {} -- drop any in-flight long-press tracking from the old active layer
    recall_layer(layer, patterns[layer_num][idx])
    layer.loaded_slot = idx
    draw_pattern_grid()
    redraw() -- active_layer now guarantees layer == active(), always redraw
  else
    -- saved even with no notes held/latched: a snapshot's division,
    -- mode, octave span, repeats, rotation (and hold/sticky, in "per
    -- phrase" mode) are all still worth recalling on their own for live
    -- performance, so an empty note set doesn't disqualify the save --
    -- see draw_pattern_grid for how these show up dimmer on the grid
    -- than a slot that actually has notes.
    patterns[layer_num][idx] = capture_layer(layer)
    layer.loaded_slot = idx
    save_patterns_to_disk()
    draw_pattern_grid()
  end
end

local function toggle_view()
  key_state = {} -- drop any in-flight long-press tracking from the old view
  if view_mode == "main" then
    abort_replace(active()) -- changing to phrase view aborts any pending replace
    abort_insert(active())  -- ...and any pending insert
    view_mode = "pattern"
    draw_pattern_grid()
  else
    view_mode = "main"
    redraw_grid()
  end
end

g.key = function(x, y, z)
  if view_mode == "pattern" then
    pattern_grid_key(x, y, z)
  else
    main_grid_key(x, y, z)
  end
end

-- ------------------------------------------------------------------
-- arp clock
-- ------------------------------------------------------------------

-- computes the next raw index given the current mode. updn/dnup
-- bounce back and forth across the same single-pass grid columns instead
-- of the grid holding a duplicated up-then-down list. everything else
-- just wraps forward. "wrapped" means a lap/pass boundary was crossed
-- (used to advance the octave lap).
local function step_index(layer, idx, direction, n)
  local mode = ARP_MODES[layer.mode_idx]
  if mode == "thru" then
    -- frozen: keep whatever traversal style (bounce vs linear) was
    -- active before entering thru, not "thru" itself
    mode = layer.frozen_mode
  end

  if mode == "updn" or mode == "dnup" or mode == "ord.pp" then
    local next_idx = idx + direction
    local wrapped = false
    if next_idx < 1 then
      next_idx = (n >= 2) and 2 or 1
      direction = 1
      wrapped = true
    elseif next_idx > n then
      next_idx = (n >= 2) and (n - 1) or n
      direction = -1
    end
    return next_idx, direction, wrapped
  else
    local next_idx = idx + 1
    local wrapped = false
    if next_idx > n then
      next_idx = 1
      wrapped = true
    end
    return next_idx, 1, wrapped
  end
end

-- is this entry landable at all right now? always false if literally
-- muted (bottom-row toggle). a "skip" lap_mode note is only landable on
-- a lap that's a multiple of its divisor -- on an off-lap it's treated
-- exactly like a muted step, so the search below jumps over it entirely
-- instead of landing on it. a "silent" (default) lap_mode note is always
-- landable regardless of lap -- it still takes its turn in the
-- traversal/ratchet every lap, it just plays at vel 0 on an off-lap (see
-- the divisor check in arp_clock below). raw_lap is the lap count this
-- entry would actually land on, which during a forward search may be
-- further ahead than layer.raw_lap_count if the search crosses a lap
-- boundary along the way.
local function step_playable(layer, entry, raw_lap)
  if not entry then return false end
  -- stamp before any of the muted/skip logic below, so every candidate
  -- the traversal search actually touches gets a fresh stamp regardless
  -- of whether it turns out playable -- draw_lap_grid reads this instead
  -- of layer.raw_lap_count directly (see lap_stamp above).
  layer.lap_stamp[entry.id] = raw_lap
  if layer.muted[entry.id] then return false end
  if layer.lap_mode[entry.id] == "skip" then
    local divisor = util.clamp(layer.lap_divisor[entry.id] or 1, 1, MAX_LAP_DIVISOR)
    -- counted from this note's own lap_anchor, not from raw_lap directly
    -- (see lap_anchor above) -- so "on lap" means "divisor laps since
    -- this note took on this divisor", not "raw_lap happens to be a
    -- multiple of divisor".
    local anchor = layer.lap_anchor[entry.id] or 0
    local on_lap = ((raw_lap - anchor) % divisor == 0)
    local inverted = layer.lap_invert[entry.id] or false
    if divisor > 1 and (on_lap == inverted) then
      return false
    end
  end
  return true
end

-- searches forward (respecting the current mode's direction rules) for the
-- next non-skipped step. returns nil if everything's skipped. second return
-- value is how many lap boundaries were crossed during the search.
-- random mode picks a fresh random step every time, rather than walking
-- a fixed (if scrambled) order. "wraps" (for octave lap purposes) is
-- approximated by counting every n picks as one lap
local function next_random_step(layer)
  local n = #layer.sequence
  if n == 0 then return nil, 0 end

  local candidates = {}
  for i = 1, n do
    local entry = layer.sequence[i]
    if step_playable(layer, entry, layer.raw_lap_count) then
      table.insert(candidates, i)
    end
  end

  if #candidates == 0 then
    -- nothing landable this lap -- e.g. every note sharing a lap divisor
    -- in "skip" mode, all off-lap at once. still edge the random "lap"
    -- counter forward (using the full sequence length as the divisor,
    -- since there are no candidates to count against) so this doesn't
    -- freeze raw_lap_count and deadlock itself out of ever becoming
    -- eligible again -- see the same reasoning in arp_clock below.
    layer.random_pick_count = (layer.random_pick_count or 0) + 1
    local wraps = 0
    if layer.random_pick_count >= n then
      wraps = 1
      layer.random_pick_count = 0
    end
    return nil, wraps
  end

  local idx = candidates[math.random(#candidates)]

  layer.random_pick_count = (layer.random_pick_count or 0) + 1
  local wraps = 0
  if layer.random_pick_count >= #candidates then
    wraps = 1
    layer.random_pick_count = 0
  end
  return idx, wraps
end

-- chord mode's playhead has nothing to search for: every eligible note
-- in the pool sounds together on every tick (see the chord branch in
-- arp_clock below), so unlike every other mode there's no such thing as
-- an "unlandable" step to skip over or freeze on. the playhead just
-- advances forward by one and wraps, unconditionally, same cadence as
-- plain "up" -- this is also what keeps the lap/octave bookkeeping
-- (raw_lap_count, layer.lap) advancing at exactly one lap per full pass
-- through the columns, matching every other mode.
local function next_chord_step(layer)
  local n = #layer.sequence
  if n == 0 then return nil, 0 end
  local idx = layer.step
  if idx < 1 or idx > n then idx = 0 end
  local next_idx = idx + 1
  local wraps = 0
  if next_idx > n then
    next_idx = 1
    wraps = 1
  end
  return next_idx, wraps
end

local function next_unmuted_step(layer)
  local mode = ARP_MODES[layer.mode_idx]
  if mode == "thru" then
    mode = layer.frozen_mode
  end

  if mode == "rand" then
    return next_random_step(layer)
  end

  if mode == "chord" then
    return next_chord_step(layer)
  end

  local n = #layer.sequence
  if n == 0 then return nil, 0 end
  local idx = layer.step
  local direction = layer.direction
  local wraps = 0
  for _ = 1, n * 2 do
    local next_idx, new_dir, wrapped = step_index(layer, idx, direction, n)
    idx = next_idx
    direction = new_dir
    if wrapped then wraps = wraps + 1 end
    local entry = layer.sequence[idx]
    if step_playable(layer, entry, layer.raw_lap_count + wraps) then
      layer.direction = direction
      return idx, wraps
    end
  end
  layer.direction = direction
  return nil, wraps
end

-- one independent coroutine per layer: each syncs to its own division on
-- the shared clock grid, so the two layers stay locked to the same clock
-- but can run different divisions/modes/etc.
local function arp_clock(layer)
  while true do
    clock.sync(DIVISIONS[layer.division_idx].beat)

    -- "off" mode keeps layer.sequence populated now (see order_pool) so
    -- the grid still shows the held notes, but the arp engine itself
    -- must stay fully bypassed while off -- notes go out via note_on's
    -- raw passthrough branch instead, never through here. this also
    -- forces layer.step to 0 every tick (the "else" branch below), which
    -- is what makes the playhead stop and disappear on the grid.
    if #layer.sequence > 0 and ARP_MODES[layer.mode_idx] ~= "off" then
      -- thru just keeps replaying whatever frozen_mode was active before
      -- it froze, same substitution used everywhere else (order_pool,
      -- step_index, next_unmuted_step) -- so a layer frozen out of chord
      -- still chords here too. computed once per tick, up here, since
      -- the landing block below also needs it (chord mode doesn't use
      -- per-note octave counters at all -- see that block).
      local effective_mode = effective_mode_of(layer)

      -- chord mode's grid flash is throttled to once per full pass through
      -- the sequence (the same wraps signal that already drives layer.lap
      -- below), not once per individual note-fire -- every note re-fires
      -- every tick regardless (audio is untouched by this flag), but with
      -- a chord of any real size lighting the grid on every single tick
      -- read as a strobe rather than a pulse. this just means "a cycle
      -- completed this tick, so this is the one tick out of the pass that
      -- gets to animate" -- effectively dividing the flash rate by the
      -- note count, same divisor a full pass already takes in ticks.
      local flash_this_tick = false

      if layer.repeat_count <= 0 then
        local next_step, wraps = next_unmuted_step(layer)
        if wraps > 0 then
          -- always advance the raw lap counter by however many lap
          -- boundaries the search actually crossed, whether or not it
          -- found a landable step. lap-divisor eligibility (see
          -- step_playable) itself depends on this counter moving
          -- forward, so if it only advanced on a successful landing, an
          -- all-ineligible lap (e.g. every note sharing a divisor in
          -- "skip" mode, all off-lap together) would freeze it and
          -- deadlock permanently. the octave lap counter below doesn't
          -- have this problem -- it's fine for it to freeze while
          -- nothing's playing -- so it keeps its original, success-only
          -- behavior.
          layer.raw_lap_count = layer.raw_lap_count + wraps
          flash_this_tick = true
        end
        if next_step then
          layer.step = next_step
          layer.repeat_count = layer.repeats
          if wraps > 0 then
            layer.lap = (layer.lap + wraps) % octave_lap_count(layer)
          end

          -- decide (and, for divisor>1 notes, advance) which octave-lap
          -- this landing plays at -- once per landing, right here, not
          -- once per repeat. repeats/ratchets replay this same landed
          -- step over several ticks in a row (see repeat_count below);
          -- every rep of one landing has to sound at the same octave, so
          -- this is stashed in layer.step_note_lap and just read back on
          -- every rep below, rather than recomputed inside the vel>0
          -- firing check further down where it would re-run per rep.
          local landed_entry = layer.sequence[layer.step]
          if landed_entry and effective_mode ~= "chord" then
            local divisor = util.clamp(layer.lap_divisor[landed_entry.id] or 1, 1, MAX_LAP_DIVISOR)
            if divisor > 1 then
              local note_lap = layer.note_octave_lap[landed_entry.id] or layer.lap
              local anchor = layer.lap_anchor[landed_entry.id] or 0
              local on_lap = ((layer.raw_lap_count - anchor) % divisor == 0)
              local inverted = layer.lap_invert[landed_entry.id] or false
              if on_lap ~= inverted then
                -- this landing actually lands on-lap for this note --
                -- advance its private counter for next time, and use
                -- this lap for every rep of the current landing. a
                -- bottom-row (vel_override 0) mute doesn't gate this:
                -- the counter keeps advancing in the background even
                -- while silenced, same as an on-lap note always has.
                layer.note_octave_lap[landed_entry.id] = (note_lap + 1) % octave_lap_count(layer)
              end
              layer.step_note_lap = note_lap
            else
              layer.step_note_lap = nil
            end
          end
        else
          layer.step = 0
          layer.repeat_count = 0 -- keep re-checking every tick in case a step gets unmuted
        end
      end

      if layer.step > 0 then
        layer.repeat_count = layer.repeat_count - 1

        -- swing phase is derived fresh from the absolute transport clock
        -- position every time a step lands, not tracked as a per-layer
        -- running counter. a counter-based approach means each layer's
        -- own on/off-beat labeling depends on its own reset history, so
        -- two layers started at different moments could land on opposite
        -- parity despite nominally playing "the same beat" -- audibly
        -- out of phase with each other even with identical swing.
        -- reading the absolute clock instead means both layers agree on
        -- which beat positions are on/off-beat purely because they're
        -- reading the same external transport, regardless of when
        -- either one last reset -- so with swing enabled it's not
        -- possible for them to fall out of phase with each other.
        -- clock.sync just landed this tick almost exactly on a multiple
        -- of step_beat; dividing and rounding recovers which multiple.
        local step_beat = DIVISIONS[layer.division_idx].beat
        local absolute_step = util.round(clock.get_beats() / step_beat)
        local is_offbeat = (absolute_step % 2) == 1

        -- swing only ever pushes the off-beat half of each pair later;
        -- the on-beat half always fires right on the grid. delay
        -- happens in the spawned coroutine(s) below, not in this loop,
        -- so it can't eat into the next clock.sync and skip a step.
        local onset_delay_beat = 0
        local swing_pct = swing_percent()
        if swing_pct and is_offbeat then
          onset_delay_beat = step_beat * (2 * swing_pct / 100 - 1)
        end

        -- gate length is a % of the step's division length, but this
        -- note's total span (swing delay + gate) is capped just under
        -- one full step interval, so there's always a sliver of
        -- silence before the next step's earliest possible onset --
        -- even at a high gate_length_pct with heavy swing pushing this
        -- note's own onset late. without this, back-to-back same-pitch
        -- notes (ratchets especially) can overlap and get cut short or
        -- retriggered oddly on some synths.
        local MAX_NOTE_SPAN_FRACTION = 0.95
        local gate_beat = math.min(
          step_beat * (gate_length_pct / 100),
          step_beat * MAX_NOTE_SPAN_FRACTION - onset_delay_beat
        )
        gate_beat = math.max(gate_beat, 0)

        local function fire_note(entry, vel, play_note)
          clock.run(function()
            if onset_delay_beat > 0 then
              clock.sleep(clock.get_beat_sec() * onset_delay_beat)
            end
            -- voice_on snapshots layer.out_port and layer.out_channel as
            -- they are right now; the handle it returns is what
            -- voice_off releases against below, even if either changes
            -- during the gate_beat sleep -- see the voice_on/voice_off
            -- comments.
            local handle = voice_on(layer.out_device, layer.out_port, layer.out_channel, play_note, vel)
            clock.sleep(clock.get_beat_sec() * gate_beat)
            voice_off(handle, play_note)
          end)
        end

        if effective_mode == "chord" then
          -- chord mode: every note in the pool is checked and, if
          -- eligible, fired together on this one tick -- there's no
          -- single "landed on" entry the way every other mode has one.
          -- eligibility is the same per-note mute/divisor/invert check
          -- every other mode uses (see step_playable), just applied to
          -- the whole sequence directly instead of through a landing
          -- search -- which is also why "skip" vs "silent" lap_mode
          -- collapse to the same thing here: there's no traversal left
          -- for "skip" to jump a note out of.
          for _, entry in ipairs(layer.sequence) do
            if not layer.muted[entry.id] then
              local vel = effective_velocity(layer, entry)
              if fuzz_mode == "all" then
                vel = fuzz_velocity(vel)
              end
              local divisor = util.clamp(layer.lap_divisor[entry.id] or 1, 1, MAX_LAP_DIVISOR)
              local anchor = layer.lap_anchor[entry.id] or 0
              -- chord mode never calls step_playable (see next_chord_step
              -- and the comment on the chord branch above) -- it checks
              -- every note's eligibility inline, right here, instead of
              -- through a landing search. step_playable is the only other
              -- place lap_stamp gets written, so without this line every
              -- column's stamp would simply freeze the moment you switch
              -- into chord mode, instead of continuing to track the same
              -- raw_lap this check is actually using.
              layer.lap_stamp[entry.id] = layer.raw_lap_count
              local on_lap = ((layer.raw_lap_count - anchor) % divisor == 0)
              local inverted = layer.lap_invert[entry.id] or false
              if divisor > 1 and (on_lap == inverted) then
                vel = 0
              end

              if vel > 0 then
                -- the chord playhead visits every note's column once
                -- per lap regardless of that note's own divisor (see
                -- next_chord_step), so every note's octave just follows
                -- the shared layer.lap directly here -- a private
                -- per-note counter would end up tracking layer.lap 1:1
                -- anyway in chord mode, so there's no separate
                -- note_octave_lap bookkeeping needed the way stepped
                -- modes require it.
                local play_note = entry.base_note + octave_lap_semitones(layer, layer.lap)
                fire_note(entry, vel, play_note)

                -- grid flash for this column, throttled to once-per-pass
                -- (see flash_this_tick above) and timed to match the
                -- note's own audible span (onset_delay_beat + gate_beat,
                -- the same two numbers fire_note's own coroutine sleeps
                -- on above) rather than just staying "on" until whatever
                -- redraw happens to land next -- see chord_flash above.
                if flash_this_tick then
                  layer.chord_flash[entry.id] = true
                  local flash_id = entry.id
                  clock.run(function()
                    local off_beat = onset_delay_beat + gate_beat
                    if off_beat > 0 then
                      clock.sleep(clock.get_beat_sec() * off_beat)
                    end
                    layer.chord_flash[flash_id] = false
                    if view_mode == "main" and layer == active() then
                      redraw_grid()
                    end
                  end)
                end
              end
            end
          end

        else
          local entry = layer.sequence[layer.step]
          local vel = effective_velocity(layer, entry)
          if fuzz_mode == "all" then
            vel = fuzz_velocity(vel)
          end
          -- lap_divisor > 1 in "silent" mode means this note only sounds
          -- on laps that land on a multiple of it (0, divisor, divisor*2,
          -- ...) -- it still occupies its column and takes its turn in the
          -- traversal/ratchet on every lap, same as a muted step does, it
          -- just stays silent on the laps that don't match. "skip" mode
          -- notes never reach here off-lap at all -- step_playable already
          -- kept the traversal from landing on them -- so this is a no-op
          -- for those, landing here only on a lap that's already a match.
          local divisor = util.clamp(layer.lap_divisor[entry.id] or 1, 1, MAX_LAP_DIVISOR)
          local anchor = layer.lap_anchor[entry.id] or 0
          local on_lap = ((layer.raw_lap_count - anchor) % divisor == 0)
          local inverted = layer.lap_invert[entry.id] or false
          if divisor > 1 and (on_lap == inverted) then
            vel = 0
          end

          if vel > 0 then
            -- the octave-lap to play at was already decided once, at the
            -- moment this step landed (see the landing block above) --
            -- every rep of this same landing just reuses that stashed
            -- value here rather than re-deriving (and re-advancing) it
            -- on each individual rep's fire, which would walk a
            -- divisor>1 note's octave up with every ratchet hit instead
            -- of holding it steady for the whole pass.
            local note_lap = (divisor > 1) and (layer.step_note_lap or layer.lap) or layer.lap
            local play_note = entry.base_note + octave_lap_semitones(layer, note_lap)
            fire_note(entry, vel, play_note)
          end
        end
      end
    else
      layer.step = 0
    end

    if view_mode == "main" and layer == active() then
      redraw_grid()
    end
  end
end

-- clock.sync(beat) commits to waiting for the NEXT boundary of whatever
-- beat value was passed in at the moment it was called -- it doesn't
-- notice if layer.division_idx changes while it's still waiting. so
-- without this, switching a layer from a slow division (e.g. 1/1) to a
-- fast one (e.g. 1/32) while a tick is already in flight leaves the arp
-- stuck finishing out that one slow tick before the new, faster rate
-- ever takes effect. restarting the coroutine here throws away that
-- stale wait and re-enters arp_clock's loop immediately, so the very
-- next clock.sync call reads the just-changed division_idx and syncs to
-- the new (short) tick right away instead of the old one.
restart_arp_clock = function(layer)
  if layer.clock_id then clock.cancel(layer.clock_id) end
  layer.clock_id = clock.run(function() arp_clock(layer) end)
end

-- ------------------------------------------------------------------
-- norns ui
-- ------------------------------------------------------------------

local function flip_layer()
  abort_replace(active()) -- changing layer aborts any pending replace
  abort_insert(active())  -- ...and any pending insert
  active_layer = (active_layer == 1) and 2 or 1
  key_state = {} -- drop any in-flight long-press tracking from the old layer
  -- pattern view's slot layout doesn't depend on active_layer, so only the main view needs a repaint here
  if view_mode == "main" then
    redraw_grid()
  end
end

function key(n, z)
  if (n == 2 and k3_down) or (n == 3 and k2_down) then
    -- k2 and k3 gate each other out entirely for as long as either is
    -- held down, so neither momentary-flip gesture below can be
    -- interrupted or double-actioned by the other mid-hold. k1 and the
    -- encoders are untouched by this and stay accessible as normal.
    return
  end

  if n == 1 then
    k1_down = (z == 1)
    -- swap the grid between the arp view and the lap-select view right
    -- away, rather than waiting for the next arp_clock tick or edit to
    -- repaint it
    if view_mode == "main" then
      redraw_grid()
    end
  elseif n == 2 and z == 0 then
    -- release: if this was a plain (no k1) press held past
    -- MOMENTARY_LONG_PRESS_TIME, flip back to the layer this press
    -- started on -- a single press-and-hold-then-release becomes a
    -- momentary peek at the other layer. a quick tap (the pre-existing
    -- behavior) just leaves you on the layer it flipped to.
    k2_down = false
    if k2_momentary_armed and (util.time() - k2_press_time) > MOMENTARY_LONG_PRESS_TIME then
      flip_layer() -- only two layers, so flipping again is always "back"
    end
    k2_momentary_armed = false
  elseif n == 3 and z == 0 then
    -- same idea, mirrored: a plain k3 press held past
    -- MOMENTARY_LONG_PRESS_TIME flips back to the arp view on release --
    -- a momentary peek at the phrase view. a quick tap just leaves you
    -- on the view it switched to, exactly as before.
    k3_down = false
    if k3_momentary_armed and (util.time() - k3_press_time) > MOMENTARY_LONG_PRESS_TIME then
      toggle_view() -- only two view modes, so toggling again is always "back"
    end
    k3_momentary_armed = false
  elseif z == 1 then
    -- any key other than k1 aborts a pending replace/insert gesture --
    -- same reasoning as the encoder guard in enc() below. this covers
    -- k2/k3 alone and k1+k2/k1+k3 alike; flip_layer/toggle_view already
    -- call abort_replace/abort_insert themselves too, so this is
    -- harmlessly redundant for those two paths specifically.
    abort_replace(active())
    abort_insert(active())
    if n == 2 then
      k2_down = true
      if k1_down then
        -- k1+k2 is a different gesture entirely (hold toggle), so the
        -- momentary-flip tracking doesn't arm for this press
        k2_momentary_armed = false
        key_state = {} -- drop any in-flight grid long-press timer: set_hold below
                        -- can rebuild layer.sequence out from under it
        set_hold(active(), not active().hold)
      else
        k2_momentary_armed = true
        k2_press_time = util.time()
        flip_layer()
      end
    elseif n == 3 then
      k3_down = true
      if k1_down then
        -- k1+k3 is a different gesture entirely (sticky toggle), so the
        -- momentary-flip tracking doesn't arm for this press
        k3_momentary_armed = false
        key_state = {} -- drop any in-flight grid long-press timer: flipping
                        -- sticky changes how future rebuilds treat held/latched
        active().sticky = not active().sticky
      else
        k3_momentary_armed = true
        k3_press_time = util.time()
        toggle_view()
      end
    end
  end
  redraw()
end

function enc(n, d)
  local layer = active()
  -- any encoder move aborts a pending replace/insert gesture outright --
  -- those gestures only make sense against a frozen arp layout, so once
  -- something else is being edited the gesture's assumptions are stale
  abort_replace(layer)
  abort_insert(layer)
  if n == 1 then
    if k1_down then
      layer.octave_span = util.clamp(layer.octave_span + d, -1, 3)
      layer.lap = layer.lap % octave_lap_count(layer)
      -- octave range itself just changed -- every divisored note's own
      -- octave counter resyncs back to the shared lap rather than
      -- carrying over a value that may no longer even fit the new span
      layer.note_octave_lap = {}
    else
      local new_division_idx = util.clamp(layer.division_idx + d, 1, #DIVISIONS)
      if new_division_idx ~= layer.division_idx then
        layer.division_idx = new_division_idx
        -- kick the arp coroutine awake now rather than letting it finish
        -- out whatever old, possibly much-longer tick it's already
        -- mid-wait on -- see restart_arp_clock above.
        restart_arp_clock(layer)
      end
    end
    rebuild_sequence(layer)
  elseif n == 2 then
    if k1_down then
      layer.repeats = util.clamp(layer.repeats + d, 1, 4)
    else
      layer.mode_idx = util.clamp(layer.mode_idx + d, 1, #ARP_MODES)
      local new_mode = ARP_MODES[layer.mode_idx]
      if new_mode ~= "thru" and new_mode ~= "off" then
        layer.frozen_mode = new_mode
      end
      rebuild_sequence(layer)
    end
  elseif n == 3 then
    if k1_down then
      -- lap-only mode deliberately doesn't touch layer.rotation at all
      -- (see apply_rotation) -- notes are meant to stay frozen while
      -- only the lap fields migrate. this is what keeps the notes from
      -- jumping when you switch back to note+lap or note only: since
      -- layer.rotation never moved while frozen here, it's already
      -- exactly the value the frozen note arrangement corresponds to,
      -- so nothing needs to be reconciled on the way out. the only
      -- thing that changes on a mode switch is what the *next* turn of
      -- the knob does, not anything about the arrangement already on
      -- the grid.
      if rotation_mode ~= "lap_only" then
        layer.rotation = layer.rotation + d
      else
        layer.lap_rotation = layer.lap_rotation + d
      end
      apply_rotation(layer, d)
    else
      nudge_all_velocities(layer, d)
    end
  end
  redraw()
end

function redraw()
  local layer = active()
  screen.clear()

  local ACTIVE = 15
  local DIM = 4

  -- k1 held: the secondary row lights up and the primary row dims.
  -- not held: primary row is live, secondary row is dim
  local primary_lvl = k1_down and DIM or ACTIVE
  local secondary_lvl = k1_down and ACTIVE or DIM

  local col_x = {8, 48, 88}

  screen.font_size(8)

  -- primary encoder row: division / mode / velocity
  screen.level(primary_lvl)
  screen.move(col_x[1], 14); screen.text(DIVISIONS[layer.division_idx].name)
  screen.move(col_x[2], 14)
  screen.text(ARP_MODES[layer.mode_idx])
  screen.move(col_x[3], 14); screen.text("vel +-")

  -- secondary encoder row: octave laps / repeats / rotation
  screen.level(secondary_lvl)
  local oct_text = (layer.octave_span == 0) and "0" or string.format("%+d", layer.octave_span)
  screen.move(col_x[1], 26); screen.text("oct " .. oct_text)
  screen.move(col_x[2], 26); screen.text("rep " .. layer.repeats)
  screen.move(col_x[3], 26)
  local rot_n = #layer.sequence
  local rot_val = (rotation_mode == "lap_only") and layer.lap_rotation or layer.rotation
  screen.text("rot " .. (rot_n > 0 and (rot_val % rot_n) or 0))

  screen.level(secondary_lvl)
  screen.move(19, 43)
  screen.text("hold " .. (layer.hold and "ON" or "off"))

  -- k1+k3: sticky toggle
  screen.level(secondary_lvl)
  screen.move(62, 43)
  screen.text("sticky " .. (layer.sticky and "ON" or "off"))

  -- arp/phrase view status
  screen.level(ACTIVE)
  screen.move(col_x[2], 59)
  screen.text(view_mode == "pattern" and "phrase" or "arp")

  -- layer indicator A B
  screen.level(ACTIVE)
  screen.font_size(24)
  if active_layer == 1 then
    screen.move(0, 62)
    screen.text(LAYER_NAMES[1])
  else
    screen.move(128, 62)
    screen.text_right(LAYER_NAMES[2])
  end
  screen.font_size(8)

  screen.update()
end

-- ------------------------------------------------------------------
-- grid size detection
-- ------------------------------------------------------------------

-- g.cols/g.rows only reflect the actual connected device once its own
-- handshake with the grid completes -- not guaranteed to have happened
-- yet at the moment grid.connect() first returns -- so GRID_W/GRID_H
-- can't just be read once at file-load time (see the comment by their
-- declaration above). this re-reads them and, if either changed, updates
-- every dependent constant and repaints whatever's on screen. called
-- once from init() and again any time a grid (re)connects, so swapping
-- from a 128 to a 64 (or back) mid-session picks up the new size
-- immediately rather than requiring a script restart.
local function sync_grid_dims()
  local new_w = (g.cols and g.cols > 0) and g.cols or GRID_W
  local new_h = (g.rows and g.rows > 0) and g.rows or GRID_H
  if new_w == GRID_W and new_h == GRID_H then return end

  GRID_W = new_w
  GRID_H = new_h
  MAX_LAP_DIVISOR = GRID_H

  -- a narrower device than before can leave a layer's sequence holding
  -- more steps than it now has columns for -- trim from the right, the
  -- same eviction path a note-insert overflow already uses (see
  -- try_consume_insert above), rather than leaving state around that no
  -- column can reach or display.
  for _, layer in ipairs(layers) do
    while #layer.sequence > GRID_W do
      local overflow = layer.sequence[GRID_W + 1]
      delete_instance(layer, overflow.id)
    end
  end

  if view_mode == "pattern" then
    draw_pattern_grid()
  else
    redraw_grid()
  end
end

-- norns calls this whenever any grid device connects, including at
-- script startup for one already plugged in -- only react if it's the
-- specific device this script is bound to (dev == g), not some other
-- grid the person happens to have attached.
function grid.add(dev)
  if dev == g then
    sync_grid_dims()
  end
end

-- ------------------------------------------------------------------
-- init
-- ------------------------------------------------------------------

function init()
  -- picks up the real device size in case grid.add already fired before
  -- this point (e.g. a device that was already connected at script
  -- start) -- harmless no-op if it hasn't, sync_grid_dims runs again
  -- from grid.add itself once it does.
  sync_grid_dims()

  -- everything from here through collision is one params:add_group of
  -- exactly 9 items -- MIDI in/out device+channel for both layers, plus
  -- collision (grouped here since collision only matters in the
  -- midi-routing scenario where both layers share an output channel --
  -- see the voice_on/voice_off comment above). add_group just reserves
  -- the next n params:add calls into a collapsible submenu (norns docs,
  -- params reference): the group shows as a single "MIDI" row in the
  -- menu, K3 drills into it, K2 backs back out. groups can't nest, and
  -- the count has to stay exactly right or it'll swallow (or leave
  -- stranded) whatever params:add calls follow -- if another
  -- MIDI-related param is ever added, bump this 9, and if anything
  -- unrelated needs to go here, it can't, it'd get pulled into the
  -- group by position whether it belongs or not.
  params:add_group("midi_group", "MIDI", 9)

  -- each layer picks its own input device now, independent of the
  -- other's. see refresh_midi_in_routing for how same-device-for-both
  -- vs different-device-per-layer are reconciled under the hood.
  params:add{type = "number", id = "midi_in_device_a", name = "A in device",
    min = 1, max = 16, default = 2,
    formatter = midi_device_formatter,
    action = function(v)
      -- whatever's still physically held on the device this layer is
      -- about to leave will never send its note-off through this script
      -- again once the handler is detached (if nothing else still wants
      -- that device) -- release it now rather than leaving it stuck.
      -- see release_all_held_notes for why. scoped to just this layer
      -- so layer b's held notes aren't disturbed by an a-only switch.
      release_all_held_notes(layers[1])
      layers[1].in_device = v
      refresh_midi_in_routing()
    end}

  params:add{type = "number", id = "midi_in_device_b", name = "B in device",
    min = 1, max = 16, default = 2,
    formatter = midi_device_formatter,
    action = function(v)
      release_all_held_notes(layers[2])
      layers[2].in_device = v
      refresh_midi_in_routing()
    end}

  -- 0 = omni/all channels, matching the "all" convention used for the
  -- midi in device selectors above. see layers_for_device_channel above
  -- for how in_device and in_channel combine when two layers share a
  -- device vs when they're on separate devices entirely.
  params:add{type = "number", id = "midi_in_channel_a", name = "A in channel",
    min = 0, max = 16, default = 0,
    formatter = function(param) return (param:get() == 0) and "all" or tostring(param:get()) end,
    action = function(v) layers[1].in_channel = v end}

  params:add{type = "number", id = "midi_in_channel_b", name = "B in channel",
    min = 0, max = 16, default = 0,
    formatter = function(param) return (param:get() == 0) and "all" or tostring(param:get()) end,
    action = function(v) layers[2].in_channel = v end}

  -- each layer also picks its own output device now. a held/in-flight
  -- note's voice_on handle already snapshots layer.out_port at the
  -- moment it fires (see the voice_on/voice_off comments), so switching
  -- this mid-note releases correctly against the device it actually
  -- started on rather than wherever this param points by the time it ends.
  params:add{type = "number", id = "midi_out_device_a", name = "A out device",
    min = 1, max = 16, default = 2,
    formatter = midi_device_formatter,
    action = function(v)
      layers[1].out_device = v
      layers[1].out_port = midi.connect(v)
    end}

  params:add{type = "number", id = "midi_out_device_b", name = "B out device",
    min = 1, max = 16, default = 2,
    formatter = midi_device_formatter,
    action = function(v)
      layers[2].out_device = v
      layers[2].out_port = midi.connect(v)
    end}

  params:add{type = "number", id = "midi_out_channel_a", name = "A out channel",
    min = 1, max = 16, default = 2,
    action = function(v) layers[1].out_channel = v end}

  params:add{type = "number", id = "midi_out_channel_b", name = "B out channel",
    min = 1, max = 16, default = 2,
    action = function(v) layers[2].out_channel = v end}

  -- last item in the MIDI group (see add_group("midi_group", "MIDI", 9)
  -- above) -- only matters when both layers share an output channel and
  -- land on the identical note at the identical moment -- see the
  -- voice_on/voice_off comment above for what each option actually does.
  params:add{type = "option", id = "collision", name = "collision",
    options = {"merge", "skip", "none"}, default = 1,
    action = function(v) collision_mode = ({"merge", "skip", "none"})[v] end}

  -- controls whether exiting the script overwrites the default PSET
  -- slot (slot 1, the one that always loads at next launch -- see the
  -- PSET_DEFAULT_SLOT/PSET_LAST_SESSION_SLOT comment above) with the
  -- session you're about to close. on: launch always tracks wherever
  -- you last left off. off: slot 1 stays whatever you last saved
  -- there on purpose (by hand via PARAMETERS > PSET > 01, or from an
  -- earlier autosave-on exit), so launch is a stable, chosen starting
  -- point rather than wherever a given session happened to end up --
  -- your actual last session is never lost either way, since slot 2
  -- gets a full snapshot on every exit regardless (see "load last
  -- session" trigger below). same approach andr-ew's ndls script uses:
  -- https://github.com/andr-ew/ndls
  params:add{type = "option", id = "autosave", name = "autosave",
    options = {"off", "on"}, default = 2,
    action = function(v) autosave_on = (v == 2) end}

  -- shortcut for loading PSET slot 2 ("last session") on demand,
  -- regardless of what the "autosave" param above is currently set to
  -- -- same shortcut ndls offers. pulls in that session's phrases too.
  params:add{type = "trigger", id = "load_last_session", name = "load last session",
    action = function()
      params:read(PSET_LAST_SESSION_SLOT)
      params:bang()
      load_last_session_patterns_from_disk()
      if view_mode == "pattern" then
        draw_pattern_grid()
      end
    end}

  params:add{type = "number", id = "vel_fuzz", name = "grid vel fuzz",
    min = 0, max = 10, default = 0,
    action = function(v) vel_fuzz = v end}

  params:add{type = "option", id = "fuzz_mode", name = "fuzz: press/all",
    options = {"press", "all"}, default = 1,
    action = function(v) fuzz_mode = (v == 1) and "press" or "all" end}

  params:add{type = "number", id = "gate_length", name = "gate length %",
    min = 1, max = 95, default = 50,
    action = function(v) gate_length_pct = v end}

  -- global, affects both layers identically -- see swing_percent/
  -- swing_steps above for why this isn't per-layer
  params:add{type = "number", id = "swing", name = "swing",
    min = 0, max = SWING_MAX_STEPS, default = 0,
    formatter = function(param)
      local steps = param:get()
      if steps == 0 then return "off" end
      return string.format("%.1f%%", SWING_MIN + (steps - 1) * SWING_STEP)
    end,
    action = function(v) swing_steps = v end}

  -- whether a brand-new note claims a starting lap_divisor/lap_mode off
  -- the lap-memory pool -- see the lap_memory_on/sync_lap_columns
  -- comments above.
  --
  -- the OFF -> ON edge specifically is a "save", not a "load": every
  -- note already present on either layer at that exact moment gets
  -- lap_synced stamped true right here. lap_pool itself needs no action
  -- here -- it only ever changes when a note actually departs the
  -- sequence for good (see prune_vel_mute_state), regardless of this
  -- flag, so it's already an accurate record of recently-departed notes
  -- -- but an id that's never been through sync_lap_columns is exactly
  -- what that function treats as "fair game to claim a pool entry", so
  -- without this stamp, an already-playing note that simply never had
  -- its divisor touched would stay claimable forever, and could get
  -- silently, retroactively reassigned the next time anything (a
  -- rotation, an unrelated new note-on) triggers a rebuild after this
  -- toggle flips on. stamping every present note here closes that off
  -- entirely: turning this on can only ever affect notes that arrive
  -- after the toggle, never ones already sounding.
  params:add{type = "option", id = "lap_memory", name = "lap memory",
    options = {"off", "on"}, default = 1,
    action = function(v)
      local turning_on = (v == 2) and not lap_memory_on
      lap_memory_on = (v == 2)
      if turning_on then
        for _, layer in ipairs(layers) do
          for _, entry in ipairs(layer.sequence) do
            layer.lap_synced[entry.id] = true
          end
        end
      end
    end}

  -- what k1+e3 does to the six lap-mechanism fields relative to the
  -- notes -- see the rotation_mode comment up top for what each option
  -- actually does and why none of them need their own persistent offset
  -- counter beyond what's already here.
  params:add{type = "option", id = "rotation_mode", name = "rotation",
    options = {"note+lap", "note only", "lap only"}, default = 1,
    action = function(v)
      rotation_mode = ({"note_lap", "note_only", "lap_only"})[v]
    end}

  -- controls which gesture a quick k1+top-row tap reaches vs a
  -- long-press -- see the k1_priority comment above.
  params:add{type = "option", id = "k1_priority", name = "k1 priority",
    options = {"replace", "insert"}, default = 1,
    action = function(v) k1_priority = (v == 1) and "replace" or "insert" end}

  -- controls whether a pending note-replace gesture silences its anchor
  -- step ("mute", default) or leaves it audible ("none") while it waits
  -- for the next note-on -- see the pending_replace_mode comment above.
  params:add{type = "option", id = "pending_replace", name = "pending replace",
    options = {"mute", "none"}, default = 1,
    action = function(v) pending_replace_mode = (v == 1) and "mute" or "none" end}

  -- controls whether the hold/sticky toggles are live layer-only
  -- settings ("per_layer") or get saved/recalled with each phrase
  -- ("per_phrase") -- see the hold_sticky_mode comment above.
  params:add{type = "option", id = "hold_sticky_mode", name = "hold/sticky",
    options = {"per layer", "per phrase"}, default = 1,
    action = function(v) hold_sticky_mode = (v == 1) and "per_layer" or "per_phrase" end}

  -- destructive and immediate: wipes every saved phrase slot on both
  -- layers, no confirmation, no undo -- see clear_all_patterns above.
  params:add{type = "trigger", id = "clear_all_phrases", name = "clear all phrases",
    action = function() clear_all_patterns() end}

  -- loads dust/data/arpeggii/arpeggii-01.pset (the "default" pset slot,
  -- PSET_DEFAULT_SLOT) if one exists from a previous session --
  -- silently does nothing on a first run, before any pset has ever been
  -- written, same as an unnumbered pset always did. this always runs,
  -- regardless of the "autosave" param -- only cleanup()'s writes are
  -- gated by that, not this read. this covers PARAMS-menu settings
  -- (hold/sticky, lap priority, gate length, swing, midi devices, lap
  -- memory on/off, etc.).
  params:read(PSET_DEFAULT_SLOT)
  params:bang()

  -- params:bang() just applied the "autosave" param's own saved value
  -- (from the pset just read above) to autosave_on, so it's already
  -- accurate here -- no separate flag needed.
  --
  -- saved arp phrases are a separate mechanism from PARAMS -- see
  -- save_patterns_to_disk/load_patterns_from_disk. saving stays
  -- unconditional: every edit still flushes to disk immediately
  -- regardless of this setting (see save_patterns_to_disk's call sites
  -- above), so a crash or power loss mid-session never costs more than
  -- whatever single edit was in flight. this only gates whether that
  -- already-current-on-disk state gets loaded back in at boot. off:
  -- skip the load, both layers start with blank phrase slots even
  -- though the file underneath is fully up to date -- flipping back to
  -- on later picks up everything that was saved while it was off, same
  -- as if it'd been on the whole time.
  if autosave_on then
    load_patterns_from_disk()
  end

  for _, layer in ipairs(layers) do
    layer.clock_id = clock.run(function() arp_clock(layer) end)
  end

  grid_refresh_clock_id = clock.run(grid_refresh_loop)

  redraw_grid()
  redraw()
end

function cleanup()
  -- runs on every exit, including a reboot, before anything below that
  -- could bail out early.
  --
  -- slot 2 ("last session") always gets a full snapshot -- PARAMS plus
  -- phrases -- so "load last session" (the trigger param above, or
  -- PARAMETERS > PSET > 02) can recover exactly where you left off,
  -- whether or not autosave is on.
  params:write(PSET_LAST_SESSION_SLOT, "last session")
  save_last_session_patterns_to_disk()

  -- slot 1 ("default") is what actually loads at next launch (see
  -- params:read(PSET_DEFAULT_SLOT) in init()) -- only overwrite it here
  -- when autosave is on. off leaves it as whatever was last saved there
  -- on purpose, so launch stays a stable, chosen starting point instead
  -- of drifting to wherever this particular session ended up.
  if autosave_on then
    params:write(PSET_DEFAULT_SLOT, "default")
  end

  for _, layer in ipairs(layers) do
    if layer.clock_id then clock.cancel(layer.clock_id) end
    if layer.replace_pulse_clock_id then clock.cancel(layer.replace_pulse_clock_id) end
    if layer.insert_pulse_clock_id then clock.cancel(layer.insert_pulse_clock_id) end
  end
  if grid_refresh_clock_id then clock.cancel(grid_refresh_clock_id) end

  -- belt-and-suspenders sweep so nothing is left stuck sounding once the
  -- script unloads. release_all_held_notes handles anything still
  -- individually tracked -- held keys and off/thru passthrough -- via
  -- each note's own recorded channel/port, but it deliberately leaves
  -- latched/thru-frozen notes alone (they're supposed to keep sounding),
  -- and it can't reach a note that was mid-gate in a ratchet/arp
  -- coroutine when the clock.cancel calls above killed that coroutine
  -- before it sent its own note-off. broadcasting MIDI "all sound off"
  -- (CC 120) and "all notes off" (CC 123) catches that mid-gate case the
  -- blunt way -- every well-behaved synth/receiver honors at least one.
  --
  -- swept across every channel of every connected device, not just
  -- layer.out_channel/out_device: those are live, mutable params that
  -- can change mid-note, exactly the race voice_on/voice_off's own
  -- ch/port/device snapshot exists to survive (see those comments).
  -- reading them live here would reintroduce that race at the one place
  -- meant to be the last-resort catch-all -- it could sweep a channel or
  -- device nothing's stuck on anymore and miss the one that actually is.
  -- sweeping everything sidesteps having to guess, so a channel/device
  -- change mid-note, a stray input (e.g. a controller's own onboard
  -- arpeggiator), or any other path that leaves a voice_on handle
  -- unaccounted for all get caught the same way.
  release_all_held_notes()
  for i = 1, #midi.vports do
    local port = midi.connect(i)
    for ch = 1, 16 do
      port:cc(120, 0, ch)
      port:cc(123, 0, ch)
    end
  end
end
