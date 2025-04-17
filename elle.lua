-- |_ (Elle)
-- by @nzimas
-- Adapted for Global Pitch Shift

engine.name = "Elle"

----------------------------------------------------------------
-- 1) GLOBALS & HELPERS
----------------------------------------------------------------

local ui_mode = "main"      -- "main" or "sample_select"

-- "browse_root" (set via param) determines the root folder; default is _path.audio.
local root_dir = _path.audio
local current_dir = _path.audio

-- In sample-select UI, the left column shows items and the right column shows slot numbers.
local item_list = {}
local item_idx = 1
local slot_idx = 1 -- Target slot for sample loading

-- Ping-pong logic for playhead direction
local pingpong_metros = {nil, nil, nil}
local pingpong_sign = {1, 1, 1}

-- Geometry for main UI squares
local square_size = 30
local square_y = 15
local square_x = {10, 49, 88}

local ui_metro
local random_seek_metros = {nil, nil, nil}

local key1_hold = false -- Not currently used for long press
local key2_hold = false -- Used only for K2 long press detection
local key3_hold = false -- Not used currently

-- Scale & pitch randomization info
local scale_options = {"dorian", "natural minor", "harmonic minor", "melodic minor", "major", "locrian", "phrygian"}
local scales = {
  dorian = {0, 2, 3, 5, 7, 9, 10},
  ["natural minor"] = {0, 2, 3, 5, 7, 8, 10},
  ["harmonic minor"] = {0, 2, 3, 5, 7, 8, 11},
  ["melodic minor"] = {0, 2, 3, 5, 7, 9, 11},
  major = {0, 2, 4, 5, 7, 9, 11},
  locrian = {0, 1, 3, 5, 6, 8, 10},
  phrygian = {0, 1, 3, 5, 7, 8, 10}
}

-- Morph time options
local morph_time_options = {}
for t = 0, 90000, 500 do
  table.insert(morph_time_options, t)
end

-- LFO Configuration
local NUM_SLOTS = 3
local NUM_LFOS_PER_SLOT = 2 -- How many LFOs for each sample slot
local NUM_LFOS_PER_FX = 2   -- How many LFOs for each global FX block

-- Targetable parameter names for Slot LFOs
local slot_lfo_target_param_names = {
  "volume", "pan", "jitter", "size", "density",
  "pitch", "spread", "fade", "seek",
  "filter_cutoff", "filter_q"
}
-- Targetable parameter names for FX LFOs (relative to their FX block)
local delay_lfo_target_param_names = { "time", "feedback", "mix" }
local decimator_lfo_target_param_names = { "rate", "bits", "mul", "add" }
-- NOTE: Global Pitch Shift parameters are NOT currently LFO targets

local lfo_shape_names = {"sine", "tri", "saw", "sqr", "random"}

-- Metronome for LFOs
local lfo_metro = nil
-- Storage for current LFO phases (0-1) and values (-1 to 1)
local slot_lfo_phases = {} -- [slot][lfo] = {phase}
local slot_lfo_values = {} -- [slot][lfo] = value
-- New storage for FX LFOs
local fx_lfo_phases = {
    delay_l = {}, delay_r = {}, decimator_l = {}, decimator_r = {}
} -- [fx_block][lfo] = {phase}
local fx_lfo_values = {
    delay_l = {}, delay_r = {}, decimator_l = {}, decimator_r = {}
} -- [fx_block][lfo] = value

local LFO_METRO_RATE = 1/30 -- Update LFOs 30 times per second

-- Initialize LFO state tables
-- Slots
for s = 1, NUM_SLOTS do
    slot_lfo_phases[s] = {}
    slot_lfo_values[s] = {}
    for l = 1, NUM_LFOS_PER_SLOT do
        slot_lfo_phases[s][l] = {0} -- Store phase in a table for pass-by-reference like behaviour if needed later
        slot_lfo_values[s][l] = 0
    end
end
-- FX Blocks
local fx_blocks = {"delay_l", "delay_r", "decimator_l", "decimator_r"}
for _, block_key in ipairs(fx_blocks) do
    for l = 1, NUM_LFOS_PER_FX do
        fx_lfo_phases[block_key][l] = {0}
        fx_lfo_values[block_key][l] = 0
    end
end


-- Helper Functions
local function file_dir_name(fp)
  local d = string.match(fp, "^(.*)/[^/]*$")
  return d or fp
end

local function file_exists(path)
  if not path or path == "" then return false end
  local f = io.open(path, "rb")
  if f then f:close(); return true end
  return false
end

-- Updated is_dir: if the path ends with a known audio extension, treat it as a file.
local function is_dir(path)
  if not path or path == "" then return false end
  local lower = string.lower(path)
  if string.match(lower, "%.wav$") or
     string.match(lower, "%.aif$") or
     string.match(lower, "%.aiff$") or
     string.match(lower, "%.flac$") then
    return false
  end
  -- Use standard Norns util check - check file exists AND scandir returns a table (not nil/error)
  return util.file_exists(path) and (type(util.scandir(path)) == 'table')
end

-- Triangle wave function (0-1 phase -> -1 to 1 value)
local function tri_wave(phase)
  phase = phase % 1.0 -- Ensure phase is within 0-1
  if phase < 0.25 then
    return phase * 4.0 -- Rising from 0 to 1
  elseif phase < 0.75 then
    return 1.0 - (phase - 0.25) * 4.0 -- Falling from 1 to -1
  else
    return -1.0 + (phase - 0.75) * 4.0 -- Rising from -1 to 0
  end
end

----------------------------------------------------------------
-- 2) UI METRO & UTILS
----------------------------------------------------------------

local function setup_ui_metro()
  ui_metro = metro.init()
  ui_metro.time = 1/15
  ui_metro.event = function() redraw() end
  ui_metro:start()
end

local function smooth_transition(param_name, new_val, duration)
  -- Ensure duration is positive
  if duration <= 0 then
    params:set(param_name, new_val)
    return
  end
  clock.run(function()
    local start_val = params:get(param_name)
    -- Avoid transition if start and end are the same or param not found
    if start_val == nil or start_val == new_val then
        if start_val == nil then print("smooth_transition warning: param not found - " .. param_name) end
        return
    end

    local steps = math.max(1, math.floor(duration * 60)) -- Aim for ~60 steps per second
    local dt = duration / steps
    for i = 1, steps do
      local t = i / steps
      -- Basic linear interpolation
      local interp = start_val + (new_val - start_val) * t
      params:set(param_name, interp) -- Assume param exists if start_val was not nil
      clock.sleep(dt)
    end
    -- Final set to ensure exact value
    params:set(param_name, new_val)
  end)
end

----------------------------------------------------------------
-- 3) DIRECTORY Browse FUNCTIONS
----------------------------------------------------------------

local function list_dir_contents(dir)
  local items = {}
  -- Add '..' navigation option if not in root
  if dir ~= root_dir and dir ~= "/" and dir ~= nil and dir ~= "" then
    local parent_dir = file_dir_name(dir)
    -- Ensure parent isn't below root_dir somehow (basic check)
    if parent_dir and (#parent_dir <= #root_dir or root_dir == _path.audio) and (#parent_dir < #dir or dir=="/") then
         table.insert(items, {type = "up", name = "[..]", path = parent_dir})
    end
  end

  local ok, listing = pcall(util.scandir, dir)
  if not ok or not listing then
    print("Error scanning directory: " .. tostring(dir))
    return {{type = "none", name = "(empty or error)", path = dir}}
  end

  local dirs = {}
  local files = {}

  -- Separate files and directories
  for _, f in ipairs(listing) do
    -- Ignore hidden files/dirs
    if string.sub(f, 1, 1) ~= '.' then
      local p = dir .. "/" .. f
      if file_exists(p) then -- Check existence (scandir might list broken links)
        if is_dir(p) then
          table.insert(dirs, {type = "dir", name = f, path = p})
        else
          local lower = string.lower(f)
          if string.match(lower, "%.wav$") or string.match(lower, "%.aif$") or
                           string.match(lower, "%.aiff$") or string.match(lower, "%.flac$") then
            table.insert(files, {type = "file", name = f, path = p})
          end
        end
      end
    end
  end

  -- Sort directories and files alphabetically (case-insensitive)
  table.sort(dirs, function(a, b) return string.lower(a.name) < string.lower(b.name) end)
  table.sort(files, function(a, b) return string.lower(a.name) < string.lower(b.name) end)

  -- Combine lists: '..' then directories, then files
  for _, d in ipairs(dirs) do table.insert(items, d) end
  for _, f in ipairs(files) do table.insert(items, f) end

  -- Handle empty directory case (only contains '..' or nothing)
  if #items == 0 then
        table.insert(items, {type = "none", name = "(empty)", path = dir})
  elseif #items == 1 and items[1].type == "up" then
        table.insert(items, {type = "none", name = "(empty)", path = dir})
  end

  return items
end


----------------------------------------------------------------
-- 4) PLAYHEAD / PING-PONG LOGIC
----------------------------------------------------------------

