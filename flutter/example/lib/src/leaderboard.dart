import 'dart:async';

import 'package:flutter/material.dart';

import 'config.dart';
import 'screens.dart' show describeError;
import 'variants/features.dart';

/// Weekly leaderboard, same screen in both variants: live top entries, a "my rank" card and the
/// entries around the user; the Engage variant adds a "hide me" switch. Refreshes every
/// [refreshInterval] while visible (ranks are live server-side) and on pull-to-refresh, clearing
/// client caches first (Engage keeps reads for 60 s).
class LeaderboardScreen extends StatefulWidget {
  const LeaderboardScreen({
    super.key,
    this.leaderboardId = ExampleConfig.leaderboardId,
    this.refreshInterval = const Duration(seconds: 15),
  });

  final String leaderboardId;
  final Duration refreshInterval;

  @override
  State<LeaderboardScreen> createState() => _LeaderboardScreenState();
}

class _LeaderboardScreenState extends State<LeaderboardScreen> {
  BoardPage? _top;
  List<BoardEntry> _around = const [];
  BoardRank? _me;
  String? _error;
  String? _meError;
  bool _disabled = false;
  bool _savingOptOut = false;
  Timer? _timer;
  DateTime? _updatedAt;
  late ReferralFeatures _features;
  bool _started = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _features = FeaturesScope.of(context);
    if (!_started) {
      _started = true;
      _load();
      _timer = Timer.periodic(widget.refreshInterval, (_) => _refresh());
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  Future<void> _refresh() {
    _features.clearCache();
    return _load();
  }

  Future<void> _load() async {
    try {
      final top = await _features.leaderboard(widget.leaderboardId, limit: 20);
      if (!mounted) return;
      setState(() {
        _top = top;
        _error = null;
        _updatedAt = DateTime.now();
      });
    } on AppError catch (e) {
      if (!mounted) return;
      setState(() {
        _disabled = e.code == 'feature_disabled';
        _error = _disabled ? null : describeError(e);
      });
      if (_disabled) _timer?.cancel();
      return;
    }
    // "My rank" needs a signed-in user who has a referral link; say why if not.
    try {
      final me = await _features.myRank(widget.leaderboardId);
      final around = await _features.aroundMe(widget.leaderboardId, radius: 2);
      if (!mounted) return;
      setState(() {
        _me = me;
        _around = around;
        _meError = null;
      });
    } on AppError catch (e) {
      if (!mounted) return;
      setState(() => _meError = switch (e.code) {
            'referrer_not_found' => 'Invite a friend to get on the board.',
            'not_identified' || 'identity_required' || 'unauthenticated' => 'Sign in to see your rank.',
            _ => describeError(e),
          });
    }
  }

  Future<void> _setOptOut(bool hide) async {
    setState(() => _savingOptOut = true);
    try {
      await _features.setLeaderboardOptOut(hide);
      await _refresh();
    } on AppError catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(describeError(e))));
    } finally {
      if (mounted) setState(() => _savingOptOut = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final top = _top;
    final me = _me;
    return Scaffold(
      appBar: AppBar(title: Text(top?.name ?? 'Leaderboard')),
      body: _disabled
          ? const Center(
              key: Key('leaderboard-disabled'),
              child: Padding(padding: EdgeInsets.all(24), child: Text('Leaderboards are turned off for this app.')),
            )
          : RefreshIndicator(
              onRefresh: _refresh,
              child: ListView(
                padding: const EdgeInsets.all(16),
                children: [
                  if (top != null)
                    Text(
                      'Period ${top.period.key} (${top.period.status})'
                      '${top.period.endsAt != null ? ' · ends ${_date(top.period.endsAt!)}' : ''}',
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  const SizedBox(height: 8),
                  _myRankCard(context),
                  if (me != null && _features.supportsLeaderboardOptOut)
                    SwitchListTile(
                      key: const Key('leaderboard-opt-out'),
                      title: const Text('Hide me from leaderboards'),
                      value: me.optedOut,
                      onChanged: _savingOptOut ? null : _setOptOut,
                    ),
                  if (_error != null) Text(_error!, key: const Key('leaderboard-error'), style: const TextStyle(color: Colors.red)),
                  const SizedBox(height: 8),
                  Text('Top ${top?.metric ?? ''}', style: Theme.of(context).textTheme.titleMedium),
                  if (top == null && _error == null)
                    const Padding(padding: EdgeInsets.all(24), child: Center(child: CircularProgressIndicator())),
                  if (top != null && top.entries.isEmpty) const ListTile(title: Text('No one on the board yet.')),
                  for (final e in top?.entries ?? const <BoardEntry>[]) _entryTile(e),
                  if (_around.isNotEmpty && !(top?.entries.any((e) => e.isMe) ?? false)) ...[
                    const Divider(),
                    Text('Around you', style: Theme.of(context).textTheme.titleMedium),
                    for (final e in _around) _entryTile(e),
                  ],
                  if (_updatedAt != null)
                    Padding(
                      padding: const EdgeInsets.only(top: 12),
                      child: Text(
                          'Updated ${TimeOfDay.fromDateTime(_updatedAt!).format(context)} · refreshes every ${widget.refreshInterval.inSeconds} s',
                          style: Theme.of(context).textTheme.bodySmall),
                    ),
                ],
              ),
            ),
    );
  }

  Widget _myRankCard(BuildContext context) {
    final me = _me;
    if (me == null) {
      return Card(
        child: ListTile(leading: const Icon(Icons.person), title: const Text('My rank'), subtitle: Text(_meError ?? '…', key: const Key('my-rank-message'))),
      );
    }
    final lines = [
      'Score ${me.score}${me.pending != null ? ' · ${me.pending} pending' : ''}',
      if (me.gapToNext != null) '${me.gapToNext} more to move up',
      if (me.bestRank != null) 'Best rank #${me.bestRank}',
      if (me.optedOut) 'Hidden from the board',
    ];
    return Card(
      key: const Key('my-rank-card'),
      color: Theme.of(context).colorScheme.primaryContainer,
      child: ListTile(
        leading: CircleAvatar(child: Text(me.rank != null ? '#${me.rank}' : '–')),
        title: Text(me.rank != null ? 'You are #${me.rank}' : 'Not ranked yet'),
        subtitle: Text(lines.join('\n')),
      ),
    );
  }

  Widget _entryTile(BoardEntry e) => ListTile(
        key: Key('entry-${e.rank}-${e.referrerId}'),
        selected: e.isMe,
        leading: CircleAvatar(child: Text('${e.rank}')),
        title: Text(e.isMe ? '${e.display} (you)' : e.display),
        subtitle: e.pending != null && e.pending! > 0 ? Text('${e.pending} pending') : null,
        trailing: Text('${e.score}', style: Theme.of(context).textTheme.titleMedium),
      );

  static String _date(DateTime d) {
    final l = d.toLocal();
    return '${l.year}-${l.month.toString().padLeft(2, '0')}-${l.day.toString().padLeft(2, '0')}';
  }
}
