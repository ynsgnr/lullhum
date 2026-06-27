import Toybox.Lang;
using Toybox.Communications;
using Toybox.Math;
using Toybox.System;
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
// (:background) is REQUIRED: the recovery push (pushRecovery and everything it
// calls) runs in the background temporal-event service. Without this annotation
// the compiler leaves the whole module out of the background memory image, and
// BackgroundService.onTemporalEvent faults ("Illegal Access (Out of Bounds) -
// Failed invoking <symbol>") the instant it tries to call into Metrics, so no
// session ever delivered its metrics. The foreground keeps full access too.
(:background)
module Metrics {

    // Sessions shorter than this are ignored (accidental starts / config churn).
    const MIN_SESSION_SEC = 30;

    var active = false;
    var sessionType = "";
    var startSec = 0;
    var endSec = 0;

    // Heart rate, accumulated live from sensor events. hrMin tracks the lowest
    // beat seen during the session (-1 until the first sample).
    var hrSum = 0;
    var hrCount = 0;
    var hrMin = -1;

    // HRV (RMSSD, ms) computed live from beat-to-beat R-R intervals delivered by
    // Sensor.registerSensorDataListener. The platform exposes no HRV *history*, and
    // the R-R listener only runs in the foreground, so there's no true pre-session
    // or post-recovery beat-to-beat HRV to read. Instead we window the live stream:
    //   start  = first HRV_START_SEC of the session ("before"/settling-in)
    //   avg    = the whole session ("during")
    //   end    = roughly the last minute or two ("after"/end-of-session)
    // A rising RMSSD start -> end is parasympathetic activation. RMSSD = sqrt(mean
    // of squared successive R-R differences); we accumulate the squared diffs in
    // O(1) memory (no buffers) with two rolling 60 s buckets approximating the end.
    const HRV_START_SEC = 60;
    const HRV_BUCKET_SEC = 60;
    // Plausible adult R-R interval band (ms); anything outside is an artefact.
    const RR_MIN_MS = 300;
    const RR_MAX_MS = 2000;
    var mLastRr = 0;            // previous accepted R-R, for successive differences
    var hrvSqAll = 0;  var hrvNAll = 0;   // whole session
    var hrvSqStart = 0; var hrvNStart = 0; // first window
    var hrvSqCur = 0;  var hrvNCur = 0;    // current 60 s bucket (end estimate)
    var hrvSqPrev = 0; var hrvNPrev = 0;   // previous 60 s bucket
    var hrvBucketEdge = 0;     // session-seconds boundary of the current bucket

    // Respiration / stress baselines, sampled from history at start.
    var respStart = null;
    var stressStart = null;

    // Send queue, drained sequentially in the background; bgMode lets the final
    // callback end the background process. pubStart/pubEnd are the session window
    // (ISO) attached to every entity for context. In bgMode the queue is mirrored
    // to Storage (PENDING_QUEUE) so a wake that gets killed before draining can be
    // resumed by the next scheduled wake — see scheduleDrainRetry / pushRecovery.
    const PENDING_QUEUE = "pending_queue";     // remaining POSTs (survives a killed wake)
    const PENDING_SESSION = "pending_session"; // the stashed session, until its queue drains
    // A queue item that keeps failing to send (e.g. a malformed entity, or HA
    // unreachable for hours) is dropped after this many delivery attempts so it
    // can't pin the queue and respawn a background wake forever. Each item carries
    // its own attempt count (TRIES_KEY) across wakes via the persisted queue.
    const MAX_TRIES = 8;
    const TRIES_KEY = "t";
    var pending = [];
    var bgMode = false;
    var pubStart = "";
    var pubEnd = "";
    // Optional one-shot callback fired when the foreground send queue drains,
    // used to defer app exit until the idle end-marker has actually been sent.
    var mExitCb = null;

    function onSessionStart(type as String) as Void {
        if (!configured()) { return; }
        active = true;
        sessionType = type;
        startSec = Time.now().value();
        hrSum = 0; hrCount = 0; hrMin = -1;
        resetHrv();
        respStart = newestRespiration();
        stressStart = newestStress();
        if (Sensor has :setEnabledSensors) {
            Sensor.setEnabledSensors([Sensor.SENSOR_HEARTRATE]);
            Sensor.enableSensorEvents(new Lang.Method(Metrics, :onSensor));
        }
        // Separately stream beat-to-beat R-R intervals for live HRV. If this and
        // the 1 Hz HR events can't coexist on a given device, onSessionEnd falls
        // back to a history-derived HR average, so the session still records.
        if (Sensor has :registerSensorDataListener) {
            try {
                Sensor.registerSensorDataListener(
                    new Lang.Method(Metrics, :onSensorData),
                    { :period => 1, :heartBeatIntervals => { :enabled => true } });
            } catch (e) {
            }
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
            if (hrMin < 0 || hr < hrMin) { hrMin = hr; }
        }
    }

