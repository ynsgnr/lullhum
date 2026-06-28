package diy.hosted.lullhum

import android.content.Context

/**
 * Small persistent store for one-time user settings. Currently just the
 * alternation calibration trim: a manual phase offset (ms) applied to the
 * phone's buzz so the user can centre it against the watch once and forget it.
 */
object Prefs {
    private const val FILE = "lullhum_prefs"
    private const val KEY_CALIBRATION_TRIM = "calibration_trim_ms"
    private const val KEY_SHOW_DESCRIPTIONS = "show_descriptions"

    // The watch/phone clock offset we're correcting for is at most a couple
    // hundred ms; this bounds the slider and guards a corrupt stored value.
    const val CALIBRATION_TRIM_MAX = 250

    private fun prefs(ctx: Context) =
        ctx.getSharedPreferences(FILE, Context.MODE_PRIVATE)

    fun calibrationTrimMs(ctx: Context): Int =
        prefs(ctx).getInt(KEY_CALIBRATION_TRIM, 0)
            .coerceIn(-CALIBRATION_TRIM_MAX, CALIBRATION_TRIM_MAX)

    fun setCalibrationTrimMs(ctx: Context, trimMs: Int) {
        prefs(ctx).edit()
            .putInt(KEY_CALIBRATION_TRIM, trimMs.coerceIn(-CALIBRATION_TRIM_MAX, CALIBRATION_TRIM_MAX))
            .apply()
    }

    // Whether the per-section help text is shown. Defaults on (expanded).
    fun showDescriptions(ctx: Context): Boolean =
        prefs(ctx).getBoolean(KEY_SHOW_DESCRIPTIONS, true)

    fun setShowDescriptions(ctx: Context, show: Boolean) {
        prefs(ctx).edit().putBoolean(KEY_SHOW_DESCRIPTIONS, show).apply()
    }
}
