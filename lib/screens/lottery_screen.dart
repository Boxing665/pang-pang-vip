import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../models/lottery_model.dart';
import '../models/newspaper_539_data.dart';
import '../models/prediction_log.dart';
import '../services/ai_prediction_service.dart';
import '../services/lottery_service.dart';
import '../services/prediction_log_service.dart';
import '../services/failure_analysis_service.dart';
import '../services/self_learning_service.dart';
import '../widgets/lottery_prediction_card.dart';

/// 財神爺樂透預測頁面
///
/// 功能：539 / 大樂透 / 威力彩 AI 推薦號碼 + 歷史開獎記錄 + 紅框輸入
class LotteryScreen extends StatefulWidget {
  const LotteryScreen({super.key});

  @override
  State<LotteryScreen> createState() => _LotteryScreenState();
}

class _LotteryScreenState extends State<LotteryScreen> with WidgetsBindingObserver {
  final _service = LotteryService();
  LotteryFetchResult? _data;
  String? _loadError;
  bool _isLoading = false;
  bool _showHistory = true;
  int _historyTab = 0; // 0=539 1=大樂透 2=威力彩
  PredictionLog? _lastLotteryLog;

  bool _isRefreshing = false; // 背景更新中（已有快取資料時）

  // ── 539 自動學習 ───────────────────────────────────────────────
  String _last539DrawDate = '';      // 上次記錄的開獎日期，避免重複記錄
  String _current539Strategy = 'balanced'; // 當前使用策略（由自我學習推薦）
  Timer? _lottery539Timer;           // 每 10 分鐘自動重新學習

