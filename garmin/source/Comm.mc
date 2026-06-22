using Toybox.Communications;

// Phone messaging for Alternating mode: sends start (with speed) / stop to the
// Android companion. Transmit failures are ignored so the watch runs solo.
module Comm {

    // anchorSec: shared wall-clock second the phone aligns its buzzes to.
    function sendStart(speedMs, anchorSec) {
        if (Communications has :transmit) {
            var payload = { "cmd" => "start", "speed" => speedMs, "anchor" => anchorSec };
            Communications.transmit(payload, null, new CommListener());
        }
    }

    function sendStop() {
        if (Communications has :transmit) {
            var payload = { "cmd" => "stop" };
            Communications.transmit(payload, null, new CommListener());
        }
    }

    // Interval mode: ask the phone to run a background reminder that buzzes the
    // watch via a periodic notification (phone enforces the 5-minute minimum).
    function sendReminderStart(intervalSec) {
        if (Communications has :transmit) {
            var payload = { "cmd" => "reminderStart", "intervalSec" => intervalSec };
            Communications.transmit(payload, null, new CommListener());
        }
    }

    function sendReminderStop() {
        if (Communications has :transmit) {
            var payload = { "cmd" => "reminderStop" };
            Communications.transmit(payload, null, new CommListener());
        }
    }
}

class CommListener extends Communications.ConnectionListener {
    function initialize() {
        Communications.ConnectionListener.initialize();
    }

    function onComplete() {}
    function onError() {}
}
