// SPDX-License-Identifier: GPL-3.0-or-later
package com.cyrilpeng.venera_saf_probe_provider

import android.app.Activity
import android.content.ContentProvider
import android.content.ContentValues
import android.content.Intent
import android.database.Cursor
import android.database.MatrixCursor
import android.net.Uri
import android.os.Bundle
import android.os.CancellationSignal
import android.os.Handler
import android.os.Looper
import android.os.ParcelFileDescriptor
import android.provider.DocumentsContract
import android.provider.DocumentsContract.Document
import android.provider.DocumentsContract.Root
import android.provider.DocumentsProvider
import java.io.File
import java.io.FileNotFoundException
import java.io.IOException
import java.util.concurrent.atomic.AtomicInteger

const val AUTHORITY = "com.cyrilpeng.venera_saf_probe_provider.documents"
const val ALIAS = "com.cyrilpeng.venera_saf_probe_provider.alias"
const val LONG_ROOT = "probe:目录/授权根"
const val SHORT_ROOT = "probe:目录"
const val MIRROR_ROOT = "probe:镜像根"
const val CLIENT = "com.cyrilpeng.venera_saf_probe"

object ProbeState {
    @Volatile var offline = false
    val opens = AtomicInteger()
    val closes = AtomicInteger()
}

class GrantActivity : Activity() {
    override fun onCreate(state: Bundle?) {
        super.onCreate(state)
        require(callingPackage == CLIENT)
        val authority = intent.getStringExtra("authority") ?: AUTHORITY
        val root = intent.getStringExtra("root") ?: LONG_ROOT
        require(authority in setOf(AUTHORITY, ALIAS) && root in setOf(LONG_ROOT, SHORT_ROOT, MIRROR_ROOT))
        val uri = DocumentsContract.buildTreeDocumentUri(authority, root)
        val flags = Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_GRANT_WRITE_URI_PERMISSION or
            Intent.FLAG_GRANT_PERSISTABLE_URI_PERMISSION or Intent.FLAG_GRANT_PREFIX_URI_PERMISSION
        grantUriPermission(CLIENT, uri, flags)
        setResult(RESULT_OK, Intent().setData(uri).addFlags(flags))
        finish()
    }
}

class ProbeControlProvider : ContentProvider() {
    override fun onCreate() = true
    override fun call(method: String, arg: String?, extras: Bundle?): Bundle {
        require(callingPackage == CLIENT)
        if (method == "offline") ProbeState.offline = arg == "true"
        if (method == "reset") {
            require(ProbeState.opens.get() == ProbeState.closes.get())
            for (name in listOf("long", "short")) {
                val root = File(context!!.filesDir, name).canonicalFile
                require(root.parentFile == context!!.filesDir.canonicalFile)
                root.deleteRecursively(); root.mkdirs()
            }
            ProbeState.offline = false
            ProbeState.opens.set(0); ProbeState.closes.set(0)
        }
        return Bundle().apply {
            putInt("opens", ProbeState.opens.get())
            putInt("closes", ProbeState.closes.get())
            putBoolean("offline", ProbeState.offline)
        }
    }
    override fun query(uri: Uri, projection: Array<String>?, selection: String?, args: Array<String>?, order: String?): Cursor? = null
    override fun getType(uri: Uri): String? = null
    override fun insert(uri: Uri, values: ContentValues?): Uri? = null
    override fun delete(uri: Uri, selection: String?, args: Array<String>?) = 0
    override fun update(uri: Uri, values: ContentValues?, selection: String?, args: Array<String>?) = 0
}

