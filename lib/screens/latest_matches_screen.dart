import 'dart:async';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import '../models/match_fixture.dart';
import '../models/match_prediction.dart';
import '../models/sport_type.dart';
import '../models/team_form.dart';
import '../services/pang_pang_sports_service.dart';
import '../services/prediction_log_service.dart';
import '../services/real_data_service.dart';
import '../theme/app_theme.dart';
import '../widgets/app_shell.dart';
import '../widgets/prediction_breakdown_card.dart';
import '../widgets/sport_filter_chips.dart';

/// 所有比賽屏幕 - 顯示今日和明日的所有比賽
class LatestMatchesScreen extends StatefulWidget {
  const LatestMatchesScreen({super.key});

  @override
  State<LatestMatchesScreen> createState() => _LatestMatchesScreenState();
}

class _LatestMatchesScreenState extends State<LatestMatchesScreen>
    with TickerProviderStateMixin {
  Future<List<MatchFixture>>? _matchesFuture;
  late PangPangSportsService _sportsService;
  String _selectedSport = 'all';
  List<MatchFixture> _cachedMatches = [];
  Timer? _liveTimer;
  final _logSvc = PredictionLogService();
  // 已完賽比賽 ID 集合，用來偵測「新完賽」事件
  final Set<String> _prevCompletedIds = {};
  // 足球聯賽收合狀態（在 set 中 = 已收合，預設全部展開）
  final Set<String> _collapsedLeagues = {};
  // 已完賽區塊收合狀態（預設收合）
  bool _completedCollapsed = true;

  // 日期分頁：0=今天，1=明天，2=後天
  int _selectedDayOffset = 0;

  // 預測快取：match.id → MatchPrediction
  final Map<String, MatchPrediction> _predictionCache = {};

  // 即時更新：最後更新時間 & 是否正在靜默刷新
  DateTime? _lastRefreshTime;
  // ignore: prefer_final_fields
  bool _isSilentRefreshing = false;

  // 排行榜
  bool _showStandings = false;
  String _standingsLeague = '英超';
  List<LeagueStandingEntry>? _standingsData;
  bool _standingsLoading = false;

  late AnimationController _pulseCtrl;
  late Animation<double> _pulseAnim;

  SportType? get _selectedSportType => switch (_selectedSport) {
        '⚾' => SportType.baseball,
        '🏀' => SportType.basketball,
        '⚽' => SportType.football,
        _ => null,
      };

  @override
  void initState() {
    super.initState();
    _sportsService = PangPangSportsService();
    _pulseCtrl = AnimationController(
        vsync: this, duration: const Duration(milliseconds: 900))
      ..repeat(reverse: true);
    _pulseAnim = Tween<double>(begin: 0.3, end: 1.0)
        .animate(CurvedAnimation(parent: _pulseCtrl, curve: Curves.easeInOut));

    // 載入比賽資料
    _loadMatches();
  }

  @override
  void dispose() {
    _liveTimer?.cancel();
    _pulseCtrl.dispose();
    super.dispose();
  }

  void _startLiveTimer() {
    _liveTimer?.cancel();
    // 有進行中的美職棒時用 20s（SBO 跑分快）；其餘固定 30s，確保賭盤賠率即時更新
    final hasLiveBall = _cachedMatches.any(
        (m) => m.status == MatchStatus.live && m.sport == SportType.baseball);
    final interval = hasLiveBall ? 20 : 30;
    _liveTimer = Timer.periodic(Duration(seconds: interval), (_) {
      if (!mounted) return;
      // 無論是否有進行中比賽，都靜默刷新以取得最新賭盤賠率
      _loadMatches(silent: true);
    });
  }

  void _loadMatches({bool silent = false}) {
    if (!silent) {
      _matchesFuture = _sportsService.getMatchesForDays(days: 5).then((matches) {
        _cachedMatches = matches;
        _lastRefreshTime = DateTime.now();
        _startLiveTimer();
        _autoSaveSportPredictions(matches);
        _computePredictions(matches);
        return matches;
      });
      if (mounted) setState(() {});
    } else {
      if (_isSilentRefreshing) return; // 避免並發刷新
      setState(() => _isSilentRefreshing = true);
      _sportsService.getMatchesForDays(days: 5).then((matches) {
        if (!mounted) return;
        // 當賠率有變動時，清除預測快取以便使用最新盤口重算
        final oddsChanged = _oddsChanged(_cachedMatches, matches);
        if (oddsChanged) {
          _predictionCache.clear();
          PangPangSportsService.clearPredictionCache();
        }
        setState(() {
          _cachedMatches = matches;
          _lastRefreshTime = DateTime.now();
          _isSilentRefreshing = false;
        });
        _matchesFuture = Future.value(matches);
        _autoSaveSportPredictions(matches);
        _computePredictions(matches);
      }).catchError((_) {
        if (mounted) setState(() => _isSilentRefreshing = false);
      });
    }
  }

  /// 比較前後兩份賽程中，是否有任何賭盤賠率發生變化
  bool _oddsChanged(List<MatchFixture> oldList, List<MatchFixture> newList) {
    if (oldList.length != newList.length) return true;
    for (int i = 0; i < oldList.length; i++) {
      final o = oldList[i].odds;
      final n = newList[i].odds;
      if ((o.homeWin - n.homeWin).abs() > 0.01 ||
          (o.awayWin - n.awayWin).abs() > 0.01 ||
          (o.overLine - n.overLine).abs() > 0.05) {
        return true;
      }
    }
    return false;
  }

  String _formatRefreshTime(DateTime t) {
    final h = t.hour.toString().padLeft(2, '0');
    final m = t.minute.toString().padLeft(2, '0');
    final s = t.second.toString().padLeft(2, '0');
    return '$h:$m:$s';
  }

  Future<void> _computePredictions(List<MatchFixture> matches) async {
    final toSave = <Future<void>>[];
    for (final m in matches) {
      if (m.status == MatchStatus.completed) continue;
      if (_predictionCache.containsKey(m.id)) continue;
      try {
        // predictMatch() 有 static session cache，整個 app 同一場比賽只算一次
        final pred = _sportsService.predictMatch(m);
        _predictionCache[m.id] = pred;
        final ph = pred.predictedHomeScore;
        final pa = pred.predictedAwayScore;
        if (ph != 0 || pa != 0) {
          // 寫入 PredictionLogService，讓圖表頁讀到完全相同的數據
          toSave.add(_logSvc.saveSportPrediction(
            matchId: m.id,
            homeTeam: m.homeTeam,
            awayTeam: m.awayTeam,
            league: m.league,
            matchTime: m.startTime,
            predictedHome: ph,
            predictedHomeRaw: ph,
            predictedAway: pa,
            predictedAwayRaw: pa,
            confidence: pred.confidence,
            sportType: m.sport.name,
            winner: ph > pa ? 'home' : ph < pa ? 'away' : 'draw',
            mcHomeWinPct: pred.monteCarloHomeWinPct,
            mcDrawPct: pred.monteCarloDrawPct,
            mcAwayWinPct: pred.monteCarloAwayWinPct,
          ));
        }
      } catch (_) {}
    }
    // 並行寫入，等全部完成再 setState（圖表頁開啟時資料已就緒）
    await Future.wait(toSave, eagerError: false);
    if (mounted) setState(() {});
  }

  void _loadStandings(String league) {
    setState(() {
      _standingsLeague = league;
      _standingsLoading = true;
      _standingsData = null;
    });
    RealDataService.fetchStandings(league).then((data) {
      if (!mounted) return;
      setState(() {
        _standingsData = data;
        _standingsLoading = false;
      });
    });
  }

  void _autoSaveSportPredictions(List<MatchFixture> matches) {
    final completedScores = <String, (int, int)>{};
    final newlyCompletedLeagues = <String>{};

    for (final match in matches) {
      if (match.status != MatchStatus.completed) continue;
      completedScores[match.id] = (match.homeScore, match.awayScore);
      if (!_prevCompletedIds.contains(match.id)) {
        newlyCompletedLeagues.add(match.league);
      }
    }

    _prevCompletedIds
      ..clear()
      ..addAll(completedScores.keys);

    // 回填已完賽比分到 AI 預測紀錄（供下次 AI 學習使用）
    _logSvc.autoReportSportsByMatchId(completedScores);

    for (final league in newlyCompletedLeagues) {
      _sportsService.notifyLeagueMatchCompleted(league);
    }
  }

  /// 依選定日期過濾
  /// m.startTime 由 _toTaiwanTime() 產生：是 UTC-flagged 但值已是台灣時間 (UTC+8)
  /// 直接比對 year/month/day 即為台灣日期，不可再加 8 小時。
  /// 美聯賽事 (美職聯/NBA/美職棒) 改以美東日期比對（台灣 − 12h=EDT，−13h=EST），
  /// 避免下午~凌晨的美國比賽被移到隔天分頁。
  List<MatchFixture> _filterByDay(List<MatchFixture> matches) {
    final twNow = DateTime.now().toUtc().add(const Duration(hours: 8));
    final target = DateTime(twNow.year, twNow.month, twNow.day)
        .add(Duration(days: _selectedDayOffset));

    // 美東時區：夏令 UTC-4（3~11月）= 台灣 -12h；冬令 UTC-5 = 台灣 -13h
    final utcMonth = DateTime.now().toUtc().month;
    final twToUsHours = (utcMonth >= 3 && utcMonth <= 11) ? 12 : 13;

    return matches.where((m) {
      final compareDate = _usTimezoneLeagues.contains(m.league)
          ? m.startTime.subtract(Duration(hours: twToUsHours))
          : m.startTime;
      return compareDate.year == target.year &&
          compareDate.month == target.month &&
          compareDate.day == target.day;
    }).toList();
  }

  // 使用美東日期而非台灣日期的聯賽
  static const _usTimezoneLeagues = {'NBA', '美職棒', '美職聯'};

  List<MatchFixture> _filterBySport(List<MatchFixture> matches) {
    List<MatchFixture> filtered;
    if (_selectedSport == 'all') {
      filtered = matches;
    } else {
      filtered = matches.where((match) {
        return switch (_selectedSport) {
          '⚾' => match.sport == SportType.baseball,
          '🏀' => match.sport == SportType.basketball,
          '⚽' => match.sport == SportType.football,
          _ => true,
        };
      }).toList();
    }

    // Sort: live first, then scheduled (by time), then completed
    filtered.sort((a, b) {
      int statusOrder(MatchStatus s) => switch (s) {
            MatchStatus.live => 0,
            MatchStatus.scheduled => 1,
            MatchStatus.completed => 2,
            MatchStatus.postponed => 3,
          };
      final so = statusOrder(a.status).compareTo(statusOrder(b.status));
      if (so != 0) return so;
      return a.startTime.compareTo(b.startTime);
    });
    return filtered;
  }

  Widget _buildDayTabs(DateTime twNow) {
    const labels = ['今天', '明天', '後天', '第4天', '第5天'];
    const weekdays = ['一', '二', '三', '四', '五', '六', '日'];
    return SizedBox(
      height: 54,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        itemCount: 5,
        separatorBuilder: (_, _) => const SizedBox(width: 8),
        itemBuilder: (context, i) {
          final day = DateTime(twNow.year, twNow.month, twNow.day)
              .add(Duration(days: i));
          final weekday = weekdays[day.weekday - 1];
          final selected = _selectedDayOffset == i;
          return GestureDetector(
            onTap: () => setState(() => _selectedDayOffset = i),
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 180),
              width: 68,
              padding: const EdgeInsets.symmetric(vertical: 6),
              decoration: BoxDecoration(
                color: selected
                    ? AppTheme.primaryAccent.withValues(alpha: 0.18)
                    : Colors.white.withValues(alpha: 0.05),
                borderRadius: BorderRadius.circular(10),
                border: Border.all(
                  color: selected
                      ? AppTheme.primaryAccent.withValues(alpha: 0.6)
                      : Colors.white.withValues(alpha: 0.08),
                ),
              ),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Text(
                    labels[i],
                    style: TextStyle(
                      color: selected ? AppTheme.primaryAccent : Colors.white54,
                      fontSize: 12,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    '${day.month}/${day.day} 週$weekday',
                    style: TextStyle(
                      color: selected
                          ? AppTheme.primaryAccent.withValues(alpha: 0.8)
                          : Colors.white38,
                      fontSize: 9,
                    ),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return AppShell(
      title: '所有比賽',
      actions: [
        // 即時更新狀態：顯示最後刷新時間 + 脈衝圓點
        if (_lastRefreshTime != null)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                AnimatedBuilder(
                  animation: _pulseAnim,
                  builder: (_, child) => Container(
                    width: 7,
                    height: 7,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: (_isSilentRefreshing
                              ? Colors.orange
                              : Colors.greenAccent)
                          .withValues(alpha: _pulseAnim.value),
                    ),
                  ),
                ),
                const SizedBox(width: 4),
                Text(
                  _formatRefreshTime(_lastRefreshTime!),
                  style: const TextStyle(
                      fontSize: 10,
                      color: Colors.white54,
                      fontFeatures: [FontFeature.tabularFigures()]),
                ),
              ],
            ),
          ),
        IconButton(
          icon: const Icon(Icons.refresh_rounded),
          onPressed: _loadMatches,
        ),
      ],
      padding: EdgeInsets.zero,
      child: RefreshIndicator(
        color: AppTheme.primaryAccent,
        onRefresh: () async => _loadMatches(),
        child: FutureBuilder<List<MatchFixture>>(
          future: _matchesFuture,
          builder: (context, snapshot) {
            if (snapshot.connectionState == ConnectionState.waiting) {
              return const Center(
                child: CircularProgressIndicator(
                  valueColor:
                      AlwaysStoppedAnimation<Color>(AppTheme.primaryAccent),
                ),
              );
            }
            if (snapshot.hasError) {
              return Center(
                child: Text('加載失敗：${snapshot.error}',
                    style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                          color: Theme.of(context).colorScheme.error,
                        )),
              );
            }

            final allMatches = snapshot.data ?? [];

            if (allMatches.isEmpty) {
              return const Center(
                child: Text('暫無比賽',
                    style: TextStyle(color: Colors.white54, fontSize: 16)),
              );
            }

            final filteredMatches = _filterByDay(_filterBySport(allMatches));

            // Taiwan today
            final twNow =
                DateTime.now().toUtc().add(const Duration(hours: 8));
            final todayKey =
                '${twNow.year}-${twNow.month.toString().padLeft(2, '0')}-${twNow.day.toString().padLeft(2, '0')}';

            String dateSectionLabel(String key) {
              final parts = key.split('-');
              final m = int.parse(parts[1]);
              final d = int.parse(parts[2]);
              final diff = DateTime(int.parse(parts[0]), m, d)
                  .difference(DateTime(twNow.year, twNow.month, twNow.day))
                  .inDays;
              final suffix = switch (diff) {
                0 => '今天',
                1 => '明天',
                2 => '後天',
                -1 => '昨天',
                _ when diff < 0 => '${-diff}天前',
                _ => '$diff天後',
              };
              return '📅  $m/$d  $suffix';
            }

            // 分離已完賽與未完賽
            final activeFiltered = filteredMatches
                .where((m) => m.status != MatchStatus.completed)
                .toList();
            final completedFiltered = filteredMatches
                .where((m) => m.status == MatchStatus.completed)
                .toList();

            // Build a flat list of items
            final items = <_ListItem>[];

            if (_selectedSport == '⚽') {
              // ── 足球：依聯賽分組（可展開/收合）────────────────────
              final byLeague = <String, List<MatchFixture>>{};
              for (final m in activeFiltered) {
                byLeague.putIfAbsent(m.league, () => []).add(m);
              }
              // 排序：有進行中的聯賽優先，再按最早比賽時間
              final sortedLeagues = byLeague.keys.toList()
                ..sort((a, b) {
                  final aLive = byLeague[a]!.any((m) => m.status == MatchStatus.live);
                  final bLive = byLeague[b]!.any((m) => m.status == MatchStatus.live);
                  if (aLive != bLive) return aLive ? -1 : 1;
                  final aFirst = byLeague[a]!.map((m) => m.startTime).reduce((x, y) => x.isBefore(y) ? x : y);
                  final bFirst = byLeague[b]!.map((m) => m.startTime).reduce((x, y) => x.isBefore(y) ? x : y);
                  return aFirst.compareTo(bFirst);
                });
              for (final league in sortedLeagues) {
                final leagueMatches = byLeague[league]!;
                final hasLive = leagueMatches.any((m) => m.status == MatchStatus.live);
                final isExpanded = !_collapsedLeagues.contains(league);
                items.add(_LeagueGroupHeader(
                  league: league,
                  count: leagueMatches.length,
                  hasLive: hasLive,
                  isExpanded: isExpanded,
                ));
                if (isExpanded) {
                  for (final m in leagueMatches) {
                    items.add(_MatchItem(m));
                  }
                }
              }

              // ── 足球已完賽區塊 ──────────────────────────────────
              if (completedFiltered.isNotEmpty) {
                items.add(_SectionHeader(
                  '✅ 已完賽',
                  isCompleted: true,
                  count: completedFiltered.length,
                  isExpanded: !_completedCollapsed,
                ));
                if (!_completedCollapsed) {
                  final compByLeague = <String, List<MatchFixture>>{};
                  for (final m in completedFiltered) {
                    compByLeague.putIfAbsent(m.league, () => []).add(m);
                  }
                  for (final league in compByLeague.keys) {
                    items.add(_LeagueGroupHeader(
                      league: league,
                      count: compByLeague[league]!.length,
                      isExpanded: true,
                    ));
                    for (final m in compByLeague[league]!) {
                      items.add(_MatchItem(m));
                    }
                  }
                }
              }
            } else {
              // ── 其他模式：依日期分組 ──────────────────────────────
              final activeLive = activeFiltered
                  .where((m) => m.status == MatchStatus.live)
                  .toList();
              final activeNonLive = activeFiltered
                  .where((m) => m.status != MatchStatus.live)
                  .toList();

              // 未完賽依日期分組
              final activeByDate = <String, List<MatchFixture>>{};
              for (final m in activeNonLive) {
                final key =
                    '${m.startTime.year}-${m.startTime.month.toString().padLeft(2, '0')}-${m.startTime.day.toString().padLeft(2, '0')}';
                activeByDate.putIfAbsent(key, () => []).add(m);
              }
              final activeSortedDates = activeByDate.keys.toList()..sort();

              if (activeLive.isNotEmpty) {
                items.add(_SectionHeader('🔴 進行中', isLive: true));
                for (final m in activeLive) {
                  items.add(_MatchItem(m));
                }
              }
              for (final dateKey in activeSortedDates) {
                final label = dateSectionLabel(dateKey);
                items.add(_SectionHeader(label,
                    isToday: dateKey == todayKey));
                for (final m in activeByDate[dateKey]!) {
                  items.add(_MatchItem(m));
                }
              }

              // ── 已完賽區塊 ──────────────────────────────────────
              if (completedFiltered.isNotEmpty) {
                items.add(_SectionHeader(
                  '✅ 已完賽',
                  isCompleted: true,
                  count: completedFiltered.length,
                  isExpanded: !_completedCollapsed,
                ));
                if (!_completedCollapsed) {
                  // 已完賽依日期分組
                  final compByDate = <String, List<MatchFixture>>{};
                  for (final m in completedFiltered) {
                    final tw = m.startTime.toUtc().add(const Duration(hours: 8));
                    final key =
                        '${tw.year}-${tw.month.toString().padLeft(2, '0')}-${tw.day.toString().padLeft(2, '0')}';
                    compByDate.putIfAbsent(key, () => []).add(m);
                  }
                  final compSortedDates = compByDate.keys.toList()..sort((a, b) => b.compareTo(a)); // 最新優先
                  for (final dateKey in compSortedDates) {
                    final label = dateSectionLabel(dateKey);
                    items.add(_SectionHeader(label));
                    for (final m in compByDate[dateKey]!) {
                      items.add(_MatchItem(m));
                    }
                  }
                }
              }
            }

            return ListView.builder(
              physics: const AlwaysScrollableScrollPhysics(),
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 96),
              itemCount: items.length + 1,
              itemBuilder: (context, index) {
                if (index == 0) {
                  return Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceAround,
                        children: [
                          _StatBadge('全部', allMatches.length),
                          _StatBadge(
                              '進行中',
                              allMatches
                                  .where(
                                      (m) => m.status == MatchStatus.live)
                                  .length,
                              color: Colors.red),
                          _StatBadge(
                              '棒球',
                              allMatches
                                  .where((m) =>
                                      m.sport == SportType.baseball)
                                  .length),
                          _StatBadge(
                              '籃球',
                              allMatches
                                  .where((m) =>
                                      m.sport == SportType.basketball)
                                  .length),
                          _StatBadge(
                              '足球',
                              allMatches
                                  .where(
                                      (m) => m.sport == SportType.football)
                                  .length),
                        ],
                      ),
                      const SizedBox(height: 14),
                      SportFilterChips(
                        selectedSport: _selectedSportType,
                        onChanged: (sport) => setState(() {
                          _selectedSport = switch (sport) {
                            SportType.baseball => '⚾',
                            SportType.basketball => '🏀',
                            SportType.football => '⚽',
                            null => 'all',
                          };
                          _showStandings = false;
                        }),
                      ),
                      const SizedBox(height: 10),
                      // ── 日期分頁選擇器 ────────────────────────
                      _buildDayTabs(twNow),
                      const SizedBox(height: 8),
                      // ── 排行榜切換按鈕 ─────────────────────────
                      GestureDetector(
                        onTap: () {
                          setState(() => _showStandings = !_showStandings);
                          if (_showStandings && _standingsData == null) {
                            // 根據當前運動篩選選擇默認聯賽
                            final defaultLeague = switch (_selectedSport) {
                              '⚾' => '美職棒',
                              '🏀' => 'NBA',
                              _ => '英超',
                            };
                            _loadStandings(defaultLeague);
                          }
                        },
                        child: Container(
                          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                          decoration: BoxDecoration(
                            color: _showStandings
                                ? AppTheme.primaryAccent.withValues(alpha: 0.15)
                                : Colors.white.withValues(alpha: 0.05),
                            borderRadius: BorderRadius.circular(20),
                            border: Border.all(
                              color: _showStandings
                                  ? AppTheme.primaryAccent.withValues(alpha: 0.5)
                                  : Colors.white.withValues(alpha: 0.1),
                            ),
                          ),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(Icons.leaderboard_rounded,
                                  size: 16,
                                  color: _showStandings ? AppTheme.primaryAccent : Colors.white54),
                              const SizedBox(width: 6),
                              Text('排行榜',
                                  style: TextStyle(
                                    color: _showStandings ? AppTheme.primaryAccent : Colors.white54,
                                    fontSize: 13,
                                    fontWeight: _showStandings ? FontWeight.w700 : FontWeight.w500,
                                  )),
                              const SizedBox(width: 4),
                              Icon(
                                _showStandings ? Icons.expand_less : Icons.expand_more,
                                size: 16,
                                color: _showStandings ? AppTheme.primaryAccent : Colors.white38,
                              ),
                            ],
                          ),
                        ),
                      ),
                      // ── 排行榜內容 ──────────────────────────────
                      if (_showStandings) ...[
                        const SizedBox(height: 10),
                        _buildStandingsSection(),
                      ],
                      const SizedBox(height: 14),
                    ],
                  );
                }

                final item = items[index - 1];
                if (item is _SectionHeader) {
                  return _buildSectionHeader(item);
                }
                if (item is _LeagueGroupHeader) {
                  return _buildLeagueHeader(item);
                }
                final match = (item as _MatchItem).match;
                return Padding(
                  padding: const EdgeInsets.only(bottom: 10),
                  child: _MatchTile(
                    match: match,
                    pulseAnim: _pulseAnim,
                    prediction: _predictionCache[match.id],
                    onBookmark: () {
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(content: Text('已加入關注清單')),
                      );
                    },
                  ),
                );
              },
            );
          },
        ),
      ),
    );
  }

  // ── 排行榜 UI ────────────────────────────────────────────────
  static const _soccerStandingsLeagues = ['英超', '西甲', '德甲', '意甲', '法甲', '日職', '葡超', '荷甲', '澳超', '歐冠', '歐洲聯賽', '歐協聯'];
  static const _baseballStandingsLeagues = ['美職棒', '日本職棒', '中華職棒'];
  static const _basketballStandingsLeagues = ['NBA'];

  List<String> get _availableStandingsLeagues {
    return switch (_selectedSport) {
      '⚽' => _soccerStandingsLeagues,
      '⚾' => _baseballStandingsLeagues,
      '🏀' => _basketballStandingsLeagues,
      _ => [..._soccerStandingsLeagues, ..._baseballStandingsLeagues, ..._basketballStandingsLeagues],
    };
  }

  Widget _buildStandingsSection() {
    final leagues = _availableStandingsLeagues;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // 聯賽選擇 chips
        SizedBox(
          height: 34,
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            itemCount: leagues.length,
            separatorBuilder: (_, _) => const SizedBox(width: 8),
            itemBuilder: (context, i) {
              final lg = leagues[i];
              final selected = lg == _standingsLeague;
              return GestureDetector(
                onTap: () => _loadStandings(lg),
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                  decoration: BoxDecoration(
                    color: selected
                        ? AppTheme.primaryAccent.withValues(alpha: 0.2)
                        : Colors.white.withValues(alpha: 0.06),
                    borderRadius: BorderRadius.circular(16),
                    border: Border.all(
                      color: selected
                          ? AppTheme.primaryAccent.withValues(alpha: 0.6)
                          : Colors.white.withValues(alpha: 0.1),
                    ),
                  ),
                  child: Text(lg,
                      style: TextStyle(
                        color: selected ? AppTheme.primaryAccent : Colors.white54,
                        fontSize: 12,
                        fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                      )),
                ),
              );
            },
          ),
        ),
        const SizedBox(height: 10),
        // 排行榜表格
        if (_standingsLoading)
          const Center(
            child: Padding(
              padding: EdgeInsets.all(20),
              child: CircularProgressIndicator(
                strokeWidth: 2,
                valueColor: AlwaysStoppedAnimation<Color>(AppTheme.primaryAccent),
              ),
            ),
          )
        else if (_standingsData != null && _standingsData!.isNotEmpty)
          _buildStandingsTable(_standingsData!)
        else if (_standingsData != null)
          const Center(
            child: Padding(
              padding: EdgeInsets.all(16),
              child: Text('暫無排行資料', style: TextStyle(color: Colors.white38, fontSize: 13)),
            ),
          ),
      ],
    );
  }

  Widget _buildStandingsTable(List<LeagueStandingEntry> entries) {
    // 判斷是否為足球聯賽（有 draws 和 points）
    final isSoccer = entries.any((e) => e.points > 0);
    // 如果有 group 分組（MLB/NBA），按組分段
    final groups = <String, List<LeagueStandingEntry>>{};
    for (final e in entries) {
      groups.putIfAbsent(e.group, () => []).add(e);
    }

    return Container(
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.03),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.white.withValues(alpha: 0.08)),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        children: [
          for (final groupEntry in groups.entries) ...[
            if (groups.length > 1)
              Container(
                width: double.infinity,
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                color: Colors.white.withValues(alpha: 0.04),
                child: Text(groupEntry.key,
                    style: const TextStyle(
                        color: Colors.white60, fontSize: 12, fontWeight: FontWeight.w600)),
              ),
            // 表頭
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
              color: Colors.white.withValues(alpha: 0.02),
              child: Row(
                children: [
                  const SizedBox(width: 24, child: Text('#', textAlign: TextAlign.center,
                      style: TextStyle(color: Colors.white38, fontSize: 11))),
                  const SizedBox(width: 6),
                  const Expanded(child: Text('球隊',
                      style: TextStyle(color: Colors.white38, fontSize: 11))),
                  SizedBox(width: 28, child: Text(isSoccer ? '賽' : '勝', textAlign: TextAlign.center,
                      style: const TextStyle(color: Colors.white38, fontSize: 11))),
                  if (isSoccer) ...[
                    const SizedBox(width: 28, child: Text('勝', textAlign: TextAlign.center,
                        style: TextStyle(color: Colors.white38, fontSize: 11))),
                    const SizedBox(width: 28, child: Text('和', textAlign: TextAlign.center,
                        style: TextStyle(color: Colors.white38, fontSize: 11))),
                    const SizedBox(width: 28, child: Text('負', textAlign: TextAlign.center,
                        style: TextStyle(color: Colors.white38, fontSize: 11))),
                    const SizedBox(width: 32, child: Text('淨', textAlign: TextAlign.center,
                        style: TextStyle(color: Colors.white38, fontSize: 11))),
                    const SizedBox(width: 30, child: Text('分', textAlign: TextAlign.center,
                        style: TextStyle(color: Colors.white38, fontSize: 11, fontWeight: FontWeight.bold))),
                  ] else ...[
                    const SizedBox(width: 28, child: Text('負', textAlign: TextAlign.center,
                        style: TextStyle(color: Colors.white38, fontSize: 11))),
                    const SizedBox(width: 42, child: Text('勝率', textAlign: TextAlign.center,
                        style: TextStyle(color: Colors.white38, fontSize: 11))),
                  ],
                ],
              ),
            ),
            ...groupEntry.value.asMap().entries.map((e) {
              final idx = e.key;
              final entry = e.value;
              final isTop = entry.rank <= 4;
              final isBottom = isSoccer && entry.rank >= groupEntry.value.length - 2;
              return Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
                decoration: BoxDecoration(
                  color: idx.isEven ? Colors.transparent : Colors.white.withValues(alpha: 0.015),
                  border: Border(
                    left: BorderSide(
                      width: 3,
                      color: isTop
                          ? AppTheme.primaryAccent.withValues(alpha: 0.6)
                          : isBottom
                              ? Colors.red.withValues(alpha: 0.5)
                              : Colors.transparent,
                    ),
                  ),
                ),
                child: Row(
                  children: [
                    SizedBox(width: 24,
                      child: Text('${entry.rank}', textAlign: TextAlign.center,
                          style: TextStyle(
                            color: isTop ? AppTheme.primaryAccent : Colors.white54,
                            fontSize: 11,
                            fontWeight: isTop ? FontWeight.w700 : FontWeight.w500,
                          ))),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(entry.teamName,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(color: Colors.white, fontSize: 12)),
                    ),
                    if (isSoccer) ...[
                      SizedBox(width: 28, child: Text('${entry.gamesPlayed}', textAlign: TextAlign.center,
                          style: const TextStyle(color: Colors.white54, fontSize: 11))),
                      SizedBox(width: 28, child: Text('${entry.wins}', textAlign: TextAlign.center,
                          style: const TextStyle(color: Colors.white70, fontSize: 11))),
                      SizedBox(width: 28, child: Text('${entry.draws}', textAlign: TextAlign.center,
                          style: const TextStyle(color: Colors.white54, fontSize: 11))),
                      SizedBox(width: 28, child: Text('${entry.losses}', textAlign: TextAlign.center,
                          style: const TextStyle(color: Colors.white54, fontSize: 11))),
                      SizedBox(width: 32, child: Text(entry.goalDifference, textAlign: TextAlign.center,
                          style: TextStyle(
                            color: entry.goalDifference.startsWith('+') ? Colors.greenAccent : entry.goalDifference.startsWith('-') ? Colors.redAccent : Colors.white54,
                            fontSize: 11,
                          ))),
                      SizedBox(width: 30, child: Text('${entry.points}', textAlign: TextAlign.center,
                          style: TextStyle(
                            color: isTop ? AppTheme.primaryAccent : Colors.white,
                            fontSize: 12,
                            fontWeight: FontWeight.w700,
                          ))),
                    ] else ...[
                      SizedBox(width: 28, child: Text('${entry.wins}', textAlign: TextAlign.center,
                          style: const TextStyle(color: Colors.white70, fontSize: 11))),
                      SizedBox(width: 28, child: Text('${entry.losses}', textAlign: TextAlign.center,
                          style: const TextStyle(color: Colors.white54, fontSize: 11))),
                      SizedBox(width: 42, child: Text(entry.winPct, textAlign: TextAlign.center,
                          style: const TextStyle(color: Colors.white, fontSize: 11, fontWeight: FontWeight.w600))),
                    ],
                  ],
                ),
              );
            }),
          ],
        ],
      ),
    );
  }

  Widget _buildLeagueHeader(_LeagueGroupHeader header) {
    return GestureDetector(
      onTap: () => setState(() {
        if (_collapsedLeagues.contains(header.league)) {
          _collapsedLeagues.remove(header.league);
        } else {
          _collapsedLeagues.add(header.league);
        }
      }),
      child: Container(
        margin: const EdgeInsets.only(top: 10, bottom: 4),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        decoration: BoxDecoration(
          color: header.hasLive
              ? Colors.red.withValues(alpha: 0.08)
              : Colors.white.withValues(alpha: 0.05),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: header.hasLive
                ? Colors.red.withValues(alpha: 0.35)
                : Colors.white.withValues(alpha: 0.10),
          ),
        ),
        child: Row(
          children: [
            if (header.hasLive)
              AnimatedBuilder(
                animation: _pulseAnim,
                builder: (context, _) => Container(
                  width: 8,
                  height: 8,
                  margin: const EdgeInsets.only(right: 8),
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: Colors.red.withValues(alpha: _pulseAnim.value),
                  ),
                ),
              )
            else
              const Text('⚽', style: TextStyle(fontSize: 14)),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                header.league,
                style: TextStyle(
                  color: header.hasLive ? Colors.redAccent : Colors.white,
                  fontSize: 14,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
              decoration: BoxDecoration(
                color: AppTheme.primaryAccent.withValues(alpha: 0.15),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Text(
                '${header.count}場',
                style: const TextStyle(
                  color: AppTheme.primaryAccent,
                  fontSize: 11,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            const SizedBox(width: 6),
            AnimatedRotation(
              turns: header.isExpanded ? 0.0 : -0.25,
              duration: const Duration(milliseconds: 200),
              child: const Icon(Icons.keyboard_arrow_down_rounded,
                  color: Colors.white54, size: 22),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildSectionHeader(_SectionHeader header) {
    // ── 已完賽區塊標頭（可展開/收合）──────────────────────────────
    if (header.isCompleted) {
      return GestureDetector(
        onTap: () => setState(() => _completedCollapsed = !_completedCollapsed),
        child: Container(
          margin: const EdgeInsets.only(top: 16, bottom: 6),
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          decoration: BoxDecoration(
            color: Colors.white.withValues(alpha: 0.05),
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: Colors.white.withValues(alpha: 0.10)),
          ),
          child: Row(
            children: [
              Text(header.label,
                  style: const TextStyle(
                    color: Colors.white70,
                    fontSize: 14,
                    fontWeight: FontWeight.w700,
                  )),
              const SizedBox(width: 8),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                decoration: BoxDecoration(
                  color: Colors.white.withValues(alpha: 0.08),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Text(
                  '${header.count}場',
                  style: const TextStyle(
                    color: Colors.white54,
                    fontSize: 11,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              const Spacer(),
              AnimatedRotation(
                turns: header.isExpanded ? 0.0 : -0.25,
                duration: const Duration(milliseconds: 200),
                child: const Icon(Icons.keyboard_arrow_down_rounded,
                    color: Colors.white54, size: 22),
              ),
            ],
          ),
        ),
      );
    }

    // ── 一般區塊標頭 ────────────────────────────────────────────
    final color = header.isLive
        ? Colors.red
        : header.isToday
            ? AppTheme.primaryAccent
            : Colors.white60;
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 16, 0, 6),
      child: Row(
        children: [
          if (header.isLive)
            AnimatedBuilder(
              animation: _pulseAnim,
              builder: (context, child) => Container(
                width: 8,
                height: 8,
                margin: const EdgeInsets.only(right: 6),
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: Colors.red.withValues(alpha: _pulseAnim.value),
                ),
              ),
            ),
          Text(
            header.label,
            style: TextStyle(
              color: color,
              fontSize: 13,
              fontWeight: FontWeight.w700,
              letterSpacing: 0.5,
            ),
          ),
          if (header.isToday) ...[
            const SizedBox(width: 6),
            Container(
              padding:
                  const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
              decoration: BoxDecoration(
                color: AppTheme.primaryAccent.withValues(alpha: 0.15),
                borderRadius: BorderRadius.circular(6),
              ),
              child: Text('今日',
                  style: TextStyle(
                      color: AppTheme.primaryAccent,
                      fontSize: 9,
                      fontWeight: FontWeight.w800,
                      letterSpacing: 1)),
            ),
          ],
        ],
      ),
    );
  }
}

// ── List item types ───────────────────────────────────────────────
sealed class _ListItem {}

class _SectionHeader extends _ListItem {
  _SectionHeader(this.label, {this.isLive = false, this.isToday = false, this.isCompleted = false, this.count = 0, this.isExpanded = false});
  final String label;
  final bool isLive;
  final bool isToday;
  final bool isCompleted;
  final int count;
  final bool isExpanded;
}

class _LeagueGroupHeader extends _ListItem {
  _LeagueGroupHeader({
    required this.league,
    required this.count,
    this.hasLive = false,
    this.isExpanded = true,
  });
  final String league;
  final int count;
  final bool hasLive;
  final bool isExpanded;
}

class _MatchItem extends _ListItem {
  _MatchItem(this.match);
  final MatchFixture match;
}

// ── 統計徽章 ──────────────────────────────────────────────────────
class _StatBadge extends StatelessWidget {
  const _StatBadge(this.label, this.count, {this.color});
  final String label;
  final int count;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Text(
          '$count',
          style: TextStyle(
            color: color ?? AppTheme.primaryAccent,
            fontSize: 20,
            fontWeight: FontWeight.w800,
          ),
        ),
        const SizedBox(height: 2),
        Text(label,
            style: Theme.of(context).textTheme.bodySmall),
      ],
    );
  }
}

// ── AI 預測徽章 ───────────────────────────────────────────────────
class _PredictionBadge extends StatelessWidget {
  const _PredictionBadge({required this.match, required this.prediction});
  final MatchFixture match;
  final MatchPrediction prediction;

  @override
  Widget build(BuildContext context) {
    final h = prediction.predictedHomeScore;
    final a = prediction.predictedAwayScore;
    final confPct = (prediction.confidence * 100).round();

    // 決定預測勝方標籤
    final String winnerLabel;
    if (match.sport == SportType.football) {
      if (h > a) {
        winnerLabel = '主勝';
      } else if (h < a) {
        winnerLabel = '客勝';
      } else {
        winnerLabel = '平局';
      }
    } else {
      winnerLabel = h >= a ? '主勝' : '客勝';
    }

    final winnerColor = winnerLabel == '主勝'
        ? const Color(0xFF4FC3F7)
        : winnerLabel == '客勝'
            ? const Color(0xFFFFB74D)
            : Colors.white54;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: AppTheme.primaryAccent.withValues(alpha: 0.07),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: AppTheme.primaryAccent.withValues(alpha: 0.2)),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Row(
            children: [
              const Text('🤖 ', style: TextStyle(fontSize: 11)),
              Text(
                '預測比分  $h : $a',
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 12,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 0.5,
                ),
              ),
            ],
          ),
          Row(
            children: [
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
                decoration: BoxDecoration(
                  color: winnerColor.withValues(alpha: 0.18),
                  borderRadius: BorderRadius.circular(6),
                  border: Border.all(color: winnerColor.withValues(alpha: 0.5)),
                ),
                child: Text(
                  winnerLabel,
                  style: TextStyle(
                    color: winnerColor,
                    fontSize: 11,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              const SizedBox(width: 6),
              Text(
                '信心 $confPct%',
                style: const TextStyle(color: Colors.white38, fontSize: 10),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

// ── 比賽列表卡片 ──────────────────────────────────────────────────
class _MatchTile extends StatelessWidget {
  const _MatchTile({
    required this.match,
    required this.pulseAnim,
    required this.onBookmark,
    this.prediction,
  });
  final MatchFixture match;
  final Animation<double> pulseAnim;
  final VoidCallback onBookmark;
  final MatchPrediction? prediction;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    if (match.sport == SportType.basketball) {
      return _BasketballCompactTile(
        match: match,
        prediction: prediction,
        onTap: () => _showBasketballDetail(context, match),
      );
    }

    final isLive = match.status == MatchStatus.live;
    final isCompleted = match.status == MatchStatus.completed;
    final hh = match.startTime.hour.toString().padLeft(2, '0');
    final mm = match.startTime.minute.toString().padLeft(2, '0');
    final timeStr =
        '${match.startTime.month}/${match.startTime.day} $hh:$mm';

    final sportEmoji = switch (match.sport) {
      SportType.football => '⚽',
      SportType.basketball => '🏀',
      SportType.baseball => '⚾',
    };

    return GestureDetector(
      onTap: match.sport == SportType.baseball
          ? () => _showBaseballDetail(context, match)
          : match.sport == SportType.basketball
              ? () => _showBasketballDetail(context, match)
              : match.sport == SportType.football
                  ? () => _showSoccerDetail(context, match)
                  : null,
      child: Card(
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(14),
        side: isLive
            ? BorderSide(color: Colors.red.withValues(alpha: 0.6), width: 1.5)
            : BorderSide.none,
      ),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // 聯賽 + 狀態 + 時間
            Row(
              children: [
                Text(
                  '$sportEmoji  ${match.league}',
                  style: theme.textTheme.bodySmall,
                ),
                const Spacer(),
                if (isLive) ...[
                  AnimatedBuilder(
                    animation: pulseAnim,
                    builder: (context, child) => Container(
                      width: 7,
                      height: 7,
                      margin: const EdgeInsets.only(right: 5),
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: Colors.red.withValues(alpha: pulseAnim.value),
                      ),
                    ),
                  ),
                  Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 7, vertical: 2),
                    decoration: BoxDecoration(
                      color: Colors.red.withValues(alpha: 0.15),
                      borderRadius: BorderRadius.circular(6),
                      border: Border.all(
                          color: Colors.red.withValues(alpha: 0.5)),
                    ),
                    child: const Text('直播',
                        style: TextStyle(
                            color: Colors.red,
                            fontSize: 10,
                            fontWeight: FontWeight.w800,
                            letterSpacing: 1)),
                  ),
                ] else if (isCompleted)
                  Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 7, vertical: 2),
                    decoration: BoxDecoration(
                      color: Colors.white.withValues(alpha: 0.07),
                      borderRadius: BorderRadius.circular(6),
                    ),
                    child: const Text('已完賽',
                        style: TextStyle(
                            color: Colors.white38, fontSize: 10)),
                  )
                else
                  Text(
                    timeStr,
                    style: theme.textTheme.labelMedium
                        ?.copyWith(color: AppTheme.primaryAccent),
                  ),
              ],
            ),
            const SizedBox(height: 12),
            // 球隊 vs / 比分
            if (isLive || isCompleted)
              // Show live / final score prominently
              Row(
                children: [
                  Expanded(
                    child: Text(
                      match.homeTeam,
                      style: theme.textTheme.titleMedium,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  Padding(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 12),
                    child: Text(
                      '${match.homeScore}  :  ${match.awayScore}',
                      style: TextStyle(
                        fontSize: 22,
                        fontWeight: FontWeight.w900,
                        color: isLive ? Colors.red : Colors.white,
                        letterSpacing: 2,
                      ),
                    ),
                  ),
                  Expanded(
                    child: Text(
                      match.awayTeam,
                      textAlign: TextAlign.right,
                      style: theme.textTheme.titleMedium,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ],
              )
            else
              Row(
                children: [
                  Expanded(
                    child: Text(
                      match.homeTeam,
                      style: theme.textTheme.titleMedium,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  Padding(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 12),
                    child: Text(
                      '對',
                      style: theme.textTheme.labelLarge
                          ?.copyWith(color: AppTheme.highlight),
                    ),
                  ),
                  Expanded(
                    child: Text(
                      match.awayTeam,
                      textAlign: TextAlign.right,
                      style: theme.textTheme.titleMedium,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ],
              ),

            if (isLive) ...[
              const SizedBox(height: 8),
              if (match.sport == SportType.baseball)
                Center(child: _BaseballSituation(match: match))
              else
                Center(
                  child: Text(
                    match.progressDetail.isNotEmpty
                        ? '⏱ ${match.progressDetail}'
                        : '⏱ 比賽進行中',
                    style: TextStyle(
                        color: Colors.red.withValues(alpha: 0.85),
                        fontSize: 12,
                        fontWeight: FontWeight.w600),
                  ),
                ),
            ],
            const SizedBox(height: 12),
            // 賠率 + 來源標籤
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceAround,
              children: [
                _OddsChip(label: '主勝', value: match.odds.homeWin),
                if (match.sport == SportType.baseball)
                  const _BaseballOUChip()
                else if (match.sport == SportType.basketball)
                  _OddsChip(label: '大/小', value: match.odds.overLine)
                else
                  _OddsChip(label: '平局', value: match.odds.draw),
                _OddsChip(label: '客勝', value: match.odds.awayWin),
              ],
            ),
            if (match.odds.isFromBookmaker &&
                match.odds.bookmakerName.isNotEmpty) ...[
              const SizedBox(height: 4),
              Center(
                child: Text(
                  '📡 ${match.odds.bookmakerName} 即時賠率',
                  style: TextStyle(
                      color: Colors.greenAccent.withValues(alpha: 0.7),
                      fontSize: 9,
                      letterSpacing: 0.3),
                ),
              ),
            ],
            if (prediction != null && match.status != MatchStatus.completed) ...[
              const SizedBox(height: 8),
              _PredictionBadge(match: match, prediction: prediction!),
            ],
            if (match.sport == SportType.baseball) ...[
              const SizedBox(height: 6),
              Center(
                child: Text(
                  '點擊卡片查看先發名單 & 傷兵 →',
                  style: TextStyle(
                      color: AppTheme.primaryAccent.withValues(alpha: 0.6),
                      fontSize: 10),
                ),
              ),
            ],
            if (match.sport == SportType.football) ...[
              const SizedBox(height: 6),
              Center(
                child: Text(
                  '點擊卡片查看實況 / 先發 / 傷兵 / 數據 →',
                  style: TextStyle(
                      color: AppTheme.primaryAccent.withValues(alpha: 0.6),
                      fontSize: 10),
                ),
              ),
            ],
            if (match.analystNote.isNotEmpty) ...[
              const SizedBox(height: 10),
              Text(
                match.analystNote,
                style: theme.textTheme.bodySmall,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
            ],
          ],
        ),
      ),
      ),
    );
  }

  static void _showBaseballDetail(BuildContext context, MatchFixture match) {
    final eventId = match.id.replaceFirst('espn_', '');
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => _BaseballDetailPage(
          match: match,
          eventId: eventId,
        ),
      ),
    );
  }

  static void _showBasketballDetail(BuildContext context, MatchFixture match) {
    final eventId = match.id.replaceFirst('espn_', '');
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => _BasketballDetailPage(
          match: match,
          eventId: eventId,
        ),
      ),
    );
  }

  static void _showSoccerDetail(BuildContext context, MatchFixture match) {
    final eventId = match.id.replaceFirst('espn_', '');
    final leagueSlug = RealDataService.soccerSlugForLeague(match.league) ?? 'eng.1';
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => _SoccerDetailPage(
          match: match,
          eventId: eventId,
          leagueSlug: leagueSlug,
        ),
      ),
    );
  }
}


