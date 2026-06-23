package diy.hosted.lullhum

import android.Manifest
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Build
import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material3.Button
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.core.content.ContextCompat
import diy.hosted.lullhum.ui.theme.LullhumTheme

private val StatusGreen = Color(0xFF2E7D32)
private val StatusBlue = Color(0xFF1565C0)
private val StatusGrey = Color(0xFF757575)
private val REMINDER_PRESETS = listOf(5, 10, 15, 30, 60)

/**
 * Status indicator (watch-driven) plus a self-contained background interval
 * reminder that buzzes the watch via notifications.
 */
class MainActivity : ComponentActivity() {

    private val requestNotifications =
        registerForActivityResult(ActivityResultContracts.RequestPermission()) {}

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        enableEdgeToEdge()

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU &&
            ContextCompat.checkSelfPermission(this, Manifest.permission.POST_NOTIFICATIONS)
            != PackageManager.PERMISSION_GRANTED
        ) {
            requestNotifications.launch(Manifest.permission.POST_NOTIFICATIONS)
        }

        ContextCompat.startForegroundService(this, Intent(this, VibrationService::class.java))

        setContent {
            LullhumTheme {
                Scaffold(modifier = Modifier.fillMaxSize()) { padding ->
                    StatusScreen(Modifier.padding(padding))
                }
            }
        }
    }
}

@Composable
fun StatusScreen(modifier: Modifier = Modifier) {
    val status by LullhumState.status.collectAsState()

    Column(
        modifier = modifier
            .fillMaxSize()
            .padding(24.dp),
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.Center
    ) {
        Text("Lullhum", fontSize = 28.sp, fontWeight = FontWeight.Bold)
        Spacer(Modifier.height(24.dp))
        StatusIndicator(status)
        Spacer(Modifier.height(32.dp))
        HorizontalDivider()
        Spacer(Modifier.height(24.dp))
        ReminderControls()
    }
}

@Composable
private fun StatusIndicator(status: Status) {
    val color = when (status) {
        Status.RUNNING -> StatusGreen
        Status.STOPPED -> StatusBlue
        Status.DISCONNECTED -> StatusGrey
    }
    Column(horizontalAlignment = Alignment.CenterHorizontally) {
        Box(Modifier.size(56.dp).clip(CircleShape).background(color))
        Spacer(Modifier.height(16.dp))
        Text(status.label, fontSize = 20.sp, color = color, fontWeight = FontWeight.Medium)
    }
}

@Composable
private fun ReminderControls() {
    val ctx = LocalContext.current
    val active by LullhumState.reminderActive.collectAsState()
    val intervalMin by LullhumState.reminderIntervalMin.collectAsState()
    var minutesText by remember { mutableStateOf("15") }

    Column(horizontalAlignment = Alignment.CenterHorizontally) {
        Text("Background reminder", fontSize = 18.sp, fontWeight = FontWeight.Medium)
        Spacer(Modifier.height(6.dp))
        Text(
            "To buzz the watch: enable notifications and turn off Do Not Disturb on both watch and phone. " +
                "For correct timing while locked, also disable battery optimisation for Lullhum.",
            fontSize = 12.sp,
            color = StatusGrey,
            textAlign = TextAlign.Center
        )
        Spacer(Modifier.height(12.dp))
        Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            REMINDER_PRESETS.forEach { min ->
                IntervalChip(min, selected = minutesText == min.toString(), enabled = !active) {
                    minutesText = min.toString()
                }
            }
        }
        Spacer(Modifier.height(12.dp))
        OutlinedTextField(
            value = minutesText,
            onValueChange = { minutesText = it.filter(Char::isDigit).take(3) },
            enabled = !active,
            singleLine = true,
            label = { Text("Minutes (min ${VibrationService.MIN_REMINDER_MIN})") },
            keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Number),
            modifier = Modifier.width(160.dp)
        )
        Spacer(Modifier.height(16.dp))
        Button(
            onClick = {
                if (active) {
                    sendReminder(ctx, VibrationService.ACTION_STOP_REMINDER)
                } else {
                    val min = (minutesText.toIntOrNull() ?: VibrationService.MIN_REMINDER_MIN)
                        .coerceAtLeast(VibrationService.MIN_REMINDER_MIN)
                    sendReminder(ctx, VibrationService.ACTION_START_REMINDER, min)
                }
            },
            enabled = active || minutesText.isNotEmpty(),
            modifier = Modifier.fillMaxWidth()
        ) {
            Text(if (active) "Stop reminder" else "Start reminder")
        }
        if (active) {
            Spacer(Modifier.height(8.dp))
            Text("Buzzing the watch every $intervalMin min", fontSize = 14.sp, color = StatusGreen)
        }
    }
}

@Composable
private fun IntervalChip(min: Int, selected: Boolean, enabled: Boolean, onClick: () -> Unit) {
    if (selected) {
        Button(onClick = onClick, enabled = enabled) { Text("$min") }
    } else {
        OutlinedButton(onClick = onClick, enabled = enabled) { Text("$min") }
    }
}

private fun sendReminder(ctx: Context, action: String, intervalMin: Int = 0) {
    val intent = Intent(ctx, VibrationService::class.java).setAction(action)
    if (intervalMin > 0) intent.putExtra(VibrationService.EXTRA_INTERVAL_MIN, intervalMin)
    ContextCompat.startForegroundService(ctx, intent)
}
