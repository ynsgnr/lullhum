package diy.hosted.lullhum

import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow

/** Connection / activity status surfaced to the UI by [VibrationService]. */
enum class Status {
    /** SDK not ready or Garmin Connect Mobile unavailable. */
    DISCONNECTED,

    /** Connected to the watch, waiting for a start message. */
    STOPPED,

    /** Received a start message; vibrating on even intervals. */
    RUNNING,
}

/**
 * Process-wide state bridge between the foreground [VibrationService] and the
 * Compose UI. The UI has no controls — it only observes this.
 */
object LullhumState {
    private val _status = MutableStateFlow(Status.DISCONNECTED)
    val status: StateFlow<Status> = _status.asStateFlow()

    fun set(status: Status) {
        _status.value = status
    }
}