String _formatBaseballInningZh(String detail, {bool compact = false}) {
  final top = RegExp(r'Top (\d+)', caseSensitive: false).firstMatch(detail);
  if (top != null) return '${top.group(1)}局上';
  final bot = RegExp(r'Bot (\d+)', caseSensitive: false).firstMatch(detail);
  if (bot != null) return '${bot.group(1)}局下';
  final mid = RegExp(r'Mid (\d+)', caseSensitive: false).firstMatch(detail);
  if (mid != null) return compact ? '${mid.group(1)}局完' : '${mid.group(1)}局中';
  final end = RegExp(r'End (\d+)', caseSensitive: false).firstMatch(detail);
  if (end != null) return '${end.group(1)}局完';
  return detail.isNotEmpty ? detail : '比賽進行中';
}

class _BasketballCompactTile extends StatelessWidget {
  const _BasketballCompactTile({
    required this.match,
    required this.onTap,
    this.prediction,
  });

  final MatchFixture match;
  final VoidCallback onTap;
  final MatchPrediction? prediction;

  @override
  Widget build(BuildContext context) {
    final isLive = match.status == MatchStatus.live;
    final isCompleted = match.status == MatchStatus.completed;
    final hh = match.startTime.hour.toString().padLeft(2, '0');
    final mm = match.startTime.minute.toString().padLeft(2, '0');
    final timeStr = '$hh:$mm';

    Color teamColor(int own, int opp) {
      if (!isLive && !isCompleted) return Colors.white;
      if (own > opp) return AppTheme.primaryAccent;
      return Colors.white;
    }

    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(8),
      child: Container(
        margin: const EdgeInsets.only(bottom: 8),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
        decoration: BoxDecoration(
          color: Colors.white.withValues(alpha: 0.02),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: Colors.white10),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            Expanded(
              flex: 5,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    match.awayTeam,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: teamColor(match.awayScore, match.homeScore),
                      fontSize: 21,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    match.homeTeam,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: teamColor(match.homeScore, match.awayScore),
                      fontSize: 21,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ],
              ),
            ),
            Expanded(
              flex: 2,
              child: isLive || isCompleted
                  ? Column(
                      children: [
                        Text(
                          '${match.awayScore}',
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 35,
                            fontWeight: FontWeight.w900,
                            height: 1,
                          ),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          '${match.homeScore}',
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 35,
                            fontWeight: FontWeight.w900,
                            height: 1,
                          ),
                        ),
                      ],
                    )
                  : Text(
                      timeStr,
                      style: const TextStyle(
                        color: Colors.white54,
                        fontSize: 18,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
            ),
            Expanded(
              flex: 3,
              child: Align(
                alignment: Alignment.centerRight,
                child: isLive
                    ? Text(
                        match.progressDetail.isNotEmpty
                            ? match.progressDetail
                            : '直播',
                        textAlign: TextAlign.right,
                        maxLines: 2,
                        style: const TextStyle(
                          color: Colors.red,
                          fontSize: 15,
                          fontWeight: FontWeight.w800,
                        ),
                      )
                    : isCompleted
                        ? const Text(
                            '完賽',
                            style: TextStyle(
                              color: Colors.white54,
                              fontSize: 18,
                              fontWeight: FontWeight.w700,
                            ),
                          )
                        : prediction != null
                            ? Column(
                                crossAxisAlignment: CrossAxisAlignment.end,
                                children: [
                                  Text(
                                    '${prediction!.predictedAwayScore}',
                                    style: const TextStyle(
                                      color: Color(0xFF4FC3F7),
                                      fontSize: 28,
                                      fontWeight: FontWeight.w900,
                                      height: 1,
                                    ),
                                  ),
                                  const SizedBox(height: 4),
                                  Text(
                                    '${prediction!.predictedHomeScore}',
                                    style: const TextStyle(
                                      color: Color(0xFF4FC3F7),
                                      fontSize: 28,
                                      fontWeight: FontWeight.w900,
                                      height: 1,
                                    ),
                                  ),
                                  Text(
                                    '🤖 預測',
                                    style: TextStyle(
                                      color: Colors.white.withValues(alpha: 0.3),
                                      fontSize: 9,
                                    ),
                                  ),
                                ],
                              )
                            : const Text(
                                '數據',
                                style: TextStyle(
                                  color: Colors.white70,
                                  fontSize: 24,
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// 棒球即時壘包 & SBO 小圖（仿記分板樣式）
// ─────────────────────────────────────────────────────────────────────────────
class _BaseballSituation extends StatefulWidget {
  const _BaseballSituation({required this.match});
  final MatchFixture match;

  @override
  State<_BaseballSituation> createState() => _BaseballSituationState();
}

class _BaseballSituationState extends State<_BaseballSituation> {

  // ESPN shortDetail → 中文局數，例如 "Top 6th" → "6局上"
  static String _toChineseInning(String detail) {
    final top = RegExp(r'Top (\d+)', caseSensitive: false).firstMatch(detail);
    if (top != null) return '${top.group(1)}局上';
    final bot = RegExp(r'Bot (\d+)', caseSensitive: false).firstMatch(detail);
    if (bot != null) return '${bot.group(1)}局下';
    final mid = RegExp(r'Mid (\d+)', caseSensitive: false).firstMatch(detail);
    if (mid != null) return '${mid.group(1)}局中';
    final end = RegExp(r'End (\d+)', caseSensitive: false).firstMatch(detail);
    if (end != null) return '${end.group(1)}局末';
    return detail.isNotEmpty ? detail : '比賽進行中';
  }

  @override
  Widget build(BuildContext context) {
    final match = widget.match;
    const amber = Color(0xFFFFB300);
    const emptyColor = Color(0xFF252525);
    const emptyBorder = Colors.white24;

    Widget base(bool on, {double size = 22.0}) {
      return Transform.rotate(
        angle: math.pi / 4,
        child: Container(
          width: size,
          height: size,
          decoration: BoxDecoration(
            color: on ? amber : emptyColor,
            border: Border.all(
              color: on ? Colors.amber.shade400 : emptyBorder,
              width: 1.5,
            ),
          ),
        ),
      );
    }

    final inning = _toChineseInning(match.progressDetail);
    const dW = 72.0;
    const dH = 64.0;
    const bs = 22.0;
    const hs = 15.0;
    const cx = (dW - bs) / 2;

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        // 局數文字
        Text(
          inning,
          style: const TextStyle(
            color: Colors.white,
            fontSize: 20,
            fontWeight: FontWeight.w800,
          ),
        ),
        const SizedBox(height: 10),
        Row(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            // ── 壘包菱形 ──
            SizedBox(
              width: dW,
              height: dH,
              child: Stack(
                children: [
                  Positioned(
                    left: cx, top: 0,
                    child: base(match.onSecond),
                  ),
                  Positioned(
                    left: 0, top: dH / 2 - bs / 2,
                    child: base(match.onThird),
                  ),
                  Positioned(
                    right: 0, top: dH / 2 - bs / 2,
                    child: base(match.onFirst),
                  ),
                  Positioned(
                    left: (dW - hs) / 2, bottom: 0,
                    child: base(false, size: hs),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 18),
            // ── S / B / O 指示點 ──
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                _SboRow('好', count: match.strikes, max: 2, color: amber),
                const SizedBox(height: 6),
                _SboRow('壞', count: match.balls,   max: 3, color: amber),
                const SizedBox(height: 6),
                _SboRow('出', count: match.outs,    max: 2, color: amber),
              ],
            ),
          ],
        ),
      ],
    );
  }
}

class _SboRow extends StatelessWidget {
  const _SboRow(this.label, {required this.count, required this.max, required this.color});
  final String label;
  final int count;
  final int max;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        SizedBox(
          width: 14,
          child: Text(
            label,
            style: const TextStyle(
                color: Colors.white70,
                fontSize: 12,
                fontWeight: FontWeight.w700),
          ),
        ),
        ...List.generate(max, (i) {
          final filled = i < count;
          return Container(
            width: 11,
            height: 11,
            margin: const EdgeInsets.only(left: 4),
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: filled ? color : Colors.transparent,
              border: Border.all(
                  color: color.withValues(alpha: 0.5), width: 1.5),
            ),
          );
        }),
      ],
    );
  }
}

