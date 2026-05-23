import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../models/match_fixture.dart';
import '../models/match_prediction.dart';
import '../models/prediction_log.dart';
import '../models/sport_type.dart';
import '../services/ai_prediction_service.dart';
import '../services/pang_pang_sports_service.dart';
import '../services/prediction_log_service.dart';
import '../services/real_data_service.dart';
import '../services/self_learning_service.dart';
import '../theme/app_theme.dart';
import '../widgets/app_shell.dart';
import '../widgets/match_card.dart';
import 'match_analysis_screen.dart';
import '../widgets/sport_filter_chips.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> with WidgetsBindingObserver {
  Future<List<MatchFixture>>? _matchesFuture;
  late PangPangSportsService _sportsService;
  SportType? _selectedSport;
  final Set<String> _collapsedLeagues = {};
  bool _completedCollapsed = true;
  int _selectedDayOffset = 0;

  final _logSvc = PredictionLogService();
  Map<String, PredictionLog> _logsByMatchId = {};
  Timer? _learningTimer;

  static const _usTimezoneLeagues = {'NBA', '美職棒', '美職聯'};

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _sportsService = PangPangSportsService();
    AiPredictionService.instance.runSelfLearning();
    _loadMatches();
    _sportsService.predictionRefreshNotifier.addListener(_onLeagueMatchCompleted);
    // 每 15 分鐘自動拉取賽果並校正 Perceptron 權重
    _learningTimer = Timer.periodic(const Duration(minutes: 15), (_) {
      if (mounted) SelfLearningService.runForced(_logSvc).ignore();
    });
  }

  @override
  void dispose() {
    _learningTimer?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    _sportsService.predictionRefreshNotifier.removeListener(_onLeagueMatchCompleted);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      RealDataService.clearSessionCaches();
      _sportsService.clearCache();
      AiPredictionService.instance.clearCache();
      AiPredictionService.instance.runSelfLearning();
      _loadMatches();
    }
  }

  void _onLeagueMatchCompleted() {
    if (!mounted) return;
    _loadMatches();
    // 賽事結束立即強制學習，不受 15 分鐘防抖限制
    SelfLearningService.runForced(_logSvc).ignore();
  }

  void _loadMatches() {
    _matchesFuture = _sportsService.getMatchesForDays(days: 5);
    _loadLogs();
    if (mounted) setState(() {});
  }

  Future<void> _loadLogs() async {
    final logs = await _logSvc.loadByType(PredictionType.sport);
    if (!mounted) return;
    setState(() {
      _logsByMatchId = {
        for (final l in logs)
          (l.details['matchId'] ?? '').toString(): l,
      };
    });
  }

  List<MatchFixture> _filterByDay(List<MatchFixture> matches) {
    final twNow = DateTime.now().toUtc().add(const Duration(hours: 8));
    final target = DateTime(twNow.year, twNow.month, twNow.day)
        .add(Duration(days: _selectedDayOffset));
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

  Widget _buildDayTabs(DateTime twNow) {
    const labels = ['今天', '明天', '後天', '第4天', '第5天'];
    const weekdays = ['一', '二', '三', '四', '五', '六', '日'];
    return SizedBox(
      height: 54,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 16),
        itemCount: 5,
        separatorBuilder: (_, _) => const SizedBox(width: 8),
        itemBuilder: (context, i) {
          final day = twNow.add(Duration(days: i));
          final weekday = weekdays[day.weekday - 1];
          final isSelected = _selectedDayOffset == i;
          return GestureDetector(
            onTap: () => setState(() => _selectedDayOffset = i),
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 180),
              width: 68,
              decoration: BoxDecoration(
                color: isSelected
                    ? AppTheme.primaryAccent.withAlpha(40)
                    : Colors.white.withAlpha(10),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(
                  color: isSelected
                      ? AppTheme.primaryAccent.withAlpha(160)
                      : Colors.white.withAlpha(20),
                ),
              ),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Text(
                    labels[i],
                    style: TextStyle(
                      fontSize: 11,
                      color: isSelected ? AppTheme.primaryAccent : Colors.white54,
                      fontWeight: isSelected ? FontWeight.w700 : FontWeight.normal,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    '週$weekday',
                    style: TextStyle(
                      fontSize: 13,
                      color: isSelected ? Colors.white : Colors.white70,
                      fontWeight: isSelected ? FontWeight.w700 : FontWeight.normal,
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
    final twNow = DateTime.now().toUtc().add(const Duration(hours: 8));
    return AppShell(
      title: '胖胖體育 · 預測',
      actions: [
        IconButton(
          icon: const Icon(Icons.refresh_rounded),
          tooltip: '重新整理',
          onPressed: () {
            _sportsService.clearCache();
            _loadMatches();
          },
        ),
      ],
      padding: EdgeInsets.zero,
      child: FutureBuilder<List<MatchFixture>>(
        future: _matchesFuture,
        builder: (context, snapshot) {
          if (snapshot.connectionState == ConnectionState.waiting) {
            return const Center(
              child: CircularProgressIndicator(color: AppTheme.primaryAccent),
            );
          }
          if (snapshot.hasError) {
            return Center(
              child: Text(
                '載入失敗：${snapshot.error}',
                style: Theme.of(context).textTheme.bodyMedium,
              ),
            );
          }

          final allMatches = snapshot.data ?? [];
          final dayMatches = _filterByDay(allMatches);
          final filtered = _selectedSport == null
              ? dayMatches
              : dayMatches.where((m) => m.sport == _selectedSport).toList();

          // Build predictions using static session cache
          final predMap = <String, MatchPrediction>{};
          for (final m in filtered) {
            if (m.status != MatchStatus.completed) {
              try {
                predMap[m.id] = _sportsService.predictMatch(m);
              } catch (_) {}
            }
          }

          final active = filtered.where((m) => m.status != MatchStatus.completed).toList();
          final completed = filtered.where((m) => m.status == MatchStatus.completed).toList();

          // Group active by league, sort within league and between leagues by time
          final byLeague = <String, List<MatchFixture>>{};
          for (final m in active) {
            byLeague.putIfAbsent(m.league, () => []).add(m);
          }
          for (final list in byLeague.values) {
            list.sort((a, b) => a.startTime.compareTo(b.startTime));
          }
          final sortedLeagues = byLeague.keys.toList()
            ..sort((a, b) {
              final aFirst = byLeague[a]!.first.startTime;
              final bFirst = byLeague[b]!.first.startTime;
              return aFirst.compareTo(bFirst);
            });

          final items = <_HomeItem>[];
          for (final league in sortedLeagues) {
            final ms = byLeague[league]!;
            final isExpanded = !_collapsedLeagues.contains(league);
            items.add(_HomeLeagueHeader(league: league, count: ms.length, isExpanded: isExpanded));
            if (isExpanded) {
              for (final m in ms) {
                items.add(_HomePredItem(fixture: m, prediction: predMap[m.id]));
              }
            }
          }

          if (completed.isNotEmpty) {
            completed.sort((a, b) => b.startTime.compareTo(a.startTime));
            items.add(_HomeCompletedHeader(
              count: completed.length,
              isExpanded: !_completedCollapsed,
            ));
            if (!_completedCollapsed) {
              for (final m in completed) {
                items.add(_HomePredItem(fixture: m, prediction: predMap[m.id]));
              }
            }
          }

          return RefreshIndicator(
            color: AppTheme.primaryAccent,
            onRefresh: () async {
              _sportsService.clearCache();
              _loadMatches();
            },
            child: ListView.builder(
              physics: const AlwaysScrollableScrollPhysics(),
              padding: const EdgeInsets.fromLTRB(0, 0, 0, 96),
              itemCount: items.length + 1,
              itemBuilder: (context, index) {
                if (index == 0) {
                  return Padding(
                    padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        SportFilterChips(
                          selectedSport: _selectedSport,
                          onChanged: (sport) => setState(() {
                            _selectedSport = sport;
                          }),
                        ),
                        const SizedBox(height: 8),
                        Row(
                          children: [
                            Container(
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 10, vertical: 4),
                              decoration: BoxDecoration(
                                color: Colors.green.shade800.withAlpha(160),
                                borderRadius: BorderRadius.circular(20),
                              ),
                              child: const Row(
                                children: [
                                  Icon(Icons.wifi_rounded,
                                      size: 13, color: Colors.white70),
                                  SizedBox(width: 4),
                                  Text('盤口退算預測',
                                      style: TextStyle(
                                          fontSize: 11, color: Colors.white70)),
                                ],
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 12),
                        _buildDayTabs(twNow),
                        const SizedBox(height: 12),
                        if (filtered.isEmpty)
                          const Padding(
                            padding: EdgeInsets.symmetric(vertical: 60),
                            child: Center(
                              child: Text('此日期目前無賽事',
                                  style: TextStyle(color: Colors.white54)),
                            ),
                          ),
                      ],
                    ),
                  );
                }

                final item = items[index - 1];

                if (item is _HomeLeagueHeader) {
                  return Padding(
                    padding: const EdgeInsets.fromLTRB(16, 0, 16, 0),
                    child: GestureDetector(
                      onTap: () => setState(() {
                        if (_collapsedLeagues.contains(item.league)) {
                          _collapsedLeagues.remove(item.league);
                        } else {
                          _collapsedLeagues.add(item.league);
                        }
                      }),
                      child: Container(
                        margin: const EdgeInsets.only(top: 6, bottom: 4),
                        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                        decoration: BoxDecoration(
                          color: Colors.white.withAlpha(13),
                          borderRadius: BorderRadius.circular(12),
                          border: Border.all(color: Colors.white.withAlpha(25)),
                        ),
                        child: Row(
                          children: [
                            Text(_leagueEmoji(item.league),
                                style: const TextStyle(fontSize: 15)),
                            const SizedBox(width: 8),
                            Expanded(
                              child: Text(item.league,
                                  style: const TextStyle(
                                    color: Colors.white,
                                    fontSize: 14,
                                    fontWeight: FontWeight.w700,
                                  )),
                            ),
                            Container(
                              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                              decoration: BoxDecoration(
                                color: AppTheme.primaryAccent.withAlpha(38),
                                borderRadius: BorderRadius.circular(12),
                              ),
                              child: Text('${item.count}場',
                                  style: const TextStyle(
                                    color: AppTheme.primaryAccent,
                                    fontSize: 11,
                                    fontWeight: FontWeight.w600,
                                  )),
                            ),
                            const SizedBox(width: 6),
                            AnimatedRotation(
                              turns: item.isExpanded ? 0.0 : -0.25,
                              duration: const Duration(milliseconds: 200),
                              child: const Icon(Icons.keyboard_arrow_down_rounded,
                                  color: Colors.white54, size: 22),
                            ),
                          ],
                        ),
                      ),
                    ),
                  );
                }

                if (item is _HomeCompletedHeader) {
                  return Padding(
                    padding: const EdgeInsets.fromLTRB(16, 0, 16, 0),
                    child: GestureDetector(
                      onTap: () => setState(() => _completedCollapsed = !_completedCollapsed),
                      child: Container(
                        margin: const EdgeInsets.only(top: 16, bottom: 6),
                        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                        decoration: BoxDecoration(
                          color: Colors.white.withAlpha(13),
                          borderRadius: BorderRadius.circular(12),
                          border: Border.all(color: Colors.white.withAlpha(25)),
                        ),
                        child: Row(
                          children: [
                            const Text('✅ 已結束比賽',
                                style: TextStyle(
                                  color: Colors.white70,
                                  fontSize: 14,
                                  fontWeight: FontWeight.w700,
                                )),
                            const SizedBox(width: 8),
                            Container(
                              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                              decoration: BoxDecoration(
                                color: Colors.white.withAlpha(20),
                                borderRadius: BorderRadius.circular(12),
                              ),
                              child: Text(
                                '${item.count}場',
                                style: const TextStyle(
                                  color: Colors.white54,
                                  fontSize: 11,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ),
                            const Spacer(),
                            AnimatedRotation(
                              turns: item.isExpanded ? 0.0 : -0.25,
                              duration: const Duration(milliseconds: 200),
                              child: const Icon(Icons.keyboard_arrow_down_rounded,
                                  color: Colors.white54, size: 22),
                            ),
                          ],
                        ),
                      ),
                    ),
                  );
                }

                final predItem = item as _HomePredItem;
                final m = predItem.fixture;
                final pred = predItem.prediction;
                final isCompleted = m.status == MatchStatus.completed;
                final log = _logsByMatchId[m.id];

                if (pred == null) {
                  return const SizedBox.shrink();
                }

                return Padding(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 10),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      MatchCard(
                        fixture: m,
                        prediction: pred,
                        onTap: () => _showBreakdown(context, m, pred),
                      ),
                      if (!isCompleted)
                        _BetRecommendationBar(fixture: m, prediction: pred),
                      if (isCompleted)
                        _SportResultBar(
                          log: log,
                          fixtureId: m.id,
                          predictedResult: log?.predictedResult ?? '',
                          onConfirm: (home, away) async {
                            final logId = log?.id ?? 'sport_${m.id}_football';
                            await _logSvc.reportResult(
                              id: logId,
                              actualResult: '$home:$away',
                            );
                            await _loadLogs();
                          },
                        ),
                    ],
                  ),
                );
              },
            ),
          );
        },
      ),
    );
  }

  String _leagueEmoji(String league) {
    if (league.contains('NBA') || league.contains('籃')) return '🏀';
    if (league.contains('棒') || league.contains('MLB') || league.contains('職棒')) return '⚾';
    return '⚽';
  }

  void _showBreakdown(BuildContext context, MatchFixture fixture, MatchPrediction prediction) {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => MatchAnalysisScreen(fixture: fixture, prediction: prediction),
      ),
    );
  }
}

// ── 首頁預測列表項目類型 ──────────────────────────────────────────
sealed class _HomeItem {}

class _HomeLeagueHeader extends _HomeItem {
  _HomeLeagueHeader({required this.league, required this.count, required this.isExpanded});
  final String league;
  final int count;
  final bool isExpanded;
}

class _HomeCompletedHeader extends _HomeItem {
  _HomeCompletedHeader({
    required this.count,
    this.isExpanded = false,
  });
  final int count;
  final bool isExpanded;
}

class _HomePredItem extends _HomeItem {
  _HomePredItem({required this.fixture, required this.prediction});
  final MatchFixture fixture;
  final MatchPrediction? prediction;
}

// ── 比賽結果回報列 ───────────────────────────────────────────────
class _SportResultBar extends StatefulWidget {
  const _SportResultBar({
    required this.log,
    required this.fixtureId,
    required this.predictedResult,
    required this.onConfirm,
  });
  final PredictionLog? log;
  final String fixtureId;
  final String predictedResult;
  final Future<void> Function(int home, int away) onConfirm;

  @override
  State<_SportResultBar> createState() => _SportResultBarState();
}

class _SportResultBarState extends State<_SportResultBar> {
  final _homeCtrl = TextEditingController();
  final _awayCtrl = TextEditingController();
  bool _editing = false;
  bool _saving = false;

  @override
  void dispose() {
    _homeCtrl.dispose();
    _awayCtrl.dispose();
    super.dispose();
  }

  Color get _outcomeColor {
    return switch (widget.log?.outcome) {
      PredictionOutcome.correct   => const Color(0xFF4CAF50),
      PredictionOutcome.partial   => const Color(0xFFFF9800),
      PredictionOutcome.incorrect => const Color(0xFFF44336),
      _                           => Colors.white24,
    };
  }

  String get _outcomeIcon {
    return switch (widget.log?.outcome) {
      PredictionOutcome.correct   => '✅',
      PredictionOutcome.partial   => '🟡',
      PredictionOutcome.incorrect => '❌',
      _                           => '📝',
    };
  }

  String get _outcomeLabel {
    return switch (widget.log?.outcome) {
      PredictionOutcome.correct   => '預測正確',
      PredictionOutcome.partial   => '部分正確',
      PredictionOutcome.incorrect => '預測錯誤',
      _                           => '輸入實際比分',
    };
  }

  @override
  Widget build(BuildContext context) {
    final hasPending = widget.log == null ||
        widget.log!.outcome == PredictionOutcome.pending;

    return Container(
      margin: const EdgeInsets.only(top: 2, bottom: 2),
      decoration: BoxDecoration(
        color: _outcomeColor.withAlpha(20),
        borderRadius: const BorderRadius.only(
          bottomLeft: Radius.circular(14),
          bottomRight: Radius.circular(14),
        ),
        border: Border.all(color: _outcomeColor.withAlpha(60)),
      ),
      child: hasPending
          ? _buildInputRow(context)
          : _buildResultRow(),
    );
  }

  Widget _buildResultRow() {
    final actual = widget.log!.actualResult ?? '';
    final predicted = widget.predictedResult;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
      child: Row(
        children: [
          Text(_outcomeIcon, style: const TextStyle(fontSize: 15)),
          const SizedBox(width: 8),
          Text(
            _outcomeLabel,
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w700,
              color: _outcomeColor,
            ),
          ),
          const SizedBox(width: 8),
          Text(
            '實際 $actual  預測 $predicted',
            style: const TextStyle(fontSize: 11, color: Colors.white54),
          ),
          const Spacer(),
          GestureDetector(
            onTap: () => setState(() { _editing = true; }),
            child: const Icon(Icons.edit_outlined, size: 14, color: Colors.white30),
          ),
        ],
      ),
    );
  }

  Widget _buildInputRow(BuildContext context) {
    if (!_editing && widget.log?.outcome == PredictionOutcome.pending) {
      return InkWell(
        onTap: () => setState(() => _editing = true),
        borderRadius: const BorderRadius.only(
          bottomLeft: Radius.circular(14),
          bottomRight: Radius.circular(14),
        ),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
          child: Row(
            children: [
              const Icon(Icons.edit_rounded, size: 14, color: Colors.white38),
              const SizedBox(width: 6),
              const Text('輸入實際比分，提升下次預測準確度',
                  style: TextStyle(fontSize: 11, color: Colors.white38)),
              const Spacer(),
              const Icon(Icons.chevron_right_rounded, size: 16, color: Colors.white24),
            ],
          ),
        ),
      );
    }

    if (!_editing) {
      return InkWell(
        onTap: () => setState(() => _editing = true),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
          child: Row(
            children: [
              const Icon(Icons.edit_rounded, size: 14, color: Colors.white38),
              const SizedBox(width: 6),
              const Text('輸入實際比分',
                  style: TextStyle(fontSize: 11, color: Colors.white38)),
            ],
          ),
        ),
      );
    }

    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
      child: Row(
        children: [
          const Text('實際比分：',
              style: TextStyle(fontSize: 12, color: Colors.white60)),
          _ScoreBox(ctrl: _homeCtrl, hint: '主'),
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: 6),
            child: Text(':', style: TextStyle(color: Colors.white54, fontSize: 16, fontWeight: FontWeight.w700)),
          ),
          _ScoreBox(ctrl: _awayCtrl, hint: '客'),
          const SizedBox(width: 12),
          _saving
              ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2, color: AppTheme.primaryAccent))
              : TextButton(
                  onPressed: _submit,
                  style: TextButton.styleFrom(
                    backgroundColor: AppTheme.primaryAccent.withAlpha(30),
                    padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
                    minimumSize: Size.zero,
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                  ),
                  child: const Text('確認', style: TextStyle(fontSize: 12, color: AppTheme.primaryAccent, fontWeight: FontWeight.w700)),
                ),
          const SizedBox(width: 4),
          GestureDetector(
            onTap: () => setState(() { _editing = false; _homeCtrl.clear(); _awayCtrl.clear(); }),
            child: const Icon(Icons.close_rounded, size: 16, color: Colors.white30),
          ),
        ],
      ),
    );
  }

  Future<void> _submit() async {
    final h = int.tryParse(_homeCtrl.text.trim());
    final a = int.tryParse(_awayCtrl.text.trim());
    if (h == null || a == null) return;
    setState(() => _saving = true);
    await widget.onConfirm(h, a);
    setState(() { _saving = false; _editing = false; });
  }
}

