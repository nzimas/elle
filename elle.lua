-- |_ (Elle)
-- by @nzimas
--

engine.name = "Elle"

----------------------------------------------------------------
-- 1) GLOBALS & HELPERS
----------------------------------------------------------------

local ui_mode = "main"     -- "main" or "sample_select"

-- "browse_root" (set via param) determines the root folder; default is _path.audio.
local root_dir = _path.audio
local current_dir = _path.audio

-- In sample-select UI, the left column shows items and the right column shows slot numbers.
local item_list = {}
local item_idx = 1
local slot_idx = 1

local function file_dir_name(fp)
  local d = string.match(fp, "^(.*)/[^/]*$")
  return d or fp
end

local function file_exists(path)
  if not path or path == "" then return false end
  local f = io.open(path, "rb")
  if f then f:close() return true end
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
  local ok, items = pcall(util.scandir, path)
  return (ok and items ~= nil)
end

-- Ping-pong logic for playhead direction
local pingpong_metros = {nil, nil, nil}
local pingpong_sign = {1, 1, 1}

-- Geometry for main UI squares
local square_size = 30
local square_y = 15
local square_x = {10, 49, 88}

local ui_metro
local random_seek_metros = {nil, nil, nil}

local key1_hold = false
local key2_hold = false
local key3_hold = false

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

-- We only use morph_time (no transitions)
local morph_time_options = {}
for t = 0, 90000, 500 do
  table.insert(morph_time_options, t)
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
  clock.run(function()
    local start_val = params:get(param_name)
    local steps = 60
    local dt = duration / steps
    for i = 1, steps do
      local t = i / steps
      local interp = start_val + (new_val - start_val) * t
      params:set(param_name, interp)
      clock.sleep(dt)
    end
    params:set(param_name, new_val)
  end)
end

----------------------------------------------------------------
-- 3) DIRECTORY Browse FUNCTIONS
----------------------------------------------------------------

local function list_dir_contents(dir)
  local items = {}
  if dir ~= root_dir and dir ~= "/" then
    table.insert(items, {type = "up", name = "[..]", path = file_dir_name(dir)})
  end
  local ok, listing = pcall(util.scandir, dir)
  if not ok or not listing then
    return {{type = "none", name = "(empty or error)", path = dir}}
  end
  -- Subdirectories first
  for _, f in ipairs(listing) do
    local p = dir .. "/" .. f
    if file_exists(p) and is_dir(p) then
      table.insert(items, {type = "dir", name = f, path = p})
    end
  end
  -- Then audio files
  for _, f in ipairs(listing) do
    local p = dir .. "/" .. f
    if file_exists(p) and not is_dir(p) then
      local lower = string.lower(f)
      if string.match(lower, "%.wav$") or string.match(lower, "%.aif$") or
         string.match(lower, "%.aiff$") or string.match(lower, "%.flac$") then
        table.insert(items, {type = "file", name = f, path = p})
      end
    end
  end
  if #items < 1 then
    table.insert(items, {type = "none", name = "(no subdirs or audio)", path = dir})
  end
  return items
end

----------------------------------------------------------------
-- 4) PLAYHEAD / PING-PONG LOGIC
----------------------------------------------------------------

local function update_playhead(i)
  local rate = params:get(i.."playhead_rate")
  local dir = params:get(i.."playhead_direction")
  if pingpong_metros[i] then
    pingpong_metros[i]:stop()
    pingpong_metros[i] = nil
    pingpong_sign[i] = 1
  end
  if dir == 1 then
    engine.speed(i, rate)
  elseif dir == 2 then
    engine.speed(i, -rate)
  else
    pingpong_metros[i] = metro.init()
    pingpong_metros[i].time = 2.0
    pingpong_metros[i].event = function()
      pingpong_sign[i] = -pingpong_sign[i]
      engine.speed(i, pingpong_sign[i] * rate)
    end
    pingpong_metros[i]:start()
    engine.speed(i, rate)
  end
end

----------------------------------------------------------------
-- 5) PITCH RANDOMIZATION
----------------------------------------------------------------

local function random_float(mn, mx)
  return mn + math.random()*(mx - mn)
end

