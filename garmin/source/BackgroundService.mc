using Toybox.System;
using Toybox.Background;
import Toybox.Lang;

// Wakes ~recovery-window minutes after a session ends (scheduled by Metrics via
// a one-shot temporal event) and pushes the post-session recovery readings to
// Home Assistant. Runs even after the user has exited the app.
(:background)
class BackgroundService extends System.ServiceDelegate {

    function initialize() {
        System.ServiceDelegate.initialize();
    }

    function onTemporalEvent() as Void {
        Metrics.pushRecovery();
    }
}
