using Toybox.Application;
using Toybox.WatchUi;

// Owns the shared VibrationController so timing survives view transitions.
class LullhumApp extends Application.AppBase {

    hidden var mController as VibrationController?;

    // Kept deliberately lean: this runs for the background recovery-push service
    // too, whose memory budget is tiny. Loading the Config module here (with all
    // its option arrays) blew that budget and crashed the service before
    // getServiceDelegate() could run, so the recovery push never fired and no
    // metrics reached HA. Config is foreground-only state, so it loads in
    // getInitialView() instead.
    function initialize() {
        AppBase.initialize();
    }

    // Lazily created so the background service (recovery push) doesn't pull the
    // whole vibration engine into its small memory budget.
    function getController() as VibrationController {
        if (mController == null) {
            mController = new VibrationController();
        }
        return mController;
    }

    // Runs the post-session recovery read; see Metrics / BackgroundService.
    function getServiceDelegate() {
        return [ new BackgroundService() ];
    }

    function onStart(state) {
    }

    function onStop(state) {
        if (mController != null) {
            mController.stop();
        }
    }

    // Launch straight into the running screen; it auto-starts with the saved
    // selection. Settings are reachable from there via the menu button.
    function getInitialView() {
        Config.load();
        return [ new RunningView(), new RunningDelegate() ];
    }
}

// Convenience accessor used by views/delegates.
function getController() as VibrationController {
    var app = Application.getApp() as LullhumApp;
    return app.getController();
}
