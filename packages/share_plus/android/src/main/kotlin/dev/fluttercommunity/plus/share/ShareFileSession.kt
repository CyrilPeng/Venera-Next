package dev.fluttercommunity.plus.share

import java.io.File
import java.io.IOException
import java.util.UUID

/**
 * Owns only this invocation's copies. Once Android accepts the launch, the files
 * remain available to URI recipients. Chooser completion, another share, and
 * process restart are not consumer-completion signals and never delete them.
 * Android/user cache eviction can still remove this cache; there is no TTL sweep.
 */
internal class ShareFileSession(cache: File) {
    private val directory: File
    private var delivered = false
    private var nextFile = 0

    init {
        if (!cache.mkdirs() && !cache.isDirectory) {
            throw IOException("Cannot create share cache: $cache")
        }
        directory = File(cache, UUID.randomUUID().toString())
        if (!directory.mkdir()) {
            throw IOException("Cannot create share directory: $directory")
        }
    }

    fun copy(source: File): File {
        check(!delivered) { "Share has already been delivered" }
        // Preserve each display name, including two same-name files in one share.
        val item = File(directory, (nextFile++).toString())
        if (!item.mkdir()) throw IOException("Cannot create share item: $item")
        return source.copyTo(File(item, source.name), overwrite = false)
    }

    fun markDelivered() {
        delivered = true
    }

    fun cleanUndelivered() {
        if (!delivered && !directory.deleteRecursively()) {
            throw IOException("Cannot remove undelivered share directory: $directory")
        }
    }
}

/** Always preserves the original failure and attempts every owned cleanup. */
internal fun preserveShareFailure(error: Throwable, vararg cleanups: () -> Unit): Nothing {
    cleanups.forEach { cleanup ->
        try {
            cleanup()
        } catch (cleanupError: Throwable) {
            if (cleanupError !== error) error.addSuppressed(cleanupError)
        }
    }
    throw error
}
