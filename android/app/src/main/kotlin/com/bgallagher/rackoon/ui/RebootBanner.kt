package com.bgallagher.rackoon.ui

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableLongStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.bgallagher.rackoon.RebootUi
import com.bgallagher.rackoon.ui.theme.Rackoon
import com.bgallagher.rackoon.ui.theme.RackoonIcons
import kotlinx.coroutines.delay

/** A reboot started from the app: asking, waiting for the server to come back, back, timed out or failed. */
@Composable
fun RebootBanner(phase: RebootUi, name: String, onDismiss: () -> Unit) {
    val c = Rackoon.colors
    when (phase) {
        RebootUi.Requesting -> Box(c.accent, "Asking $name to reboot…", null, spinner = true, onDismiss = null)
        is RebootUi.Waiting -> {
            var now by remember { mutableLongStateOf(System.currentTimeMillis()) }
            LaunchedEffect(phase.sinceMillis) { while (true) { delay(1000); now = System.currentTimeMillis() } }
            Box(c.accent, "Rebooting $name…", "Waiting for it to come back · ${duration(now - phase.sinceMillis)} so far", spinner = true, onDismiss = null)
        }
        is RebootUi.Back -> Box(c.ok, "$name is back", "It restarted and answered again after ${duration(phase.afterMillis)}.", spinner = false, onDismiss = onDismiss)
        RebootUi.TimedOut -> Box(c.warn, "$name has not come back", "No answer after 10 minutes. Check the machine or the provider's console.", spinner = false, onDismiss = onDismiss)
        is RebootUi.Failed -> Box(c.danger, "Could not reboot $name", phase.message, spinner = false, onDismiss = onDismiss)
    }
}

private fun duration(millis: Long): String {
    val s = (millis / 1000).coerceAtLeast(0)
    return if (s < 60) "$s s" else "${s / 60} min ${s % 60} s"
}

@Composable
private fun Box(color: Color, title: String, detail: String?, spinner: Boolean, onDismiss: (() -> Unit)?) {
    val c = Rackoon.colors
    Row(
        Modifier.fillMaxWidth().clip(RoundedCornerShape(10.dp)).background(color.copy(alpha = 0.12f)).padding(start = 12.dp, top = 12.dp, bottom = 12.dp, end = if (onDismiss != null) 4.dp else 12.dp),
        verticalAlignment = Alignment.Top, horizontalArrangement = Arrangement.spacedBy(10.dp),
    ) {
        if (spinner) CircularProgressIndicator(Modifier.padding(top = 2.dp).size(18.dp), strokeWidth = 2.dp, color = color)
        Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(2.dp)) {
            Text(title, fontWeight = FontWeight.Medium, color = c.textPrimary)
            detail?.let { Text(it, fontSize = 12.sp, lineHeight = 17.sp, color = c.textSecondary) }
        }
        onDismiss?.let { IconTap(RackoonIcons.Close, "Dismiss", c.textMuted, it, Modifier.size(36.dp)) }
    }
}