class _OddsChip extends StatelessWidget {
  const _OddsChip({required this.label, required this.value});
  final String label;
  final double value;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Text(
          value.toStringAsFixed(2),
          style: const TextStyle(
            color: AppTheme.primaryAccent,
            fontSize: 14,
            fontWeight: FontWeight.w700,
          ),
        ),
        const SizedBox(height: 2),
        Text(label, style: Theme.of(context).textTheme.bodySmall),
      ],
    );
  }
}

// ── 投手列 ────────────────────────────────────────────────────────
// ignore: unused_element
class _PitcherRow extends StatelessWidget {
  const _PitcherRow({required this.match, required this.detail});
  final MatchFixture match;
  final BaseballGameDetail detail;

  @override
  Widget build(BuildContext context) {
    final isLive = match.status == MatchStatus.live;
    final isTop = match.progressDetail.toLowerCase().startsWith('top');

    if (isLive && match.currentPitcherName.isNotEmpty) {
      // Top inning => home team pitches. Bottom inning => away team pitches.
      final defenseTeam = isTop ? match.homeTeam : match.awayTeam;
      final defenseIsAway = !isTop;
      final gameStats = detail.pitcherGameStatsByPlayerId[match.currentPitcherPlayerId];
      final probableId = defenseIsAway
          ? match.awayProbablePitcherId
          : match.homeProbablePitcherId;
      final seasonEra = defenseIsAway
          ? match.awayProbableEra
          : match.homeProbableEra;
      final wins = defenseIsAway
          ? match.awayProbableWins
          : match.homeProbableWins;
      final losses = defenseIsAway
          ? match.awayProbableLosses
          : match.homeProbableLosses;

      return _PitcherDetailCard(
        team: defenseTeam,
        pitcherName: match.currentPitcherName,
        isAway: defenseIsAway,
        seasonEra: seasonEra.isNotEmpty
            ? seasonEra
            : (gameStats?.era ?? ''),
        seasonWins: match.currentPitcherPlayerId == probableId ? wins : '',
        seasonLosses: match.currentPitcherPlayerId == probableId ? losses : '',
        gameStats: gameStats,
      );
    }

    return Column(
      children: [
        _PitcherDetailCard(
          team: match.awayTeam,
          pitcherName: match.awayProbablePitcher,
          isAway: true,
          seasonEra: match.awayProbableEra,
          seasonWins: match.awayProbableWins,
          seasonLosses: match.awayProbableLosses,
          gameStats: null,
        ),
        const SizedBox(height: 10),
        _PitcherDetailCard(
          team: match.homeTeam,
          pitcherName: match.homeProbablePitcher,
          isAway: false,
          seasonEra: match.homeProbableEra,
          seasonWins: match.homeProbableWins,
          seasonLosses: match.homeProbableLosses,
          gameStats: null,
        ),
      ],
    );
  }
}

class _PitcherDetailCard extends StatelessWidget {
  const _PitcherDetailCard({
    required this.team,
    required this.pitcherName,
    required this.isAway,
    required this.seasonEra,
    required this.seasonWins,
    required this.seasonLosses,
    required this.gameStats,
  });

  final String team;
  final String pitcherName;
  final bool isAway;
  final String seasonEra;
  final String seasonWins;
  final String seasonLosses;
  final BaseballPitcherGameStats? gameStats;

  @override
  Widget build(BuildContext context) {
    final color = isAway ? AppTheme.secondaryAccent : AppTheme.primaryAccent;
    final hasGame = gameStats != null;

    Widget statLine(String label, String value, {bool strong = false}) {
      return Padding(
        padding: const EdgeInsets.only(bottom: 4),
        child: Row(
          children: [
            Text(
              label,
              style: TextStyle(
                color: Colors.white54,
                fontSize: strong ? 21 : 18,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(width: 8),
            Text(
              value,
              style: TextStyle(
                color: Colors.white,
                fontSize: strong ? 21 : 18,
                fontWeight: strong ? FontWeight.w800 : FontWeight.w700,
              ),
            ),
          ],
        ),
      );
    }

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.05),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: Colors.white12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            team,
            style: TextStyle(
              color: color,
              fontSize: 12,
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            pitcherName.isNotEmpty ? pitcherName : '—',
            style: const TextStyle(
              color: Colors.white,
              fontSize: 24,
              fontWeight: FontWeight.w800,
            ),
          ),
          const SizedBox(height: 8),
          statLine('防禦率', seasonEra.isNotEmpty ? seasonEra : '-'),
          statLine(
            '季戰績',
            (seasonWins.isNotEmpty || seasonLosses.isNotEmpty)
                ? '${seasonWins.isEmpty ? '0' : seasonWins} 勝 ${seasonLosses.isEmpty ? '0' : seasonLosses} 敗'
                : '-',
          ),
          if (hasGame) ...[
            const SizedBox(height: 10),
            const Text(
              '今日',
              style: TextStyle(
                color: Colors.white,
                fontSize: 18,
                fontWeight: FontWeight.w800,
              ),
            ),
            const SizedBox(height: 8),
            statLine('主投', '${gameStats!.innings.isNotEmpty ? gameStats!.innings : '-'} 局', strong: true),
            statLine('失分', gameStats!.runs.isNotEmpty ? gameStats!.runs : '0'),
            statLine('用球', gameStats!.pitches.isNotEmpty ? gameStats!.pitches : '-'),
            statLine('好球', gameStats!.strikes.isNotEmpty ? gameStats!.strikes : '-'),
            statLine('壞球', gameStats!.balls.isNotEmpty ? gameStats!.balls : '-'),
            statLine('安打', gameStats!.hits.isNotEmpty ? gameStats!.hits : '0'),
            statLine('四壞', gameStats!.walks.isNotEmpty ? gameStats!.walks : '0'),
            statLine('三振', gameStats!.strikeouts.isNotEmpty ? gameStats!.strikeouts : '0'),
          ],
        ],
      ),
    );
  }
}

// ── 現在打者卡片 ──────────────────────────────────────────────────
// ignore: unused_element
class _CurrentBatterCard extends StatelessWidget {
  const _CurrentBatterCard({required this.match, required this.lineup});
  final MatchFixture match;
  final BaseballGameDetail lineup;

  List<BaseballPlayer> _battingLineup() {
    final detail = match.progressDetail.toLowerCase();
    if (detail.startsWith('top') || detail.startsWith('mid')) {
      return lineup.awayLineup;
    }
    return lineup.homeLineup;
  }

  List<BaseballPlayer> _nextBatters(List<BaseballPlayer> line, int count) {
    if (line.isEmpty) return [];
    final idx = line.indexWhere((p) => p.playerId == match.currentBatterPlayerId);
    if (idx < 0) return [];
    return List.generate(count, (i) => line[(idx + 1 + i) % line.length]);
  }

  @override
  Widget build(BuildContext context) {
    const amber = Color(0xFFFFB300);
    final isLive = match.status == MatchStatus.live;
    final line = _battingLineup();
    final next = _nextBatters(line, 3);
    final batterAvg = lineup.batterAvgByPlayerId[match.currentBatterPlayerId] ?? '';
    final batterHits = lineup.batterHitsByPlayerId[match.currentBatterPlayerId] ?? '';
    final subStat = isLive
        ? (batterHits.isNotEmpty ? '今日 $batterHits 安打' : '今日 0 安打')
        : (batterAvg.isNotEmpty ? '打擊率 $batterAvg' : '打擊率 -');

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.05),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: Colors.white12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 7,
                height: 7,
                margin: const EdgeInsets.only(right: 7),
                decoration: const BoxDecoration(
                    shape: BoxShape.circle, color: amber),
              ),
              Text(
                match.currentBatterName,
                style: const TextStyle(
                    color: amber,
                    fontSize: 15,
                    fontWeight: FontWeight.w800),
              ),
              const Spacer(),
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
                decoration: BoxDecoration(
                  color: amber.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(5),
                  border: Border.all(color: amber.withValues(alpha: 0.4)),
                ),
                child: const Text('打擊中',
                    style: TextStyle(
                        color: amber,
                        fontSize: 10,
                        fontWeight: FontWeight.w700)),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            subStat,
            style: const TextStyle(color: Colors.white70, fontSize: 12),
          ),
          if (next.isNotEmpty) ...[
            const SizedBox(height: 8),
            const Divider(color: Colors.white12, height: 1),
            const SizedBox(height: 8),
            Row(
              children: [
                const Text('後3棒  ',
                    style: TextStyle(
                        color: Colors.white38,
                        fontSize: 11,
                        fontWeight: FontWeight.w600)),
                ...next.asMap().entries.map((e) {
                  final isLast = e.key == next.length - 1;
                  return Text(
                    '${e.value.name}${isLast ? '' : '  ›  '}',
                    style: const TextStyle(
                        color: Colors.white70, fontSize: 11),
                  );
                }),
              ],
            ),
          ],
        ],
      ),
    );
  }
}

class _BaseballOUChip extends StatelessWidget {
  const _BaseballOUChip();

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        const Text(
          '大/小盤',
          style: TextStyle(
            color: AppTheme.highlight,
            fontSize: 14,
            fontWeight: FontWeight.w700,
          ),
        ),
        const SizedBox(height: 2),
        Text('點開查看', style: Theme.of(context).textTheme.bodySmall),
      ],
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// 棒球賽事詳情全頁
// ─────────────────────────────────────────────────────────────────────────────
class _BaseballDetailPage extends StatefulWidget {
  const _BaseballDetailPage({
    required this.match,
    required this.eventId,
  });
  final MatchFixture match;
  final String eventId;

  @override
  State<_BaseballDetailPage> createState() => _BaseballDetailPageState();
}

class _BaseballDetailPageState extends State<_BaseballDetailPage>
    with SingleTickerProviderStateMixin {
  BaseballGameDetail? _detail;
  bool _loading = true;
  late final TabController _tabController;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 4, vsync: this);
    _load();
  }

  @override
  void dispose() {
    _tabController.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final detail = await RealDataService.fetchBaseballSummary(widget.eventId);
    if (mounted) setState(() { _detail = detail; _loading = false; });
  }

  @override
  Widget build(BuildContext context) {
    final match = widget.match;
    final detail = _detail;
    final isLive = match.status == MatchStatus.live;
    final isCompleted = match.status == MatchStatus.completed;

    return Scaffold(
      backgroundColor: const Color(0xFF0A1020),
      appBar: AppBar(
        backgroundColor: const Color(0xFF0A1020),
        foregroundColor: Colors.white,
        elevation: 0,
        centerTitle: true,
        title: Column(
          children: [
            Text(
              match.league,
              style: const TextStyle(
                color: Colors.white70,
                fontSize: 12,
                fontWeight: FontWeight.w600,
              ),
            ),
            if (isLive)
              Text(
                _formatBaseballInningZh(match.progressDetail, compact: true),
                style: const TextStyle(
                  color: AppTheme.primaryAccent,
                  fontSize: 13,
                  fontWeight: FontWeight.w800,
                ),
              )
            else if (isCompleted)
              const Text(
                '比賽結束',
                style: TextStyle(
                  color: Colors.white54,
                  fontSize: 12,
                ),
              ),
          ],
        ),
      ),
      bottomNavigationBar: Container(
        color: const Color(0xFF101820),
        child: SafeArea(
          top: false,
          child: TabBar(
            controller: _tabController,
            labelColor: AppTheme.primaryAccent,
            unselectedLabelColor: Colors.white38,
            indicatorColor: AppTheme.primaryAccent,
            indicatorSize: TabBarIndicatorSize.label,
            indicatorWeight: 2.5,
            dividerColor: Colors.white12,
            labelStyle: const TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w800,
            ),
            unselectedLabelStyle: const TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w600,
            ),
            tabs: const [
              Tab(text: '賽況'),
              Tab(text: '先發'),
              Tab(text: '傷兵'),
              Tab(text: '數據'),
            ],
          ),
        ),
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : detail == null
              ? const Center(
                  child: Text('無法載入詳細資料',
                      style: TextStyle(color: Colors.white54)))
              : Column(
                  children: [
                    // ── 固定比分頭部 ──
                    _BaseballDetailHeader(match: match, detail: detail),
                    const Divider(height: 1, color: Colors.white12),
                    // ── 各頁籤內容 ──
                    Expanded(
                      child: TabBarView(
                        controller: _tabController,
                        children: [
                          // 賽況頁
                          ListView(
                            padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
                            children: [
                              if ((match.homeProbablePitcher.isNotEmpty ||
                                      match.awayProbablePitcher.isNotEmpty) ||
                                  (match.status == MatchStatus.live &&
                                      match.currentBatterName.isNotEmpty)) ...[
                                _PitchingBattingSplit(
                                    match: match, detail: detail),
                                const SizedBox(height: 16),
                              ],
                              if (detail.homeLineScores.isNotEmpty ||
                                  detail.awayLineScores.isNotEmpty) ...[
                                _SheetSectionTitle(title: '得分版'),
                                const SizedBox(height: 8),
                                _BaseballLineScoreTable(
                                    match: match, detail: detail),
                                const SizedBox(height: 16),
                              ],
                              if (match.lastPlayText.isNotEmpty) ...[
                                _SheetSectionTitle(title: '最新戰況'),
                                const SizedBox(height: 8),
                                _BaseballLastPlayCard(text: match.lastPlayText),
                              ],
                            ],
                          ),
                          // 先發名單頁
                          ListView(
                            padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
                            children: [
                              _LineupsRow(
                                homeTeam: match.homeTeam,
                                awayTeam: match.awayTeam,
                                homeLineup: detail.homeLineup,
                                awayLineup: detail.awayLineup,
                              ),
                            ],
                          ),
                          // 傷兵名單頁
                          detail.injuries.isEmpty
                              ? const Center(
                                  child: Text(
                                    '目前無傷兵資料',
                                    style: TextStyle(
                                        color: Colors.white38, fontSize: 14),
                                  ),
                                )
                              : ListView(
                                  padding: const EdgeInsets.fromLTRB(
                                      16, 16, 16, 24),
                                  children: detail.injuries
                                      .map((inj) => _InjuryRow(injury: inj))
                                      .toList(),
                                ),
                          // 數據頁
                          ListView(
                            padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
                            children: [
                              PredictionBreakdownCard(
                                fixture: match,
                                prediction: PangPangSportsService().predictMatch(match),
                              ),
                              const SizedBox(height: 20),
                              _SheetSectionTitle(title: '球隊戰績'),
                              const SizedBox(height: 10),
                              _TeamRecordCard(match: match, detail: detail),
                              const SizedBox(height: 20),
                              _SheetSectionTitle(title: '近況'),
                              const SizedBox(height: 10),
                              _TeamStreakCard(match: match, detail: detail),
                              const SizedBox(height: 20),
                              _SheetSectionTitle(title: '先發投手'),
                              const SizedBox(height: 10),
                              _StarterPitcherEraCard(match: match, detail: detail),
                              const SizedBox(height: 20),
                              if (detail.awayLineup.isNotEmpty || detail.homeLineup.isNotEmpty) ...[
                                _SheetSectionTitle(title: '球員資料'),
                                const SizedBox(height: 10),
                                _PlayerStatsSection(match: match, detail: detail),
                                const SizedBox(height: 20),
                              ],
                              if (detail.overUnder != null) ...[
                                _SheetSectionTitle(title: '大小盤建議'),
                                const SizedBox(height: 8),
                                _OverUnderCard(detail: detail, match: match),
                              ],
                            ],
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
    );
  }
}

class _BaseballDetailHeader extends StatelessWidget {
  const _BaseballDetailHeader({required this.match, required this.detail});

  final MatchFixture match;
  final BaseballGameDetail detail;

  @override
  Widget build(BuildContext context) {
    final isLive = match.status == MatchStatus.live;
    final isCompleted = match.status == MatchStatus.completed;

    Widget scoreSide({
      required String team,
      required int score,
      required TextAlign align,
      required Color nameColor,
    }) {
      return Column(
        crossAxisAlignment: align == TextAlign.left
            ? CrossAxisAlignment.start
            : CrossAxisAlignment.end,
        children: [
          Text(
            team,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            textAlign: align,
            style: TextStyle(
              color: nameColor,
              fontSize: 15,
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            isLive || isCompleted ? '$score' : '--',
            textAlign: align,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 54,
              height: 0.9,
              fontWeight: FontWeight.w900,
            ),
          ),
        ],
      );
    }

    return Container(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 18),
      color: const Color(0xFF0A1020),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: scoreSide(
              team: match.awayTeam,
              score: match.awayScore,
              align: TextAlign.left,
              nameColor: AppTheme.secondaryAccent,
            ),
          ),
          const SizedBox(width: 8),
          _BaseballCenterDiamond(match: match),
          const SizedBox(width: 8),
          Expanded(
            child: scoreSide(
              team: match.homeTeam,
              score: match.homeScore,
              align: TextAlign.right,
              nameColor: AppTheme.primaryAccent,
            ),
          ),
        ],
      ),
    );
  }
}

