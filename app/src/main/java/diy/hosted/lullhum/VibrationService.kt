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
 * The watch (Alternating mode) sends `{cmd:"start", speed:<ms>}` on start and
 * `{cmd:"stop"}` on stop. The phone vibrates on even intervals only, offset by
 * one full interval from the watch so the two devices strictly alternate.
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
    }

    private lateinit var connectIQ: ConnectIQ
    private val iqApp = IQApp(IQ_APP_ID)
    private val registeredDevices = mutableListOf<IQDevice>()

    private val handler = Handler(Looper.getMainLooper())
    private var vibrateRunnable: Runnable? = null
    private var sdkReady = false

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
        startForeground(NOTIFICATION_ID, buildNotification(statusText()))
        return START_STICKY
    }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onDestroy() {
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
                        startVibration(speed)
                    }
                    "stop" -> stopVibration()
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

    private fun startVibration(speedMs: Int) {
        stopVibration()
        val period = (2L * speedMs)
        val pulse = minOf(speedMs.toLong(), MAX_PULSE_MS)

        val runnable = object : Runnable {
            override fun run() {
                vibrateOnce(pulse)
                handler.postDelayed(this, period)
            }
        }
        vibrateRunnable = runnable
        // First phone buzz one full interval after the watch's first buzz
        // (watch buzzes at t=speed, phone at t=2*speed), then every 2*speed.
        handler.postDelayed(runnable, period)

        LullhumState.set(Status.RUNNING)
        updateNotification()
    }

    private fun stopVibration() {
        vibrateRunnable?.let { handler.removeCallbacks(it) }
        vibrateRunnable = null
        vibrator.cancel()
        LullhumState.set(Status.STOPPED)
        updateNotification()
    }

    private fun vibrateOnce(durationMs: Long) {
        vibrator.vibrate(
            VibrationEffect.createOneShot(durationMs, VibrationEffect.DEFAULT_AMPLITUDE)
        )
    }

    // ---- Notification / status ---------------------------------------------

    private fun statusText(): String = when (LullhumState.status.value) {
        Status.RUNNING -> "Running"
        Status.STOPPED -> "Connected"
        Status.DISCONNECTED -> "Waiting for watch"
    }

    private fun createNotificationChannel() {
        val channel = NotificationChannel(
            CHANNEL_ID,
            "Lullhum status",
            NotificationManager.IMPORTANCE_LOW
        ).apply { description = "Keeps Lullhum listening for the watch" }
        val manager = getSystemService(NotificationManager::class.java)
        manager.createNotificationChannel(channel)
    }

    private fun buildNotification(text: String): Notification {
        return Notification.Builder(this, CHANNEL_ID)
            .setContentTitle("Lullhum")
            .setContentText(text)
            .setSmallIcon(R.mipmap.ic_launcher)
            .setOngoing(true)
            .build()
    }

    private fun updateNotification() {
        val manager = getSystemService(NotificationManager::class.java)
        manager.notify(NOTIFICATION_ID, buildNotification(statusText()))
    }
}
