using Toybox.WatchUi;
using Toybox.Graphics;
using Toybox.Timer;
using Toybox.System;

// Running screen: auto-starts on show and refreshes the elapsed/phase readout.
class RunningView extends WatchUi.View {

    hidden var mController as VibrationController;
    hidden var mUiTimer as Timer.Timer or Null = null;

    function initialize() {
        View.initialize();
        mController = getController();
    }

    function onShow() {
        mController.start();
        mUiTimer = new Timer.Timer();
        mUiTimer.start(method(:onUiTick), 250, true);
    }

    function onHide() {
        if (mUiTimer != null) {
            mUiTimer.stop();
        }
    }

    function onUiTick() as Void {
        WatchUi.requestUpdate();
    }

    function onUpdate(dc) {
        dc.setColor(Graphics.COLOR_WHITE, Graphics.COLOR_BLACK);
        dc.clear();

        var cx = dc.getWidth() / 2;
        var cy = dc.getHeight() / 2;

        dc.drawText(cx, cy - 60, Graphics.FONT_SMALL, modeName(),
            Graphics.TEXT_JUSTIFY_CENTER);

        var status = mController.isRunning() ? "RUNNING" : "STOPPED";
        var color = mController.isRunning() ? Graphics.COLOR_GREEN : Graphics.COLOR_RED;
        dc.setColor(color, Graphics.COLOR_BLACK);
        dc.drawText(cx, cy - 20, Graphics.FONT_MEDIUM, status,
            Graphics.TEXT_JUSTIFY_CENTER);

        dc.setColor(Graphics.COLOR_WHITE, Graphics.COLOR_BLACK);
        dc.drawText(cx, cy + 20, Graphics.FONT_NUMBER_MILD, formatElapsed(),
            Graphics.TEXT_JUSTIFY_CENTER);

        var detail = mController.currentPhaseName();
        if (detail.equals("")) {
            detail = "SELECT: start/stop";
        }
        dc.drawText(cx, cy + 60, Graphics.FONT_TINY, detail,
            Graphics.TEXT_JUSTIFY_CENTER);
    }

    hidden function modeName() {
        var m = mController.mode();
        if (m == Config.MODE_ALTERNATING) { return "Alternating"; }
        if (m == Config.MODE_INTERVAL) { return "Interval"; }
        return "Breathing";
    }

    hidden function formatElapsed() {
        var totalSec = mController.elapsedMs() / 1000;
        var min = totalSec / 60;
        var sec = totalSec % 60;
        return min.format("%02d") + ":" + sec.format("%02d");
    }
}

class RunningDelegate extends WatchUi.BehaviorDelegate {
    hidden var mController as VibrationController;

    function initialize() {
        BehaviorDelegate.initialize();
        mController = getController();
    }

    // ENTER key / tap toggles start/stop.
    function onSelect() {
        if (mController.isRunning()) {
            mController.stop();
        } else {
            mController.start();
        }
        WatchUi.requestUpdate();
        return true;
    }

    // BACK stops and returns to config.
    function onBack() {
        mController.stop();
        WatchUi.popView(WatchUi.SLIDE_RIGHT);
        return true;
    }
}