class _SheetSectionTitle extends StatelessWidget {
  const _SheetSectionTitle({required this.title});
  final String title;
  @override
  Widget build(BuildContext context) {
    return Text(
      title,
      style: const TextStyle(
          color: Colors.white70,
          fontSize: 14,
          fontWeight: FontWeight.w700),
    );
  }
}

class _BaseballLastPlayCard extends StatelessWidget {
  const _BaseballLastPlayCard({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: const Color(0xFF131C31),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Text(
        text,
        style: const TextStyle(
          color: Colors.white,
          fontSize: 14,
          fontWeight: FontWeight.w600,
          height: 1.45,
        ),
      ),
    );
  }
}

class _BaseballCenterDiamond extends StatelessWidget {
  const _BaseballCenterDiamond({required this.match});

  final MatchFixture match;

  @override
  Widget build(BuildContext context) {
    final inning = _formatBaseballInningZh(match.progressDetail, compact: true);

    Widget countRow(String label, int value, int max) {
      return Text(
        '$label ${List.generate(max, (index) => index < value ? '●' : '○').join(' ')}',
        style: const TextStyle(
          color: Colors.white,
          fontSize: 10,
          fontWeight: FontWeight.w700,
          height: 1.1,
        ),
      );
    }

    Widget cornerBase(bool on) {
      return Transform.rotate(
        angle: math.pi / 4,
        child: Container(
          width: 12,
          height: 12,
          decoration: BoxDecoration(
            color: on ? const Color(0xFF16B455) : Colors.white,
            border: Border.all(color: const Color(0xFFD7D7D7)),
          ),
        ),
      );
    }

    return SizedBox(
      width: 104,
      height: 118,
      child: Stack(
        clipBehavior: Clip.none,
        alignment: Alignment.center,
        children: [
          Positioned(top: 6, child: cornerBase(match.onSecond)),
          Positioned(left: 4, child: cornerBase(match.onThird)),
          Positioned(right: 4, child: cornerBase(match.onFirst)),
          Transform.rotate(
            angle: math.pi / 4,
            child: Container(
              width: 74,
              height: 74,
              decoration: BoxDecoration(
                color: const Color(0xFF1DB554),
                borderRadius: BorderRadius.circular(6),
                boxShadow: const [
                  BoxShadow(
                    color: Color(0x22000000),
                    blurRadius: 12,
                    offset: Offset(0, 4),
                  ),
                ],
              ),
            ),
          ),
          Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const SizedBox(height: 4),
              Text(
                inning,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 13,
                  fontWeight: FontWeight.w800,
                ),
              ),
              const SizedBox(height: 4),
              countRow('好', match.strikes, 2),
              countRow('壞', match.balls, 3),
              countRow('出', match.outs, 2),
            ],
          ),
        ],
      ),
    );
  }
}

class _PitchingBattingSplit extends StatelessWidget {
  const _PitchingBattingSplit({required this.match, required this.detail});

  final MatchFixture match;
  final BaseballGameDetail detail;

  @override
  Widget build(BuildContext context) {
    final showLivePitcher = match.status == MatchStatus.live &&
        match.currentPitcherName.isNotEmpty;
    final isTop = match.progressDetail.toLowerCase().startsWith('top');
    final pitcherIsAway = showLivePitcher ? !isTop : true;
    final pitcherName = showLivePitcher
        ? match.currentPitcherName
        : (match.awayProbablePitcher.isNotEmpty
            ? match.awayProbablePitcher
            : match.homeProbablePitcher);
    final probableId = showLivePitcher
        ? (pitcherIsAway
            ? match.awayProbablePitcherId
            : match.homeProbablePitcherId)
        : (match.awayProbablePitcher.isNotEmpty
            ? match.awayProbablePitcherId
            : match.homeProbablePitcherId);
    final seasonEra = showLivePitcher
        ? (pitcherIsAway ? match.awayProbableEra : match.homeProbableEra)
        : (match.awayProbablePitcher.isNotEmpty
            ? match.awayProbableEra
            : match.homeProbableEra);
    final seasonWins = showLivePitcher
        ? (pitcherIsAway ? match.awayProbableWins : match.homeProbableWins)
        : (match.awayProbablePitcher.isNotEmpty
            ? match.awayProbableWins
            : match.homeProbableWins);
    final seasonLosses = showLivePitcher
        ? (pitcherIsAway ? match.awayProbableLosses : match.homeProbableLosses)
        : (match.awayProbablePitcher.isNotEmpty
            ? match.awayProbableLosses
            : match.homeProbableLosses);
    final gameStats = showLivePitcher
        ? detail.pitcherGameStatsByPlayerId[match.currentPitcherPlayerId]
        : null;

    final battingLineup = (() {
      final progress = match.progressDetail.toLowerCase();
      if (progress.startsWith('top') || progress.startsWith('mid')) {
        return detail.awayLineup;
      }
      return detail.homeLineup;
    })();
    final currentIndex = battingLineup
        .indexWhere((player) => player.playerId == match.currentBatterPlayerId);
    final currentBatter = currentIndex >= 0
        ? battingLineup[currentIndex]
        : battingLineup.isNotEmpty
            ? battingLineup.first
            : null;
    final queue = battingLineup.isEmpty
        ? const <BaseballPlayer>[]
        : List.generate(
            math.min(4, battingLineup.length),
            (index) => battingLineup[
                ((currentIndex >= 0 ? currentIndex : 0) + index) % battingLineup.length],
          );

    return Container(
      decoration: BoxDecoration(
        color: const Color(0xFF131C31),
        borderRadius: BorderRadius.circular(16),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: _BaseballPitchingPane(
              name: pitcherName,
              era: seasonEra,
              wins: seasonWins,
              losses: seasonLosses,
              gameStats: gameStats,
              probableId: probableId,
              currentPitcherId: match.currentPitcherPlayerId,
            ),
          ),
          Container(width: 1, color: Colors.white12),
          Expanded(
            child: _BaseballBattingPane(
              match: match,
              detail: detail,
              currentBatter: currentBatter,
              queue: queue,
            ),
          ),
        ],
      ),
    );
  }
}

class _BaseballPitchingPane extends StatelessWidget {
  const _BaseballPitchingPane({
    required this.name,
    required this.era,
    required this.wins,
    required this.losses,
    required this.gameStats,
    required this.probableId,
    required this.currentPitcherId,
  });

  final String name;
  final String era;
  final String wins;
  final String losses;
  final BaseballPitcherGameStats? gameStats;
  final String probableId;
  final String currentPitcherId;

