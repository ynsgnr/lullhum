import Toybox.Lang;
using Toybox.Communications;
using Toybox.Sensor;
using Toybox.SensorHistory;
using Toybox.Time;
using Toybox.Time.Gregorian;
using Toybox.Application;
using Toybox.Application.Storage;
using Toybox.Background;
using Toybox.PersistedContent;

// Per-session relaxation metrics pushed to Home Assistant as plain entities.
//
// Each session writes a handful of ordinary `sensor.lullhum_*` states that HA
// renders natively with no template / card / config: the mode is a text state
// (`sensor.lullhum_session`) that shows as a History timeline bar, and the rest
// are numeric states that show as History lines. Metrics are framed as
// baseline -> during -> recovery; heart rate is the primary proxy, with Garmin's
// HRV-derived stress and respiration as stronger parasympathetic markers.
// Nothing is sent unless the HA URL + token are configured.
module Metrics {

    // Sessions shorter than this are ignored (accidental starts / config churn).
    const MIN_SESSION_SEC = 30;

    var active = false;
    var sessionType = "";
    var startSec = 0;
    var endSec = 0;

    // Heart rate, accumulated live from sensor events.
    var hrSum = 0;
    var hrCount = 0;

    // Respiration / stress baselines, sampled from history at start.
    var respStart = null;
    var stressStart = null;

    // Send queue, drained sequentially in the background; bgMode lets the final
    // callback end the background process. pubStart/pubEnd are the session window
    // (ISO) attached to every entity for context.
    var pending = [];
    var bgMode = false;
    var pubStart = "";
    var pubEnd = "";

    function onSessionStart(type as String) as Void {
        if (!configured()) { return; }
        active = true;
        sessionType = type;
        startSec = Time.now().value();
        hrSum = 0; hrCount = 0;
        respStart = newestRespiration();
        stressStart = newestStress();
        if (Sensor has :setEnabledSensors) {
            Sensor.setEnabledSensors([Sensor.SENSOR_HEARTRATE]);
            Sensor.enableSensorEvents(new Lang.Method(Metrics, :onSensor));
        }
        // Mark the real session start now (app is foreground), so the mode
        // entity's native History bar begins at the true time.
        postMode(sessionType, isoTime(startSec), "");
    }

    function onSensor(info as Sensor.Info) as Void {
        if (!active) { return; }
        var hr = info.heartRate;
        if (hr != null && hr > 0) {
            hrSum += hr;
            hrCount++;
        }
    }

    function onSessionEnd() as Void {
        if (!active) { return; }
        active = false;
        if (Sensor has :enableSensorEvents) { Sensor.enableSensorEvents(null); }

        endSec = Time.now().value();
        if (endSec - startSec < MIN_SESSION_SEC || hrCount == 0) {
            postMode("idle", isoTime(startSec), isoTime(endSec)); // close the bar
            return;
        }

        // Stash the session (baseline read back from history); the background
        // wake adds recovery and sends everything. Delivery is background-only:
        // the app has no stop button (closing it is "stop"), so an immediate send
        // would be cut off mid-queue.
        var rec = {};
        rec.put("mode", sessionType);
        rec.put("start", isoTime(startSec));
        rec.put("end", isoTime(endSec));
        rec.put("end_epoch", endSec);
        rec.put("rec_win", recoveryWindowSec());
        rec.put("duration_sec", endSec - startSec);
        rec.put("hr_avg", hrSum / hrCount);
        var hrBaseline = avgHrInWindow(startSec - baselineWindowSec(), startSec);
        if (hrBaseline != null) { rec.put("hr_baseline", hrBaseline); }
        if (stressStart != null) { rec.put("stress_baseline", stressStart); }
        if (respStart != null) { rec.put("resp_baseline", respStart); }
        Storage.setValue("pending_session", rec);
        registerRecovery();
        // Best-effort live close (flushes if the app stays open, e.g. a timed
        // session completing); if you stop by closing the app it won't flush, so
        // the background wake closes the bar as a fallback.
        postMode("idle", isoTime(startSec), isoTime(endSec));
    }

    // ---- Recovery + send (background) --------------------------------------

    function registerRecovery() as Void {
        if (!(Toybox has :Background) || !(Background has :registerForTemporalEvent)) { return; }
        if (baseUrl() == null) { return; }
        try {
            Background.registerForTemporalEvent(new Time.Moment(endSec + recoveryWindowSec()));
        } catch (e) {
            // e.g. an event is already scheduled; the latest session wins.
        }
    }