local function get_random_pitch(slot)
  local s = tostring(slot)
  local root_off = params:get("pitch_root") - 1
  local sc_idx = params:get("pitch_scale")
  local base = scales[ scale_options[sc_idx] ]
  local min_off = tonumber(params:string(s.."pitch_rng_min"))
  local max_off = tonumber(params:string(s.."pitch_rng_max"))
  if min_off > max_off then min_off = max_off end
  local cur_pitch = params:get(s.."pitch")
  local cur_off = cur_pitch - root_off
  local allowed = {}
  for _, iv in ipairs(base) do
    for _, sh in ipairs({-12, 0, 12}) do
      local c = iv + sh
      if c >= min_off and c <= max_off then
        table.insert(allowed, c)
      end
    end
  end
  if #allowed > 1 then
    for i, v in ipairs(allowed) do
      if v == cur_off then
        table.remove(allowed, i)
        break
      end
    end
  end
  if #allowed > 0 then
    local chosen = allowed[math.random(#allowed)]
    return root_off + chosen
  else
    return root_off
  end
end

----------------------------------------------------------------
-- 6) PARAMETER DEFINITIONS
----------------------------------------------------------------

local function setup_params()
  params:add_file("browse_root", "sample root dir", _path.audio)
  params:set_action("browse_root", function(file)
    if file and file ~= "" then
      local d = file_dir_name(file)
      -- Basic validation: check if directory exists
      if util.file_exists(d) and is_dir(d) then
         root_dir = d
         print("browse_root => " .. root_dir)
      else
         print("browse_root invalid: " .. d .. ", reverting to default.")
         root_dir = _path.audio
         params:set("browse_root", root_dir) -- Update param if corrected
      end
    else
      root_dir = _path.audio
      print("browse_root => (default) " .. root_dir)
    end
  end)

  params:add_separator() -- Separator before groups

  -- ======================== SLOT 1 PARAMETERS ========================
  local slot1_param_count = 20 -- Manually count params added below
  params:add_group("slot1", "Slot 1 Settings", slot1_param_count)
  do -- Use a block to scope local i = 1
    local i = 1
    local sid = i.."" -- String version of slot index for IDs

    -- Unique ID: sid.."sample", Label: "sample"
    params:add_file(sid.."sample", "sample")
    params:set_action(sid.."sample", function(f) engine.read(i, f) end)

    -- Unique ID: sid.."playhead_rate", Label: "playhead rate"
    params:add_control(sid.."playhead_rate", "playhead rate",
      controlspec.new(0, 4, "lin", 0.01, 1.0, "", 0.01/4))
    params:set_action(sid.."playhead_rate", function() update_playhead(i) end)

    -- Unique ID: sid.."playhead_direction", Label: "direction"
    params:add_option(sid.."playhead_direction", "direction", {">>", "<<", "<->"}, 1)
    params:set_action(sid.."playhead_direction", function() update_playhead(i) end)

    -- Unique ID: sid.."volume", Label: "volume"
    params:add_taper(sid.."volume", "volume", -60, 20, 0, 0, "dB")
    params:set_action(sid.."volume", function(v) engine.volume(i, util.dbamp(v)) end) -- Use dbamp helper

    -- Unique ID: sid.."jitter", Label: "jitter"
    params:add_taper(sid.."jitter", "jitter", 0, 2000, 0, 5, "ms")
    params:set_action(sid.."jitter", function(v) engine.jitter(i, v/1000) end)

    -- Unique ID: sid.."size", Label: "size"
    params:add_taper(sid.."size", "size", 1, 500, 100, 5, "ms")
    params:set_action(sid.."size", function(v) engine.size(i, v/1000) end)

    -- Unique ID: sid.."density", Label: "density"
    params:add_taper(sid.."density", "density", 0, 512, 20, 6, "hz")
    params:set_action(sid.."density", function(v) engine.density(i, v) end)

    -- Unique ID: sid.."pitch", Label: "pitch"
    params:add_taper(sid.."pitch", "pitch", -48, 48, 0, 0, "st")
    -- FIX: Use math.pow for semitone to ratio conversion
    params:set_action(sid.."pitch", function(v) engine.pitch(i, math.pow(2, v/12)) end)

    -- Unique ID: sid.."spread", Label: "spread"
    params:add_taper(sid.."spread", "spread", 0, 100, 0, 0, "%")
    params:set_action(sid.."spread", function(v) engine.spread(i, v/100) end)

    -- Unique ID: sid.."fade", Label: "fade"
    params:add_taper(sid.."fade", "fade", 1, 9000, 1000, 3, "ms")
    params:set_action(sid.."fade", function(v) engine.envscale(i, v/1000) end)

    -- Unique ID: sid.."seek", Label: "seek"
    params:add_control(sid.."seek", "seek",
      controlspec.new(0, 100, "lin", 0.1, 0, "%", 0.1/100)) -- Default 0 for slot 1
    params:set_action(sid.."seek", function(v) engine.seek(i, v/100) end)

    -- Unique ID: sid.."random_seek", Label: "random seek"
    params:add_option(sid.."random_seek", "random seek", {"off", "on"}, 1)

    -- Unique ID: sid.."random_seek_freq_min", Label: "rseek freq min"
    params:add_control(sid.."random_seek_freq_min", "rseek freq min",
      controlspec.new(100, 30000, "lin", 100, 500, "ms"))
    params:set_action(sid.."random_seek_freq_min", function(val)
      local mx = params:get(sid.."random_seek_freq_max")
      if val > mx then params:set(sid.."random_seek_freq_min", mx) end
    end)

    -- Unique ID: sid.."random_seek_freq_max", Label: "rseek freq max"
    params:add_control(sid.."random_seek_freq_max", "rseek freq max",
      controlspec.new(100, 30000, "lin", 100, 2000, "ms"))
    params:set_action(sid.."random_seek_freq_max", function(val)
      local mn = params:get(sid.."random_seek_freq_min")
      if val < mn then params:set(sid.."random_seek_freq_max", mn) end
    end)

    -- Action for random_seek toggle (refers to other params within the same slot)
    params:set_action(sid.."random_seek", function(val)
      if val == 2 then
        if not random_seek_metros[i] then
          random_seek_metros[i] = metro.init()
          random_seek_metros[i].event = function()
            params:set(sid.."seek", math.random() * 100)
            local tmin = params:get(sid.."random_seek_freq_min")
            local tmax = params:get(sid.."random_seek_freq_max")
            local nxt = math.random(tmin, tmax)
            random_seek_metros[i].time = nxt / 1000
          end
        end
        local tmin_init = params:get(sid.."random_seek_freq_min")
        local tmax_init = params:get(sid.."random_seek_freq_max")
        random_seek_metros[i].time = math.random(tmin_init, tmax_init) / 1000
        random_seek_metros[i]:start()
      else
        if random_seek_metros[i] then random_seek_metros[i]:stop() end
      end
    end)

    -- Unique ID: sid.."pitch_change", Label: "pitch change?"
    params:add_option(sid.."pitch_change", "pitch change?", {"no", "yes"}, 2)

    local pitch_vals = {}
    for v = -24, 24 do table.insert(pitch_vals, v) end
    local pitch_strs = {}
    for _, v in ipairs(pitch_vals) do table.insert(pitch_strs, tostring(v)) end

    -- Unique ID: sid.."pitch_rng_min", Label: "pitch rng min"
    params:add_option(sid.."pitch_rng_min", "pitch rng min", pitch_strs, 25) -- 0 st
    params:set_action(sid.."pitch_rng_min", function(idx)
      local mn_idx = idx -- Use the new index being set
      local mx_idx = params:get(sid.."pitch_rng_max")
      if mn_idx > mx_idx then params:set(sid.."pitch_rng_min", mx_idx) end
    end)

    -- Unique ID: sid.."pitch_rng_max", Label: "pitch rng max"
    params:add_option(sid.."pitch_rng_max", "pitch rng max", pitch_strs, 25) -- 0 st
    params:set_action(sid.."pitch_rng_max", function(idx)
       local mn_idx = params:get(sid.."pitch_rng_min")
       local mx_idx = idx -- Use the new index being set
       if mx_idx < mn_idx then params:set(sid.."pitch_rng_max", mn_idx) end
    end)

    -- Unique ID: sid.."filter_change", Label: "random filter?"
    params:add_option(sid.."filter_change", "random filter?", {"no", "yes"}, 1)

    -- Unique ID: sid.."filter_cutoff", Label: "filter cutoff"
    params:add_taper(sid.."filter_cutoff", "filter cutoff", 20, 20000, 8000, 0, "Hz")
    params:set_action(sid.."filter_cutoff", function(v) engine.filterCutoff(i, v) end)

    -- Unique ID: sid.."filter_q", Label: "filter Q"
    params:add_taper(sid.."filter_q", "filter Q", 0.1, 4.0, 0.5, 0, "")
    params:set_action(sid.."filter_q", function(v) engine.filterRQ(i, v) end)
  end -- End of Slot 1 block

  -- ======================== SLOT 2 PARAMETERS ========================
  local slot2_param_count = 20
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
    params:add_taper(sid.."jitter", "jitter", 0, 2000, 0, 5, "ms")
    params:set_action(sid.."jitter", function(v) engine.jitter(i, v/1000) end)
    params:add_taper(sid.."size", "size", 1, 500, 100, 5, "ms")
    params:set_action(sid.."size", function(v) engine.size(i, v/1000) end)
    params:add_taper(sid.."density", "density", 0, 512, 20, 6, "hz")
    params:set_action(sid.."density", function(v) engine.density(i, v) end)
    params:add_taper(sid.."pitch", "pitch", -48, 48, 0, 0, "st")
    -- FIX: Use math.pow for semitone to ratio conversion
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
    params:set_action(sid.."random_seek_freq_min", function(val) local mx = params:get(sid.."random_seek_freq_max"); if val > mx then params:set(sid.."random_seek_freq_min", mx) end end)
    params:set_action(sid.."random_seek_freq_max", function(val) local mn = params:get(sid.."random_seek_freq_min"); if val < mn then params:set(sid.."random_seek_freq_max", mn) end end)
    params:set_action(sid.."random_seek", function(val) if val == 2 then if not random_seek_metros[i] then random_seek_metros[i] = metro.init(); random_seek_metros[i].event = function() params:set(sid.."seek", math.random() * 100); local tmin = params:get(sid.."random_seek_freq_min"); local tmax = params:get(sid.."random_seek_freq_max"); local nxt = math.random(tmin, tmax); random_seek_metros[i].time = nxt / 1000; end end; local tmin_init = params:get(sid.."random_seek_freq_min"); local tmax_init = params:get(sid.."random_seek_freq_max"); random_seek_metros[i].time = math.random(tmin_init, tmax_init) / 1000; random_seek_metros[i]:start(); else if random_seek_metros[i] then random_seek_metros[i]:stop() end end end)
    params:add_option(sid.."pitch_change", "pitch change?", {"no", "yes"}, 2)
    local pitch_vals = {} for v = -24, 24 do table.insert(pitch_vals, v) end
    local pitch_strs = {} for _, v in ipairs(pitch_vals) do table.insert(pitch_strs, tostring(v)) end
    params:add_option(sid.."pitch_rng_min", "pitch rng min", pitch_strs, 25)
    params:add_option(sid.."pitch_rng_max", "pitch rng max", pitch_strs, 25)
    params:set_action(sid.."pitch_rng_min", function(idx) local mn_idx = idx; local mx_idx = params:get(sid.."pitch_rng_max"); if mn_idx > mx_idx then params:set(sid.."pitch_rng_min", mx_idx) end end)
    params:set_action(sid.."pitch_rng_max", function(idx) local mn_idx = params:get(sid.."pitch_rng_min"); local mx_idx = idx; if mx_idx < mn_idx then params:set(sid.."pitch_rng_max", mn_idx) end end)
    params:add_option(sid.."filter_change", "random filter?", {"no", "yes"}, 1)
    params:add_taper(sid.."filter_cutoff", "filter cutoff", 20, 20000, 8000, 0, "Hz")
    params:set_action(sid.."filter_cutoff", function(v) engine.filterCutoff(i, v) end)
    params:add_taper(sid.."filter_q", "filter Q", 0.1, 4.0, 0.5, 0, "")
    params:set_action(sid.."filter_q", function(v) engine.filterRQ(i, v) end)
  end -- End of Slot 2 block


  -- ======================== SLOT 3 PARAMETERS ========================
  local slot3_param_count = 20
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
    params:add_taper(sid.."jitter", "jitter", 0, 2000, 0, 5, "ms")
    params:set_action(sid.."jitter", function(v) engine.jitter(i, v/1000) end)
    params:add_taper(sid.."size", "size", 1, 500, 100, 5, "ms")
    params:set_action(sid.."size", function(v) engine.size(i, v/1000) end)
    params:add_taper(sid.."density", "density", 0, 512, 20, 6, "hz")
    params:set_action(sid.."density", function(v) engine.density(i, v) end)
    params:add_taper(sid.."pitch", "pitch", -48, 48, 0, 0, "st")
    -- FIX: Use math.pow for semitone to ratio conversion
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
    params:set_action(sid.."random_seek_freq_min", function(val) local mx = params:get(sid.."random_seek_freq_max"); if val > mx then params:set(sid.."random_seek_freq_min", mx) end end)
    params:set_action(sid.."random_seek_freq_max", function(val) local mn = params:get(sid.."random_seek_freq_min"); if val < mn then params:set(sid.."random_seek_freq_max", mn) end end)
    params:set_action(sid.."random_seek", function(val) if val == 2 then if not random_seek_metros[i] then random_seek_metros[i] = metro.init(); random_seek_metros[i].event = function() params:set(sid.."seek", math.random() * 100); local tmin = params:get(sid.."random_seek_freq_min"); local tmax = params:get(sid.."random_seek_freq_max"); local nxt = math.random(tmin, tmax); random_seek_metros[i].time = nxt / 1000; end end; local tmin_init = params:get(sid.."random_seek_freq_min"); local tmax_init = params:get(sid.."random_seek_freq_max"); random_seek_metros[i].time = math.random(tmin_init, tmax_init) / 1000; random_seek_metros[i]:start(); else if random_seek_metros[i] then random_seek_metros[i]:stop() end end end)
    params:add_option(sid.."pitch_change", "pitch change?", {"no", "yes"}, 2)
    local pitch_vals = {} for v = -24, 24 do table.insert(pitch_vals, v) end
    local pitch_strs = {} for _, v in ipairs(pitch_vals) do table.insert(pitch_strs, tostring(v)) end
    params:add_option(sid.."pitch_rng_min", "pitch rng min", pitch_strs, 25)
    params:add_option(sid.."pitch_rng_max", "pitch rng max", pitch_strs, 25)
    params:set_action(sid.."pitch_rng_min", function(idx) local mn_idx = idx; local mx_idx = params:get(sid.."pitch_rng_max"); if mn_idx > mx_idx then params:set(sid.."pitch_rng_min", mx_idx) end end)
    params:set_action(sid.."pitch_rng_max", function(idx) local mn_idx = params:get(sid.."pitch_rng_min"); local mx_idx = idx; if mx_idx < mn_idx then params:set(sid.."pitch_rng_max", mn_idx) end end)
    params:add_option(sid.."filter_change", "random filter?", {"no", "yes"}, 1)
    params:add_taper(sid.."filter_cutoff", "filter cutoff", 20, 20000, 8000, 0, "Hz")
    params:set_action(sid.."filter_cutoff", function(v) engine.filterCutoff(i, v) end)
    params:add_taper(sid.."filter_q", "filter Q", 0.1, 4.0, 0.5, 0, "")
    params:set_action(sid.."filter_q", function(v) engine.filterRQ(i, v) end)
  end -- End of Slot 3 block

  -- ======================== GLOBAL PARAMETERS ========================
  params:add_separator("Global Settings")

  params:add_separator("key & scale")
  local notes = {"C", "C#/Db", "D", "D#/Eb", "E", "F", "F#/Gb", "G", "G#/Ab", "A", "A#/Bb", "B"}
  params:add_option("pitch_root", "root note", notes, 1)
  params:add_option("pitch_scale", "scale", scale_options, 1)

  params:add_separator("morphing")
  params:add_option("morph_time", "morph time (ms)", morph_time_options, 1) -- index 1 is 0ms


  params:add_separator("delay Left")
  params:add_taper("delay_time_l", "L delay time", 0.0, 2.0, 0.5, 0, "s")
  params:set_action("delay_time_l", function(v) engine.delay_time_l(v) end)
  params:add_taper("delay_feedback_l", "L delay feedback", 0, 1, 0.5, 0, "")
  params:set_action("delay_feedback_l", function(v) engine.delay_feedback_l(v) end)
  params:add_taper("delay_mix_l", "L delay mix", 0, 1, 0.5, 0, "")
  params:set_action("delay_mix_l", function(v) engine.delay_mix_l(v) end)

  params:add_separator("decimator Left")
  params:add_taper("decimator_rate_l", "L decimator rate", 100, 96000, 48000, 0, "Hz")
  params:set_action("decimator_rate_l", function(v) engine.decimator_rate_l(v) end)
  params:add_taper("decimator_bits_l", "L decimator bits", 1, 32, 32, 0, "")
  params:set_action("decimator_bits_l", function(v) engine.decimator_bits_l(v) end)
  params:add_control("decimator_mul_l", "L decimator mul", controlspec.new(0, 10, "lin", 0, 1.0, ""))
  params:set_action("decimator_mul_l", function(v) engine.decimator_mul_l(v) end)
  params:add_control("decimator_add_l", "L decimator add", controlspec.new(-10, 10, "lin", 0, 0, ""))
  params:set_action("decimator_add_l", function(v) engine.decimator_add_l(v) end)

  params:add_separator("delay Right")
  params:add_taper("delay_time_r", "R delay time", 0.0, 2.0, 0.5, 0, "s")
  params:set_action("delay_time_r", function(v) engine.delay_time_r(v) end)
  params:add_taper("delay_feedback_r", "R delay feedback", 0, 1, 0.5, 0, "")
  params:set_action("delay_feedback_r", function(v) engine.delay_feedback_r(v) end)
  params:add_taper("delay_mix_r", "R delay mix", 0, 1, 0.5, 0, "")
  params:set_action("delay_mix_r", function(v) engine.delay_mix_r(v) end)

  params:add_separator("decimator Right")
  params:add_taper("decimator_rate_r", "R decimator rate", 100, 96000, 48000, 0, "Hz")
  params:set_action("decimator_rate_r", function(v) engine.decimator_rate_r(v) end)
  params:add_taper("decimator_bits_r", "R decimator bits", 1, 32, 32, 0, "")
  params:set_action("decimator_bits_r", function(v) engine.decimator_bits_r(v) end)
  params:add_control("decimator_mul_r", "R decimator mul", controlspec.new(0, 10, "lin", 0, 1.0, ""))
  params:set_action("decimator_mul_r", function(v) engine.decimator_mul_r(v) end)
  params:add_control("decimator_add_r", "R decimator add", controlspec.new(-10, 10, "lin", 0, 0, ""))
  params:set_action("decimator_add_r", function(v) engine.decimator_add_r(v) end)

  params:add_separator("randomizer")
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

  -- Note: pitch_1..5 params seem unused by randomize() function, perhaps legacy? Kept for now.
  params:add_taper("pitch_1", "pitch (1)", -48, 48, -12, 0, "st")
  params:add_taper("pitch_2", "pitch (2)", -48, 48, -5, 0, "st")
  params:add_taper("pitch_3", "pitch (3)", -48, 48, 0, 0, "st")
  params:add_taper("pitch_4", "pitch (4)", -48, 48, 7, 0, "st")
  params:add_taper("pitch_5", "pitch (5)", -48, 48, 12, 0, "st")

  params:bang() -- Trigger initial actions for all params
end

----------------------------------------------------------------
-- 7) RANDOMIZE LOGIC
----------------------------------------------------------------

