package diy.hosted.lullhum

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.Service
import android.content.Context
import android.content.Intent
import android.os.Build
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import android.os.PowerManager
import android.os.VibrationEffect
import android.os.Vibrator
import android.os.VibratorManager
import android.util.Log
import com.garmin.android.connectiq.ConnectIQ
import com.garmin.android.connectiq.IQApp
import com.garmin.android.connectiq.IQDevice

/**
 * Foreground service that keeps the Connect IQ listener alive and vibrates the
 * phone in alternation with the watch.
 *
 * The watch (Alternating mode) sends `{cmd:"start", speed, anchor}` on start and
 * `{cmd:"stop"}` on stop. The phone aligns its buzzes to the shared `anchor`
 * wall-clock second, one interval behind the watch, so the two strictly
 * alternate regardless of message latency. The background reminder lives in
 * [Reminder] (AlarmManager-based) so it survives the service being killed.
 */
class VibrationService : Service() {

    companion object {
        private const val TAG = "Lullhum"
        private const val CHANNEL_ID = "lullhum_status"
        private const val NOTIFICATION_ID = 1

        // Must match the Connect IQ app id in garmin/manifest.xml.
        private const val IQ_APP_ID = "f1e2d3c4b5a697887766554433221100"

        // Phone pulse is kept short — well under one interval — so a clear silent
        // gap stays open between the watch's buzz and the phone's even with some
        // clock skew. Floored so it's still perceptible, capped so it stays crisp.
        private const val MIN_PULSE_MS = 80L
        private const val MAX_PULSE_MS = 200L

        const val ACTION_START_REMINDER = "diy.hosted.lullhum.START_REMINDER"
        const val ACTION_STOP_REMINDER = "diy.hosted.lullhum.STOP_REMINDER"
        const val EXTRA_INTERVAL_MIN = "interval_min"
        const val MIN_REMINDER_MIN = 5

        // Two-phone pair mode (watch-independent). Two phones, each set to Pair 1 or
        // Pair 2, alternate buzzes by anchoring to the shared wall clock: Pair 1 on
        // each whole second, Pair 2 half a second later. No BLE or messaging — they
        // stay interleaved purely because both phones' clocks are network-synced and
        // they re-anchor to the same absolute grid on every tick.
        const val ACTION_START_PAIR = "diy.hosted.lullhum.START_PAIR"
        const val ACTION_STOP_PAIR = "diy.hosted.lullhum.STOP_PAIR"
        const val EXTRA_PAIR = "pair"
        private const val PAIR_PERIOD_MS = 1000L
        private const val PAIR_OFFSET_MS = 500L  // Pair 2's lead behind Pair 1
        private const val PAIR_PULSE_MS = 250L   // leaves a clear gap inside the 500ms half
    }

    // What the shared vibration timer is currently driving, so a watch event never
    // tears down an independent pair session and vice versa.
    private enum class TimerMode { NONE, WATCH, PAIR }
    private var timerMode = TimerMode.NONE

    private lateinit var connectIQ: ConnectIQ
    private val iqApp = IQApp(IQ_APP_ID)
    private val registeredDevices = mutableListOf<IQDevice>()

    private val handler = Handler(Looper.getMainLooper())
    private var vibrateRunnable: Runnable? = null
    private var sdkReady = false
    private var wakeLock: PowerManager.WakeLock? = null

