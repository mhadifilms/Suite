# Suite + Screener Protocol Extension Plan

Working plan for the four paired features that require coordinated changes across the
**Suite** host (`mhadifilms/Suite`, local checkout `~/Documents/GitHub/mhadifilms/Daylight`)
and the **Screener** client (`mhadifilms/Screener`, local checkout
`~/Documents/GitHub/mhadifilms/Screener`).

Order of delivery:

1. Phase 1 — Client-side stall timeout (client only)
2. Phase 2 — Clipboard sync (host + client, no protocol fork needed)
3. Phase 3 — Auto-reconnect (client only)
4. Phase 4 — Client-rendered cursor channel (host + client + moonlight-common-c fork)

Each phase lands as its own set of commits, builds clean before merging
(`BUILD_WERROR=ON` for Suite; `qmake && make` warning-free for Screener), and degrades
gracefully against stock peers (stock Moonlight ↔ Suite, Screener ↔ stock Sunshine).

---

## 0. Repo mechanics and ground rules

### 0.1 Current state

- Suite is 13 commits + a large uncommitted working tree ahead of upstream Sunshine
  `v2026.703.144423`. Host-side groundwork already in the tree:
  - `ping_timeout` default raised to **30 s** on macOS (`src/config.cpp`).
  - Clipboard primitives `platf::get_clipboard()` / `platf::set_clipboard()`
    (`src/platform/macos/misc.mm`, declared in `src/platform/common.h`).
  - Web-port clipboard API `GET/POST /api/clipboard` (`src/confighttp.cpp`).
  - Cursor-capture toggle honored live in both capture backends
    (`src/platform/macos/sc_capture.m` `setCursorCapture:`, `av_video.m` `capturesCursor`).
  - `unicode()` text injection implemented on macOS (`src/platform/macos/input.cpp`),
    which makes Moonlight's Ctrl+Alt+Shift+V clipboard-paste combo work today.
- Screener is upstream moonlight-qt master (`fd34a1fd`) plus the Suite theme/branding
  pass (uncommitted). Builds via `qmake` + `make` with Homebrew Qt 6.11 and the
  prebuilt `libs/` bundle fetched by `setup-deps.py` (extract to **repo root**, not cwd).

### 0.2 moonlight-common-c fork (needed for Phases 1 and 4)

The client consumes `moonlight-common-c` as a git submodule at
`moonlight-common-c/moonlight-common-c` (currently `moonlight-stream/moonlight-common-c`
@ `2600bea`). Phases 1 and 4 modify that library, so:

1. `gh repo fork moonlight-stream/moonlight-common-c --clone=false` →
   `mhadifilms/moonlight-common-c`.
2. Create branch `suite-extensions` from the pinned submodule commit `2600bea`
   (not master, to avoid an implicit library upgrade).
3. Repoint the Screener submodule:
   `git submodule set-url moonlight-common-c/moonlight-common-c
   https://github.com/mhadifilms/moonlight-common-c.git`
   then check out `suite-extensions` inside the submodule and commit the gitlink bump.
4. All Phase 1/4 library changes land on `suite-extensions`, pushed before the
   Screener gitlink commit that references them.

The **host does not need a common-c fork**: Sunshine implements its own control-stream
server in `src/stream.cpp` and constructs control payloads by hand, so new message
types are plain host-side code.

### 0.3 Compatibility matrix (target behavior after all phases)

| | Suite host | Stock Sunshine host |
|---|---|---|
| **Screener client** | All four features active | Timeout + auto-reconnect active; clipboard endpoints 404 → feature hidden; cursor channel not negotiated → normal cursor |
| **Stock Moonlight client** | Today's behavior (30 s host timeout, Ctrl+Alt+Shift+V paste, cursor toggle) | Upstream behavior |

Feature detection must be explicit (serverinfo flags / RTSP negotiation / HTTP 404
fallbacks) — never assume the peer is ours.

---

## Phase 1 — Client-side stall timeout

**Goal:** a Wi-Fi hiccup of up to ~25 s pauses the stream instead of killing the
session. The host already tolerates 30 s; the client still gives up at 10 s in three
independent places.

### 1.1 Changes (all in `mhadifilms/moonlight-common-c`, branch `suite-extensions`)