local function randomize(slot)
  local morph_ms = morph_time_options[params:get("morph_time")]
  local morph_duration = morph_ms / 1000

  local new_jitter = random_float(params:get("min_jitter"), params:get("max_jitter"))
  local new_size = random_float(params:get("min_size"), params:get("max_size"))
  local new_density = random_float(params:get("min_density"), params:get("max_density"))
  local new_spread = random_float(params:get("min_spread"), params:get("max_spread"))

  if params:get(slot.."pitch_change") == 2 then
    local new_pitch = get_random_pitch(slot)
    -- Use smooth transition for pitch if morph duration > 0
    if morph_duration > 0 then
      smooth_transition(slot.."pitch", new_pitch, morph_duration)
    else
      params:set(slot.."pitch", new_pitch)
    end
  end

  if params:get(slot.."filter_change") == 2 then
    local new_cutoff = random_float(params:get("min_filter_cutoff"), params:get("max_filter_cutoff"))
    local new_q = random_float(params:get("min_filter_q"), params:get("max_filter_q"))
    smooth_transition(slot.."filter_cutoff", new_cutoff, morph_duration)
    smooth_transition(slot.."filter_q", new_q, morph_duration)
  end

  local new_seek = math.random(0, 100)
  smooth_transition(slot.."seek", new_seek, morph_duration)
  smooth_transition(slot.."jitter", new_jitter, morph_duration)
  smooth_transition(slot.."size", new_size, morph_duration)
  smooth_transition(slot.."density", new_density, morph_duration)
  smooth_transition(slot.."spread", new_spread, morph_duration)
