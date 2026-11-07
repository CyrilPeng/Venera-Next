// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 VeneraNext contributors
package com.cyrilpeng.venera_saf

import android.content.ContentResolver
import android.content.Context
import android.content.Intent
import android.content.SharedPreferences
import android.net.Uri
import android.os.ParcelFileDescriptor
import android.provider.DocumentsContract
import android.provider.DocumentsContract.Document
import android.system.ErrnoException
import android.system.Os
import android.system.OsConstants
import android.webkit.MimeTypeMap
import org.json.JSONArray
import org.json.JSONObject
import java.io.FileNotFoundException
import java.io.IOException
import java.util.Locale

internal class SafFailure(val code: Int, message: String) : IOException(message)

internal object SafDocuments {
    private const val PREFIX = "android://"
    @Volatile private var resolver: ContentResolver? = null
    @Volatile private var preferences: SharedPreferences? = null
    private val grantLock = Any()
    private val projection = arrayOf(Document.COLUMN_DOCUMENT_ID, Document.COLUMN_DISPLAY_NAME,
        Document.COLUMN_MIME_TYPE, Document.COLUMN_SIZE, Document.COLUMN_LAST_MODIFIED,
        Document.COLUMN_FLAGS)
    private val io: ContentResolver get() = resolver ?: throw SafFailure(5, "Storage access is not initialized")

    fun configure(context: Context) {
        resolver = context.applicationContext.contentResolver
        preferences = context.applicationContext.getSharedPreferences("venera_saf_grants", Context.MODE_PRIVATE)
        grants()
    }

    fun persist(uri: Uri, flags: Int) {
        if (!DocumentsContract.isTreeUri(uri) || flags == 0) {
            throw SafFailure(13, "Directory picker did not return a persistent tree grant")
        }
        io.takePersistableUriPermission(uri, flags)
    }

    private data class Grant(val uri: Uri, val id: String, val read: Boolean, val write: Boolean) {
        val path get() = PREFIX + id
    }
    private data class Node(val uri: Uri, val id: String, val name: String, val directory: Boolean,
        val size: Long, val modified: Long, val flags: Int) {
        val identity get() = "${uri.authority}:$id"
        fun json(path: String) = JSONObject().put("path", path).put("identity", identity)
            .put("type", if (directory) "directory" else "file")
            .put("size", if (directory) 0 else size).put("modified", modified)
    }

    private fun grants(): List<Grant> {
        val active = io.persistedUriPermissions.filter {
        DocumentsContract.isTreeUri(it.uri) && (it.isReadPermission || it.isWritePermission)
    }.map { Grant(it.uri, DocumentsContract.getTreeDocumentId(it.uri), it.isReadPermission, it.isWritePermission) }
        .distinctBy { Pair(it.uri.authority, it.id) }
        synchronized(grantLock) {
            val storage = preferences ?: throw SafFailure(5, "Grant registry is unavailable")
            val known = storage.getStringSet("known_tree_ids", emptySet())!!.toMutableSet()
            if (known.addAll(active.map { it.id })) storage.edit().putStringSet("known_tree_ids", known).apply()
        }
        return active
    }

    private fun validPath(value: String): String {
        if (!value.startsWith(PREFIX) || value.indexOf('\u0000') >= 0) {
            throw SafFailure(22, "Invalid Android document path")
        }
        return value
    }

    private fun grant(path: String): Grant {
        validPath(path)
        val active = grants()
        val known = preferences?.getStringSet("known_tree_ids", emptySet()) ?: emptySet()
        val longest = known.map { PREFIX + it }.filter { path == it || path.startsWith(it + "/") }
            .maxOfOrNull { it.length }
            ?: throw SafFailure(13, "No persistent directory permission for $path")
        val selected = active.filter { it.path.length == longest && (path == it.path || path.startsWith(it.path + "/")) }
        if (selected.isEmpty()) throw SafFailure(13, "Persistent directory permission was revoked for $path")
        if (selected.size != 1) throw SafFailure(22, "Multiple document providers share this tree ID: $path")
        return selected.single()
    }

    private fun requireAccess(grant: Grant, write: Boolean = false, read: Boolean = true) {
        if (read && !grant.read || write && !grant.write) {
            throw SafFailure(13, "Persistent directory permission does not allow this operation")
        }
    }

    private fun node(grant: Grant, uri: Uri): Node? {
        io.query(uri, projection, null, null, null)?.use { cursor ->
            if (!cursor.moveToFirst()) return null
            return Node(uri, cursor.getString(0), cursor.getString(1) ?: "",
                cursor.getString(2) == Document.MIME_TYPE_DIR,
                if (cursor.isNull(3)) -1 else cursor.getLong(3),
                if (cursor.isNull(4)) 0 else cursor.getLong(4),
                if (cursor.isNull(5)) 0 else cursor.getInt(5))
        }
        throw SafFailure(5, "Document provider is unavailable: ${grant.uri.authority}")
    }