class _ScoreBox extends StatelessWidget {
  const _ScoreBox({required this.ctrl, required this.hint});
  final TextEditingController ctrl;
  final String hint;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 38,
      height: 32,
      child: TextField(
        controller: ctrl,
        keyboardType: TextInputType.number,
        inputFormatters: [FilteringTextInputFormatter.digitsOnly],
        textAlign: TextAlign.center,
        style: const TextStyle(color: Colors.white, fontSize: 14, fontWeight: FontWeight.w700),
        decoration: InputDecoration(
          hintText: hint,
          hintStyle: const TextStyle(color: Colors.white30, fontSize: 12),
          isDense: true,
          contentPadding: const EdgeInsets.symmetric(vertical: 6),
          enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(6),
            borderSide: const BorderSide(color: Colors.white24),
          ),
          focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(6),
            borderSide: BorderSide(color: AppTheme.primaryAccent.withAlpha(180)),
          ),
          filled: true,
          fillColor: Colors.white.withAlpha(12),
        ),
      ),
    );
  }
}

// ── 下注建議列 ────────────────────────────────────────────────────
class _BetRecommendationBar extends StatelessWidget {
  const _BetRecommendationBar({
    required this.fixture,
    required this.prediction,
  });

  final MatchFixture fixture;
  final MatchPrediction prediction;

