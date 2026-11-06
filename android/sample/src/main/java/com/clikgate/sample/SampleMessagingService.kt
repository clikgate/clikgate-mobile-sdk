package com.clikgate.sample

import com.clikgate.Clikgate
import com.clikgate.PushProvider
import com.google.firebase.messaging.FirebaseMessagingService
import com.google.firebase.messaging.RemoteMessage

/** How an app with its own FirebaseMessagingService forwards tokens and filters Clikgate pushes. */
class SampleMessagingService : FirebaseMessagingService() {

    override fun onNewToken(token: String) {
        Clikgate.setPushToken(token, PushProvider.FCM)
    }

    override fun onMessageReceived(message: RemoteMessage) {
        // Clikgate's silent uninstall check: nothing to show, nothing to do.
        if (Clikgate.isClikgateMessage(message.data)) return

        // ... the app's own message handling ...
    }
}
