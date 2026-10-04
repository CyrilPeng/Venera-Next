package dev.fluttercommunity.plus.share

import android.app.Activity
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import androidx.core.content.FileProvider
import java.io.File
import java.io.IOException

/**
 * Handles share intent. The `context` and `activity` are used to start the share
 * intent. The `activity` might be null when constructing the [Share] object and set
 * to non-null when an activity is available using [.setActivity].
 */
internal class Share(
    private val context: Context,
    private var activity: Activity?,
    private val manager: ShareSuccessManager
) {
    private val providerAuthority: String by lazy {
        getContext().packageName + ".flutter.share_provider"
    }

    private val shareCacheFolder: File
        get() = File(getContext().cacheDir, "share_plus")

    /**
     * Setting mutability flags as API v31+ requires.
     */
    private val immutabilityIntentFlags: Int by lazy {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
            PendingIntent.FLAG_MUTABLE
        } else {
            0
        }
    }

    private fun getContext(): Context {
        return if (activity != null) {
            activity!!
        } else {
            context
        }
    }

    /**
     * Sets the activity when an activity is available. When the activity becomes unavailable, use
     * this method to set it to null.
     */
    fun setActivity(activity: Activity?) {
        this.activity = activity
    }

    @Throws(IOException::class)
    fun share(arguments: Map<String, Any>, withResult: Boolean) {
        var files: ShareFileSession? = null
        val grantedUris = mutableSetOf<Uri>()
        var launched = false
        try {
            val text = arguments["text"] as String?
            val uri = arguments["uri"] as String?
            val subject = arguments["subject"] as String?
            val title = arguments["title"] as String?
            val paths = (arguments["paths"] as List<*>?)?.filterIsInstance<String>()
            val mimeTypes = (arguments["mimeTypes"] as List<*>?)?.filterIsInstance<String>()
            val fileUris = paths?.let {
                val ownedFiles = ShareFileSession(shareCacheFolder)
                files = ownedFiles
                getUrisForPaths(it, ownedFiles)
            }

            // Create Share Intent
            val shareIntent = Intent()
            if (fileUris == null) {
                shareIntent.apply {
                    action = Intent.ACTION_SEND
                    type = "text/plain"
                    putExtra(Intent.EXTRA_TEXT, uri ?: text)
                    if (!subject.isNullOrBlank()) putExtra(Intent.EXTRA_SUBJECT, subject)
                    if (!title.isNullOrBlank()) putExtra(Intent.EXTRA_TITLE, title)
                }
            } else {
                when {
                    fileUris.isEmpty() -> {
                        throw IOException("Error sharing files: No files found")
                    }

                    fileUris.size == 1 -> {
                        val mimeType = if (!mimeTypes.isNullOrEmpty()) {
                            mimeTypes.first()
                        } else {
                            "*/*"
                        }
                        shareIntent.apply {
                            action = Intent.ACTION_SEND
                            type = mimeType
                            putExtra(Intent.EXTRA_STREAM, fileUris.first())
                        }
                    }

                    else -> {
                        shareIntent.apply {
                            action = Intent.ACTION_SEND_MULTIPLE
                            type = reduceMimeTypes(mimeTypes)
                            putParcelableArrayListExtra(Intent.EXTRA_STREAM, fileUris)
                        }
                    }
                }

                shareIntent.apply {
                    if (!text.isNullOrBlank()) putExtra(Intent.EXTRA_TEXT, text)
                    if (!subject.isNullOrBlank()) putExtra(Intent.EXTRA_SUBJECT, subject)
                    if (!title.isNullOrBlank()) putExtra(Intent.EXTRA_TITLE, title)
                    addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                }
            }

            // Create the chooser intent
            val chooserIntent =
                if (withResult && Build.VERSION.SDK_INT >= Build.VERSION_CODES.LOLLIPOP_MR1) {
                    // Build chooserIntent with broadcast to ShareSuccessManager on success
                    Intent.createChooser(
                        shareIntent,
                        title,
                        PendingIntent.getBroadcast(
                            context,
                            manager.request.activityCode,
                            Intent(context, SharePlusPendingIntent::class.java).apply {
                                action = manager.request.token
                                putExtra(SharePlusPendingIntent.REQUEST_TOKEN, manager.request.token)
                            },
                            PendingIntent.FLAG_ONE_SHOT or immutabilityIntentFlags
                        ).intentSender
                    )
                } else {
                    Intent.createChooser(shareIntent, title)
                }

            // Grant permissions to all apps that can handle the files shared
            if (fileUris != null) {
                val resInfoList = getContext().packageManager.queryIntentActivities(
                    chooserIntent, PackageManager.MATCH_DEFAULT_ONLY
                )
                resInfoList.forEach { resolveInfo ->
                    val packageName = resolveInfo.activityInfo.packageName
                    fileUris.forEach { fileUri ->
                        grantedUris.add(fileUri)
                        getContext().grantUriPermission(
                            packageName,
                            fileUri,
                            Intent.FLAG_GRANT_WRITE_URI_PERMISSION or Intent.FLAG_GRANT_READ_URI_PERMISSION,
                        )
                    }
                }
            }

            // Launch share intent
            startActivity(chooserIntent, withResult)
            launched = true
            files?.markDelivered()
            // An accepted launch owns the URI copies even if no Activity can report
            // chooser completion. Never acknowledge before startActivity can fail.
            if (withResult && activity == null) manager.unavailable()
        } catch (error: Throwable) {
            if (launched) throw error
            val revokeGrants = grantedUris.map { uri ->
                {
                    getContext().revokeUriPermission(
                        uri,
                        Intent.FLAG_GRANT_WRITE_URI_PERMISSION or Intent.FLAG_GRANT_READ_URI_PERMISSION,
                    )
                }
            }
            preserveShareFailure(error, *revokeGrants.toTypedArray(), { files?.cleanUndelivered() })
        }
    }

    private fun startActivity(intent: Intent, withResult: Boolean) {
        if (activity != null) {
            if (withResult) {
                activity!!.startActivityForResult(intent, manager.request.activityCode)
            } else {
                activity!!.startActivity(intent)
            }
        } else {
            intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            context.startActivity(intent)
        }
    }

    @Throws(IOException::class)
    private fun getUrisForPaths(paths: List<String>, files: ShareFileSession): ArrayList<Uri> {
        val uris = ArrayList<Uri>(paths.size)
        paths.forEach { path ->
            val file = files.copy(File(path))
            uris.add(FileProvider.getUriForFile(getContext(), providerAuthority, file))
        }
        return uris
    }

    /**
     * Reduces provided MIME types to a common one to provide [Intent] with a correct type to share
     * multiple files
     */
    private fun reduceMimeTypes(mimeTypes: List<String>?): String {
        if (mimeTypes?.isEmpty() != false) return "*/*"
        if (mimeTypes.size == 1) return mimeTypes.first()

        var commonMimeType = mimeTypes.first()
        for (i in 1..mimeTypes.lastIndex) {
            if (commonMimeType != mimeTypes[i]) {
                if (getMimeTypeBase(commonMimeType) == getMimeTypeBase(mimeTypes[i])) {
                    commonMimeType = getMimeTypeBase(mimeTypes[i]) + "/*"
                } else {
                    commonMimeType = "*/*"
                    break
                }
            }
        }
        return commonMimeType
    }

    /**
     * Returns the first part of provided MIME type, which comes before '/' symbol
     */
    private fun getMimeTypeBase(mimeType: String?): String {
        return if (mimeType == null || !mimeType.contains("/")) {
            "*"
        } else {
            mimeType.substring(0, mimeType.indexOf("/"))
        }
    }

}
