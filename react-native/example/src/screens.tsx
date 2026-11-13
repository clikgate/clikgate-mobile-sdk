import { useCallback, useEffect, useState, type ReactNode } from 'react';
import {
  ActivityIndicator,
  ScrollView,
  StyleSheet,
  Text,
  TextInput,
  TouchableOpacity,
  View,
} from 'react-native';

// Invite, stats, leaderboard and promo-code screens use the Engage features (ClikgateEngage, apps
// without a backend). With a backend, fetch these from your server instead (docs/engage.md).
import {
  Clikgate,
  ClikgateEngage,
  ClikgateError,
  ClikgateProvider,
  ShareApp,
  type ClikgateAttribution,
  type ClikgateDeepLink,
  type LeaderboardEntry,
  type LeaderboardPage,
  type MyRank,
  type ReferralLink,
  type ReferralStats,
  type ReferredBy,
} from '@clikgate/react-native';

import type { Route } from './App';
import { ExampleConfig } from './config';
import { pushStatus } from './push';

/** One Engage instance for the app (it holds the 60 s read cache). */
const engage = new ClikgateEngage();

export const describeError = (e: unknown) =>
  e instanceof ClikgateError ? `${e.code}: ${e.message}` : String(e);

// ------------------------------------------------------------------ small UI kit

function Card({ children, tone }: { children: ReactNode; tone?: 'success' }) {
  return (
    <View style={[styles.card, tone === 'success' && styles.cardSuccess]}>
      {children}
    </View>
  );
}

function Button({
  title,
  onPress,
  primary,
  disabled,
  testID,
}: {
  title: string;
  onPress: () => void;
  primary?: boolean;
  disabled?: boolean;
  testID?: string;
}) {
  return (
    <TouchableOpacity
      accessibilityRole="button"
      testID={testID}
      disabled={disabled}
      onPress={onPress}
      style={[
        styles.button,
        primary && styles.buttonPrimary,
        disabled && styles.buttonDisabled,
      ]}
    >
      <Text style={[styles.buttonText, primary && styles.buttonTextPrimary]}>
        {title}
      </Text>
    </TouchableOpacity>
  );
}

function Field(props: {
  label: string;
  value: string;
  onChangeText: (v: string) => void;
  placeholder?: string;
  autoCapitalize?: 'none' | 'characters';
}) {
  return (
    <View style={styles.field}>
      <Text style={styles.label}>{props.label}</Text>
      <TextInput
        style={styles.input}
        value={props.value}
        onChangeText={props.onChangeText}
        placeholder={props.placeholder}
        autoCapitalize={props.autoCapitalize ?? 'none'}
        autoCorrect={false}
      />
    </View>
  );
}

// ------------------------------------------------------------------ home

