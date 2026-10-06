import com.github.cyrilpeng.veneranext.SelectedFileStorage
import java.io.File
import java.nio.file.Files

private fun rejects(action: () -> Unit) {
    var rejected = false
    try { action() } catch (_: Exception) { rejected = true }
    check(rejected) { "Unsafe release was accepted" }
}

fun main() {
    val root = Files.createTempDirectory("selected-file-storage-").toFile()
    var passed = 0
    fun scenario(name: String, action: (File, SelectedFileStorage) -> Unit) {
        val directory = File(root, "case-${passed + 1}")
        action(directory, SelectedFileStorage(directory))
        passed++
        println("PASS: $name")
    }
    try {
        scenario("same name keeps independent owners") { _, storage ->
            val first = storage.create("book.pdf")
            val second = storage.create("book.pdf")
            first.file.writeText("one")
            second.file.writeText("two")
            check(first.file != second.file)
            storage.release(first.file.absolutePath, first.token)
            check(second.file.readText() == "two")
            storage.release(second.file.absolutePath, second.token)
            storage.release(second.file.absolutePath, second.token)
        }
        scenario("wrong token and external path preserve files") { directory, storage ->
            val copy = storage.create("book.pdf")
            copy.file.writeText("kept")
            val borrowed = File(directory, "borrowed.pdf").apply { writeText("original") }
            rejects { storage.release(copy.file.absolutePath, "bad-token") }
            rejects { storage.release(borrowed.absolutePath, copy.token) }
            check(copy.file.readText() == "kept" && borrowed.readText() == "original")
            storage.release(copy.file.absolutePath, copy.token)
        }
        scenario("unknown sibling blocks deletion and permits explicit retry") { _, storage ->
            val copy = storage.create("book.pdf")
            copy.file.writeText("kept")
            val unknown = File(copy.file.parentFile, "unknown").apply { writeText("kept") }
            rejects { storage.release(copy.file.absolutePath, copy.token) }
            check(copy.file.exists() && unknown.exists())
            check(unknown.delete())
            storage.release(copy.file.absolutePath, copy.token)
        }
        scenario("missing and corrupt receipts cannot authorize deletion") { _, storage ->
            val copy = storage.create("book.pdf")
            copy.file.writeText("kept")
            val receipt = File(copy.file.parentFile, ".selection-owner")
            val bytes = receipt.readBytes()
            check(receipt.delete())
            rejects { storage.release(copy.file.absolutePath, copy.token) }
            receipt.writeText("corrupt")
            rejects { storage.release(copy.file.absolutePath, copy.token) }
            check(copy.file.readText() == "kept")
            receipt.writeBytes(bytes)
            storage.release(copy.file.absolutePath, copy.token)
        }
        scenario("release resumes after file or receipt removal") { _, storage ->
            val first = storage.create("one.pdf")
            first.file.writeText("one")
            check(first.file.delete())
            storage.release(first.file.absolutePath, first.token)
            val second = storage.create("two.pdf")
            check(File(second.file.parentFile, ".selection-owner").delete())
            storage.release(second.file.absolutePath, second.token)
            check(!second.file.parentFile.exists())
        }
        scenario("invalid names never create owned directories") { directory, storage ->
            for (name in listOf("", ".", "..", ".selection-owner", "../outside", "a\\b", "bad\u0000", "x".repeat(256))) {
                rejects { storage.create(name) }
            }
            check(!directory.exists())
        }
        scenario("symlink file and directory cannot escape ownership") { directory, storage ->
            val copy = storage.create("book.pdf")
            val outside = Files.createTempDirectory("selected-file-outside-").toFile()
            try {
                val target = File(outside, "book.pdf").apply { writeText("outside") }
                Files.createSymbolicLink(copy.file.toPath(), target.toPath())
                rejects { storage.release(copy.file.absolutePath, copy.token) }
                Files.delete(copy.file.toPath())
                storage.release(copy.file.absolutePath, copy.token)
                Files.createSymbolicLink(File(directory, copy.token).toPath(), outside.toPath())
                rejects { storage.release(copy.file.absolutePath, copy.token) }
                check(target.readText() == "outside")
                Files.delete(File(directory, copy.token).toPath())
            } finally {
                outside.deleteRecursively()
            }
        }
        println("$passed native selected-file scenarios passed")
    } finally {
        root.deleteRecursively()
    }
}