  @override
  Widget build(BuildContext context) {
    final isProbable = probableId.isNotEmpty && probableId == currentPitcherId;
    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 14, 10, 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            '投',
            style: TextStyle(
              color: AppTheme.secondaryAccent,
              fontSize: 15,
              fontWeight: FontWeight.w800,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            name.isNotEmpty ? name : '尚無資料',
            style: const TextStyle(
              color: Colors.white,
              fontSize: 18,
              fontWeight: FontWeight.w800,
            ),
          ),
          const SizedBox(height: 8),
          _LightInfoPair(label: '防禦率', value: era.isNotEmpty ? era : '-'),
          _LightInfoPair(
            label: '季戰績',
            value: (wins.isNotEmpty || losses.isNotEmpty)
                ? '${wins.isEmpty ? '0' : wins} 勝 ${losses.isEmpty ? '0' : losses} 敗'
                : '-',
          ),
          const SizedBox(height: 10),
          const Text(
            '今日',
            style: TextStyle(
              color: Colors.white54,
              fontSize: 12,
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 6),
          _LightInfoPair(
            label: '主投',
            value: gameStats?.innings.isNotEmpty == true
                ? '${gameStats!.innings} 局'
                : '-',
            strong: true,
          ),
          _LightInfoPair(label: '失分', value: gameStats?.runs.isNotEmpty == true ? gameStats!.runs : '0'),
          _LightInfoPair(label: '用球', value: gameStats?.pitches.isNotEmpty == true ? gameStats!.pitches : '-'),
          _LightInfoPair(label: '好球', value: gameStats?.strikes.isNotEmpty == true ? gameStats!.strikes : '-'),
          _LightInfoPair(label: '壞球', value: gameStats?.balls.isNotEmpty == true ? gameStats!.balls : '-'),
          _LightInfoPair(label: '安打', value: gameStats?.hits.isNotEmpty == true ? gameStats!.hits : '0'),
          _LightInfoPair(label: '四壞', value: gameStats?.walks.isNotEmpty == true ? gameStats!.walks : '0'),
          _LightInfoPair(label: '三振', value: gameStats?.strikeouts.isNotEmpty == true ? gameStats!.strikeouts : '0'),
          if (gameStats == null && isProbable)
            const Padding(
              padding: EdgeInsets.only(top: 6),
              child: Text(
                '先發預估資料',
                style: TextStyle(
                  color: Colors.white38,
                  fontSize: 11,
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _BaseballBattingPane extends StatelessWidget {
  const _BaseballBattingPane({
    required this.match,
    required this.detail,
    required this.currentBatter,
    required this.queue,
  });

  final MatchFixture match;
  final BaseballGameDetail detail;
  final BaseballPlayer? currentBatter;
  final List<BaseballPlayer> queue;

  @override
  Widget build(BuildContext context) {
    final isLive = match.status == MatchStatus.live;

    String subValue(BaseballPlayer player) {
      if (isLive) {
        final hits = detail.batterHitsByPlayerId[player.playerId] ?? player.hitsToday;
        final atBats = player.atBatsToday.isNotEmpty ? player.atBatsToday : '-';
        return '今日 $hits-$atBats';
      }
      final avg = detail.batterAvgByPlayerId[player.playerId] ?? player.battingAvg;
      return avg.isNotEmpty ? '.${avg.replaceFirst('.', '')}' : '.000';
    }

    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 14, 14, 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            '打',
            style: TextStyle(
              color: AppTheme.primaryAccent,
              fontSize: 15,
              fontWeight: FontWeight.w800,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            currentBatter?.name ??
                (match.currentBatterName.isNotEmpty
                    ? match.currentBatterName
                    : '尚無打者資料'),
            style: const TextStyle(
              color: Colors.white,
              fontSize: 18,
              fontWeight: FontWeight.w800,
            ),
          ),
          const SizedBox(height: 6),
          if (currentBatter != null)
            _BatterQueueRow(
              indexLabel: currentBatter!.batOrder > 0
                  ? '${currentBatter!.batOrder}'
                  : '打',
              title: currentBatter!.name,
              subtitle: subValue(currentBatter!),
              highlight: true,
            )
          else
            const Text(
              '目前無打者資料',
              style: TextStyle(
                color: Colors.white38,
                fontSize: 12,
              ),
            ),
          const SizedBox(height: 8),
          ...queue.skip(currentBatter == null ? 0 : 1).take(3).map((player) =>
                _BatterQueueRow(
                  indexLabel: player.batOrder > 0 ? '${player.batOrder}' : '-',
                  title: player.name,
                  subtitle: subValue(player),
                ),
              ),
        ],
      ),
    );
  }
}

class _LightInfoPair extends StatelessWidget {
  const _LightInfoPair({
    required this.label,
    required this.value,
    this.strong = false,
  });

  final String label;
  final String value;
  final bool strong;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Row(
        children: [
          SizedBox(
            width: 42,
            child: Text(
              label,
              style: TextStyle(
                color: Colors.white54,
                fontSize: strong ? 15 : 13,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          Expanded(
            child: Text(
              value,
              style: TextStyle(
                color: Colors.white,
                fontSize: strong ? 18 : 14,
                fontWeight: strong ? FontWeight.w800 : FontWeight.w700,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _BatterQueueRow extends StatelessWidget {
  const _BatterQueueRow({
    required this.indexLabel,
    required this.title,
    required this.subtitle,
    this.highlight = false,
  });

  final String indexLabel;
  final String title;
  final String subtitle;
  final bool highlight;

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(bottom: 6),
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
      decoration: BoxDecoration(
        color: highlight ? const Color(0xFF1C2D4A) : Colors.transparent,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 22,
            child: Text(
              indexLabel,
              style: TextStyle(
                color: Colors.white54,
                fontSize: 13,
                fontWeight: highlight ? FontWeight.w800 : FontWeight.w700,
              ),
            ),
          ),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 14,
                    fontWeight: highlight ? FontWeight.w800 : FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  subtitle,
                  style: const TextStyle(
                    color: Colors.white54,
                    fontSize: 12,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _BaseballLineScoreTable extends StatelessWidget {
  const _BaseballLineScoreTable({required this.match, required this.detail});

  final MatchFixture match;
  final BaseballGameDetail detail;

  @override
  Widget build(BuildContext context) {
    final innings = math.max(
      9,
      math.max(detail.awayLineScores.length, detail.homeLineScores.length),
    );

    return Container(
      padding: const EdgeInsets.fromLTRB(10, 12, 10, 12),
      decoration: BoxDecoration(
        color: const Color(0xFF131C31),
        borderRadius: BorderRadius.circular(16),
      ),
      child: Table(
        defaultVerticalAlignment: TableCellVerticalAlignment.middle,
        columnWidths: {
          0: const FlexColumnWidth(2.2),
          for (var i = 1; i <= innings + 3; i++) i: const FlexColumnWidth(1),
        },
        children: [
          TableRow(
            children: [
              _lineCell('', header: true, align: TextAlign.left),
              for (var inning = 1; inning <= innings; inning++)
                _lineCell('$inning', header: true),
              _lineCell('R', header: true),
              _lineCell('H', header: true),
              _lineCell('E', header: true),
            ],
          ),
          _lineScoreRow(
            team: match.awayTeam,
            innings: innings,
            lineScores: detail.awayLineScores,
            runs: '${match.awayScore}',
            hits: detail.awayHits,
            errors: detail.awayErrors,
          ),
          _lineScoreRow(
            team: match.homeTeam,
            innings: innings,
            lineScores: detail.homeLineScores,
            runs: '${match.homeScore}',
            hits: detail.homeHits,
            errors: detail.homeErrors,
          ),
        ],
      ),
    );
  }

  TableRow _lineScoreRow({
    required String team,
    required int innings,
    required List<BaseballLineScore> lineScores,
    required String runs,
    required String hits,
    required String errors,
  }) {
    return TableRow(
      children: [
        _lineCell(team, align: TextAlign.left, strong: true),
        for (var index = 0; index < innings; index++)
          _lineCell(index < lineScores.length ? lineScores[index].runs : ''),
        _lineCell(runs, strong: true),
        _lineCell(hits),
        _lineCell(errors),
      ],
    );
  }

  Widget _lineCell(
    String value, {
    bool header = false,
    bool strong = false,
    TextAlign align = TextAlign.center,
  }) {
    return Container(
      height: 32,
      alignment: align == TextAlign.left ? Alignment.centerLeft : Alignment.center,
      padding: EdgeInsets.only(left: align == TextAlign.left ? 6 : 0),
      decoration: BoxDecoration(
        border: Border.all(color: Colors.white12, width: 0.6),
      ),
      child: Text(
        value,
        textAlign: align,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(
          color: Colors.white,
          fontSize: header ? 11 : 12,
          fontWeight: header || strong ? FontWeight.w800 : FontWeight.w600,
        ),
      ),
    );
  }
}

// ── 近況連勝連敗卡 ────────────────────────────────────────────────
class _TeamStreakCard extends StatelessWidget {
  const _TeamStreakCard({required this.match, required this.detail});
  final MatchFixture match;
  final BaseballGameDetail detail;

  bool _hasMeaningfulValue(String value) {
    final v = value.trim();
    if (v.isEmpty) return false;
    const placeholders = {'-', '--', 'N/A', 'n/a', 'na', 'NA'};
    return !placeholders.contains(v);
  }

  String _fallbackLastTen(TeamForm form) {
    if (form.lastFiveResults.isEmpty) return '';
    final sample = form.lastFiveResults.take(10).toList();
    final wins = sample.where((r) => r == '勝').length;
    final losses = sample.where((r) => r == '負').length;
    return '$wins-$losses';
  }

  String _fallbackStreak(TeamForm form) {
    if (form.streakDisplay.isNotEmpty) return form.streakDisplay;
    final streak = form.currentStreak;
    if (streak > 0) return '連勝$streak';
    if (streak < 0) return '連敗${streak.abs()}';
    return '';
  }

  String _lastTenWinRate(String summary) {
    final parts = summary.split('-');
    if (parts.length < 2) return '';
    final wins = int.tryParse(parts[0]);
    final losses = int.tryParse(parts[1]);
    if (wins == null || losses == null) return '';
    final games = wins + losses;
    if (games <= 0) return '';
    final pct = (wins / games * 100).toStringAsFixed(0);
    return '$pct%';
  }

  Color _streakColor(String streak) {
    if (streak.startsWith('連勝')) return AppTheme.primaryAccent;
    if (streak.startsWith('連敗')) return Colors.redAccent;
    return Colors.white54;
  }

  @override
  Widget build(BuildContext context) {
    Widget streakSide({
      required String team,
      required Color teamColor,
      required String streak,
      required String last10,
      required String homeRec,
      required String roadRec,
      required CrossAxisAlignment cross,
    }) {
      final sc = _streakColor(streak);
      return Expanded(
        child: Column(
          crossAxisAlignment: cross,
          children: [
            Text(team, maxLines: 1, overflow: TextOverflow.ellipsis,
                style: TextStyle(color: teamColor, fontSize: 11, fontWeight: FontWeight.w700)),
            const SizedBox(height: 6),
            if (streak.isNotEmpty) ...[
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                decoration: BoxDecoration(
                  color: sc.withValues(alpha: 0.15),
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: sc.withValues(alpha: 0.5)),
                ),
                child: Text(
                  streak.startsWith('連勝') ? '連勝 ${streak.replaceFirst('連勝', '')} 場' :
                  streak.startsWith('連敗') ? '連敗 ${streak.replaceFirst('連敗', '')} 場' : streak,
                  style: TextStyle(color: sc, fontSize: 14, fontWeight: FontWeight.w800),
                ),
              ),
              const SizedBox(height: 8),
            ],
            if (last10.isNotEmpty) _statRow('近10場', last10, cross),
            if (last10.isNotEmpty)
              _statRow('近10勝率', _lastTenWinRate(last10), cross),
            if (homeRec.isNotEmpty) _statRow('主場', homeRec, cross),
            if (roadRec.isNotEmpty) _statRow('客場', roadRec, cross),
          ],
        ),
      );
    }

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: const Color(0xFF131C31),
        borderRadius: BorderRadius.circular(16),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          streakSide(
            team: match.awayTeam,
            teamColor: AppTheme.secondaryAccent,
            streak: _hasMeaningfulValue(detail.awayStreak)
                ? detail.awayStreak
                : _fallbackStreak(match.awayForm),
            last10: _hasMeaningfulValue(detail.awayLast10)
                ? detail.awayLast10
                : _fallbackLastTen(match.awayForm),
            homeRec: detail.awayHomeRecord,
            roadRec: detail.awayRoadRecord,
            cross: CrossAxisAlignment.start,
          ),
          Container(width: 1, height: 80, color: Colors.white12,
              margin: const EdgeInsets.symmetric(horizontal: 12)),
          streakSide(
            team: match.homeTeam,
            teamColor: AppTheme.primaryAccent,
            streak: _hasMeaningfulValue(detail.homeStreak)
                ? detail.homeStreak
                : _fallbackStreak(match.homeForm),
            last10: _hasMeaningfulValue(detail.homeLast10)
                ? detail.homeLast10
                : _fallbackLastTen(match.homeForm),
            homeRec: detail.homeHomeRecord,
            roadRec: detail.homeRoadRecord,
            cross: CrossAxisAlignment.end,
          ),
        ],
      ),
    );
  }

  Widget _statRow(String label, String value, CrossAxisAlignment cross) {
    final row = Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text('$label  ', style: const TextStyle(color: Colors.white54, fontSize: 12)),
        Text(value, style: const TextStyle(color: Colors.white, fontSize: 13, fontWeight: FontWeight.w700)),
      ],
    );
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: cross == CrossAxisAlignment.end
          ? Row(mainAxisAlignment: MainAxisAlignment.end, children: [row])
          : row,
    );
  }
}

// ── 球員資料區塊 ──────────────────────────────────────────────────
class _PlayerStatsSection extends StatelessWidget {
  const _PlayerStatsSection({required this.match, required this.detail});
  final MatchFixture match;
  final BaseballGameDetail detail;

  @override
  Widget build(BuildContext context) {
    // Show batters from both lineups, up to 9 each
    final awayBatters = detail.awayLineup.take(9).toList();
    final homeBatters = detail.homeLineup.take(9).toList();

    Widget teamHeader(String team, Color color) {
      return Padding(
        padding: const EdgeInsets.only(bottom: 6),
        child: Text(team,
            style: TextStyle(
                color: color, fontSize: 13, fontWeight: FontWeight.w800)),
      );
    }

    Widget playerRow(BaseballPlayer p) {
      final avg = detail.batterAvgByPlayerId[p.playerId] ?? p.battingAvg;
      final hits = detail.batterHitsByPlayerId[p.playerId] ?? p.hitsToday;
      final isLive = match.status == MatchStatus.live;
      final statText = isLive && hits.isNotEmpty
          ? '今日 $hits 安打'
          : avg.isNotEmpty
              ? '打擊率 $avg'
              : p.position;
      return Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: Row(
          children: [
            Container(
              width: 22,
              height: 22,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: Colors.white.withValues(alpha: 0.06),
                borderRadius: BorderRadius.circular(4),
              ),
              child: Text(
                p.batOrder > 0 ? '${p.batOrder}' : p.position.isNotEmpty ? p.position : '-',
                style: const TextStyle(
                    color: Colors.white54, fontSize: 10, fontWeight: FontWeight.w700),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(p.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                      color: Colors.white, fontSize: 13, fontWeight: FontWeight.w600)),
            ),
            Text(statText,
                style: const TextStyle(color: Colors.white54, fontSize: 12)),
          ],
        ),
      );
    }

    return Container(
      padding: const EdgeInsets.fromLTRB(14, 14, 14, 10),
      decoration: BoxDecoration(
        color: const Color(0xFF131C31),
        borderRadius: BorderRadius.circular(16),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (awayBatters.isNotEmpty) ...[
            teamHeader(match.awayTeam, AppTheme.secondaryAccent),
            ...awayBatters.map(playerRow),
          ],
          if (homeBatters.isNotEmpty) ...[
            const SizedBox(height: 12),
            const Divider(color: Colors.white12, height: 1),
            const SizedBox(height: 12),
            teamHeader(match.homeTeam, AppTheme.primaryAccent),
            ...homeBatters.map(playerRow),
          ],
        ],
      ),
    );
  }
}

// ── 球隊戰績卡 ────────────────────────────────────────────────────
class _TeamRecordCard extends StatelessWidget {
  const _TeamRecordCard({required this.match, required this.detail});
  final MatchFixture match;
  final BaseballGameDetail detail;

  bool _hasMeaningfulValue(String value) {
    final v = value.trim();
    if (v.isEmpty) return false;
    const placeholders = {'-', '--', 'N/A', 'n/a', 'na', 'NA'};
    return !placeholders.contains(v);
  }

  String _fallbackRecord(TeamForm form) {
    if (form.seasonRecord.isNotEmpty) return form.seasonRecord;
    final wins = form.lastFiveResults.where((r) => r == '勝').length;
    final losses = form.lastFiveResults.where((r) => r == '負').length;
    if (wins == 0 && losses == 0) return '';
    return '$wins-$losses';
  }

  @override
  Widget build(BuildContext context) {
    Widget side({
      required String team,
      required String record,
      required Color nameColor,
      required TextAlign align,
    }) {
      final parts = record.split('-');
      final wins = parts.isNotEmpty ? parts[0] : '-';
      final losses = parts.length > 1 ? parts[1] : '-';
      return Expanded(
        child: Column(
          crossAxisAlignment: align == TextAlign.left
              ? CrossAxisAlignment.start
              : CrossAxisAlignment.end,
          children: [
            Text(
              team,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              textAlign: align,
              style: TextStyle(
                color: nameColor,
                fontSize: 13,
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              record.isNotEmpty ? record : '-',
              textAlign: align,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 28,
                fontWeight: FontWeight.w900,
                height: 1,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              record.isNotEmpty ? '$wins 勝 $losses 敗' : '--',
              textAlign: align,
              style: const TextStyle(
                color: Colors.white54,
                fontSize: 12,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
      );
    }

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: const Color(0xFF131C31),
        borderRadius: BorderRadius.circular(16),
      ),
      child: Row(
        children: [
          side(
            team: match.awayTeam,
            record: _hasMeaningfulValue(detail.awayRecord)
                ? detail.awayRecord
                : _fallbackRecord(match.awayForm),
            nameColor: AppTheme.secondaryAccent,
            align: TextAlign.left,
          ),
          const SizedBox(
            width: 40,
            child: Center(
              child: Text(
                '對',
                style: TextStyle(
                  color: Colors.white38,
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ),
          side(
            team: match.homeTeam,
            record: _hasMeaningfulValue(detail.homeRecord)
                ? detail.homeRecord
                : _fallbackRecord(match.homeForm),
            nameColor: AppTheme.primaryAccent,
            align: TextAlign.right,
          ),
        ],
      ),
    );
  }
}

// ── 先發投手防禦率卡 ──────────────────────────────────────────────
class _StarterPitcherEraCard extends StatelessWidget {
  const _StarterPitcherEraCard({required this.match, required this.detail});
  final MatchFixture match;
  final BaseballGameDetail detail;

  @override
  Widget build(BuildContext context) {
    Widget pitcherSide({
      required String team,
      required String name,
      required String era,
      required String wins,
      required String losses,
      required Color teamColor,
      required CrossAxisAlignment crossAlign,
      required TextAlign textAlign,
    }) {
      return Expanded(
        child: Column(
          crossAxisAlignment: crossAlign,
          children: [
            Text(
              team,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: teamColor,
                fontSize: 11,
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              name.isNotEmpty ? name : '—',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              textAlign: textAlign,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 15,
                fontWeight: FontWeight.w800,
              ),
            ),
            const SizedBox(height: 8),
            Row(
              mainAxisAlignment: crossAlign == CrossAxisAlignment.start
                  ? MainAxisAlignment.start
                  : MainAxisAlignment.end,
              children: [
                Text(
                  '防禦率  ',
                  style: const TextStyle(
                    color: Colors.white54,
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                Text(
                  era.isNotEmpty ? era : '-',
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 22,
                    fontWeight: FontWeight.w900,
                    height: 1,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 4),
            Text(
              (wins.isNotEmpty || losses.isNotEmpty)
                  ? '${wins.isEmpty ? '0' : wins} 勝 ${losses.isEmpty ? '0' : losses} 敗'
                  : '--',
              textAlign: textAlign,
              style: const TextStyle(
                color: Colors.white54,
                fontSize: 12,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
      );
    }

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: const Color(0xFF131C31),
        borderRadius: BorderRadius.circular(16),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          pitcherSide(
            team: match.awayTeam,
            name: match.awayProbablePitcher,
            era: match.awayProbableEra,
            wins: match.awayProbableWins,
            losses: match.awayProbableLosses,
            teamColor: AppTheme.secondaryAccent,
            crossAlign: CrossAxisAlignment.start,
            textAlign: TextAlign.left,
          ),
          Container(width: 1, height: 80, color: Colors.white12, margin: const EdgeInsets.symmetric(horizontal: 12)),
          pitcherSide(
            team: match.homeTeam,
            name: match.homeProbablePitcher,
            era: match.homeProbableEra,
            wins: match.homeProbableWins,
            losses: match.homeProbableLosses,
            teamColor: AppTheme.primaryAccent,
            crossAlign: CrossAxisAlignment.end,
            textAlign: TextAlign.right,
          ),
        ],
      ),
    );
  }
}

class _OverUnderCard extends StatelessWidget {
  const _OverUnderCard({required this.detail, required this.match});
  final BaseballGameDetail detail;
  final MatchFixture match;

  @override
  Widget build(BuildContext context) {
    final ou = detail.overUnder!;
    final overOdds = detail.overOdds;
    final underOdds = detail.underOdds;
    // Recommend: if overOdds better (closer to -100), suggest Over
    final String suggestion;
    if (overOdds != null && underOdds != null) {
      suggestion = overOdds > underOdds ? '建議下「大」($ou 分以上)' : '建議下「小」($ou 分以下)';
    } else {
      suggestion = '大小盤：$ou 分';
    }
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: const Color(0xFF131C31),
        borderRadius: BorderRadius.circular(16),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            suggestion,
            style: const TextStyle(
                color: AppTheme.primaryAccent,
                fontSize: 16,
                fontWeight: FontWeight.w800),
          ),
          const SizedBox(height: 6),
          Row(
            children: [
              _OUOddsChip(
                  label: '大 (Over)',
                  odds: overOdds,
                  active: overOdds != null &&
                      underOdds != null &&
                      overOdds > underOdds),
              const SizedBox(width: 10),
              _OUOddsChip(
                  label: '小 (Under)',
                  odds: underOdds,
                  active: overOdds != null &&
                      underOdds != null &&
                      underOdds > overOdds),
            ],
          ),
        ],
      ),
    );
  }
}

class _OUOddsChip extends StatelessWidget {
  const _OUOddsChip(
      {required this.label,
      required this.odds,
      required this.active});
  final String label;
  final double? odds;
  final bool active;

  @override
  Widget build(BuildContext context) {
    final color = active ? AppTheme.primaryAccent : Colors.white38;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: color.withValues(alpha: 0.4)),
      ),
      child: Column(
        children: [
          Text(label,
              style: TextStyle(
                  color: color, fontSize: 11, fontWeight: FontWeight.w600)),
          if (odds != null)
            Text(
              odds! >= 0 ? '+${odds!.toInt()}' : '${odds!.toInt()}',
              style: TextStyle(
                  color: color,
                  fontSize: 13,
                  fontWeight: FontWeight.w800),
            ),
        ],
      ),
    );
  }
}

class _LineupsRow extends StatelessWidget {
  const _LineupsRow({
    required this.homeTeam,
    required this.awayTeam,
    required this.homeLineup,
    required this.awayLineup,
  });
  final String homeTeam;
  final String awayTeam;
  final List<BaseballPlayer> homeLineup;
  final List<BaseballPlayer> awayLineup;

  @override
  Widget build(BuildContext context) {
    if (homeLineup.isEmpty && awayLineup.isEmpty) {
      return const Text('先發名單尚未公布',
          style: TextStyle(color: Colors.white38, fontSize: 12));
    }

    Widget teamBlock(String team, List<BaseballPlayer> lineup,
        {required bool isAway}) {
      final color = isAway ? AppTheme.secondaryAccent : AppTheme.primaryAccent;
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            team,
            style: TextStyle(
                color: color, fontSize: 13, fontWeight: FontWeight.w800),
          ),
          const SizedBox(height: 6),
          ...lineup.map((p) => _LineupPlayerCard(player: p)),
        ],
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // 先攻(客隊)在上，後攻(主隊)在下
        if (awayLineup.isNotEmpty) ...[
          teamBlock(awayTeam, awayLineup, isAway: true),
          const SizedBox(height: 12),
        ],
        if (homeLineup.isNotEmpty)
          teamBlock(homeTeam, homeLineup, isAway: false),
      ],
    );
  }
}

class _LineupPlayerCard extends StatelessWidget {
  const _LineupPlayerCard({required this.player});

  final BaseballPlayer player;

  @override
  Widget build(BuildContext context) {
    final todayLine =
        (player.atBatsToday.isNotEmpty || player.hitsToday.isNotEmpty)
            ? '今日 ${player.atBatsToday.isEmpty ? '-' : player.atBatsToday}-${player.hitsToday.isEmpty ? '0' : player.hitsToday}'
            : '今日 -';
    final seasonLine =
        '本季 ${player.battingAvg.isEmpty ? '-' : player.battingAvg} / 全壘打 ${player.homeRuns.isEmpty ? '0' : player.homeRuns} / 打點 ${player.rbis.isEmpty ? '0' : player.rbis}';

    return Container(
      margin: const EdgeInsets.only(bottom: 6),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.04),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: Colors.white12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              SizedBox(
                width: 22,
                child: Text(
                  '${player.batOrder}',
                  style: const TextStyle(
                      color: Colors.white38,
                      fontSize: 20,
                      fontWeight: FontWeight.w600),
                ),
              ),
              Expanded(
                child: Text(
                  player.name,
                  style: const TextStyle(
                      color: Colors.white,
                      fontSize: 24,
                      fontWeight: FontWeight.w700),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
          const SizedBox(height: 2),
          Text(todayLine,
              style: const TextStyle(color: Colors.white70, fontSize: 16)),
          const SizedBox(height: 4),
          Text(seasonLine,
              style: const TextStyle(color: Colors.white60, fontSize: 14)),
        ],
      ),
    );
  }
}

class _InjuryRow extends StatelessWidget {
  const _InjuryRow({required this.injury});
  final BaseballInjury injury;

  String _statusZh(String status) {
    return switch (status.toLowerCase()) {
      'out' => '無法出賽',
      '10-day-il' || '15-day-il' || '60-day-il' => '傷兵名單',
      'day-to-day' => '觀察中',
      'doubtful' => '出賽困難',
      'questionable' => '出賽存疑',
      'probable' => '可能出賽',
      _ => status.isNotEmpty ? status : '未知',
    };
  }

  @override
  Widget build(BuildContext context) {
    final statusColor = switch (injury.status.toLowerCase()) {
      'out' || '10-day-il' || '15-day-il' || '60-day-il' => Colors.red.shade400,
      'day-to-day' => Colors.orange.shade300,
      _ => Colors.white54,
    };
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        children: [
          Expanded(
            child: Text(
              injury.playerName,
              style: const TextStyle(color: Colors.white70, fontSize: 12),
              overflow: TextOverflow.ellipsis,
            ),
          ),
          const SizedBox(width: 8),
          Text(
            injury.team,
            style:
                const TextStyle(color: Colors.white38, fontSize: 11),
            overflow: TextOverflow.ellipsis,
          ),
          const SizedBox(width: 8),
          Container(
            padding: const EdgeInsets.symmetric(
                horizontal: 7, vertical: 2),
            decoration: BoxDecoration(
              color: statusColor.withValues(alpha: 0.15),
              borderRadius: BorderRadius.circular(5),
              border:
                  Border.all(color: statusColor.withValues(alpha: 0.4)),
            ),
            child: Text(
              _statusZh(injury.status),
              style: TextStyle(
                  color: statusColor,
                  fontSize: 10,
                  fontWeight: FontWeight.w600),
            ),
          ),
        ],
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// 籃球賽事詳情全頁
// ─────────────────────────────────────────────────────────────────────────────
class _BasketballDetailPage extends StatefulWidget {
  const _BasketballDetailPage({
    required this.match,
    required this.eventId,
  });
  final MatchFixture match;
  final String eventId;

  @override
  State<_BasketballDetailPage> createState() => _BasketballDetailPageState();
}

class _BasketballDetailPageState extends State<_BasketballDetailPage>
    with SingleTickerProviderStateMixin {
  BasketballGameDetail? _detail;
  bool _loading = true;
  late final TabController _tabController;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 4, vsync: this);
    _load();
  }

  @override
  void dispose() {
    _tabController.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final detail = await RealDataService.fetchBasketballSummary(widget.eventId);
    final safeDetail = detail ?? _fallbackBasketballDetail(widget.match);
    if (mounted) {
      setState(() {
        _detail = safeDetail;
        _loading = false;
      });
    }
  }

  BasketballGameDetail _fallbackBasketballDetail(MatchFixture match) {
    String recordFromForm(TeamForm form) {
      if (form.seasonRecord.isNotEmpty) return form.seasonRecord;
      final wins = form.lastFiveResults.where((r) => r == '勝').length;
      final losses = form.lastFiveResults.where((r) => r == '負').length;
      if (wins == 0 && losses == 0) return '';
      return '$wins-$losses';
    }

    String lastTenFromForm(TeamForm form) {
      if (form.lastFiveResults.isEmpty) return '';
      final sample = form.lastFiveResults.take(10).toList();
      final wins = sample.where((r) => r == '勝').length;
      final losses = sample.where((r) => r == '負').length;
      return '$wins-$losses';
    }

    String streakFromForm(TeamForm form) {
      if (form.streakDisplay.isNotEmpty) return form.streakDisplay;
      final streak = form.currentStreak;
      if (streak > 0) return '連勝$streak';
      if (streak < 0) return '連敗${streak.abs()}';
      return '';
    }

    return BasketballGameDetail(
      overUnder: match.odds.overLine > 0 ? match.odds.overLine : null,
      overOdds: match.odds.overOdds > 0 ? match.odds.overOdds : null,
      underOdds: match.odds.underOdds > 0 ? match.odds.underOdds : null,
      homeRecord: recordFromForm(match.homeForm),
      awayRecord: recordFromForm(match.awayForm),
      homeStreak: streakFromForm(match.homeForm),
      awayStreak: streakFromForm(match.awayForm),
      homeLast10: lastTenFromForm(match.homeForm),
      awayLast10: lastTenFromForm(match.awayForm),
      homeHomeRecord: '',
      awayHomeRecord: '',
      homeRoadRecord: '',
      awayRoadRecord: '',
      homeLineScores: const [],
      awayLineScores: const [],
      homeLineup: const [],
      awayLineup: const [],
      injuries: const [],
      playerAvgPointsById: const {},
      playerPointsTodayById: const {},
      homeTeamStats: const {},
      awayTeamStats: const {},
      homePlayerEfficiencyRating: 0.0,
      awayPlayerEfficiencyRating: 0.0,
    );
  }

  @override
  Widget build(BuildContext context) {
    final match = widget.match;
    final detail = _detail;
    final isLive = match.status == MatchStatus.live;
    final isCompleted = match.status == MatchStatus.completed;

    return Scaffold(
      backgroundColor: const Color(0xFF0A1020),
      appBar: AppBar(
        backgroundColor: const Color(0xFF0A1020),
        foregroundColor: Colors.white,
        elevation: 0,
        centerTitle: true,
        title: Column(
          children: [
            Text(
              match.league,
              style: const TextStyle(
                  color: Colors.white70, fontSize: 12, fontWeight: FontWeight.w600),
            ),
            if (isLive)
              Text(
                match.progressDetail.isNotEmpty ? match.progressDetail : '直播',
                style: const TextStyle(
                    color: Colors.red, fontSize: 13, fontWeight: FontWeight.w800),
              )
            else if (isCompleted)
              const Text('比賽結束',
                  style: TextStyle(color: Colors.white54, fontSize: 12)),
          ],
        ),
      ),
      bottomNavigationBar: Container(
        color: const Color(0xFF101820),
        child: SafeArea(
          top: false,
          child: TabBar(
            controller: _tabController,
            labelColor: AppTheme.primaryAccent,
            unselectedLabelColor: Colors.white38,
            indicatorColor: AppTheme.primaryAccent,
            indicatorSize: TabBarIndicatorSize.label,
            indicatorWeight: 2.5,
            dividerColor: Colors.white12,
            labelStyle:
                const TextStyle(fontSize: 13, fontWeight: FontWeight.w800),
            unselectedLabelStyle:
                const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
            tabs: const [
              Tab(text: '實況'),
              Tab(text: '先發名單'),
              Tab(text: '傷兵名單'),
              Tab(text: '數據'),
              Tab(text: '推薦'),
            ],
          ),
        ),
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : detail == null
              ? const Center(
                  child: Text('無法載入詳細資料',
                      style: TextStyle(color: Colors.white54)))
              : Column(
                  children: [
                    _BasketballDetailHeader(match: match, detail: detail),
                    const Divider(height: 1, color: Colors.white12),
                    Expanded(
                      child: TabBarView(
                        controller: _tabController,
                        children: [
                          // 賽況頁
                          ListView(
                            padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
                            children: [
                              if (detail.homeLineScores.isNotEmpty ||
                                  detail.awayLineScores.isNotEmpty) ...[
                                _SheetSectionTitle(title: '計分版'),
                                const SizedBox(height: 8),
                                _BasketballLineScoreTable(
                                  match: match,
                                  detail: detail,
                                ),
                                const SizedBox(height: 16),
                              ],
                              if (detail.homeTeamStats.isNotEmpty ||
                                  detail.awayTeamStats.isNotEmpty) ...[
                                _SheetSectionTitle(title: '球隊數據'),
                                const SizedBox(height: 8),
                                _BasketballTeamStatsCard(
                                  match: match,
                                  detail: detail,
                                ),
                                const SizedBox(height: 16),
                              ],
                              if (match.lastPlayText.isNotEmpty) ...[
                                _SheetSectionTitle(title: '最新戰況'),
                                const SizedBox(height: 8),
                                _BaseballLastPlayCard(text: match.lastPlayText),
                              ] else if (detail.homeTeamStats.isEmpty &&
                                  detail.awayTeamStats.isEmpty)
                                const Center(
                                  child: Padding(
                                    padding: EdgeInsets.only(top: 40),
                                    child: Text('暫無即時戰況',
                                        style: TextStyle(
                                            color: Colors.white38, fontSize: 16)),
                                  ),
                                ),
                            ],
                          ),
                          // 先發名單頁
                          ListView(
                            padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
                            children: [
                              _BasketballLineupSection(
                                  match: match, detail: detail),
                            ],
                          ),
                          // 傷兵名單頁
                          detail.injuries.isEmpty
                              ? const Center(
                                  child: Text('目前無傷兵資料',
                                      style: TextStyle(
                                    color: Colors.white38, fontSize: 18)))
                              : ListView(
                                  padding: const EdgeInsets.fromLTRB(
                                      16, 16, 16, 24),
                                  children: detail.injuries
                                  .map((inj) =>
                                    _BasketballInjuryRow(injury: inj))
                                      .toList(),
                                ),
                          // 數據頁
                          ListView(
                            padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
                            children: [
                              _SheetSectionTitle(title: '球隊戰績'),
                              const SizedBox(height: 10),
                              _BasketballTeamRecordCard(
                                  match: match, detail: detail),
                              const SizedBox(height: 20),
                              _SheetSectionTitle(title: '近況'),
                              const SizedBox(height: 10),
                              _BasketballTeamStreakCard(
                                  match: match, detail: detail),
                              const SizedBox(height: 20),
                              if (detail.homeLineup.isNotEmpty ||
                                  detail.awayLineup.isNotEmpty) ...[
                                _SheetSectionTitle(title: '球員近況'),
                                const SizedBox(height: 10),
                                _BasketballPlayerStatsSection(
                                    match: match, detail: detail),
                                const SizedBox(height: 20),
                              ],
                              if (detail.overUnder != null) ...[
                                _SheetSectionTitle(title: '建議總得分'),
                                const SizedBox(height: 8),
                                _BasketballOverUnderCard(detail: detail),
                              ],
                            ],
                          ),
                          // 推薦頁
                          _BasketballRecommendTab(match: match, detail: detail),
                        ],
                      ),
                    ),
                  ],
                ),
    );
  }
}

class _BasketballDetailHeader extends StatelessWidget {
  const _BasketballDetailHeader({required this.match, required this.detail});
  final MatchFixture match;
  final BasketballGameDetail detail;

  @override
  Widget build(BuildContext context) {
    final isLive = match.status == MatchStatus.live;
    final isCompleted = match.status == MatchStatus.completed;

    Widget scoreSide({
      required String team,
      required int score,
      required TextAlign align,
      required Color nameColor,
    }) {
      return Column(
        crossAxisAlignment: align == TextAlign.left
            ? CrossAxisAlignment.start
            : CrossAxisAlignment.end,
        children: [
          Text(
            team,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            textAlign: align,
            style: TextStyle(
                color: nameColor, fontSize: 15, fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 6),
          Text(
            isLive || isCompleted ? '$score' : '--',
            textAlign: align,
            style: const TextStyle(
                color: Colors.white,
                fontSize: 54,
                height: 0.9,
                fontWeight: FontWeight.w900),
          ),
        ],
      );
    }

    return Container(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 18),
      color: const Color(0xFF0A1020),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: scoreSide(
              team: match.awayTeam,
              score: match.awayScore,
              align: TextAlign.left,
              nameColor: AppTheme.secondaryAccent,
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 12, 12, 0),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Text('🏀', style: TextStyle(fontSize: 22)),
                const SizedBox(height: 4),
                Text(
                  isLive
                      ? (match.progressDetail.isNotEmpty
                          ? match.progressDetail
                          : '直播')
                      : isCompleted
                          ? '完賽'
                          : '對',
                  style: TextStyle(
                    color: isLive ? Colors.red : Colors.white54,
                    fontSize: 11,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ],
            ),
          ),
          Expanded(
            child: scoreSide(
              team: match.homeTeam,
              score: match.homeScore,
              align: TextAlign.right,
              nameColor: AppTheme.primaryAccent,
            ),
          ),
        ],
      ),
    );
  }
}

class _BasketballTeamStatsCard extends StatelessWidget {
  const _BasketballTeamStatsCard(
      {required this.match, required this.detail});
  final MatchFixture match;
  final BasketballGameDetail detail;

