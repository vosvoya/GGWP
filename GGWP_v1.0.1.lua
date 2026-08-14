--[[
  GGWP — Group Gain Wave Proxy
  Version 1.0.1

  One-click workflow:
    1. Select one folder/group track.
    2. GGWP renders its post-fader parent-send output.
    3. The rendered item is moved onto the same group track.
    4. A stock JS Channel Mapper makes the PRINT silent without muting the item.
    5. A neutral Take Volume Envelope is created on the PRINT.
    6. The current Track Volume Envelope is frozen as BASE.
    7. While the script runs:
         RESULT(t) = BASE(t) * TAKE(t)
       which is equivalent to:
         RESULT_dB(t) = BASE_dB(t) + TAKE_dB(t)

  Requirements:
    - REAPER 7.30+
    - No SWS
    - No mandatory ReaPack dependency
    - js_ReaScriptAPI is OPTIONAL:
        * if available, GGWP uses exact global LMB state;
        * if unavailable, GGWP automatically uses the native timing fallback.

  v1.0.1 mouse-edit UX:
    - Exact mode: if reaper.JS_Mouse_GetState is available, GGWP never writes
      the generated Track Volume while LMB is held.
    - A pending Take Volume edit is committed immediately on LMB release.
    - Non-mouse Take-envelope edits still use the small 50 ms edit settle.
    - Native fallback remains available with no external dependency:
      Take settle + mouse-motion settle.
    - No hidden gfx window is used.

  v1.0.1 reliability / UX:
    - Re-running GGWP quietly terminates the old instance, commits any pending
      Take edit, and launches a fresh PRINT pass.
    - Toolbar/action toggle state reflects whether GGWP is running.
    - Previous PRINT is kept until the replacement is fully configured.
    - Silent Channel Mapper routing is watched and repaired automatically.
    - Project-tab / PRINT-timing changes stop the engine safely.

  Current v1.0.1 limitations:
    - Selected track must be a folder parent.
    - Track Volume Automation Items are not supported.
    - While GGWP is running, edit the PRINT Take Volume Envelope,
      not the generated Track Volume Envelope.
    - Old rendered WAV files are NOT deleted from disk automatically.
      This is intentional for Undo/media safety; a dedicated cleanup action
      should handle orphaned renders later.
--]]

------------------------------------------------------------
-- PROJECT / VERSION
------------------------------------------------------------

local PROJECT = select(1, reaper.EnumProjects(-1, ""))

local APP_VERSION = reaper.GetAppVersion() or ""
local MAJOR_VERSION, MINOR_VERSION = APP_VERSION:match("^(%d+)%.(%d+)")
MAJOR_VERSION = tonumber(MAJOR_VERSION) or 0
MINOR_VERSION = tonumber(MINOR_VERSION) or 0

if MAJOR_VERSION < 7
  or (MAJOR_VERSION == 7 and MINOR_VERSION < 30)
then
  reaper.ShowMessageBox(
    "GGWP v1.0.1 requires REAPER 7.30 or newer.\n\nDetected: " .. APP_VERSION,
    "GGWP v1.0.1",
    0
  )
  return
end

------------------------------------------------------------
-- CONFIG
------------------------------------------------------------

local VERSION = "1.0.1"

-- Native REAPER actions.
local ACTION_RENDER_GROUP_POST_FADER_PARENT_SEND = 42589
local ACTION_TOGGLE_TAKE_VOLUME_ENVELOPE = 40693
local ACTION_TOGGLE_TRACK_VOLUME_ACTIVE = 40052

-- Internal envelope chunk for normal Track Volume.
local TRACK_VOLUME_CHUNK = "<VOLENV2"

-- Live engine.
--
-- GGWP has two mouse-edit modes:
--
-- EXACT MODE (preferred)
--   Enabled automatically when js_ReaScriptAPI exposes JS_Mouse_GetState.
--   While LMB is held, GGWP NEVER rewrites Track Volume. If Take Volume
--   changed during that gesture, the result is committed on LMB release.
--
-- NATIVE FALLBACK
--   Used automatically when JS_Mouse_GetState is unavailable.
--   This keeps GGWP fully usable without external extensions:
--     1) Take Envelope must stop changing for EDIT_SETTLE_TIME.
--     2) Mouse position must stop changing for MOUSE_SETTLE_TIME.
--
-- EDIT_SETTLE_TIME is also used in exact mode for edits that happen while
-- LMB is not involved (keyboard/actions/etc.).
local POLL_INTERVAL = 0.025         -- 40 lightweight read checks/sec max
local EDIT_SETTLE_TIME = 0.05      -- 50 ms for non-LMB / native settling
local MOUSE_SETTLE_TIME = 0.15     -- 150 ms, native fallback only
local SAFETY_INTERVAL = 0.10       -- verify silent PRINT routing 10x/sec

local HAS_EXACT_MOUSE_STATE =
  type(reaper.JS_Mouse_GetState) == "function"

local MAX_ERROR_DB = 0.01          -- adaptive approximation accuracy
local MIN_SEGMENT_LENGTH = 0.005   -- 5 ms
local MAX_RECURSION_DEPTH = 18

-- GGWP metadata.
local EXT_PRINT = "P_EXT:GGWP_PRINT"
local EXT_SOURCE_GUID = "P_EXT:GGWP_SOURCE_TRACK_GUID"
local EXT_TAKE_VOL_GUID = "P_EXT:GGWP_TAKE_VOLUME_ENV_GUID"
local EXT_VERSION = "P_EXT:GGWP_VERSION"

-- Project-level run ownership.
local PROJ_EXT_SECTION = "GGWP"
local RUN_KEY_PREFIX = "RUN:"

-- Stock Cockos JSFX.
local MAPPER_NAMES = {
  "JS: Channel Mapper-Downmixer",
  "utility/channel_mapper"
}

