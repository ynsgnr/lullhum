import Toybox.Lang;
using Toybox.Attention;
using Toybox.Timer;
using Toybox.System;
using Toybox.Time;
using Toybox.WatchUi;

enum { BREATHE_HOLD, BREATHE_INHALE, BREATHE_EXHALE }

class BreathPhase {
    var name as String;
    var durationMs as Number;
    var pattern as Number; // BREATHE_HOLD / INHALE / EXHALE

    function initialize(name as String, durationMs as Number, pattern as Number) {
        self.name = name;
        self.durationMs = durationMs;
        self.pattern = pattern;
    }
}

// Timing + vibration engine for all three modes. One instance, owned by the app
// and shared with the running screen.
class VibrationController {

    hidden var mTimer as Timer.Timer;
    hidden var mSyncTimer as Timer.Timer;
    hidden var mRunning = false;
    hidden var mMode = Config.MODE_ALTERNATING;
    hidden var mStartMs = 0;
    hidden var mSyncAnchor = 0;
    hidden var mPhases as Array<BreathPhase> = [];
    hidden var mPhaseIdx = 0;
    const SLOT_MS = 250; // breathing motif slot length

    function initialize() {
        mTimer = new Timer.Timer();
        mSyncTimer = new Timer.Timer();
    }

    function isRunning() as Boolean { return mRunning; }
    function mode() as Number { return mMode; }
    function elapsedMs() as Number { return mStartMs == 0 ? 0 : System.getTimer() - mStartMs; }

    function start() as Void {
        if (mRunning) { return; }
        mMode = Config.mode;
        mRunning = true;
        mStartMs = System.getTimer();

        if (mMode == Config.MODE_ALTERNATING) {
            startAlternating();
        } else if (mMode == Config.MODE_INTERVAL) {
            mTimer.start(method(:onIntervalTick), Config.intervalMs(), true);
        } else {
            startBreathing();
        }
    }

    function stop() as Void {
        if (!mRunning) { return; }
        mRunning = false;
        mTimer.stop();
        mSyncTimer.stop();
        if (mMode == Config.MODE_ALTERNATING) {
            Comm.sendStop(); // failure (no phone) is ignored; the watch keeps going
        }
    }

    // Re-read the (possibly changed) config and apply it live, only if running.
    function restart() as Void {
        if (mRunning) {
            stop();
            start();
        }
    }

    // Alternating: align watch + phone to a shared wall-clock second so their
    // buzzes interleave instead of landing together. The watch picks the next
    // whole second as the anchor and sends it to the phone; both start there.
    // Watch buzzes at anchor, anchor+2*speed, ...; phone one interval later.
    hidden function startAlternating() as Void {
        mSyncAnchor = Time.now().value() + 1; // next whole epoch second (~0.5s avg lead)
        Comm.sendStart(Config.speedMs(), mSyncAnchor);
        // The watch clock has 1-second resolution, so poll to catch the boundary.
        mSyncTimer.start(method(:onSyncPoll), 16, true);
    }

    function onSyncPoll() as Void {
        if (!mRunning) { mSyncTimer.stop(); return; }
        if (Time.now().value() >= mSyncAnchor) {
            mSyncTimer.stop();
            vibrate(100, altPulseMs()); // first watch buzz, on the anchor
            mTimer.start(method(:onAltTick), 2 * Config.speedMs(), true);
        }
    }

    function onAltTick() as Void {
        if (!mRunning) { return; }
        vibrate(100, altPulseMs());
        var durMin = Config.durationMin();
        if (durMin > 0 && elapsedMs() >= durMin * 60000) {
            stop();
            WatchUi.requestUpdate();
        }
    }

    hidden function altPulseMs() as Number {
        var p = Config.speedMs() / 2;
        return p > 300 ? 300 : (p < 100 ? 100 : p);
    }

    function onIntervalTick() as Void {
        if (mRunning) { vibrate(100, 300); }
    }

