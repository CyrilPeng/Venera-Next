// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 VeneraNext contributors
package com.cyrilpeng.venera_saf

import android.app.Activity
import android.content.Intent
import android.provider.DocumentsContract
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.embedding.engine.plugins.activity.ActivityAware
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.PluginRegistry.ActivityResultListener

internal object NativeBridge {
    init { System.loadLibrary("venera_saf") }
    @JvmStatic external fun initialize(type: Class<*>)
}

class VeneraSafPlugin : FlutterPlugin, ActivityAware,
    MethodChannel.MethodCallHandler, ActivityResultListener {
    private var channel: MethodChannel? = null
    private var activity: ActivityPluginBinding? = null
    private var picker: MethodChannel.Result? = null

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        SafDocuments.configure(binding.applicationContext)
        NativeBridge.initialize(SafDocuments::class.java)
        channel = MethodChannel(binding.binaryMessenger, "venera/saf").also {
            it.setMethodCallHandler(this)
        }
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        finishPickerError("Plugin detached")
        channel?.setMethodCallHandler(null)
        channel = null
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        if (call.method != "pickDirectory") { result.notImplemented(); return }
        val host = activity?.activity
        if (host == null) { result.error("activity_unavailable", "No activity is attached", null); return }
        if (picker != null) { result.error("picker_busy", "A directory picker is already open", null); return }
        picker = result
        try {
            host.startActivityForResult(Intent(Intent.ACTION_OPEN_DOCUMENT_TREE).apply {
                addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION or
                    Intent.FLAG_GRANT_WRITE_URI_PERMISSION or
                    Intent.FLAG_GRANT_PERSISTABLE_URI_PERMISSION or
                    Intent.FLAG_GRANT_PREFIX_URI_PERMISSION)
            }, REQUEST_DIRECTORY)
        } catch (error: Exception) {
            finishPickerError(error.toString())
        }
    }

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?): Boolean {
        if (requestCode != REQUEST_DIRECTORY) return false
        val result = picker ?: return false
        picker = null
        if (resultCode != Activity.RESULT_OK || data?.data == null) {
            result.success(null); return true
        }
        try {
            val uri = data.data!!
            val flags = data.flags and (Intent.FLAG_GRANT_READ_URI_PERMISSION or
                Intent.FLAG_GRANT_WRITE_URI_PERMISSION)
            SafDocuments.persist(uri, flags)
            result.success("android://" + DocumentsContract.getTreeDocumentId(uri))
        } catch (error: Exception) {
            result.error("grant_failed", error.toString(), null)
        }
        return true
    }

    private fun finishPickerError(message: String) {
        val result = picker
        picker = null
        result?.error("activity_unavailable", message, null)
    }

    override fun onAttachedToActivity(binding: ActivityPluginBinding) {
        activity = binding
        binding.addActivityResultListener(this)
    }
    override fun onDetachedFromActivityForConfigChanges() {
        activity?.removeActivityResultListener(this)
        activity = null
    }
    override fun onReattachedToActivityForConfigChanges(binding: ActivityPluginBinding) =
        onAttachedToActivity(binding)
    override fun onDetachedFromActivity() {
        onDetachedFromActivityForConfigChanges()
        finishPickerError("Activity detached")
    }

    companion object { private const val REQUEST_DIRECTORY = 0x5a71 }
}