------------------------------------------------------------
-- HELPERS
------------------------------------------------------------

local function error_box(text)
  reaper.ShowMessageBox(text, "GGWP v1.0.1", 0)
end

-- REAPER 7.30+ can manage deferred-script re-launch behavior.
-- We use set_action_options(3):
--   flag 1 = auto-terminate old instance on re-launch
--   flag 2 = re-launch after terminating it
-- Toolbar state is managed separately via SetToggleCommandState so cleanup
-- cannot accidentally alter the already-scheduled re-launch behavior.
local _, _, ACTION_SECTION_ID, ACTION_COMMAND_ID = reaper.get_action_context()
local function set_toolbar_state(state)
  if ACTION_SECTION_ID and ACTION_COMMAND_ID
    and ACTION_SECTION_ID >= 0 and ACTION_COMMAND_ID >= 0
  then
    reaper.SetToggleCommandState(
      ACTION_SECTION_ID,
      ACTION_COMMAND_ID,
      state
    )
    reaper.RefreshToolbar2(ACTION_SECTION_ID, ACTION_COMMAND_ID)
  end
end

local function enable_action_lifecycle()
  if type(reaper.set_action_options) == "function" then
    reaper.set_action_options(3)
  end
  set_toolbar_state(1)
end

local function disable_action_toggle()
  set_toolbar_state(0)
end

local function get_track_name(track)
  local ok, name = reaper.GetTrackName(track)
  if ok and name ~= "" then return name end
  return "(Unnamed Track)"
end

local function get_item_ext(item, key)
  local ok, value = reaper.GetSetMediaItemInfo_String(item, key, "", false)
  if not ok then return nil end
  return value
end

local function set_item_ext(item, key, value)
  return reaper.GetSetMediaItemInfo_String(item, key, value, true)
end

local function get_env_string(env, key)
  local ok, value = reaper.GetSetEnvelopeInfo_String(env, key, "", false)
  if not ok then return nil end
  return value
end

local function get_env_guid(env)
  return get_env_string(env, "GUID")
end

local function get_envelope_chunk(env)
  local ok, chunk = reaper.GetEnvelopeStateChunk(env, "", false)
  if not ok then return nil end
  return chunk
end

local function raw_to_gain(env, raw)
  local mode = reaper.GetEnvelopeScalingMode(env)
  return reaper.ScaleFromEnvelopeMode(mode, raw)
end

local function gain_to_raw(env, gain)
  local mode = reaper.GetEnvelopeScalingMode(env)
  return reaper.ScaleToEnvelopeMode(mode, gain)
end

local function evaluate_gain(env, time)
  local ok, raw = reaper.Envelope_Evaluate(env, time, 48000, 1)
  if not ok or ok == 0 then return nil end
  return raw_to_gain(env, raw)
end

local function gain_to_db(gain)
  if gain <= 0 then return -math.huge end
  return 20.0 * math.log(gain, 10)
end

local function format_db(gain)
  local db = gain_to_db(gain)
  if db == -math.huge then return "-inf dB" end
  return string.format("%.3f dB", db)
end

local function force_track_env_visible(env)
  reaper.GetSetEnvelopeInfo_String(env, "ACTIVE", "1", true)
  reaper.GetSetEnvelopeInfo_String(env, "VISIBLE", "1", true)
  reaper.GetSetEnvelopeInfo_String(env, "SHOWLANE", "1", true)
end

local function force_take_env_visible(env)
  reaper.GetSetEnvelopeInfo_String(env, "ACTIVE", "1", true)
  reaper.GetSetEnvelopeInfo_String(env, "VISIBLE", "1", true)
end

local function collect_track_guids()
  local out = {}
  local count = reaper.CountTracks(PROJECT)
  for i = 0, count - 1 do
    local tr = reaper.GetTrack(PROJECT, i)
    if tr then
      out[reaper.GetTrackGUID(tr)] = true
    end
  end
  return out
end