local function update_playhead(i)
  local rate_param_id = i.."playhead_rate"
  local dir_param_id = i.."playhead_direction"

  -- Get parameter values, check if they exist (return nil if not found)
  local rate = params:get(rate_param_id)
  local dir = params:get(dir_param_id)

  -- Exit if parameters don't exist (e.g., during script load/init issues)
  if rate == nil then
    -- print("Warning: param " .. rate_param_id .. " not found in update_playhead.")
    return
  end
    if dir == nil then
    -- print("Warning: param " .. dir_param_id .. " not found in update_playhead.")
    return
  end

  -- Stop existing metro for this slot if it exists
  if pingpong_metros[i] then
    pingpong_metros[i]:stop()
    pingpong_metros[i] = nil
  end
  pingpong_sign[i] = 1 -- Reset direction sign

  if dir == 1 then -- Forward (Option index 1)
    engine.speed(i, rate)
  elseif dir == 2 then -- Reverse (Option index 2)
    engine.speed(i, -rate)
  else -- Ping-Pong (Option index 3)
    -- Create and start a new metro for ping-pong
    pingpong_metros[i] = metro.init()
    -- Set a default time; actual time might depend on loop points if implemented
    -- For now, just trigger based on reaching start/end (requires engine feedback or assumptions)
    -- A simple timer-based ping-pong:
    local loop_duration = 5.0 -- Guess: Assume a 5 second loop time for reversal? Needs better logic based on sample length/loop points.
    if rate > 0 then
      pingpong_metros[i].time = loop_duration / rate -- Adjust time based on rate
    else
       pingpong_metros[i].time = 2.0 -- Fallback time if rate is zero
    end

    pingpong_metros[i].event = function()
      pingpong_sign[i] = -pingpong_sign[i] -- Flip direction
      -- Re-get rate in case it changed while metro was running
      local current_rate = params:get(rate_param_id)
      if current_rate ~= nil then -- Check rate still exists
           engine.speed(i, pingpong_sign[i] * current_rate)
      end
      -- Re-calculate metro time if rate changed
      if current_rate ~= nil and current_rate > 0 then
        pingpong_metros[i].time = loop_duration / current_rate
      else
         pingpong_metros[i].time = 2.0 -- Fallback time if rate is zero
      end
    end
    pingpong_metros[i]:start()
    -- Start moving forward initially
    engine.speed(i, rate)
  end
end


----------------------------------------------------------------
-- 5) PITCH RANDOMIZATION (Unchanged - Operates on per-slot pitch param)
----------------------------------------------------------------

local function random_float(mn, mx)
  -- Ensure mn <= mx
  if mn > mx then local temp = mn; mn = mx; mx = temp end
  return mn + math.random()*(mx - mn)
end

