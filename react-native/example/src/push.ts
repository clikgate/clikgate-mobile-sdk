import { Platform } from 'react-native';

import {
  Clikgate,
  isClikgateMessage,
  type PushProvider,
} from '@clikgate/react-native';

/**
 * Push-token registration hook for uninstall tracking. The example builds without Firebase,
 * so it only shows where the pieces go:
 *
 * - iOS (APNs, no Firebase): AppDelegate.swift forwards the device token natively with
 *   `ClikgateRN.setPushToken(deviceToken:)` and silent checks with
 *   `ClikgateRN.handleRemoteNotification(_:completionHandler:)`. Nothing to do in JS.
 * - FCM (Android, or iOS with Firebase): install `@react-native-firebase/app` +
 *   `@react-native-firebase/messaging`, add the Firebase config files, then call
 *   `registerPushToken(() => messaging().getToken(), 'fcm', (cb) => messaging().onTokenRefresh(cb))`
 *   and filter messages with `isClikgateMessage` (see `onMessage` below).
 */
export async function registerPushToken(
  getToken: () => Promise<string | null>,
  provider: PushProvider,
  onTokenRefresh?: (listener: (token: string) => void) => () => void
): Promise<() => void> {
  await Clikgate.setPushToken(await getToken(), { provider });
  const unsubscribe = onTokenRefresh?.((token) => {
    Clikgate.setPushToken(token, { provider }).catch(() => {});
  });
  return unsubscribe ?? (() => {});
}

/**
 * Use in every message handler, including the background / headless one:
 *
 *   messaging().setBackgroundMessageHandler(async (m) => { if (onMessage(m.data)) return; ... });
 *
 * `isClikgateMessage` is pure TypeScript, so it works in headless JS.
 */
export function onMessage(data: unknown): boolean {
  return isClikgateMessage(data);
}

/** Status line for the home screen. */
export function pushStatus(): string {
  return Platform.OS === 'ios'
    ? 'APNs token forwarded natively (ClikgateRN in AppDelegate)'
    : 'FCM not configured in this example (see src/push.ts)';
}
