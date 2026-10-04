package dev.fluttercommunity.plus.share

import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.embedding.engine.plugins.FlutterPlugin.FlutterPluginBinding
import io.flutter.embedding.engine.plugins.activity.ActivityAware
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding
import io.flutter.plugin.common.MethodChannel

/** Plugin method host for presenting a share sheet via Intent  */
class SharePlusPlugin : FlutterPlugin, ActivityAware {
    private lateinit var share: Share
    private lateinit var manager: ShareSuccessManager
    private lateinit var methodChannel: MethodChannel
    private var activityBinding: ActivityPluginBinding? = null

    override fun onAttachedToEngine(binding: FlutterPluginBinding) {
        methodChannel = MethodChannel(binding.binaryMessenger, CHANNEL)
        manager = ShareSuccessManager()
        share = Share(context = binding.applicationContext, activity = null, manager = manager)
        val handler = MethodCallHandler(share, manager)
        methodChannel.setMethodCallHandler(handler)
    }

    override fun onDetachedFromEngine(binding: FlutterPluginBinding) {
        activityBinding?.removeActivityResultListener(manager)
        activityBinding = null
        share.setActivity(null)
        manager.unavailable()
        methodChannel.setMethodCallHandler(null)
    }

    override fun onAttachedToActivity(binding: ActivityPluginBinding) {
        activityBinding?.removeActivityResultListener(manager)
        activityBinding = binding
        binding.addActivityResultListener(manager)
        share.setActivity(binding.activity)
    }

    override fun onDetachedFromActivity() {
        activityBinding?.removeActivityResultListener(manager)
        activityBinding = null
        share.setActivity(null)
        manager.unavailable()
    }

    override fun onReattachedToActivityForConfigChanges(binding: ActivityPluginBinding) {
        onAttachedToActivity(binding)
    }

    override fun onDetachedFromActivityForConfigChanges() {
        activityBinding?.removeActivityResultListener(manager)
        activityBinding = null
        share.setActivity(null)
    }

    companion object {
        private const val CHANNEL = "dev.fluttercommunity.plus/share"
    }
}
