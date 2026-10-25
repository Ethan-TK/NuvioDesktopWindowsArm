package com.nuvio.app.core.ui

import androidx.compose.foundation.ExperimentalFoundationApi
import androidx.compose.foundation.LocalIndication
import androidx.compose.foundation.combinedClickable
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.runtime.Composable
import androidx.compose.runtime.RememberObserver
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.runtime.staticCompositionLocalOf
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.drawWithContent
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Rect
import androidx.compose.ui.graphics.GraphicsContext
import androidx.compose.ui.graphics.drawscope.DrawScope
import androidx.compose.ui.graphics.drawscope.scale
import androidx.compose.ui.graphics.layer.drawLayer
import androidx.compose.ui.layout.LayoutCoordinates
import androidx.compose.ui.layout.onPlaced
import androidx.compose.ui.layout.positionInRoot
import androidx.compose.ui.platform.LocalGraphicsContext
import androidx.compose.ui.unit.Dp
import com.nuvio.app.isDesktop

internal val LocalPosterClickAnchor = staticCompositionLocalOf<((PosterZoomAnchor) -> Unit)?> { null }

internal class PosterLiftSource(private val graphicsContext: GraphicsContext) : RememberObserver {
    val layer = graphicsContext.createGraphicsLayer()
    // Coordinates are captured cheaply on placement; the root-relative rect is only computed when a
    // long-press/zoom actually needs it (previously every visible card recomputed it each scroll frame).
    var coordinates: LayoutCoordinates? = null
    private var lastBounds: Rect? = null
    val bounds: Rect?
        get() {
            val current = coordinates?.takeIf { it.isAttached } ?: return lastBounds
            val position = current.positionInRoot()
            return Rect(
                left = position.x,
                top = position.y,
                right = position.x + current.size.width,
                bottom = position.y + current.size.height,
            ).also { lastBounds = it }
        }
    var isLifted by mutableStateOf(false)
        private set
    private var rememberCount = 0

    val canLift: Boolean
        get() = rememberCount > 0 && !layer.isReleased && layer.size.width > 0 && layer.size.height > 0

    fun lift(): Boolean {
        if (!canLift) return false
        isLifted = true
        return true
    }

    fun land() {
        isLifted = false
        if (rememberCount == 0) release()
    }

    override fun onRemembered() {
        rememberCount++
    }

    override fun onForgotten() {
        rememberCount--
        if (rememberCount == 0 && !isLifted) release()
    }

    override fun onAbandoned() {
        if (rememberCount == 0 && !isLifted) release()
    }

    private fun release() {
        if (!layer.isReleased) graphicsContext.releaseGraphicsLayer(layer)
    }
}

@OptIn(ExperimentalFoundationApi::class)
@Composable
internal fun Modifier.posterCardClickable(
    onClick: (() -> Unit)?,
    onLongClick: (() -> Unit)?,
    zoomImageUrl: String? = null,
    zoomCornerRadius: Dp = NuvioTokens.Radius.poster,
    hoverScaleEnabled: Boolean = true,
): Modifier {
    val graphicsContext = LocalGraphicsContext.current
    val source = remember(graphicsContext, zoomImageUrl) { PosterLiftSource(graphicsContext) }
    val onPosterClickAnchor = LocalPosterClickAnchor.current
    val posterModifier = Modifier
        .drawWithContent {
            source.layer.record { this@drawWithContent.drawContent() }
            if (!source.isLifted) drawLayer(source.layer)
        }
        .onPlaced { coordinates -> source.coordinates = coordinates }
        .then(this)
    if (onClick == null && onLongClick == null) return posterModifier
    val interactionSource = remember { MutableInteractionSource() }
    val handleLongClick = onLongClick?.let { longClick ->
        {
            source.bounds?.let { cardBounds ->
                PosterZoomAnchorHolder.stash(
                    PosterZoomAnchor(cardBounds, zoomImageUrl, zoomCornerRadius).also {
                        it.source = source
                    },
                )
            }
            longClick()
        }
    }
    return Modifier
        .desktopPosterHoverScale(
            enabled = hoverScaleEnabled,
            interactionSource = interactionSource,
        )
        .then(posterModifier)
        .combinedClickable(
            interactionSource = interactionSource,
            indication = if (!isDesktop && onPosterClickAnchor == null) LocalIndication.current else null,
            onClick = {
                if (onClick != null) {
                    source.bounds?.let { bounds ->
                        onPosterClickAnchor?.invoke(
                            PosterZoomAnchor(bounds, zoomImageUrl, zoomCornerRadius).also { it.source = source },
                        )
                    }
                    onClick()
                }
            },
            onLongClick = handleLongClick,
        )
        .secondaryClick(handleLongClick)
}

internal fun DrawScope.drawLiftedPoster(source: PosterLiftSource) {
    val layer = source.layer
    if (layer.isReleased || layer.size.width <= 0 || layer.size.height <= 0) return
    scale(
        scaleX = size.width / layer.size.width,
        scaleY = size.height / layer.size.height,
        pivot = Offset.Zero,
    ) {
        drawLayer(layer)
    }
}
