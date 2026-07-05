# Suite

Suite is a direct fork of [LizardByte/Sunshine](https://github.com/LizardByte/Sunshine) that turns an Apple Silicon Mac into a streaming host for the edit suite: 4K HDR editorial, grading, and ProRes/EXR review over the Moonlight protocol.

It pairs with [Screener](https://github.com/mhadifilms/Screener), a Moonlight-based review client, but works with any stock Moonlight client. Suite keeps Sunshine's protocol, pairing, web UI, and encoder foundation, then adds macOS-native display, capture, input, and audio behavior for cleaner review sessions.

Suite was previously named Daylight; existing `daylight` launchers keep working.

## What Suite Adds

- On-demand `CGVirtualDisplay` sessions sized to the client, with hardened helper cleanup on disconnect.
- Display P3 virtual-display primaries, resolution-aware physical sizing, 60 Hz fallback modes, and support up to 7680x4320.
- ScreenCaptureKit video capture on macOS 12.3+, with AVFoundation fallback.
- HDR display detection and HDR10 metadata for macOS capture paths.
- ScreenCaptureKit 10-bit/P010 capture setup and diagnostics for HEVC Main10 / AV1 10-bit sessions.
- Native `IOHIDUserDevice` virtual gamepads, without the keyboard-emulation fallback used by older Lumen builds. This requires Apple's virtual HID entitlement or an AMFI-disabled research setup.
- Core Audio tap support with compatibility aliases for `audio_sink = system`, `desktop`, and `screencapturekit`.
- Retina and virtual-display mouse coordinate fixes, plus reduced cursor-warp traffic.
- Client-side cursor support: the host honors Moonlight's cursor-capture toggle (Ctrl+Alt+Shift+N) live on both ScreenCaptureKit and AVFoundation, so the client can render its own pointer without a doubled host cursor.
- Network-stall resilience: session ping timeout is 30 seconds on macOS hosts, and input rides the reliable control channel, so keystrokes typed during a brief stall are delivered when the connection recovers instead of being dropped.
- Clipboard paste to host: Moonlight's Ctrl+Alt+Shift+V paste combo types client clipboard text on the Mac via native Unicode text events.
- `key_swap_cmd_ctrl` option: swaps Ctrl and Cmd so Ctrl+C/V/Z from Windows or Linux clients arrive as Cmd+C/V/Z on the Mac host. Leave it off when connecting from macOS clients, which already send Cmd correctly.
- Host clipboard API: authenticated `GET`/`POST /api/clipboard` on the web UI port reads and writes the Mac's clipboard text for clipboard sync tooling.

## Requirements

- Apple Silicon Mac, with Mac Studio-class machines as the primary target.
- macOS 14 or newer.
- Xcode Command Line Tools.
- Homebrew.
- Screener or any Moonlight client for playback.

Suite is still Sunshine under the hood. The web UI is served at `https://localhost:47990`, and configuration files live under `~/.config/sunshine`.

## Install

```bash
./install.sh
```

The installer builds the current checkout, installs binaries under `~/.local/share/suite`, and creates a launcher at `~/.local/bin/suite` (with `daylight` and `lumen` symlinks for compatibility).

If the upstream FFmpeg binary download is unavailable, point `FFMPEG_PREPARED_BINARIES` or `FFMPEG_CACHE` at a prepared arm64 FFmpeg bundle before running the installer.

It will not overwrite an existing `~/.config/sunshine/sunshine.conf`. If no config exists, it creates a local-review default:

```ini
audio_sink = system
virtual_display = enabled
upnp = enabled
max_bitrate = 150000
```

Set web UI credentials:

```bash
suite --creds username password
```

Start Suite:

```bash
suite
```

## Recommended Review Setup

Use wired networking when possible. In the client, select HEVC Main10 or AV1 when offered, enable HDR for HDR review, and set bitrate high enough for the session target. Suite defaults `max_bitrate` to 150 Mbps for 4K HDR local review.

HEVC Main10 and AV1 10-bit are advertised through Sunshine's existing encoder probe results. They appear to clients only when the active VideoToolbox path successfully reports support.

HDR capture is intentionally conservative: Suite only reports active macOS HDR when the current display is in extended dynamic range on macOS 15 or newer, where ScreenCaptureKit exposes HDR local-display capture controls.

## Limits

VideoToolbox and the Moonlight protocol define the practical fidelity ceiling. Suite targets 10-bit 4:2:0 HEVC Main10 or AV1 for HDR review; it does not add a practical VideoToolbox 4:4:4 encode path.

Runtime validation still needs real hardware and client testing: Mac Studio or equivalent Apple Silicon host, HDR-capable display or virtual display workflow, an HDR client, Screen Recording permissions, and a sustained 4K60 session.

## Release

Latest release: [`v2026.703.144423-daylight.1`](https://github.com/mhadifilms/Suite/releases/tag/v2026.703.144423-daylight.1) (published under the former Daylight name), based on Sunshine `v2026.703.144423`.

## Attribution

Suite is GPLv3 software based on:

- [LizardByte/Sunshine](https://github.com/LizardByte/Sunshine), the upstream self-hosted Moonlight host.
- [trollzem/Lumen](https://github.com/trollzem/Lumen), which explored the original macOS virtual-display, ScreenCaptureKit, and virtual HID concepts that informed this fork.

The upstream `LICENSE` file is intentionally kept unchanged.