open class ProbeDocumentsProvider : DocumentsProvider() {
    private val columns = arrayOf(Document.COLUMN_DOCUMENT_ID, Document.COLUMN_DISPLAY_NAME,
        Document.COLUMN_MIME_TYPE, Document.COLUMN_SIZE, Document.COLUMN_LAST_MODIFIED, Document.COLUMN_FLAGS)
    override fun onCreate(): Boolean {
        base(LONG_ROOT).mkdirs(); base(SHORT_ROOT).mkdirs(); return true
    }
    private fun base(root: String) = File(context!!.filesDir, if (root == SHORT_ROOT) "short" else "long")
    private fun root(id: String) = listOf(LONG_ROOT, SHORT_ROOT, MIRROR_ROOT).firstOrNull {
        id == it || id.startsWith(it + "|")
    } ?: throw FileNotFoundException("Unknown probe document")
    private fun file(id: String): File {
        if (ProbeState.offline) throw IOException("Synthetic document provider is unavailable")
        val root = root(id)
        val base = base(root).canonicalFile
        val result = if (id == root) base else File(base, id.substring(root.length + 1)).canonicalFile
        require(result == base || result.path.startsWith(base.path + File.separator))
        return result
    }
    private fun id(root: String, file: File) = if (file == base(root).canonicalFile) root
        else (if (root == MIRROR_ROOT) LONG_ROOT else root) + "|" +
            file.relativeTo(base(root).canonicalFile).path.replace(File.separatorChar, '/')
    private fun row(cursor: MatrixCursor, document: String, source: File) {
        if (!source.exists()) throw FileNotFoundException("Missing probe document")
        val values = mapOf<String, Any>(Document.COLUMN_DOCUMENT_ID to document,
            Document.COLUMN_DISPLAY_NAME to source.name,
            Document.COLUMN_MIME_TYPE to if (source.isDirectory) Document.MIME_TYPE_DIR else "application/octet-stream",
            Document.COLUMN_SIZE to source.length(), Document.COLUMN_LAST_MODIFIED to source.lastModified(),
            Document.COLUMN_FLAGS to if (source.isDirectory) Document.FLAG_DIR_SUPPORTS_CREATE or
                Document.FLAG_SUPPORTS_DELETE or Document.FLAG_SUPPORTS_RENAME else
                Document.FLAG_SUPPORTS_WRITE or Document.FLAG_SUPPORTS_DELETE or Document.FLAG_SUPPORTS_RENAME)
        val row = cursor.newRow()
        cursor.columnNames.forEach { row.add(values[it]) }
    }
    override fun queryRoots(projection: Array<String>?): Cursor {
        val cursor = MatrixCursor(projection ?: arrayOf(Root.COLUMN_ROOT_ID, Root.COLUMN_DOCUMENT_ID,
            Root.COLUMN_TITLE, Root.COLUMN_FLAGS))
        listOf(LONG_ROOT, SHORT_ROOT, MIRROR_ROOT).forEach { root ->
            val values = mapOf<String, Any>(Root.COLUMN_ROOT_ID to root, Root.COLUMN_DOCUMENT_ID to root,
                Root.COLUMN_TITLE to "Venera SAF probe", Root.COLUMN_FLAGS to (Root.FLAG_SUPPORTS_CREATE or Root.FLAG_LOCAL_ONLY))
            val row = cursor.newRow(); cursor.columnNames.forEach { row.add(values[it]) }
        }
        return cursor
    }
    override fun queryDocument(documentId: String, projection: Array<String>?): Cursor =
        MatrixCursor(projection ?: columns).also { row(it, documentId, file(documentId)) }
    override fun queryChildDocuments(parentDocumentId: String, projection: Array<String>?, sortOrder: String?): Cursor {
        val parent = file(parentDocumentId)
        if (!parent.isDirectory) throw FileNotFoundException("Not a probe directory")
        return MatrixCursor(projection ?: columns).also { cursor ->
            parent.listFiles()!!.sortedBy { it.name }.forEach { row(cursor, id(root(parentDocumentId), it), it) }
        }
    }
    override fun isChildDocument(parentDocumentId: String, documentId: String): Boolean {
        val parent = file(parentDocumentId); val child = file(documentId)
        return child.path.startsWith(parent.path + File.separator)
    }
    override fun createDocument(parentDocumentId: String, mimeType: String, displayName: String): String {
        require(displayName.isNotEmpty() && displayName != "." && displayName != ".." && !displayName.contains('/'))
        val parent = file(parentDocumentId)
        val result = File(parent, if (displayName.endsWith(".wrong")) "$displayName.changed" else displayName)
        if (mimeType == Document.MIME_TYPE_DIR) {
            if (!result.mkdir()) throw IOException("Cannot create probe directory")
        } else if (!result.createNewFile()) throw IOException("Cannot create probe file")
        return id(root(parentDocumentId), result)
    }
    override fun renameDocument(documentId: String, displayName: String): String {
        require(displayName.isNotEmpty() && displayName != "." && displayName != ".." && !displayName.contains('/'))
        val source = file(documentId)
        val destination = File(source.parentFile, displayName)
        if (destination.exists() || !source.renameTo(destination)) throw IOException("Cannot rename probe document")
        return id(root(documentId), destination)
    }
    override fun deleteDocument(documentId: String) {
        require(documentId != root(documentId))
        if (!file(documentId).deleteRecursively()) throw IOException("Cannot delete probe document")
    }
    override fun openDocument(documentId: String, mode: String, signal: CancellationSignal?): ParcelFileDescriptor {
        val source = file(documentId)
        if (source.name == "remote-error") {
            val pipe = ParcelFileDescriptor.createReliablePipe()
            pipe[1].closeWithError("synthetic provider close error")
            return pipe[0]
        }
        ProbeState.opens.incrementAndGet()
        return try {
            ParcelFileDescriptor.open(source, ParcelFileDescriptor.parseMode(mode),
                Handler(Looper.getMainLooper())) { ProbeState.closes.incrementAndGet() }
        } catch (error: Exception) {
            ProbeState.closes.incrementAndGet(); throw error
        }
    }
}

class ProbeAliasDocumentsProvider : ProbeDocumentsProvider()