  // ── 今日開獎比對 ───────────────────────────────────────────────
  final List<TextEditingController> _drawnCtrls =
      List.generate(5, (_) => TextEditingController());
  List<int>? _hitNumbers;    // null = 尚未比對
  bool _showDrawnInput = true;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _initStrategy();
    _loadWithCache();
    // 每 10 分鐘自動拉取最新開獎並觸發學習
    _lottery539Timer = Timer.periodic(const Duration(minutes: 10), (_) {
      if (mounted) _load();
    });
  }

  Future<void> _initStrategy() async {
    final s = await SelfLearningService.getRecommended539Strategy();
    if (mounted) setState(() => _current539Strategy = s);
  }

  @override
  void dispose() {
    _lottery539Timer?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    for (final c in _drawnCtrls) { c.dispose(); }
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      AiPredictionService.instance.clearLotteryCache();
      AiPredictionService.instance.clearBingoCache();
      _load();
    }
  }

  // ── 報紙資料 ───────────────────────────────────────────────────

  Newspaper539Entry? get _todayNewspaper {
    final now = _taiwanNow;
    final key = '${now.month.toString().padLeft(2, '0')}/'
        '${now.day.toString().padLeft(2, '0')}';
    return newspaper539Data[key];
  }

  // ── 台灣時區 ───────────────────────────────────────────────────

  DateTime get _taiwanNow =>
      DateTime.now().toUtc().add(const Duration(hours: 8));

  String get _todayLabel {
    final now = _taiwanNow;
    const weekdays = ['一', '二', '三', '四', '五', '六', '日'];
    final wd = weekdays[now.weekday - 1];
    return '${now.month.toString().padLeft(2, '0')}/'
        '${now.day.toString().padLeft(2, '0')} (週$wd)';
  }

  String get _todayDrawKey {
    final now = _taiwanNow;
    return '${now.month.toString().padLeft(2, '0')}/'
        '${now.day.toString().padLeft(2, '0')}';
  }

  /// 計算「下一期開獎日」的 MM/DD key。
  /// 若今天開獎已出現在 records 裡（表示已開完），就預測明天（跳過週日）。
  String _nextDrawKey(List<DrawRecord> records) {
    final todayKey = _todayDrawKey;
    // 若最新一筆資料的日期 == 今天 → 今天已開完，預測下一個開獎日
    final latestDate = records.isNotEmpty ? records.first.date : '';
    if (latestDate == todayKey) {
      var next = _taiwanNow.add(const Duration(days: 1));
      // 539 週一~週六開獎，跳過週日
      if (next.weekday == DateTime.sunday) {
        next = next.add(const Duration(days: 1));
      }
      return '${next.month.toString().padLeft(2, '0')}/'
          '${next.day.toString().padLeft(2, '0')}';
    }
    return todayKey;
  }

  // ── 資料載入 ───────────────────────────────────────────────────

  final _logSvc = PredictionLogService();
  late final _analysisSvc = FailureAnalysisService(_logSvc);

  /// 先顯示快取資料（零延遲），再背景拉取最新開獎更新 UI
  Future<void> _loadWithCache() async {
    final cached = await LotteryService.loadCached539();
    if (cached.isNotEmpty && mounted) {
      // 有快取 → 先顯示舊資料，同時背景更新
      setState(() { _isRefreshing = true; _loadError = null; });
      _load(); // fire & forget
    } else {
      // 無快取 → 正常全屏載入
      _load();
    }
  }

  Future<void> _load() async {
    if (!_isRefreshing) setState(() { _isLoading = true; _loadError = null; });

    try {
      Map<String, double> multipliers = {};
      try {
        final analysis = await _analysisSvc.analyze();
        multipliers = analysis.strategyMultipliers;
      } catch (_) {}

      final npBonuses = _todayNewspaper?.extraBonuses ?? {};
      final result = await _service.fetchAndAnalyze(
          redHints: const [],
          excludeNumbers: [_taiwanNow.day],
          strategyMultipliers: multipliers,
          newspaperBonuses: npBonuses);

      // ── 539 自動學習：偵測新開獎 → 比對預測 → 更新策略 ─────────
      if (result.records539.isNotEmpty) {
        final latestDraw = result.records539.first;
        if (latestDraw.date.isNotEmpty && latestDraw.date != _last539DrawDate
            && latestDraw.numbers.isNotEmpty) {
          _last539DrawDate = latestDraw.date;
          // 從預測紀錄找出對應這期的預測號碼
          final logs = await _logSvc.loadByType(PredictionType.lottery);
          final prev = logs.where((l) =>
            (l.details['lotteryType'] as String? ?? '').contains('539') &&
            (l.details['drawNo'] as String? ?? '') == latestDraw.date
          ).toList();
          if (prev.isNotEmpty) {
            final predictedNums = (prev.first.details['numbers'] as List?)
                ?.map((e) => e as int).toList() ?? [];
            final hits = predictedNums.where((n) => latestDraw.numbers.contains(n)).length;
            await SelfLearningService.record539Strategy(_current539Strategy, hits);
          }
          // 推薦下一期策略
          final nextStrategy = await SelfLearningService.getRecommended539Strategy();
          if (mounted) setState(() => _current539Strategy = nextStrategy);
        }
      }

      // 若今天開獎已出現在 records 裡，預測的是明天（下一期）
      final drawKey = _nextDrawKey(result.records539);

      final numbers = result.results.map((r) => r.number).toList();
      if (numbers.isNotEmpty) {
        final Map<int, String> reasons = {for (final r in result.results) r.number: r.reason};
        await _logSvc.saveLotteryPrediction(
          lotteryType: '539',
          drawNo: drawKey,
          numbers: numbers,
          reasonsByNumber: reasons,
        );
      }

      final byDate = <String, List<int>>{};
      for (final r in result.records539) {
        if (r.date.isEmpty || r.numbers.isEmpty) continue;
        byDate[r.date] = r.numbers;
      }
      await _logSvc.autoReportLotteryByDate(byDate);

      final lotteryLogs = await _logSvc.loadByType(PredictionType.lottery);
      final lastCompleted = lotteryLogs.firstWhere(
        (l) => (l.actualResult ?? '').isNotEmpty,
        orElse: () => lotteryLogs.isNotEmpty ? lotteryLogs.first : PredictionLog(
          id: '', type: PredictionType.lottery, createdAt: DateTime.now(),
          title: '', subtitle: '', predictedResult: '',
        ),
      );

      if (!mounted) return;
      setState(() {
        _isLoading = false;
        _isRefreshing = false;
        _data = result;
        if (lastCompleted.id.isNotEmpty &&
            (lastCompleted.actualResult ?? '').isNotEmpty) {
          _lastLotteryLog = lastCompleted;
        }
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _isLoading = false;
        _isRefreshing = false;
        if (_data == null) _loadError = e.toString();
      });
    }
  }

  // ── 顏色常數（財神爺紅金配色）─────────────────────────────────

  static const Color _bgDeep  = Color(0xFF6B0000);
  static const Color _bgMid   = Color(0xFFA52A2A);
  static const Color _bgLight = Color(0xFFC0392B);
  static const Color _gold    = Color(0xFFFFD700);

  // ── Build ──────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Container(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            colors: [_bgDeep, _bgMid, _bgLight],
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
          ),
        ),
        child: SafeArea(
          child: RefreshIndicator(
            color: _gold,
            onRefresh: _load,
            child: ListView(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              children: [
                _headerSection(),
                const SizedBox(height: 10),
                _statusBar(),
                if (_isLoading) ...[
                  const SizedBox(height: 40),
                  const Center(child: CircularProgressIndicator(color: _gold)),
                ] else if (_loadError != null) ...[
                  const SizedBox(height: 20),
                  Container(
                    padding: const EdgeInsets.all(16),
                    decoration: BoxDecoration(
                      color: Colors.red.withAlpha(40),
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(color: Colors.red.withAlpha(100)),
                    ),
                    child: Column(
                      children: [
                        const Icon(Icons.error_outline, color: Colors.red, size: 32),
                        const SizedBox(height: 8),
                        Text('載入失敗，請下拉重試', style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w700)),
                        const SizedBox(height: 4),
                        Text(_loadError!, style: const TextStyle(color: Colors.white54, fontSize: 11)),
                      ],
                    ),
                  ),
                ],
                const SizedBox(height: 14),
                if (_lastLotteryLog != null) _lastDrawComparison(_lastLotteryLog!),
                if (_lastLotteryLog != null) const SizedBox(height: 14),
                if (_data != null)
                  Lottery539PredictionCard(
                    data: _data!,
                    taiwanNow: _taiwanNow,
                  ),
                if (_data != null) const SizedBox(height: 14),
                _predictionCard(),
                const SizedBox(height: 14),
                if (_data != null && _data!.records539.isNotEmpty)
                  _dataAnalystSection(),
                if (_data != null && _data!.records539.isNotEmpty)
                  const SizedBox(height: 14),
                _drawnNumberInput(),
                const SizedBox(height: 14),
                _historySection(),
                const SizedBox(height: 30),
              ],
            ),
          ),
        ),
      ),
    );
  }

  // ── 上一期預測對照 ──────────────────────────────────────────────

  Widget _lastDrawComparison(PredictionLog log) {
    final predicted = log.predictedResult
        .split(' ')
        .map((s) => int.tryParse(s))
        .whereType<int>()
        .toList();
    final actualStr = log.actualResult ?? '';
    final actual = actualStr
        .split(' ')
        .map((s) => int.tryParse(s))
        .whereType<int>()
        .toSet();
    final hits = predicted.where((n) => actual.contains(n)).toList();

    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: const Color(0xFF6B0000).withAlpha(180),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: _gold.withAlpha(100)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.history_rounded, color: Color(0xFFFFD700), size: 16),
              const SizedBox(width: 6),
              Expanded(
                child: Text(log.title,
                    style: const TextStyle(
                        color: Color(0xFFFFD700),
                        fontWeight: FontWeight.w700,
                        fontSize: 13)),
              ),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                decoration: BoxDecoration(
                  color: hits.length >= 3
                      ? Colors.green.withAlpha(60)
                      : hits.length >= 2
                          ? Colors.orange.withAlpha(60)
                          : Colors.red.withAlpha(50),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text(
                  '命中 ${hits.length} / ${predicted.length}',
                  style: TextStyle(
                    color: hits.length >= 3
                        ? Colors.greenAccent
                        : hits.length >= 2
                            ? Colors.orange
                            : Colors.redAccent,
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Text('上期預測', style: TextStyle(color: _gold.withAlpha(160), fontSize: 11)),
          const SizedBox(height: 6),
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: predicted.map((n) {
              final isHit = actual.contains(n);
              return Container(
                width: 34,
                height: 34,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: isHit ? _gold : const Color(0xFF8B0000),
                  border: isHit ? null : Border.all(color: _gold.withAlpha(80)),
                ),
                alignment: Alignment.center,
                child: Text(
                  '$n',
                  style: TextStyle(
                    color: isHit ? Colors.black : Colors.white70,
                    fontSize: 12,
                    fontWeight: isHit ? FontWeight.w800 : FontWeight.w500,
                  ),
                ),
              );
            }).toList(),
          ),
          if (actual.isNotEmpty) ...[
            const SizedBox(height: 10),
            Text('實際開獎', style: TextStyle(color: _gold.withAlpha(160), fontSize: 11)),
            const SizedBox(height: 4),
            Text(actualStr.replaceAll(' ', '  '),
                style: const TextStyle(color: Colors.white70, fontSize: 12)),
          ],
        ],
      ),
    );
  }

  // ── 今日開獎比對輸入 ───────────────────────────────────────────

  void _compareDrawnNumbers() {
    final drawn = _drawnCtrls
        .map((c) => int.tryParse(c.text.trim()))
        .whereType<int>()
        .where((n) => n >= 1 && n <= 39)
        .toSet();
    if (drawn.length < 5) return;

    final predicted = (_data?.results ?? [])
        .map((r) => r.number)
        .toSet();
    final hits = predicted.intersection(drawn).toList()..sort();

    setState(() => _hitNumbers = hits);

    // 自動回填最新一筆待定的樂透預測記錄
    _logSvc.autoReportLotteryByDate({_todayDrawKey: drawn.toList()..sort()});
  }

  Widget _drawnNumberInput() {
    final predicted = (_data?.results ?? []).map((r) => r.number).toSet();

    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: Colors.white.withAlpha(8),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: _gold.withAlpha(60)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Header
          GestureDetector(
            onTap: () => setState(() => _showDrawnInput = !_showDrawnInput),
            child: Row(
              children: [
                const Icon(Icons.check_circle_outline_rounded,
                    color: _gold, size: 16),
                const SizedBox(width: 6),
                const Expanded(
                  child: Text(
                    '今日開獎比對',
                    style: TextStyle(
                        color: _gold,
                        fontSize: 14,
                        fontWeight: FontWeight.w800),
                  ),
                ),
                if (_hitNumbers != null)
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                    decoration: BoxDecoration(
                      color: _hitNumbers!.length >= 3
                          ? Colors.green.withAlpha(60)
                          : _hitNumbers!.length >= 2
                              ? Colors.orange.withAlpha(60)
                              : Colors.red.withAlpha(50),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Text(
                      '命中 ${_hitNumbers!.length} 個',
                      style: TextStyle(
                        color: _hitNumbers!.length >= 3
                            ? Colors.greenAccent
                            : _hitNumbers!.length >= 2
                                ? Colors.orange
                                : Colors.redAccent,
                        fontSize: 12,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                const SizedBox(width: 6),
                AnimatedRotation(
                  turns: _showDrawnInput ? 0 : -0.25,
                  duration: const Duration(milliseconds: 200),
                  child: const Icon(Icons.keyboard_arrow_down_rounded,
                      color: Colors.white38, size: 20),
                ),
              ],
            ),
          ),

          if (_showDrawnInput) ...[
            const SizedBox(height: 12),
            const Text('輸入今日開獎 5 個號碼（1–39）',
                style: TextStyle(color: Colors.white54, fontSize: 11)),
            const SizedBox(height: 10),

            // 5 number inputs
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: List.generate(5, (i) {
                return Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 4),
                  child: _DrawnNumberBox(ctrl: _drawnCtrls[i]),
                );
              }),
            ),
            const SizedBox(height: 12),

            // Compare button
            Center(
              child: ElevatedButton.icon(
                onPressed: _compareDrawnNumbers,
                icon: const Icon(Icons.compare_arrows_rounded, size: 16),
                label: const Text('比對結果'),
                style: ElevatedButton.styleFrom(
                  backgroundColor: _gold.withAlpha(200),
                  foregroundColor: Colors.black,
                  textStyle: const TextStyle(fontWeight: FontWeight.w800, fontSize: 13),
                  padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 10),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                ),
              ),
            ),

            // Hit result
            if (_hitNumbers != null) ...[
              const SizedBox(height: 14),
              const Divider(color: Colors.white12),
              const SizedBox(height: 10),
              if (_hitNumbers!.isEmpty)
                const Center(
                  child: Text('本次未命中任何推薦號碼',
                      style: TextStyle(color: Colors.redAccent, fontSize: 13)),
                )
              else ...[
                Text(
                  '命中號碼：${_hitNumbers!.map((n) => n.toString().padLeft(2, '0')).join('  ')}',
                  style: const TextStyle(
                      color: Colors.greenAccent, fontSize: 13, fontWeight: FontWeight.w700),
                ),
                const SizedBox(height: 10),
                // Show all predicted numbers with hit highlight
                Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  children: predicted.map((n) {
                    final isHit = _hitNumbers!.contains(n);
                    return Container(
                      width: 36,
                      height: 36,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: isHit ? _gold : Colors.white.withAlpha(18),
                        border: isHit ? null : Border.all(color: Colors.white24),
                      ),
                      alignment: Alignment.center,
                      child: Text(
                        n.toString().padLeft(2, '0'),
                        style: TextStyle(
                          color: isHit ? Colors.black : Colors.white54,
                          fontSize: 11,
                          fontWeight: isHit ? FontWeight.w900 : FontWeight.w500,
                        ),
                      ),
                    );
                  }).toList(),
                ),
              ],
            ],
          ],
        ],
      ),
    );
  }

  // ── Header ─────────────────────────────────────────────────────

  Widget _headerSection() {
    return Row(
      children: [
        // 胖胖體育 logo（同一張熊貓照片）
        ClipRRect(
          borderRadius: BorderRadius.circular(16),
          child: Image.asset(
            'assets/bear.jpeg',
            width: 52,
            height: 52,
            fit: BoxFit.cover,
          ),
        ),
        const SizedBox(width: 12),
        const Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '財神爺樂透',
                style: TextStyle(
                  fontSize: 26,
                  fontWeight: FontWeight.w900,
                  color: _gold,
                  letterSpacing: 1,
                ),
              ),
              Text(
                '539 數據智能引擎',
                style: TextStyle(fontSize: 12, color: Color(0xAAFFD700)),
              ),
            ],
          ),
        ),
        if (_isRefreshing)
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: 12),
            child: SizedBox(
              width: 18, height: 18,
              child: CircularProgressIndicator(strokeWidth: 2, color: _gold),
            ),
          )
        else
          IconButton(
            onPressed: _load,
            icon: const Icon(Icons.refresh_rounded, color: _gold),
            tooltip: '重新分析',
          ),
      ],
    );
  }

  // ── Status Bar ─────────────────────────────────────────────────

  Widget _statusBar() {
    final hasNewspaper = _todayNewspaper != null;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
      decoration: BoxDecoration(
        color: Colors.black.withAlpha(55),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Column(
        children: [
          Row(
            children: [
              const Icon(Icons.calendar_today, size: 15, color: _gold),
              const SizedBox(width: 6),
              Text(
                _todayLabel,
                style: const TextStyle(
                  fontWeight: FontWeight.w600,
                  color: _gold,
                ),
              ),
              const Spacer(),
              const Icon(Icons.cancel_outlined, size: 15, color: Colors.orange),
              const SizedBox(width: 4),
              Text(
                '今日排除：${_taiwanNow.day.toString().padLeft(2, '0')}',
                style: const TextStyle(color: Colors.orange),
              ),
            ],
          ),
          if (hasNewspaper) ...[
            const SizedBox(height: 6),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
              decoration: BoxDecoration(
                color: _gold.withAlpha(25),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: _gold.withAlpha(60)),
              ),
              child: Row(
                children: [
                  const Text('📰', style: TextStyle(fontSize: 13)),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      '已載入喜雀神卦：孤支 ${_todayNewspaper!.guZhi.toString().padLeft(2, '0')}　'
                      '二中一 ${_todayNewspaper!.erZhong.map((n) => n.toString().padLeft(2, '0')).join(', ')}　'
                      '三中一 ${_todayNewspaper!.sanZhong.map((n) => n.toString().padLeft(2, '0')).join(', ')}',
                      style: TextStyle(
                          color: _gold.withAlpha(220),
                          fontSize: 10,
                          fontWeight: FontWeight.w600),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }


  // ── 預測卡片：只顯示5顆最可能號碼 ────────────────────────────

  Widget _predictionCard() {
    final results = _data?.results ?? [];
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 20),
      decoration: BoxDecoration(
        color: Colors.black.withAlpha(70),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: _gold.withAlpha(120), width: 1.5),
      ),
      child: Column(
        children: [
          Row(mainAxisAlignment: MainAxisAlignment.center, children: [
            const Icon(Icons.auto_awesome, color: _gold, size: 18),
            const SizedBox(width: 8),
            Text(
              () {
                final records = _data?.records539 ?? [];
                final key = _nextDrawKey(records);
                final todayKey = _todayDrawKey;
                return key == todayKey ? '今期最推薦號碼' : '下期最推薦號碼（$key）';
              }(),
              style: const TextStyle(
                  color: _gold, fontSize: 16, fontWeight: FontWeight.w900,
                  letterSpacing: 1.2),
            ),
          ]),
          const SizedBox(height: 20),
          if (_isLoading)
            const CircularProgressIndicator(color: _gold)
          else if (results.isEmpty)
            Text('資料載入中，請稍後…',
                style: TextStyle(color: Colors.white.withAlpha(160), fontSize: 13))
          else
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceEvenly,
              children: results.take(5).map((r) => _numberBubble(r.number)).toList(),
            ),
        ],
      ),
    );
  }

  Widget _numberBubble(int n) {
    return Container(
      width: 48,
      height: 48,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: _bgDeep,
        border: Border.all(color: _gold, width: 2),
      ),
      alignment: Alignment.center,
      child: Text(
        n.toString().padLeft(2, '0'),
        style: const TextStyle(
            color: _gold, fontWeight: FontWeight.w900, fontSize: 16),
      ),
    );
  }

  // ── 539 數據分析師 ─────────────────────────────────────────────

  Widget _dataAnalystSection() {
    final records = _data!.records539;
    final result = compute539Analysis(records, strategy: _current539Strategy);
    if (result.hotTop10.isEmpty) return const SizedBox();

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.black.withAlpha(70),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: _gold.withAlpha(100), width: 1.5),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 標題
          Row(children: [
            const Icon(Icons.analytics_rounded, color: _gold, size: 18),
            const SizedBox(width: 8),
            const Text('539 數據分析師',
                style: TextStyle(color: _gold, fontSize: 15, fontWeight: FontWeight.w900, letterSpacing: 1)),
          ]),
          const SizedBox(height: 14),

          // ── 熱門號碼 Top 10 ─────────────────────────────────
          const Text('🔥 熱門號碼（出現最多）',
              style: TextStyle(color: Colors.orangeAccent, fontSize: 12, fontWeight: FontWeight.w700)),
          const SizedBox(height: 6),
          Wrap(
            spacing: 6, runSpacing: 6,
            children: result.hotTop10.asMap().entries.map((e) {
              final rank = e.key + 1;
              final item = e.value;
              return Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                decoration: BoxDecoration(
                  color: Color.lerp(const Color(0xFFBF360C), const Color(0xFFFF6D00), e.key / 10)!.withAlpha(200),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text('$rank. ${item.number.toString().padLeft(2, '0')} (${item.frequency}次)',
                    style: const TextStyle(color: Colors.white, fontSize: 11, fontWeight: FontWeight.w700)),
              );
            }).toList(),
          ),
          const SizedBox(height: 12),

          // ── 冷門號碼 Top 10 ─────────────────────────────────
          const Text('❄️ 冷門號碼（出現最少）',
              style: TextStyle(color: Color(0xFF90CAF9), fontSize: 12, fontWeight: FontWeight.w700)),
          const SizedBox(height: 6),
          Wrap(
            spacing: 6, runSpacing: 6,
            children: result.coldTop10.asMap().entries.map((e) {
              final rank = e.key + 1;
              final item = e.value;
              return Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                decoration: BoxDecoration(
                  color: Color.lerp(const Color(0xFF0D47A1), const Color(0xFF1565C0), e.key / 10)!.withAlpha(200),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text('$rank. ${item.number.toString().padLeft(2, '0')} (${item.frequency}次)',
                    style: const TextStyle(color: Colors.white, fontSize: 11, fontWeight: FontWeight.w700)),
              );
            }).toList(),
          ),
          const SizedBox(height: 12),

          // ── 候選池 8 顆 ──────────────────────────────────────
          Row(children: [
            const Text('🎯 候選池（熱門5+冷門3）：',
                style: TextStyle(color: Colors.white70, fontSize: 12, fontWeight: FontWeight.w600)),
            const SizedBox(width: 6),
            Text(result.selectedPool.map((n) => n.toString().padLeft(2, '0')).join('  '),
                style: const TextStyle(color: _gold, fontSize: 13, fontWeight: FontWeight.w900)),
          ]),
          const SizedBox(height: 4),
          Text(
            '共 ${result.totalCombinations} 組組合 → 過濾奇偶/尾數後剩 ${result.validCombinations} 組優質組合',
            style: const TextStyle(color: Colors.white54, fontSize: 11),
          ),
          const SizedBox(height: 12),

          // ── 優質推薦組合 Top 5 ───────────────────────────────
          const Text('⭐ 優質推薦組合（評分最高）',
              style: TextStyle(color: _gold, fontSize: 12, fontWeight: FontWeight.w700)),
          const SizedBox(height: 8),
          ...result.topCombos.asMap().entries.map((e) {
            final rank = e.key + 1;
            final combo = e.value;
            return Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                decoration: BoxDecoration(
                  color: Colors.white.withAlpha(12),
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(color: _gold.withAlpha(rank == 1 ? 120 : 50)),
                ),
                child: Row(
                  children: [
                    Container(
                      width: 22,
                      height: 22,
                      decoration: BoxDecoration(
                        color: rank == 1 ? _gold : Colors.white.withAlpha(30),
                        shape: BoxShape.circle,
                      ),
                      alignment: Alignment.center,
                      child: Text('$rank',
                          style: TextStyle(
                            color: rank == 1 ? Colors.black : Colors.white70,
                            fontSize: 11, fontWeight: FontWeight.w900)),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(combo.display,
                          style: TextStyle(
                            color: rank == 1 ? _gold : Colors.white,
                            fontSize: 14,
                            fontWeight: FontWeight.w900,
                            letterSpacing: 2,
                          )),
                    ),
                    Text(combo.oddEvenLabel,
                        style: const TextStyle(color: Colors.white54, fontSize: 10)),
                    const SizedBox(width: 8),
                    Text('尾:${combo.tailDisplay}',
                        style: const TextStyle(color: Colors.white38, fontSize: 10)),
                  ],
                ),
              ),
            );
          }),
        ],
      ),
    );
  }

  // ── 歷史開獎區 ─────────────────────────────────────────────────

  Widget _historySection() {
    final labels = ['539', '大樂透', '威力彩'];
    final List<List<DrawRecord>> allRecords = [
      _data?.records539 ?? [],
      _data?.recordsLotto ?? [],
      _data?.recordsPower ?? [],
    ];

    return ClipRRect(
      borderRadius: BorderRadius.circular(10),
      child: Column(
        children: [
          GestureDetector(
            onTap: () =>
                setState(() => _showHistory = !_showHistory),
            child: Container(
              padding:
                  const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
              color: Colors.black.withAlpha(55),
              child: Row(
                children: [
                  const Icon(Icons.history_rounded, size: 16, color: _gold),
                  const SizedBox(width: 6),
                  const Text(
                    '近期開獎紀錄',
                    style: TextStyle(
                        fontSize: 13,
                        color: _gold,
                        fontWeight: FontWeight.w600),
                  ),
                  const Spacer(),
                  if (_isLoading)
                    const SizedBox(
                      width: 12,
                      height: 12,
                      child: CircularProgressIndicator(
                          strokeWidth: 1.5,
                          color: Color(0xB4FFD700)),
                    ),
                  const SizedBox(width: 6),
                  Icon(
                    _showHistory
                        ? Icons.expand_less
                        : Icons.expand_more,
                    color: _gold,
                    size: 18,
                  ),
                ],
              ),
            ),
          ),
          if (_showHistory) ...[
            // 分頁標籤
            Row(
              children: List.generate(3, (i) {
                final selected = _historyTab == i;
                return Expanded(
                  child: GestureDetector(
                    onTap: () =>
                        setState(() => _historyTab = i),
                    child: Container(
                      padding:
                          const EdgeInsets.symmetric(vertical: 7),
                      color: selected
                          ? _gold
                          : Colors.black.withAlpha(50),
                      child: Center(
                        child: Text(
                          labels[i],
                          style: TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.w700,
                            color: selected
                                ? Colors.black
                                : _gold.withAlpha(180),
                          ),
                        ),
                      ),
                    ),
                  ),
                );
              }),
            ),
            Container(
              color: Colors.black.withAlpha(33),
              child: allRecords[_historyTab].isEmpty
                  ? Padding(
                      padding: const EdgeInsets.all(16),
                      child: Center(
                        child: Text(
                          '無資料',
                          style: TextStyle(
                              fontSize: 12,
                              color: Colors.white.withAlpha(128)),
                        ),
                      ),
                    )
                  : Column(
                      children: allRecords[_historyTab]
                          .map((rec) => Column(
                                children: [
                                  Padding(
                                    padding: const EdgeInsets.symmetric(
                                        horizontal: 14, vertical: 7),
                                    child: Row(
                                      children: [
                                        SizedBox(
                                          width: 88,
                                          child: Text(
                                            rec.date,
                                            style: TextStyle(
                                              fontSize: 11,
                                              fontFamily: 'monospace',
                                              color: Colors.white
                                                  .withAlpha(165),
                                            ),
                                          ),
                                        ),
                                        Expanded(
                                          child: Text(
                                            rec.displayNumbers,
                                            style: const TextStyle(
                                              fontSize: 14,
                                              fontWeight: FontWeight.w700,
                                              fontFamily: 'monospace',
                                              color: _gold,
                                            ),
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                  Divider(
                                    height: 1,
                                    color: Colors.white.withAlpha(25),
                                  ),
                                ],
                              ))
                          .toList(),
                    ),
            ),
          ],
        ],
      ),
    );
  }

}

// ── 開獎號碼輸入格 ────────────────────────────────────────────────
class _DrawnNumberBox extends StatelessWidget {
  const _DrawnNumberBox({required this.ctrl});
  final TextEditingController ctrl;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 44,
      height: 44,
      child: TextField(
        controller: ctrl,
        keyboardType: TextInputType.number,
        inputFormatters: [FilteringTextInputFormatter.digitsOnly],
        textAlign: TextAlign.center,
        maxLength: 2,
        style: const TextStyle(
            color: Color(0xFFFFD700), fontSize: 15, fontWeight: FontWeight.w800),
        decoration: InputDecoration(
          counterText: '',
          hintText: '00',
          hintStyle: const TextStyle(color: Colors.white24, fontSize: 13),
          isDense: true,
          contentPadding: const EdgeInsets.symmetric(vertical: 10),
          enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(10),
            borderSide:
                const BorderSide(color: Color(0x66FFD700)),
          ),
          focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(10),
            borderSide:
                const BorderSide(color: Color(0xFFFFD700), width: 1.5),
          ),
          filled: true,
          fillColor: Colors.white.withAlpha(10),
        ),
      ),
    );
  }
}