| File | Today | Change |
|---|---|---|
| `src/ControlStream.c` | `#define CONTROL_STREAM_TIMEOUT_SEC 10` (line ~144) | Introduce `ControlStreamTimeoutSec` variable defaulting to 10; used everywhere the macro was. |
| `src/ControlStream.c` | `enet_peer_timeout(peer, 2, 10000, 10000)` (line ~1837, non-3DS branch) | Use `ControlStreamTimeoutSec * 1000` for both limit values. |
| `src/VideoStream.c` | `ML_ERROR_NO_VIDEO_TRAFFIC` fires after `FIRST_FRAME_TIMEOUT_SEC` (10 s) of no UDP traffic (line ~150) | Split constants: keep first-frame timeout at 10 s, add `VideoTrafficTimeoutSec` (default 10) for the steady-state watchdog; both overridable. |
| `src/Limelight.h` | — | New public setter, e.g. `void LiSetStallTimeoutsSec(int controlSec, int videoSec);` called before `LiStartConnection()`. Keeps defaults identical for other consumers of the fork. |

### 1.2 Screener wiring

- `app/streaming/session.cpp`, in the pre-connection setup (where
  `LiStartConnection` config is assembled): call
  `LiSetStallTimeoutsSec(30, 30)` when the host is detected as Suite (see §2.3),
  else leave defaults. Rationale: against stock Sunshine (10 s host ping timeout),
  a 30 s client would outlive the host session and reconnect anyway — harmless, but
  matching the host keeps failure modes predictable.
- Optional (defer unless trivial): surface "connection interrupted" earlier via the
  existing `clConnectionStatusUpdate` slow/poor callbacks so the user sees the stall
  overlay during the wait.

### 1.3 Acceptance

- Simulated stall (pause host process / pull network for 15–20 s on LAN): stream
  freezes, then resumes without session teardown; keystrokes typed during the stall
  are replayed in order after recovery (ENet reliable channel).
- 35 s stall: clean termination on both ends, no orphaned session; Screener can
  immediately resume.

---

## Phase 2 — Clipboard sync

**Goal:** Parsec-style bidirectional text clipboard between client machine and Mac host.

### 2.1 Transport decision

Use the **paired-client HTTPS channel (nvhttp, port 47984)**, not the control stream:

- Authentication is free: nvhttp already distinguishes paired clients via TLS client
  certificates (`verified_cert` in `src/nvhttp.cpp`). No web-UI credentials needed on
  the client, unlike the existing `/api/clipboard` on the web port.
- No moonlight-common-c changes; works with plain Qt networking the client already
  uses for launch/resume (`app/backend/nvhttp.cpp`).
- Works even when a stream is not active (copy something before connecting).
- Clipboard is low-frequency; HTTPS latency is irrelevant.

The control stream remains reserved for the latency-sensitive cursor channel.

### 2.2 Host (Suite) changes — `src/nvhttp.cpp`

1. New HTTPS resources on the paired-client server (register next to
   `^/launch$` / `^/resume$`):
   - `GET ^/clipboard$` → `{platf::get_clipboard()}` as `text/plain; charset=utf-8`.
   - `POST ^/clipboard$` → body (UTF-8 text) into `platf::set_clipboard()`.
2. Guards:
   - Paired/verified client only (same check path as launch).
   - Config gate `clipboard_sync = enabled|disabled` (new `config::sunshine` or
     `config::input` bool, default **enabled**; parse in `src/config.cpp`, document in
     README). Disabled → 404 so clients treat it as "not supported".
   - Size cap 512 KB request/response; reject larger with 413. Text only.
3. Feature advertisement: in `serverinfo` add
   `tree.put("root.SuiteFeatureFlags", flags)` where bit 0 = clipboard, bit 1 =
   cursor channel (Phase 4). Unknown XML nodes are ignored by stock Moonlight.
4. Keep `/api/clipboard` on the web port (already implemented) for scripting.

### 2.3 Client (Screener) changes

1. `app/backend/nvcomputer.{cpp,h}`: parse `SuiteFeatureFlags` from serverinfo into
   `NvComputer::suiteFeatures` (0 for stock hosts). This is the single "is Suite"
   signal reused by Phases 1/2/4.
2. `app/backend/nvhttp.{cpp,h}`: `QString getClipboard()` /
   `bool setClipboard(const QString&)` hitting the new endpoints with the existing
   authenticated transport.
3. New `app/backend/clipboardmanager.{cpp,h}` (QObject):
   - Started/stopped by `Session` (`app/streaming/session.cpp`) around stream lifetime.
   - **Client → host:** connect `QGuiApplication::clipboard()::dataChanged()`;
     debounce 300 ms; push text if changed and ≤ 512 KB.
   - **Host → client:** poll `GET /clipboard` every 2 s while the stream window has
     been focused since last poll (skip when unfocused to avoid waste), plus one
     immediate poll on focus-in.
   - **Loop prevention:** remember SHA-256 of the last text applied in each direction;
     never re-send what we just received, never re-apply what we just sent.
4. Settings: `StreamingPreferences` bool `clipboardSync` (default true) + checkbox in
   `app/gui/SettingsView.qml` under Input settings ("Sync clipboard with Suite hosts").