export function HomeScreen({ navigate }: { navigate: (r: Route) => void }) {
  const [attribution, setAttribution] = useState<ClikgateAttribution | null>(
    null
  );
  const [referredBy, setReferredBy] = useState<ReferredBy | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [message, setMessage] = useState<string | null>(null);

  const refresh = useCallback(async () => {
    try {
      setAttribution(await Clikgate.getAttribution());
      setReferredBy(await Clikgate.referrals.referredBy());
      setError(null);
    } catch (e) {
      setError(describeError(e));
    }
  }, []);

  useEffect(() => {
    refresh();
  }, [refresh]);

  // Identity Path B: send this to your own server with the sign-in request; your server calls identifyUser.
  const showInstallationId = async () => {
    try {
      const id = await Clikgate.getInstallationId();
      setMessage(
        id == null
          ? 'Tracking is off: no installation ID'
          : `Installation ${id.slice(0, 8)}…`
      );
    } catch (e) {
      setMessage(describeError(e));
    }
  };

  // Goals: use your own reference only, never customer data.
  const recordGoal = async () => {
    const r = await Clikgate.goal('account_opened', {
      value: '2000000',
      currency: 'NGN',
      reference: `APP-${Date.now()}`,
      isFirst: true,
    });
    setMessage(
      `account_opened: ${r.status}${r.reason ? ` (${r.reason})` : ''}`
    );
  };

  // A Payment goal: pass the provider and the reference your checkout returned. It waits until
  // your payment provider or server confirms it, with the real amount.
  const recordPaymentGoal = async () => {
    const r = await Clikgate.goal('purchase', {
      reference: `T${Date.now()}`,
      provider: ClikgateProvider.Paystack,
    });
    setMessage(`purchase: ${r.status}${r.reason ? ` (${r.reason})` : ''}`);
  };

  // Change 03: consent (your consent banner would call these) and sales metadata.
  const [consent, setConsentInfo] = useState<string>('…');
  const showConsent = useCallback(async () => {
    const c = await Clikgate.getConsent();
    setConsentInfo(
      `analytics ${c.analytics}, attribution ${c.attribution}, ad data ${c.adUserData}` +
        ` (required: ${c.required ?? 'unknown'}${c.region ? `, region ${c.region}` : ''})`
    );
  }, []);
  useEffect(() => {
    showConsent().catch(() => {});
  }, [showConsent]);
  const setAll = async (state: 'granted' | 'denied') => {
    await Clikgate.setConsent({
      analytics: state,
      attribution: state,
      adUserData: state,
      adPersonalization: state,
    });
    await showConsent();
  };
  const showMetadata = async () => {
    // Put these in Paystack `metadata` / Flutterwave `meta` at checkout.
    setMessage(
      `attributionMetadata: ${JSON.stringify(await Clikgate.attributionMetadata())}`
    );
  };

  const referral = referredBy?.referral;
  return (
    <ScrollView contentContainerStyle={styles.content}>
      {referredBy?.referred && referral ? (
        <Card tone="success">
          <Text style={styles.cardTitle} testID="referred-by-banner">
            Invited by {referral.referrerDisplayName ?? 'a friend'}
          </Text>
          <Text>Referral status: {referral.status}</Text>
        </Card>
      ) : null}
      <Card>
        <Text style={styles.cardTitle}>
          Attribution: {attribution?.status ?? '…'}
        </Text>
        {attribution?.matchType ? (
          <Text>via {attribution.matchType}</Text>
        ) : null}
        {attribution?.installId ? (
          <Text>install {attribution.installId}</Text>
        ) : null}
        {error ? <Text style={styles.error}>{error}</Text> : null}
      </Card>
      <Card>
        <Text style={styles.cardTitle}>Consent</Text>
        <Text testID="consent-state">{consent}</Text>
      </Card>
      <Button title="Consent: accept all" onPress={() => setAll('granted')} />
      <Button
        title="Consent: necessary only"
        onPress={() => setAll('denied')}
      />
      <Button
        title="Pretend the user is in the EEA"
        onPress={async () => {
          await Clikgate.setConsentRegion('EEA');
          await showConsent();
        }}
      />
      <Button
        title="Attribution metadata (for Paystack)"
        onPress={showMetadata}
      />
      <Card>
        <Text style={styles.cardTitle}>Push</Text>
        <Text>{pushStatus()}</Text>
      </Card>
      <Button
        primary
        title="Invite friends"
        onPress={() => navigate({ name: 'invite' })}
      />
      <Button
        title="I have a referral code"
        onPress={() => navigate({ name: 'applyCode' })}
      />
      <Button
        title="Weekly leaderboard"
        onPress={() => navigate({ name: 'leaderboard' })}
      />
      <Button
        title="Redeem a promo code"
        onPress={() => navigate({ name: 'promoCode' })}
      />
      <Button title="Show installation ID" onPress={showInstallationId} />
      <Button title="Goal: account opened (₦2,000,000)" onPress={recordGoal} />
      <Button
        title="Payment goal: purchase (Paystack)"
        onPress={recordPaymentGoal}
      />
      <Button title="Refresh" onPress={refresh} />
      {message ? <Text style={styles.hint}>{message}</Text> : null}
      <Text style={styles.hint}>
        Open https://{ExampleConfig.linkDomain}/… links to test direct deep
        links.
      </Text>
    </ScrollView>
  );
}

// ------------------------------------------------------------------ invite