    // Breathing: at each phase change, play that stage's binary on/off motif
    // once, then wait out the phase in silence.
    hidden function startBreathing() as Void {
        mPhases = buildPhases();
        mPhaseIdx = -1;
        advancePhase();
    }

    hidden function buildPhases() as Array<BreathPhase> {
        var raw;
        if (Config.presetIdx == Config.PRESET_SIGH) {
            raw = [
                new BreathPhase("Inhale", 2000, BREATHE_INHALE),
                new BreathPhase("Inhale", 1000, BREATHE_INHALE),
                new BreathPhase("Hold", 0, BREATHE_HOLD),
                new BreathPhase("Exhale", 8000, BREATHE_EXHALE),
                new BreathPhase("Hold", 2000, BREATHE_HOLD)
            ];
        } else if (Config.presetIdx == Config.PRESET_478) {
            raw = [
                new BreathPhase("Inhale", 4000, BREATHE_INHALE),
                new BreathPhase("Hold", 7000, BREATHE_HOLD),
                new BreathPhase("Exhale", 8000, BREATHE_EXHALE),
                new BreathPhase("Hold", 0, BREATHE_HOLD)
            ];
        } else {
            var c = Config.customMs;
            raw = [
                new BreathPhase("Inhale", c[0], BREATHE_INHALE),
                new BreathPhase("Inhale", c[1], BREATHE_INHALE),
                new BreathPhase("Hold", c[2], BREATHE_HOLD),
                new BreathPhase("Exhale", c[3], BREATHE_EXHALE),
                new BreathPhase("Hold", c[4], BREATHE_HOLD)
            ];
        }

        // Drop zero-length phases so the cycle never stalls.
        var phases = [];
        for (var i = 0; i < raw.size(); i++) {
            if (raw[i].durationMs > 0) { phases.add(raw[i]); }
        }
        return phases;
    }

    hidden function advancePhase() as Void {
        if (!mRunning || mPhases.size() == 0) { return; }
        mPhaseIdx = (mPhaseIdx + 1) % mPhases.size();
        var phase = mPhases[mPhaseIdx];
        playMotif(phase.pattern);
        mTimer.start(method(:onBreathPhaseEnd), phase.durationMs, false);
    }

    function onBreathPhaseEnd() as Void {
        if (mRunning) { advancePhase(); }
    }

    function currentPhaseName() as String {
        if (mMode != Config.MODE_BREATHING || mPhaseIdx < 0 || mPhaseIdx >= mPhases.size()) {
            return "";
        }
        return mPhases[mPhaseIdx].name;
    }

    // On/off motif, one bool per 250 ms slot, played once per phase:
    //   inhale "-.-."   exhale "---."   holds silent.
    hidden function motifFor(pattern as Number) as Array<Boolean> {
        if (pattern == BREATHE_INHALE) { return [true, false, true, false]; }
        if (pattern == BREATHE_EXHALE) { return [true, true, false, false]; }
        if (pattern == BREATHE_HOLD) { return [true, false, false, true]; }
        return [false];
    }

    // Render the motif as a single vibration: runs of on-slots merge into one
    // buzz, off-slots become gaps, trailing silence is dropped (<= 8 profiles).
    hidden function playMotif(pattern as Number) as Void {
        if (!(Attention has :vibrate)) { return; }
        var motif = motifFor(pattern);
        var profiles = [];
        var i = 0;
        while (i < motif.size()) {
            var on = motif[i];
            var run = 1;
            while (i + run < motif.size() && motif[i + run] == on) { run++; }
            if (on) {
                profiles.add(new Attention.VibeProfile(100, run * SLOT_MS));
            } else if (i + run < motif.size()) {
                profiles.add(new Attention.VibeProfile(0, run * SLOT_MS));
            }
            i += run;
        }
        if (profiles.size() > 0) {
            Attention.vibrate(profiles as Array<Attention.VibeProfile>);
        }
    }

    hidden function vibrate(dutyCycle as Number, lengthMs as Number) as Void {
        if (Attention has :vibrate) {
            Attention.vibrate([new Attention.VibeProfile(dutyCycle, lengthMs)]);
        }
    }
}
