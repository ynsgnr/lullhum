using Toybox.WatchUi;

// Per-mode settings. Cycling a row updates the value, persists it, and applies
// it live. "Done" returns to the running screen and ensures it's vibrating.

// Persist + apply a change while a value is being cycled.
function applyChange() {
    Config.save();
    getController().restart();
    WatchUi.requestUpdate();
}

// Return to the foreground running screen (pop the config + mode menus) and start.
function finishConfig() {
    var controller = getController();
    if (!controller.isRunning()) { controller.start(); }
    WatchUi.popView(WatchUi.SLIDE_RIGHT); // close config menu
    WatchUi.popView(WatchUi.SLIDE_RIGHT); // close mode menu -> running screen
}

// ---- Mode 1: Alternating --------------------------------------------------

class AltConfigMenu extends WatchUi.Menu2 {
    function initialize() {
        Menu2.initialize({ :title => "Alternating" });
        addItem(new WatchUi.MenuItem("Speed", Config.speedLabel(), :speed, {}));
        addItem(new WatchUi.MenuItem("Duration", Config.durationLabel(), :duration, {}));
        addItem(new WatchUi.MenuItem("Done", null, :done, {}));
    }
}

class AltConfigDelegate extends WatchUi.Menu2InputDelegate {
    function initialize() { Menu2InputDelegate.initialize(); }

    function onSelect(item) {
        var id = item.getId();
        if (id == :done) { finishConfig(); return; }
        if (id == :speed) {
            Config.cycleSpeed();
            item.setSubLabel(Config.speedLabel());
        } else {
            Config.cycleDuration();
            item.setSubLabel(Config.durationLabel());
        }
        applyChange();
    }
}

// ---- Mode 2: Interval -----------------------------------------------------

class IntervalConfigMenu extends WatchUi.Menu2 {
    function initialize() {
        Menu2.initialize({ :title => "Interval" });
        addItem(new WatchUi.MenuItem("Interval", Config.intervalLabel(), :interval, {}));
        // Hand the interval to the phone to keep buzzing in the background (>=5 min).
        addItem(new WatchUi.MenuItem("Phone reminder", Config.phoneReminderLabel(), :phone, {}));
        addItem(new WatchUi.MenuItem("Done", null, :done, {}));
    }
}

class IntervalConfigDelegate extends WatchUi.Menu2InputDelegate {
    function initialize() { Menu2InputDelegate.initialize(); }

    function onSelect(item) {
        var id = item.getId();
        if (id == :done) {
            finishConfig();
        } else if (id == :phone) {
            Config.phoneReminderOn = !Config.phoneReminderOn;
            if (Config.phoneReminderOn) {
                Comm.sendReminderStart(Config.intervalSec());
            } else {
                Comm.sendReminderStop();
            }
            item.setSubLabel(Config.phoneReminderLabel());
            WatchUi.requestUpdate();
        } else {
            Config.cycleInterval();
            item.setSubLabel(Config.intervalLabel());
            applyChange();
        }
    }
}

// ---- Mode 3: Breathing ----------------------------------------------------

class BreathConfigMenu extends WatchUi.Menu2 {
    function initialize() {
        Menu2.initialize({ :title => "Breathing" });
        addItem(new WatchUi.MenuItem("Preset", Config.presetLabel(), :preset, {}));
        // Custom phase rows (used when preset = Custom).
        addItem(new WatchUi.MenuItem("Inhale 1", Config.customPhaseLabel(0), :p0, {}));
        addItem(new WatchUi.MenuItem("Inhale 2", Config.customPhaseLabel(1), :p1, {}));
        addItem(new WatchUi.MenuItem("Hold", Config.customPhaseLabel(2), :p2, {}));
        addItem(new WatchUi.MenuItem("Exhale", Config.customPhaseLabel(3), :p3, {}));
        addItem(new WatchUi.MenuItem("Hold 2", Config.customPhaseLabel(4), :p4, {}));
        addItem(new WatchUi.MenuItem("Done", null, :done, {}));
    }
}

class BreathConfigDelegate extends WatchUi.Menu2InputDelegate {
    function initialize() { Menu2InputDelegate.initialize(); }

    function onSelect(item) {
        var id = item.getId();
        if (id == :done) {
            finishConfig();
        } else if (id == :preset) {
            Config.cyclePreset();
            item.setSubLabel(Config.presetLabel());
            applyChange();
        } else {
            var phase = phaseIndex(id);
            Config.cycleCustomPhase(phase);
            item.setSubLabel(Config.customPhaseLabel(phase));
            applyChange();
        }
    }

    hidden function phaseIndex(id) {
        if (id == :p0) { return 0; }
        if (id == :p1) { return 1; }
        if (id == :p2) { return 2; }
        if (id == :p3) { return 3; }
        return 4;
    }
}
