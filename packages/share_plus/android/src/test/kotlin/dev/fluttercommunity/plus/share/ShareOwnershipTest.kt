package dev.fluttercommunity.plus.share

import java.io.File
import java.io.IOException
import java.nio.file.Files

/** Dependency-free JVM regressions for the production ownership primitives. */
object ShareOwnershipTest {
    @JvmStatic
    fun main(args: Array<String>) {
        var count = 0
        fun test(name: String, body: () -> Unit) {
            body()
            count++
            println("PASS $name")
        }

        test("later same-name share preserves the first delivered bytes") {
            withFiles { root, cache ->
                val source = File(root, "漫画.png").apply { writeText("first") }
                val first = ShareFileSession(cache)
                val firstCopy = first.copy(source)
                first.markDelivered()
                source.writeText("second")
                val second = ShareFileSession(cache)
                val secondCopy = second.copy(source)
                second.markDelivered()
                first.cleanUndelivered()
                second.cleanUndelivered()
                check(firstCopy != secondCopy)
                check(firstCopy.readText() == "first")
                check(secondCopy.readText() == "second")
                check(firstCopy.name == source.name && secondCopy.name == source.name)
            }
        }

        test("same basenames in one request remain independent") {
            withFiles { root, cache ->
                val a = File(root, "a/same.png").apply { parentFile!!.mkdirs(); writeText("a") }
                val b = File(root, "b/same.png").apply { parentFile!!.mkdirs(); writeText("b") }
                val session = ShareFileSession(cache)
                val ac = session.copy(a)
                val bc = session.copy(b)
                session.markDelivered()
                check(ac != bc && ac.readText() == "a" && bc.readText() == "b")
            }
        }

        test("partial copy failure cleans only this request and preserves source") {
            withFiles { root, cache ->
                val source = File(root, "cover.png").apply { writeText("source") }
                val first = ShareFileSession(cache)
                val retained = first.copy(source)
                first.markDelivered()
                val failing = ShareFileSession(cache)
                val partial = failing.copy(source)
                val error = failure { failing.copy(File(root, "missing")) }
                val rethrown = failure { preserveShareFailure(error, { failing.cleanUndelivered() }) }
                check(error === rethrown)
                check(!partial.exists())
                check(retained.readText() == "source" && source.readText() == "source")
                check(cache.listFiles()!!.size == 1)
            }
        }

        test("legacy cache files and another undelivered owner are not swept") {
            withFiles { root, cache ->
                cache.mkdirs()
                val old = File(cache, "old.png").apply { writeText("old") }
                val source = File(root, "source.png").apply { writeText("source") }
                val a = ShareFileSession(cache)
                val ac = a.copy(source)
                val b = ShareFileSession(cache)
                b.copy(source)
                b.cleanUndelivered()
                check(ac.readText() == "source" && old.readText() == "old")
                a.cleanUndelivered()
                check(!ac.exists() && old.readText() == "old")
            }
        }

        test("resharing a retained copy creates a new owner") {
            withFiles { root, cache ->
                val first = ShareFileSession(cache)
                val retained = first.copy(File(root, "file").apply { writeText("data") })
                first.markDelivered()
                val second = ShareFileSession(cache)
                val copy = second.copy(retained)
                second.cleanUndelivered()
                check(!copy.exists() && retained.readText() == "data")
            }
        }

        test("invalid cache creation fails without modifying the existing file") {
            withFiles { _, cache ->
                cache.writeText("not a directory")
                check(failure { ShareFileSession(cache) } is IOException)
                check(cache.readText() == "not a directory")
            }
        }

        test("operation failure retains every cleanup error and original stack") {
            val operation = IOException("launch")
            val originalStack = operation.stackTrace.toList()
            val revoke = IOException("revoke")
            val remove = IOException("remove")
            var lastAttempted = false
            val result = failure {
                preserveShareFailure(operation, { throw revoke }, { throw remove }, { lastAttempted = true })
            }
            check(result === operation && result.stackTrace.toList() == originalStack)
            check(result.suppressed.toList() == listOf(revoke, remove) && lastAttempted)
            check(result.stackTraceToString().contains("Suppressed: java.io.IOException: remove"))
        }

        test("concurrent calls cannot replace an accepted callback") {
            val requests = ShareRequestCoordinator()
            val owner = Any()
            val results = mutableListOf<String>()
            val first = requests.begin(owner) { results.add(it) }!!
            check(requests.begin(owner) { error("replaced") } == null)
            check(requests.begin(Any()) { error("other engine replaced") } == null)
            requests.choose(first.token, "reader/Target")
            check(requests.complete(owner, first.activityCode))
            check(results == listOf("reader/Target"))
            check(!requests.complete(owner, first.activityCode))
        }

        test("late chooser broadcasts and activity results cannot complete the next share") {
            val requests = ShareRequestCoordinator()
            val owner = Any()
            val results = mutableListOf<String>()
            val first = requests.begin(owner) { results.add(it) }!!
            requests.unavailable(owner)
            val next = requests.begin(owner) { results.add(it) }!!
            check(first.token != next.token && first.activityCode != next.activityCode)
            requests.choose(first.token, "stale/Target")
            check(!requests.complete(owner, first.activityCode))
            check(requests.complete(owner, next.activityCode))
            check(results == listOf(ShareRequestCoordinator.RESULT_UNAVAILABLE, ""))
        }

        test("another owner cannot clear or receive an active result") {
            val requests = ShareRequestCoordinator()
            val owner = Any()
            val stranger = Any()
            var result: String? = null
            val request = requests.begin(owner) { result = it }!!
            requests.clear(stranger)
            requests.unavailable(stranger)
            check(!requests.complete(stranger, request.activityCode))
            check(requests.current(owner) === request && result == null)
            requests.choose(request.token, "chosen")
            requests.complete(owner, request.activityCode)
            check(result == "chosen")
        }

        test("failed launch releases admission without completing its callback") {
            val requests = ShareRequestCoordinator()
            val owner = Any()
            val first = requests.begin(owner) { error("failed launch must reply through error") }!!
            requests.clear(owner)
            check(requests.begin(owner) {} != null)
            check(!requests.complete(owner, first.activityCode))
        }

        test("callback can start the next request without losing its ownership") {
            val requests = ShareRequestCoordinator()
            val owner = Any()
            var next: ShareRequestCoordinator.Request? = null
            val first = requests.begin(owner) { next = requests.begin(owner) {} }!!
            requests.complete(owner, first.activityCode)
            check(next != null && requests.current(owner) === next)
        }

        test("activity codes never wrap onto an abandoned request") {
            val requests = ShareRequestCoordinator()
            val owner = Any()
            val codes = mutableSetOf<Int>()
            repeat(0x10000 - 0x5873) {
                val request = requests.begin(owner) {}!!
                check(request.activityCode in 0..0xffff && codes.add(request.activityCode))
                requests.clear(owner)
            }
            check(failure { requests.begin(owner) {} } is IllegalStateException)
        }
        println("$count Android share ownership JVM tests passed")
    }

    private fun failure(body: () -> Unit): Throwable {
        try {
            body()
        } catch (error: Throwable) {
            return error
        }
        error("Expected failure")
    }

    private fun withFiles(body: (File, File) -> Unit) {
        val root = Files.createTempDirectory("share-plus-ownership-").toFile()
        try {
            body(root, File(root, "share_plus"))
        } finally {
            check(root.deleteRecursively())
        }
    }
}
