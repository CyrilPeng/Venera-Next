package com.github.cyrilpeng.veneranext

import java.io.DataInputStream
import java.io.DataOutputStream
import java.io.File
import java.io.IOException
import java.util.UUID

/** Receipt-bound copies; never infer ownership from a filename/cache prefix. */
class SelectedFileStorage(private val root: File) {
    data class Copy(val file: File, val token: String)
    class CreationFailure(val copy: Copy, cause: Exception) : IOException("Cannot create selection receipt", cause)
    private val receiptName = ".selection-owner"
    private val incompleteCopies = mutableMapOf<String, Copy>()

    @Synchronized
    fun create(name: String): Copy {
        require(name.isNotEmpty() && name != "." && name != ".." &&
            name != receiptName && !name.contains('/') && !name.contains('\\') &&
            !name.contains('\u0000') && name.toByteArray(Charsets.UTF_8).size <= 255) {
            "Invalid selected document name"
        }
        check(root.isDirectory || root.mkdirs()) { "Cannot create selection storage" }
        val token = UUID.randomUUID().toString()
        val directory = File(root, token)
        check(directory.mkdir()) { "Cannot create selection directory" }
        val receipt = File(directory, receiptName)
        val copy = Copy(File(directory, name), token)
        try {
            DataOutputStream(receipt.outputStream()).use {
                it.writeUTF(token)
                it.writeUTF(name)
            }
        } catch (error: Exception) {
            incompleteCopies[token] = copy
            throw CreationFailure(copy, error)
        }
        return copy
    }

    @Synchronized
    fun release(path: String, token: String) {
        require(UUID.fromString(token).toString() == token) { "Invalid selection token" }
        val directory = File(root, token).absoluteFile
        val file = File(path).absoluteFile
        require(file.parentFile == directory && file.name != receiptName &&
            directory.canonicalFile == File(root.canonicalFile, token) &&
            file.canonicalFile == File(directory.canonicalFile, file.name)) { "Invalid selected copy path" }
        if (!directory.exists()) {
            incompleteCopies.remove(token)
            return
        }
        val receipt = File(directory, receiptName)
        // The receipt is deleted last. A leftover empty directory is a safe
        // retry of a failed final directory removal; unknown entries stay.
        if (!receipt.exists()) {
            require(directory.listFiles()?.isEmpty() == true) { "Missing selection receipt" }
            check(directory.delete()) { "Cannot remove empty selection directory" }
            incompleteCopies.remove(token)
            return
        }
        require(receipt.canonicalFile == File(directory.canonicalFile, receiptName)) { "Invalid selection receipt" }
        if (incompleteCopies[token]?.file?.absoluteFile != file) {
            DataInputStream(receipt.inputStream()).use {
                require(it.readUTF() == token && it.readUTF() == file.name && it.read() == -1) { "Selection receipt mismatch" }
            }
        }
        require(directory.listFiles()?.all { it.name == file.name || it.name == receiptName } == true) { "Unknown selection contents" }
        require(!file.exists() || file.isFile) { "Selected copy is not a file" }
        if (file.exists()) check(file.delete()) { "Cannot delete selected copy" }
        check(receipt.delete()) { "Cannot delete selection receipt" }
        check(directory.delete()) { "Cannot delete selection directory" }
        incompleteCopies.remove(token)
    }
}
