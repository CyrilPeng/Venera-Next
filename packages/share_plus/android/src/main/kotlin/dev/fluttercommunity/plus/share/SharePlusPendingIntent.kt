package dev.fluttercommunity.plus.share

import android.content.*
import android.os.Build
import androidx.annotation.RequiresApi

/**
 * This helper class allows us to use FLAG_MUTABLE on the PendingIntent used in the Share class,
 * as it allows us to make the underlying Intent explicit, therefore avoiding any risks an implicit
 * mutable Intent may carry.
 *
 * When the PendingIntent is sent, the system will instantiate this class and call `onReceive` on it.
 */
internal class SharePlusPendingIntent: BroadcastReceiver() {
    companion object {
        // The receiver is system-created. Keep only the active request here;
        // detach/completion clears it, and stale broadcasts cannot change it.
        internal val requests = ShareRequestCoordinator()
        internal const val REQUEST_TOKEN = "dev.fluttercommunity.plus.share.REQUEST_TOKEN"
    }

    /**
     * Handler called after an action was chosen. Called only on success.
     */
    @RequiresApi(Build.VERSION_CODES.LOLLIPOP_MR1)
    override fun onReceive(context: Context, intent: Intent) {
        // Extract chosen ComponentName
        val chosenComponent = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            // Only available from API level 33 onwards
            intent.getParcelableExtra(Intent.EXTRA_CHOSEN_COMPONENT, ComponentName::class.java)
        } else {
            // Deprecated in API level 33
            @Suppress("DEPRECATION")
            intent.getParcelableExtra(Intent.EXTRA_CHOSEN_COMPONENT)
        }

        // Unambiguously identify the chosen action
        if (chosenComponent != null) {
            val token = intent.getStringExtra(REQUEST_TOKEN) ?: return
            requests.choose(token, chosenComponent.flattenToString())
        }
    }
}