end

----------------------------------------------------------------
-- 8) INIT / ENGINE
----------------------------------------------------------------

local function setup_engine()
  -- Set initial values (these will be overridden by params:bang() if saved)
  engine.seek(1, 0)
  engine.gate(1, 1)

  engine.seek(2, 0)
  engine.gate(2, 1)

  engine.seek(3, 1)
  engine.gate(3, 1)

  -- Ensure params are loaded and actions triggered *before* randomizing
  -- params:bang() is now called at the end of setup_params()

  -- Set initial playhead speeds based on loaded/default param values
  for i = 1, 3 do
    update_playhead(i)
  end

  -- Optional: Apply initial randomization if desired, or rely on saved state
  -- randomize(1)
  -- randomize(2)
  -- randomize(3)
end

----------------------------------------------------------------
-- 9) SAMPLE-SELECT UI FUNCTIONS
----------------------------------------------------------------

local function refresh_dir_contents()
  item_list = list_dir_contents(current_dir)
  item_idx = util.clamp(item_idx, 1, #item_list)
end

local function open_sample_select()
  ui_mode = "sample_select"
  current_dir = root_dir
  item_idx = 1
  slot_idx = 1
  refresh_dir_contents() -- Refresh contents immediately
end

local function open_item()
  if #item_list < 1 or item_idx < 1 or item_idx > #item_list then return end
  local it = item_list[item_idx]
  if it.type == "up" or it.type == "dir" then
    current_dir = it.path
    refresh_dir_contents()
  elseif it.type == "file" then
    -- If user presses K2 on a file, load it into the current slot
     print("confirm_sample_select (K2): reading " .. it.path .. " into slot " .. slot_idx)
     engine.read(slot_idx, it.path)
     params:set(slot_idx.."sample", it.path)
     ui_mode = "main" -- Exit sample select after loading
  end
end

local function confirm_sample_select()
  if #item_list < 1 or item_idx < 1 or item_idx > #item_list then
    ui_mode = "main"
    return
  end
  local it = item_list[item_idx]
  print("confirm_sample_select: item type = " .. tostring(it.type))
  if it.type == "file" then
    print("confirm_sample_select (K3): reading " .. it.path .. " into slot " .. slot_idx)
    engine.read(slot_idx, it.path)
    params:set(slot_idx.."sample", it.path)
  elseif it.type == "dir" or it.type == "up" then
     -- If K3 pressed on a directory, open it (same as K2)
     current_dir = it.path
     refresh_dir_contents()
     return -- Stay in sample select mode
  else
    print("confirm_sample_select: selection is not a file or directory.")
  end
  ui_mode = "main" -- Exit sample select after loading or if selection invalid
end

----------------------------------------------------------------
-- 10) KEY / ENC HANDLING
----------------------------------------------------------------

