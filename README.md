# Lullhum

Bilateral vibration app in two parts that share one Connect IQ app UUID
(`f1e2d3c4b5a697887766554433221100`):

- **`garmin/`** — Garmin Connect IQ watch app (Monkey C), target **Venu 3**.
- **`app/`** — Android companion (Kotlin/Compose), `minSdk 26`.

## Component 1 — Garmin watch app (`garmin/`)

Foreground Simple App with three modes:

| Mode | Phone? | Behaviour |
|------|--------|-----------|
| **Alternating** | yes | Watch and phone strictly alternate. To stay interleaved despite BLE latency, the watch picks the next whole wall-clock second as a shared anchor and sends `{cmd:"start", speed, anchor}`; both start there (watch on the anchor, phone one interval behind). Speed slow/medium/fast (1000/500/250 ms per side), duration 5/10/15/30 min or unlimited. Sends `{cmd:"stop"}` to end. If the phone drops, the watch keeps its own intervals. |
| **Interval** | no | One `Attention.vibrate()` pulse every 2s…30min. Runs until stopped. |
| **Longer Interval w/ Phone** | yes | One `Attention.vibrate()` pulse every 2s…30min. Also starts a background service that periodically sends a notification in the Android app. Runs until stopped. |
| **Breathing** | no | At each stage change, plays a distinct binary on/off motif once (250 ms per slot) so the stages are easy to tell apart: inhale `-.-.`, exhale `--..`, holds `-..=`. Presets: **A** breathing sigh (2000/1000/0/8000/2000 ms), **B** 4-7-8 (4000/7000/8000/0 ms), **C** box 4-4-4-4 (inhale/hold/exhale/hold, 4000 ms each), **D** custom per-phase. |

### Behaviour & controls

- **Launches straight into the running screen** and auto-starts with your last-used
  mode and settings (persisted via `Application.Storage`).
- **Select button / screen tap** — pause ⇄ resume.
- **Menu button** — open settings (mode + parameters). Changes persist and apply
  live; vibration keeps running underneath while the menu is open. Each mode's
  settings has a **Done** row that returns to the running screen and starts.
- **Back** — exit.

> **Background:** as a foreground Connect IQ app it keeps vibrating with the screen
> off or while a menu is open, but **not** once you exit to the watch face — the
> platform offers no API for continuous background haptics. (The Android companion,
> being a foreground service, is unaffected.)

### Metrics → Home Assistant

To check whether sessions actually have an effect, the watch logs each session
and pushes it to Home Assistant (`Metrics.mc`). Heart rate is the primary proxy
(a lower / falling HR suggests parasympathetic "rest-and-digest" activation);
respiration rate and Garmin's HRV-derived **stress score** are captured at the
start and end as stronger, lower-noise markers of nervous-system down-regulation.

Configure under the Connect IQ app **Settings** (Garmin Connect Mobile → the
app → Settings, or Connect IQ Store / Express):

