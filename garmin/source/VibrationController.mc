import Toybox.Lang;
using Toybox.Attention;
using Toybox.Timer;
using Toybox.System;
using Toybox.WatchUi;

class BreathPhase {
    var name as String;
    var durationMs as Number;
    var vibrate as Boolean;

    function initialize(name as String, durationMs as Number, vibrate as Boolean) {
        self.name = name;
        self.durationMs = durationMs;
        self.vibrate = vibrate;
    }
}

// Timing + vibration engine for all three modes. One instance, owned by the app
// and shared with the running screen.
class VibrationController {

    hidden var mTimer as Timer.Timer;
    hidden var mRunning = false;
    hidden var mMode = Config.MODE_ALTERNATING;
    hidden var mStartMs = 0;
    hidden var mCount = 0;
    hidden var mPhases as Array<BreathPhase> = [];
    hidden var mPhaseIdx = 0;

    function initialize() {
        mTimer = new Timer.Timer();
    }

    function isRunning() as Boolean { return mRunning; }
    function mode() as Number { return mMode; }
    function elapsedMs() as Number { return mStartMs == 0 ? 0 : System.getTimer() - mStartMs; }

    function start() as Void {
        if (mRunning) { return; }
        mMode = Config.mode;
        mRunning = true;
        mCount = 0;
        mStartMs = System.getTimer();

        if (mMode == Config.MODE_ALTERNATING) {
            Comm.sendStart(Config.speedMs());
            mTimer.start(method(:onAltTick), Config.speedMs(), true);
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
        if (mMode == Config.MODE_ALTERNATING) {
            Comm.sendStop(); // failure (no phone) is ignored; the watch keeps going
        }
    }

    // Alternating: one tick per "speed" ms. Watch buzzes on odd ticks; the phone
    // handles even ticks independently, offset by one interval.
    function onAltTick() as Void {
        if (!mRunning) { return; }
        mCount++;
        if (mCount % 2 == 1) { vibrate(100, altPulseMs()); }

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

    // Breathing: cycle through phases, buzzing during inhale/exhale only.
    hidden function startBreathing() as Void {
        mPhases = buildPhases();
        mPhaseIdx = -1;
        advancePhase();
    }

    hidden function buildPhases() as Array<BreathPhase> {
        var raw;
        if (Config.presetIdx == Config.PRESET_SIGH) {
            raw = [
                new BreathPhase("Inhale", 2000, true),
                new BreathPhase("Inhale", 1000, true),
                new BreathPhase("Hold", 0, false),
                new BreathPhase("Exhale", 8000, true),
                new BreathPhase("Hold", 2000, false)
            ];
        } else if (Config.presetIdx == Config.PRESET_478) {
            raw = [
                new BreathPhase("Inhale", 4000, true),
                new BreathPhase("Hold", 7000, false),
                new BreathPhase("Exhale", 8000, true),
                new BreathPhase("Hold", 0, false)
            ];
        } else {
            var c = Config.customMs;
            raw = [
                new BreathPhase("Inhale", c[0], true),
                new BreathPhase("Inhale", c[1], true),
                new BreathPhase("Hold", c[2], false),
                new BreathPhase("Exhale", c[3], true),
                new BreathPhase("Hold", c[4], false)
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
        if (phase.vibrate) { vibrate(25, phase.durationMs); }
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

    hidden function vibrate(dutyCycle as Number, lengthMs as Number) as Void {
        if (Attention has :vibrate) {
            Attention.vibrate([new Attention.VibeProfile(dutyCycle, lengthMs)]);
        }
    }
}