local function get_random_pitch(slot)
  local s = tostring(slot)
  -- Check if necessary params exist
  if not params:get("pitch_root") or not params:get(s.."pitch_rng_min") or not params:get(s.."pitch") then
       print("Error: required pitch params not found for slot " .. s)
       return params:get(s.."pitch") or 0 -- Return current pitch or 0 if params missing
  end

  local root_note_idx = params:get("pitch_root") -- 1-based index from notes list

  local scale_name_idx = params:get("pitch_scale")
  local scale_name = scale_options[scale_name_idx]
  local scale_intervals = scales[scale_name]
  if not scale_intervals then return params:get(s.."pitch") end -- Safety check, return current pitch

  -- Get min/max range limits (these are option indices, convert to values)
  local min_option_idx = params:get(s.."pitch_rng_min")
  local max_option_idx = params:get(s.."pitch_rng_max")
  -- Need the definition of pitch_vals from setup_params to convert index back to value
  local pitch_vals_lookup = {}
  for v = -24, 24 do table.insert(pitch_vals_lookup, v) end
  local min_semitone_offset = pitch_vals_lookup[min_option_idx]
  local max_semitone_offset = pitch_vals_lookup[max_option_idx]

  -- Ensure min <= max (should be handled by param actions, but double check)
  if min_semitone_offset == nil or max_semitone_offset == nil then return params:get(s.."pitch") end -- More safety
  if min_semitone_offset > max_semitone_offset then min_semitone_offset = max_semitone_offset end

  local current_pitch_st = params:get(s.."pitch")

  local allowed_offsets = {}
  -- Check scale notes across multiple octaves within the min/max range
  -- Add root offset here to work with scale intervals directly
  local root_offset_st = root_note_idx - 1 -- C=0
  for octave_shift = -24, 24, 12 do
    for _, interval in ipairs(scale_intervals) do
      local semitone_offset = interval + octave_shift + root_offset_st
      if semitone_offset >= min_semitone_offset and semitone_offset <= max_semitone_offset then
        -- Avoid adding duplicates if range spans octaves
        local found = false
        for _, existing in ipairs(allowed_offsets) do
          if existing == semitone_offset then found = true; break end
        end
        if not found then
             table.insert(allowed_offsets, semitone_offset)
        end
      end
    end
  end

  -- Remove current pitch from possibilities if more than one option exists
  if #allowed_offsets > 1 then
    for i = #allowed_offsets, 1, -1 do -- Iterate backwards when removing
      if allowed_offsets[i] == current_pitch_st then
        table.remove(allowed_offsets, i)
        break -- Assume only one instance of current pitch
      end
    end
  end

  -- Choose a random offset from the allowed list
  if #allowed_offsets > 0 then
    local chosen_st = allowed_offsets[math.random(#allowed_offsets)]
    return chosen_st
  else
    -- If no valid options (e.g., range allows only current pitch), return current pitch
    return current_pitch_st
  end
end


----------------------------------------------------------------
-- 6) PARAMETER DEFINITIONS
----------------------------------------------------------------

local function setup_params()
  params:add_file("browse_root", "sample root dir", _path.audio)
  -- Corrected browse_root action
  params:set_action("browse_root", function(selected_path)
    local new_root = _path.audio -- Default fallback
    if selected_path and selected_path ~= "" then
      local potential_root = selected_path
      -- If selection looks like a file, use its directory
      if not is_dir(potential_root) and util.file_exists(potential_root) then
           potential_root = file_dir_name(potential_root)
      end
       -- Check if the potential root is valid
      if util.file_exists(potential_root) and is_dir(potential_root) then
           new_root = potential_root
      else
           print("browse_root selection invalid: '" .. tostring(selected_path) .."', reverting to default.")
           -- Force param back to default if selection invalid
           clock.run(function() clock.sleep(0.1); params:set("browse_root", _path.audio) end)
      end
    end
    -- Update the global root_dir variable
    root_dir = new_root
    print("browse_root action set root_dir to: " .. root_dir)

    -- If the browser is currently open, reset its view to the new root
    if ui_mode == "sample_select" then
       print("Browser open, resetting current_dir to new root.")
       current_dir = root_dir
       item_idx = 1
       refresh_dir_contents()
       redraw()
    end
  end)

  params:add_separator() -- Separator before groups

  -- Function to add LFO params for a slot
  local function add_slot_lfo_params(slot_idx)
    local slot_prefix = slot_idx .. "" -- e.g., "1"
    for lfo_num = 1, NUM_LFOS_PER_SLOT do
        local lfo_id_prefix = slot_prefix .. "lfo" .. lfo_num .. "_" -- e.g., 1lfo1_
        local lfo_name_prefix = " LFO " .. lfo_num .. " " -- e.g., " LFO 1 "

        params:add_separator(lfo_name_prefix .. "Settings")

        -- Target Parameter (Which param within the slot)
        params:add_option(lfo_id_prefix .. "target_param", lfo_name_prefix .. "target", slot_lfo_target_param_names, 1) -- Default "volume"

        -- LFO Rate
        params:add_control(lfo_id_prefix .. "rate", lfo_name_prefix .. "rate", controlspec.new(0.01, 20, "exp", 0.01, 1.0, "Hz"))

        -- LFO Amount/Depth (0 = off, 1 = full range modulation)
        params:add_control(lfo_id_prefix .. "amount", lfo_name_prefix .. "amount", controlspec.new(0.0, 1.0, "lin", 0.01, 0.0, "")) -- Default 0 (LFO off)

        -- LFO Shape
        params:add_option(lfo_id_prefix .. "shape", lfo_name_prefix .. "shape", lfo_shape_names, 1) -- Default 'sine'
    end
  end

  -- Function to add LFO params for an FX block
  local function add_fx_lfo_params(fx_id_prefix, fx_name_prefix, target_param_names)
      -- fx_id_prefix e.g., "delay_l_"
      -- fx_name_prefix e.g., "Delay L "
      -- target_param_names e.g., {"time", "feedback", "mix"}
      for lfo_num = 1, NUM_LFOS_PER_FX do
          local lfo_param_id_prefix = fx_id_prefix .. "lfo" .. lfo_num .. "_" -- e.g., delay_l_lfo1_
          local lfo_param_name_prefix = fx_name_prefix .. "LFO " .. lfo_num .. " " -- e.g., "Delay L LFO 1 "

          params:add_separator(lfo_param_name_prefix .. "Settings")

          -- Target Parameter (Which param within the FX block)
          params:add_option(lfo_param_id_prefix .. "target_param", lfo_param_name_prefix .. "target", target_param_names, 1) -- Default to first param in list

          -- LFO Rate
          params:add_control(lfo_param_id_prefix .. "rate", lfo_param_name_prefix .. "rate", controlspec.new(0.01, 20, "exp", 0.01, 1.0, "Hz"))

          -- LFO Amount/Depth (0 = off, 1 = full range modulation)
          params:add_control(lfo_param_id_prefix .. "amount", lfo_param_name_prefix .. "amount", controlspec.new(0.0, 1.0, "lin", 0.01, 0.0, "")) -- Default 0 (LFO off)

          -- LFO Shape
          params:add_option(lfo_param_id_prefix .. "shape", lfo_param_name_prefix .. "shape", lfo_shape_names, 1) -- Default 'sine'
      end
  end

  -- Calculate params per slot LFO group
  local params_per_lfo = 5 -- separator, target, rate, amount, shape
  local slot_lfo_group_size = NUM_LFOS_PER_SLOT * params_per_lfo
  local fx_lfo_group_size = NUM_LFOS_PER_FX * params_per_lfo


  -- ======================== SLOT 1 PARAMETERS ========================
  -- NOTE: The original script had 21 base params BEFORE LFOs, but the per-voice pitch shift params
  -- were not included in the lua script. So the count remains 21 + LFOs.
  local base_slot1_param_count = 21
  local slot1_param_count = base_slot1_param_count + slot_lfo_group_size
  params:add_group("slot1", "Slot 1 Settings", slot1_param_count)
  do -- Use a block to scope local i = 1
    local i = 1
    local sid = i.."" -- String version of slot index for IDs

    params:add_file(sid.."sample", "sample")
    params:set_action(sid.."sample", function(f) engine.read(i, f) end)

    params:add_control(sid.."playhead_rate", "playhead rate",
      controlspec.new(0, 4, "lin", 0.01, 1.0, "", 0.01/4))
    params:set_action(sid.."playhead_rate", function() update_playhead(i) end)

    params:add_option(sid.."playhead_direction", "direction", {">>", "<<", "<->"}, 1)
    params:set_action(sid.."playhead_direction", function() update_playhead(i) end)

    params:add_taper(sid.."volume", "volume", -60, 20, 0, 0, "dB")
    params:set_action(sid.."volume", function(v) engine.volume(i, util.dbamp(v)) end)

    params:add_control(sid.."pan", "pan", controlspec.new(-1.0, 1.0, "lin", 0.01, 0.0, "", 0.01))
    params:set_action(sid.."pan", function(v) engine.pan(i, v) end)

    params:add_taper(sid.."jitter", "jitter", 0, 2000, 0, 5, "ms")
    params:set_action(sid.."jitter", function(v) engine.jitter(i, v/1000) end)

    params:add_taper(sid.."size", "size", 1, 500, 100, 5, "ms")
    params:set_action(sid.."size", function(v) engine.size(i, v/1000) end)

    params:add_taper(sid.."density", "density", 0, 512, 20, 6, "hz")
    params:set_action(sid.."density", function(v) engine.density(i, v) end)

    params:add_taper(sid.."pitch", "pitch", -48, 48, 0, 0, "st")
    params:set_action(sid.."pitch", function(v) engine.pitch(i, math.pow(2, v/12)) end)

    params:add_taper(sid.."spread", "spread", 0, 100, 0, 0, "%")
    params:set_action(sid.."spread", function(v) engine.spread(i, v/100) end)

    params:add_taper(sid.."fade", "fade", 1, 9000, 1000, 3, "ms")
    params:set_action(sid.."fade", function(v) engine.envscale(i, v/1000) end)

    params:add_control(sid.."seek", "seek",
      controlspec.new(0, 100, "lin", 0.1, 0, "%", 0.1/100)) -- Default 0 for slot 1
    params:set_action(sid.."seek", function(v) engine.seek(i, v/100) end)

    params:add_option(sid.."random_seek", "random seek", {"off", "on"}, 1)
    params:add_control(sid.."random_seek_freq_min", "rseek freq min",
      controlspec.new(100, 30000, "lin", 100, 500, "ms"))
    params:add_control(sid.."random_seek_freq_max", "rseek freq max",
      controlspec.new(100, 30000, "lin", 100, 2000, "ms"))
    -- Actions to ensure min <= max
    params:set_action(sid.."random_seek_freq_min", function(val)
      local mx = params:get(sid.."random_seek_freq_max")
      if mx ~= nil and val > mx then params:set(sid.."random_seek_freq_min", mx) end
    end)
    params:set_action(sid.."random_seek_freq_max", function(val)
      local mn = params:get(sid.."random_seek_freq_min")
      if mn ~= nil and val < mn then params:set(sid.."random_seek_freq_max", mn) end
    end)
    -- Action for random_seek toggle
    params:set_action(sid.."random_seek", function(val)
      if val == 2 then -- "on"
        if not random_seek_metros[i] then
          random_seek_metros[i] = metro.init()
          random_seek_metros[i].event = function()
            -- Check param exists before setting (safety)
            if params:get(sid.."seek") ~= nil then
              params:set(sid.."seek", math.random() * 100)
            end
            local tmin = params:get(sid.."random_seek_freq_min")
            local tmax = params:get(sid.."random_seek_freq_max")
            if tmin ~= nil and tmax ~= nil then
                 local nxt = math.random(tmin, tmax)
                 random_seek_metros[i].time = nxt / 1000
            end
          end
        end
        local tmin_init = params:get(sid.."random_seek_freq_min")
        local tmax_init = params:get(sid.."random_seek_freq_max")
        if tmin_init ~= nil and tmax_init ~= nil then
           random_seek_metros[i].time = math.random(tmin_init, tmax_init) / 1000
           random_seek_metros[i]:start()
        end
      else -- "off"
        if random_seek_metros[i] then
          random_seek_metros[i]:stop()
        end
      end
    end)

    params:add_option(sid.."pitch_change", "pitch change?", {"no", "yes"}, 2)
    local pitch_vals = {} for v = -24, 24 do table.insert(pitch_vals, v) end
    local pitch_strs = {} for _, v in ipairs(pitch_vals) do table.insert(pitch_strs, tostring(v)) end
    params:add_option(sid.."pitch_rng_min", "pitch rng min", pitch_strs, 25) -- 0 st (index 25)
    params:add_option(sid.."pitch_rng_max", "pitch rng max", pitch_strs, 25) -- 0 st (index 25)
    -- Actions to ensure min <= max for range options
    params:set_action(sid.."pitch_rng_min", function(idx)
      local mn_idx = idx
      local mx_idx = params:get(sid.."pitch_rng_max")
      if mx_idx ~= nil and mn_idx > mx_idx then params:set(sid.."pitch_rng_min", mx_idx) end
    end)
    params:set_action(sid.."pitch_rng_max", function(idx)
       local mn_idx = params:get(sid.."pitch_rng_min")
       local mx_idx = idx
       if mn_idx ~= nil and mx_idx < mn_idx then params:set(sid.."pitch_rng_max", mn_idx) end
    end)

    params:add_option(sid.."filter_change", "random filter?", {"no", "yes"}, 1)
    params:add_taper(sid.."filter_cutoff", "filter cutoff", 20, 20000, 8000, 0, "Hz")
    params:set_action(sid.."filter_cutoff", function(v) engine.filterCutoff(i, v) end)
    params:add_taper(sid.."filter_q", "filter Q", 0.1, 4.0, 0.5, 0, "")
    params:set_action(sid.."filter_q", function(v) engine.filterRQ(i, v) end)

    -- Add Slot 1 LFOs
    add_slot_lfo_params(i)

  end -- End of Slot 1 block

  -- ======================== SLOT 2 PARAMETERS ========================
  local base_slot2_param_count = 21
  local slot2_param_count = base_slot2_param_count + slot_lfo_group_size
  params:add_group("slot2", "Slot 2 Settings", slot2_param_count)
  do -- Use a block to scope local i = 2
    local i = 2
    local sid = i..""

    params:add_file(sid.."sample", "sample")
    params:set_action(sid.."sample", function(f) engine.read(i, f) end)
    params:add_control(sid.."playhead_rate", "playhead rate", controlspec.new(0, 4, "lin", 0.01, 1.0, "", 0.01/4))
    params:set_action(sid.."playhead_rate", function() update_playhead(i) end)
    params:add_option(sid.."playhead_direction", "direction", {">>", "<<", "<->"}, 1)
    params:set_action(sid.."playhead_direction", function() update_playhead(i) end)
    params:add_taper(sid.."volume", "volume", -60, 20, -60, 0, "dB") -- Default -60
    params:set_action(sid.."volume", function(v) engine.volume(i, util.dbamp(v)) end)
    params:add_control(sid.."pan", "pan", controlspec.new(-1.0, 1.0, "lin", 0.01, 0.0, "", 0.01))
    params:set_action(sid.."pan", function(v) engine.pan(i, v) end)
    params:add_taper(sid.."jitter", "jitter", 0, 2000, 0, 5, "ms")
    params:set_action(sid.."jitter", function(v) engine.jitter(i, v/1000) end)
    params:add_taper(sid.."size", "size", 1, 500, 100, 5, "ms")
    params:set_action(sid.."size", function(v) engine.size(i, v/1000) end)
    params:add_taper(sid.."density", "density", 0, 512, 20, 6, "hz")
    params:set_action(sid.."density", function(v) engine.density(i, v) end)
    params:add_taper(sid.."pitch", "pitch", -48, 48, 0, 0, "st")
    params:set_action(sid.."pitch", function(v) engine.pitch(i, math.pow(2, v/12)) end)
    params:add_taper(sid.."spread", "spread", 0, 100, 0, 0, "%")
    params:set_action(sid.."spread", function(v) engine.spread(i, v/100) end)
    params:add_taper(sid.."fade", "fade", 1, 9000, 1000, 3, "ms")
    params:set_action(sid.."fade", function(v) engine.envscale(i, v/1000) end)
    params:add_control(sid.."seek", "seek", controlspec.new(0, 100, "lin", 0.1, 0, "%", 0.1/100)) -- Default 0
    params:set_action(sid.."seek", function(v) engine.seek(i, v/100) end)
    params:add_option(sid.."random_seek", "random seek", {"off", "on"}, 1)
    params:add_control(sid.."random_seek_freq_min", "rseek freq min", controlspec.new(100, 30000, "lin", 100, 500, "ms"))
    params:add_control(sid.."random_seek_freq_max", "rseek freq max", controlspec.new(100, 30000, "lin", 100, 2000, "ms"))
    params:set_action(sid.."random_seek_freq_min", function(val) local mx = params:get(sid.."random_seek_freq_max"); if mx ~= nil and val > mx then params:set(sid.."random_seek_freq_min", mx) end end)
    params:set_action(sid.."random_seek_freq_max", function(val) local mn = params:get(sid.."random_seek_freq_min"); if mn ~= nil and val < mn then params:set(sid.."random_seek_freq_max", mn) end end)
    params:set_action(sid.."random_seek", function(val) if val == 2 then if not random_seek_metros[i] then random_seek_metros[i] = metro.init(); random_seek_metros[i].event = function() if params:get(sid.."seek") ~= nil then params:set(sid.."seek", math.random() * 100) end; local tmin = params:get(sid.."random_seek_freq_min"); local tmax = params:get(sid.."random_seek_freq_max"); if tmin ~= nil and tmax ~= nil then local nxt = math.random(tmin, tmax); random_seek_metros[i].time = nxt / 1000; end end end; local tmin_init = params:get(sid.."random_seek_freq_min"); local tmax_init = params:get(sid.."random_seek_freq_max"); if tmin_init ~= nil and tmax_init ~= nil then random_seek_metros[i].time = math.random(tmin_init, tmax_init) / 1000; random_seek_metros[i]:start() end; else if random_seek_metros[i] then random_seek_metros[i]:stop() end end end)
    params:add_option(sid.."pitch_change", "pitch change?", {"no", "yes"}, 2)
    local pitch_vals = {} for v = -24, 24 do table.insert(pitch_vals, v) end
    local pitch_strs = {} for _, v in ipairs(pitch_vals) do table.insert(pitch_strs, tostring(v)) end
    params:add_option(sid.."pitch_rng_min", "pitch rng min", pitch_strs, 25)
    params:add_option(sid.."pitch_rng_max", "pitch rng max", pitch_strs, 25)
    params:set_action(sid.."pitch_rng_min", function(idx) local mn_idx = idx; local mx_idx = params:get(sid.."pitch_rng_max"); if mx_idx ~= nil and mn_idx > mx_idx then params:set(sid.."pitch_rng_min", mx_idx) end end)
    params:set_action(sid.."pitch_rng_max", function(idx) local mn_idx = params:get(sid.."pitch_rng_min"); local mx_idx = idx; if mn_idx ~= nil and mx_idx < mn_idx then params:set(sid.."pitch_rng_max", mn_idx) end end)
    params:add_option(sid.."filter_change", "random filter?", {"no", "yes"}, 1)
    params:add_taper(sid.."filter_cutoff", "filter cutoff", 20, 20000, 8000, 0, "Hz")
    params:set_action(sid.."filter_cutoff", function(v) engine.filterCutoff(i, v) end)
    params:add_taper(sid.."filter_q", "filter Q", 0.1, 4.0, 0.5, 0, "")
    params:set_action(sid.."filter_q", function(v) engine.filterRQ(i, v) end)

    -- Add Slot 2 LFOs
    add_slot_lfo_params(i)

  end -- End of Slot 2 block


  -- ======================== SLOT 3 PARAMETERS ========================
  local base_slot3_param_count = 21
  local slot3_param_count = base_slot3_param_count + slot_lfo_group_size
  params:add_group("slot3", "Slot 3 Settings", slot3_param_count)
  do -- Use a block to scope local i = 3
    local i = 3
    local sid = i..""

    params:add_file(sid.."sample", "sample")
    params:set_action(sid.."sample", function(f) engine.read(i, f) end)
    params:add_control(sid.."playhead_rate", "playhead rate", controlspec.new(0, 4, "lin", 0.01, 1.0, "", 0.01/4))
    params:set_action(sid.."playhead_rate", function() update_playhead(i) end)
    params:add_option(sid.."playhead_direction", "direction", {">>", "<<", "<->"}, 1)
    params:set_action(sid.."playhead_direction", function() update_playhead(i) end)
    params:add_taper(sid.."volume", "volume", -60, 20, -60, 0, "dB") -- Default -60
    params:set_action(sid.."volume", function(v) engine.volume(i, util.dbamp(v)) end)
    params:add_control(sid.."pan", "pan", controlspec.new(-1.0, 1.0, "lin", 0.01, 0.0, "", 0.01))
    params:set_action(sid.."pan", function(v) engine.pan(i, v) end)
    params:add_taper(sid.."jitter", "jitter", 0, 2000, 0, 5, "ms")
    params:set_action(sid.."jitter", function(v) engine.jitter(i, v/1000) end)
    params:add_taper(sid.."size", "size", 1, 500, 100, 5, "ms")
    params:set_action(sid.."size", function(v) engine.size(i, v/1000) end)
    params:add_taper(sid.."density", "density", 0, 512, 20, 6, "hz")
    params:set_action(sid.."density", function(v) engine.density(i, v) end)
    params:add_taper(sid.."pitch", "pitch", -48, 48, 0, 0, "st")
    params:set_action(sid.."pitch", function(v) engine.pitch(i, math.pow(2, v/12)) end)
    params:add_taper(sid.."spread", "spread", 0, 100, 0, 0, "%")
    params:set_action(sid.."spread", function(v) engine.spread(i, v/100) end)
    params:add_taper(sid.."fade", "fade", 1, 9000, 1000, 3, "ms")
    params:set_action(sid.."fade", function(v) engine.envscale(i, v/1000) end)
    params:add_control(sid.."seek", "seek", controlspec.new(0, 100, "lin", 0.1, 100, "%", 0.1/100)) -- Default 100 for slot 3
    params:set_action(sid.."seek", function(v) engine.seek(i, v/100) end)
    params:add_option(sid.."random_seek", "random seek", {"off", "on"}, 1)
    params:add_control(sid.."random_seek_freq_min", "rseek freq min", controlspec.new(100, 30000, "lin", 100, 500, "ms"))
    params:add_control(sid.."random_seek_freq_max", "rseek freq max", controlspec.new(100, 30000, "lin", 100, 2000, "ms"))
    params:set_action(sid.."random_seek_freq_min", function(val) local mx = params:get(sid.."random_seek_freq_max"); if mx ~= nil and val > mx then params:set(sid.."random_seek_freq_min", mx) end end)
    params:set_action(sid.."random_seek_freq_max", function(val) local mn = params:get(sid.."random_seek_freq_min"); if mn ~= nil and val < mn then params:set(sid.."random_seek_freq_max", mn) end end)
    params:set_action(sid.."random_seek", function(val) if val == 2 then if not random_seek_metros[i] then random_seek_metros[i] = metro.init(); random_seek_metros[i].event = function() if params:get(sid.."seek") ~= nil then params:set(sid.."seek", math.random() * 100) end; local tmin = params:get(sid.."random_seek_freq_min"); local tmax = params:get(sid.."random_seek_freq_max"); if tmin ~= nil and tmax ~= nil then local nxt = math.random(tmin, tmax); random_seek_metros[i].time = nxt / 1000; end end end; local tmin_init = params:get(sid.."random_seek_freq_min"); local tmax_init = params:get(sid.."random_seek_freq_max"); if tmin_init ~= nil and tmax_init ~= nil then random_seek_metros[i].time = math.random(tmin_init, tmax_init) / 1000; random_seek_metros[i]:start() end; else if random_seek_metros[i] then random_seek_metros[i]:stop() end end end)
    params:add_option(sid.."pitch_change", "pitch change?", {"no", "yes"}, 2)
    local pitch_vals = {} for v = -24, 24 do table.insert(pitch_vals, v) end
    local pitch_strs = {} for _, v in ipairs(pitch_vals) do table.insert(pitch_strs, tostring(v)) end
    params:add_option(sid.."pitch_rng_min", "pitch rng min", pitch_strs, 25)
    params:add_option(sid.."pitch_rng_max", "pitch rng max", pitch_strs, 25)
    params:set_action(sid.."pitch_rng_min", function(idx) local mn_idx = idx; local mx_idx = params:get(sid.."pitch_rng_max"); if mx_idx ~= nil and mn_idx > mx_idx then params:set(sid.."pitch_rng_min", mx_idx) end end)
    params:set_action(sid.."pitch_rng_max", function(idx) local mn_idx = params:get(sid.."pitch_rng_min"); local mx_idx = idx; if mn_idx ~= nil and mx_idx < mn_idx then params:set(sid.."pitch_rng_max", mn_idx) end end)
    params:add_option(sid.."filter_change", "random filter?", {"no", "yes"}, 1)
    params:add_taper(sid.."filter_cutoff", "filter cutoff", 20, 20000, 8000, 0, "Hz")
    params:set_action(sid.."filter_cutoff", function(v) engine.filterCutoff(i, v) end)
    params:add_taper(sid.."filter_q", "filter Q", 0.1, 4.0, 0.5, 0, "")
    params:set_action(sid.."filter_q", function(v) engine.filterRQ(i, v) end)

    -- Add Slot 3 LFOs
    add_slot_lfo_params(i)

  end -- End of Slot 3 block

  -- ======================== GLOBAL PARAMETERS ========================
  params:add_separator("Global Settings")

  params:add_separator("key & scale")
  local notes = {"C", "C#/Db", "D", "D#/Eb", "E", "F", "F#/Gb", "G", "G#/Ab", "A", "A#/Bb", "B"}
  params:add_option("pitch_root", "root note", notes, 1)
  params:add_option("pitch_scale", "scale", scale_options, 1)

  params:add_separator("morphing")
  params:add_option("morph_time", "morph time (ms)", morph_time_options, 1) -- index 1 is 0ms


  -- ======================== GLOBAL FX PARAMETERS ========================
  -- FX groups now include their own LFOs

  -- DELAY LEFT
  local base_delay_l_count = 3 -- time, feedback, mix
  local delay_l_count = base_delay_l_count + fx_lfo_group_size
  params:add_group("delay_l", "Delay L Settings", delay_l_count)
  do
      local prefix = "delay_l_"
      local name_prefix = "L Delay "
      params:add_taper(prefix .. "time", name_prefix .. "time", 0.0, 2.0, 0.5, 0, "s")
      params:set_action(prefix .. "time", function(v) engine.delay_time_l(v) end)
      params:add_taper(prefix .. "feedback", name_prefix .. "feedback", 0, 1, 0.5, 0, "")
      params:set_action(prefix .. "feedback", function(v) engine.delay_feedback_l(v) end)
      params:add_taper(prefix .. "mix", name_prefix .. "mix", 0, 1, 0.5, 0, "")
      params:set_action(prefix .. "mix", function(v) engine.delay_mix_l(v) end)
      -- Add Delay L LFOs
      add_fx_lfo_params(prefix, name_prefix, delay_lfo_target_param_names)
  end

  -- DECIMATOR LEFT
  local base_decimator_l_count = 4 -- rate, bits, mul, add
  local decimator_l_count = base_decimator_l_count + fx_lfo_group_size
  params:add_group("decimator_l", "Decimator L Settings", decimator_l_count)
  do
      local prefix = "decimator_l_"
      local name_prefix = "L Decimator "
      params:add_taper(prefix .. "rate", name_prefix .. "rate", 100, 96000, 48000, 0, "Hz")
      params:set_action(prefix .. "rate", function(v) engine.decimator_rate_l(v) end)
      params:add_taper(prefix .. "bits", name_prefix .. "bits", 1, 32, 32, 0, "")
      params:set_action(prefix .. "bits", function(v) engine.decimator_bits_l(v) end)
      params:add_control(prefix .. "mul", name_prefix .. "mul", controlspec.new(0, 10, "lin", 0, 1.0, ""))
      params:set_action(prefix .. "mul", function(v) engine.decimator_mul_l(v) end)
      params:add_control(prefix .. "add", name_prefix .. "add", controlspec.new(-10, 10, "lin", 0, 0, ""))
      params:set_action(prefix .. "add", function(v) engine.decimator_add_l(v) end)
      -- Add Decimator L LFOs
      add_fx_lfo_params(prefix, name_prefix, decimator_lfo_target_param_names)
  end

  -- DELAY RIGHT
  local base_delay_r_count = 3 -- time, feedback, mix
  local delay_r_count = base_delay_r_count + fx_lfo_group_size
  params:add_group("delay_r", "Delay R Settings", delay_r_count)
  do
      local prefix = "delay_r_"
      local name_prefix = "R Delay "
      params:add_taper(prefix .. "time", name_prefix .. "time", 0.0, 2.0, 0.5, 0, "s")
      params:set_action(prefix .. "time", function(v) engine.delay_time_r(v) end)
      params:add_taper(prefix .. "feedback", name_prefix .. "feedback", 0, 1, 0.5, 0, "")
      params:set_action(prefix .. "feedback", function(v) engine.delay_feedback_r(v) end)
      params:add_taper(prefix .. "mix", name_prefix .. "mix", 0, 1, 0.5, 0, "")
      params:set_action(prefix .. "mix", function(v) engine.delay_mix_r(v) end)
      -- Add Delay R LFOs
      add_fx_lfo_params(prefix, name_prefix, delay_lfo_target_param_names)
  end

  -- DECIMATOR RIGHT
  local base_decimator_r_count = 4 -- rate, bits, mul, add
  local decimator_r_count = base_decimator_r_count + fx_lfo_group_size
  params:add_group("decimator_r", "Decimator R Settings", decimator_r_count)
  do
      local prefix = "decimator_r_"
      local name_prefix = "R Decimator "
      params:add_taper(prefix .. "rate", name_prefix .. "rate", 100, 96000, 48000, 0, "Hz")
      params:set_action(prefix .. "rate", function(v) engine.decimator_rate_r(v) end)
      params:add_taper(prefix .. "bits", name_prefix .. "bits", 1, 32, 32, 0, "")
      params:set_action(prefix .. "bits", function(v) engine.decimator_bits_r(v) end)
      params:add_control(prefix .. "mul", name_prefix .. "mul", controlspec.new(0, 10, "lin", 0, 1.0, ""))
      params:set_action(prefix .. "mul", function(v) engine.decimator_mul_r(v) end)
      params:add_control(prefix .. "add", name_prefix .. "add", controlspec.new(-10, 10, "lin", 0, 0, ""))
      params:set_action(prefix .. "add", function(v) engine.decimator_add_r(v) end)
      -- Add Decimator R LFOs
      add_fx_lfo_params(prefix, name_prefix, decimator_lfo_target_param_names)
  end

  -- ======================== NEW GLOBAL PITCH SHIFT PARAMETERS ========================
  local global_ps_count = 6 -- Six parameters for the global pitch shifter
  params:add_group("global_pitch_shift", "Global Pitch Shift", global_ps_count)
  do
    local prefix = "global_ps_"
    local name_prefix = "Global PS "

    params:add_taper(prefix .. "windowSize", name_prefix .. "Window", 0.01, 1.0, 0.1, 0, "s")
    params:set_action(prefix .. "windowSize", function(v) engine.global_ps_windowSize(v) end)

    params:add_control(prefix .. "pitchRatio", name_prefix .. "Ratio", controlspec.new(0.25, 1.0, "exp", 0.01, 1.0, "ratio"))
    params:set_action(prefix .. "pitchRatio", function(v) engine.global_ps_pitchRatio(v) end)

    params:add_control(prefix .. "pitchDispersion", name_prefix .. "Pitch Disp.", controlspec.new(0.0, 1.0, "lin", 0.01, 0.0, ""))
    params:set_action(prefix .. "pitchDispersion", function(v) engine.global_ps_pitchDispersion(v) end)

    params:add_control(prefix .. "timeDispersion", name_prefix .. "Time Disp.", controlspec.new(0.0, 0.2, "lin", 0.001, 0.0, "s")) -- Max 200ms dispersion
    params:set_action(prefix .. "timeDispersion", function(v) engine.global_ps_timeDispersion(v) end)

    params:add_control(prefix .. "mul", name_prefix .. "Mul", controlspec.new(0.0, 4.0, "lin", 0.01, 1.0, ""))
    params:set_action(prefix .. "mul", function(v) engine.global_ps_mul(v) end)

    params:add_control(prefix .. "add", name_prefix .. "Add", controlspec.new(-1.0, 1.0, "lin", 0.01, 0.0, ""))
    params:set_action(prefix .. "add", function(v) engine.global_ps_add(v) end)
  end

  -- ======================== RANDOMIZER PARAMETERS ========================
  params:add_separator("Randomizer Settings") -- Separator for clarity
  local randomizer_param_count = 17 -- Old count, including legacy pitch
  params:add_group("randomizer", "Randomizer Controls", randomizer_param_count)

  params:add_taper("min_jitter", "jitter (min)", 0, 2000, 0, 5, "ms")
  params:add_taper("max_jitter", "jitter (max)", 0, 2000, 500, 5, "ms")
  params:add_taper("min_size", "size (min)", 1, 500, 1, 5, "ms")
  params:add_taper("max_size", "size (max)", 1, 500, 500, 5, "ms")
  params:add_taper("min_density", "density (min)", 0, 512, 0, 6, "hz")
  params:add_taper("max_density", "density (max)", 0, 512, 40, 6, "hz")
  params:add_taper("min_spread", "spread (min)", 0, 100, 0, 0, "%")
  params:add_taper("max_spread", "spread (max)", 0, 100, 100, 0, "%")
  params:add_taper("min_filter_cutoff", "filter cutoff (min)", 20, 20000, 500, 0, "Hz")
  params:add_taper("max_filter_cutoff", "filter cutoff (max)", 20, 20000, 8000, 0, "Hz")
  params:add_taper("min_filter_q", "filter Q (min)", 0.1, 4.0, 0.25, 0, "")
  params:add_taper("max_filter_q", "filter Q (max)", 0.1, 4.0, 1.2, 0, "")

  -- Legacy pitch params (unused by randomize function, kept for compatibility if needed)
  params:add_taper("pitch_1", "pitch (1)", -48, 48, -12, 0, "st")
  params:add_taper("pitch_2", "pitch (2)", -48, 48, -5, 0, "st")
  params:add_taper("pitch_3", "pitch (3)", -48, 48, 0, 0, "st")
  params:add_taper("pitch_4", "pitch (4)", -48, 48, 7, 0, "st")
  params:add_taper("pitch_5", "pitch (5)", -48, 48, 12, 0, "st")

  params:bang() -- Trigger initial actions for all params based on loaded/default values
end


----------------------------------------------------------------
-- 7) RANDOMIZE LOGIC (Unchanged)
----------------------------------------------------------------

