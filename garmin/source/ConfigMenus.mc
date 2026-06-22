using Toybox.WatchUi;

// Config screens: a parameter row cycles its value in place; "Start" launches.

function launchRunning() {
    WatchUi.pushView(new RunningView(), new RunningDelegate(), WatchUi.SLIDE_LEFT);
}

// ---- Mode 1: Alternating --------------------------------------------------

class AltConfigMenu extends WatchUi.Menu2 {
    function initialize() {
        Menu2.initialize({ :title => "Alternating" });
        addItem(new WatchUi.MenuItem("Speed", Config.speedLabel(), :speed, {}));
        addItem(new WatchUi.MenuItem("Duration", Config.durationLabel(), :duration, {}));
        addItem(new WatchUi.MenuItem("Start", null, :start, {}));
    }
}

class AltConfigDelegate extends WatchUi.Menu2InputDelegate {
    function initialize() { Menu2InputDelegate.initialize(); }

    function onSelect(item) {
        var id = item.getId();
        if (id == :speed) {
            Config.cycleSpeed();
            item.setSubLabel(Config.speedLabel());
            WatchUi.requestUpdate();
        } else if (id == :duration) {
            Config.cycleDuration();
            item.setSubLabel(Config.durationLabel());
            WatchUi.requestUpdate();
        } else if (id == :start) {
            launchRunning();
        }
    }
}

// ---- Mode 2: Interval -----------------------------------------------------

class IntervalConfigMenu extends WatchUi.Menu2 {
    function initialize() {
        Menu2.initialize({ :title => "Interval" });
        addItem(new WatchUi.MenuItem("Interval", Config.intervalLabel(), :interval, {}));
        addItem(new WatchUi.MenuItem("Start", null, :start, {}));
    }
}

class IntervalConfigDelegate extends WatchUi.Menu2InputDelegate {
    function initialize() { Menu2InputDelegate.initialize(); }

    function onSelect(item) {
        var id = item.getId();
        if (id == :interval) {
            Config.cycleInterval();
            item.setSubLabel(Config.intervalLabel());
            WatchUi.requestUpdate();
        } else if (id == :start) {
            launchRunning();
        }
    }
}

// ---- Mode 3: Breathing ----------------------------------------------------

class BreathConfigMenu extends WatchUi.Menu2 {
    function initialize() {
        Menu2.initialize({ :title => "Breathing" });
        addItem(new WatchUi.MenuItem("Preset", Config.presetLabel(), :preset, {}));
        // Custom phase rows (only used when preset = Custom).
        addItem(new WatchUi.MenuItem("Inhale 1", Config.customPhaseLabel(0), :p0, {}));
        addItem(new WatchUi.MenuItem("Inhale 2", Config.customPhaseLabel(1), :p1, {}));
        addItem(new WatchUi.MenuItem("Hold", Config.customPhaseLabel(2), :p2, {}));
        addItem(new WatchUi.MenuItem("Exhale", Config.customPhaseLabel(3), :p3, {}));
        addItem(new WatchUi.MenuItem("Hold 2", Config.customPhaseLabel(4), :p4, {}));
        addItem(new WatchUi.MenuItem("Start", null, :start, {}));
    }
}

class BreathConfigDelegate extends WatchUi.Menu2InputDelegate {
    function initialize() { Menu2InputDelegate.initialize(); }

    function onSelect(item) {
        var id = item.getId();
        if (id == :preset) {
            Config.cyclePreset();
            item.setSubLabel(Config.presetLabel());
            WatchUi.requestUpdate();
        } else if (id == :p0) {
            Config.cycleCustomPhase(0); item.setSubLabel(Config.customPhaseLabel(0)); WatchUi.requestUpdate();
        } else if (id == :p1) {
            Config.cycleCustomPhase(1); item.setSubLabel(Config.customPhaseLabel(1)); WatchUi.requestUpdate();
        } else if (id == :p2) {
            Config.cycleCustomPhase(2); item.setSubLabel(Config.customPhaseLabel(2)); WatchUi.requestUpdate();
        } else if (id == :p3) {
            Config.cycleCustomPhase(3); item.setSubLabel(Config.customPhaseLabel(3)); WatchUi.requestUpdate();
        } else if (id == :p4) {
            Config.cycleCustomPhase(4); item.setSubLabel(Config.customPhaseLabel(4)); WatchUi.requestUpdate();
        } else if (id == :start) {
            launchRunning();
        }
    }
}