export function InviteScreen() {
  const [userId, setUserId] = useState('user_42');
  const [token, setToken] = useState('');
  const [name, setName] = useState('Ada');
  const [link, setLink] = useState<ReferralLink | null>(null);
  const [stats, setStats] = useState<ReferralStats | null>(null);
  const [status, setStatus] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);

  const run = async (action: () => Promise<void>) => {
    setBusy(true);
    try {
      await action();
      setStatus(null);
    } catch (e) {
      setStatus(describeError(e));
    } finally {
      setBusy(false);
    }
  };

  const createLink = () =>
    run(async () => {
      // The identity token comes from your backend (HMAC of the user id, see docs).
      await Clikgate.identifyUser({
        label: name.trim().length > 0 ? name.trim() : null,
        customerId: userId.trim(),
        identityToken: token.trim().length > 0 ? token.trim() : null,
      });
      setLink(
        await engage.referrals.createLink({
          programId: ExampleConfig.programId,
          displayName: name.trim(),
        })
      );
    });

  // share.referralLink: each app gets its own version of the link, so Clikgate knows where it was shared.
  const share = async (l: ReferralLink) => {
    await engage.share.referralLink(l, {
      message: 'Join me on the Clikgate example:',
    });
  };

  const shareToWhatsApp = () =>
    run(async () => {
      const l = await engage.referrals.createLink({
        programId: ExampleConfig.programId,
        displayName: name.trim(),
      });
      const opened = await engage.share.referralLink(l, {
        message: 'Join me on the Clikgate example:',
        app: ShareApp.WhatsApp,
      });
      if (!opened) setStatus('WhatsApp not installed: used the share sheet');
    });

  const loadStats = () =>
    run(async () => {
      setStats(
        await engage.referrals.myStats({ programId: ExampleConfig.programId })
      );
    });

  return (
    <ScrollView
      contentContainerStyle={styles.content}
      keyboardShouldPersistTaps="handled"
    >
      <Field label="Customer user id" value={userId} onChangeText={setUserId} />
      <Field
        label="Identity token (optional)"
        value={token}
        onChangeText={setToken}
      />
      <Field label="Display name" value={name} onChangeText={setName} />
      <Button
        primary
        disabled={busy}
        title="Get my invite link"
        onPress={createLink}
      />
      {busy ? <ActivityIndicator /> : null}
      {link ? (
        <Card>
          <Text selectable testID="referral-link">
            Code: {link.code}
            {'\n'}
            {link.url}
          </Text>
          <Button primary title="Share" onPress={() => share(link)} />
        </Card>
      ) : null}
      <Button
        disabled={busy}
        title="Share to WhatsApp"
        onPress={shareToWhatsApp}
      />
      <Button disabled={busy} title="My referral stats" onPress={loadStats} />
      {stats ? (
        <Card>
          {(
            [
              ['Clicks', stats.clicks],
              ['Installs', stats.installs],
              ['Signups', stats.signups],
              ['In progress', stats.inProgress],
              ['Qualified', stats.qualified],
              ['Disqualified', stats.disqualified],
              ['Rejected', stats.rejected],
            ] as const
          ).map(([label, value]) => (
            <View key={label} style={styles.row}>
              <Text>{label}</Text>
              <Text>{value}</Text>
            </View>
          ))}
        </Card>
      ) : null}
      {status ? <Text style={styles.error}>{status}</Text> : null}
    </ScrollView>
  );
}

// ------------------------------------------------------------------ apply code

const friendly: Record<string, string> = {
  code_not_found: 'That code does not exist.',
  already_referred: 'You were already referred.',
  window_expired: 'Codes can only be entered shortly after installing.',
  self_referral: 'You can’t use your own code.',
  program_paused: 'The referral program is paused.',
  manual_entry_disabled: 'Codes can’t be entered manually for this program.',
  referrer_blocked: 'That code can no longer be used.',
};

export function ApplyCodeScreen() {
  const [code, setCode] = useState('');
  const [message, setMessage] = useState<string | null>(null);

  const apply = async () => {
    try {
      const referral = await Clikgate.referrals.applyCode({
        programId: ExampleConfig.programId,
        code: code.trim(),
      });
      setMessage(
        `Referred by ${referral.referrerDisplayName ?? 'a friend'} (${referral.status})`
      );
    } catch (e) {
      setMessage(
        e instanceof ClikgateError
          ? (friendly[e.code] ?? describeError(e))
          : String(e)
      );
    }
  };

  return (
    <View style={styles.content}>
      <Field
        label="Friend’s code"
        value={code}
        onChangeText={setCode}
        placeholder="ADA42X"
        autoCapitalize="characters"
      />
      <Button primary title="Apply" onPress={apply} />
      {message ? <Text style={styles.hint}>{message}</Text> : null}
    </View>
  );
}

