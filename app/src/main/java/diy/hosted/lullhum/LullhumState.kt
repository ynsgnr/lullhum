package diy.hosted.lullhum

import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow

/** Connection / activity status, shown in both the UI and the notification. */
enum class Status(val label: String) {
    DISCONNECTED("Waiting for watch"),
    STOPPED("Connected"),
    RUNNING("Running"),
}

/** Process-wide state bridge from [VibrationService] / [Reminder] to the UI. */
object LullhumState {
    private val _status = MutableStateFlow(Status.DISCONNECTED)
    val status: StateFlow<Status> = _status.asStateFlow()

    private val _reminderActive = MutableStateFlow(false)
    val reminderActive: StateFlow<Boolean> = _reminderActive.asStateFlow()

    private val _reminderIntervalMin = MutableStateFlow(15)
    val reminderIntervalMin: StateFlow<Int> = _reminderIntervalMin.asStateFlow()

    // Two-phone pair mode: whether this phone is currently buzzing, and which side
    // (1 or 2) it plays. Independent of the watch — see VibrationService.startPair.
    private val _pairActive = MutableStateFlow(false)
    val pairActive: StateFlow<Boolean> = _pairActive.asStateFlow()

    private val _pairRole = MutableStateFlow(1)
    val pairRole: StateFlow<Int> = _pairRole.asStateFlow()

    fun set(status: Status) {
        _status.value = status
    }

    fun setReminder(active: Boolean, intervalMin: Int) {
        _reminderActive.value = active
        _reminderIntervalMin.value = intervalMin
    }

    fun setPair(active: Boolean, role: Int) {
        _pairActive.value = active
        _pairRole.value = role
    }
}
