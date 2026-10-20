<!--
A copy of the contract the shell's optional FRAME-API half speaks, taken from
the server that defined it ("panels", part of a private home-dashboard repo,
v3.25.4). It is here so the shell can be read and checked without that repo;
if you write your own server, this is what it answers. The shell needs none of
it to run as a plain kiosk (README, "Configuring the page").
-->

# The touch frame — what a shell must implement

The VPhoto "Modern 10 Elite" (1280x800, touch) is a cortex-displays screen
that runs a **page**, not a PNG. `panels` serves the page and its API
(`src/server/touchframe.ts`); the device runs a thin **shell**: a full-screen
browser engine for the page, plus a native half for the screen and sensors.
Two shells implement this same contract: Android (`frame-android/`, on the
stock Android 6.0.1) and Linux (the mainline port on the TF card). Build
against this file; if the two disagree with it, this file is the bug report.

None of this touches the ESP32 `.ver`/`.png` contract (`firmware.ts`). The
page ships from `panels`, so the page and its API move together; the shell is
the only part with a release cycle, and it should stay dumb.

## Base URL and auth

```
http://<panels-host>:8902/frame?k=<PANEL_TOKEN>
```

- `?k=` is the same `PANEL_TOKEN` as every other route. When the server has
  one configured, EVERY request below needs `?k=`; the page appends it to its
  own calls (it is injected as `window.__FRAME__.token`). The shell appends it
  to `/frame/api/report`.
- LAN only, plain HTTP. The HA token never leaves `panels`.

## 1. Load the page

- Full screen, 1280x800 landscape, no browser chrome, no zoom, no text
  selection UI. The page is fixed-size; it is not responsive.
- Needs: ES2020 + ES modules, `EventSource`, `fetch`, CSS grid and custom
  properties. It is built for **chrome106** (the Android WebView ceiling);
  anything newer is fine.
- Fonts and assets come from `/frame/assets/*` (cacheable). No CDN.
- **Offline**: if the page itself fails to load (panels down, Wi-Fi gone), the
  shell shows its own "can't reach panels" screen and retries every ~10 s.
  Once loaded, the page handles a lost stream by itself (it shows
  "Reconnecting…"; `EventSource` retries every 3 s).
- The page reloads itself when `panels` reports a new version, so a deploy
  reaches the glass without touching the shell.
- The page also obeys `event: cmd` on its stream (v3.26): `{"do":"reload"}`
  reloads it, `{"do":"screenOff"}` calls the bridge's `screenOff()`. They come
  from the home page's Frame tab; the shell needs nothing new for them.

## 2. The bridge — `window.CortexFrame` (optional, page → shell)

The page works in a desktop browser with no bridge. On the device the shell
exposes an object named `CortexFrame` on `window` with these methods (all
synchronous, string/number arguments only — the Android `@JavascriptInterface`
shape):

| method | what the shell does |
|---|---|
| `policy(json: string)` | the screen policy (§4), pushed live by panels through the page's stream. Same object the report answers; apply it the same way. |
| `screenOff()` | backlight off now (the page's moon button). Motion or a touch wakes it as usual. |
| `setBrightness(level: number)` | 0..1 backlight; `-1` = back to the policy/system. |
| `info(): string` | JSON of the shell's last readings: `{shell, motion, lux, soc_temp, screen, brightness}`. Debug only. |
| `reload()` | reload the page. |

## 3. Report — `POST /frame/api/report?k=` (shell → panels → HA)

`Content-Type: application/json`, every field optional (report what the
hardware has):

```json
{ "motion": true, "lux": 41, "soc_temp": 47.5, "screen": true,
  "brightness": 0.6, "shell": "android/0.1.0", "uptime": 3600 }
```

- `motion` — someone is there: the PIR, OR a wake the shell didn't cause (a
  touch on the dark glass wakes the panel inside the OS and never reaches the
  page). Hold it true ~30 s after the last sign. **`null` = this frame has no
  motion sensor**: HA gets `unavailable`, never a permanent `off` that an
  automation would read as "nobody here". **The VPhoto unit has no PIR
  fitted** (2026-10-19: PG12 / `sleepmode` stayed 0 for minutes with the
  owner in front of it; the vendor flag `ro.fullja.human_sensor` is 0), so
  both shells send `null` and the screen wakes on touch. A shell may switch to
  booleans if its sensor ever reads high.