// ------------------------------------------------------------------ leaderboard (v3)

function EntryRow({ entry }: { entry: LeaderboardEntry }) {
  return (
    <View style={[styles.row, entry.isMe && styles.rowMe]}>
      <Text>
        #{entry.rank} {entry.display}
        {entry.isMe ? ' (you)' : ''}
      </Text>
      <Text>
        {entry.score}
        {entry.pending != null ? ` (+${entry.pending} pending)` : ''}
      </Text>
    </View>
  );
}

/** Weekly board: top 10, the user's rank and the entries around them. */
export function LeaderboardScreen() {
  const id = ExampleConfig.leaderboardId;
  const [enabled, setEnabled] = useState<boolean | null>(null);
  const [top, setTop] = useState<LeaderboardPage | null>(null);
  const [me, setMe] = useState<MyRank | null>(null);
  const [around, setAround] = useState<LeaderboardPage | null>(null);
  const [status, setStatus] = useState<string | null>(null);

  const load = useCallback(async () => {
    const on = await Clikgate.isFeatureEnabled('leaderboards');
    setEnabled(on);
    if (!on) return;
    try {
      setTop(await engage.leaderboards.top(id, { limit: 10 }));
      setStatus(null);
    } catch (e) {
      setStatus(describeError(e));
      return;
    }
    // `me` / `aroundMe` need an identified user (see "Invite friends").
    try {
      setMe(await engage.leaderboards.me(id));
      setAround(await engage.leaderboards.aroundMe(id, { radius: 3 }));
    } catch (e) {
      setStatus(
        e instanceof ClikgateError && e.code === 'referrer_not_found'
          ? 'Create an invite link to join the leaderboard.'
          : describeError(e)
      );
    }
  }, [id]);

  useEffect(() => {
    load();
  }, [load]);

  const toggleOptOut = async (programId: string, optOut: boolean) => {
    try {
      await engage.leaderboards.setOptOut({ programId, optOut });
      await load();
    } catch (e) {
      setStatus(describeError(e));
    }
  };

  if (enabled === false) {
    return (
      <View style={styles.content}>
        <Text>Leaderboards are switched off for this organisation.</Text>
      </View>
    );
  }
  return (
    <ScrollView contentContainerStyle={styles.content}>
      {top ? (
        <Card>
          <Text style={styles.cardTitle}>
            {top.name ?? 'Leaderboard'} · {top.period.key}
          </Text>
          {top.period.endsAt ? (
            <Text style={styles.hint}>
              Ends {top.period.endsAt.toLocaleString()}
            </Text>
          ) : null}
          {top.entries.map((e) => (
            <EntryRow key={e.referrerId} entry={e} />
          ))}
          {top.entries.length === 0 ? <Text>No entries yet.</Text> : null}
        </Card>
      ) : (
        <ActivityIndicator />
      )}
      {me ? (
        <Card tone="success">
          <Text style={styles.cardTitle} testID="my-rank">
            {me.rank != null ? `You are #${me.rank}` : 'Not ranked yet'} ·{' '}
            {me.score} points
          </Text>
          {me.gapToNext != null ? (
            <Text>{me.gapToNext} more to move up</Text>
          ) : null}
          {me.bestRank != null ? <Text>Best rank: #{me.bestRank}</Text> : null}
        </Card>
      ) : null}
      {around && around.entries.length > 0 ? (
        <Card>
          <Text style={styles.cardTitle}>Around you</Text>
          {around.entries.map((e) => (
            <EntryRow key={e.referrerId} entry={e} />
          ))}
        </Card>
      ) : null}
      {me ? (
        <Button
          title={me.optedOut ? 'Show me on leaderboards' : 'Hide me'}
          onPress={() => toggleOptOut(ExampleConfig.programId, !me.optedOut)}
        />
      ) : null}
      <Button title="Refresh" onPress={load} />
      {status ? <Text style={styles.error}>{status}</Text> : null}
    </ScrollView>
  );
}

// ------------------------------------------------------------------ promo code (v3)

const promoErrors: Record<string, string> = {
  code_not_found: 'That code does not exist.',
  code_expired: 'That code has expired.',
  code_disabled: 'That code is no longer active.',
  redemption_limit_reached: 'That code has been used up.',
  rate_limited: 'Too many attempts. Try again later.',
  feature_disabled: 'Promo codes are switched off.',
};

export function PromoCodeScreen() {
  const [code, setCode] = useState('');
  const [message, setMessage] = useState<string | null>(null);

  const redeem = async () => {
    try {
      const r = await engage.codes.redeem(code);
      setMessage(
        r.referral
          ? `Referred by ${r.referral.referrerDisplayName ?? 'a friend'}`
          : `Code ${r.code.code} redeemed (${r.code.kind})`
      );
    } catch (e) {
      setMessage(
        e instanceof ClikgateError
          ? (promoErrors[e.code] ?? friendly[e.code] ?? describeError(e))
          : String(e)
      );
    }
  };

  return (
    <View style={styles.content}>
      <Field
        label="Promo code"
        value={code}
        onChangeText={setCode}
        placeholder="LAGOS50"
        autoCapitalize="characters"
      />
      <Button primary title="Redeem" onPress={redeem} />
      {message ? (
        <Text style={styles.hint} testID="promo-result">
          {message}
        </Text>
      ) : null}
    </View>
  );
}

// ------------------------------------------------------------------ deep link destinations

/** Destination of product links (`/products/{id}`). */
export function ProductScreen({ link }: { link: ClikgateDeepLink }) {
  const productId =
    typeof link.data.product_id === 'string' ? link.data.product_id : link.path;
  return (
    <ScrollView contentContainerStyle={styles.content}>
      <Text style={styles.headline}>Product {productId}</Text>
      <Text>
        path: {link.path}
        {'\n'}data: {JSON.stringify(link.data)}
        {'\n'}deferred: {String(link.isDeferred)}
        {'\n'}match: {link.matchType}
      </Text>
      {link.link?.externalReference ? (
        <Text>offer: {link.link.externalReference}</Text>
      ) : null}
    </ScrollView>
  );
}

/** Shown for referral links (deferred after install, or direct). */
export function ReferralWelcomeScreen({ link }: { link: ClikgateDeepLink }) {
  return (
    <View style={styles.content}>
      <Text style={styles.headline} testID="referral-welcome">
        {link.referral?.referrerDisplayName ?? 'A friend'} invited you!
      </Text>
      <Text>
        {link.isDeferred
          ? 'Deferred deep link after install'
          : 'Opened from a link'}{' '}
        → {link.path}
        {'\n'}data: {JSON.stringify(link.data)}
      </Text>
    </View>
  );
}

const styles = StyleSheet.create({
  content: { padding: 16, gap: 12 },
  card: { backgroundColor: 'white', borderRadius: 12, padding: 16, gap: 6 },
  cardSuccess: { backgroundColor: '#e8f5e9' },
  cardTitle: { fontSize: 16, fontWeight: '600' },
  button: {
    borderWidth: 1,
    borderColor: '#3f51b5',
    borderRadius: 24,
    paddingVertical: 12,
    alignItems: 'center',
  },
  buttonPrimary: { backgroundColor: '#3f51b5' },
  buttonDisabled: { opacity: 0.5 },
  buttonText: { color: '#3f51b5', fontWeight: '600' },
  buttonTextPrimary: { color: 'white' },
  field: { gap: 4 },
  label: { color: '#555' },
  input: {
    backgroundColor: 'white',
    borderRadius: 8,
    borderWidth: StyleSheet.hairlineWidth,
    borderColor: '#999',
    paddingHorizontal: 12,
    paddingVertical: 10,
  },
  row: { flexDirection: 'row', justifyContent: 'space-between' },
  rowMe: { backgroundColor: '#e8eaf6', borderRadius: 4 },
  error: { color: '#c62828' },
  hint: { color: '#555', fontSize: 13 },
  headline: { fontSize: 22, fontWeight: '600' },
});