local function randomize(slot)
  -- Check if necessary params exist before proceeding
  if not params:get("morph_time") or
     not params:get("min_jitter") or not params:get("max_jitter") or
     not params:get(slot.."jitter") or not params:get(slot.."seek") or not params:get(slot.."pan") then
     print("Error: Cannot randomize slot " .. slot .. " - required params missing.")
     return
  end

  local morph_time_idx = params:get("morph_time")
  local morph_ms = morph_time_options[morph_time_idx] or 0 -- Default 0 if not found
  local morph_duration = morph_ms / 1000
  local s = tostring(slot) -- Param ID prefix

  -- Randomize grain parameters
  local new_jitter = random_float(params:get("min_jitter"), params:get("max_jitter"))
  local new_size = random_float(params:get("min_size"), params:get("max_size"))
  local new_density = random_float(params:get("min_density"), params:get("max_density"))
  local new_spread = random_float(params:get("min_spread"), params:get("max_spread"))

  smooth_transition(s.."jitter", new_jitter, morph_duration)
  smooth_transition(s.."size", new_size, morph_duration)
  smooth_transition(s.."density", new_density, morph_duration)
  smooth_transition(s.."spread", new_spread, morph_duration)

  -- Randomize pitch if enabled (using the slot's pitch quantization settings)
  if params:get(s.."pitch_change") == 2 then -- "yes"
    local new_pitch = get_random_pitch(slot)
    smooth_transition(s.."pitch", new_pitch, morph_duration)
  end

  -- Randomize filter if enabled
  if params:get(s.."filter_change") == 2 then -- "yes"
    local new_cutoff = random_float(params:get("min_filter_cutoff"), params:get("max_filter_cutoff"))
    local new_q = random_float(params:get("min_filter_q"), params:get("max_filter_q"))
    smooth_transition(s.."filter_cutoff", new_cutoff, morph_duration)
    smooth_transition(s.."filter_q", new_q, morph_duration)
  end

  -- Randomize seek position
  local new_seek = math.random() * 100 -- Random value between 0 and 100
  smooth_transition(s.."seek", new_seek, morph_duration)

  -- Randomize pan position
  local new_pan = random_float(-1.0, 1.0)
  smooth_transition(s.."pan", new_pan, morph_duration)
end

----------------------------------------------------------------
-- 8) INIT / ENGINE (Unchanged logic, relies on params:bang())
----------------------------------------------------------------

