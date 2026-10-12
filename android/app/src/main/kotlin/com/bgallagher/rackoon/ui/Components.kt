package com.bgallagher.rackoon.ui

import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.Icon
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.bgallagher.rackoon.ui.theme.Rackoon

/** A card like the design's: card colour, 1 dp border, 14 dp corners. */
@Composable
fun RCard(modifier: Modifier = Modifier, borderColor: Color = Rackoon.colors.border, content: @Composable () -> Unit) {
    Box(
        modifier.clip(RoundedCornerShape(14.dp)).background(Rackoon.colors.card)
            .border(BorderStroke(1.dp, borderColor), RoundedCornerShape(14.dp)),
    ) { content() }
}

@Composable
fun StatusDot(color: Color, size: Int = 8) {
    Box(Modifier.size(size.dp).clip(CircleShape).background(color))
}

@Composable
fun SectionLabel(text: String, color: Color = Rackoon.colors.textMuted) {
    Text(text.uppercase(), color = color, fontSize = 12.sp, letterSpacing = 0.7.sp)
}

val MonoFamily = FontFamily.Monospace

@Composable
fun PrimaryButton(text: String, onClick: () -> Unit, modifier: Modifier = Modifier, enabled: Boolean = true) {
    Button(
        onClick = onClick, enabled = enabled, modifier = modifier.height(48.dp), shape = RoundedCornerShape(24.dp),
        colors = ButtonDefaults.buttonColors(
            containerColor = Rackoon.colors.accent, contentColor = Rackoon.colors.accentText,
            disabledContainerColor = Rackoon.colors.selection, disabledContentColor = Rackoon.colors.textMuted,
        ),
    ) { Text(text, fontWeight = FontWeight.SemiBold) }
}

@Composable
fun SecondaryButton(text: String, onClick: () -> Unit, modifier: Modifier = Modifier, enabled: Boolean = true) {
    OutlinedButton(
        onClick = onClick, enabled = enabled, modifier = modifier.height(48.dp), shape = RoundedCornerShape(24.dp),
        border = BorderStroke(1.dp, Rackoon.colors.border),
        colors = ButtonDefaults.outlinedButtonColors(contentColor = Rackoon.colors.textPrimary, disabledContentColor = Rackoon.colors.textMuted),
    ) { Text(text, fontWeight = FontWeight.Medium) }
}

/** A tappable icon with a 48 dp touch target. */
@Composable
fun IconTap(icon: ImageVector, label: String, tint: Color, onClick: () -> Unit, modifier: Modifier = Modifier) {
    Box(modifier.size(48.dp).clip(CircleShape).clickable(onClick = onClick), contentAlignment = Alignment.Center) {
        Icon(icon, contentDescription = label, tint = tint, modifier = Modifier.size(22.dp))
    }
}

/** The label/value rows of the System card. */
@Composable
fun InfoRow(label: String, value: String, onCopy: (() -> Unit)?) {
    Row(Modifier.fillMaxWidth().padding(start = 16.dp, end = 4.dp).height(52.dp), verticalAlignment = Alignment.CenterVertically) {
        Text(label, color = Rackoon.colors.textSecondary, fontSize = 13.sp, modifier = Modifier.width(96.dp))
        Text(value, fontFamily = MonoFamily, fontSize = 13.sp, color = Rackoon.colors.textPrimary, modifier = Modifier.weight(1f))
        if (onCopy != null) IconTap(com.bgallagher.rackoon.ui.theme.RackoonIcons.Copy, "Copy $label", Rackoon.colors.textSecondary, onCopy)
        else Spacer(Modifier.width(48.dp))
    }
}
