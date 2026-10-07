package com.github.cyrilpeng.veneranext

/** Activity/engine-owned tokens. All calls run on the Android main thread. */
internal class VolumeKeySubscriptions {
    private val tokens = linkedSetOf<String>()

    fun listen(token: String) {
        require(token.isNotBlank()) { "A volume subscription token is required" }
        tokens.add(token)
    }

    fun cancel(token: String) {
        tokens.remove(token)
    }

    fun dispatch(value: Int, send: (String, Int) -> Unit): Boolean {
        val token = tokens.lastOrNull() ?: return false
        send(token, value)
        return true
    }

    fun clear() = tokens.clear()
}