  static const _labelZh = <String, String>{
    'PTS': '得分',
    'FG': '投籃',
    'FGA': '投籃次',
    'FGM': '投籃中',
    'FG%': '投籃%',
    '3PT': '三分球',
    '3PTA': '三分次',
    '3PTM': '三分中',
    '3PT%': '三分%',
    'FT': '罰球',
    'FTA': '罰球次',
    'FTM': '罰球中',
    'FT%': '罰球%',
    'REB': '籃板',
    'OREB': '進攻籃板',
    'DREB': '防守籃板',
    'AST': '助攻',
    'STL': '抄截',
    'BLK': '阻攻',
    'TO': '失誤',
    'PF': '犯規',
  };
  static const _order = [
    'PTS', 'FG', 'FGA', 'FGM', 'FG%',
    '3PT', '3PTA', '3PTM', '3PT%',
    'FT', 'FTA', 'FTM', 'FT%',
    'REB', 'OREB', 'DREB',
    'AST', 'STL', 'BLK', 'TO', 'PF'
  ];

  @override
  Widget build(BuildContext context) {
    final home = detail.homeTeamStats;
    final away = detail.awayTeamStats;
    final allKeys = <String>{
      ...home.keys,
      ...away.keys,
    }.where((k) => _labelZh.containsKey(k)).toList()
      ..sort((a, b) {
        final ai = _order.indexOf(a);
        final bi = _order.indexOf(b);
        if (ai == -1 && bi == -1) return a.compareTo(b);
        if (ai == -1) return 1;
        if (bi == -1) return -1;
        return ai.compareTo(bi);
      });
    if (allKeys.isEmpty) return const SizedBox.shrink();

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        color: const Color(0xFF131C31),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  match.awayTeam,
                  style: const TextStyle(
                      color: AppTheme.secondaryAccent,
                      fontSize: 12,
                      fontWeight: FontWeight.w700),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              const SizedBox(
                  width: 80,
                  child: Center(
                      child: Text('項目',
                          style: TextStyle(
                              color: Colors.white38, fontSize: 11)))),
              Expanded(
                child: Text(
                  match.homeTeam,
                  textAlign: TextAlign.right,
                  style: const TextStyle(
                      color: AppTheme.primaryAccent,
                      fontSize: 12,
                      fontWeight: FontWeight.w700),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
          const Divider(color: Colors.white12, height: 14),
          for (final key in allKeys)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 5),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      away[key] ?? '-',
                      style: const TextStyle(
                          color: Colors.white,
                          fontSize: 14,
                          fontWeight: FontWeight.w700),
                    ),
                  ),
                  SizedBox(
                    width: 80,
                    child: Center(
                      child: Text(
                        _labelZh[key] ?? key,
                        style: const TextStyle(
                            color: Colors.white54, fontSize: 11),
                      ),
                    ),
                  ),
                  Expanded(
                    child: Text(
                      home[key] ?? '-',
                      textAlign: TextAlign.right,
                      style: const TextStyle(
                          color: Colors.white,
                          fontSize: 14,
                          fontWeight: FontWeight.w700),
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

class _BasketballLineScoreTable extends StatelessWidget {
  const _BasketballLineScoreTable({required this.match, required this.detail});

  final MatchFixture match;
  final BasketballGameDetail detail;

  int _sumPoints(List<BasketballLineScore> scores) {
    var total = 0;
    for (final s in scores) {
      total += int.tryParse(s.points) ?? 0;
    }
    return total;
  }

  @override
  Widget build(BuildContext context) {
    final periodCount =
        math.max(detail.awayLineScores.length, detail.homeLineScores.length);
    if (periodCount == 0) {
      return const SizedBox.shrink();
    }

    Widget cell(
      String text, {
      double width = 42,
      bool header = false,
      bool emphasize = false,
      TextAlign align = TextAlign.center,
    }) {
      return SizedBox(
        width: width,
        child: Text(
          text,
          textAlign: align,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            color: header
                ? Colors.white70
                : emphasize
                    ? Colors.white
                    : Colors.white60,
            fontSize: header ? 11 : 13,
            fontWeight: emphasize ? FontWeight.w800 : FontWeight.w600,
          ),
        ),
      );
    }

    Widget teamRow({
      required String team,
      required List<BasketballLineScore> lineScores,
      required Color teamColor,
      required int total,
    }) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: Row(
          children: [
            Expanded(
              child: Text(
                team,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: teamColor,
                  fontSize: 13,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
            for (var i = 0; i < periodCount; i++)
              cell(i < lineScores.length ? lineScores[i].points : '-'),
            cell('$total', width: 46, emphasize: true),
          ],
        ),
      );
    }

    final awayTotal =
        (match.status == MatchStatus.live || match.status == MatchStatus.completed)
            ? match.awayScore
            : _sumPoints(detail.awayLineScores);
    final homeTotal =
        (match.status == MatchStatus.live || match.status == MatchStatus.completed)
            ? match.homeScore
            : _sumPoints(detail.homeLineScores);

    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: const Color(0xFF131C31),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        children: [
          Row(
            children: [
              const Expanded(
                child: Text(
                  '球隊',
                  style: TextStyle(
                    color: Colors.white70,
                    fontSize: 11,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              for (var i = 0; i < periodCount; i++)
                cell('Q${i + 1}', header: true),
              cell('總分', width: 46, header: true),
            ],
          ),
          const Divider(color: Colors.white12, height: 14),
          teamRow(
            team: match.awayTeam,
            lineScores: detail.awayLineScores,
            teamColor: AppTheme.secondaryAccent,
            total: awayTotal,
          ),
          teamRow(
            team: match.homeTeam,
            lineScores: detail.homeLineScores,
            teamColor: AppTheme.primaryAccent,
            total: homeTotal,
          ),
        ],
      ),
    );
  }
}

class _BasketballLineupSection extends StatelessWidget {
  const _BasketballLineupSection({required this.match, required this.detail});
  final MatchFixture match;
  final BasketballGameDetail detail;

  @override
  Widget build(BuildContext context) {
    if (detail.homeLineup.isEmpty && detail.awayLineup.isEmpty) {
      return const Text('先發名單尚未公布',
          style: TextStyle(color: Colors.white38, fontSize: 16));
    }

    Widget teamBlock(String team, List<BasketballPlayer> lineup,
        {required bool isAway}) {
      final color = isAway ? AppTheme.secondaryAccent : AppTheme.primaryAccent;
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(team,
              style: TextStyle(
                color: color, fontSize: 16, fontWeight: FontWeight.w800)),
          const SizedBox(height: 6),
            ...lineup.map((p) => _BasketballPlayerCard(
              player: p,
              isLive: match.status == MatchStatus.live ||
                match.status == MatchStatus.completed)),
        ],
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (detail.awayLineup.isNotEmpty) ...[
          teamBlock(match.awayTeam, detail.awayLineup, isAway: true),
          const SizedBox(height: 16),
        ],
        if (detail.homeLineup.isNotEmpty)
          teamBlock(match.homeTeam, detail.homeLineup, isAway: false),
      ],
    );
  }
}

class _BasketballPlayerCard extends StatelessWidget {
  const _BasketballPlayerCard(
      {required this.player, required this.isLive});
  final BasketballPlayer player;
  final bool isLive;

  @override
  Widget build(BuildContext context) {
    final seasonLine = [
      if (player.avgPoints.isNotEmpty) '${player.avgPoints} 分',
      if (player.avgRebounds.isNotEmpty) '${player.avgRebounds} 籃板',
      if (player.avgAssists.isNotEmpty) '${player.avgAssists} 助攻',
    ].join(' / ');

    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.04),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: Colors.white12),
      ),
      child: Row(
        children: [
          if (player.jerseyNumber.isNotEmpty)
            SizedBox(
              width: 32,
              child: Text(
                '#${player.jerseyNumber}',
                style: const TextStyle(
                    color: Colors.white38,
                    fontSize: 15,
                    fontWeight: FontWeight.w700),
              ),
            ),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        player.name,
                        style: const TextStyle(
                            color: Colors.white,
                          fontSize: 18,
                            fontWeight: FontWeight.w700),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    if (player.position.isNotEmpty)
                      Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 6, vertical: 2),
                        decoration: BoxDecoration(
                          color: Colors.white.withValues(alpha: 0.06),
                          borderRadius: BorderRadius.circular(4),
                        ),
                        child: Text(player.position,
                            style: const TextStyle(
                            color: Colors.white54, fontSize: 13)),
                      ),
                  ],
                ),
                const SizedBox(height: 3),
                if (isLive && player.pointsToday.isNotEmpty)
                  Text('今日 ${player.pointsToday} 分',
                      style: const TextStyle(
                          color: Color(0xFFFFB300), fontSize: 15))
                else if (seasonLine.isNotEmpty)
                  Text('場均 $seasonLine',
                      style: const TextStyle(
                          color: Colors.white54, fontSize: 14)),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _BasketballTeamRecordCard extends StatelessWidget {
  const _BasketballTeamRecordCard(
      {required this.match, required this.detail});
  final MatchFixture match;
  final BasketballGameDetail detail;

  bool _hasMeaningfulValue(String value) {
    final v = value.trim();
    if (v.isEmpty) return false;
    const placeholders = {'-', '--', 'N/A', 'n/a', 'na', 'NA'};
    return !placeholders.contains(v);
  }

  String _fallbackRecord(TeamForm form) {
    if (form.seasonRecord.isNotEmpty) return form.seasonRecord;
    final wins = form.lastFiveResults.where((r) => r == '勝').length;
    final losses = form.lastFiveResults.where((r) => r == '負').length;
    if (wins == 0 && losses == 0) return '';
    return '$wins-$losses';
  }

  @override
  Widget build(BuildContext context) {
    Widget side({
      required String team,
      required String record,
      required Color nameColor,
      required TextAlign align,
    }) {
      final parts = record.split('-');
      final wins = parts.isNotEmpty ? parts[0] : '-';
      final losses = parts.length > 1 ? parts[1] : '-';
      return Expanded(
        child: Column(
          crossAxisAlignment: align == TextAlign.left
              ? CrossAxisAlignment.start
              : CrossAxisAlignment.end,
          children: [
            Text(team,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                textAlign: align,
                style: TextStyle(
                    color: nameColor,
                    fontSize: 13,
                    fontWeight: FontWeight.w700)),
            const SizedBox(height: 6),
            Text(
              record.isNotEmpty ? record : '-',
              textAlign: align,
              style: const TextStyle(
                  color: Colors.white,
                  fontSize: 28,
                  fontWeight: FontWeight.w900,
                  height: 1),
            ),
            const SizedBox(height: 4),
            Text(
              record.isNotEmpty ? '$wins 勝 $losses 敗' : '--',
              textAlign: align,
              style: const TextStyle(
                  color: Colors.white54,
                  fontSize: 14,
                  fontWeight: FontWeight.w600),
            ),
          ],
        ),
      );
    }

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
          color: const Color(0xFF131C31),
          borderRadius: BorderRadius.circular(16)),
      child: Row(
        children: [
          side(
            team: match.awayTeam,
            record: _hasMeaningfulValue(detail.awayRecord)
                ? detail.awayRecord
                : _fallbackRecord(match.awayForm),
            nameColor: AppTheme.secondaryAccent,
            align: TextAlign.left,
          ),
          const SizedBox(
            width: 40,
            child: Center(
              child: Text('對',
                  style: TextStyle(
                      color: Colors.white38,
                      fontSize: 14,
                      fontWeight: FontWeight.w600)),
            ),
          ),
          side(
            team: match.homeTeam,
            record: _hasMeaningfulValue(detail.homeRecord)
                ? detail.homeRecord
                : _fallbackRecord(match.homeForm),
            nameColor: AppTheme.primaryAccent,
            align: TextAlign.right,
          ),
        ],
      ),
    );
  }
}

class _BasketballTeamStreakCard extends StatelessWidget {
  const _BasketballTeamStreakCard(
      {required this.match, required this.detail});
  final MatchFixture match;
  final BasketballGameDetail detail;

  bool _hasMeaningfulValue(String value) {
    final v = value.trim();
    if (v.isEmpty) return false;
    const placeholders = {'-', '--', 'N/A', 'n/a', 'na', 'NA'};
    return !placeholders.contains(v);
  }

  String _fallbackLastTen(TeamForm form) {
    if (form.lastFiveResults.isEmpty) return '';
    final sample = form.lastFiveResults.take(10).toList();
    final wins = sample.where((r) => r == '勝').length;
    final losses = sample.where((r) => r == '負').length;
    return '$wins-$losses';
  }

  String _fallbackStreak(TeamForm form) {
    if (form.streakDisplay.isNotEmpty) return form.streakDisplay;
    final streak = form.currentStreak;
    if (streak > 0) return '連勝$streak';
    if (streak < 0) return '連敗${streak.abs()}';
    return '';
  }

  String _lastTenWinRate(String summary) {
    final parts = summary.split('-');
    if (parts.length < 2) return '';
    final wins = int.tryParse(parts[0]);
    final losses = int.tryParse(parts[1]);
    if (wins == null || losses == null) return '';
    final games = wins + losses;
    if (games <= 0) return '';
    final pct = (wins / games * 100).toStringAsFixed(0);
    return '$pct%';
  }

  Color _streakColor(String streak) {
    if (streak.startsWith('連勝')) return AppTheme.primaryAccent;
    if (streak.startsWith('連敗')) return Colors.redAccent;
    return Colors.white54;
  }

  @override
  Widget build(BuildContext context) {
    Widget streakSide({
      required String team,
      required Color teamColor,
      required String streak,
      required String last10,
      required String homeRec,
      required String roadRec,
      required CrossAxisAlignment cross,
    }) {
      final sc = _streakColor(streak);
      return Expanded(
        child: Column(
          crossAxisAlignment: cross,
          children: [
            Text(team,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                    color: teamColor,
                    fontSize: 11,
                    fontWeight: FontWeight.w700)),
            const SizedBox(height: 6),
            if (streak.isNotEmpty) ...[
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                decoration: BoxDecoration(
                  color: sc.withValues(alpha: 0.15),
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: sc.withValues(alpha: 0.5)),
                ),
                child: Text(
                  streak,
                  style: TextStyle(
                      color: sc, fontSize: 14, fontWeight: FontWeight.w800),
                ),
              ),
              const SizedBox(height: 8),
            ],
            if (last10.isNotEmpty) _statRow('近10場', last10, cross),
            if (last10.isNotEmpty)
              _statRow('近10勝率', _lastTenWinRate(last10), cross),
            if (homeRec.isNotEmpty) _statRow('主場', homeRec, cross),
            if (roadRec.isNotEmpty) _statRow('客場', roadRec, cross),
          ],
        ),
      );
    }

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
          color: const Color(0xFF131C31),
          borderRadius: BorderRadius.circular(16)),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          streakSide(
            team: match.awayTeam,
            teamColor: AppTheme.secondaryAccent,
            streak: _hasMeaningfulValue(detail.awayStreak)
                ? detail.awayStreak
                : _fallbackStreak(match.awayForm),
            last10: _hasMeaningfulValue(detail.awayLast10)
                ? detail.awayLast10
                : _fallbackLastTen(match.awayForm),
            homeRec: detail.awayHomeRecord,
            roadRec: detail.awayRoadRecord,
            cross: CrossAxisAlignment.start,
          ),
          Container(
              width: 1,
              height: 80,
              color: Colors.white12,
              margin: const EdgeInsets.symmetric(horizontal: 12)),
          streakSide(
            team: match.homeTeam,
            teamColor: AppTheme.primaryAccent,
            streak: _hasMeaningfulValue(detail.homeStreak)
                ? detail.homeStreak
                : _fallbackStreak(match.homeForm),
            last10: _hasMeaningfulValue(detail.homeLast10)
                ? detail.homeLast10
                : _fallbackLastTen(match.homeForm),
            homeRec: detail.homeHomeRecord,
            roadRec: detail.homeRoadRecord,
            cross: CrossAxisAlignment.end,
          ),
        ],
      ),
    );
  }

  Widget _statRow(String label, String value, CrossAxisAlignment cross) {
    final row = Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text('$label  ',
            style: const TextStyle(color: Colors.white54, fontSize: 12)),
        Text(value,
            style: const TextStyle(
                color: Colors.white,
                fontSize: 13,
                fontWeight: FontWeight.w700)),
      ],
    );
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: cross == CrossAxisAlignment.end
          ? Row(mainAxisAlignment: MainAxisAlignment.end, children: [row])
          : row,
    );
  }
}

class _BasketballPlayerStatsSection extends StatelessWidget {
  const _BasketballPlayerStatsSection(
      {required this.match, required this.detail});
  final MatchFixture match;
  final BasketballGameDetail detail;

  @override
  Widget build(BuildContext context) {
    final isLive = match.status == MatchStatus.live ||
        match.status == MatchStatus.completed;

    Widget teamHeader(String team, Color color) {
      return Padding(
        padding: const EdgeInsets.only(bottom: 6),
        child: Text(team,
            style: TextStyle(
                color: color, fontSize: 13, fontWeight: FontWeight.w800)),
      );
    }

    Widget playerRow(BasketballPlayer p) {
      final pts = detail.playerPointsTodayById[p.playerId] ?? p.pointsToday;
      final avg = detail.playerAvgPointsById[p.playerId] ?? p.avgPoints;
      String statText;
      if (isLive && pts.isNotEmpty) {
        final ptsNum = double.tryParse(pts);
        final avgNum = double.tryParse(avg);
        if (ptsNum != null && avgNum != null) {
          if (ptsNum >= avgNum + 5) {
            statText = '今日 $pts 分 | 近況火燙';
          } else if (ptsNum <= avgNum - 5) {
            statText = '今日 $pts 分 | 近況偏冷';
          } else {
            statText = '今日 $pts 分 | 近況穩定';
          }
        } else {
          statText = '今日 $pts 分';
        }
      } else if (avg.isNotEmpty) {
        statText = '場均 $avg 分 | 近況待觀察';
      } else {
        statText = p.position;
      }
      return Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: Row(
          children: [
            Container(
              width: 28,
              height: 22,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: Colors.white.withValues(alpha: 0.06),
                borderRadius: BorderRadius.circular(4),
              ),
              child: Text(
                p.jerseyNumber.isNotEmpty
                    ? '#${p.jerseyNumber}'
                    : p.position.isNotEmpty
                        ? p.position
                        : '-',
                style: const TextStyle(
                    color: Colors.white54,
                    fontSize: 10,
                    fontWeight: FontWeight.w700),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(p.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                      color: Colors.white,
                      fontSize: 13,
                      fontWeight: FontWeight.w600)),
            ),
            Text(statText,
                style: const TextStyle(color: Colors.white54, fontSize: 12)),
          ],
        ),
      );
    }

    return Container(
      padding: const EdgeInsets.fromLTRB(14, 14, 14, 10),
      decoration: BoxDecoration(
          color: const Color(0xFF131C31),
          borderRadius: BorderRadius.circular(16)),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (detail.awayLineup.isNotEmpty) ...[
            teamHeader(match.awayTeam, AppTheme.secondaryAccent),
            ...detail.awayLineup.map(playerRow),
          ],
          if (detail.homeLineup.isNotEmpty) ...[
            const SizedBox(height: 12),
            const Divider(color: Colors.white12, height: 1),
            const SizedBox(height: 12),
            teamHeader(match.homeTeam, AppTheme.primaryAccent),
            ...detail.homeLineup.map(playerRow),
          ],
        ],
      ),
    );
  }
}

class _BasketballInjuryRow extends StatelessWidget {
  const _BasketballInjuryRow({required this.injury});

  final BaseballInjury injury;

  String _statusZh(String status) {
    return switch (status.toLowerCase()) {
      'out' => '無法出賽',
      'day-to-day' => '觀察中',
      'doubtful' => '出賽困難',
      'questionable' => '出賽存疑',
      'probable' => '可能出賽',
      _ => status.isNotEmpty ? status : '未知',
    };
  }

  @override
  Widget build(BuildContext context) {
    final statusColor = switch (injury.status.toLowerCase()) {
      'out' || 'day-to-day' || 'doubtful' || 'questionable' => Colors.orange.shade300,
      _ => Colors.white54,
    };

    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.04),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: Colors.white12),
      ),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  injury.playerName,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 17,
                    fontWeight: FontWeight.w700,
                  ),
                  overflow: TextOverflow.ellipsis,
                ),
                const SizedBox(height: 4),
                Text(
                  injury.team,
                  style: const TextStyle(
                    color: Colors.white60,
                    fontSize: 14,
                    fontWeight: FontWeight.w500,
                  ),
                  overflow: TextOverflow.ellipsis,
                ),
                if (injury.description.isNotEmpty) ...[
                  const SizedBox(height: 4),
                  Text(
                    injury.description,
                    style: const TextStyle(color: Colors.white54, fontSize: 13),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ],
            ),
          ),
          const SizedBox(width: 8),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
            decoration: BoxDecoration(
              color: statusColor.withValues(alpha: 0.15),
              borderRadius: BorderRadius.circular(6),
              border: Border.all(color: statusColor.withValues(alpha: 0.4)),
            ),
            child: Text(
              _statusZh(injury.status),
              style: TextStyle(
                color: statusColor,
                fontSize: 12,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _BasketballOverUnderCard extends StatelessWidget {
  const _BasketballOverUnderCard({required this.detail});
  final BasketballGameDetail detail;

  @override
  Widget build(BuildContext context) {
    final ou = detail.overUnder!;
    final overOdds = detail.overOdds;
    final underOdds = detail.underOdds;
    final String suggestion;
    if (overOdds != null && underOdds != null) {
      suggestion = overOdds > underOdds
          ? '建議下「大」($ou 分以上)'
          : '建議下「小」($ou 分以下)';
    } else {
      suggestion = '建議總得分線：$ou 分';
    }
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
          color: const Color(0xFF131C31),
          borderRadius: BorderRadius.circular(16)),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(suggestion,
              style: const TextStyle(
                  color: AppTheme.primaryAccent,
                  fontSize: 16,
                  fontWeight: FontWeight.w800)),
          const SizedBox(height: 6),
          Row(
            children: [
              _OUOddsChip(
                  label: '大 (Over)',
                  odds: overOdds,
                  active: overOdds != null &&
                      underOdds != null &&
                      overOdds > underOdds),
              const SizedBox(width: 10),
              _OUOddsChip(
                  label: '小 (Under)',
                  odds: underOdds,
                  active: overOdds != null &&
                      underOdds != null &&
                      underOdds > overOdds),
            ],
          ),
        ],
      ),
    );
  }
}

// ─────────────────────────────────────────────
// 籃球「推薦」分頁
// ─────────────────────────────────────────────
class _BasketballRecommendTab extends StatelessWidget {
  const _BasketballRecommendTab({required this.match, this.detail});
  final MatchFixture match;
  final BasketballGameDetail? detail;

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 20, 16, 32),
      children: [
        PredictionBreakdownCard(
          fixture: match,
          prediction: PangPangSportsService().predictMatch(match),
        ),
      ],
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// 足球賽事詳情全頁
// ─────────────────────────────────────────────────────────────────────────────
class _SoccerDetailPage extends StatefulWidget {
  const _SoccerDetailPage({
    required this.match,
    required this.eventId,
    required this.leagueSlug,
  });
  final MatchFixture match;
  final String eventId;
  final String leagueSlug;

  @override
  State<_SoccerDetailPage> createState() => _SoccerDetailPageState();
}

