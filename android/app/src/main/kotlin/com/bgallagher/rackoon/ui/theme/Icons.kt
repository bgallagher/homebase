package com.bgallagher.rackoon.ui.theme

import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.graphics.StrokeJoin
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.graphics.vector.PathParser
import androidx.compose.ui.unit.dp

/** The small line icons from the design canvas (16 x 16 viewBox, rounded strokes), so the app does not need the big icon set. */
object RackoonIcons {
    private fun rr(x: Float, y: Float, w: Float, h: Float, r: Float) =
        "M${x + r},$y H${x + w - r} Q${x + w},$y ${x + w},${y + r} V${y + h - r} Q${x + w},${y + h} ${x + w - r},${y + h} H${x + r} Q$x,${y + h} $x,${y + h - r} V${y + r} Q$x,$y ${x + r},$y Z"

    private fun stroke(name: String, width: Float = 1.5f, vararg paths: String): ImageVector =
        ImageVector.Builder(name, 24.dp, 24.dp, 16f, 16f).apply {
            for (p in paths) {
                addPath(
                    PathParser().parsePathString(p).toNodes(), stroke = SolidColor(Color.Black), strokeLineWidth = width,
                    strokeLineCap = StrokeCap.Round, strokeLineJoin = StrokeJoin.Round,
                )
            }
        }.build()

    val Overview = stroke("overview", 1.4f, rr(2f, 2f, 5f, 5f, 1.2f), rr(9f, 2f, 5f, 5f, 1.2f), rr(2f, 9f, 5f, 5f, 1.2f), rr(9f, 9f, 5f, 5f, 1.2f))
    val Terminal = stroke("terminal", 1.4f, rr(2f, 3f, 12f, 10f, 2f), "M5 7l2 1.5L5 10M8.5 10.5H11")
    val Lock = stroke("lock", 1.8f, rr(3f, 7f, 10f, 7f, 1.5f), "M5.5 7V5a2.5 2.5 0 015 0v2")
    val Copy = stroke("copy", 1.4f, rr(5.5f, 5.5f, 8f, 8f, 1.5f), "M10.5 5.5v-2a1.5 1.5 0 00-1.5-1.5H4a1.5 1.5 0 00-1.5 1.5V9A1.5 1.5 0 004 10.5h1.5")
    val ChevronDown = stroke("chevronDown", 1.8f, "M4 6l4 4 4-4")
    val ChevronRight = stroke("chevronRight", 1.8f, "M6 4l4 4-4 4")
    val ChevronLeft = stroke("chevronLeft", 1.8f, "M10 4l-4 4 4 4")
    val Close = stroke("close", 1.6f, "M4 4l8 8M12 4l-8 8")
    val Back = stroke("back", 1.6f, "M10 3L5 8l5 5")
    val Plus = stroke("plus", 1.8f, "M8 3v10M3 8h10")
    val Info = stroke("info", 1.5f, "M8 2a6 6 0 100 12A6 6 0 008 2z", "M8 7.5V11M8 5.2v.1")

    val More: ImageVector = ImageVector.Builder("more", 24.dp, 24.dp, 16f, 16f).apply {
        for (cx in listOf(3.5f, 8f, 12.5f)) {
            addPath(PathParser().parsePathString("M${cx - 1.3f},8 a1.3,1.3 0 1,0 2.6,0 a1.3,1.3 0 1,0 -2.6,0 Z").toNodes(), fill = SolidColor(Color.Black))
        }
    }.build()
}
