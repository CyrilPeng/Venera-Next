package com.github.cyrilpeng.veneranext

fun main() {
    val subscriptions = VolumeKeySubscriptions()
    val events = mutableListOf<Pair<String, Int>>()
    fun dispatch(value: Int) = subscriptions.dispatch(value) { token, key -> events.add(token to key) }

    check(!dispatch(1))
    subscriptions.listen("old")
    check(dispatch(1))
    check(events.last() == "old" to 1)
    subscriptions.listen("current")
    subscriptions.listen("old") // Duplicate listen must not steal ownership.
    check(dispatch(2))
    check(events.last() == "current" to 2)
    subscriptions.cancel("old")
    subscriptions.cancel("old") // A repeated, late old cancel remains harmless.
    check(dispatch(1))
    check(events.last() == "current" to 1)
    subscriptions.cancel("unknown")
    subscriptions.cancel("current")
    check(!dispatch(2))
    subscriptions.listen("covered")
    subscriptions.listen("cover")
    subscriptions.cancel("cover")
    check(dispatch(2))
    check(events.last() == "covered" to 2)
    subscriptions.clear()
    check(!dispatch(1))
    check(runCatching { subscriptions.listen(" ") }.exceptionOrNull() is IllegalArgumentException)
    subscriptions.listen("new-engine")
    subscriptions.cancel("covered")
    check(dispatch(1))
    check(events.last() == "new-engine" to 1)
    println("Volume token ownership: 7 scenarios passed")
}