class _SoccerDetailPageState extends State<_SoccerDetailPage>
    with SingleTickerProviderStateMixin {
  SoccerGameDetail? _detail;
  bool _loading = true;
  late final TabController _tabController;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 4, vsync: this);
    _load();
  }

  @override
  void dispose() {
    _tabController.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final detail = await RealDataService.fetchSoccerSummary(
        widget.eventId, widget.leagueSlug);
    if (mounted) setState(() { _detail = detail; _loading = false; });
  }

  @override
  Widget build(BuildContext context) {
    final match = widget.match;
    final detail = _detail;
    final isLive = match.status == MatchStatus.live;
    final isCompleted = match.status == MatchStatus.completed;

    return Scaffold(
      backgroundColor: const Color(0xFF0A1020),
      appBar: AppBar(
        backgroundColor: const Color(0xFF0A1020),
        foregroundColor: Colors.white,
        elevation: 0,
        centerTitle: true,
        title: Column(
          children: [
            Text(
              match.league,
              style: const TextStyle(
                  color: Colors.white70, fontSize: 12, fontWeight: FontWeight.w600),
            ),
            if (isLive)
              Text(
                match.progressDetail.isNotEmpty ? match.progressDetail : '直播',
                style: const TextStyle(
                    color: Colors.red, fontSize: 13, fontWeight: FontWeight.w800),
              )
            else if (isCompleted)
              const Text('比賽結束',
                  style: TextStyle(color: Colors.white54, fontSize: 12)),
          ],
        ),
      ),
      bottomNavigationBar: Container(
        color: const Color(0xFF101820),
        child: SafeArea(
          top: false,
          child: TabBar(
            controller: _tabController,
            labelColor: AppTheme.primaryAccent,
            unselectedLabelColor: Colors.white38,
            indicatorColor: AppTheme.primaryAccent,
            indicatorSize: TabBarIndicatorSize.label,
            indicatorWeight: 2.5,
            dividerColor: Colors.white12,
            labelStyle:
                const TextStyle(fontSize: 13, fontWeight: FontWeight.w800),
            unselectedLabelStyle:
                const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
            tabs: const [
              Tab(text: '實況'),
              Tab(text: '先發名單'),
              Tab(text: '傷兵/禁賽'),
              Tab(text: '數據'),
            ],
          ),
        ),
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator(
              valueColor: AlwaysStoppedAnimation<Color>(AppTheme.primaryAccent)))
          : Column(
              children: [
                _SoccerDetailHeader(match: match, detail: detail),
                const Divider(height: 1, color: Colors.white12),
                Expanded(
                  child: TabBarView(
                    controller: _tabController,
                    children: [
                      // ── 實況 tab ──────────────────────────────────────
                      ListView(
                        padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
                        children: [
                          _SoccerPitchWidget(match: match, detail: detail),
                          const SizedBox(height: 20),
                          if (detail != null &&
                              (detail.homeFirstHalf >= 0 ||
                                  detail.homeSecondHalf >= 0)) ...[
                            _SheetSectionTitle(title: '半場比分'),
                            const SizedBox(height: 10),
                            _SoccerHalfScoreCard(match: match, detail: detail),
                            const SizedBox(height: 20),
                          ],
                          if (detail != null && detail.events.isNotEmpty) ...[
                            _SheetSectionTitle(title: '賽事紀錄'),
                            const SizedBox(height: 10),
                            ...detail.events.map(
                                (e) => _SoccerEventTile(event: e, match: match)),
                          ] else if (detail != null)
                            const Center(
                              child: Padding(
                                padding: EdgeInsets.only(top: 20),
                                child: Text('暫無賽事紀錄',
                                    style: TextStyle(
                                        color: Colors.white38, fontSize: 14)),
                              ),
                            ),
                        ],
                      ),
                      // ── 先發名單 tab ──────────────────────────────────
                      detail == null
                          ? const Center(
                              child: Text('無法載入先發資料',
                                  style: TextStyle(
                                      color: Colors.white38, fontSize: 14)))
                          : ListView(
                              padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
                              children: [
                                _SoccerLineupSection(
                                    match: match, detail: detail),
                              ],
                            ),
                      // ── 傷兵 & 禁賽 tab ───────────────────────────────
                      Builder(builder: (context) {
                        final allInjuries = detail?.injuries ?? [];
                        final suspensions = detail?.suspensions ?? [];
                        // 分開真正傷兵 vs 未入選名單
                        final realInjuries = allInjuries.where((i) => i.status != '未入選').toList();
                        final absentPlayers = allInjuries.where((i) => i.status == '未入選').toList();
                        // 按隊伍分組缺席球員
                        final homeAbsent = absentPlayers.where((i) {
                          final ht = match.homeTeam.toLowerCase();
                          return i.team.toLowerCase().contains(ht) || ht.contains(i.team.toLowerCase());
                        }).toList();
                        final awayAbsent = absentPlayers.where((i) {
                          final at = match.awayTeam.toLowerCase();
                          return i.team.toLowerCase().contains(at) || at.contains(i.team.toLowerCase());
                        }).toList();
                        // 如果按名稱沒分好，就用簡單方式：前半 home，後半 away
                        final List<BaseballInjury> homeAbs;
                        final List<BaseballInjury> awayAbs;
                        if (homeAbsent.isEmpty && awayAbsent.isEmpty && absentPlayers.isNotEmpty) {
                          // fallback: group by team name
                          final byTeam = <String, List<BaseballInjury>>{};
                          for (final p in absentPlayers) {
                            byTeam.putIfAbsent(p.team, () => []).add(p);
                          }
                          final teams = byTeam.keys.toList();
                          homeAbs = teams.isNotEmpty ? byTeam[teams[0]]! : [];
                          awayAbs = teams.length > 1 ? byTeam[teams[1]]! : [];
                        } else {
                          homeAbs = homeAbsent;
                          awayAbs = awayAbsent;
                        }
                        if (allInjuries.isEmpty && suspensions.isEmpty) {
                          return const Center(
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Text('目前無傷兵 / 禁賽資料',
                                    style: TextStyle(
                                        color: Colors.white38, fontSize: 16)),
                                SizedBox(height: 8),
                                Text('比賽名單尚未公布或聯賽無相關資料',
                                    textAlign: TextAlign.center,
                                    style: TextStyle(
                                        color: Colors.white24, fontSize: 12)),
                              ],
                            ),
                          );
                        }
                        return ListView(
                          padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
                          children: [
                            if (realInjuries.isNotEmpty) ...[
                              _SheetSectionTitle(title: '⚕ 傷兵名單'),
                              const SizedBox(height: 8),
                              ...realInjuries.map((inj) => _SoccerInjuryRow(injury: inj)),
                              const SizedBox(height: 16),
                            ],
                            if (suspensions.isNotEmpty) ...[
                              _SheetSectionTitle(title: '🟥 禁賽名單'),
                              const SizedBox(height: 8),
                              ...suspensions.map((s) => _SoccerSuspensionRow(suspension: s)),
                              const SizedBox(height: 16),
                            ],
                            if (absentPlayers.isNotEmpty) ...[
                              _SheetSectionTitle(title: '🚫 未入選本場名單'),
                              const SizedBox(height: 4),
                              const Padding(
                                padding: EdgeInsets.only(bottom: 8),
                                child: Text('以下球員在隊伍名冊中，但未列入本場比賽名單',
                                    style: TextStyle(color: Colors.white24, fontSize: 11)),
                              ),
                              if (homeAbs.isNotEmpty) ...[
                                Padding(
                                  padding: const EdgeInsets.only(top: 4, bottom: 6),
                                  child: Text(homeAbs.first.team,
                                      style: const TextStyle(
                                          color: Colors.white54,
                                          fontSize: 13,
                                          fontWeight: FontWeight.w600)),
                                ),
                                ...homeAbs.map((p) => _SoccerAbsentRow(injury: p)),
                                const SizedBox(height: 12),
                              ],
                              if (awayAbs.isNotEmpty) ...[
                                Padding(
                                  padding: const EdgeInsets.only(top: 4, bottom: 6),
                                  child: Text(awayAbs.first.team,
                                      style: const TextStyle(
                                          color: Colors.white54,
                                          fontSize: 13,
                                          fontWeight: FontWeight.w600)),
                                ),
                                ...awayAbs.map((p) => _SoccerAbsentRow(injury: p)),
                              ],
                            ],
                          ],
                        );
                      }),
                      // ── 數據 tab ──────────────────────────────────────
                      Builder(builder: (_) {
                        return ListView(
                          padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
                          children: [
                            PredictionBreakdownCard(
                              fixture: match,
                              prediction: PangPangSportsService().predictMatch(match),
                            ),
                            const SizedBox(height: 20),
                            _SheetSectionTitle(title: '球隊戰績'),
                            const SizedBox(height: 10),
                            _SoccerRecordCard(match: match, detail: detail),
                            const SizedBox(height: 20),
                            if (detail != null &&
                                (detail.homeTeamStats.isNotEmpty ||
                                    detail.awayTeamStats.isNotEmpty)) ...[
                              _SheetSectionTitle(title: '比賽數據'),
                              const SizedBox(height: 10),
                              _SoccerStatsCompare(match: match, detail: detail),
                            ] else
                              const Center(
                                child: Text('暫無數據',
                                    style: TextStyle(
                                        color: Colors.white38, fontSize: 14)),
                              ),
                          ],
                        );
                      }),
                    ],
                  ),
                ),
              ],
            ),
    );
  }
}

// ── 足球比分頭部 ──────────────────────────────────────────────────
class _SoccerDetailHeader extends StatelessWidget {
  const _SoccerDetailHeader({required this.match, this.detail});
  final MatchFixture match;
  final SoccerGameDetail? detail;

  @override
  Widget build(BuildContext context) {
    final isLive = match.status == MatchStatus.live;
    final isCompleted = match.status == MatchStatus.completed;
    final showScore = isLive || isCompleted;

    return Container(
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 18),
      color: const Color(0xFF0A1020),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  match.awayTeam,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: AppTheme.secondaryAccent,
                    fontSize: 15,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                if (detail?.awayRecord.isNotEmpty == true)
                  Text(detail!.awayRecord,
                      style: const TextStyle(color: Colors.white38, fontSize: 11)),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Column(
              children: [
                Text(
                  showScore
                      ? '${match.awayScore}  -  ${match.homeScore}'
                      : '對',
                  style: TextStyle(
                    color: isLive ? Colors.red : showScore ? Colors.white : AppTheme.highlight,
                    fontSize: showScore ? 30 : 18,
                    fontWeight: FontWeight.w900,
                    letterSpacing: 2,
                  ),
                ),
                if (isLive && match.progressDetail.isNotEmpty)
                  Text(match.progressDetail,
                      style: const TextStyle(
                          color: Colors.red, fontSize: 12, fontWeight: FontWeight.w700))
                else if (!showScore) ...[
                  const SizedBox(height: 4),
                  Builder(builder: (_) {
                    final tw = match.startTime.toUtc().add(const Duration(hours: 8));
                    return Text(
                      '${tw.month}/${tw.day} ${tw.hour.toString().padLeft(2, '0')}:${tw.minute.toString().padLeft(2, '0')}',
                      style: const TextStyle(
                          color: AppTheme.primaryAccent, fontSize: 12),
                    );
                  }),
                ],
              ],
            ),
          ),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Text(
                  match.homeTeam,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  textAlign: TextAlign.right,
                  style: const TextStyle(
                    color: AppTheme.primaryAccent,
                    fontSize: 15,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                if (detail?.homeRecord.isNotEmpty == true)
                  Text(detail!.homeRecord,
                      style: const TextStyle(color: Colors.white38, fontSize: 11)),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

// ── 足球球場可視化 ─────────────────────────────────────────────────
class _SoccerPitchWidget extends StatefulWidget {
  const _SoccerPitchWidget({required this.match, this.detail});
  final MatchFixture match;
  final SoccerGameDetail? detail;

  @override
  State<_SoccerPitchWidget> createState() => _SoccerPitchWidgetState();
}

class _SoccerPitchWidgetState extends State<_SoccerPitchWidget>
    with TickerProviderStateMixin {
  late AnimationController _pulseCtrl;
  late Animation<double> _pulseAnim;
  late AnimationController _moveCtrl;
  late Animation<Offset> _moveAnim;

  Offset _ballTarget = const Offset(0.50, 0.50);
  String _eventLabel = '';

  @override
  void initState() {
    super.initState();
    _pulseCtrl = AnimationController(
        vsync: this, duration: const Duration(milliseconds: 1200))
      ..repeat(reverse: true);
    _pulseAnim = Tween<double>(begin: 0.3, end: 1.0)
        .animate(CurvedAnimation(parent: _pulseCtrl, curve: Curves.easeInOut));

    _moveCtrl = AnimationController(
        vsync: this, duration: const Duration(milliseconds: 900));
    final initPos = _deriveBallPos();
    _ballTarget = initPos.$1;
    _eventLabel = initPos.$2;
    _moveAnim = Tween<Offset>(begin: initPos.$1, end: initPos.$1)
        .animate(CurvedAnimation(parent: _moveCtrl, curve: Curves.easeOutCubic));
  }

  @override
  void didUpdateWidget(covariant _SoccerPitchWidget old) {
    super.didUpdateWidget(old);
    final pos = _deriveBallPos();
    final newTarget = pos.$1;
    final newLabel = pos.$2;
    if ((newTarget - _ballTarget).distance > 0.04 || newLabel != _eventLabel) {
      final from = _moveAnim.value;
      _ballTarget = newTarget;
      _eventLabel = newLabel;
      _moveAnim = Tween<Offset>(begin: from, end: newTarget)
          .animate(CurvedAnimation(parent: _moveCtrl, curve: Curves.easeOutCubic));
      _moveCtrl.forward(from: 0);
    }
  }

  @override
  void dispose() {
    _pulseCtrl.dispose();
    _moveCtrl.dispose();
    super.dispose();
  }

  /// Derive normalised ball position + event label from ESPN situation data.
  ///
  /// Coordinate system: x=0.0 is the LEFT edge (where home attacks toward,
  /// per existing painter convention), x=1.0 is the RIGHT edge.
  /// y=0.0 is the TOP, y=1.0 is the BOTTOM.
  (Offset, String) _deriveBallPos() {
    final team = widget.detail?.situationTeam ?? '';
    final raw  = widget.detail?.situationDescription ?? '';
    final desc = raw.toLowerCase();

    // Corner kick ─ ball is at the corner flag of the attacking team's zone
    if (desc.contains('corner')) {
      final x = team == 'home' ? 0.04 : team == 'away' ? 0.96 : 0.50;
      final y = (desc.hashCode & 1) == 0 ? 0.07 : 0.93;
      return (Offset(x, y), '角球');
    }
    // Penalty ─ penalty spot
    if (desc.contains('penalty')) {
      final x = team == 'home' ? 0.13 : team == 'away' ? 0.87 : 0.50;
      return (Offset(x, 0.50), '點球');
    }
    // Goal kick ─ keeper has ball near own goal
    if (desc.contains('goal kick')) {
      // If home has possession & doing goal kick → home keeper = right side (x~0.90)
      final x = team == 'home' ? 0.90 : team == 'away' ? 0.10 : 0.50;
      return (Offset(x, 0.50), '開球門');
    }
    // Free kick
    if (desc.contains('free kick') ||
        (desc.contains('free') && desc.contains('kick'))) {
      final x = team == 'home' ? 0.24 : team == 'away' ? 0.76 : 0.50;
      return (Offset(x, 0.50), '任意球');
    }
    // Throw-in ─ near sideline
    if (desc.contains('throw')) {
      final x = team == 'home' ? 0.28 : team == 'away' ? 0.72 : 0.50;
      return (Offset(x, 0.08), '界外球');
    }
    // Kick-off
    if (desc.contains('kick off') || desc.contains('kickoff')) {
      return (const Offset(0.50, 0.50), '開球');
    }
    // Offside
    if (desc.contains('offside')) {
      final x = team == 'home' ? 0.15 : team == 'away' ? 0.85 : 0.50;
      return (Offset(x, 0.50), '越位');
    }
    // Default: generic possession / attacking
    if (team == 'home') return (const Offset(0.30, 0.50), '進攻中');
    if (team == 'away') return (const Offset(0.70, 0.50), '進攻中');
    return (const Offset(0.50, 0.50), '');
  }

  @override
  Widget build(BuildContext context) {
    final match = widget.match;
    final detail = widget.detail;
    final isLive = match.status == MatchStatus.live;
    final situationTeam = detail?.situationTeam ?? '';

    return Container(
      decoration: BoxDecoration(
        color: const Color(0xFF0D1A1A),
        borderRadius: BorderRadius.circular(16),
      ),
      padding: const EdgeInsets.all(14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                decoration: BoxDecoration(
                  color: Colors.white.withValues(alpha: 0.07),
                  borderRadius: BorderRadius.circular(6),
                ),
                child: Text(
                  isLive ? '⚡ 即時追蹤' : '📊 比賽態勢',
                  style: const TextStyle(
                      color: Colors.white70, fontSize: 11, fontWeight: FontWeight.w600),
                ),
              ),
              if (isLive && match.progressDetail.isNotEmpty) ...[
                const SizedBox(width: 8),
                Text(
                  match.progressDetail,
                  style: const TextStyle(
                      color: Colors.red, fontSize: 12, fontWeight: FontWeight.w800),
                ),
              ],
            ],
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: Text(
                  match.awayTeam,
                  textAlign: TextAlign.left,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                      color: AppTheme.secondaryAccent,
                      fontSize: 11,
                      fontWeight: FontWeight.w700),
                ),
              ),
              const Text('對',
                  style: TextStyle(color: Colors.white38, fontSize: 11)),
              Expanded(
                child: Text(
                  match.homeTeam,
                  textAlign: TextAlign.right,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                      color: AppTheme.primaryAccent,
                      fontSize: 11,
                      fontWeight: FontWeight.w700),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          AnimatedBuilder(
            animation: Listenable.merge([_pulseAnim, _moveAnim]),
            builder: (context, child) {
              return SizedBox(
                height: 200,
                width: double.infinity,
                child: CustomPaint(
                  painter: _SoccerFieldPainter(
                    situationTeam: situationTeam,
                    ballNorm: _moveAnim.value,
                    eventLabel: _eventLabel,
                    pulseValue: isLive ? _pulseAnim.value : 0.5,
                    isLive: isLive,
                  ),
                ),
              );
            },
          ),
          if (_eventLabel.isNotEmpty || situationTeam.isNotEmpty) ...[  
            const SizedBox(height: 10),
            Center(
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(
                    width: 8,
                    height: 8,
                    decoration: const BoxDecoration(
                        shape: BoxShape.circle, color: Colors.white),
                  ),
                  const SizedBox(width: 6),
                  Text(
                    () {
                      final teamName = situationTeam == 'home'
                          ? match.homeTeam
                          : situationTeam == 'away'
                              ? match.awayTeam
                              : '';
                      if (teamName.isEmpty) return _eventLabel.isNotEmpty ? _eventLabel : '';
                      return _eventLabel.isNotEmpty ? '$teamName  $_eventLabel' : '$teamName  進攻中';
                    }(),
                    style: const TextStyle(
                        color: Colors.white,
                        fontSize: 13,
                        fontWeight: FontWeight.w700),
                  ),
                ],
              ),
            ),
          ] else if (!isLive) ...[  
            const SizedBox(height: 8),
            const Center(
              child: Text('比賽未開始或已結束',
                  style: TextStyle(color: Colors.white38, fontSize: 12)),
            ),
          ],
          if (detail != null) ...[  
            const SizedBox(height: 14),
            _SoccerPossessionBar(match: match, detail: detail),
          ],
        ],
      ),
    );
  }
}

class _SoccerFieldPainter extends CustomPainter {
  final String situationTeam;
  final double pulseValue;
  final bool isLive;
  /// Normalised ball position: dx ∈ [0,1] left→right, dy ∈ [0,1] top→bottom
  final Offset ballNorm;
  /// Chinese event label drawn near the ball (e.g. '角球', '任意球')
  final String eventLabel;

  const _SoccerFieldPainter({
    required this.situationTeam,
    required this.pulseValue,
    required this.isLive,
    this.ballNorm = const Offset(0.5, 0.5),
    this.eventLabel = '',
  });

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width;
    final h = size.height;
    const m = 4.0; // margin

    // Clip to rounded rect
    canvas.clipRRect(
        RRect.fromRectAndRadius(Rect.fromLTWH(0, 0, w, h), const Radius.circular(8)));

    // Green field
    canvas.drawRect(
        Rect.fromLTWH(0, 0, w, h), Paint()..color = const Color(0xFF1A7A34));

    // Stripe pattern
    final stripeW = w / 8;
    for (int i = 0; i < 8; i++) {
      canvas.drawRect(
        Rect.fromLTWH(i * stripeW, 0, stripeW, h),
        Paint()
          ..color = (i.isEven
                  ? const Color(0xFF1F8A3C)
                  : const Color(0xFF177030))
              .withValues(alpha: 0.9),
      );
    }

    final linePaint = Paint()
      ..color = Colors.white.withValues(alpha: 0.7)
      ..strokeWidth = 1.2
      ..style = PaintingStyle.stroke;

    // Boundary
    canvas.drawRect(Rect.fromLTRB(m, m, w - m, h - m), linePaint);

    // Center line
    canvas.drawLine(Offset(w / 2, m), Offset(w / 2, h - m), linePaint);

    // Center circle
    canvas.drawCircle(Offset(w / 2, h / 2), h * 0.22, linePaint);
    canvas.drawCircle(Offset(w / 2, h / 2), 3,
        Paint()..color = Colors.white.withValues(alpha: 0.7));

    // Penalty areas
    final penW = w * 0.14;
    final penH = h * 0.5;
    final penY = (h - penH) / 2;
    // Left
    canvas.drawRect(Rect.fromLTWH(m, penY, penW, penH), linePaint);
    // Right
    canvas.drawRect(
        Rect.fromLTWH(w - penW - m, penY, penW, penH), linePaint);

    // Goal areas
    final gaW = w * 0.06;
    final gaH = h * 0.26;
    final gaY = (h - gaH) / 2;
    canvas.drawRect(Rect.fromLTWH(m, gaY, gaW, gaH), linePaint);
    canvas.drawRect(Rect.fromLTWH(w - gaW - m, gaY, gaW, gaH), linePaint);

    // Goals
    final goalH = h * 0.18;
    final goalY = (h - goalH) / 2;
    final goalPaint = Paint()
      ..color = Colors.white.withValues(alpha: 0.5)
      ..strokeWidth = 2.0
      ..style = PaintingStyle.stroke;
    canvas.drawRect(Rect.fromLTWH(0, goalY, 6, goalH), goalPaint);
    canvas.drawRect(Rect.fromLTWH(w - 6, goalY, 6, goalH), goalPaint);

    // Attacking zone highlight
    if (situationTeam == 'away') {
      // Away attacking → toward right (home goal)
      canvas.drawRect(
          Rect.fromLTWH(w / 2, m, w / 2 - m, h - 2 * m),
          Paint()..color = Colors.white.withValues(alpha: 0.07));
    } else if (situationTeam == 'home') {
      // Home attacking → toward left (away goal)
      canvas.drawRect(
          Rect.fromLTWH(m, m, w / 2 - m, h - 2 * m),
          Paint()..color = Colors.white.withValues(alpha: 0.07));
    }

    // Ball position from normalised coordinates provided by state
    final ballX = ballNorm.dx * w;
    final ballY = ballNorm.dy * h;