  // 分析所有模型訊號，輸出最強建議
  ({String label, String emoji, Color color, String reason, double conf}) _analyze() {
    final pred = prediction;
    final odds = fixture.odds;

    // ── 1. 大小分建議 ──────────────────────────────────────────
    // AI 預測總分 vs 莊家大小分線
    final aiTotal = pred.aiTotalExpected > 0
        ? pred.aiTotalExpected
        : (pred.predictedHomeScore + pred.predictedAwayScore).toDouble();
    final overLine = odds.overLine;
    final overEdge  = aiTotal - overLine;
    final isOver    = overEdge > 0.5;
    final isUnder   = overEdge < -0.5;

    // ── 2. 勝負建議 ──────────────────────────────────────────
    final ensH = pred.ensembleHomeWinPct;
    final ensD = pred.ensembleDrawPct;
    final ensA = pred.ensembleAwayWinPct;

    // 凱利值：正值 = 正期望，推薦該方向
    final kellyH = pred.kellyHome;
    final kellyA = pred.kellyAway;

    // 是否有顯著 value bet
    final valueH = pred.homeValueEdge;
    final valueA = pred.awayValueEdge;

    // ── 3. 聰明錢信號 ─────────────────────────────────────────
    final smartMoney = odds.hasReverseLineMovement;

    // ── 4. 決策邏輯 ──────────────────────────────────────────
    // 優先度：大小分確定性 > 主客勝負 value bet > 聰明錢
    if (isOver && overEdge > 1.5) {
      final conf = (0.5 + overEdge / 6.0).clamp(0.55, 0.92);
      return (
        label: '推薦下大分  ${overLine.toStringAsFixed(1)}',
        emoji: '📈',
        color: const Color(0xFFFF6B35),
        reason: 'AI預測${aiTotal.toStringAsFixed(1)}分 > 莊家線${overLine.toStringAsFixed(1)}，賠率${odds.overOdds.toStringAsFixed(2)}',
        conf: conf,
      );
    }
    if (isUnder && overEdge < -1.5) {
      final conf = (0.5 + (-overEdge) / 6.0).clamp(0.55, 0.92);
      return (
        label: '推薦下小分  ${overLine.toStringAsFixed(1)}',
        emoji: '📉',
        color: const Color(0xFF42A5F5),
        reason: 'AI預測${aiTotal.toStringAsFixed(1)}分 < 莊家線${overLine.toStringAsFixed(1)}，賠率${odds.underOdds.toStringAsFixed(2)}',
        conf: conf,
      );
    }
    if (pred.hasValueBetSignal && kellyH > 0.05 && valueH > 0.08) {
      final conf = (0.5 + valueH).clamp(0.55, 0.88);
      return (
        label: '推薦主勝  ${fixture.homeTeam}',
        emoji: '🏆',
        color: const Color(0xFF66BB6A),
        reason: '模型勝率${(ensH * 100).round()}% > 隱含機率，Kelly=${kellyH.toStringAsFixed(2)}',
        conf: conf,
      );
    }
    if (pred.hasValueBetSignal && kellyA > 0.05 && valueA > 0.08) {
      final conf = (0.5 + valueA).clamp(0.55, 0.88);
      return (
        label: '推薦客勝  ${fixture.awayTeam}',
        emoji: '🏆',
        color: const Color(0xFF66BB6A),
        reason: '模型勝率${(ensA * 100).round()}% > 隱含機率，Kelly=${kellyA.toStringAsFixed(2)}',
        conf: conf,
      );
    }
    if (ensD > 0.32 && ensH < 0.42 && ensA < 0.42) {
      return (
        label: '平局機率高，建議觀望',
        emoji: '🤝',
        color: Colors.amber,
        reason: '多模型平局機率${(ensD * 100).round()}%，雙方勝率相近',
        conf: ensD,
      );
    }
    if (smartMoney) {
      final favHome = ensH > ensA;
      return (
        label: favHome ? '聰明錢偏${fixture.homeTeam}' : '聰明錢偏${fixture.awayTeam}',
        emoji: '💡',
        color: Colors.purpleAccent,
        reason: '盤口逆向移動，資金流向異常，慎入',
        conf: 0.55,
      );
    }
    // 無強訊號
    final favHome = ensH > ensA;
    return (
      label: favHome ? '微弱偏主 ${fixture.homeTeam}' : '微弱偏客 ${fixture.awayTeam}',
      emoji: '⚠️',
      color: Colors.white38,
      reason: '訊號弱，不建議重倉',
      conf: 0.50,
    );
  }

  @override
  Widget build(BuildContext context) {
    final rec = _analyze();
    final confPct = (rec.conf * 100).round();

    return Container(
      margin: const EdgeInsets.only(top: 4),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        color: rec.color.withAlpha(20),
        borderRadius: const BorderRadius.only(
          bottomLeft: Radius.circular(12),
          bottomRight: Radius.circular(12),
        ),
        border: Border.all(color: rec.color.withAlpha(60)),
      ),
      child: Row(
        children: [
          Text(rec.emoji, style: const TextStyle(fontSize: 16)),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  rec.label,
                  style: TextStyle(
                    color: rec.color,
                    fontSize: 13,
                    fontWeight: FontWeight.w800,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  rec.reason,
                  style: const TextStyle(color: Colors.white54, fontSize: 10),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            decoration: BoxDecoration(
              color: rec.color.withAlpha(40),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Text(
              '信心 $confPct%',
              style: TextStyle(
                color: rec.color,
                fontSize: 11,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
