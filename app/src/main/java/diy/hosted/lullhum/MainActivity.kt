package diy.hosted.lullhum

import android.Manifest
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
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.core.content.ContextCompat
import diy.hosted.lullhum.ui.theme.LullhumTheme

/** Status-only screen — all control comes from the watch via [VibrationService]. */
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
    val (label, color) = when (status) {
        Status.RUNNING -> "Running" to Color(0xFF2E7D32)
        Status.STOPPED -> "Connected" to Color(0xFF1565C0)
        Status.DISCONNECTED -> "Waiting for watch" to Color(0xFF757575)
    }

    Column(
        modifier = modifier.fillMaxSize(),
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.Center
    ) {
        Text("Lullhum", fontSize = 28.sp, fontWeight = FontWeight.Bold)
        Spacer(Modifier.height(24.dp))
        Box(Modifier.size(56.dp).clip(CircleShape).background(color))
        Spacer(Modifier.height(16.dp))
        Text(label, fontSize = 20.sp, color = color, fontWeight = FontWeight.Medium)
    }
}
