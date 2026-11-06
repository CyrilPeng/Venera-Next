// SPDX-License-Identifier: GPL-3.0-or-later
package com.cyrilpeng.venera_saf_probe

import android.app.Activity
import android.content.Intent
import android.net.Uri
import android.provider.DocumentsContract
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private var pending: MethodChannel.Result? = null
    override fun configureFlutterEngine(engine: FlutterEngine) {
        super.configureFlutterEngine(engine)
        MethodChannel(engine.dartExecutor.binaryMessenger, "saf_probe/control").setMethodCallHandler { call, result ->
            try {
                when (call.method) {
                    "phase" -> result.success(intent.getStringExtra("phase") ?: "initial")
                    "grant" -> {
                        require(pending == null)
                        pending = result
                        startActivityForResult(Intent().setClassName("com.cyrilpeng.venera_saf_probe_provider",
                            "com.cyrilpeng.venera_saf_probe_provider.GrantActivity")
                            .putExtra("authority", call.argument<String>("authority") ?: AUTHORITY)
                            .putExtra("root", call.argument<String>("root") ?: LONG_ROOT), 981)
                    }
                    "revoke" -> {
                        val authority = call.argument<String>("authority") ?: AUTHORITY
                        val root = call.argument<String>("root") ?: LONG_ROOT
                        require(authority in setOf(AUTHORITY, ALIAS) && root in setOf(LONG_ROOT, SHORT_ROOT, MIRROR_ROOT))
                        val uri = DocumentsContract.buildTreeDocumentUri(authority, root)
                        if (contentResolver.persistedUriPermissions.any { it.uri == uri }) {
                            contentResolver.releasePersistableUriPermission(uri,
                                Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_GRANT_WRITE_URI_PERMISSION)
                        }
                        result.success(null)
                    }
                    "stats", "offline", "reset" -> {
                        val bundle = contentResolver.call(Uri.parse("content://com.cyrilpeng.venera_saf_probe_provider.control"),
                            call.method, call.argument<Boolean>("enabled")?.toString(), null)!!
                        result.success(mapOf("opens" to bundle.getInt("opens"), "closes" to bundle.getInt("closes"),
                            "offline" to bundle.getBoolean("offline")))
                    }
                    else -> result.notImplemented()
                }
            } catch (error: Exception) {
                pending = null
                result.error("probe_control", error.toString(), null)
            }
        }
    }
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        if (requestCode != 981) { super.onActivityResult(requestCode, resultCode, data); return }
        val result = pending ?: return
        pending = null
        try {
            require(resultCode == Activity.RESULT_OK && data?.data != null)
            val uri = data!!.data!!
            contentResolver.takePersistableUriPermission(uri, data.flags and
                (Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_GRANT_WRITE_URI_PERMISSION))
            result.success("android://" + DocumentsContract.getTreeDocumentId(uri))
        } catch (error: Exception) { result.error("probe_grant", error.toString(), null) }
    }
    companion object {
        const val AUTHORITY = "com.cyrilpeng.venera_saf_probe_provider.documents"
        const val ALIAS = "com.cyrilpeng.venera_saf_probe_provider.alias"
        const val LONG_ROOT = "probe:目录/授权根"
        const val SHORT_ROOT = "probe:目录"
        const val MIRROR_ROOT = "probe:镜像根"
    }
}
