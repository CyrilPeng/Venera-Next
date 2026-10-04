package dev.fluttercommunity.plus.share

import java.util.UUID

/** Serializes native chooser ownership and rejects late results by request identity. */
internal class ShareRequestCoordinator {
    internal class Request(
        val owner: Any,
        val token: String,
        val activityCode: Int,
        val callback: (String) -> Unit,
        var chosenComponent: String = "",
    )

    private var active: Request? = null
    private var nextActivityCode = 0x5873

    @Synchronized
    fun begin(owner: Any, callback: (String) -> Unit): Request? {
        if (active != null) return null
        // Activity result codes must fit the lower 16 bits. Do not reuse a code
        // in this process: an abandoned Activity may still return much later.
        check(nextActivityCode <= 0xffff) { "Share activity request codes exhausted" }
        return Request(owner, UUID.randomUUID().toString(), nextActivityCode++, callback)
            .also { active = it }
    }

    @Synchronized
    fun current(owner: Any): Request? = active?.takeIf { it.owner === owner }

    @Synchronized
    fun choose(token: String, component: String) {
        active?.takeIf { it.token == token }?.chosenComponent = component
    }

    fun complete(owner: Any, activityCode: Int): Boolean {
        val request = synchronized(this) {
            val pending = active
            if (pending == null || pending.owner !== owner || pending.activityCode != activityCode) {
                return false
            }
            active = null
            pending
        }
        request.callback(request.chosenComponent)
        return true
    }

    fun unavailable(owner: Any) {
        take(owner)?.callback?.invoke(RESULT_UNAVAILABLE)
    }

    fun clear(owner: Any) {
        take(owner)
    }

    @Synchronized
    private fun take(owner: Any): Request? {
        val pending = active?.takeIf { it.owner === owner } ?: return null
        active = null
        return pending
    }

    companion object {
        const val RESULT_UNAVAILABLE = "dev.fluttercommunity.plus/share/unavailable"
    }
}
