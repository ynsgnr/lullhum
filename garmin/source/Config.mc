import Toybox.Lang;
using Toybox.Application.Storage;

// Shared, mutable settings chosen on the config screens and read by the controller.
// Selections persist across launches via Application.Storage.
module Config {

    enum { MODE_ALTERNATING, MODE_INTERVAL, MODE_BREATHING }
    enum { PRESET_SIGH, PRESET_478, PRESET_BOX, PRESET_CUSTOM }

    var mode = MODE_ALTERNATING;

    // --- Alternating: ms per side, duration in minutes (0 = unlimited) ---
    var speedOptions as Array<Number> = [1000, 500, 250];
    var speedLabels as Array<String> = ["Slow", "Medium", "Fast"];
    var speedIdx = 1;
    var durationOptions as Array<Number> = [5, 10, 15, 30, 0];
    var durationIdx = 1;

    function speedMs() as Number { return speedOptions[speedIdx]; }
    function durationMin() as Number { return durationOptions[durationIdx]; }
    function cycleSpeed() as Void { speedIdx = (speedIdx + 1) % speedOptions.size(); }
    function cycleDuration() as Void { durationIdx = (durationIdx + 1) % durationOptions.size(); }

    function speedLabel() as String { return speedLabels[speedIdx]; }
    function durationLabel() as String {
        var d = durationMin();
        return d == 0 ? "Unlimited" : d.toString() + " min";
    }

    // --- Interval: seconds between pulses ---
    var intervalOptions as Array<Number> = [2, 5, 10, 30, 60, 120, 300, 600, 900, 1800];
    var intervalIdx = 1;

    function intervalMs() as Number { return intervalOptions[intervalIdx] * 1000; }
    function intervalSec() as Number { return intervalOptions[intervalIdx]; }
    function cycleInterval() as Void { intervalIdx = (intervalIdx + 1) % intervalOptions.size(); }

    // Live intent to run the phone's background reminder (not persisted; the
    // phone UI is the source of truth for whether it's actually running).
    var phoneReminderOn = false;
    function phoneReminderLabel() as String { return phoneReminderOn ? "On" : "Off"; }
    function intervalLabel() as String {
        var s = intervalOptions[intervalIdx];
        return s < 60 ? s.toString() + " sec" : (s / 60).toString() + " min";
    }

    // --- Breathing: preset + custom phase durations [inhale1, inhale2, hold, exhale, hold2] ---
    var presetIdx = PRESET_SIGH;
    var presetLabels as Array<String> = ["Phys. sigh", "4-7-8", "Box 4-4-4-4", "Custom"];
    var customMs as Array<Number> = [2000, 1000, 0, 8000, 2000];
    var phaseOptions as Array<Number> = [0, 1000, 2000, 3000, 4000, 5000, 6000, 7000, 8000, 10000];

    function cyclePreset() as Void { presetIdx = (presetIdx + 1) % presetLabels.size(); }
    function presetLabel() as String { return presetLabels[presetIdx]; }
    function cycleCustomPhase(phase as Number) as Void {
        var idx = (phaseOptions.indexOf(customMs[phase]) + 1) % phaseOptions.size();
        customMs[phase] = phaseOptions[idx];
    }
    function customPhaseLabel(phase as Number) as String {
        return (customMs[phase] / 1000.0).format("%.1f") + " s";
    }

    // --- Persistence ---
    function save() as Void {
        Storage.setValue("mode", mode);
        Storage.setValue("speedIdx", speedIdx);
        Storage.setValue("durationIdx", durationIdx);
        Storage.setValue("intervalIdx", intervalIdx);
        Storage.setValue("presetIdx", presetIdx);
        Storage.setValue("customMs", customMs);
    }

    function load() as Void {
        mode = readInt("mode", mode);
        speedIdx = readInt("speedIdx", speedIdx);
        durationIdx = readInt("durationIdx", durationIdx);
        intervalIdx = readInt("intervalIdx", intervalIdx);
        presetIdx = readInt("presetIdx", presetIdx);
        var cm = Storage.getValue("customMs");
        if (cm instanceof Array) { customMs = cm as Array<Number>; }
    }

    function readInt(key, dflt) {
        var v = Storage.getValue(key);
        return (v instanceof Number) ? v : dflt;
    }
}
