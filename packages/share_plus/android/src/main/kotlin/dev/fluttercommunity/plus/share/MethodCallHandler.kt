package dev.fluttercommunity.plus.share

import android.os.Build
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

/** Handles the method calls for the plugin.  */
internal class MethodCallHandler(
    private val share: Share,
    private val manager: ShareSuccessManager,
) : MethodChannel.MethodCallHandler {

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        if (call.method != "share") {
            result.notImplemented()
            return
        }
        var ownsRequest = false
        try {
            expectMapArguments(call)
            if (!manager.setCallback(result)) return
            ownsRequest = true
            val isWithResult = Build.VERSION.SDK_INT >= Build.VERSION_CODES.LOLLIPOP_MR1
            share.share(call.arguments<Map<String, Any>>()!!, isWithResult)
            if (!isWithResult) manager.unavailable()
        } catch (e: Throwable) {
            if (ownsRequest) manager.clear()
            // Throwable is not a StandardMessageCodec value. Include suppressed
            // cleanup failures in an encodable stack instead of losing the reply.
            result.error("Share failed", e.message, e.stackTraceToString())
        }
    }

    @Throws(IllegalArgumentException::class)
    private fun expectMapArguments(call: MethodCall) {
        require(call.arguments is Map<*, *>) { "Map arguments expected" }
    }
}
