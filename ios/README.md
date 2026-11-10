# Clikgate iOS SDK

Deep links, deferred deep links, install attribution, goals, identifyUser, referrals (referee side) and uninstall tracking for
iOS 13+, in Swift, with no third-party dependencies. Build with Xcode 26 or newer.

## Install

**Swift Package Manager:** add `https://github.com/clikgate/clikgate-ios-sdk` and link the `Clikgate` product.
Link `ClikgateEngage` too only if you use the optional Engage add-on.

**CocoaPods:** `pod 'Clikgate', '~> 2.0'` (add `pod 'Clikgate/Engage'` for the Engage add-on).

## Use

```swift
import Clikgate

Clikgate.configure(sdkKey: "cg_sdk_live_…", options: ClikgateOptions(linkDomains: ["go.yourbrand.com"]))

// One method for every goal. On a Payment goal, send your payment provider and its reference:
Clikgate.shared.goal("purchase", reference: "T123456", provider: .paystack) { result in
    // result.status: .counted, .waiting (a Payment goal waits for its confirmation), .received (stored, not
    // ticked as a goal in the dashboard yet) or .refused
}

// Identify signed-in users: Path A with a token from your server, or Path B with the installation ID.
Clikgate.shared.identifyUser(customerId: user.id, identityToken: me.clikgateToken)
let installationId: String? = try await Clikgate.shared.installationId()   // send it with your sign-in request
Clikgate.shared.identifyUser(customerId: nil)                              // sign-out
```

Path A (the default): your server makes an identity token with the server SDK's `createIdentityToken` (secret
`CLIKGATE_IDENTITY_SECRET`, server only) and returns it in the sign-in and "current user" responses; the app passes
it to `identifyUser`. Path B (no token): the app sends its installation ID with the sign-in request and your server
calls `identifyUser({appId, installationId, customerId, label?})`. The installation ID is `null` when tracking is off
(opt-out, consent denied or not given yet where required, deep-link-only mode). The customer ID is your own user ID,
never an email or phone number. Guide: https://clikgate.com/docs/identify-users

The full guide is at https://clikgate.com/docs/sdks/ios. Licence: Apache 2.0 (`LICENSE`).
