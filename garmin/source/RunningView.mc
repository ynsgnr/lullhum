import Toybox.Lang;
using Toybox.WatchUi;
using Toybox.Graphics;
using Toybox.Timer;

// Running screen: auto-starts once with the saved selection and refreshes the readout.
class RunningView extends WatchUi.View {

    hidden var mController as VibrationController;
    hidden var mUiTimer as Timer.Timer;
    hidden var mAutoStarted = false;

    function initialize() {
        View.initialize();
        mController = getController();
        mUiTimer = new Timer.Timer();
    }

    function onShow() as Void {
        if (!mAutoStarted) {
            mAutoStarted = true;
            mController.start();
        }
        // The readout is mm:ss, so a 1 s refresh is enough (and easier on battery).
        mUiTimer.start(method(:onUiTick), 1000, true);
    }

    function onHide() as Void {
        mUiTimer.stop();
    }

    function onUiTick() as Void {
        WatchUi.requestUpdate();
    }

    // Positions are fractions of screen height and vertically centered, so text
    // stays clear of the round bezel on the Venu 3.
    function onUpdate(dc) {
        dc.setColor(Graphics.COLOR_WHITE, Graphics.COLOR_BLACK);
        dc.clear();

        var cx = dc.getWidth() / 2;
        var h = dc.getHeight();
        var center = Graphics.TEXT_JUSTIFY_CENTER | Graphics.TEXT_JUSTIFY_VCENTER;

        dc.drawText(cx, h * 0.30, Graphics.FONT_SMALL, modeName(), center);

        var running = mController.isRunning();
        dc.setColor(running ? Graphics.COLOR_GREEN : Graphics.COLOR_RED, Graphics.COLOR_BLACK);
        dc.drawText(cx, h * 0.45, Graphics.FONT_MEDIUM, running ? "RUNNING" : "PAUSED", center);

        dc.setColor(Graphics.COLOR_WHITE, Graphics.COLOR_BLACK);
        dc.drawText(cx, h * 0.60, Graphics.FONT_NUMBER_MILD, formatElapsed(), center);
        dc.drawText(cx, h * 0.74, Graphics.FONT_TINY, subtitle(), center);
    }

    hidden function modeName() {
        var m = mController.mode();
        if (m == Config.MODE_ALTERNATING) { return "Alternating"; }
        if (m == Config.MODE_INTERVAL) { return "Interval"; }
        return "Breathing";
    }

    hidden function subtitle() {
        var m = mController.mode();
        if (m == Config.MODE_BREATHING) {
            var phase = mController.currentPhaseName();
            return phase.equals("") ? Config.presetLabel() : phase;
        }
        if (m == Config.MODE_INTERVAL) { return Config.intervalLabel(); }
        return Config.speedLabel();
    }

    hidden function formatElapsed() {
        var totalSec = mController.elapsedMs() / 1000;
        return (totalSec / 60).format("%02d") + ":" + (totalSec % 60).format("%02d");
    }
}

class RunningDelegate extends WatchUi.BehaviorDelegate {
    hidden var mController as VibrationController;

    function initialize() {
        BehaviorDelegate.initialize();
        mController = getController();
    }

    // Physical select button.
    function onSelect() {
        toggle();
        return true;
    }

    // Screen tap.
    function onTap(evt) {
        toggle();
        return true;
    }

    // Menu button opens settings; vibration keeps running underneath.
    function onMenu() {
        WatchUi.pushView(new ModeMenu(), new ModeDelegate(), WatchUi.SLIDE_LEFT);
        return true;
    }

    // Back exits the app (and stops vibration — it can't run once closed).
    function onBack() {
        mController.stop();
        WatchUi.popView(WatchUi.SLIDE_RIGHT);
        return true;
    }

    hidden function toggle() as Void {
        if (mController.isRunning()) {
            mController.stop();
        } else {
            mController.start();
        }
        WatchUi.requestUpdate();
    }
}