    // Called from BackgroundService.onTemporalEvent once the recovery window has
    // elapsed: reads the recovery window from history and sends every entity.
    // Ordered most-important-first so a background timeout drops only the tail.
    function pushRecovery() as Void {
        bgMode = true;
        var rec = Storage.getValue("pending_session");
        if (!(rec instanceof Lang.Dictionary) || baseUrl() == null) { finishBg(); return; }

        sessionType = rec.get("mode");
        pubStart = rec.get("start");
        pubEnd = rec.get("end");

        var hrBaseline = rec.get("hr_baseline");
        var hrRec = null;
        var recEnd = rec.get("end_epoch");
        if (recEnd instanceof Lang.Number) {
            var winSec = rec.get("rec_win");
            if (!(winSec instanceof Lang.Number)) { winSec = 900; }
            hrRec = avgHrInWindow(recEnd, recEnd + winSec);
        }

        pending = [];
        addSessionClose(rec);  // close the mode bar (fallback if live end didn't flush)
        if (hrRec != null && hrBaseline instanceof Lang.Number) {
            addMetric("hr_recovery_delta", "Lullhum HR recovery delta", hrRec - hrBaseline, "bpm");
        }
        if (hrBaseline instanceof Lang.Number) { addMetric("hr_baseline", "Lullhum HR baseline", hrBaseline, "bpm"); }
        if (hrRec != null) { addMetric("hr_recovery", "Lullhum HR recovery", hrRec, "bpm"); }
        addMetric("hr_avg", "Lullhum HR avg", rec.get("hr_avg"), "bpm");
        addMetric("duration", "Lullhum duration", rec.get("duration_sec"), "s");

        var stressBase = rec.get("stress_baseline");
        if (stressBase != null) { addMetric("stress_baseline", "Lullhum stress baseline", stressBase, null); }
        var stressRec = newestStress();
        if (stressRec != null) { addMetric("stress_recovery", "Lullhum stress recovery", stressRec, null); }
        var respBase = rec.get("resp_baseline");
        if (respBase != null) { addMetric("resp_baseline", "Lullhum respiration baseline", respBase, "br/min"); }
        var respRec = newestRespiration();
        if (respRec != null) { addMetric("resp_recovery", "Lullhum respiration recovery", respRec, "br/min"); }

        Storage.deleteValue("pending_session");
        if (pending.size() == 0) { finishBg(); return; }
        sendNext();
    }

    function finishBg() as Void {
        if (bgMode && (Toybox has :Background)) {
            Background.exit(null);
        }
    }

    // ---- Home Assistant REST states API ------------------------------------

    // Immediately set the mode entity's state (foreground, single POST). Used to
    // mark the real session start (state = mode) and end (state = "idle"); HA's
    // built-in History renders the text state as a labeled timeline bar.
    function postMode(state as String, startIso as String, endIso as String) as Void {
        if (baseUrl() == null) { return; }
        pending = [{
            "path" => "/api/states/sensor.lullhum_session",
            "body" => {
                "state" => state,
                "attributes" => {
                    "friendly_name" => "Lullhum session",
                    "icon" => "mdi:meditation",
                    "mode" => sessionType,
                    "start" => startIso,
                    "end" => endIso
                }
            }
        }];
        sendNext();
    }

    // Background fallback: close the mode bar (state = "idle") in case the live
    // end POST didn't flush (app closed to stop). Carries the real times.
    function addSessionClose(rec as Dictionary) as Void {
        pending.add({
            "path" => "/api/states/sensor.lullhum_session",
            "body" => {
                "state" => "idle",
                "attributes" => {
                    "friendly_name" => "Lullhum session",
                    "icon" => "mdi:meditation",
                    "mode" => rec.get("mode"),
                    "start" => rec.get("start"),
                    "end" => rec.get("end"),
                    "duration_sec" => rec.get("duration_sec")
                }
            }
        });
    }

    // Numeric entity: state_class so HA records statistics and History draws a
    // line. Session mode + start/end ride along as attributes.
    function addMetric(key as String, name as String, value as Number, unit as String?) as Void {
        var attrs = {
            "friendly_name" => name,
            "state_class" => "measurement",
            "mode" => sessionType,
            "start" => pubStart,
            "end" => pubEnd
        };
        if (unit != null) { attrs.put("unit_of_measurement", unit); }
        pending.add({
            "path" => "/api/states/sensor.lullhum_" + key,
            "body" => { "state" => value, "attributes" => attrs }
        });
    }

