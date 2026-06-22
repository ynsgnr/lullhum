package diy.hosted.lullhum

import android.app.AlarmManager
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.os.SystemClock

/**
 * Background interval reminder, scheduled via [AlarmManager] rather than an
 * in-process timer.
 *
 * Battery: `setAndAllowWhileIdle` fires during Doze but is inexact, so the
 * system batches the wakeup with others and the CPU sleeps in between — no
 * repeating handler, no wakelock. Each fire reschedules the next one, so the
 * reminder also survives the service being killed (the receiver is in the
 * manifest). The trade-off is that timing may drift by a few minutes in deep
 * Doze, which is fine for a multi-minute reminder.
 */
object Reminder {
    const val ACTION_FIRE = "diy.hosted.lullhum.REMINDER_FIRE"
    private const val CHANNEL_ID = "lullhum_reminder"
    private const val REQUEST_CODE = 2001
    private var notifId = 1000

    fun start(ctx: Context, intervalMin: Int) {
        val min = intervalMin.coerceAtLeast(VibrationService.MIN_REMINDER_MIN)
        buzz(ctx)                       // immediate confirmation
        schedule(ctx, min)
        LullhumState.setReminder(true, min)
    }

    fun stop(ctx: Context) {
        alarmManager(ctx).cancel(pendingIntent(ctx, 0))
        LullhumState.setReminder(false, LullhumState.reminderIntervalMin.value)
    }

    /** Called by [ReminderReceiver] when an alarm fires. */
    fun fire(ctx: Context, intervalMin: Int) {
        buzz(ctx)
        schedule(ctx, intervalMin)      // chain the next one
        LullhumState.setReminder(true, intervalMin)
    }

    private fun schedule(ctx: Context, intervalMin: Int) {
        val triggerAt = SystemClock.elapsedRealtime() + intervalMin * 60_000L
        alarmManager(ctx).setAndAllowWhileIdle(
            AlarmManager.ELAPSED_REALTIME_WAKEUP, triggerAt, pendingIntent(ctx, intervalMin)
        )
    }

    private fun pendingIntent(ctx: Context, intervalMin: Int): PendingIntent {
        val intent = Intent(ctx, ReminderReceiver::class.java)
            .setAction(ACTION_FIRE)
            .putExtra(VibrationService.EXTRA_INTERVAL_MIN, intervalMin)
        return PendingIntent.getBroadcast(
            ctx, REQUEST_CODE, intent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )
    }

    private fun alarmManager(ctx: Context) =
        ctx.getSystemService(Context.ALARM_SERVICE) as AlarmManager

    // A fresh notification id each time forces the watch to re-alert; cancelling
    // the previous one keeps the shade and watch list from piling up.
    private fun buzz(ctx: Context) {
        val manager = ctx.getSystemService(NotificationManager::class.java)
        if (manager.getNotificationChannel(CHANNEL_ID) == null) {
            manager.createNotificationChannel(
                NotificationChannel(CHANNEL_ID, "Lullhum reminders", NotificationManager.IMPORTANCE_HIGH)
                    .apply {
                        description = "Periodic buzz relayed to the watch"
                        enableVibration(true)
                    }
            )
        }
        manager.cancel(notifId)
        notifId++
        manager.notify(
            notifId,
            Notification.Builder(ctx, CHANNEL_ID)
                .setContentTitle("Lullhum")
                .setContentText("Interval reminder")
                .setSmallIcon(R.mipmap.ic_launcher)
                .setAutoCancel(true)
                .build()
        )
    }
}