function key(n, z)
  if ui_mode == "sample_select" then
    if n == 2 and z == 1 then
      open_item()  -- K2 opens folder/up OR loads selected file
    elseif n == 3 and z == 1 then
      confirm_sample_select()  -- K3 confirms file load OR opens selected folder
    end
    return
  end

  if n == 1 then
    if z == 1 then
      key1_hold = true
      clock.run(function()
        clock.sleep(1)
        if key1_hold then randomize(3) end
      end)
    else key1_hold = false end

  elseif n == 2 then
    if z == 1 then
      key2_hold = true
      clock.run(function()
        clock.sleep(1)
        if key2_hold == true then -- Check hold state hasn't changed
          open_sample_select()
          key2_hold = "sample_select" -- Update state to indicate mode change
          redraw() -- Update screen immediately
        end
      end)
    else
      if key2_hold == true then -- Short press detected
        randomize(1)
      end
      key2_hold = false -- Reset hold state regardless
    end

  elseif n == 3 then
    if z == 1 then
      key3_hold = true
      clock.run(function()
        clock.sleep(1)
        -- No long press action defined for K3
        -- if key3_hold then
        --   -- Long press action here
        -- end
      end)
    else
      if key3_hold then -- Short press detected
        randomize(2)
      end
      key3_hold = false -- Reset hold state
    end
  end