local function setup_engine()
  -- This function now primarily ensures gates are open and
  -- relies on params:bang() in setup_params() to set initial engine values
  -- based on saved PSET or defaults.

  engine.gate(1, 1)
  engine.gate(2, 1)
  engine.gate(3, 1)

  -- Set initial playhead speeds based on potentially loaded param values
  -- update_playhead is called by the param action triggered by params:bang()
  -- Also ensure random seek metros are correctly started if loaded from PSET
  clock.run(function()
      clock.sleep(0.1) -- Small delay allows params system to settle
      for i = 1, 3 do
        -- Call update_playhead explicitly to be sure it runs after init
        update_playhead(i)
        -- Check random seek status
        if params:get(i.."random_seek") == 2 then -- If "on"
          -- Trigger the action again to start the metro if needed
          params:set(i.."random_seek", 1) -- Temporarily set to off
          params:set(i.."random_seek", 2) -- Set back to on to trigger action
        end
      end
  end)
end

----------------------------------------------------------------
-- 9) SAMPLE-SELECT UI FUNCTIONS (Unchanged)
----------------------------------------------------------------

local function refresh_dir_contents()
  item_list = list_dir_contents(current_dir)
  -- Clamp index, considering potential empty list
  item_idx = util.clamp(item_idx, 1, math.max(1, #item_list))
end

-- Corrected open_sample_select
local function open_sample_select()
  print("Opening sample select...")
  -- Ensure root_dir is valid before using it (safety check)
  if not root_dir or not util.file_exists(root_dir) or not is_dir(root_dir) then
       print("Warning: Invalid root_dir ('"..tostring(root_dir).."') detected. Reverting to audio default.")
       root_dir = _path.audio
       params:set("browse_root", root_dir) -- Correct param too
  end

  ui_mode = "sample_select"
  -- Always start Browse from the validated root directory
  current_dir = root_dir
  print("Sample select starting at: " .. current_dir)
  -- Reset view state
  item_idx = 1
  slot_idx = 1 -- Reset target slot for loading
  refresh_dir_contents() -- Refresh contents for the root directory
  redraw() -- Update display immediately
end

local function open_item()
  if #item_list < 1 or item_idx < 1 or item_idx > #item_list then return end
  local it = item_list[item_idx]
  if it.type == "up" or it.type == "dir" then
    current_dir = it.path
    item_idx = 1 -- Reset item index when changing directory
    refresh_dir_contents()
    redraw()
  elseif it.type == "file" then
    -- If user presses K2 on a file, load it into the current slot
     print("Load sample (K2): reading " .. it.path .. " into slot " .. slot_idx)
     engine.read(slot_idx, it.path)
     params:set(slot_idx.."sample", it.path) -- Update the parameter
     ui_mode = "main" -- Exit sample select after loading
     redraw() -- Update screen immediately
  end
end

local function confirm_sample_select()
  if #item_list < 1 or item_idx < 1 or item_idx > #item_list then
    ui_mode = "main" -- Exit if list is empty or index invalid
    redraw()
    return
  end
  local it = item_list[item_idx]

  if it.type == "file" then
    print("Load sample (K3): reading " .. it.path .. " into slot " .. slot_idx)
    engine.read(slot_idx, it.path)
    params:set(slot_idx.."sample", it.path) -- Update the parameter
    ui_mode = "main" -- Exit sample select after loading
    redraw()
  elseif it.type == "dir" or it.type == "up" then
     -- If K3 pressed on a directory or '..', open it (same as K2)
     current_dir = it.path
     item_idx = 1 -- Reset item index
     refresh_dir_contents()
     redraw() -- Update browser view, stay in sample select mode
  else
    -- If "none" type item selected, just exit
    -- print("confirm_sample_select: selection is not a file or directory.")
    ui_mode = "main" -- Exit if selection invalid
    redraw()
  end
end

----------------------------------------------------------------
-- 10) KEY / ENC HANDLING (Unchanged)
----------------------------------------------------------------

-- Corrected key function
function key(n, z)
    if ui_mode == "sample_select" then
      if z == 1 then -- Key down only
        if n == 1 then -- K1 exits sample select mode
          ui_mode = "main"
          redraw()
        elseif n == 2 then
          open_item()  -- K2 opens folder/up OR loads selected file
        elseif n == 3 then
          confirm_sample_select()  -- K3 confirms file load OR opens selected folder
        end
      end
      return -- Prevent main mode key handling
    end

    -- Main Mode Key Handling
    if n == 1 then
      if z == 1 then -- K1 Press: Randomize Slot 3
        print("K1 press: Randomize Slot 3")
        randomize(3)
      end
    elseif n == 2 then
      if z == 1 then -- K2 Press: Start timer for long press
        key2_hold = true -- Mark as pressed
        clock.run(function()
          clock.sleep(0.6) -- Hold duration threshold
          if key2_hold == true then -- Still held and not marked as long_executed? It's a long press.
            print("K2 long press: Open Sample Select")
            key2_hold = "long_executed" -- Mark long press action as done *before* opening selector
            open_sample_select() -- This changes ui_mode and redraws
          end
        end)
      else -- K2 Release (z == 0)
        if key2_hold == true then -- Was pressed but long press didn't execute? Short press.
          print("K2 short press: Randomize Slot 1")
          randomize(1)
        end
        key2_hold = false -- Reset state on release regardless
      end
    elseif n == 3 then
      if z == 1 then -- K3 Press: Randomize Slot 2
        print("K3 press: Randomize Slot 2")
        randomize(2)
      end
    end
  end

function enc(n, d)
  if ui_mode == "sample_select" then
    if n == 2 then -- E2 scrolls file/dir list
      item_idx = util.clamp(item_idx + d, 1, math.max(1, #item_list))
    elseif n == 3 then -- E3 selects target slot for loading
      slot_idx = util.clamp(slot_idx + d, 1, 3)
    end
    redraw() -- Update browser display
  else
    -- Main Mode Encoder Handling: Volume control
    -- E1 -> Slot 3 Volume
    -- E2 -> Slot 1 Volume
    -- E3 -> Slot 2 Volume
    local target_param_id = ""
    if n == 1 then target_param_id = "3volume"
    elseif n == 2 then target_param_id = "1volume"
    elseif n == 3 then target_param_id = "2volume"
    end
    if target_param_id ~= "" then
      -- Check param exists before delta
      if params:get(target_param_id) ~= nil then
           params:delta(target_param_id, d)
      end
    end
    -- Redraw is handled by the UI metro
  end
end

----------------------------------------------------------------
-- 11) LFO LOGIC (Unchanged - Does not target new pitch shift params)
----------------------------------------------------------------

local function update_lfos()
  -- === Update Slot LFOs ===
  for slot_idx = 1, NUM_SLOTS do
    for lfo_num = 1, NUM_LFOS_PER_SLOT do
        local lfo_id_prefix = slot_idx .. "lfo" .. lfo_num .. "_" -- e.g., 1lfo1_
        local amount = params:get(lfo_id_prefix .. "amount")

        -- Skip if LFO amount is negligible
        if amount == nil or amount < 0.001 then
          slot_lfo_values[slot_idx][lfo_num] = 0 -- Ensure value is reset if turned off
          goto continue_slot_lfo_loop -- Skip to the next LFO in this slot
        end

        -- Get LFO parameters
        local target_param_idx = params:get(lfo_id_prefix .. "target_param") -- Option index
        local rate = params:get(lfo_id_prefix .. "rate")
        local shape_idx = params:get(lfo_id_prefix .. "shape")

        -- Safety checks for missing params
        if target_param_idx == nil or rate == nil or shape_idx == nil then
           goto continue_slot_lfo_loop
        end

        local target_param_name = slot_lfo_target_param_names[target_param_idx]
        local shape_name = lfo_shape_names[shape_idx]

        -- Update phase
        local current_phase = slot_lfo_phases[slot_idx][lfo_num][1]
        local new_phase = (current_phase + rate * LFO_METRO_RATE) % 1.0
        slot_lfo_phases[slot_idx][lfo_num][1] = new_phase

        -- Calculate LFO wave value (-1 to 1)
        local lfo_wave = 0
        if shape_name == "sine" then
            lfo_wave = math.sin(new_phase * 2 * math.pi)
        elseif shape_name == "tri" then
            lfo_wave = tri_wave(new_phase)
        elseif shape_name == "saw" then
            lfo_wave = (new_phase * 2.0) - 1.0 -- Ramp up from -1 to 1
        elseif shape_name == "sqr" then
            lfo_wave = (new_phase < 0.5) and 1.0 or -1.0
        elseif shape_name == "random" then
            lfo_wave = (math.random() * 2.0) - 1.0
            -- Stepped random example (update only when phase wraps)
            -- if new_phase < current_phase then
            --     slot_lfo_values[slot_idx][lfo_num] = (math.random() * 2.0) - 1.0
            -- end
            -- lfo_wave = slot_lfo_values[slot_idx][lfo_num]
        end
        slot_lfo_values[slot_idx][lfo_num] = lfo_wave -- Store current raw value

        -- Apply modulation to the target slot parameter
        local full_param_id = slot_idx .. target_param_name -- e.g., "1volume"
        local base_val = params:get(full_param_id)

        if base_val ~= nil then
            local modulated_val = base_val -- Start with base
            local final_engine_val -- Value in the format engine expects

            -- Apply modulation based on parameter type
            if target_param_name == "volume" then -- dB taper, range -60 to 20
                local range = 80 -- (20 - (-60))
                local offset_db = lfo_wave * amount * (range / 2.0)
                modulated_val = util.clamp(base_val + offset_db, -60, 20)
                final_engine_val = util.dbamp(modulated_val) -- Convert to amplitude
                engine.volume(slot_idx, final_engine_val)

            elseif target_param_name == "pan" then -- Linear, range -1 to 1
                local range = 2 -- (1 - (-1))
                local offset = lfo_wave * amount * (range / 2.0)
                modulated_val = util.clamp(base_val + offset, -1.0, 1.0)
                final_engine_val = modulated_val
                engine.pan(slot_idx, final_engine_val)

            elseif target_param_name == "jitter" then -- ms taper, 0 to 2000
                local range = 2000
                local offset_ms = lfo_wave * amount * (range / 2.0)
                modulated_val = util.clamp(base_val + offset_ms, 0, 2000)
                final_engine_val = modulated_val / 1000.0 -- Convert to seconds
                engine.jitter(slot_idx, final_engine_val)

            elseif target_param_name == "size" then -- ms taper, 1 to 500
                local range = 499
                local offset_ms = lfo_wave * amount * (range / 2.0)
                modulated_val = util.clamp(base_val + offset_ms, 1, 500)
                final_engine_val = modulated_val / 1000.0 -- Convert to seconds
                engine.size(slot_idx, final_engine_val)

            elseif target_param_name == "density" then -- hz taper, 0 to 512
                local range = 512
                local offset_hz = lfo_wave * amount * (range / 2.0)
                modulated_val = util.clamp(base_val + offset_hz, 0, 512)
                final_engine_val = modulated_val
                engine.density(slot_idx, final_engine_val)

            elseif target_param_name == "pitch" then -- st taper, -48 to 48
                local range = 96 -- (48 - (-48))
                local offset_st = lfo_wave * amount * (range / 2.0)
                modulated_val = util.clamp(base_val + offset_st, -48, 48)
                final_engine_val = math.pow(2, modulated_val / 12.0) -- Convert to pitch ratio
                engine.pitch(slot_idx, final_engine_val)

            elseif target_param_name == "spread" then -- % taper, 0 to 100
                local range = 100
                local offset_pct = lfo_wave * amount * (range / 2.0)
                modulated_val = util.clamp(base_val + offset_pct, 0, 100)
                final_engine_val = modulated_val / 100.0 -- Convert to 0-1
                engine.spread(slot_idx, final_engine_val)

            elseif target_param_name == "fade" then -- ms taper, 1 to 9000
                local range = 8999
                local offset_ms = lfo_wave * amount * (range / 2.0)
                modulated_val = util.clamp(base_val + offset_ms, 1, 9000)
                final_engine_val = modulated_val / 1000.0 -- Convert to seconds
                engine.envscale(slot_idx, final_engine_val)

            elseif target_param_name == "seek" then -- % linear, 0 to 100
                local range = 100
                local offset_pct = lfo_wave * amount * (range / 2.0)
                modulated_val = util.clamp(base_val + offset_pct, 0, 100)
                final_engine_val = modulated_val / 100.0 -- Convert to 0-1
                engine.seek(slot_idx, final_engine_val)

            elseif target_param_name == "filter_cutoff" then -- Hz taper, 20 to 20000
                local range = 19980 -- (20000 - 20)
                local offset_hz = lfo_wave * amount * (range / 2.0)
                modulated_val = util.clamp(base_val + offset_hz, 20, 20000)
                final_engine_val = modulated_val
                engine.filterCutoff(slot_idx, final_engine_val)

            elseif target_param_name == "filter_q" then -- Q taper, 0.1 to 4.0
                local range = 3.9 -- (4.0 - 0.1)
                local offset_q = lfo_wave * amount * (range / 2.0)
                modulated_val = util.clamp(base_val + offset_q, 0.1, 4.0)
                final_engine_val = modulated_val
                engine.filterRQ(slot_idx, final_engine_val)

            end -- end parameter type check
        else
            -- print("Slot LFO Warning: Target param not found: " .. full_param_id)
        end -- end base_val check

        ::continue_slot_lfo_loop::
    end -- end slot LFO loop
  end -- end slot loop

  -- === Update FX LFOs ===
  local fx_modulation_targets = {
      { block_key = "delay_l",     prefix = "delay_l_",     target_names = delay_lfo_target_param_names,     engine_funcs = {time = engine.delay_time_l, feedback = engine.delay_feedback_l, mix = engine.delay_mix_l} },
      { block_key = "delay_r",     prefix = "delay_r_",     target_names = delay_lfo_target_param_names,     engine_funcs = {time = engine.delay_time_r, feedback = engine.delay_feedback_r, mix = engine.delay_mix_r} },
      { block_key = "decimator_l", prefix = "decimator_l_", target_names = decimator_lfo_target_param_names, engine_funcs = {rate = engine.decimator_rate_l, bits = engine.decimator_bits_l, mul = engine.decimator_mul_l, add = engine.decimator_add_l} },
      { block_key = "decimator_r", prefix = "decimator_r_", target_names = decimator_lfo_target_param_names, engine_funcs = {rate = engine.decimator_rate_r, bits = engine.decimator_bits_r, mul = engine.decimator_mul_r, add = engine.decimator_add_r} }
  }

  for _, fx_target in ipairs(fx_modulation_targets) do
      local block_key = fx_target.block_key
      local fx_prefix = fx_target.prefix
      local target_param_name_list = fx_target.target_names
      local engine_funcs = fx_target.engine_funcs

      for lfo_num = 1, NUM_LFOS_PER_FX do
          local lfo_param_id_prefix = fx_prefix .. "lfo" .. lfo_num .. "_" -- e.g., delay_l_lfo1_
          local amount = params:get(lfo_param_id_prefix .. "amount")

          -- Skip if LFO amount is negligible
          if amount == nil or amount < 0.001 then
             fx_lfo_values[block_key][lfo_num] = 0 -- Ensure value is reset
             goto continue_fx_lfo_loop -- Skip to the next LFO in this block
          end

          -- Get LFO parameters
          local target_param_idx = params:get(lfo_param_id_prefix .. "target_param") -- Option index relative to fx block
          local rate = params:get(lfo_param_id_prefix .. "rate")
          local shape_idx = params:get(lfo_param_id_prefix .. "shape")

          -- Safety checks
          if target_param_idx == nil or rate == nil or shape_idx == nil then
             goto continue_fx_lfo_loop
          end

          local target_param_name = target_param_name_list[target_param_idx] -- e.g., "time", "feedback"
          local shape_name = lfo_shape_names[shape_idx]
          local engine_function = engine_funcs[target_param_name] -- Get the correct engine function

          -- Check if we found a valid target param name and engine function
          if not target_param_name or not engine_function then
             -- print("FX LFO Warning: Invalid target param index or name for " .. lfo_param_id_prefix)
             goto continue_fx_lfo_loop
          end

          -- Update phase
          local current_phase = fx_lfo_phases[block_key][lfo_num][1]
          local new_phase = (current_phase + rate * LFO_METRO_RATE) % 1.0
          fx_lfo_phases[block_key][lfo_num][1] = new_phase

          -- Calculate LFO wave value (-1 to 1)
          local lfo_wave = 0
          if shape_name == "sine" then
              lfo_wave = math.sin(new_phase * 2 * math.pi)
          elseif shape_name == "tri" then
              lfo_wave = tri_wave(new_phase)
          elseif shape_name == "saw" then
              lfo_wave = (new_phase * 2.0) - 1.0
          elseif shape_name == "sqr" then
              lfo_wave = (new_phase < 0.5) and 1.0 or -1.0
          elseif shape_name == "random" then
              lfo_wave = (math.random() * 2.0) - 1.0
          end
          fx_lfo_values[block_key][lfo_num] = lfo_wave

          -- Apply modulation to the target FX parameter
          local full_engine_param_id = fx_prefix .. target_param_name -- e.g., "delay_l_time"
          local base_val = params:get(full_engine_param_id)

          if base_val ~= nil then
              local modulated_val = base_val
              local final_engine_val

              -- Apply modulation based on parameter type
              if target_param_name == "time" then -- Delay time: 0 to 2.0 s
                  local range = 2.0
                  local offset_s = lfo_wave * amount * (range / 2.0)
                  modulated_val = util.clamp(base_val + offset_s, 0.0, 2.0)
                  final_engine_val = modulated_val

              elseif target_param_name == "feedback" or target_param_name == "mix" then -- Delay feedback/mix: 0 to 1.0
                  local range = 1.0
                  local offset = lfo_wave * amount * (range / 2.0)
                  modulated_val = util.clamp(base_val + offset, 0.0, 1.0)
                  final_engine_val = modulated_val

              elseif target_param_name == "rate" then -- Decimator rate: 100 to 96000 Hz
                  local range = 95900
                  local offset_hz = lfo_wave * amount * (range / 2.0)
                  modulated_val = util.clamp(base_val + offset_hz, 100, 96000)
                  final_engine_val = modulated_val

              elseif target_param_name == "bits" then -- Decimator bits: 1 to 32
                  local range = 31
                  local offset_bits = lfo_wave * amount * (range / 2.0)
                  modulated_val = util.clamp(base_val + offset_bits, 1, 32)
                  final_engine_val = math.floor(modulated_val + 0.5) -- Round to nearest integer

              elseif target_param_name == "mul" then -- Decimator mul: 0 to 10
                  local range = 10
                  local offset_mul = lfo_wave * amount * (range / 2.0)
                  modulated_val = util.clamp(base_val + offset_mul, 0, 10)
                  final_engine_val = modulated_val

              elseif target_param_name == "add" then -- Decimator add: -10 to 10
                  local range = 20
                  local offset_add = lfo_wave * amount * (range / 2.0)
                  modulated_val = util.clamp(base_val + offset_add, -10, 10)
                  final_engine_val = modulated_val

              else
                  final_engine_val = base_val -- Fallback if type unknown
              end

              -- Call the engine function
              engine_function(final_engine_val)

          else
              -- print("FX LFO Warning: Base value not found for: " .. full_engine_param_id)
          end

          ::continue_fx_lfo_loop::
      end -- end LFO loop for this block
  end -- end FX blocks loop
end


local function setup_lfo_metro()
  lfo_metro = metro.init()
  lfo_metro.time = LFO_METRO_RATE
  lfo_metro.event = update_lfos
  lfo_metro:start()
end


----------------------------------------------------------------
-- 12) REDRAW (Unchanged)
----------------------------------------------------------------

function redraw()
  screen.clear()
  if ui_mode == "sample_select" then
    screen.level(15)
    screen.move(0, 10)
    -- Show only last part of path for brevity
    local dir_display_name = current_dir
    if dir_display_name then -- Check current_dir is not nil
         dir_display_name = string.match(current_dir, "([^/]+)/*$") or current_dir
    else
         dir_display_name = "(error)" -- Fallback if dir is nil
    end
    screen.text("Browse: " .. dir_display_name)

    local top_y = 22
    local line_h = 8
    local display_count = 4 -- Max items to display at once to leave space for labels
    local scroll_offset = 0
    if #item_list > 0 then
        -- Ensure item_idx is valid before calculating offset
        item_idx = util.clamp(item_idx, 1, #item_list)
        scroll_offset = math.max(0, item_idx - display_count)
    end

    -- Display directory/file items
    for i = 1, display_count do
        local list_index = i + scroll_offset
        if list_index <= #item_list then
          local item = item_list[list_index]
          if item then -- Check item exists
            local yy = top_y + (i - 1) * line_h
            if list_index == item_idx then screen.level(15) else screen.level(5) end
            screen.move(5, yy)
            local prefix = ""
            if item.type == "dir" then prefix = "/" elseif item.type == "up" then prefix = "" end
            -- Truncate long names
            local display_name = item.name or "(invalid item)"
            if string.len(display_name) > 18 then display_name = string.sub(display_name, 1, 17) .. "…" end
            screen.text(prefix .. display_name)
          end
        end
    end
    -- Scroll indicators
    if scroll_offset > 0 then
        screen.level(5)
        screen.move(0, top_y - 4); screen.line_rel(3, 0); screen.stroke()
    end
    if #item_list > 0 and scroll_offset + display_count < #item_list then
        screen.level(5)
        screen.move(0, top_y + display_count * line_h - 4); screen.line_rel(3, 0); screen.stroke()
    end


    local rx = 75 -- X position for slot list
    -- Display Slot selector
    screen.level(15)
    screen.move(rx, top_y - line_h) -- Label above slots
    screen.text("Load Slot:")
    for s = 1, 3 do
      local yy = top_y + (s - 1) * line_h
      if s == slot_idx then screen.level(15) else screen.level(5) end
      screen.move(rx, yy)
      local sample_path = params:string(s.."sample") or "" -- Use string representation or ""
      local sample_filename = "(empty)"
      if sample_path ~= "" then
           sample_filename = string.match(sample_path, "([^/]+)/*$") or sample_path
      end
       -- Truncate filename
      if string.len(sample_filename) > 8 then sample_filename = string.sub(sample_filename, 1, 7) .. "…" end
      screen.text(s .. ": " .. sample_filename)
    end

    -- Help text at bottom
    screen.level(5)
    screen.move(0, 56)
    screen.text("K1:exit E2:list E3:slot K2/3:ok")


  else -- Main UI mode (Squares)
    for i = 1, 3 do
      local x = square_x[i]
      local y = square_y
      local s = square_size
      screen.level(1) -- Dark background for square
      screen.rect(x, y, s, s); screen.fill()

      -- Volume Indicator (Vertical bar on left)
      local vol_db = params:get(i.."volume")
      if vol_db == nil then vol_db = -60 end -- Default if param missing
      local volFrac = util.linlin(-60, 20, 0, 1, vol_db)
      volFrac = util.clamp(volFrac, 0, 1)
      local bar_width = 4
      local bar_height = s * volFrac
      local bar_x = x
      local bar_y = y + s - bar_height -- Bar grows from bottom
      screen.level(4); screen.rect(bar_x, y, bar_width, s); screen.fill() -- Background track
      screen.level(15); screen.rect(bar_x, bar_y, bar_width, bar_height); screen.fill() -- Indicator

      -- Seek Indicator (Horizontal bar on bottom)
      local seek_val = params:get(i.."seek")
      if seek_val == nil then seek_val = 0 end
      local seekFrac = util.linlin(0, 100, 0, 1, seek_val)
      seekFrac = util.clamp(seekFrac, 0, 1)
      local hbar_height = 4
      local hbar_width = s * seekFrac
      local hbar_x = x
      local hbar_y = y + s - hbar_height
      screen.level(4); screen.rect(hbar_x, hbar_y, s, hbar_height); screen.fill() -- Background track
      screen.level(15); screen.rect(hbar_x, hbar_y, hbar_width, hbar_height); screen.fill() -- Indicator
    end
  end
  screen.update()
end

----------------------------------------------------------------
-- 13) INIT (Unchanged logic)
----------------------------------------------------------------

-- Corrected init function
function init()
  print("Elle init starting...")
  -- Ensure params are cleared before setup? Generally not needed unless debugging PSET issues.
  -- params:clear()
  setup_params() -- Setup params first to load saved values / defaults

  -- Set root directory based on loaded parameter or default
  local br = params:get("browse_root")
  local validated_root = _path.audio -- Default fallback

  if type(br) == "string" and br ~= "" then
    local potential_root = br
    -- If param looks like a file, try its directory
    if not is_dir(potential_root) and util.file_exists(potential_root) then
         potential_root = file_dir_name(potential_root)
    end
    -- Check if the potential root (original or derived directory) is valid
    if util.file_exists(potential_root) and is_dir(potential_root) then
         validated_root = potential_root
         print("init: Using browse_root: " .. validated_root)
    else
         print("init: browse_root param invalid ('"..tostring(br).."'), using default.")
    end
  else
    print("init: browse_root param missing or invalid type, using default.")
  end

  -- Set the global root_dir
  root_dir = validated_root
  -- Ensure the parameter reflects the actual root being used
  if params:get("browse_root") ~= root_dir then
       params:set("browse_root", root_dir)
  end
  print("browse_root initialized to: " .. root_dir)
  current_dir = root_dir -- Start Browse from root

  setup_engine() -- Send initial gate commands, starts clock for playhead update
  setup_ui_metro() -- Start UI updates
  setup_lfo_metro() -- Start LFO updates
  print("Elle init finished.")
  -- Initial redraw is handled by metro soon after
end

-- Optional: Cleanup function for when script exits
function cleanup()
    print("Elle cleanup...")
    -- Stop all metros
    if ui_metro then ui_metro:stop(); ui_metro = nil end
    if lfo_metro then lfo_metro:stop(); lfo_metro = nil end
    for i=1,3 do
        if pingpong_metros[i] then pingpong_metros[i]:stop(); pingpong_metros[i] = nil end
        if random_seek_metros[i] then random_seek_metros[i]:stop(); random_seek_metros[i] = nil end
    end
    print("Elle cleanup finished.")
end