    function resetHrv() as Void {
        mLastRr = 0;
        hrvSqAll = 0; hrvNAll = 0;
        hrvSqStart = 0; hrvNStart = 0;
        hrvSqCur = 0; hrvNCur = 0;
        hrvSqPrev = 0; hrvNPrev = 0;
        hrvBucketEdge = HRV_BUCKET_SEC;
    }

    // Batched R-R intervals (ms) since the last callback. Each accepted interval
    // contributes its squared difference from the previous one to the running
    // RMSSD accumulators (whole session, first window, rolling end buckets).
    function onSensorData(data as Sensor.SensorData) as Void {
        if (!active || data == null) { return; }
        var hrData = data.heartRateData;
        if (hrData == null) { return; }
        var rrs = hrData.heartBeatIntervals;
        if (rrs == null) { return; }
        var elapsed = Time.now().value() - startSec;
        // Roll the 60 s end-buckets forward to cover the current session time.
        while (elapsed >= hrvBucketEdge) {
            hrvSqPrev = hrvSqCur; hrvNPrev = hrvNCur;
            hrvSqCur = 0; hrvNCur = 0;
            hrvBucketEdge += HRV_BUCKET_SEC;
        }
        for (var i = 0; i < rrs.size(); i++) {
            var rr = rrs[i];
            if (rr == null || rr < RR_MIN_MS || rr > RR_MAX_MS) { mLastRr = 0; continue; }
            if (mLastRr > 0) {
                var d = rr - mLastRr;
                var sq = d * d;
                hrvSqAll += sq; hrvNAll++;
                if (elapsed <= HRV_START_SEC) { hrvSqStart += sq; hrvNStart++; }
                hrvSqCur += sq; hrvNCur++;
            }
            mLastRr = rr;
        }
    }

    // RMSSD over an accumulated (sum-of-squared-diffs, count) pair, rounded to a
    // whole millisecond, or null when there were too few intervals to be meaningful.
    function rmssd(sumSq as Number, n as Number) as Number? {
        if (n < 2) { return null; }
        return Math.round(Math.sqrt(sumSq.toFloat() / n)).toNumber();
    }

