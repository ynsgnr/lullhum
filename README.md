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
| **Breathing** | no | At each stage change, plays a distinct binary on/off motif once (250 ms per slot) so the stages are easy to tell apart: inhale `-.-.`, exhale `--..`, holds `-..=`. Presets: **A** breathing sigh (2000/1000/0/8000/2000 ms), **B** 4-7-8 (4000/7000/8000/0 ms), **C** custom per-phase. |

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

Both blank by default, so nothing is sent until configured. Each metric is its
own HA sensor entity, written via `POST /api/states/sensor.lullhum_<metric>`
(`Authorization: Bearer <token>`). Each carries `state_class: measurement` so
HA's statistics engine plots it over time directly — **no template sensors
needed**. `session_type` and `start`/`end` (ISO 8601 UTC) ride along as
attributes. Plot any of them with a **Statistics graph** or **History** card.

The whole point is *effect*, so each session is framed against the surrounding
windows — and because Garmin logs HR/stress/respiration continuously, neither
window needs the app to be running:

| Entity | Window | Unit |
|--------|--------|------|
| `sensor.lullhum_hr_baseline` | mean HR over the N min **before** the session | bpm |
| `sensor.lullhum_hr_avg` | mean HR **during** the session | bpm |
| `sensor.lullhum_hr_recovery` | mean HR over the N min **after** the session | bpm |
| `sensor.lullhum_hr_recovery_delta` | recovery − baseline (negative = settled) | bpm |
| `sensor.lullhum_duration` | session length | s |
| `sensor.lullhum_stress_baseline` / `_recovery` | Garmin stress before / after | — |
| `sensor.lullhum_resp_baseline` / `_recovery` | respiration before / after | br/min |

`hr_recovery_delta` is the headline: a consistently negative value across
sessions is the signal that the app is having an effect. The `stress_*` /
`resp_*` entities only appear when the device exposes those histories.

- **Baseline** is read back from `SensorHistory` at session end (the configured
  minutes *before* you started).
- **Recovery** can't be read until it happens, so a Connect IQ **background
  service** registers a one-shot temporal event and wakes the configured minutes
  *after* the session — even after you've closed the app.

The recovery window has a hard **5-minute floor** (the platform's minimum for
background temporal events). History resolution is coarser than live sampling
(Garmin stores HR every few minutes when you're not in an activity), so the
windows are averages, not high-res curves — fine for trend deltas.

> **Delivery is background-only.** The app has no stop button — closing it *is*
> "stop" — so an immediate send at session end would be cut off mid-queue (the
> watch relays each POST through the phone over BLE, which is slow). Instead the
> whole batch is persisted and sent **together with the recovery readings from
> the post-session background wake** (~recovery-window minutes later). So expect
> all metrics to appear in HA only after that delay, not right when you finish.
> The metric set is deliberately small because the background process has a
> ~30-second budget for the BLE-relayed POSTs.

> **Note:** states set via the REST API aren't backed by an integration, so they
> can't be attached to an HA **device** (only MQTT discovery / a custom
> integration can do that), and they read `unknown` after a Home Assistant
> restart until the next session repopulates them — recorded history is retained.

> **More proxies worth adding later:** beat-to-beat **HRV (RMSSD)** is the gold
> standard for parasympathetic tone but has limited in-app access on most
> devices; **Body Battery** and **Pulse Ox** move too slowly to show a
> within-session effect (better for day-level trends). The HR recovery delta,
> stress, and respiration are the proxies that best distinguish genuine
> relaxation from merely sitting still.

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

Status indicator (Running / Connected / Waiting for watch) plus a background
interval reminder. A foreground service (`VibrationService`) keeps the Connect IQ
listener alive with a persistent notification, listens for watch messages, and on
`start` vibrates on even intervals only (offset one full interval from the watch).
On `stop` or a dropped connection it cancels the timer.

> **Locked-screen timing:** the alternating timer runs on the main looper, which
> is paced by `uptimeMillis` and stops advancing once the CPU suspends — a
> foreground service keeps the process alive but not the CPU. So while alternating
> is active the service holds a `PARTIAL_WAKE_LOCK` (released on stop/drop) and
> re-anchors every buzz to the shared wall clock, so a single late buzz
> self-corrects instead of drifting out of sync. For this to work with the screen
> off, **battery optimisation must be disabled for Lullhum** (Settings → Apps →
> Lullhum → Battery → Unrestricted); aggressive OEM power management can otherwise
> throttle the service or BLE and break sync.

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
