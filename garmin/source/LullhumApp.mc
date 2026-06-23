using Toybox.Application;
using Toybox.WatchUi;

// Owns the shared VibrationController so timing survives view transitions.
class LullhumApp extends Application.AppBase {

    hidden var mController as VibrationController?;

    function initialize() {
        AppBase.initialize();
        Config.load();
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
        return [ new RunningView(), new RunningDelegate() ];
    }
}

// Convenience accessor used by views/delegates.
function getController() as VibrationController {
    var app = Application.getApp() as LullhumApp;
    return app.getController();
}
