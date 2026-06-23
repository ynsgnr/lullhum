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

        var endSec = Time.now().value();
        if (endSec - startSec < MIN_SESSION_SEC || hrCount == 0) { return; }

        var hrAvg = hrSum / hrCount;
        var attrs = {
            "friendly_name" => "Lullhum session",
            "unit_of_measurement" => "bpm",
            "session_type" => sessionType,
            "start" => isoTime(startSec),
            "end" => isoTime(endSec),
            "duration_sec" => endSec - startSec,
            "hr_start" => hrStart,
            "hr_end" => hrEnd,
            "hr_avg" => hrAvg,
            "hr_min" => hrMin,
            "hr_max" => hrMax,
            "hr_delta" => hrEnd - hrStart
        };

        var respEnd = newestRespiration();
        if (respStart != null) { attrs.put("resp_start", respStart); }
        if (respEnd != null) { attrs.put("resp_end", respEnd); }
        if (respStart != null && respEnd != null) { attrs.put("resp_delta", respEnd - respStart); }

        var stressEnd = newestStress();
        if (stressStart != null) { attrs.put("stress_start", stressStart); }
        if (stressEnd != null) { attrs.put("stress_end", stressEnd); }
        if (stressStart != null && stressEnd != null) { attrs.put("stress_delta", stressEnd - stressStart); }

        // hr_avg is the entity state so it graphs directly; the rest are
        // attributes for HA template sensors / history.
        post({ "state" => hrAvg, "attributes" => attrs });
    }

    // ---- Home Assistant REST states API ------------------------------------

    function post(payload as Dictionary) as Void {
        var url = baseUrl();
        var token = Application.Properties.getValue("haToken");
        if (url == null || token == null) { return; }
        var options = {
            :method => Communications.HTTP_REQUEST_METHOD_POST,
            :headers => {
                "Content-Type" => Communications.REQUEST_CONTENT_TYPE_JSON,
                "Authorization" => "Bearer " + token
            },
            :responseType => Communications.HTTP_RESPONSE_CONTENT_TYPE_JSON
        };
        Communications.makeWebRequest(
            url + "/api/states/sensor.lullhum_session", payload, options, new Lang.Method(Metrics, :onPost));
    }

    function onPost(responseCode as Number, data as Null or Dictionary or String or PersistedContent.Iterator) as Void {
        // Fire-and-forget; the watch keeps working regardless of HA's response.
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
