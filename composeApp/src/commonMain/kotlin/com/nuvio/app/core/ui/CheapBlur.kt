package com.nuvio.app.core.ui

import androidx.compose.runtime.Composable
import androidx.compose.runtime.remember
import coil3.compose.LocalPlatformContext
import coil3.request.ImageRequest

/**
 * Longest side, in pixels, of the source decoded for a "blurred backdrop". Drawn upscaled with
 * bicubic filtering it reads like a ~20-30dp Gaussian blur.
 */
internal const val CheapBlurSourcePx = 64

/**
 * Full-window backdrops used to be drawn at full resolution with Modifier.blur(). Skia doesn't
 * cache that, so the whole-screen Gaussian blur was recomputed on every frame while the content
 * above it scrolled. Decoding a tiny copy and letting the GPU upscale it gives almost the same look
 * for the cost of a single texture draw. Returns [url] unchanged when [enabled] is false.
 */
@Composable
internal fun rememberCheapBlurModel(url: String?, enabled: Boolean): Any? {
    val context = LocalPlatformContext.current
    return remember(url, enabled, context) {
        if (!enabled || url == null) {
            url
        } else {
            ImageRequest.Builder(context)
                .data(url)
                .size(CheapBlurSourcePx)
                .memoryCacheKeyExtra("nuvio.cheapBlur", CheapBlurSourcePx.toString())
                .build()
        }
    }
}
