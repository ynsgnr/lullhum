using Toybox.Application;
using Toybox.WatchUi;

// Owns the shared VibrationController so timing survives view transitions.
class LullhumApp extends Application.AppBase {

    hidden var mController as VibrationController;

    function initialize() {
        AppBase.initialize();
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

    function getInitialView() {
        return [ new ModeMenu(), new ModeDelegate() ];
    }
}

// Convenience accessor used by views/delegates.
function getController() as VibrationController {
    var app = Application.getApp() as LullhumApp;
    return app.getController();
}
