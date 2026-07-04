# Daylight

Daylight is a direct fork of [LizardByte/Sunshine](https://github.com/LizardByte/Sunshine) tuned for high-quality Moonlight sessions on Apple Silicon Macs.

It targets local-network professional video review: 4K HDR editorial, grading, ProRes/EXR workflows, and Mac Studio setups. The fork keeps Sunshine's protocol, pairing, web UI, and encoder foundation, then adds macOS-native display, capture, input, and audio behavior for cleaner review sessions.

## What Daylight Adds

- On-demand `CGVirtualDisplay` sessions sized to the Moonlight client, with hardened helper cleanup on disconnect.
- Display P3 virtual-display primaries, resolution-aware physical sizing, 60 Hz fallback modes, and support up to 7680x4320.
- ScreenCaptureKit video capture on macOS 12.3+, with AVFoundation fallback.
- HDR display detection and HDR10 metadata for macOS capture paths.
- ScreenCaptureKit 10-bit/P010 capture setup and diagnostics for HEVC Main10 / AV1 10-bit sessions.
- Native `IOHIDUserDevice` virtual gamepads, without the keyboard-emulation fallback used by older Lumen builds.
- Core Audio tap support with compatibility aliases for `audio_sink = system`, `desktop`, and `screencapturekit`.
- Retina and virtual-display mouse coordinate fixes, plus reduced cursor-warp traffic.

## Requirements

- Apple Silicon Mac, with Mac Studio-class machines as the primary target.
- macOS 14 or newer.
- Xcode Command Line Tools.
- Homebrew.
- A Moonlight client for playback.

Daylight is still Sunshine under the hood. The web UI is served at `https://localhost:47990`, and configuration files live under `~/.config/sunshine`.

## Install

```bash
./install.sh
```

The installer builds the current checkout, installs binaries under `~/.local/share/daylight`, and creates launchers at `~/.local/bin/daylight` and `~/.local/bin/lumen`.

It will not overwrite an existing `~/.config/sunshine/sunshine.conf`. If no config exists, it creates a local-review default:

```ini
audio_sink = system
virtual_display = enabled
upnp = enabled
max_bitrate = 150000
```

Set web UI credentials:

```bash
daylight --creds username password
```

Start Daylight:

```bash
daylight
```

## Recommended Review Setup

Use wired networking when possible. In Moonlight, select HEVC Main10 or AV1 when the client offers it, enable HDR for HDR review, and set bitrate high enough for the session target. Daylight defaults `max_bitrate` to 150 Mbps for 4K HDR local review.

HEVC Main10 and AV1 10-bit are advertised through Sunshine's existing encoder probe results. They appear to Moonlight only when the active VideoToolbox path successfully reports support.

## Limits

VideoToolbox and Moonlight define the practical fidelity ceiling. Daylight targets 10-bit 4:2:0 HEVC Main10 or AV1 for HDR review; it does not add a practical VideoToolbox 4:4:4 encode path.

Runtime validation still needs real hardware and client testing: Mac Studio or equivalent Apple Silicon host, HDR-capable display or virtual display workflow, Moonlight HDR client, Screen Recording permissions, and a sustained 4K60 session.

## Release

Current Daylight release: [`v2026.703.144423-daylight.1`](https://github.com/mhadifilms/Daylight/releases/tag/v2026.703.144423-daylight.1), based on Sunshine `v2026.703.144423`.

## Attribution

Daylight is GPLv3 software based on:

- [LizardByte/Sunshine](https://github.com/LizardByte/Sunshine), the upstream self-hosted Moonlight host.
- [trollzem/Lumen](https://github.com/trollzem/Lumen), which explored the original macOS virtual-display, ScreenCaptureKit, and virtual HID concepts that informed this fork.

The upstream `LICENSE` file is intentionally kept unchanged.
