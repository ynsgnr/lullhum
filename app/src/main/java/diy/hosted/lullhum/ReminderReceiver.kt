package diy.hosted.lullhum

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent

/** Receives the AlarmManager tick, buzzes the watch, and chains the next alarm. */
class ReminderReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action == Reminder.ACTION_FIRE) {
            val min = intent.getIntExtra(
                VibrationService.EXTRA_INTERVAL_MIN, VibrationService.MIN_REMINDER_MIN
            )
            Reminder.fire(context.applicationContext, min)
        }
    }
}
