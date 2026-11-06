import { AppRegistry } from 'react-native';
import { Clikgate } from '@clikgate/react-native';

import App from './src/App';
import { ExampleConfig } from './src/config';
import { name as appName } from './app.json';

// Configure as early as possible. Deep links received before the first
// Clikgate.onDeepLink listener are buffered and replayed to it.
// Change 03: client-side Firebase / GA4 forwarding. The native SDK finds Firebase Analytics at
// runtime (e.g. installed by @react-native-firebase/analytics); without it this is a no-op. It is
// called before configure so it applies from the first launch.
Clikgate.enableFirebaseForwarding({ mirrorEvents: true }).catch(() => {});

Clikgate.configure({
  sdkKey: ExampleConfig.sdkKey,
  linkDomains: [ExampleConfig.linkDomain],
  apiBaseUrl: ExampleConfig.apiBaseUrl || null,
  logLevel: 'debug',
}).catch((e) => console.warn('Clikgate.configure failed', e));

AppRegistry.registerComponent(appName, () => App);