- `lux` — ambient light (analog phototransistor on the LRADC; Android calls it
  `pt3r850`). Uncalibrated: trends, not absolute lux.
- `soc_temp` — °C of the A33 **die**. There is no room thermometer in the
  frame; this is a health reading and HA gets it as a diagnostic, never as a
  room temperature.
- `screen` — is the backlight on; `brightness` 0..1 what the shell set.

**When**: immediately on a motion edge (0→1 and 1→0) and on a screen on/off
change; otherwise every `report_s` seconds from the last policy (60) as a
heartbeat — the heartbeat is how a hold from HA reaches a frame whose page
isn't running. Fire and forget; a failed report is retried at the next one.

**What HA sees** (REST `POST /api/states`, the same mechanism as the e-ink's
battery — no integration, so after an HA restart they reappear on the next
report):

| entity | from |
|---|---|
| `binary_sensor.panel_frame_motion` (device_class motion) | `motion` (`null` -> `unavailable`) |
| `sensor.panel_frame_illuminance` (lx) | `lux` |
| `sensor.panel_frame_soc_temperature` (°C, diagnostic) | `soc_temp` |
| `binary_sensor.panel_frame_screen` (device_class power) | `screen` |

## 4. Screen policy — the report's answer (panels → shell)

```json
{ "awake_s": 300, "night": false, "force": null, "force_s": 0,
  "brightness": null, "report_s": 60 }
```

The shell owns the backlight and decides by this rule, re-evaluated every
second:

1. `force: "on"` → backlight on, `force: "off"` → off, for `force_s` seconds
   (counted from when the policy arrived), regardless of motion.
2. Otherwise on while `now − last(motion or touch) < awake_s`, then off.
   **A wake the shell didn't cause IS activity.** On this panel a touch on
   the dark glass wakes the device by itself and the touch never reaches the
   shell's window; if that wake isn't counted, the rule turns the screen off
   again within a second (Android shell 0.1.0 did exactly that). The Linux
   shell will see the touch itself — count it the same way.
3. `brightness` 0..1 when not null (panels dims it at night, or the owner
   fixed a level on the home page); null = the shell's own choice (system
   auto-brightness, or full).

`awake_s` is `FRAME_AWAKE_SECONDS` (300) inside `ACTIVE_HOURS`,
`FRAME_NIGHT_AWAKE_SECONDS` (30) outside — unless the home page pins night
mode on or off (STATE_DIR/frame.settings, which also holds the fixed
brightness). The screen is never "always on":
a frame nobody walks past is dark.

The same object arrives on `CortexFrame.policy()` whenever it changes (an HA
hold lands within a second while the page is running), and at the latest in
the answer to the next heartbeat.

## 5. For HA: hold the screen

```
GET  /frame/api/screen?on=1&for=600&k=     on for 10 min (on=0: off)
GET  /frame/api/screen?release=1&k=        back to motion
POST /frame/api/screen  {"on": true, "for": 600} | {"release": true}
```

`for` is 5 s .. 24 h (default 600). In memory: a `panels` restart releases it.

## The rest of the API (the page's, listed for completeness)

| route | |
|---|---|
| `GET /frame/api/state` | the whole snapshot (`FrameSnapshot`, `src/server/frameTypes.ts`) |
| `GET /frame/api/events` | SSE, `event: state` with the snapshot whenever it changes |
| `POST /frame/api/tile` | `{entity, on?, brightness?}` — only entities on the tile list (404 otherwise) |
| `POST /frame/api/scene` | `{scene: "focus"\|"pomodoro", minutes?, task?}` or `{off: "focus,pomodoro"\|"all"}` on `FRAME_SCENE_SCREEN` (the color screen); never ends a scene it didn't start the kind of |

Config (env on `panels`): `FRAME_TILES` (`entity=Label,...`, the default
tile list), `FRAME_SCENE_SCREEN` (default `color`), `FRAME_AWAKE_SECONDS`,
`FRAME_NIGHT_AWAKE_SECONDS`.

The tile list — which is also the allowlist — is edited on the home page's
Frame tab since v3.26 and saved to `STATE_DIR/frame.tiles` (one
`entity=Label` per line). While that file doesn't exist, `FRAME_TILES` is the
list; deleting it (the tab's "reset") goes back. The tab's own routes are
`/frame/control*` (`src/server/framecontrol.ts`); a shell never calls them.
