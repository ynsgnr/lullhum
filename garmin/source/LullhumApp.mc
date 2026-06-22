using Toybox.Application;
using Toybox.WatchUi;

// Owns the shared VibrationController so timing survives view transitions.
class LullhumApp extends Application.AppBase {

    hidden var mController as VibrationController;

    function initialize() {
        AppBase.initialize();
        Config.load();
        mController = new VibrationController();
    }

    function getController() as VibrationController {
        return mController;
    }

    function onStart(state) {
    }

    function onStop(state) {
        mController.stop();
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