    private val vibrator: Vibrator by lazy {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            val mgr = getSystemService(Context.VIBRATOR_MANAGER_SERVICE) as VibratorManager
            mgr.defaultVibrator
        } else {
            @Suppress("DEPRECATION")
            getSystemService(Context.VIBRATOR_SERVICE) as Vibrator
        }
    }

    override fun onCreate() {
        super.onCreate()
        createNotificationChannel()
        initConnectIQ()
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        startForeground(NOTIFICATION_ID, buildNotification())
        when (intent?.action) {
            ACTION_START_REMINDER ->
                Reminder.start(this, intent.getIntExtra(EXTRA_INTERVAL_MIN, MIN_REMINDER_MIN))
            ACTION_STOP_REMINDER -> Reminder.stop(this)
            ACTION_START_PAIR -> startPair(intent.getIntExtra(EXTRA_PAIR, 1))
            ACTION_STOP_PAIR -> stopPair()
        }
        return START_STICKY
    }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onDestroy() {
        // Note: the reminder is intentionally NOT cancelled here — it's alarm-based
        // and meant to keep buzzing the watch even if this service is killed.
        cancelTimer()
        timerMode = TimerMode.NONE
        unregisterDevices()
        if (sdkReady) {
            try {
                connectIQ.shutdown(this)
            } catch (e: Exception) {
                Log.w(TAG, "ConnectIQ shutdown failed", e)
            }
        }
        super.onDestroy()
    }

    // ---- Connect IQ --------------------------------------------------------

    private fun initConnectIQ() {
        connectIQ = ConnectIQ.getInstance(this, ConnectIQ.IQConnectType.WIRELESS)
        connectIQ.initialize(this, false, object : ConnectIQ.ConnectIQListener {
            override fun onSdkReady() {
                sdkReady = true
                registerConnectedDevices()
            }

            override fun onInitializeError(status: ConnectIQ.IQSdkErrorStatus) {
                Log.w(TAG, "ConnectIQ init error: $status")
                LullhumState.set(Status.DISCONNECTED)
            }

            override fun onSdkShutDown() {
                sdkReady = false
            }
        })
    }

    private fun registerConnectedDevices() {
        val devices = try {
            connectIQ.connectedDevices ?: emptyList()
        } catch (e: Exception) {
            Log.w(TAG, "Could not query devices", e)
            emptyList()
        }

        if (devices.isEmpty()) {
            LullhumState.set(Status.DISCONNECTED)
            return
        }

        for (device in devices) {
            registerDevice(device)
        }
        LullhumState.set(Status.STOPPED)
    }

    private fun registerDevice(device: IQDevice) {
        registeredDevices.add(device)

        connectIQ.registerForDeviceEvents(device) { _, status ->
            if (status != IQDevice.IQDeviceStatus.CONNECTED) {
                // Connection dropped: stop watch-driven vibration (a pair session is
                // independent and keeps running), but keep the service alive.
                stopVibration()
                LullhumState.set(Status.DISCONNECTED)
            } else {
                LullhumState.set(if (timerMode == TimerMode.WATCH) Status.RUNNING else Status.STOPPED)
            }
        }

        connectIQ.registerForAppEvents(device, iqApp) { _, _, messageData, _ ->
            handleMessage(messageData)
        }
    }

    private fun handleMessage(messageData: List<Any>) {
        for (item in messageData) {
            if (item is Map<*, *>) {
                when (item["cmd"] as? String) {
                    "start" -> {
                        val speed = (item["speed"] as? Number)?.toInt() ?: 500
                        val anchorSec = (item["anchor"] as? Number)?.toLong() ?: 0L
                        startVibration(speed, anchorSec)
                    }
                    "stop" -> stopVibration()
                    "reminderStart" -> {
                        val sec = (item["intervalSec"] as? Number)?.toInt() ?: (MIN_REMINDER_MIN * 60)
                        Reminder.start(this, sec / 60)
                    }
                    "reminderStop" -> Reminder.stop(this)
                }
            }
        }
    }

    private fun unregisterDevices() {
        if (!sdkReady) return
        for (device in registeredDevices) {
            try {
                connectIQ.unregisterForDeviceEvents(device)
                connectIQ.unregisterForApplicationEvents(device, iqApp)
            } catch (e: Exception) {
                Log.w(TAG, "Unregister failed", e)
            }
        }
        registeredDevices.clear()
    }

    // ---- Vibration timer ---------------------------------------------------

    // Watch-driven alternation (started by a watch "start" message): the phone
    // buzzes one interval behind the watch's shared anchor.
    private fun startVibration(speedMs: Int, anchorSec: Long) {
        takeOverTimer(TimerMode.WATCH)
        val period = 2L * speedMs
        // ~40% of one interval, clamped: leaves a silent gap of at least ~60% of
        // the interval before the watch's next buzz (vs. only ~50ms at Fast when
        // the pulse ran the full 200ms), so clock skew is far less likely to merge
        // the two into one felt buzz.
        val pulse = (speedMs * 2L / 5L).coerceIn(MIN_PULSE_MS, MAX_PULSE_MS)

        // The shared anchor is what keeps the phone interleaved with the watch. If
        // it's somehow missing, do NOT silently free-run from message arrival —
        // that's exactly how the two drift into buzzing together. Log it (so the
        // desync is diagnosable) and anchor to the current whole second, which at
        // least keeps the phone on a defined half-period grid.
        val anchor = if (anchorSec > 0) {
            anchorSec
        } else {
            Log.w(TAG, "start message had no anchor; phone alternation may not align with the watch")
            System.currentTimeMillis() / 1000L
        }

        acquireWakeLock()
        scheduleBuzz(pulse) { nextBuzzDelay(anchor, speedMs.toLong(), period) }
        LullhumState.set(Status.RUNNING)
        updateNotification()
    }

    // Watch stop (message or dropped connection). No-op when a pair session owns
    // the timer, so the watch never tears down an independent two-phone session.
    private fun stopVibration() {
        if (timerMode != TimerMode.WATCH) return
        cancelTimer()
        timerMode = TimerMode.NONE
        LullhumState.set(Status.STOPPED)
        updateNotification()
    }

    // Two-phone pair mode (started by the user, watch-independent). Both phones
    // anchor to the nearest whole second and re-anchor every tick; Pair 1 buzzes on
    // each whole second, Pair 2 PAIR_OFFSET_MS later, so they interleave with no BLE
    // or messaging as long as the two clocks agree (both phones use network time).
    private fun startPair(pair: Int) {
        val role = if (pair == 2) 2 else 1
        takeOverTimer(TimerMode.PAIR)
        val anchor = (System.currentTimeMillis() + 500L) / 1000L // round to nearest second
        val offset = if (role == 2) PAIR_OFFSET_MS else 0L
        acquireWakeLock()
        scheduleBuzz(PAIR_PULSE_MS) { nextPairDelay(anchor, offset) }
        LullhumState.setPair(active = true, role = role)
        updateNotification()
    }

    private fun stopPair() {
        if (timerMode != TimerMode.PAIR) return
        cancelTimer()
        timerMode = TimerMode.NONE
        LullhumState.setPair(active = false, role = LullhumState.pairRole.value)
        updateNotification()
    }

    // Cancel whatever's running and claim the timer for [mode], clearing the other
    // feature's active state so only one shows as running at a time.
    private fun takeOverTimer(mode: TimerMode) {
        cancelTimer()
        if (timerMode == TimerMode.PAIR && mode != TimerMode.PAIR) {
            LullhumState.setPair(active = false, role = LullhumState.pairRole.value)
        }
        if (timerMode == TimerMode.WATCH && mode != TimerMode.WATCH &&
            LullhumState.status.value == Status.RUNNING
        ) {
            LullhumState.set(Status.STOPPED)
        }
        timerMode = mode
    }

    // Schedule a self-rescheduling buzz: vibrate, then re-anchor to the wall clock
    // via [delay] so a single late tick (after a brief CPU stall) self-corrects
    // instead of drifting the rest of the session.
    private fun scheduleBuzz(pulseMs: Long, delay: () -> Long) {
        // A foreground service keeps the process alive but lets the CPU suspend with
        // the screen off; the Handler runs on uptimeMillis, which freezes during
        // that suspend, so the wake lock (acquired by the caller) keeps it ticking.
        val runnable = object : Runnable {
            override fun run() {
                vibrateOnce(pulseMs)
                handler.postDelayed(this, delay())
            }
        }
        vibrateRunnable = runnable
        handler.postDelayed(runnable, delay())
    }

    // Pure timer teardown — releases the wake lock and vibrator, no state changes.
    private fun cancelTimer() {
        vibrateRunnable?.let { handler.removeCallbacks(it) }
        vibrateRunnable = null
        vibrator.cancel()
        releaseWakeLock()
    }

    // Phone buzzes one interval after the watch's anchor buzz, then every 2*speed.
    // Aligning to the shared wall-clock anchor keeps the two interleaved despite
    // BLE latency; from any "now" we pick the next valid slot at least 30ms out.
    // The caller guarantees anchorSec > 0 (see startVibration).
    private fun nextBuzzDelay(anchorSec: Long, speedMs: Long, period: Long): Long {
        val now = System.currentTimeMillis()
        var next = anchorSec * 1000L + speedMs
        while (next < now + 30) next += period
        return next - now
    }

    // Pair buzz: Pair 1 on the anchor grid (offset 0), Pair 2 PAIR_OFFSET_MS later,
    // repeating every PAIR_PERIOD_MS; from any "now" pick the next slot ≥30ms out.
    private fun nextPairDelay(anchorSec: Long, offset: Long): Long {
        val now = System.currentTimeMillis()
        var next = anchorSec * 1000L + offset
        while (next < now + 30) next += PAIR_PERIOD_MS
        return next - now
    }

    private fun acquireWakeLock() {
        if (wakeLock?.isHeld == true) return
        val pm = getSystemService(Context.POWER_SERVICE) as PowerManager
        wakeLock = pm.newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "$TAG:vibration").apply {
            setReferenceCounted(false)
            acquire()
        }
    }

    private fun releaseWakeLock() {
        wakeLock?.let { if (it.isHeld) it.release() }
        wakeLock = null
    }

    private fun vibrateOnce(durationMs: Long) {
        vibrator.vibrate(
            VibrationEffect.createOneShot(durationMs, VibrationEffect.DEFAULT_AMPLITUDE)
        )
    }

    // ---- Notification / status ---------------------------------------------

    private fun createNotificationChannel() {
        // The reminder channel is created lazily by Reminder.
        getSystemService(NotificationManager::class.java).createNotificationChannel(
            NotificationChannel(CHANNEL_ID, "Lullhum status", NotificationManager.IMPORTANCE_LOW)
                .apply { description = "Keeps Lullhum listening for the watch" }
        )
    }

    private fun buildNotification(): Notification {
        val text = if (LullhumState.pairActive.value) {
            "Pair ${LullhumState.pairRole.value} vibrating"
        } else {
            LullhumState.status.value.label
        }
        return Notification.Builder(this, CHANNEL_ID)
            .setContentTitle("Lullhum")
            .setContentText(text)
            .setSmallIcon(R.mipmap.ic_launcher)
            .setOngoing(true)
            .build()
    }

    private fun updateNotification() {
        getSystemService(NotificationManager::class.java)
            .notify(NOTIFICATION_ID, buildNotification())
    }
}
