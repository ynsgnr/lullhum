using Toybox.Communications;

// Phone messaging for Alternating mode: sends start (with speed) / stop to the
// Android companion. Transmit failures are ignored so the watch runs solo.
module Comm {

    function sendStart(speedMs) {
        if (Communications has :transmit) {
            var payload = { "cmd" => "start", "speed" => speedMs };
            Communications.transmit(payload, null, new CommListener());
        }
    }

    function sendStop() {
        if (Communications has :transmit) {
            var payload = { "cmd" => "stop" };
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