    function onSessionEnd() as Void {
        if (!active) { return; }
        active = false;
        if (Sensor has :enableSensorEvents) { Sensor.enableSensorEvents(null); }
        if (Sensor has :unregisterSensorDataListener) {
            try { Sensor.unregisterSensorDataListener(); } catch (e) {}
        }

        endSec = Time.now().value();
        // Live HR may be empty if the R-R listener preempted the 1 Hz events on this
        // device; fall back to the session window from history so we still record.
        var hrAvg = (hrCount > 0) ? hrSum / hrCount : avgHrInWindow(startSec, endSec);
        if (endSec - startSec < MIN_SESSION_SEC || hrAvg == null) {
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
        rec.put("hr_avg", hrAvg);
        if (hrCount > 0 && hrMin > 0) { rec.put("hr_min", hrMin); }
        var hrvStart = rmssd(hrvSqStart, hrvNStart);
        var hrvAll = rmssd(hrvSqAll, hrvNAll);
        var hrvEnd = rmssd(hrvSqPrev + hrvSqCur, hrvNPrev + hrvNCur);
        if (hrvStart != null) { rec.put("hrv_start", hrvStart); }
        if (hrvAll != null) { rec.put("hrv_avg", hrvAll); }
        if (hrvEnd != null) { rec.put("hrv_end", hrvEnd); }
        var hrBaseline = avgHrInWindow(startSec - baselineWindowSec(), startSec);
        if (hrBaseline != null) { rec.put("hr_baseline", hrBaseline); } else { log("baseline HR null (no history before start)"); }
        if (stressStart != null) { rec.put("stress_baseline", stressStart); } else { log("baseline stress null"); }
        if (respStart != null) { rec.put("resp_baseline", respStart); } else { log("baseline respiration null"); }
        Storage.setValue(PENDING_SESSION, rec);
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
    // elapsed: reads the recovery window from history and queues every entity,
    // cheap-captured ones first then the recovery deltas, so a background timeout
    // drops only the weaker tail. Resumes a half-sent queue from a prior wake.
    function pushRecovery() as Void {
        bgMode = true;

        // Resume an in-progress drain: a previous wake can be killed (CIQ caps a
        // background process's wall-clock time) before the whole queue is sent.
        // The remaining, fully-formed POSTs were persisted, so just keep draining.
        var resume = Storage.getValue(PENDING_QUEUE);
        if (resume instanceof Lang.Array && resume.size() > 0) {
            pending = resume;
            scheduleDrainRetry(); // re-arm in case this wake is also cut short
            sendNext();
            return;
        }

        var rec = Storage.getValue(PENDING_SESSION);
        if (!(rec instanceof Lang.Dictionary) || baseUrl() == null) { finishBg(); return; }

        sessionType = rec.get("mode");
        pubStart = rec.get("start");
        pubEnd = rec.get("end");

        // Read the post-session recovery values from history (the slow part). null
        // when the device logged nothing in the window — skipped, and logged.
        var hrBase = rec.get("hr_baseline");
        var hrRec = recoveryHr(rec);
        var stressBase = rec.get("stress_baseline");
        var stressRec = newestStress();
        var respBase = rec.get("resp_baseline");
        var respRec = newestRespiration();
        if (hrRec == null) { log("recovery HR null (no history in window)"); }
        if (stressRec == null) { log("recovery stress null"); }
        if (respRec == null) { log("recovery respiration null"); }

        pending = [];

        // Cheap, always-present group first: close the bar and emit everything
        // captured in the foreground, so it lands even if the history reads above
        // came back empty or this wake is cut short before the recovery group.
        addSessionClose(rec);  // close the mode bar (fallback if live end didn't flush)
        addNum("hr_avg", "Lullhum HR avg", rec.get("hr_avg"), "bpm");
        addNum("hr_min", "Lullhum HR min", rec.get("hr_min"), "bpm");
        addNum("duration", "Lullhum duration", rec.get("duration_sec"), "s");
        addNum("hrv_avg", "Lullhum HRV avg", rec.get("hrv_avg"), "ms");
        addNum("hrv_start", "Lullhum HRV start", rec.get("hrv_start"), "ms");
        addNum("hrv_end", "Lullhum HRV end", rec.get("hrv_end"), "ms");
        addNum("hr_baseline", "Lullhum HR baseline", hrBase, "bpm");

        // Recovery group: each family leads with its delta (recovery - baseline;
        // negative = settled), the headline signal, so a cut-short tail drops only
        // the weaker raw before/after readings.
        addDelta("hr_recovery_delta", "Lullhum HR recovery delta", hrRec, hrBase, "bpm");
        addNum("hr_recovery", "Lullhum HR recovery", hrRec, "bpm");
        addDelta("stress_delta", "Lullhum stress delta", stressRec, stressBase, null);
        addNum("stress_baseline", "Lullhum stress baseline", stressBase, null);
        addNum("stress_recovery", "Lullhum stress recovery", stressRec, null);
        addDelta("resp_delta", "Lullhum respiration delta", respRec, respBase, "br/min");
        addNum("resp_baseline", "Lullhum respiration baseline", respBase, "br/min");
        addNum("resp_recovery", "Lullhum respiration recovery", respRec, "br/min");

        if (pending.size() == 0) {
            // Nothing to send (URL/token gone, or no usable data) — clear state so
            // we don't rebuild an empty queue on every future wake.
            clearDrainState();
            finishBg();
            return;
        }
        // Persist the queue and schedule a follow-up wake before sending: if this
        // process dies mid-drain, the next wake resumes from the saved queue.
        // pending_session is left in place; only the final onPost deletes both.
        saveQueue();
        scheduleDrainRetry();
        sendNext();
    }

    // Queue a numeric entity, skipping absent (null / non-number) values so a
    // device that doesn't expose a given metric simply omits it.
    function addNum(key as String, name as String, value, unit as String?) as Void {
        if (value instanceof Lang.Number) { addMetric(key, name, value, unit); }
    }

    // Queue a recovery-minus-baseline delta, only when both ends are present.
    function addDelta(key as String, name as String, recVal, baseVal, unit as String?) as Void {
        if (recVal instanceof Lang.Number && baseVal instanceof Lang.Number) {
            addMetric(key, name, recVal - baseVal, unit);
        }
    }

    // Mean HR over the recovery window that opens at the session's end, read from
    // history. null if the record lacks an end time or no samples were logged.
    function recoveryHr(rec as Dictionary) as Number? {
        var recEnd = rec.get("end_epoch");
        if (!(recEnd instanceof Lang.Number)) { return null; }
        var winSec = rec.get("rec_win");
        if (!(winSec instanceof Lang.Number)) { winSec = 900; }
        return avgHrInWindow(recEnd, recEnd + winSec);
    }

    function finishBg() as Void {
        if (bgMode && (Toybox has :Background)) {
            Background.exit(null);
        }
    }

    // Mirror the live queue to Storage so a killed wake can resume (bgMode only;
    // the foreground postMode path must not leave a queue for a wake to pick up).
    function saveQueue() as Void {
        if (bgMode) { Storage.setValue(PENDING_QUEUE, pending); }
    }

    // Drain finished (queue empty): drop both persisted copies and cancel the
    // follow-up wake so no further background process spins up. This is the single
    // place pending_session is deleted, so the session survives every partial wake
    // until its queue is fully accounted for.
    function clearDrainState() as Void {
        Storage.deleteValue(PENDING_QUEUE);
        Storage.deleteValue(PENDING_SESSION);
        if ((Toybox has :Background) && (Background has :deleteTemporalEvent)) {
            try { Background.deleteTemporalEvent(); } catch (e) {}
        }
    }

    // Schedule the next wake to keep draining. Replaces any pending temporal event
    // (CIQ allows one); the recovery event has already fired by the time we drain.
    // The 5-minute floor is the CIQ temporal-event minimum.
    function scheduleDrainRetry() as Void {
        if (!(Toybox has :Background) || !(Background has :registerForTemporalEvent)) { return; }
        try {
            Background.registerForTemporalEvent(new Time.Moment(Time.now().value() + 300));
        } catch (e) {
        }
    }

    // ---- Home Assistant REST states API ------------------------------------

    // Immediately set the mode entity's state (foreground, single POST). Used to
    // mark the real session start (state = mode) and end (state = "idle"); HA's
    // built-in History renders the text state as a labeled timeline bar.
    function postMode(state as String, startIso as String, endIso as String) as Void {
        if (baseUrl() == null) { return; }
        // Append rather than overwrite: clobbering the array would drop an in-flight
        // POST (e.g. the start marker still draining when the end marker is queued).
        // If a send is already in progress, onPost chains to this item; otherwise
        // kick it off here.
        var wasIdle = (pending.size() == 0);
        pending.add({
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
        });
        if (wasIdle) { sendNext(); }
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
        var url = baseUrl();
        var token = Application.Properties.getValue("haToken");
        if (url == null || token == null) { pending = []; } // unconfigured: nothing to send
        if (pending.size() == 0) { finishDrain(); return; }
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
        var path = headPath();
        log("POST " + path + " -> " + responseCode);
        var ok = (responseCode >= 200 && responseCode < 300);
        var permanent = (responseCode >= 400 && responseCode < 500);

        // Delivered, a permanent 4xx that retrying can't fix (drop so it can't wedge
        // the queue), or a best-effort foreground marker — advance and keep draining.
        if (ok || permanent || !bgMode) {
            dropHead();
            if (pending.size() == 0) { finishDrain(); } else { sendNext(); }
            return;
        }

        // Transient background failure — no phone/BLE, server 5xx, relay timeout
        // (CIQ reports these as negative codes). Keep the item for the armed retry
        // wake rather than advancing (advancing here was the bug that silently lost
        // every metric when the recovery wake couldn't reach HA), but give up on it
        // after MAX_TRIES so one unreachable POST can't pin the queue forever.
        if (pending.size() == 0) { finishDrain(); return; }
        var item = pending[0];
        var tries = (item.hasKey(TRIES_KEY) ? item.get(TRIES_KEY) : 0) + 1;
        if (tries >= MAX_TRIES) {
            log("dropping " + path + " after " + tries + " tries");
            dropHead();
        } else {
            item.put(TRIES_KEY, tries);
            saveQueue();
        }
        // Stop this wake; connectivity is likely down for the whole queue, so let
        // the +5 min retry resume rather than hammer the rest now.
        if (pending.size() == 0) { finishDrain(); } else { scheduleDrainRetry(); finishBg(); }
    }

    function headPath() as String {
        return (pending.size() > 0) ? pending[0]["path"] : "?";
    }

    // Remove the head and checkpoint, so a killed wake resumes after it, not at it.
    function dropHead() as Void {
        if (pending.size() > 0) { pending = pending.slice(1, null); }
        saveQueue();
    }

    // Queue fully accounted for: release a deferred app-exit, and in the background
    // wipe the persisted state so no further wake spins up.
    function finishDrain() as Void {
        if (mExitCb != null) { var cb = mExitCb; mExitCb = null; cb.invoke(); }
        if (bgMode) { clearDrainState(); }
        finishBg();
    }

    // Invoke cb once the foreground send queue has drained (used to defer app
    // exit until the session's idle end-marker has been sent). Fires immediately
    // if nothing is queued.
    function flushThen(cb as Lang.Method) as Void {
        if (pending.size() == 0) { cb.invoke(); return; }
        mExitCb = cb;
    }

    // ---- Helpers -----------------------------------------------------------

    // Diagnostic trace to the CIQ log (visible in the simulator and in device
    // logs), prefixed so HA-delivery lines are easy to grep. Cheap and harmless in
    // production; it's the only window into the background send, which has no UI.
    function log(msg as String) as Void {
        System.println("[Lullhum] " + msg);
    }

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