    private fun children(grant: Grant, parent: Node): List<Node> {
        if (!parent.directory) throw SafFailure(20, "Document is not a directory")
        val uri = DocumentsContract.buildChildDocumentsUriUsingTree(grant.uri, parent.id)
        val result = mutableListOf<Node>()
        io.query(uri, projection, null, null, null)?.use { cursor ->
            while (cursor.moveToNext()) {
                val id = cursor.getString(0)
                val name = cursor.getString(1) ?: throw SafFailure(5, "Provider omitted a document name")
                validName(name)
                result.add(Node(DocumentsContract.buildDocumentUriUsingTree(grant.uri, id),
                    id, name, cursor.getString(2) == Document.MIME_TYPE_DIR,
                    if (cursor.isNull(3)) -1 else cursor.getLong(3),
                    if (cursor.isNull(4)) 0 else cursor.getLong(4),
                    if (cursor.isNull(5)) 0 else cursor.getInt(5)))
            }
            if (result.map { it.name }.distinct().size != result.size) {
                throw SafFailure(17, "Provider returned ambiguous duplicate display names")
            }
            return result
        }
        throw SafFailure(5, "Document provider is unavailable: ${grant.uri.authority}")
    }

    private fun validName(name: String) {
        if (name.isEmpty() || name == "." || name == ".." || name.indexOf('/') >= 0 || name.indexOf('\u0000') >= 0) {
            throw SafFailure(22, "Document name cannot be represented in a stored Android path")
        }
    }

    private fun parts(grant: Grant, path: String): List<String> {
        if (path == grant.path) return emptyList()
        return path.substring(grant.path.length + 1).split('/').also { names -> names.forEach(::validName) }
    }

    private fun resolve(grant: Grant, path: String): Node? {
        var current = node(grant, DocumentsContract.buildDocumentUriUsingTree(grant.uri, grant.id))
            ?: throw SafFailure(5, "Authorized root is unavailable: ${grant.uri.authority}")
        for (name in parts(grant, path)) {
            current = children(grant, current).singleOrNull { it.name == name } ?: return null
        }
        return current
    }

    private fun required(grant: Grant, path: String) = resolve(grant, path)
        ?: throw SafFailure(2, "Document does not exist: $path")

    private fun parentPath(grant: Grant, path: String): String {
        parts(grant, path)
        return if (path == grant.path) PREFIX else path.substringBeforeLast('/')
    }

    private fun mime(name: String): String = MimeTypeMap.getSingleton()
        .getMimeTypeFromExtension(name.substringAfterLast('.', "").lowercase(Locale.ROOT))
        ?: "application/octet-stream"

    private fun create(grant: Grant, path: String, directory: Boolean, recursive: Boolean): Node {
        requireAccess(grant, write = true)
        var parent = required(grant, grant.path)
        val names = parts(grant, path)
        if (names.isEmpty()) {
            if (!directory || !parent.directory) throw SafFailure(21, "Authorized root is a directory")
            return parent
        }
        names.forEachIndexed { index, name ->
            val isDirectory = index < names.lastIndex || directory
            val before = children(grant, parent)
            val existing = before.singleOrNull { it.name == name }
            if (existing != null) {
                if (existing.directory != isDirectory) throw SafFailure(17, "A different document type already exists: $name")
                parent = existing
            } else {
                if (index < names.lastIndex && !recursive) throw SafFailure(2, "Parent directory does not exist: $name")
                if (parent.flags and Document.FLAG_DIR_SUPPORTS_CREATE == 0) throw SafFailure(95, "Provider cannot create documents here")
                val created = DocumentsContract.createDocument(io, parent.uri,
                    if (isDirectory) Document.MIME_TYPE_DIR else mime(name), name)
                    ?: throw SafFailure(5, "Provider did not create the document")
                val result = node(grant, created) ?: throw SafFailure(5, "Created document is unavailable")
                if (result.name != name || result.directory != isDirectory) {
                    // The contract returns the newly created URI. Never remove a
                    // URI already present before this particular create call.
                    if (result.id != parent.id && before.none { it.id == result.id }) {
                        try { DocumentsContract.deleteDocument(io, created) } catch (_: Exception) {}
                    }
                    throw SafFailure(17, "Provider changed the requested document name or type: $name")
                }
                parent = result
            }
        }
        return parent
    }

