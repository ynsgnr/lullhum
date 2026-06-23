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

        // Phone pulse length is capped so fast speeds stay crisp.
        private const val MAX_PULSE_MS = 200L

        const val ACTION_START_REMINDER = "diy.hosted.lullhum.START_REMINDER"
        const val ACTION_STOP_REMINDER = "diy.hosted.lullhum.STOP_REMINDER"
        const val EXTRA_INTERVAL_MIN = "interval_min"
        const val MIN_REMINDER_MIN = 5
    }

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
        }
        return START_STICKY
    }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onDestroy() {
        // Note: the reminder is intentionally NOT cancelled here — it's alarm-based
        // and meant to keep buzzing the watch even if this service is killed.
        stopVibration()
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
                // Connection dropped: stop vibrating, but keep the service alive.
                stopVibration()
                LullhumState.set(Status.DISCONNECTED)
            } else {
                LullhumState.set(if (isVibrating()) Status.RUNNING else Status.STOPPED)
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

    private fun isVibrating() = vibrateRunnable != null

    private fun startVibration(speedMs: Int, anchorSec: Long) {
        stopVibration()
        val period = 2L * speedMs
        val pulse = minOf(speedMs.toLong(), MAX_PULSE_MS)

        // A foreground service keeps the process alive but lets the CPU suspend
        // with the screen off; the Handler runs on uptimeMillis, which freezes
        // during that suspend, so without this the timer stalls and desyncs.
        acquireWakeLock()

        val runnable = object : Runnable {
            override fun run() {
                vibrateOnce(pulse)
                // Re-anchor every tick to the shared wall clock so a single late
                // buzz (e.g. after a brief CPU stall) self-corrects instead of
                // drifting the rest of the session out of sync with the watch.
                handler.postDelayed(this, nextBuzzDelay(anchorSec, speedMs.toLong(), period))
            }
        }
        vibrateRunnable = runnable
        handler.postDelayed(runnable, nextBuzzDelay(anchorSec, speedMs.toLong(), period))

        LullhumState.set(Status.RUNNING)
        updateNotification()
    }

    // Phone buzzes one interval after the watch's anchor buzz, then every 2*speed.
    // Aligning to the shared wall-clock anchor keeps the two interleaved despite
    // BLE latency; from any "now" we pick the next valid slot at least 30ms out.
    private fun nextBuzzDelay(anchorSec: Long, speedMs: Long, period: Long): Long {
        if (anchorSec <= 0) return period
        val now = System.currentTimeMillis()
        var next = anchorSec * 1000L + speedMs
        while (next < now + 30) next += period
        return next - now
    }

    private fun stopVibration() {
        vibrateRunnable?.let { handler.removeCallbacks(it) }
        vibrateRunnable = null
        vibrator.cancel()
        releaseWakeLock()
        LullhumState.set(Status.STOPPED)
        updateNotification()
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

    private fun buildNotification(): Notification =
        Notification.Builder(this, CHANNEL_ID)
            .setContentTitle("Lullhum")
            .setContentText(LullhumState.status.value.label)
            .setSmallIcon(R.mipmap.ic_launcher)
            .setOngoing(true)
            .build()

    private fun updateNotification() {
        getSystemService(NotificationManager::class.java)
            .notify(NOTIFICATION_ID, buildNotification())
    }
}
