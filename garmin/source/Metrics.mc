import Toybox.Lang;
using Toybox.Communications;
using Toybox.Sensor;
using Toybox.SensorHistory;
using Toybox.Time;
using Toybox.Time.Gregorian;
using Toybox.Application;
using Toybox.PersistedContent;

// Per-session relaxation metrics pushed to Home Assistant.
//
// Heart rate is the primary proxy (lower / falling during a session suggests
// parasympathetic activation). Respiration rate and Garmin's HRV-derived stress
// score are captured at the start and end as stronger, lower-noise proxies for
// nervous-system down-regulation. Nothing is sent unless the HA URL + token are
// configured (Connect IQ app settings) and the session ran long enough to mean
// something.
module Metrics {

    // Sessions shorter than this are ignored (covers accidental starts and the
    // stop/start churn from live config edits).
    const MIN_SESSION_SEC = 30;

    var active = false;
    var sessionType = "";
    var startSec = 0;

    // Heart rate, accumulated live from sensor events.
    var hrStart = 0;
    var hrEnd = 0;
    var hrMin = 0;
    var hrMax = 0;
    var hrSum = 0;
    var hrCount = 0;

    // Respiration / stress baselines, sampled from history at start.
    var respStart = null;
    var stressStart = null;

    var endSec = 0;
    // Queue of one-per-metric POSTs, drained sequentially: Connect IQ only
    // reliably handles one web request at a time, so each fires the next.
    var pending = [];

    function onSessionStart(type as String) as Void {
        if (!configured()) { return; }
        active = true;
        sessionType = type;
        startSec = Time.now().value();
        hrStart = 0; hrEnd = 0; hrMin = 0; hrMax = 0; hrSum = 0; hrCount = 0;
        respStart = newestRespiration();
        stressStart = newestStress();
        if (Sensor has :setEnabledSensors) {
            Sensor.setEnabledSensors([Sensor.SENSOR_HEARTRATE]);
            Sensor.enableSensorEvents(new Lang.Method(Metrics, :onSensor));
        }
    }

    function onSensor(info as Sensor.Info) as Void {
        if (!active) { return; }
        var hr = info.heartRate;
        if (hr != null && hr > 0) {
            if (hrStart == 0) { hrStart = hr; }
            hrEnd = hr;
            hrSum += hr;
            hrCount++;
            if (hrMin == 0 || hr < hrMin) { hrMin = hr; }
            if (hr > hrMax) { hrMax = hr; }
        }
    }

    function onSessionEnd() as Void {
        if (!active) { return; }
        active = false;
        if (Sensor has :enableSensorEvents) { Sensor.enableSensorEvents(null); }

        endSec = Time.now().value();
        if (endSec - startSec < MIN_SESSION_SEC || hrCount == 0) { return; }

        // One real HA sensor entity per metric, each with state_class so HA's
        // statistics engine plots it over time directly (no template sensors).
        pending = [];
        addMetric("hr_avg", "Lullhum HR avg", hrSum / hrCount, "bpm");
        addMetric("hr_min", "Lullhum HR min", hrMin, "bpm");
        addMetric("hr_max", "Lullhum HR max", hrMax, "bpm");
        addMetric("hr_delta", "Lullhum HR delta", hrEnd - hrStart, "bpm");
        addMetric("duration", "Lullhum duration", endSec - startSec, "s");

        var respEnd = newestRespiration();
        if (respEnd != null) { addMetric("resp_end", "Lullhum respiration", respEnd, "br/min"); }
        if (respStart != null && respEnd != null) {
            addMetric("resp_delta", "Lullhum respiration delta", respEnd - respStart, "br/min");
        }

        var stressEnd = newestStress();
        if (stressEnd != null) { addMetric("stress_end", "Lullhum stress", stressEnd, null); }
        if (stressStart != null && stressEnd != null) {
            addMetric("stress_delta", "Lullhum stress delta", stressEnd - stressStart, null);
        }

        sendNext();
    }

    // ---- Home Assistant REST states API ------------------------------------

    // Queue a POST that sets sensor.lullhum_<key> to a numeric state, tagged so
    // HA records long-term statistics for it. session_type/start/end ride along
    // as attributes for context.
    function addMetric(key as String, name as String, value as Number, unit as String?) as Void {
        var attrs = {
            "friendly_name" => name,
            "state_class" => "measurement",
            "session_type" => sessionType,
            "start" => isoTime(startSec),
            "end" => isoTime(endSec)
        };
        if (unit != null) { attrs.put("unit_of_measurement", unit); }
        pending.add({
            "path" => "/api/states/sensor.lullhum_" + key,
            "body" => { "state" => value, "attributes" => attrs }
        });
    }

    function sendNext() as Void {
        if (pending.size() == 0) { return; }
        var url = baseUrl();
        var token = Application.Properties.getValue("haToken");
        if (url == null || token == null) { pending = []; return; }
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
        // Drop the request just sent and chain the next, regardless of result;
        // the watch keeps working even if HA is unreachable.
        if (pending.size() > 0) { pending = pending.slice(1, null); }
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

    function newestStress() as Number? {
        if (!(Toybox has :SensorHistory) || !(SensorHistory has :getStressHistory)) { return null; }
        var it = SensorHistory.getStressHistory({ :period => 1, :order => SensorHistory.ORDER_NEWEST_FIRST });
        return sampleValue(it);
    }

    function newestRespiration() as Number? {
        if (!(Toybox has :SensorHistory) || !(SensorHistory has :getRespirationRateHistory)) { return null; }
        var it = SensorHistory.getRespirationRateHistory({ :period => 1, :order => SensorHistory.ORDER_NEWEST_FIRST });
        return sampleValue(it);
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
