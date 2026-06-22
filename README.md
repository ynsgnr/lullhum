# Lullhum

Bilateral vibration app in two parts that share one Connect IQ app UUID
(`f1e2d3c4b5a697887766554433221100`):

- **`garmin/`** — Garmin Connect IQ watch app (Monkey C), target **Venu 3**.
- **`app/`** — Android companion (Kotlin/Compose), `minSdk 26`.

## Component 1 — Garmin watch app (`garmin/`)

Foreground Simple App with three modes:

| Mode | Phone? | Behaviour |
|------|--------|-----------|
| **Alternating** | yes | Watch buzzes on odd intervals, phone on even — strict alternation. Speed slow/medium/fast (1000/500/250 ms per side), duration 5/10/15/30 min or unlimited. Sends `{cmd:"start", speed}` / `{cmd:"stop"}` to the phone. If the phone connection drops, the watch keeps its own intervals. |
| **Interval** | no | One `Attention.vibrate()` pulse every 2s…30min. Runs until stopped. |
| **Breathing** | no | Vibrates during inhale/exhale, silent during holds. Presets: **A** physiological sigh (2000/1000/0/8000/2000 ms), **B** 4-7-8 (4000/7000/8000/0 ms), **C** custom per-phase. Runs until stopped. |

UI flow: **Mode select → config (cycle values in place) → running screen** (SELECT/tap = start/stop, BACK = stop + exit).

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

> The build currently succeeds (`BUILD SUCCESSFUL`). The container-access
> warnings from strict type checking are harmless.

## Component 2 — Android companion (`app/`)

Single status-only screen (Running / Connected / Waiting for watch) — there are
no controls; everything is driven by the watch. A foreground service
(`VibrationService`) keeps the Connect IQ listener alive with a persistent
notification, listens for watch messages, and on `start` vibrates on even
intervals only (offset one full interval from the watch). On `stop` or a
dropped connection it cancels the timer.

### Build

The Connect IQ companion SDK comes from Maven Central
(`com.garmin.connectiq:ciq-companion-app-sdk`), so no manual download is needed:

```powershell
./gradlew :app:installDebug       # build + deploy to a connected device
```

Builds and runs as-is; verified installed with the foreground listener service
active.
