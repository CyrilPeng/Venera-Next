package dev.fluttercommunity.plus.share

import android.content.Intent
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.PluginRegistry.ActivityResultListener

/** Owns one chooser callback; another caller cannot replace it. */
internal class ShareSuccessManager : ActivityResultListener {
    private val requests get() = SharePlusPendingIntent.requests
    val request: ShareRequestCoordinator.Request
        get() = checkNotNull(requests.current(this)) { "No active share request" }

    fun setCallback(callback: MethodChannel.Result): Boolean {
        if (requests.begin(this) { callback.success(it) } != null) return true
        callback.error("share_busy", "Another native share request is still pending", null)
        return false
    }

    fun unavailable() = requests.unavailable(this)

    fun clear() = requests.clear(this)

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?): Boolean =
        requests.complete(this, requestCode)
}
