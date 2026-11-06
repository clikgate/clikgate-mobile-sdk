# Clikgate iOS SDK

Deep links, deferred deep links, install attribution, goals, referrals (referee side) and uninstall tracking for
iOS 13+, in Swift, with no third-party dependencies.

## Install

**Swift Package Manager:** add `https://github.com/clikgate/clikgate-ios-sdk` and link the `Clikgate` product.
Link `ClikgateEngage` too only if you use the optional Engage add-on.

**CocoaPods:** `pod 'Clikgate', '~> 1.5'` (add `pod 'Clikgate/Engage'` for the Engage add-on).

## Use

```swift
import Clikgate

Clikgate.configure(sdkKey: "cg_sdk_live_…", options: ClikgateOptions(linkDomains: ["go.yourbrand.com"]))

// One method for every goal. On a Payment goal, send your payment provider and its reference:
Clikgate.shared.goal("purchase", reference: "T123456", provider: .paystack) { result in
    // result.status: .counted, .waiting (a Payment goal waits for its confirmation) or .refused
}
```

The full guide is at https://clikgate.com/docs/sdks/ios. Licence: Apache 2.0 (`LICENSE`).
