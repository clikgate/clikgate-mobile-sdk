/**
 * Example configuration from environment variables, inlined by Metro at bundle time
 * (babel-plugin-transform-inline-environment-variables, see babel.config.js):
 *
 *   CLIKGATE_SDK_KEY=cg_sdk_... \
 *   CLIKGATE_API_BASE_URL=http://10.0.2.2:8000 \
 *   CLIKGATE_LINK_DOMAIN=inv.myapp.com \
 *   CLIKGATE_PROGRAM_ID=rpg_... \
 *   CLIKGATE_LEADERBOARD_ID=lb_... \
 *   npx react-native start --reset-cache
 *
 * The link domain must also be set natively: Android `-Pclikgate.linkDomain=...` (intent
 * filter) and iOS `ios/ClikgateExample/Clikgate.xcconfig` (associated domains).
 */
const env = (value: string | undefined, fallback: string) =>
  value != null && value.length > 0 ? value : fallback;

export const ExampleConfig = {
  sdkKey: env(process.env.CLIKGATE_SDK_KEY, 'cg_sdk_example'),
  apiBaseUrl: env(process.env.CLIKGATE_API_BASE_URL, ''),
  linkDomain: env(process.env.CLIKGATE_LINK_DOMAIN, 'inv.example.com'),
  programId: env(process.env.CLIKGATE_PROGRAM_ID, 'rpg_example'),
  leaderboardId: env(process.env.CLIKGATE_LEADERBOARD_ID, 'lb_example'),
};