end

function enc(n, d)
  if ui_mode == "sample_select" then
    if n == 2 then
      item_idx = util.clamp(item_idx + d, 1, #item_list)
    elseif n == 3 then
      slot_idx = util.clamp(slot_idx + d, 1, 3)
    end
  else
    -- Modified encoder behavior:
    -- E1 controls volume for slot 3,
    -- E2 controls volume for slot 1,
    -- E3 controls volume for slot 2.
    if n == 1 then
      params:delta("3volume", d)
    elseif n == 2 then
      params:delta("1volume", d)
    elseif n == 3 then
      params:delta("2volume", d)
    end
  end
end

----------------------------------------------------------------
-- 11) REDRAW
----------------------------------------------------------------

function redraw()
  screen.clear()
  if ui_mode == "sample_select" then
    screen.level(15)
    screen.move(0, 10)
    -- FIX: Replace util.basename with Lua string matching
    local dir_display_name = string.match(current_dir, "([^/]+)/*$") or current_dir -- Get last component or full path
    screen.text("Browse: " .. dir_display_name)

    local top_y = 20
    local display_count = 5 -- Max items to display at once
    local scroll_offset = math.max(0, item_idx - display_count) -- Calculate scroll offset

    -- Display directory/file items
    for i = 1, display_count do
       local list_index = i + scroll_offset
       if list_index <= #item_list then
          local item = item_list[list_index]
          local yy = top_y + (i - 1) * 8
          if list_index == item_idx then screen.level(15) else screen.level(5) end
          screen.move(5, yy)
          -- Indicate directories
          local prefix = ""
          if item.type == "dir" then prefix = "/" end
          if item.type == "up" then prefix = "" end -- No prefix for [..]
          screen.text(prefix .. item.name)
       end
    end
    -- Scroll indicators
    if scroll_offset > 0 then
       screen.level(5)
       screen.move(0, top_y - 4)
       screen.line(0, top_y - 4, 3, top_y - 4)
       screen.stroke()
    end
    if scroll_offset + display_count < #item_list then
       screen.level(5)
       screen.move(0, top_y + display_count * 8 - 4)
       screen.line(0, top_y + display_count * 8 - 4, 3, top_y + display_count * 8 - 4)
       screen.stroke()
    end


    local rx = 80
    -- Display Slot selector
    screen.level(15)
    screen.move(rx, top_y - 10)
    screen.text("Load Slot:")
    for s = 1, 3 do
      local yy = top_y + (s - 1) * 8
      if s == slot_idx then screen.level(15) else screen.level(5) end
      screen.move(rx, yy)
      -- FIX: Use string.match to get basename for sample display too
      local sample_path = params:string(s.."sample")
      local sample_filename = string.match(sample_path, "([^/]+)/*$") or sample_path -- Get basename or full path
      screen.text(s .. ": " .. sample_filename) -- Show filename only
    end

    screen.level(5)
    screen.move(0, 58) -- Adjusted y position slightly
    screen.text("E2: browse | E3: select slot")
    screen.move(0, 58+8)
    screen.text("K2: open/load | K3: confirm/load")


  else -- Main UI mode
    for i = 1, 3 do
      local x = square_x[i]
      local y = square_y
      local s = square_size
      screen.level(1) -- Dark background for square
      screen.rect(x, y, s, s)
      screen.fill()

      -- Volume Indicator (Vertical bar on left)
      local vol_db = params:get(i.."volume") or 0
      local volFrac = util.linlin(-60, 20, 0, 1, vol_db) -- Map dB range to 0-1
      volFrac = util.clamp(volFrac, 0, 1)

      local bar_width = 4
      local bar_height = s * volFrac
      local bar_x = x
      local bar_y = y + s - bar_height -- Bar grows from bottom

      screen.level(4) -- Dimmed background for bar area
      screen.rect(bar_x, y, bar_width, s)
      screen.fill()

      screen.level(15) -- Bright indicator
      screen.rect(bar_x, bar_y, bar_width, bar_height)
      screen.fill()

      -- Seek Indicator (Horizontal bar on bottom)
      local seek_val = params:get(i.."seek") or 0
      local seekFrac = util.linlin(0, 100, 0, 1, seek_val) -- Map % to 0-1
      seekFrac = util.clamp(seekFrac, 0, 1)

      local hbar_height = 4
      local hbar_width = s * seekFrac
      local hbar_x = x
      local hbar_y = y + s - hbar_height

      screen.level(4) -- Dimmed background for bar area
      screen.rect(hbar_x, hbar_y, s, hbar_height)
      screen.fill()

      screen.level(15) -- Bright indicator
      screen.rect(hbar_x, hbar_y, hbar_width, hbar_height)
      screen.fill()
    end
  end
  screen.update()
end

----------------------------------------------------------------
-- 12) INIT
----------------------------------------------------------------

function init()
  setup_params() -- Setup params first to load saved values

  -- Set root directory based on loaded parameter or default
  local br = params:get("browse_root")
  if type(br) == "string" and br ~= "" then
    -- Check if the saved path exists and is a directory
    if util.file_exists(br) and is_dir(br) then
       root_dir = br
    elseif util.file_exists(file_dir_name(br)) and is_dir(file_dir_name(br)) then
       -- If saved path was a file, use its directory
       root_dir = file_dir_name(br)
       params:set("browse_root", root_dir) -- Update param if corrected
    else
       root_dir = _path.audio -- Fallback if saved path is invalid
       params:set("browse_root", root_dir) -- Update param
    end
    print("browse_root => " .. root_dir)
  else
    root_dir = _path.audio
    print("browse_root => (default) " .. root_dir)
    params:set("browse_root", root_dir) -- Ensure param has default if empty
  end
  current_dir = root_dir -- Start Browse from root

  setup_engine() -- Setup engine state based on loaded params
  setup_ui_metro() -- Start UI updates
  -- Initial redraw is handled by metro
end