5. Failure handling: any 404 → mark unsupported for the session, stop polling silently.

### 2.4 Acceptance

- Copy on client → paste on host (Cmd+V) within ~1 s; copy on host → paste on client
  within one poll interval; no ping-pong loops (verify with rapid alternating copies).
- Stock Sunshine host: no requests after the first 404. `clipboard_sync = disabled`
  on host behaves identically.
- Unicode (emoji, CJK), 100 KB text blob, and empty-clipboard cases pass.

---

## Phase 3 — Auto-reconnect

**Goal:** transient failures beyond the stall window resume the session automatically
instead of dumping the user back to the PC grid.

### 3.1 Client changes (all Screener, no host work)

1. `app/settings/streamingpreferences.{cpp,h}`: bool `autoReconnect`
   (default **true**), persisted like the other prefs; checkbox in `SettingsView.qml`
   (Basic settings: "Automatically reconnect after connection loss").
2. `app/streaming/session.{cpp,h}`:
   - Classify termination in `clConnectionTerminated(int errorCode)` (line ~88):
     reconnectable = `ML_ERROR_NO_VIDEO_TRAFFIC`, ENet/link loss codes, and the
     `default:` unexpected bucket. **Not** reconnectable: `ML_ERROR_GRACEFUL_TERMINATION`
     (user quit / host quit), `ML_ERROR_PROTECTED_CONTENT`, `ML_ERROR_FRAME_CONVERSION`
     (deterministic re-failure).
   - New signal `readyForReconnect(int attempt)` instead of `displayLaunchError` when
     reconnectable and `autoReconnect` is on and the session ran ≥ 10 s (guard against
     instant-fail loops).
   - Reconnect executor: retry loop re-running the quit-less relaunch path the CLI
     resume flow already uses (`http.startApp("resume", ...)` at session.cpp ~1595 —
     the session object is rebuilt, not reused). Backoff: 2 s, 4 s, 8 s, then every
     10 s; give up after 5 minutes or on any non-network error.
3. `app/gui/StreamSegue.qml`: new visual state — "Connection lost. Reconnecting
   (attempt N)…" with a Cancel button (Esc) that stops the loop and pops to PcView.
   Reuse the existing stage-text plumbing (`stageStarting` signals) rather than a new
   dialog so controller/keyboard nav keeps working.
4. Interaction notes:
   - Suite keeps the app/session resumable after ping timeout (upstream behavior +
     our VD teardown only fires on failed launch or stream stop), so `/resume`
     rebuilds cleanly; verify the virtual display is re-created on resume (it is —
     `create_virtual_display` runs in the `/resume` handler).
   - Phase 1 makes this rarer; Phase 3 catches everything longer than the stall window.

### 3.2 Acceptance

- Kill network 60 s mid-stream: overlay appears, stream resumes automatically when
  network returns, VD/HDR/bitrate all intact.
- Host process killed: reconnect attempts fail fast, loop gives up with the normal
  error dialog. User-initiated quit never triggers reconnect.

---

## Phase 4 — Client-rendered cursor channel

**Goal:** true Parsec-style local cursor: host stops compositing the pointer, streams
cursor *shape* changes to the client, and the client shows that shape as its **local OS
cursor** — zero added latency, no double cursor.

### 4.1 Design decision: shape channel + local rendering

In absolute-mouse ("remote desktop") mode the client's local pointer position already
equals the position the host applies. So the client does **not** need per-frame cursor
positions; it needs the host's current cursor *image* applied via
`SDL_CreateColorCursor` + `SDL_SetCursor`. Position messages are only needed for
host-initiated warps. This avoids per-frame compositing in every renderer backend.

### 4.2 Protocol (control stream, Suite extension)

- Audit `packetTypes[]` in Suite `src/stream.cpp` (0x0305, 0x0307, …) and the client
  `ControlStream.c` gen7/gen13 tables; pick two unused type codes, provisionally
  `0x5501` (SHAPE) and `0x5502` (POSITION). Sent host→client on the encrypted control
  channel when negotiated (same envelope as `IDX_HDR_MODE`, see `control_hdr_mode_t`).
- `SS_CURSOR_SHAPE` payload:
  `{u16 width; u16 height; u16 hotspotX; u16 hotspotY; u8 format(0=BGRA32); u8 visible; u32 dataLen; u8 data[];}`
  — cursors are ≤ 64×64 on macOS in practice (≤ 16 KB BGRA); cap 128×128, drop larger.
- `SS_CURSOR_POSITION` payload: `{i16 x; i16 y; u8 visible;}` in stream-surface
  coordinates; sent **only** on host-side warps or visibility changes, rate-limited
  to 30 Hz.