    @JvmStatic fun metadata(request: ByteArray): ByteArray {
        val response = try {
            val operation = JSONObject(String(request, Charsets.UTF_8))
            val path = validPath(operation.getString("path"))
            val op = operation.getString("op")
            val result = if (path == PREFIX) {
                when (op) {
                    "stat" -> JSONObject().put("type", "directory").put("size", 0).put("identity", PREFIX)
                    "parent" -> JSONObject().put("path", PREFIX)
                    "list" -> {
                        val roots = grants()
                        if (roots.groupBy { it.id }.any { it.value.size > 1 }) {
                            throw SafFailure(22, "Multiple document providers share a stored tree ID")
                        }
                        JSONObject().put("entries", JSONArray(roots.map { root ->
                            requireAccess(root)
                            required(root, root.path).json(root.path)
                        }))
                    }
                    else -> throw SafFailure(13, "Authorized directory roots cannot be changed")
                }
            } else {
                val root = grant(path)
                requireAccess(root)
                when (op) {
                    "stat" -> resolve(root, path)?.json(path)
                        ?: JSONObject().put("type", "notFound").put("size", -1)
                    "parent" -> JSONObject().put("path", parentPath(root, path))
                    "list" -> JSONObject().put("entries", JSONArray(children(root, required(root, path)).map {
                        it.json(path + "/" + it.name)
                    }))
                    "create" -> create(root, path, operation.getBoolean("directory"), operation.optBoolean("recursive")).json(path)
                    "delete" -> {
                        requireAccess(root, write = true)
                        if (path == root.path) throw SafFailure(13, "Authorized roots cannot be deleted")
                        val document = required(root, path)
                        if (document.directory != operation.getBoolean("directory")) throw SafFailure(21, "Document type does not match deletion")
                        if (document.directory && !operation.optBoolean("recursive") && children(root, document).isNotEmpty()) {
                            throw SafFailure(39, "Directory is not empty")
                        }
                        if (document.flags and Document.FLAG_SUPPORTS_DELETE == 0) throw SafFailure(95, "Provider cannot delete this document")
                        if (!DocumentsContract.deleteDocument(io, document.uri)) throw SafFailure(5, "Provider refused document deletion")
                        JSONObject()
                    }
                    "rename" -> {
                        requireAccess(root, write = true)
                        val target = validPath(operation.getString("target"))
                        val targetRoot = grant(target)
                        if (path == root.path || target == targetRoot.path) throw SafFailure(13, "Authorized roots cannot be renamed")
                        if (targetRoot.uri.authority != root.uri.authority || targetRoot.id != root.id ||
                            parentPath(root, path) != parentPath(targetRoot, target)) {
                            throw SafFailure(95, "Provider rename is supported only within the same directory")
                        }
                        val document = required(root, path)
                        if (document.directory != operation.getBoolean("directory")) throw SafFailure(21, "Document type does not match rename")
                        if (path == target) document.json(path) else {
                            if (resolve(root, target) != null) throw SafFailure(17, "Rename target already exists")
                            if (document.flags and Document.FLAG_SUPPORTS_RENAME == 0) throw SafFailure(95, "Provider cannot rename this document")
                            val name = parts(targetRoot, target).last()
                            val renamed = DocumentsContract.renameDocument(io, document.uri, name)
                                ?: throw SafFailure(5, "Provider refused document rename")
                            val resultNode = node(root, renamed) ?: throw SafFailure(5, "Renamed document is unavailable")
                            if (resultNode.name != name) throw SafFailure(17, "Provider changed the requested rename target")
                            resultNode.json(target)
                        }
                    }
                    else -> throw SafFailure(95, "Unsupported document operation: $op")
                }
            }
            JSONObject().put("ok", true).put("result", result)
        } catch (error: Exception) {
            val code = when (error) {
                is SafFailure -> error.code
                is SecurityException -> 13
                is FileNotFoundException -> 2
                is ErrnoException -> error.errno
                is IllegalArgumentException -> 22
                is UnsupportedOperationException -> 95
                else -> 5
            }
            JSONObject().put("ok", false).put("message", error.toString()).put("errno", code)
        }
        return response.toString().toByteArray(Charsets.UTF_8)
    }

    @JvmStatic fun openDescriptor(pathBytes: ByteArray, mode: Int): ParcelFileDescriptor {
        val path = validPath(String(pathBytes, Charsets.UTF_8))
        if (mode !in 0..4) throw SafFailure(22, "Invalid file mode")
        val root = grant(path)
        requireAccess(root, write = mode != 0, read = mode < 3)
        val document = if (mode == 0) required(root, path) else create(root, path, false, false)
        if (document.directory) throw SafFailure(21, "Cannot open a directory as a file")
        val descriptor = io.openFileDescriptor(document.uri, when (mode) {
            0 -> "r"
            1 -> "rwt"
            2 -> "rw"
            3 -> "wt"
            else -> "wa"
        }) ?: throw SafFailure(5, "Provider did not return a file descriptor")
        if (mode == 2 || mode == 4) {
            try {
                val fd = descriptor.fileDescriptor
                Os.fcntlInt(fd, OsConstants.F_SETFL, Os.fcntlInt(fd, OsConstants.F_GETFL, 0) or OsConstants.O_APPEND)
                Os.lseek(fd, 0, OsConstants.SEEK_END)
            } catch (error: Exception) {
                try { descriptor.close() } catch (_: Exception) {}
                throw error
            }
        }
        return descriptor
    }
}