local function find_new_tracks(old_guids)
  local out = {}
  local count = reaper.CountTracks(PROJECT)
  for i = 0, count - 1 do
    local tr = reaper.GetTrack(PROJECT, i)
    if tr then
      local guid = reaper.GetTrackGUID(tr)
      if not old_guids[guid] then
        out[#out + 1] = tr
      end
    end
  end
  return out
end

------------------------------------------------------------
-- VALIDATE SOURCE GROUP
------------------------------------------------------------

if reaper.CountSelectedTracks(PROJECT) ~= 1 then
  error_box("Select exactly one folder/group track and run GGWP again.")
  return
end

local source_track = reaper.GetSelectedTrack(PROJECT, 0)
if not source_track then
  error_box("Could not get the selected track.")
  return
end

local folder_depth = math.floor(
  reaper.GetMediaTrackInfo_Value(source_track, "I_FOLDERDEPTH")
)

if folder_depth ~= 1 then
  error_box(
    "The selected track is not a folder parent.\n\n" ..
    "GGWP v1.0.0 expects a summing folder/group track."
  )
  return
end

local source_name = get_track_name(source_track)
local source_guid = reaper.GetTrackGUID(source_track)

-- From this point the script becomes the active GGWP instance.
-- Re-running the same action quietly terminates this instance first,
-- commits any pending Take edit, and then starts a fresh pass.
enable_action_lifecycle()

------------------------------------------------------------
-- RUN OWNERSHIP
--
-- Starting GGWP again on the same group supersedes the
-- previous live engine on that group.
--
-- This lock is session-only: it does not dirty/save the project.
------------------------------------------------------------

local run_key =
  RUN_KEY_PREFIX ..
  tostring(PROJECT) ..
  ":" ..
  source_guid

local run_token = reaper.genGuid("")

reaper.SetExtState(
  PROJ_EXT_SECTION,
  run_key,
  run_token,
  false
)

local function owns_run_token()
  return
    reaper.GetExtState(
      PROJ_EXT_SECTION,
      run_key
    )
    == run_token
end

local function clear_run_token_if_owned()
  if owns_run_token() then
    reaper.DeleteExtState(
      PROJ_EXT_SECTION,
      run_key,
      false
    )
  end
end

------------------------------------------------------------
-- SETUP UNDO / SAFETY
------------------------------------------------------------

reaper.Undo_BeginBlock2(PROJECT)
reaper.PreventUIRefresh(1)

local setup_open = true
local source_mute_before =
  reaper.GetMediaTrackInfo_Value(source_track, "B_MUTE")

-- Forward declaration so setup_fail() can clean it up
-- even if failure happens after the item was moved.
local print_item = nil

-- Previous GGWP PRINTs are staged, not deleted immediately.
-- They stay available for rollback if the new render/setup fails.
local old_prints = {}

local function finish_setup_undo(name)
  if setup_open then
    reaper.PreventUIRefresh(-1)
    reaper.Undo_EndBlock2(PROJECT, name, -1)
    setup_open = false
  end
end

local function setup_fail(message, new_tracks_to_delete)
  if reaper.ValidatePtr2(PROJECT, source_track, "MediaTrack*") then
    reaper.SetMediaTrackInfo_Value(
      source_track,
      "B_MUTE",
      source_mute_before
    )
  end

  if print_item
    and reaper.ValidatePtr2(PROJECT, print_item, "MediaItem*")
  then
    local item_track = reaper.GetMediaItemTrack(print_item)
    if item_track then
      reaper.DeleteTrackMediaItem(item_track, print_item)
    end
  end

  if new_tracks_to_delete then
    for _, tr in ipairs(new_tracks_to_delete) do
      if reaper.ValidatePtr2(PROJECT, tr, "MediaTrack*") then
        reaper.DeleteTrack(tr)
      end
    end
  end

  -- Roll back temporary safety-muting of the previous PRINT(s).
  for _, old in ipairs(old_prints) do
    if old.item
      and reaper.ValidatePtr2(PROJECT, old.item, "MediaItem*")
    then
      reaper.SetMediaItemInfo_Value(
        old.item,
        "B_MUTE",
        old.mute
      )
    end
  end

  finish_setup_undo("GGWP v1.0.0 - Setup failed")
  clear_run_token_if_owned()
  disable_action_toggle()
  reaper.UpdateArrange()
  error_box(message)
end

------------------------------------------------------------
-- ENSURE NORMAL TRACK VOLUME ENVELOPE EXISTS
------------------------------------------------------------

reaper.SetOnlyTrackSelected(source_track)

local track_env = reaper.GetTrackEnvelopeByChunkName(
  source_track,
  TRACK_VOLUME_CHUNK
)

if not track_env then
  -- Only call the toggle when the envelope does not exist.
  reaper.Main_OnCommand(ACTION_TOGGLE_TRACK_VOLUME_ACTIVE, 0)

  track_env = reaper.GetTrackEnvelopeByChunkName(
    source_track,
    TRACK_VOLUME_CHUNK
  )
end

if not track_env then
  setup_fail("Could not create/find the normal Track Volume Envelope.")
  return
end

force_track_env_visible(track_env)

local automation_item_count =
  reaper.CountAutomationItems(track_env)

if automation_item_count > 0 then
  setup_fail(
    "GGWP v1.0.0 does not yet support Track Volume Automation Items.\n\n" ..
    "Found: " .. tostring(automation_item_count) ..
    "\n\nOrdinary envelope points are supported."
  )
  return
end

------------------------------------------------------------
-- FREEZE CURRENT TRACK VOLUME AS BASE
--
-- Captured BEFORE the new render, so the rendered waveform
-- already contains exactly this BASE.
------------------------------------------------------------

local BASE_CHUNK = get_envelope_chunk(track_env)

if not BASE_CHUNK then
  setup_fail("Could not capture the Track Volume BASE.")
  return
end

------------------------------------------------------------
-- STAGE PREVIOUS GGWP PRINT(S)
--
-- v1.0.0 reliability change:
-- Do NOT delete the old visual PRINT before the replacement is known-good.
-- Temporarily mute it during rendering so it can never enter its own render.
-- If setup fails, setup_fail() restores the old PRINT exactly as it was.
------------------------------------------------------------

local old_print_count = 0

for i = reaper.CountTrackMediaItems(source_track) - 1, 0, -1 do
  local item = reaper.GetTrackMediaItem(source_track, i)

  if item
    and get_item_ext(item, EXT_PRINT) == "1"
  then
    old_prints[#old_prints + 1] = {
      item = item,
      mute = reaper.GetMediaItemInfo_Value(item, "B_MUTE")
    }

    reaper.SetMediaItemInfo_Value(item, "B_MUTE", 1)
    old_print_count = old_print_count + 1
  end
end
------------------------------------------------------------
-- RENDER CURRENT GROUP OUTPUT
------------------------------------------------------------

local track_guids_before = collect_track_guids()

reaper.SetOnlyTrackSelected(source_track)

reaper.Main_OnCommand(
  ACTION_RENDER_GROUP_POST_FADER_PARENT_SEND,
  0
)

local new_tracks = find_new_tracks(track_guids_before)

-- Native action mutes the source; restore its previous state.
if reaper.ValidatePtr2(PROJECT, source_track, "MediaTrack*") then
  reaper.SetMediaTrackInfo_Value(source_track, "B_MUTE", source_mute_before)
end

if #new_tracks ~= 1 then
  setup_fail(
    "GGWP expected exactly one rendered stem track, but found " ..
    tostring(#new_tracks) .. ".",
    new_tracks
  )
  return
end

local stem_track = new_tracks[1]
local stem_item_count = reaper.CountTrackMediaItems(stem_track)

if stem_item_count ~= 1 then
  setup_fail(
    "GGWP expected exactly one rendered item, but the stem contains " ..
    tostring(stem_item_count) .. ".",
    new_tracks
  )
  return
end

print_item = reaper.GetTrackMediaItem(stem_track, 0)
if not print_item then
  setup_fail("Could not get the rendered PRINT item.", new_tracks)
  return
end

-- Safety while moving/configuring.
reaper.SetMediaItemInfo_Value(print_item, "B_MUTE", 1)

if not reaper.MoveMediaItemToTrack(print_item, source_track) then
  setup_fail("Could not move the rendered PRINT onto the group track.", new_tracks)
  return
end

-- The item is already safely moved away.
reaper.DeleteTrack(stem_track)

local print_take = reaper.GetActiveTake(print_item)
if not print_take then
  setup_fail("The rendered PRINT has no active take.")
  return
end

reaper.GetSetMediaItemTakeInfo_String(
  print_take,
  "P_NAME",
  "GGWP PRINT - " .. source_name,
  true
)

------------------------------------------------------------
-- CONFIGURE SILENT CHANNEL MAPPER
------------------------------------------------------------

local function find_mapper_fx(take)
  local count = reaper.TakeFX_GetCount(take)
  for fx = 0, count - 1 do
    local ok, name = reaper.TakeFX_GetFXName(take, fx)
    if ok and name and name:find("Channel Mapper-Downmixer", 1, true) then
      return fx
    end
  end
  return -1
end

local function force_mapper_pinflags_zero_out(item)
  local ok, chunk = reaper.GetItemStateChunk(item, "", false)
  if not ok then
    return false, "Could not read PRINT item state."
  end

  local replacements
  chunk, replacements = chunk:gsub(
    "PINFLAGS%s+%-?%d+",
    "PINFLAGS 1",
    1
  )

  if replacements ~= 1 then
    return false, "Could not uniquely set Channel Mapper PINFLAGS."
  end

  if not reaper.SetItemStateChunk(item, chunk, false) then
    return false, "Could not write PRINT item state."
  end

  return true
end

local function mapper_pinflags_zero_out(item)
  local ok, chunk = reaper.GetItemStateChunk(item, "", false)
  if not ok then
    return false
  end

  local flags = tonumber(chunk:match("PINFLAGS%s+(%-?%d+)"))
  if not flags then
    return false
  end

  return (flags & 1) == 1
end

local function mapper_outputs_are_disconnected(take, fx)
  local _, _, outputs = reaper.TakeFX_GetIOSize(take, fx)
  if not outputs or outputs < 1 then
    return false
  end

  for pin = 0, outputs - 1 do
    local low, high = reaper.TakeFX_GetPinMappings(take, fx, 1, pin)
    if low ~= 0 or high ~= 0 then
      return false
    end
  end

  return true
end

local function mapper_is_safe(item)
  local take = reaper.GetActiveTake(item)
  if not take then
    return false, "PRINT has no active take."
  end

  local fx_count = reaper.TakeFX_GetCount(take)
  local fx = find_mapper_fx(take)
  if fx < 0 then
    return false, "Channel Mapper is missing."
  end

  -- GGWP PRINT is an internal visual proxy. To make PINFLAGS state parsing
  -- unambiguous and guarantee that nothing can generate audio after the
  -- silencing mapper, the mapper must be the ONLY Take FX.
  if fx_count ~= 1 or fx ~= 0 then
    return false, "Unexpected Take FX exist on the GGWP PRINT."
  end

  if not reaper.TakeFX_GetEnabled(take, fx) then
    return false, "Channel Mapper is bypassed."
  end

  if reaper.TakeFX_GetOffline(take, fx) then
    return false, "Channel Mapper is offline."
  end

  if not mapper_outputs_are_disconnected(take, fx) then
    return false, "Channel Mapper output routing changed."
  end

  if not mapper_pinflags_zero_out(item) then
    return false, "Channel Mapper is not in Zero-out mode."
  end

  return true
end

local function repair_mapper_safety(item)
  -- Fail safe first: a dark PRINT for a fraction of a second is preferable
  -- to ever allowing the rendered group to double the real group output.
  reaper.SetMediaItemInfo_Value(item, "B_MUTE", 1)

  local take = reaper.GetActiveTake(item)
  if not take then
    return false, "PRINT has no active take."
  end

  local fx = find_mapper_fx(take)
  local fx_count = reaper.TakeFX_GetCount(take)

  if fx < 0 then
    -- Only auto-recreate when there are no unknown Take FX.
    if fx_count ~= 0 then
      return false, "Channel Mapper is missing and unknown Take FX exist."
    end

    for _, mapper_name in ipairs(MAPPER_NAMES) do
      fx = reaper.TakeFX_AddByName(take, mapper_name, 1)
      if fx >= 0 then break end
    end

    if fx < 0 then
      return false, "Could not recreate Channel Mapper."
    end
  end

  if reaper.TakeFX_GetCount(take) ~= 1 or fx ~= 0 then
    return false, "Unexpected Take FX exist on the GGWP PRINT."
  end

  reaper.TakeFX_SetEnabled(take, fx, true)
  reaper.TakeFX_SetOffline(take, fx, false)

  local _, _, outputs = reaper.TakeFX_GetIOSize(take, fx)
  for pin = 0, outputs - 1 do
    if not reaper.TakeFX_SetPinMappings(take, fx, 1, pin, 0, 0) then
      return false, "Could not restore Channel Mapper output routing."
    end
  end

  local ok, err = force_mapper_pinflags_zero_out(item)
  if not ok then
    return false, err
  end

  local safe, reason = mapper_is_safe(item)
  if not safe then
    return false, reason
  end

  reaper.SetMediaItemInfo_Value(item, "B_MUTE", 0)
  reaper.UpdateItemInProject(item)
  return true
end

-- Fresh stem PRINT should not contain any Take FX.
if reaper.TakeFX_GetCount(print_take) ~= 0 then
  setup_fail(
    "Unexpected Take FX were found on the freshly rendered PRINT.\n\n" ..
    "GGWP aborted to avoid changing the wrong FX."
  )
  return
end

local mapper_fx = -1

for _, mapper_name in ipairs(MAPPER_NAMES) do
  mapper_fx = reaper.TakeFX_AddByName(print_take, mapper_name, 1)
  if mapper_fx >= 0 then break end
end

if mapper_fx < 0 then
  setup_fail(
    "Could not add the stock Cockos JS: Channel Mapper-Downmixer."
  )
  return
end

local _, _, mapper_outputs = reaper.TakeFX_GetIOSize(print_take, mapper_fx)

for pin = 0, mapper_outputs - 1 do
  local ok = reaper.TakeFX_SetPinMappings(
    print_take,
    mapper_fx,
    1,      -- output
    pin,
    0,
    0
  )

  if not ok then
    setup_fail("Could not disconnect a Channel Mapper output pin.")
    return
  end
end

local pinflags_ok, pinflags_error =
  force_mapper_pinflags_zero_out(print_item)

if not pinflags_ok then
  setup_fail(pinflags_error)
  return
end

-- Re-fetch after item state chunk write.
print_take = reaper.GetActiveTake(print_item)
mapper_fx = find_mapper_fx(print_take)

if mapper_fx < 0 then
  setup_fail("Channel Mapper disappeared after configuring its state.")
  return
end

local _, _, verify_outputs = reaper.TakeFX_GetIOSize(print_take, mapper_fx)

for pin = 0, verify_outputs - 1 do
  local low, high = reaper.TakeFX_GetPinMappings(
    print_take,
    mapper_fx,
    1,
    pin
  )

  if low ~= 0 or high ~= 0 then
    setup_fail("Channel Mapper output verification failed.")
    return
  end
end

-- PRINT is now silent because the mapper zeroes all unmapped outputs.
reaper.SetMediaItemInfo_Value(print_item, "B_MUTE", 0)

------------------------------------------------------------
-- MARK PRINT AS GGWP
------------------------------------------------------------

set_item_ext(print_item, EXT_PRINT, "1")
set_item_ext(print_item, EXT_SOURCE_GUID, source_guid)
set_item_ext(print_item, EXT_VERSION, VERSION)

------------------------------------------------------------
-- CREATE / IDENTIFY TAKE VOLUME ENVELOPE
-- LANGUAGE-INDEPENDENT
------------------------------------------------------------

reaper.SetMediaItemTakeInfo_Value(print_take, "D_VOL", 1.0)

local function snapshot_take_envelopes(take)
  local snapshot = {}
  local count = reaper.CountTakeEnvelopes(take)

  for i = 0, count - 1 do
    local env = reaper.GetTakeEnvelope(take, i)
    if env then
      local guid = get_env_guid(env)
      if guid then
        snapshot[guid] = {
          env = env,
          active = get_env_string(env, "ACTIVE"),
          visible = get_env_string(env, "VISIBLE"),
          chunk = get_envelope_chunk(env) or ""
        }
      end
    end
  end

  return snapshot
end

local function detect_changed_take_env(before, after)
  local created = {}

  for guid, data in pairs(after) do
    if not before[guid] then
      created[#created + 1] = data.env
    end
  end

  if #created == 1 then
    return created[1]
  end

  local changed = {}

  for guid, after_data in pairs(after) do
    local before_data = before[guid]
    if before_data then
      if before_data.active ~= after_data.active
        or before_data.visible ~= after_data.visible
        or before_data.chunk ~= after_data.chunk
      then
        changed[#changed + 1] = after_data.env
      end
    end
  end

  if #changed == 1 then
    return changed[1]
  end

  return nil
end

-- Ensure only PRINT item is selected for the native Take action.
for i = 0, reaper.CountMediaItems(PROJECT) - 1 do
  local item = reaper.GetMediaItem(PROJECT, i)
  if item then
    reaper.SetMediaItemSelected(item, item == print_item)
  end
end

local take_before = snapshot_take_envelopes(print_take)

reaper.Main_OnCommand(ACTION_TOGGLE_TAKE_VOLUME_ENVELOPE, 0)

print_take = reaper.GetActiveTake(print_item)
local take_after = snapshot_take_envelopes(print_take)

local take_env = detect_changed_take_env(take_before, take_after)

if not take_env then
  setup_fail(
    "Could not identify the Take Volume Envelope after native Action 40693."
  )
  return
end

force_take_env_visible(take_env)

------------------------------------------------------------
-- FORCE TAKE VOLUME TO A FRESH FLAT 0 dB
------------------------------------------------------------

local print_item_length =
  reaper.GetMediaItemInfo_Value(print_item, "D_LENGTH")

reaper.DeleteEnvelopePointRange(
  take_env,
  -1.0,
  print_item_length + 1.0
)

local unity_raw = gain_to_raw(take_env, 1.0)

reaper.InsertEnvelopePoint(
  take_env,
  0.0,
  unity_raw,
  0,
  0.0,
  false,
  false
)

reaper.Envelope_SortPoints(take_env)

local take_env_guid = get_env_guid(take_env)

if not take_env_guid or take_env_guid == "" then
  setup_fail("REAPER did not return a GUID for the Take Volume Envelope.")
  return
end

set_item_ext(print_item, EXT_TAKE_VOL_GUID, take_env_guid)

------------------------------------------------------------
-- COMMIT REPLACEMENT: REMOVE OLD GGWP PRINT(S)
--
-- The new PRINT is now rendered, silent, tagged, and has a fresh Take
-- Volume Envelope. Only now is it safe to discard the previous visual proxy.
------------------------------------------------------------

for _, old in ipairs(old_prints) do
  if old.item
    and reaper.ValidatePtr2(PROJECT, old.item, "MediaItem*")
  then
    local old_track = reaper.GetMediaItemTrack(old.item)
    if old_track then
      reaper.DeleteTrackMediaItem(old_track, old.item)
    end
  end
end

------------------------------------------------------------
-- FINAL SETUP UI
------------------------------------------------------------

force_track_env_visible(track_env)

reaper.SetOnlyTrackSelected(source_track)

for i = 0, reaper.CountMediaItems(PROJECT) - 1 do
  local item = reaper.GetMediaItem(PROJECT, i)
  if item then
    reaper.SetMediaItemSelected(item, item == print_item)
  end
end

reaper.UpdateItemInProject(print_item)
reaper.TrackList_AdjustWindows(false)
reaper.UpdateTimeline()
reaper.UpdateArrange()

finish_setup_undo("GGWP v1.0.1 - Create Group Gain Wave Proxy")

------------------------------------------------------------
-- LIVE ENGINE SETUP
------------------------------------------------------------

local item_start =
  reaper.GetMediaItemInfo_Value(print_item, "D_POSITION")

local item_length =
  reaper.GetMediaItemInfo_Value(print_item, "D_LENGTH")

local item_end = item_start + item_length

if item_length <= 0 then
  clear_run_token_if_owned()
  disable_action_toggle()
  error_box("GGWP PRINT has zero length.")
  return
end

local function find_take_env_by_guid(take, target_guid)
  local count = reaper.CountTakeEnvelopes(take)

  for i = 0, count - 1 do
    local env = reaper.GetTakeEnvelope(take, i)
    if env and get_env_guid(env) == target_guid then
      return env
    end
  end

  return nil
end

-- Re-resolve once from GUID after all setup/chunk operations.
print_take = reaper.GetActiveTake(print_item)
take_env = find_take_env_by_guid(print_take, take_env_guid)

if not take_env then
  clear_run_token_if_owned()
  disable_action_toggle()
  error_box(
    "Take Volume Envelope could not be re-resolved by GUID after setup."
  )
  return
end

------------------------------------------------------------
-- ADAPTIVE RESULT ENGINE
------------------------------------------------------------

local evaluation_cache = {}

local function clear_evaluation_cache()
  evaluation_cache = {}
end

local function collect_anchor_times()
  local times = {}
  local seen = {}

  local function add_time(t)
    if t < item_start then t = item_start end
    if t > item_end then t = item_end end

    local key = string.format("%.12f", t)

    if not seen[key] then
      seen[key] = true
      times[#times + 1] = t
    end
  end

  add_time(item_start)
  add_time(item_end)

  local track_points = reaper.CountEnvelopePoints(track_env)

  for i = 0, track_points - 1 do
    local ok, time = reaper.GetEnvelopePoint(track_env, i)
    if ok and time >= item_start and time <= item_end then
      add_time(time)
    end
  end

  local take_points = reaper.CountEnvelopePoints(take_env)

  for i = 0, take_points - 1 do
    local ok, local_time = reaper.GetEnvelopePoint(take_env, i)
    if ok then
      local project_time = item_start + local_time
      if project_time >= item_start and project_time <= item_end then
        add_time(project_time)
      end
    end
  end

  table.sort(times)
  return times
end

local function evaluate_exact_result(project_time)
  local key = string.format("%.12f", project_time)

  if evaluation_cache[key] then
    return evaluation_cache[key]
  end

  local base_gain = evaluate_gain(track_env, project_time)
  if not base_gain then return nil end

  local take_time = project_time - item_start
  local correction_gain = evaluate_gain(take_env, take_time)
  if not correction_gain then return nil end

  local result_gain = base_gain * correction_gain
  local result_raw = gain_to_raw(track_env, result_gain)

  local point = {
    time = project_time,
    raw = result_raw,
    gain = result_gain
  }

  evaluation_cache[key] = point
  return point
end

local function interpolation_error_db(left, right, actual)
  local duration = right.time - left.time
  if duration <= 0 then return 0.0 end

  local fraction = (actual.time - left.time) / duration

  -- Linear envelope shape interpolates raw envelope values.
  local predicted_raw =
    left.raw + (right.raw - left.raw) * fraction

  local predicted_gain = raw_to_gain(track_env, predicted_raw)

  if predicted_gain <= 0 or actual.gain <= 0 then
    if predicted_gain == actual.gain then return 0.0 end
    return math.huge
  end

  return math.abs(
    20.0 * math.log(actual.gain / predicted_gain, 10)
  )
end

local function subdivide_segment(left, right, depth, output)
  local duration = right.time - left.time

  if duration <= MIN_SEGMENT_LENGTH
    or depth >= MAX_RECURSION_DEPTH
  then
    output[#output + 1] = right
    return
  end

  local p25 = evaluate_exact_result(left.time + duration * 0.25)
  local p50 = evaluate_exact_result(left.time + duration * 0.50)
  local p75 = evaluate_exact_result(left.time + duration * 0.75)

  if not p25 or not p50 or not p75 then
    output[#output + 1] = right
    return
  end

  local max_error = math.max(
    interpolation_error_db(left, right, p25),
    interpolation_error_db(left, right, p50),
    interpolation_error_db(left, right, p75)
  )

  if max_error <= MAX_ERROR_DB then
    output[#output + 1] = right
    return
  end

  subdivide_segment(left, p50, depth + 1, output)
  subdivide_segment(p50, right, depth + 1, output)
end

local function build_result_points()
  clear_evaluation_cache()

  local anchor_times = collect_anchor_times()
  if #anchor_times < 2 then return nil end

  local first = evaluate_exact_result(anchor_times[1])
  if not first then return nil end

  local output = { first }

  for i = 1, #anchor_times - 1 do
    local left = evaluate_exact_result(anchor_times[i])
    local right = evaluate_exact_result(anchor_times[i + 1])

    if not left or not right then
      return nil
    end

    subdivide_segment(left, right, 0, output)
  end

  return output
end

local function restore_base()
  local current_env = reaper.GetTrackEnvelopeByChunkName(
    source_track,
    TRACK_VOLUME_CHUNK
  )

  if not current_env then return false end

  if not reaper.SetEnvelopeStateChunk(
    current_env,
    BASE_CHUNK,
    false
  ) then
    return false
  end

  track_env = reaper.GetTrackEnvelopeByChunkName(
    source_track,
    TRACK_VOLUME_CHUNK
  )

  if not track_env then return false end

  force_track_env_visible(track_env)
  return true
end

local function take_is_neutral()
  local count = reaper.CountEnvelopePoints(take_env)

  for i = 0, count - 1 do
    local ok, _, raw = reaper.GetEnvelopePoint(take_env, i)
    if ok then
      local gain = raw_to_gain(take_env, raw)
      if math.abs(gain - 1.0) > 1e-10 then
        return false
      end
    end
  end

  local start_gain = evaluate_gain(take_env, 0.0)
  local end_gain = evaluate_gain(take_env, item_length)

  if not start_gain or not end_gain then return false end

  return
    math.abs(start_gain - 1.0) <= 1e-10
    and
    math.abs(end_gain - 1.0) <= 1e-10
end

local function write_result(result_points)
  reaper.DeleteEnvelopePointRange(
    track_env,
    item_start,
    item_end + 0.000000001
  )

  for _, point in ipairs(result_points) do
    reaper.InsertEnvelopePoint(
      track_env,
      point.time,
      point.raw,
      0,      -- linear
      0.0,
      false,
      true    -- noSort
    )
  end

  reaper.Envelope_SortPoints(track_env)
  force_track_env_visible(track_env)
end

local sync_count = 0
local last_result_points = 0
local live_changed = false
local superseded = false
local stop_reason = nil

-- IMPORTANT UX RULE:
-- Never rewrite Track Volume during an active Take Volume mouse drag.
-- The Take envelope itself redraws the PRINT waveform natively, so GGWP can
-- wait until the edit gesture is finished before generating Group Volume.
--
-- If js_ReaScriptAPI is present, JS_Mouse_GetState gives the exact global
-- LMB state. Otherwise the proven native mouse-motion fallback is used.
local pending_sync = false
local last_take_change_time = 0.0

-- Exact-mode mouse state.
local previous_left_down = false
if HAS_EXACT_MOUSE_STATE then
  previous_left_down = reaper.JS_Mouse_GetState(1) ~= 0
end

-- Native fallback mouse state.
local last_mouse_x, last_mouse_y = reaper.GetMousePosition()
local last_mouse_move_time = reaper.time_precise()

local last_safety_check_time = reaper.time_precise()
local safety_repair_count = 0

local initial_take_playrate =
  reaper.GetMediaItemTakeInfo_Value(print_take, "D_PLAYRATE")
local initial_take_startoffs =
  reaper.GetMediaItemTakeInfo_Value(print_take, "D_STARTOFFS")

local function synchronize()
  reaper.PreventUIRefresh(1)

  if not restore_base() then
    reaper.PreventUIRefresh(-1)
    return false
  end

  if take_is_neutral() then
    last_result_points = reaper.CountEnvelopePoints(track_env)
  else
    local result_points = build_result_points()

    if not result_points then
      reaper.PreventUIRefresh(-1)
      return false
    end

    write_result(result_points)
    last_result_points = #result_points
  end

  sync_count = sync_count + 1
  live_changed = true

  reaper.PreventUIRefresh(-1)
  -- UpdateArrange is enough for the generated Track Volume lane and is
  -- less invasive during envelope editing than forcing a full timeline refresh.
  reaper.UpdateArrange()

  return true
end

------------------------------------------------------------
-- LIVE LOOP
------------------------------------------------------------

local last_take_state = get_envelope_chunk(take_env)

if not last_take_state then
  clear_run_token_if_owned()
  disable_action_toggle()
  error_box("Could not read the Take Volume Envelope state.")
  return
end

local last_poll_time = reaper.time_precise()

local function loop()
  if not owns_run_token() then
    superseded = true
    stop_reason = "Superseded by a newer GGWP run."
    return
  end

  if not reaper.ValidatePtr2(PROJECT, print_item, "MediaItem*") then
    stop_reason = "PRINT item was removed."
    return
  end

  if not reaper.ValidatePtr2(PROJECT, source_track, "MediaTrack*") then
    stop_reason = "Source group was removed."
    return
  end

  if not reaper.ValidatePtr2(PROJECT, take_env, "TrackEnvelope*") then
    -- Self-heal once from stored GUID.
    local current_take = reaper.GetActiveTake(print_item)
    if current_take then
      take_env = find_take_env_by_guid(current_take, take_env_guid)
    end

    if not take_env then
      stop_reason = "Take Volume Envelope became unavailable."
      return
    end
  end

  -- v1.0.0 safety: do not keep a hidden live engine running after the user
  -- changes project tabs. The generated result is already committed.
  local active_project = select(1, reaper.EnumProjects(-1, ""))
  if active_project ~= PROJECT then
    stop_reason = "Active project tab changed."
    return
  end

  local current_take = reaper.GetActiveTake(print_item)
  if not current_take then
    stop_reason = "PRINT active take became unavailable."
    return
  end

  local current_playrate =
    reaper.GetMediaItemTakeInfo_Value(current_take, "D_PLAYRATE")
  local current_startoffs =
    reaper.GetMediaItemTakeInfo_Value(current_take, "D_STARTOFFS")

  if math.abs(current_playrate - initial_take_playrate) > 1e-12
    or math.abs(current_startoffs - initial_take_startoffs) > 1e-12
  then
    stop_reason = "PRINT take timing changed; live engine stopped for safety."
    return
  end

  -- PRINT movement would invalidate the project-time mapping.
  local current_start =
    reaper.GetMediaItemInfo_Value(print_item, "D_POSITION")
  local current_length =
    reaper.GetMediaItemInfo_Value(print_item, "D_LENGTH")

  if math.abs(current_start - item_start) > 1e-9
    or math.abs(current_length - item_length) > 1e-9
  then
    stop_reason = "PRINT item position/length changed; live engine stopped for safety."
    return
  end

  local now = reaper.time_precise()

  -- Silent-PRINT watchdog. If the Channel Mapper is bypassed, deleted,
  -- remapped, put offline, or switched away from Zero-out mode, GGWP first
  -- mutes the PRINT, then repairs the safety routing before unmuting it.
  if now - last_safety_check_time >= SAFETY_INTERVAL then
    last_safety_check_time = now

    local safe, safety_reason = mapper_is_safe(print_item)
    if not safe then
      local repaired, repair_reason = repair_mapper_safety(print_item)

      if not repaired then
        -- repair_mapper_safety() mutes first and leaves it muted on failure.
        stop_reason =
          "PRINT safety watchdog stopped GGWP: " ..
          tostring(repair_reason or safety_reason)
        return
      end

      safety_repair_count = safety_repair_count + 1
    end
  end

  if now - last_poll_time >= POLL_INTERVAL then
    last_poll_time = now

    --------------------------------------------------------
    -- MOUSE STATE
    --------------------------------------------------------

    local left_down = false
    local left_released = false

    if HAS_EXACT_MOUSE_STATE then
      -- js_ReaScriptAPI exact mode.
      --
      -- Mask 1 = left mouse button. This works globally in REAPER,
      -- including Arrange/Envelope editing, without a gfx window.
      left_down = reaper.JS_Mouse_GetState(1) ~= 0
      left_released = previous_left_down and not left_down
    else
      -- Dependency-free fallback: track mouse movement only.
      local mouse_x, mouse_y = reaper.GetMousePosition()

      if mouse_x ~= last_mouse_x or mouse_y ~= last_mouse_y then
        last_mouse_x = mouse_x
        last_mouse_y = mouse_y
        last_mouse_move_time = now
      end
    end

    --------------------------------------------------------
    -- TAKE ENVELOPE CHANGE DETECTION
    --------------------------------------------------------

    local current_state = get_envelope_chunk(take_env)

    if not current_state then
      stop_reason = "Could not read Take Volume Envelope state."
      return
    end

    if current_state ~= last_take_state then
      -- A drag can change the chunk many times per second.
      -- Record only the latest state; never rebuild Group Volume here.
      last_take_state = current_state
      pending_sync = true
      last_take_change_time = now
    end

    --------------------------------------------------------
    -- COMMIT POLICY
    --------------------------------------------------------

    if pending_sync then
      local should_sync = false

      if HAS_EXACT_MOUSE_STATE then
        if left_down then
          -- Exact rule: while LMB is physically held, GGWP must not write
          -- Track Volume. This is what prevents points detaching from mouse.
          should_sync = false

        elseif left_released then
          -- The Take changed during this mouse gesture and LMB has just
          -- transitioned DOWN -> UP. Commit immediately.
          should_sync = true

        elseif not previous_left_down
          and (now - last_take_change_time) >= EDIT_SETTLE_TIME
        then
          -- Take changed without an LMB gesture (keyboard/action/etc.).
          -- Preserve a tiny trailing-edge settle for those edits.
          should_sync = true
        end

      else
        -- Native dependency-free fallback.
        should_sync =
          (now - last_take_change_time) >= EDIT_SETTLE_TIME
          and
          (now - last_mouse_move_time) >= MOUSE_SETTLE_TIME
      end

      if should_sync then
        if not synchronize() then
          stop_reason = "Synchronization failed."
          return
        end

        pending_sync = false
      end
    end

    if HAS_EXACT_MOUSE_STATE then
      previous_left_down = left_down
    end
  end

  reaper.defer(loop)
end

------------------------------------------------------------
-- CLEANUP
------------------------------------------------------------

local function cleanup()
  -- If the user terminates GGWP immediately after an edit, do not leave the
  -- final Take change unapplied. Skip this when superseded by a newer run.
  if pending_sync and not superseded
    and reaper.ValidatePtr2(PROJECT, print_item, "MediaItem*")
    and reaper.ValidatePtr2(PROJECT, source_track, "MediaTrack*")
    and reaper.ValidatePtr2(PROJECT, take_env, "TrackEnvelope*")
  then
    synchronize()
    pending_sync = false
  end

  clear_run_token_if_owned()
  disable_action_toggle()

  reaper.UpdateTimeline()
  reaper.UpdateArrange()

  -- Deferred ReaScripts do not create an undo point
  -- automatically. Commit the live paint as one undo state
  -- when this instance ends normally.
  if live_changed and not superseded then
    reaper.Undo_OnStateChangeEx2(
      PROJECT,
      "GGWP v1.0.1 - Live gain paint",
      -1,
      -1
    )
  end

end

reaper.atexit(cleanup)

------------------------------------------------------------
-- START
------------------------------------------------------------

reaper.defer(loop)