- Negotiation: client adds `x-ss-cursor=1` RTSP option (Sunshine already parses
  `x-ss-*` attributes in `src/rtsp.cpp`); host sets `SuiteFeatureFlags` bit 1 in
  serverinfo so the client offers it only to Suite hosts. Both present → host enters
  cursor-channel mode for that session.

### 4.3 Host (Suite) implementation

1. `src/platform/macos/cursor_monitor.{h,mm}` (new): background monitor that
   - polls the private-but-stable `CGSCurrentCursorSeed()` (SkyLight, already linked
     for `vd_helper`) at 30 Hz to detect shape changes cheaply;
   - fetches the current image via `[NSCursor currentSystemCursor]` with
     `CGSCopyRegisteredCursorImages` fallback, downscales Retina (2x) reps to the
     wire size, converts to BGRA;
   - reports visibility via `CGCursorIsVisible` equivalents;
   - exposes a `platf::cursor_monitor` callback interface in `src/platform/common.h`
     (no-op default so non-macOS builds are unaffected).
   - **Risk:** private CGS APIs — isolate behind runtime `dlsym` lookups with a
     graceful "shape channel unavailable" fallback (position/visibility only).
2. `src/stream.cpp`: when the session negotiated the cursor channel,
   - start the monitor on stream start, stop on stop;
   - marshal shape/warp events through the existing `control_server_t` send path
     (encrypted when `controlProtocolType == 13`);
   - force `display_cursor = false` for capture (client renders it), restoring on
     session end — the capture backends already honor this live.
3. Config gate `cursor_channel = enabled|disabled` (default enabled) beside
   `clipboard_sync`.

### 4.4 Client (Screener) implementation

1. moonlight-common-c `suite-extensions`:
   - dispatch `0x5501`/`0x5502` in `ControlStream.c`;
   - new optional callbacks in `CONNECTION_LISTENER_CALLBACKS`
     (`cursorShape`, `cursorPosition`) — appended at the end of the struct with
     null-checks so existing consumers are ABI-safe;
   - send `x-ss-cursor=1` during RTSP when the app opts in
     (new field in `STREAM_CONFIGURATION`).
2. Screener:
   - `Session::clCursorShape` / `clCursorPosition` → queue to
     `app/streaming/input/mouse.cpp` territory: build `SDL_Surface` from BGRA,
     `SDL_CreateColorCursor(surface, hotX, hotY)`, `SDL_SetCursor`; free the previous
     cursor. Visibility=false → `SDL_ShowCursor(SDL_DISABLE)`.
   - Position messages → `SDL_WarpMouseInWindow` only when divergence > 2 px, and
     only in absolute-mouse mode.
   - Enable the channel only when: Suite host, absolute mouse mode active, and new
     `StreamingPreferences::clientCursor` (default true) is on. When active, stop
     sending the "toggle host cursor" combo default.
   - HiDPI: scale hotspot/size by the ratio of stream resolution to window points
     (reuse `streamutils` scaling helpers).
3. Fallbacks: channel not negotiated → exactly today's behavior. Shape decode failure
   → keep last cursor, log once.

### 4.5 Acceptance

- Cursor changes (arrow → I-beam → resize → custom NLE cursors in Resolve/Premiere)
  reflect on the client within one poll tick; pointer motion has zero added latency
  (it's the local cursor).
- No double cursor in any mode; toggling the setting mid-session restores host
  compositing cleanly; stock Moonlight sessions are unaffected.
- 30 min soak: no leaks from repeated `SDL_CreateColorCursor` (destroy previous),
  monitor thread CPU < 1%.

---

## 5. Sequencing, commits, verification

1. **Fork + submodule plumbing** (one commit in Screener + new repo): §0.2.
2. **Phase 1** — common-c timeouts (2 commits: library, Screener wiring). Gate: both
   builds clean; LAN stall tests from §1.3.
3. **Phase 2** — host endpoints + flags (Suite, 1–2 commits), client manager +
   settings (Screener, 2 commits). Gate: §2.4 matrix including stock-host fallback.
4. **Phase 3** — prefs + session reconnect + segue UI (Screener, 2–3 commits).
   Gate: §3.2.
5. **Phase 4** — protocol/library (1 commit), host monitor + control send (2 commits),
   client rendering (2 commits), docs. Gate: §4.5. Highest risk — keep it last and
   independently revertable.
6. After each phase: update Suite `README.md` + Screener README feature notes; tag a
   fresh `-suite.N` prerelease at phase boundaries rather than moving any existing tag.

Standing rules: never break stock-peer compatibility; every feature has a config/pref
kill-switch; Suite builds with `BUILD_WERROR=ON` before every commit; nothing is
committed or pushed without an explicit go-ahead.
