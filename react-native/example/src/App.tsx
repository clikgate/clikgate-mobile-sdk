import { useCallback, useEffect, useState } from 'react';
import {
  BackHandler,
  StatusBar,
  StyleSheet,
  Text,
  TouchableOpacity,
  View,
} from 'react-native';
import { SafeAreaProvider, SafeAreaView } from 'react-native-safe-area-context';

import { Clikgate, type ClikgateDeepLink } from '@clikgate/react-native';

import {
  ApplyCodeScreen,
  HomeScreen,
  InviteScreen,
  LeaderboardScreen,
  ProductScreen,
  PromoCodeScreen,
  ReferralWelcomeScreen,
} from './screens';

export type Route =
  | { name: 'home' }
  | { name: 'invite' }
  | { name: 'applyCode' }
  | { name: 'leaderboard' }
  | { name: 'promoCode' }
  | { name: 'product'; link: ClikgateDeepLink }
  | { name: 'welcome'; link: ClikgateDeepLink };

const titles: Record<Route['name'], string> = {
  home: 'Clikgate example',
  invite: 'Invite friends',
  applyCode: 'Enter a referral code',
  leaderboard: 'Weekly leaderboard',
  promoCode: 'Promo code',
  product: 'Product',
  welcome: 'Welcome',
};

/** Maps a deep link to a screen (product links and referral links). */
export function routeFor(link: ClikgateDeepLink): Route | null {
  const path = link.path ?? '/';
  if (path.startsWith('/products/')) return { name: 'product', link };
  if (link.referral != null || path === '/welcome')
    return { name: 'welcome', link };
  return null;
}

export default function App() {
  const [stack, setStack] = useState<Route[]>([{ name: 'home' }]);
  const [notice, setNotice] = useState<string | null>(null);
  const route = stack[stack.length - 1] ?? { name: 'home' };

  const push = useCallback((r: Route) => setStack((s) => [...s, r]), []);
  const pop = useCallback(
    () => setStack((s) => (s.length > 1 ? s.slice(0, -1) : s)),
    []
  );

  useEffect(() => {
    // Deferred (after install) and direct deep links. Links that arrived before this
    // subscription (e.g. the link that cold-started the app) are replayed to it.
    return Clikgate.onDeepLink((link) => {
      const target = routeFor(link);
      if (target) push(target);
      else
        setNotice(
          `Deep link: ${link.path ?? '/'} ${JSON.stringify(link.data)}`
        );
    });
  }, [push]);

  useEffect(() => {
    const sub = BackHandler.addEventListener('hardwareBackPress', () => {
      if (stack.length <= 1) return false;
      pop();
      return true;
    });
    return () => sub.remove();
  }, [stack.length, pop]);

  return (
    <SafeAreaProvider>
      <StatusBar barStyle="dark-content" />
      <SafeAreaView style={styles.root} edges={['top', 'bottom']}>
        <View style={styles.header}>
          {stack.length > 1 ? (
            <TouchableOpacity
              onPress={pop}
              accessibilityRole="button"
              testID="back"
            >
              <Text style={styles.back}>‹ Back</Text>
            </TouchableOpacity>
          ) : null}
          <Text style={styles.title}>{titles[route.name]}</Text>
        </View>
        {notice ? (
          <TouchableOpacity
            onPress={() => setNotice(null)}
            style={styles.notice}
          >
            <Text>{notice}</Text>
          </TouchableOpacity>
        ) : null}
        <View style={styles.body}>
          {route.name === 'home' && <HomeScreen navigate={push} />}
          {route.name === 'invite' && <InviteScreen />}
          {route.name === 'applyCode' && <ApplyCodeScreen />}
          {route.name === 'leaderboard' && <LeaderboardScreen />}
          {route.name === 'promoCode' && <PromoCodeScreen />}
          {route.name === 'product' && <ProductScreen link={route.link} />}
          {route.name === 'welcome' && (
            <ReferralWelcomeScreen link={route.link} />
          )}
        </View>
      </SafeAreaView>
    </SafeAreaProvider>
  );
}

const styles = StyleSheet.create({
  root: { flex: 1, backgroundColor: '#f6f6fb' },
  header: { flexDirection: 'row', alignItems: 'center', padding: 16, gap: 12 },
  back: { fontSize: 17, color: '#3f51b5' },
  title: { fontSize: 20, fontWeight: '600' },
  notice: {
    marginHorizontal: 16,
    padding: 12,
    borderRadius: 8,
    backgroundColor: '#e8eaf6',
  },
  body: { flex: 1 },
});