    // Glow
    if (isLive) {
      canvas.drawCircle(
          Offset(ballX, ballY),
          16,
          Paint()
            ..color = Colors.white.withValues(alpha: 0.12 * pulseValue)
            ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 14));
    }

    // Shadow
    canvas.drawCircle(
        Offset(ballX + 2, ballY + 2),
        7,
        Paint()
          ..color = Colors.black38
          ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 4));

    // Ball
    canvas.drawCircle(Offset(ballX, ballY), 7, Paint()..color = Colors.white);

    // Ball pentagon hint
    final crossPaint = Paint()
      ..color = Colors.black26
      ..strokeWidth = 1.5
      ..style = PaintingStyle.stroke;
    canvas.drawLine(Offset(ballX - 4, ballY), Offset(ballX + 4, ballY), crossPaint);
    canvas.drawLine(Offset(ballX, ballY - 4), Offset(ballX, ballY + 4), crossPaint);

    // Event label badge above ball
    if (eventLabel.isNotEmpty) {
      final tp = TextPainter(
        text: TextSpan(
          text: eventLabel,
          style: const TextStyle(
            color: Colors.white,
            fontSize: 10,
            fontWeight: FontWeight.w700,
          ),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      final lx = (ballX - tp.width / 2).clamp(4.0, w - tp.width - 4);
      final ly = (ballY - 24).clamp(4.0, h - tp.height - 4);
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromLTWH(lx - 5, ly - 3, tp.width + 10, tp.height + 6),
          const Radius.circular(6),
        ),
        Paint()..color = const Color(0xCC111111),
      );
      tp.paint(canvas, Offset(lx, ly));
    }

    // Trailing dash toward nearest goal
    if (situationTeam == 'away' || situationTeam == 'home') {
      final targetX = ballNorm.dx < 0.5 ? 6.0 : w - 6.0;
      final dashPaint = Paint()
        ..color = Colors.white.withValues(alpha: 0.25)
        ..strokeWidth = 1.5
        ..style = PaintingStyle.stroke;
      final dx = targetX - ballX;
      final totalLen = dx.abs();
      const dashLen = 8.0;
      const gapLen = 6.0;
      double drawn = dashLen + 4; // start after ball
      while (drawn < totalLen - dashLen) {
        final t1 = drawn / totalLen;
        final t2 = (drawn + dashLen) / totalLen;
        canvas.drawLine(
            Offset(ballX + t1 * dx, ballY),
            Offset(ballX + t2 * dx, ballY),
            dashPaint);
        drawn += dashLen + gapLen;
      }
    }
  }

  @override
  bool shouldRepaint(covariant _SoccerFieldPainter old) =>
      old.situationTeam != situationTeam ||
      old.ballNorm != ballNorm ||
      old.eventLabel != eventLabel ||
      (old.pulseValue - pulseValue).abs() > 0.01;
}

// ── 控球率條 ──────────────────────────────────────────────────────
class _SoccerPossessionBar extends StatelessWidget {
  const _SoccerPossessionBar({required this.match, required this.detail});
  final MatchFixture match;
  final SoccerGameDetail detail;

  @override
  Widget build(BuildContext context) {
    String homePoss = '';
    String awayPoss = '';
    const possKeys = ['possessionPct', 'possessionPctg', 'possession'];
    for (final k in possKeys) {
      if (detail.homeTeamStats.containsKey(k)) {
        homePoss = detail.homeTeamStats[k]!;
        awayPoss = detail.awayTeamStats[k] ?? '';
        break;
      }
    }
    if (homePoss.isEmpty) {
      for (final entry in detail.homeTeamStats.entries) {
        if (entry.key.toLowerCase().contains('oss')) {
          homePoss = entry.value;
          awayPoss = detail.awayTeamStats[entry.key] ?? '';
          break;
        }
      }
    }
    if (homePoss.isEmpty) return const SizedBox.shrink();

    final homeNum = double.tryParse(homePoss.replaceAll('%', '')) ?? 50.0;
    final awayNum = double.tryParse(awayPoss.replaceAll('%', '')) ?? (100 - homeNum);
    final total = homeNum + awayNum;

    return Column(
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(match.awayTeam,
                style: const TextStyle(
                    color: AppTheme.secondaryAccent,
                    fontSize: 11,
                    fontWeight: FontWeight.w600)),
            const Text('控球率',
                style: TextStyle(color: Colors.white54, fontSize: 11)),
            Text(match.homeTeam,
                style: const TextStyle(
                    color: AppTheme.primaryAccent,
                    fontSize: 11,
                    fontWeight: FontWeight.w600)),
          ],
        ),
        const SizedBox(height: 6),
        ClipRRect(
          borderRadius: BorderRadius.circular(4),
          child: LayoutBuilder(builder: (context, constraints) {
            final awayW = total > 0
                ? constraints.maxWidth * (awayNum / total)
                : constraints.maxWidth * 0.5;
            final homeW = constraints.maxWidth - awayW;
            return Row(children: [
              Container(width: awayW, height: 6, color: AppTheme.secondaryAccent),
              Container(width: homeW, height: 6, color: AppTheme.primaryAccent),
            ]);
          }),
        ),
        const SizedBox(height: 4),
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(
              awayPoss.contains('%') ? awayPoss : '${awayNum.toStringAsFixed(0)}%',
              style: const TextStyle(
                  color: AppTheme.secondaryAccent,
                  fontSize: 12,
                  fontWeight: FontWeight.w700),
            ),
            Text(
              homePoss.contains('%') ? homePoss : '${homeNum.toStringAsFixed(0)}%',
              style: const TextStyle(
                  color: AppTheme.primaryAccent,
                  fontSize: 12,
                  fontWeight: FontWeight.w700),
            ),
          ],
        ),
      ],
    );
  }
}

// ── 半場比分卡 ─────────────────────────────────────────────────────
class _SoccerHalfScoreCard extends StatelessWidget {
  const _SoccerHalfScoreCard({required this.match, required this.detail});
  final MatchFixture match;
  final SoccerGameDetail detail;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: const Color(0xFF131C31),
        borderRadius: BorderRadius.circular(12),
      ),
      child: IntrinsicHeight(
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(match.awayTeam,
                      style: const TextStyle(
                          color: AppTheme.secondaryAccent,
                          fontSize: 11,
                          fontWeight: FontWeight.w600)),
                  const SizedBox(height: 6),
                  if (detail.awayFirstHalf >= 0)
                    _halfRow('上半場', '${detail.awayFirstHalf}'),
                  if (detail.awaySecondHalf >= 0)
                    _halfRow('下半場', '${detail.awaySecondHalf}'),
                ],
              ),
            ),
            Container(width: 1, color: Colors.white12,
                margin: const EdgeInsets.symmetric(horizontal: 12)),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Text(match.homeTeam,
                      style: const TextStyle(
                          color: AppTheme.primaryAccent,
                          fontSize: 11,
                          fontWeight: FontWeight.w600)),
                  const SizedBox(height: 6),
                  if (detail.homeFirstHalf >= 0)
                    _halfRow('上半場', '${detail.homeFirstHalf}', right: true),
                  if (detail.homeSecondHalf >= 0)
                    _halfRow('下半場', '${detail.homeSecondHalf}', right: true),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _halfRow(String label, String value, {bool right = false}) {
    final inner = [
      Text(label, style: const TextStyle(color: Colors.white54, fontSize: 12)),
      const SizedBox(width: 8),
      Text(value,
          style: const TextStyle(
              color: Colors.white, fontSize: 14, fontWeight: FontWeight.w700)),
    ];
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Row(
        mainAxisAlignment:
            right ? MainAxisAlignment.end : MainAxisAlignment.start,
        children: right ? inner.reversed.toList() : inner,
      ),
    );
  }
}

// ── 賽事紀錄行 ────────────────────────────────────────────────────
class _SoccerEventTile extends StatelessWidget {
  const _SoccerEventTile({required this.event, required this.match});
  final SoccerMatchEvent event;
  final MatchFixture match;

  @override
  Widget build(BuildContext context) {
    final isHome = event.teamSide == 'home';
    final teamColor = isHome ? AppTheme.primaryAccent : AppTheme.secondaryAccent;

    String typeEmoji;
    switch (event.type) {
      case 'goal':
      case 'score':
        typeEmoji = '⚽';
        break;
      case 'yellowcard':
      case 'yellow-card':
        typeEmoji = '🟨';
        break;
      case 'redcard':
      case 'red-card':
        typeEmoji = '🟥';
        break;
      case 'substitution':
      case 'sub':
        typeEmoji = '🔄';
        break;
      default:
        typeEmoji = '▸';
    }

    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.04),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: Colors.white10),
      ),
      child: Row(
        children: [
          SizedBox(
            width: 42,
            child: Text(
              event.clock,
              textAlign: TextAlign.center,
              style: const TextStyle(
                  color: AppTheme.primaryAccent,
                  fontSize: 13,
                  fontWeight: FontWeight.w800),
            ),
          ),
          const SizedBox(width: 8),
          Text(typeEmoji, style: const TextStyle(fontSize: 16)),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (event.playerName.isNotEmpty)
                  Text(
                    event.playerName,
                    style: TextStyle(
                        color: teamColor,
                        fontSize: 13,
                        fontWeight: FontWeight.w700),
                  ),
                if (event.description.isNotEmpty)
                  Text(
                    event.description,
                    style: const TextStyle(
                        color: Colors.white54,
                        fontSize: 11,
                        height: 1.3),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
              ],
            ),
          ),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
            decoration: BoxDecoration(
              color: teamColor.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(5),
              border: Border.all(color: teamColor.withValues(alpha: 0.3)),
            ),
            child: Text(
              event.teamSide == 'home'
                  ? '主'
                  : event.teamSide == 'away'
                      ? '客'
                      : '　',
              style: TextStyle(
                  color: teamColor, fontSize: 10, fontWeight: FontWeight.w700),
            ),
          ),
        ],
      ),
    );
  }
}

// ── 足球先發名單 ──────────────────────────────────────────────────
class _SoccerLineupSection extends StatelessWidget {
  const _SoccerLineupSection({required this.match, required this.detail});
  final MatchFixture match;
  final SoccerGameDetail detail;

  @override
  Widget build(BuildContext context) {
    if (detail.homeLineup.isEmpty && detail.awayLineup.isEmpty) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.only(top: 40),
          child: Text('尚無先發名單',
              style: TextStyle(color: Colors.white38, fontSize: 16)),
        ),
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(match.awayTeam,
                  textAlign: TextAlign.center,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                      color: AppTheme.secondaryAccent,
                      fontSize: 13,
                      fontWeight: FontWeight.w700)),
            ),
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: 8),
              child: Text('先發名單',
                  style: TextStyle(
                      color: Colors.white54, fontSize: 11, fontWeight: FontWeight.w600)),
            ),
            Expanded(
              child: Text(match.homeTeam,
                  textAlign: TextAlign.center,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                      color: AppTheme.primaryAccent,
                      fontSize: 13,
                      fontWeight: FontWeight.w700)),
            ),
          ],
        ),
        const SizedBox(height: 12),
        const Divider(color: Colors.white12, height: 1),
        const SizedBox(height: 10),
        ...List.generate(
          math.max(detail.awayLineup.length, detail.homeLineup.length),
          (i) {
            final away = i < detail.awayLineup.length ? detail.awayLineup[i] : null;
            final home = i < detail.homeLineup.length ? detail.homeLineup[i] : null;
            return Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Row(
                children: [
                  Expanded(
                    child: away != null
                        ? _SoccerPlayerCard(
                            player: away, isAway: true,
                            align: CrossAxisAlignment.start)
                        : const SizedBox.shrink(),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: home != null
                        ? _SoccerPlayerCard(
                            player: home, isAway: false,
                            align: CrossAxisAlignment.end)
                        : const SizedBox.shrink(),
                  ),
                ],
              ),
            );
          },
        ),
      ],
    );
  }
}

class _SoccerPlayerCard extends StatelessWidget {
  const _SoccerPlayerCard({
    required this.player,
    required this.isAway,
    required this.align,
  });
  final SoccerPlayer player;
  final bool isAway;
  final CrossAxisAlignment align;

  @override
  Widget build(BuildContext context) {
    final color = isAway ? AppTheme.secondaryAccent : AppTheme.primaryAccent;
    final isRight = align == CrossAxisAlignment.end;
    final numWidget = Container(
      width: 22,
      height: 22,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: color.withValues(alpha: 0.15),
      ),
      child: Text(
        player.jerseyNumber.isNotEmpty ? player.jerseyNumber : '-',
        style: TextStyle(color: color, fontSize: 10, fontWeight: FontWeight.w800),
      ),
    );
    final posWidget = Text(
      player.position,
      style: TextStyle(
          color: color.withValues(alpha: 0.7), fontSize: 10, fontWeight: FontWeight.w700),
    );

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.04),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: Colors.white10),
      ),
      child: Column(
        crossAxisAlignment: align,
        children: [
          Row(
            mainAxisAlignment:
                isRight ? MainAxisAlignment.end : MainAxisAlignment.start,
            children: isRight
                ? [posWidget, const SizedBox(width: 6), numWidget]
                : [numWidget, const SizedBox(width: 6), posWidget],
          ),
          const SizedBox(height: 4),
          Text(
            player.name,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            textAlign: isRight ? TextAlign.right : TextAlign.left,
            style: const TextStyle(
                color: Colors.white, fontSize: 13, fontWeight: FontWeight.w700),
          ),
          if ((player.goals.isNotEmpty && player.goals != '0') ||
              (player.assists.isNotEmpty && player.assists != '0'))
            Text(
              [
                if (player.goals.isNotEmpty && player.goals != '0') '⚽ ${player.goals}',
                if (player.assists.isNotEmpty && player.assists != '0') '🅰 ${player.assists}',
              ].join('  '),
              style: const TextStyle(color: Colors.white38, fontSize: 10),
            ),
        ],
      ),
    );
  }
}

// ── 足球傷兵列 ────────────────────────────────────────────────────
class _SoccerInjuryRow extends StatelessWidget {
  const _SoccerInjuryRow({required this.injury});
  final BaseballInjury injury;

  @override
  Widget build(BuildContext context) {
    Color statusColor;
    String statusZh;
    switch (injury.status.toLowerCase()) {
      case 'out':
        statusColor = Colors.red;
        statusZh = '無法出賽';
        break;
      case 'questionable':
        statusColor = Colors.orange;
        statusZh = '出賽存疑';
        break;
      case 'doubtful':
        statusColor = Colors.deepOrange;
        statusZh = '出賽困難';
        break;
      case 'probable':
        statusColor = Colors.lightGreen;
        statusZh = '可能出賽';
        break;
      default:
        statusColor = Colors.white54;
        statusZh = injury.status.isNotEmpty ? injury.status : '未知';
    }

    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.04),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: Colors.white10),
      ),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(injury.playerName,
                    style: const TextStyle(
                        color: Colors.white, fontSize: 14, fontWeight: FontWeight.w700)),
                if (injury.team.isNotEmpty)
                  Text(injury.team,
                      style: const TextStyle(color: Colors.white54, fontSize: 11)),
                if (injury.description.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: 3),
                    child: Text(injury.description,
                        style: const TextStyle(color: Colors.white38, fontSize: 11)),
                  ),
              ],
            ),
          ),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
            decoration: BoxDecoration(
              color: statusColor.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: statusColor.withValues(alpha: 0.4)),
            ),
            child: Text(statusZh,
                style: TextStyle(
                    color: statusColor, fontSize: 11, fontWeight: FontWeight.w700)),
          ),
        ],
      ),
    );
  }
}

// ── 足球禁賽名單列 ────────────────────────────────────────────────
class _SoccerSuspensionRow extends StatelessWidget {
  const _SoccerSuspensionRow({required this.suspension});
  final SoccerSuspension suspension;

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.red.withValues(alpha: 0.06),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: Colors.red.withValues(alpha: 0.3)),
      ),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(suspension.playerName,
                    style: const TextStyle(
                        color: Colors.white, fontSize: 14, fontWeight: FontWeight.w700)),
                if (suspension.teamName.isNotEmpty)
                  Text(suspension.teamName,
                      style: const TextStyle(color: Colors.white54, fontSize: 11)),
                Padding(
                  padding: const EdgeInsets.only(top: 3),
                  child: Text(suspension.reason,
                      style: const TextStyle(color: Colors.redAccent, fontSize: 11)),
                ),
              ],
            ),
          ),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            decoration: BoxDecoration(
              color: Colors.red.withValues(alpha: 0.15),
              borderRadius: BorderRadius.circular(6),
              border: Border.all(color: Colors.red.withValues(alpha: 0.4)),
            ),
            child: const Text('禁賽',
                style: TextStyle(
                    color: Colors.redAccent, fontSize: 10, fontWeight: FontWeight.w700)),
          ),
        ],
      ),
    );
  }
}

// ── 足球缺席球員列 ────────────────────────────────────────────────
class _SoccerAbsentRow extends StatelessWidget {
  const _SoccerAbsentRow({required this.injury});
  final BaseballInjury injury;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Row(
        children: [
          const Icon(Icons.person_off, size: 14, color: Colors.white24),
          const SizedBox(width: 8),
          Expanded(
            child: Text(injury.playerName,
                style: const TextStyle(color: Colors.white54, fontSize: 13)),
          ),
          if (injury.description.isNotEmpty && injury.description != '未入選本場比賽名單')
            Text(injury.description,
                style: const TextStyle(color: Colors.orangeAccent, fontSize: 11)),
        ],
      ),
    );
  }
}

// ── 足球球隊戰績卡 ────────────────────────────────────────────────
class _SoccerRecordCard extends StatelessWidget {
  const _SoccerRecordCard({required this.match, this.detail});
  final MatchFixture match;
  final SoccerGameDetail? detail;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: const Color(0xFF131C31),
        borderRadius: BorderRadius.circular(16),
      ),
      child: Row(
        children: [
          Expanded(
            child: _side(match.awayTeam, detail?.awayRecord ?? '',
                detail?.awayStreak ?? '', AppTheme.secondaryAccent,
                CrossAxisAlignment.start),
          ),
          Container(width: 1, height: 60, color: Colors.white12,
              margin: const EdgeInsets.symmetric(horizontal: 16)),
          Expanded(
            child: _side(match.homeTeam, detail?.homeRecord ?? '',
                detail?.homeStreak ?? '', AppTheme.primaryAccent,
                CrossAxisAlignment.end),
          ),
        ],
      ),
    );
  }

  Widget _side(String team, String record, String streak,
      Color teamColor, CrossAxisAlignment cross) {
    final parts = record.split('-');
    String subtitle = '';
    if (parts.length == 3) {
      subtitle = '勝 - 平 - 負';
    } else if (parts.length >= 2) {
      subtitle = '勝 - 負';
    }
    return Column(
      crossAxisAlignment: cross,
      children: [
        Text(team,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
                color: teamColor, fontSize: 12, fontWeight: FontWeight.w700)),
        const SizedBox(height: 6),
        Text(record.isNotEmpty ? record : '-',
            style: const TextStyle(
                color: Colors.white, fontSize: 22, fontWeight: FontWeight.w900)),
        if (subtitle.isNotEmpty)
          Text(subtitle,
              style: const TextStyle(color: Colors.white54, fontSize: 11)),
        if (streak.isNotEmpty) ...[
          const SizedBox(height: 8),
          _streakBadge(streak),
        ],
      ],
    );
  }

  Widget _streakBadge(String streak) {
    final isWin = streak.startsWith('連勝');
    final color = isWin ? AppTheme.primaryAccent : Colors.redAccent;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: color.withValues(alpha: 0.4)),
      ),
      child: Text(streak,
          style: TextStyle(
              color: color, fontSize: 11, fontWeight: FontWeight.w700)),
    );
  }
}

// ── 足球數據比較 ──────────────────────────────────────────────────
class _SoccerStatsCompare extends StatelessWidget {
  const _SoccerStatsCompare({required this.match, required this.detail});
  final MatchFixture match;
  final SoccerGameDetail detail;

  static const _labelMap = {
    'possessionPct': '控球率',
    'possessionPctg': '控球率',
    'possession': '控球率',
    'totalShots': '總射門',
    'totalShotsOnGoal': '射正',
    'shotsOnTarget': '射正',
    'blockedShots': '封阻',
    'fouls': '犯規',
    'yellowCards': '黃牌',
    'redCards': '紅牌',
    'offsides': '越位',
    'cornerKicks': '角球',
    'saves': '撲救',
    'goalKicks': '球門截球',
    'freekicksWon': '任意球',
  };

  @override
  Widget build(BuildContext context) {
    final allKeys = {...detail.homeTeamStats.keys, ...detail.awayTeamStats.keys};
    const priority = [
      'possessionPct', 'possessionPctg', 'possession',
      'totalShots', 'shotsOnTarget', 'totalShotsOnGoal',
      'cornerKicks', 'fouls', 'yellowCards', 'redCards',
      'offsides', 'saves', 'blockedShots',
    ];
    final ordered = [
      ...priority.where(allKeys.contains),
      ...allKeys.difference(priority.toSet()),
    ];
    if (ordered.isEmpty) {
      return const Center(
          child: Text('暫無數據',
              style: TextStyle(color: Colors.white38, fontSize: 14)));
    }
    return Container(
      decoration: BoxDecoration(
          color: const Color(0xFF131C31),
          borderRadius: BorderRadius.circular(16)),
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Column(
        children: ordered.take(12).map((key) => _StatCompareRow(
              label: _labelMap[key] ?? key,
              homeValue: detail.homeTeamStats[key] ?? '',
              awayValue: detail.awayTeamStats[key] ?? '',
            )).toList(),
      ),
    );
  }
}

class _StatCompareRow extends StatelessWidget {
  const _StatCompareRow({
    required this.label,
    required this.homeValue,
    required this.awayValue,
  });
  final String label;
  final String homeValue;
  final String awayValue;

  @override
  Widget build(BuildContext context) {
    final homeNum = double.tryParse(homeValue.replaceAll('%', ''));
    final awayNum = double.tryParse(awayValue.replaceAll('%', ''));
    final total = (homeNum ?? 0) + (awayNum ?? 0);
    final showBar = homeNum != null && awayNum != null && total > 0;

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Column(
        children: [
          Row(
            children: [
              SizedBox(
                width: 50,
                child: Text(awayValue.isNotEmpty ? awayValue : '-',
                    style: const TextStyle(
                        color: AppTheme.secondaryAccent,
                        fontSize: 14,
                        fontWeight: FontWeight.w800)),
              ),
              Expanded(
                child: Text(label,
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                        color: Colors.white54, fontSize: 12, fontWeight: FontWeight.w600)),
              ),
              SizedBox(
                width: 50,
                child: Text(homeValue.isNotEmpty ? homeValue : '-',
                    textAlign: TextAlign.right,
                    style: const TextStyle(
                        color: AppTheme.primaryAccent,
                        fontSize: 14,
                        fontWeight: FontWeight.w800)),
              ),
            ],
          ),
          if (showBar) ...[
            const SizedBox(height: 5),
            ClipRRect(
              borderRadius: BorderRadius.circular(3),
              child: LayoutBuilder(builder: (context, c) {
                final aw = c.maxWidth * (awayNum / total);
                final hw = c.maxWidth - aw;
                return Row(children: [
                  Container(
                      width: aw, height: 4,
                      color: AppTheme.secondaryAccent.withValues(alpha: 0.5)),
                  Container(
                      width: hw, height: 4,
                      color: AppTheme.primaryAccent.withValues(alpha: 0.5)),
                ]);
              }),
            ),
          ],
        ],
      ),
    );
  }
}
