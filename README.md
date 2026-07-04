# Daylight

Daylight is a direct fork of [LizardByte/Sunshine](https://github.com/LizardByte/Sunshine) tuned for professional video work on Apple Silicon Macs.

The goal is a clean upstream-based host for Moonlight that fits 4K HDR editorial, grading review, ProRes/EXR workflows, and Mac Studio setups. It keeps Sunshine's protocol and encoder foundation while adding macOS-native capture and display behavior needed for reliable professional review sessions.

## Focus

- Apple Silicon first: macOS 14+, arm64, VideoToolbox HEVC/AV1, and high-bitrate local-network streaming.
- On-demand virtual displays: client-sized CGVirtualDisplay sessions that are created after encoder probing and destroyed on disconnect.
- ScreenCaptureKit video capture: preferred on macOS 12.3+ for virtual-display reliability, with AVFoundation fallback.
- Native system audio: upstream Core Audio taps with compatibility aliases for `audio_sink = system`, `desktop`, or `screencapturekit`.
- Virtual gamepads: IOHIDUserDevice-backed gamepads without the keyboard-emulation fallback from older Lumen builds.
- Moonlight fidelity ceiling: HEVC Main10 / AV1 10-bit 4:2:0 HDR where supported by the client and VideoToolbox.

## Requirements

- Apple Silicon Mac, tested target: Mac Studio-class machines.
- macOS 14 or newer.
- Xcode Command Line Tools.
- Homebrew.
- A Moonlight client for playback.

Daylight remains a Sunshine fork, so the web UI is still served at `https://localhost:47990` and normal Sunshine configuration files live under `~/.config/sunshine`.

## Install

```bash
./install.sh
```

The installer builds the current checkout, installs binaries under `~/.local/share/daylight`, and creates `~/.local/bin/daylight`. It also creates a `lumen` symlink for muscle memory.

The installer will not overwrite an existing `~/.config/sunshine/sunshine.conf`. If no config exists, it creates a default tuned for local professional review:

```ini
audio_sink = system
virtual_display = enabled
upnp = enabled
max_bitrate = 150000
```

Set Web UI credentials with:

```bash
daylight --creds username password
```

Then start Daylight:

```bash
daylight
```

## Fidelity Notes

Moonlight and VideoToolbox define the practical ceiling. Daylight targets 10-bit 4:2:0 HEVC Main10 or AV1 for HDR review; VideoToolbox does not provide a practical 4:4:4 encode path for this use case. For grading review, select HEVC Main10 or AV1 in the Moonlight client when available and use wired networking where possible.

## Attribution

Daylight is GPLv3 software based on:

- [LizardByte/Sunshine](https://github.com/LizardByte/Sunshine), the upstream self-hosted Moonlight host.
- [trollzem/Lumen](https://github.com/trollzem/Lumen), which explored the original macOS virtual-display, ScreenCaptureKit, and virtual HID concepts that informed this fork.

The upstream `LICENSE` file is intentionally kept unchanged.
