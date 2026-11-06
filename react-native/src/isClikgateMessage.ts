/**
 * True for Clikgate's silent uninstall-check pushes: FCM `data.cg == "uc"`, APNs
 * `cg.t == "uc"` (as an object, or serialised as a JSON string by some messaging libraries).
 *
 * Pure TypeScript with no native-module access, so it works in headless JS tasks and
 * background message handlers (e.g. `messaging().setBackgroundMessageHandler`). Return early
 * without showing a notification when it is true.
 */
export function isClikgateMessage(data: unknown): boolean {
  if (typeof data !== 'object' || data === null) return false;
  const cg = (data as { cg?: unknown }).cg;
  if (cg === 'uc') return true;
  if (typeof cg === 'object' && cg !== null) {
    return (cg as { t?: unknown }).t === 'uc';
  }
  if (typeof cg === 'string' && cg.startsWith('{')) {
    try {
      const decoded: unknown = JSON.parse(cg);
      return (
        typeof decoded === 'object' &&
        decoded !== null &&
        !Array.isArray(decoded) &&
        (decoded as { t?: unknown }).t === 'uc'
      );
    } catch {
      return false;
    }
  }
  return false;
}
