using Toybox.WatchUi;

// First screen: choose one of the three modes.
class ModeMenu extends WatchUi.Menu2 {
    function initialize() {
        Menu2.initialize({ :title => "Lullhum" });
        addItem(new WatchUi.MenuItem("Alternating", "Watch + Phone", :alternating, {}));
        addItem(new WatchUi.MenuItem("Interval", "Watch only", :interval, {}));
        addItem(new WatchUi.MenuItem("Breathing", "Watch only", :breathing, {}));
    }
}

class ModeDelegate extends WatchUi.Menu2InputDelegate {
    function initialize() {
        Menu2InputDelegate.initialize();
    }

    function onSelect(item) {
        var id = item.getId();
        if (id == :alternating) {
            Config.mode = Config.MODE_ALTERNATING;
            applyMode();
            WatchUi.pushView(new AltConfigMenu(), new AltConfigDelegate(), WatchUi.SLIDE_LEFT);
        } else if (id == :interval) {
            Config.mode = Config.MODE_INTERVAL;
            applyMode();
            WatchUi.pushView(new IntervalConfigMenu(), new IntervalConfigDelegate(), WatchUi.SLIDE_LEFT);
        } else {
            Config.mode = Config.MODE_BREATHING;
            applyMode();
            WatchUi.pushView(new BreathConfigMenu(), new BreathConfigDelegate(), WatchUi.SLIDE_LEFT);
        }
    }

    // Persist the new mode and apply it live if currently running.
    hidden function applyMode() as Void {
        Config.save();
        getController().restart();
    }
}
