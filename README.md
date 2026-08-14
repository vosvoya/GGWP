# GGWP — Group Gain Wave Proxy

GGWP is a REAPER ReaScript utility for visual group gain riding via a silent rendered proxy waveform.

It renders the selected folder/group track, places the rendered item back on that group as a silent visual `PRINT`, and lets you ride a Take Volume Envelope while GGWP writes the combined result to the group Track Volume Envelope.

```text
RESULT(t) = BASE(t) × TAKE(t)
RESULT_dB(t) = BASE_dB(t) + TAKE_dB(t)
```

## Requirements

- REAPER 7.30 or newer
- No SWS dependency
- No mandatory ReaPack dependency
- Optional: [js_ReaScriptAPI](https://github.com/juliansader/ReaExtensions/tree/master/js_ReaScriptAPI) for exact left-mouse-button release detection

Without js_ReaScriptAPI, GGWP automatically uses its native timing fallback.

## Installation

1. Download [`GGWP_v1.0.1.lua`](GGWP_v1.0.1.lua), or download it from the latest GitHub release.
2. In REAPER, open **Actions → Show action list**.
3. Click **New action → Load ReaScript**.
4. Select the downloaded Lua file.
5. Optionally assign it to a keyboard shortcut or toolbar button.

## Usage

1. Select exactly one folder/group parent track.
2. Run GGWP.
3. Edit the Take Volume Envelope on the generated `GGWP PRINT` item.
4. Keep the script running while editing; GGWP updates the group Track Volume Envelope after each completed edit gesture.
5. Run the action again to refresh the proxy render. The previous instance is terminated cleanly and replaced.

The generated `PRINT` is silenced with REAPER's stock **JS: Channel Mapper-Downmixer**, so it remains visible without doubling the group's audio.

## v1.0.1 highlights

- Exact commit on left-mouse-button release when js_ReaScriptAPI is available
- Dependency-free native fallback when it is not available
- Safe action re-launch and toolbar toggle state
- Previous `PRINT` retained until its replacement is fully configured
- Automatic watchdog and repair for silent Channel Mapper routing
- Safe stop when the active project tab or `PRINT` timing changes

## Current limitations

- The selected track must be a folder parent.
- Track Volume Automation Items are not supported.
- While GGWP is running, edit the `PRINT` Take Volume Envelope rather than the generated Track Volume Envelope.
- Old rendered WAV files are intentionally not deleted automatically, preserving Undo and media safety.

## Version

The first published working version is **v1.0.1**.