    function sendNext() as Void {
        if (pending.size() == 0) { finishBg(); return; }
        var url = baseUrl();
        var token = Application.Properties.getValue("haToken");
        if (url == null || token == null) { pending = []; finishBg(); return; }
        var item = pending[0];
        var options = {
            :method => Communications.HTTP_REQUEST_METHOD_POST,
            :headers => {
                "Content-Type" => Communications.REQUEST_CONTENT_TYPE_JSON,
                "Authorization" => "Bearer " + token
            },
            :responseType => Communications.HTTP_RESPONSE_CONTENT_TYPE_JSON
        };
        Communications.makeWebRequest(
            url + item["path"], item["body"], options, new Lang.Method(Metrics, :onPost));
    }

    function onPost(responseCode as Number, data as Null or Dictionary or String or PersistedContent.Iterator) as Void {
        if (pending.size() > 0) { pending = pending.slice(1, null); }
        if (pending.size() == 0) { finishBg(); return; }
        sendNext();
    }

    // ---- Helpers -----------------------------------------------------------

    function configured() as Boolean {
        if (!(Communications has :makeWebRequest)) { return false; }
        return baseUrl() != null && Application.Properties.getValue("haToken") != null;
    }

    // Trimmed, non-empty HA base URL, or null if unset.
    function baseUrl() as String? {
        var raw = Application.Properties.getValue("haUrl");
        if (raw == null) { return null; }
        var u = raw.toString();
        while (u.length() > 0 && u.substring(u.length() - 1, u.length()).equals("/")) {
            u = u.substring(0, u.length() - 1);
        }
        return u.length() == 0 ? null : u;
    }

    function baselineWindowSec() as Number {
        var m = Application.Properties.getValue("baselineMin");
        var v = (m instanceof Lang.Number) ? m : 15;
        if (v < 1) { v = 1; }
        return v * 60;
    }

    function recoveryWindowSec() as Number {
        var m = Application.Properties.getValue("recoveryMin");
        var v = (m instanceof Lang.Number) ? m : 15;
        if (v < 5) { v = 5; } // Connect IQ temporal-event floor.
        return v * 60;
    }

    // Average HR over [fromSec, toSec] from stored history, or null if no
    // samples fall in the window.
    function avgHrInWindow(fromSec as Number, toSec as Number) as Number? {
        if (!(Toybox has :SensorHistory) || !(SensorHistory has :getHeartRateHistory)) { return null; }
        try {
            var span = Time.now().value() - fromSec + 60;
            if (span < 1) { span = 1; }
            var it = SensorHistory.getHeartRateHistory({ :period => new Time.Duration(span), :order => SensorHistory.ORDER_NEWEST_FIRST });
            if (it == null) { return null; }
            var sum = 0;
            var n = 0;
            var s = it.next();
            while (s != null) {
                if (s.data != null && s.when != null) {
                    var w = s.when.value();
                    if (w >= fromSec && w <= toSec) { sum += s.data; n++; }
                }
                s = it.next();
            }
            return (n > 0) ? sum / n : null;
        } catch (e) {
            return null;
        }
    }

    function newestStress() as Number? {
        if (!(Toybox has :SensorHistory) || !(SensorHistory has :getStressHistory)) { return null; }
        try {
            return sampleValue(SensorHistory.getStressHistory({ :period => 1, :order => SensorHistory.ORDER_NEWEST_FIRST }));
        } catch (e) {
            return null;
        }
    }

    function newestRespiration() as Number? {
        if (!(Toybox has :SensorHistory) || !(SensorHistory has :getRespirationRateHistory)) { return null; }
        try {
            return sampleValue(SensorHistory.getRespirationRateHistory({ :period => 1, :order => SensorHistory.ORDER_NEWEST_FIRST }));
        } catch (e) {
            return null;
        }
    }

    function sampleValue(it) as Number? {
        if (it == null) { return null; }
        var s = it.next();
        if (s == null || s.data == null) { return null; }
        return s.data;
    }

    // ISO 8601 UTC, e.g. 2026-06-23T14:05:09Z.
    function isoTime(sec as Number) as String {
        var g = Gregorian.utcInfo(new Time.Moment(sec), Time.FORMAT_SHORT);
        return g.year.format("%04d") + "-" + g.month.format("%02d") + "-" + g.day.format("%02d") +
            "T" + g.hour.format("%02d") + ":" + g.min.format("%02d") + ":" + g.sec.format("%02d") + "Z";
    }
}