| Setting | Value |
|---------|-------|
| **Home Assistant URL** | e.g. `https://your-home.ui.nabu.casa` (must be HTTPS and reachable from wherever the phone has internet — the watch relays web requests through the phone's Garmin Connect app). |
| **Long-lived access token** | HA → profile → *Long-lived access tokens* → Create. |
| **Baseline window (min)** | Minutes of pre-session history averaged as the baseline (default 15). |
| **Recovery window (min)** | Minutes after a session before the recovery is read (default 15, minimum 5). |

Both blank by default, so nothing is sent until configured. Each session writes a
handful of **plain `sensor.lullhum_*` entities** via
`POST /api/states/sensor.lullhum_<name>` (`Authorization: Bearer <token>`). They
render in Home Assistant **with no template, card, or config** — the mode is a
text state that HA's built-in History shows as a labeled timeline bar, and the
numbers (tagged `state_class: measurement`) show as History lines. The session
mode + `start`/`end` (ISO 8601 UTC) ride along as attributes on every entity.

Each session is framed as **baseline → during → recovery** (because Garmin logs
HR/stress/respiration continuously, the before/after windows don't need the app
running):

| Entity | Meaning | Unit |
|--------|---------|------|
| `sensor.lullhum_session` | **mode** (`alternating` / `interval` / `breathing:…`) — text state, History timeline bar | — |
| `sensor.lullhum_hr_recovery_delta` | recovery − baseline HR (negative = settled) | bpm |
| `sensor.lullhum_hr_baseline` | mean HR over the N min **before** | bpm |
| `sensor.lullhum_hr_recovery` | mean HR over the N min **after** | bpm |
| `sensor.lullhum_hr_avg` | mean HR **during** | bpm |
| `sensor.lullhum_hr_min` | lowest HR reached **during** (how deep it settled) | bpm |
| `sensor.lullhum_duration` | session length | s |
| `sensor.lullhum_stress_delta` | recovery − baseline stress (negative = settled) | — |
| `sensor.lullhum_stress_baseline` / `_recovery` | Garmin stress before / after | — |
| `sensor.lullhum_resp_delta` | recovery − baseline respiration | br/min |
| `sensor.lullhum_resp_baseline` / `_recovery` | respiration before / after | br/min |
| `sensor.lullhum_hrv_start` / `_avg` / `_end` | beat-to-beat HRV (RMSSD) over the first minute / whole session / last minute or two | ms |

`hr_recovery_delta` is the headline: consistently negative across sessions is the
signal the app is having an effect. `stress_delta` / `resp_delta` are the parallel
deltas for the lower-noise markers, sent ahead of their raw before/after readings.

**HRV (RMSSD).** Beat-to-beat HRV is the gold-standard parasympathetic marker, and a
*rising* `hrv_start → hrv_end` across a session is the cleanest within-session signal
of down-regulation. The platform has no HRV *history* API and the beat-to-beat R-R
stream (`Sensor.registerSensorDataListener` with `:heartBeatIntervals`) only runs
while the app is in the foreground, so there's no true *pre-session* or
*post-recovery* HRV to read. Instead the live stream is windowed: `hrv_start` is the
first minute (settling-in), `hrv_avg` the whole session, `hrv_end` roughly the last
minute or two. They appear only on devices that deliver R-R intervals and only when
enough beats were captured. (HR `hr_avg`/`hr_min` come from the 1 Hz HR events; if a
device won't run those alongside the R-R stream, `hr_avg` falls back to the session
window from history so the session still records — `hr_min` is then omitted.) `stress_*` / `resp_*` appear only when the
device exposes those histories. Entities send most-important-first, so if the
background run is cut short the headline ones still land.

**`sensor.lullhum_session` timeline.** Its state is set **live**: it flips to the
mode at the real session start and to `idle` at the end, so the native History bar
lines up with the actual session window. Pressing **Back** to exit defers the app
close by up to ~2 s so the `idle` request can leave first — so a normal exit ends
the bar at the right time. If the app is instead killed by the system, the
background wake sets `idle` as a fallback (the bar then runs from the true start to
roughly the wake time). The REST API can't backdate state changes, so the
start/end *attributes* hold the exact times regardless.

- **Baseline** is read back from `SensorHistory` at session end (the configured
  minutes *before* you started).
- **Recovery** can't be read until it happens, so a Connect IQ **background
  service** wakes the configured minutes *after* the session — even after you've
  closed the app — fills in the recovery values, and sends every numeric entity.

The recovery window has a hard **5-minute floor** (the platform's minimum for
background temporal events). History resolution is coarser than live sampling
(Garmin stores HR every few minutes when you're not in an activity), so the
windows are averages, not high-res curves — fine for trend deltas.

> **Delivery is background-only.** The app has no stop button — closing it *is*
> "stop" — so an immediate send at session end would be cut off mid-queue (the
> watch relays each POST through the phone over BLE). Instead the session is
> persisted and all entities are sent from the **post-session background wake**
> (~recovery-window minutes later). So a session appears in HA after that delay,
> not the moment you finish.
>
> **Multi-pass, resumable send.** A background process has only a ~30-second
> budget, so the queue may not drain in one wake. The remaining POSTs are persisted
> (`pending_queue`) and the session record is kept until the queue is fully
> accounted for, so each wake resumes where the last left off; cheap, always-present
> metrics are queued first so the slow history reads can't block them. Every send
> checks the HTTP response: a **2xx** advances; a transient failure (no phone/BLE,
> 5xx, relay timeout) **keeps** the item and re-arms a +5 min wake to retry; a
> permanent **4xx** (bad token/entity) drops just that item so it can't wedge the
> rest. Each item is dropped after **8 failed attempts** so an unreachable POST
> can't retry — and respawn wakes — forever. Response codes and any null
> baseline/recovery reads are written to the CIQ log (`[Lullhum] …`) since the
> background send has no UI.

> **Note:** states set via the REST API aren't backed by an integration, so the
> entities can't be attached to an HA **device** (only MQTT discovery / a custom
> integration can do that), and they read `unknown` after a Home Assistant restart
> until the next session repopulates them — recorded history is retained.

> **More proxies worth adding later:** **Body Battery** and **Pulse Ox** move too
> slowly to show a within-session effect (better for day-level trends). The HR
> recovery delta, stress, respiration, and the within-session HRV trend are the
> proxies that best distinguish genuine relaxation from merely sitting still.

### Build

Requires the Connect IQ SDK (tested with 9.2.0), Java, and a developer key.

```powershell
# One-time: generate a signing key (kept out of git)
openssl genrsa -out key.pem 4096
openssl pkcs8 -topk8 -inform PEM -outform DER -in key.pem -out garmin/developer_key.der -nocrypt

# Build a .prg for Venu 3
cd garmin
& "$env:APPDATA\Garmin\ConnectIQ\Sdks\<sdk-version>\bin\monkeyc.bat" `
    -d venu3 -f monkey.jungle -o bin/lullhum.prg -y developer_key.der
```

Run in the simulator with `monkeydo bin/lullhum.prg venu3`, or sideload the
`.prg` to a watch via Garmin Express / the device's `GARMIN/APPS` folder.

> The build succeeds clean (`BUILD SUCCESSFUL`, no warnings).

## Component 2 — Android companion (`app/`)

Status indicator (Running / Connected / Waiting for watch), a background interval
reminder, and a watch-independent **two-phone pairs** mode. A foreground service
(`VibrationService`) keeps the Connect IQ listener alive with a persistent
notification, listens for watch messages, and on `start` vibrates on even intervals
only (offset one full interval from the watch). On `stop` or a dropped connection it
cancels the timer.

> **Locked-screen timing:** the alternating timer runs on the main looper, which
> is paced by `uptimeMillis` and stops advancing once the CPU suspends — a
> foreground service keeps the process alive but not the CPU. So while alternating
> is active the service holds a `PARTIAL_WAKE_LOCK` (released on stop/drop) and
> re-anchors every buzz to the shared wall clock, so a single late buzz
> self-corrects instead of drifting out of sync. For this to work with the screen
> off, **battery optimisation must be disabled for Lullhum** (Settings → Apps →
> Lullhum → Battery → Unrestricted); aggressive OEM power management can otherwise
> throttle the service or BLE and break sync.

### Two-phone pairs (watch-independent)

A way to get bilateral alternation from **two phones instead of a watch + phone**,
with no BLE, pairing, or messaging. Set one phone to **Pair 1** and the other to
**Pair 2** in the app, then press **Start** on both. Each phone anchors to the
nearest whole second and buzzes off the shared wall clock: **Pair 1 on each whole
second, Pair 2 half a second later** (`PAIR_OFFSET_MS`), so they interleave.

There's no synchronisation channel — alignment relies solely on the two phones
agreeing on the time, so **keep automatic (network) date & time on** for both.
Because each phone re-anchors to the same absolute grid on every tick (Pair 1 on
`…000` ms, Pair 2 on `…500` ms), they stay interleaved no matter when each was
started, and a late tick self-corrects. It reuses the same foreground service,
`PARTIAL_WAKE_LOCK`, and re-anchoring timer as the watch path, and is fully
independent of it (a watch connecting/dropping never disturbs a pair session, and
vice versa — whichever was started last owns the single vibration timer).

### Background reminder

The one way to buzz the watch while the Connect IQ app is **closed**: the phone
posts a fresh high-importance notification every N minutes, which Garmin Connect
relays to the watch as a vibration. Each tick cancels the previous notification
and posts a new id so the watch re-alerts without the list piling up.

Scheduled with `AlarmManager.setAndAllowWhileIdle` (see `Reminder.kt` +
`ReminderReceiver`), not an in-process timer: it fires during Doze, lets the CPU
sleep between ticks (no wakelock, system-batched — battery-friendly), and each
fire chains the next, so it survives the service being killed. The trade-off is
inexact timing (may drift a few minutes in deep Doze), fine for a multi-minute
reminder.

- **Minimum 5 minutes** (the relay throttles anything faster; sub-minute pinging
  isn't reliable, and it can't express custom haptic patterns — only a plain buzz).
- Controllable two ways: the phone UI (preset chips 5/10/15/30/60 min or a numeric
  keypad for any value, + start/stop), or the watch (Interval mode → "Phone
  reminder" toggle sends `reminderStart`/`reminderStop`). It's decoupled from the
  in-app timer, so it keeps running after the watch app closes; stop it from
  either side.
- Requires Garmin smart notifications enabled and notification access granted to
  Garmin Connect. Reliability is device-dependent — test on your watch.

Message protocol (watch → phone): `{cmd:"start", speed}`, `{cmd:"stop"}`,
`{cmd:"reminderStart", intervalSec}`, `{cmd:"reminderStop"}`.

### Build

The Connect IQ companion SDK comes from Maven Central
(`com.garmin.connectiq:ciq-companion-app-sdk`), so no manual download is needed:

```powershell
./gradlew :app:installDebug       # build + deploy to a connected device
```

Builds and runs as-is; verified installed with the foreground listener service
active.

## References

### Disclaimer

This project is an independent software experiment created for personal use and learning purposes. I do not have professional training or credentials in psychology, psychotherapy, psychiatry, or any related clinical field.

Lullhum is not intended to diagnose, treat, prevent, or cure any medical or psychological condition, nor is it a substitute for professional healthcare, therapy, or psychological treatment. Any references to EMDR, bilateral stimulation, breathing techniques, or related concepts are provided for informational context only.

The application was developed primarily as a personal exploration of wearable haptics, timing synchronization, and user experience design, with assistance from generative AI tools. Any use of the software is at the user's own discretion and risk.

### Research

* **Good Vibrations: Bilateral Tactile Stimulation Decreases Startle Magnitude During Negative Imagination and Increases Skin Conductance Response for Positive Imagination in an Affective Startle Reflex Paradigm**
  https://www.sciencedirect.com/science/article/abs/pii/S2468749920300788

* **An Efficient System for Eye Movement Desensitization and Reprocessing (EMDR) Therapy: A Pilot Study**
  https://pmc.ncbi.nlm.nih.gov/articles/PMC8776167/

### Inspiration

* **Complete Guide to EMDR Bilateral Stimulation**
  https://www.coralehr.com/blog/emdr-bilateral-stimulation-guide/
