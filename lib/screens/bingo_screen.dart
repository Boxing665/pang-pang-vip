import 'dart:async';
import 'dart:math';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import '../services/bingo_service.dart';
import '../services/prediction_log_service.dart';
import '../services/self_learning_service.dart';

// Top-level functions required by compute() to run on separate isolate
// Argument: (records, strategyMode, zoneMultipliers)
BingoPrediction _computeAnalysis((List<BingoRecord>, String, Map<int, double>) arg) =>
    BingoService.analyze(arg.$1, seed: 0, strategyMode: arg.$2, zoneMultipliers: arg.$3);


List<AccuracySummary> _computeAccuracyIsolate(List<BingoRecord> records) =>
    BingoService.computeAccuracy(records, testDraws: 20);

/// 台灣賓果賓果預測頁面
///
/// 功能：
/// - 熱力球圖（顏色 = 熱度，深藍→橙→紅）
/// - 每顆球顯示距上次開出幾局
/// - 連帶分析（哪幾號最常一起開）
/// - 號碼統計（頻率 + 平均間隔）
/// - 倒數計時，T-3 分自動刷新
class BingoScreen extends StatefulWidget {
  const BingoScreen({super.key});

  @override
  State<BingoScreen> createState() => _BingoScreenState();
}

class _BingoScreenState extends State<BingoScreen>
    with TickerProviderStateMixin {
  final _service = BingoService();

  List<BingoRecord> _records = [];
  BingoPrediction? _pred;
  bool _isLoading = false;
  String _errorMsg = '';
  bool _alerted = false;
  int _secondsLeft = 0;
  int? _selectedBall;    // tapped ball number
  int _tab = 0;          // 0=連帶 1=頭遺漏 2=尾遺漏 3=統計 4=歷史 5=準確率 6=同出型態 7=型態分析
  List<AccuracySummary> _accuracy = [];

  Timer? _timer;
  late AnimationController _pulseCtrl;
  late Animation<double> _pulseAnim;

  // ── 顏色常數 ──────────────────────────────────────────────────
  static const _bg0   = Color(0xFF050E24);
  static const _bg1   = Color(0xFF0D1E4A);
  static const _gold  = Color(0xFFFFD700);
  static const _cyan  = Color(0xFF00E5FF);

  // 熱力圖顏色（冷 → 溫 → 熱）
  static const _colorCold   = Color(0xFF1A3A6B);
  static const _colorWarm   = Color(0xFFE8700A);
  static const _colorHot    = Color(0xFFFF1800);
  static const _colorLatest = Color(0xFFFFD700); // 本期開出

  @override
  void initState() {
    super.initState();
    _pulseCtrl = AnimationController(
        vsync: this, duration: const Duration(milliseconds: 1000))
      ..repeat(reverse: true);
    _pulseAnim = Tween<double>(begin: 0.5, end: 1.0)
        .animate(CurvedAnimation(parent: _pulseCtrl, curve: Curves.easeInOut));
    _load();
    _startTimer();
  }

  @override
  void dispose() {
    _timer?.cancel();
    _pulseCtrl.dispose();
    super.dispose();
  }

  // ── Data ─────────────────────────────────────────────────────

  final _logSvc = PredictionLogService();


  // 快取上一次的分析結果：若開獎號碼未變，直接沿用不重算
  int _cachedDrawNo = -1;
  int _lastRecordedDrawNo = -1; // 避免重複記錄區間命中
  BingoPrediction? _cachedPred;
  List<AccuracySummary> _cachedAccuracy = [];

  Future<void> _load({bool forceRefresh = false}) async {
    setState(() {
      _isLoading = true;
      _errorMsg = '';
    });
    final records = await _service.fetchRecent(forceRefresh: forceRefresh);
    final bingoStrategy = await SelfLearningService.getRecommendedBingoStrategy();
    BingoPrediction? pred;
    List<AccuracySummary> accuracy = [];
    if (records.isNotEmpty) {
      final latestDrawNo = records.first.drawNo;
      // 若最新一期與快取相同且非強制刷新，直接使用快取結果
      if (!forceRefresh && latestDrawNo == _cachedDrawNo && _cachedPred != null) {
        pred = _cachedPred;
        accuracy = _cachedAccuracy;
      } else {
        final zoneMultipliers = await SelfLearningService.getBingoZoneMultipliers();
        pred = await compute(_computeAnalysis, (records, bingoStrategy, zoneMultipliers));
        if (records.length >= 22) {
          accuracy = await compute(_computeAccuracyIsolate, records);
        }
        _cachedDrawNo = latestDrawNo;
        _cachedPred = pred;
        _cachedAccuracy = accuracy;
      }
    }

    // 自動比對已開獎期數，回填賓果準確率（免手動 key）
    final byDrawNo = <int, List<int>>{};
    for (final r in records) {
      if (r.numbers.isEmpty) continue;
      byDrawNo[r.drawNo] = r.numbers;
    }
    await _logSvc.autoReportBingoByDrawNo(byDrawNo);

    // 將最近一局的實際結果與預測比對，供 SelfLearningService 更新區間命中率
    // 若命中率持續低落，recordBingoDetail 會自動切換策略並回傳 true
    if (records.isNotEmpty && _cachedPred != null) {
      final latestActual = records.first.numbers;
      final latestDrawNo = records.first.drawNo;
      // 避免重複記錄：只在 drawNo 改變時記錄
      if (_lastRecordedDrawNo != latestDrawNo) {
        _lastRecordedDrawNo = latestDrawNo;
        final currentStrategy = await SelfLearningService.getRecommendedBingoStrategy();
        final switched = await SelfLearningService.recordBingoDetail(
          drawNo:    latestDrawNo,
          predicted: _cachedPred!.recommended + _cachedPred!.carryOverNumbers,
          actual:    latestActual,
          strategy:  currentStrategy,
        );
        // 策略已自動切換 → 清除快取強制重新預測（不需使用者手動按）
        if (switched) {
          _cachedDrawNo = -1;
          _cachedPred   = null;
        }
      }
    }

    // 儲存本期預測（每次載入都更新，確保最新預測存在）
    if (pred != null) {
      await _logSvc.saveBingoPrediction(
        drawNo: pred.nextDrawNo,
        groupLabel: '綜合',
        numbers: pred.recommended,
      );
      await _logSvc.saveBingoPrediction(
        drawNo: pred.nextDrawNo,
        groupLabel: '拖牌',
        numbers: pred.carryOverNumbers,
      );
    }

    if (!mounted) return;
    setState(() {
      _isLoading = false;
      _records = records;
      _accuracy = accuracy;
      if (pred != null) {
        _pred = pred;
      } else {
        _errorMsg = '資料載入失敗，請確認網路後重試';
      }
    });
  }

  void _startTimer() {
    _secondsLeft = BingoService.secondsToNextDraw();
    _timer = Timer.periodic(const Duration(seconds: 1), (_) async {
      if (!mounted) return;
      final s = BingoService.secondsToNextDraw();
      setState(() => _secondsLeft = s);
      if (!_alerted && s <= 180 && s > 0) {
        _alerted = true;
        await _load(forceRefresh: true);
        if (mounted && _pred != null) _showPredictionAlert();
      } else if (_alerted && s > 180) {
        _alerted = false;
        // 開獎後 15 秒自動刷新並觸發後台學習（無需使用者操作）
        Future.delayed(const Duration(seconds: 15), () async {
          if (!mounted) return;
          await _load(forceRefresh: true);
          // 後台自我學習：更新體育/大小分 Perceptron 權重
          SelfLearningService.runInBackground(_logSvc).ignore();
        });
      }
    });
  }

  void _showPredictionAlert() {
    if (_pred == null) return;
    final pred = _pred!;
    final latestNums =
        _records.isNotEmpty ? _records.first.numbers.toSet() : <int>{};
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (_) {
        return Container(
          decoration: BoxDecoration(
            gradient: const LinearGradient(
              colors: [Color(0xFF100020), Color(0xFF0A1535)],
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
            ),
            borderRadius:
                const BorderRadius.vertical(top: Radius.circular(24)),
            border: Border.all(color: Colors.red.withAlpha(180), width: 2),
            boxShadow: [
              BoxShadow(color: Colors.red.withAlpha(60), blurRadius: 24)
            ],
          ),
          padding: const EdgeInsets.fromLTRB(20, 16, 20, 32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // drag handle
              Container(
                width: 36,
                height: 4,
                decoration: BoxDecoration(
                    color: Colors.white24,
                    borderRadius: BorderRadius.circular(2)),
              ),
              const SizedBox(height: 14),
              // Title + countdown
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  const Text('⚡',
                      style: TextStyle(fontSize: 18)),
                  const SizedBox(width: 6),
                  Text(
                    '第 ${pred.nextDrawNo} 期 即將開獎',
                    style: const TextStyle(
                        color: Colors.red,
                        fontWeight: FontWeight.w900,
                        fontSize: 17,
                        letterSpacing: 1),
                  ),
                  const SizedBox(width: 6),
                  const Text('⚡',
                      style: TextStyle(fontSize: 18)),
                ],
              ),
              const SizedBox(height: 4),
              const Text(
                '🔁 連莊預測  ·  上期最可能再開的 6 顆',
                style: TextStyle(
                    color: Colors.white54, fontSize: 11),
              ),
              const SizedBox(height: 16),
              // Carry-over 6 balls
              if (pred.carryOverNumbers.isNotEmpty)
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceAround,
                  children: pred.carryOverNumbers.map((n) {
                    final s = pred.stats[n]!;
                    final isLatest = latestNums.contains(n);
                    final ballColor = isLatest
                        ? _colorLatest
                        : _heatColor(s.heatScore);
                    return Container(
                      width: 44,
                      height: 44,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: ballColor,
                        border: Border.all(
                            color: _gold.withAlpha(200), width: 1.5),
                        boxShadow: [
                          BoxShadow(
                              color: ballColor.withAlpha(120),
                              blurRadius: 8)
                        ],
                      ),
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Text(
                            n.toString().padLeft(2, '0'),
                            style: TextStyle(
                              fontSize: 13,
                              fontWeight: FontWeight.w900,
                              color: isLatest
                                  ? Colors.black
                                  : Colors.white,
                              height: 1,
                            ),
                          ),
                          Text(
                            s.gap == 0 ? '◎' : '${s.gap}',
                            style: TextStyle(
                              fontSize: 8,
                              color: isLatest
                                  ? Colors.black54
                                  : s.gap <= 4
                                      ? Colors.greenAccent
                                      : Colors.white54,
                              height: 1,
                            ),
                          ),
                        ],
                      ),
                    );
                  }).toList(),
                ),
              const SizedBox(height: 16),
              // Dismiss
              GestureDetector(
                onTap: () => Navigator.of(context).pop(),
                child: Container(
                  padding: const EdgeInsets.symmetric(
                      horizontal: 40, vertical: 10),
                  decoration: BoxDecoration(
                    color: Colors.red.withAlpha(40),
                    borderRadius: BorderRadius.circular(24),
                    border: Border.all(
                        color: Colors.red.withAlpha(120)),
                  ),
                  child: const Text('知道了',
                      style: TextStyle(
                          color: Colors.red,
                          fontWeight: FontWeight.w700,
                          fontSize: 14)),
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  // ── Helpers ───────────────────────────────────────────────────

  String _fmtCountdown(int s) {
    if (s <= 0) return '00:00';
    return '${(s ~/ 60).toString().padLeft(2, '0')}:'
        '${(s % 60).toString().padLeft(2, '0')}';
  }

  String get _nextTimeLabel {
    final dt = BingoService.nextDrawTime();
    return '${dt.hour.toString().padLeft(2, '0')}:'
        '${dt.minute.toString().padLeft(2, '0')}';
  }

  Color _heatColor(double heat) {
    if (heat >= 0.66) {
      return Color.lerp(_colorWarm, _colorHot, (heat - 0.66) / 0.34)!;
    } else if (heat >= 0.33) {
      return Color.lerp(_colorCold, _colorWarm, (heat - 0.33) / 0.33)!;
    } else {
      return Color.lerp(
          const Color(0xFF0A1F3B), _colorCold, heat / 0.33)!;
    }
  }

  // ══════════════════════════════════════════════════════════════
  //  BUILD
  // ══════════════════════════════════════════════════════════════

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: _bg0,
      body: Container(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            colors: [_bg0, _bg1],
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
          ),
        ),
        child: SafeArea(
          child: RefreshIndicator(
            color: _gold,
            backgroundColor: _bg1,
            onRefresh: () => _load(forceRefresh: true),
            child: CustomScrollView(
              slivers: [
                SliverToBoxAdapter(child: _header()),
                SliverToBoxAdapter(child: _countdownCard()),
                if (_isLoading && _pred == null)
                  SliverFillRemaining(child: _loadingView())
                else if (_errorMsg.isNotEmpty && _pred == null)
                  SliverFillRemaining(child: _errorView())
                else if (_pred != null) ...[
                  SliverToBoxAdapter(child: _latestDraw()),
                  SliverToBoxAdapter(child: _predictionPanel()),
                  SliverToBoxAdapter(child: _heatmapGrid()),
                  if (_selectedBall != null)
                    SliverToBoxAdapter(child: _ballDetail()),
                  SliverToBoxAdapter(child: _tabSection()),
                  const SliverToBoxAdapter(
                      child: SizedBox(height: 32)),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }

  // ── Header ────────────────────────────────────────────────────

  Widget _header() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 10, 14, 4),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('🎱 台灣賓果賓果',
                    style: TextStyle(
                        fontSize: 20,
                        fontWeight: FontWeight.w900,
                        color: _gold,
                        letterSpacing: 1)),
                Text(
                  '1–80 選 20・每 5 分鐘一局',
                  style: TextStyle(
                      fontSize: 11, color: _cyan.withAlpha(180)),
                ),
              ],
            ),
          ),
          if (_pred != null)
            Text(
              '分析 ${_pred!.analyzedDraws} 局',
              style: const TextStyle(color: Colors.white54, fontSize: 11),
            ),
          const SizedBox(width: 4),
          _isLoading
              ? const Padding(
                  padding: EdgeInsets.all(12),
                  child: SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(
                          color: _gold, strokeWidth: 2)))
              : IconButton(
                  icon: const Icon(Icons.refresh_rounded, color: _gold),
                  onPressed: () => _load(forceRefresh: true),
                ),
        ],
      ),
    );
  }

  // ── Countdown Card ────────────────────────────────────────────

  Widget _countdownCard() {
    final urgent = _secondsLeft <= 180 && _secondsLeft > 0;
    final borderColor = urgent ? Colors.red : _cyan.withAlpha(80);

    return AnimatedContainer(
      duration: const Duration(milliseconds: 300),
      margin: const EdgeInsets.symmetric(horizontal: 14, vertical: 4),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        color: Colors.black.withAlpha(urgent ? 90 : 50),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: borderColor, width: urgent ? 2 : 1),
        boxShadow: urgent
            ? [BoxShadow(
                color: Colors.red.withAlpha(60), blurRadius: 16)]
            : [],
      ),
      child: Row(
        children: [
          // Big countdown
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                urgent ? '⚡ 即將開獎' : '下局倒數',
                style: TextStyle(
                    color: urgent ? Colors.red : _cyan,
                    fontSize: 11,
                    fontWeight: FontWeight.w600),
              ),
              const SizedBox(height: 2),
              urgent
                  ? FadeTransition(
                      opacity: _pulseAnim,
                      child: _countdownText(urgent),
                    )
                  : _countdownText(urgent),
            ],
          ),
          const SizedBox(width: 16),
          // Right side info
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Text('開獎時間 $_nextTimeLabel',
                    style:
                        const TextStyle(color: Colors.white70, fontSize: 12)),
                if (_pred != null && _pred!.nextDrawNo > 0)
                  Text(
                    '第 ${_pred!.nextDrawNo} 期',
                    style: TextStyle(
                        color: _gold.withAlpha(200),
                        fontSize: 11,
                        fontWeight: FontWeight.w600),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _countdownText(bool urgent) {
    return Text(
      _fmtCountdown(_secondsLeft),
      style: TextStyle(
        fontSize: 38,
        fontWeight: FontWeight.w900,
        color: urgent ? Colors.red : _cyan,
        fontFeatures: const [FontFeature.tabularFigures()],
        height: 1,
      ),
    );
  }

  // ── Latest Draw Strip ─────────────────────────────────────────
  // Colors: green = last draw, red = repeated from prev draw, pink = last ball drawn

  static const _colorDrawGreen = Color(0xFF00CC44);
  static const _colorDrawRed   = Color(0xFFFF2222);
  static const _colorDrawPink  = Color(0xFFFF69B4);

  Widget _latestDraw() {
    if (_records.isEmpty) return const SizedBox();
    final r = _records.first;
    final prevNums = _records.length > 1 ? _records[1].numbers.toSet() : <int>{};
    final lastBall = r.numbers.isNotEmpty ? r.numbers.last : -1;

    Color _ballColor(int n) {
      if (n == lastBall) return _colorDrawPink;
      if (prevNums.contains(n)) return _colorDrawRed;
      return _colorDrawGreen;
    }

    return Container(
      margin: const EdgeInsets.fromLTRB(14, 6, 14, 6),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.black.withAlpha(60),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: _gold.withAlpha(60)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.emoji_events, color: _gold, size: 14),
              const SizedBox(width: 4),
              Text('最新: 第 ${r.drawNo} 期  ${r.drawTime}',
                  style: const TextStyle(
                      color: _gold, fontWeight: FontWeight.w700, fontSize: 12)),
              if (r.superNum.isNotEmpty) ...[
                const Spacer(),
                Text(' 超獎 ${r.superNum}',
                    style: const TextStyle(color: Colors.orange, fontSize: 11)),
              ],
            ],
          ),
          const SizedBox(height: 4),
          Row(
            children: [
              _legendDot(_colorDrawGreen, '本期'),
              const SizedBox(width: 10),
              _legendDot(_colorDrawRed, '重複'),
              const SizedBox(width: 10),
              _legendDot(_colorDrawPink, '最後一顆'),
            ],
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 5,
            runSpacing: 5,
            children: r.numbers.map((n) {
              final c = _ballColor(n);
              return Container(
                width: 32,
                height: 32,
                decoration: BoxDecoration(
                  color: c,
                  shape: BoxShape.circle,
                  boxShadow: [BoxShadow(color: c.withAlpha(100), blurRadius: 5)],
                ),
                alignment: Alignment.center,
                child: Text(
                  n.toString().padLeft(2, '0'),
                  style: TextStyle(
                    fontSize: 10,
                    fontWeight: FontWeight.w900,
                    color: c == _colorDrawGreen ? Colors.white : Colors.white,
                  ),
                ),
              );
            }).toList(),
          ),
        ],
      ),
    );
  }

  Widget _legendDot(Color c, String label) => Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      Container(width: 9, height: 9, decoration: BoxDecoration(color: c, shape: BoxShape.circle)),
      const SizedBox(width: 3),
      Text(label, style: const TextStyle(color: Colors.white54, fontSize: 9)),
    ],
  );

  // ── Prediction Panel (胖胖最強推薦 - 單一最佳預測) ─────────────

  // 合併所有演算法：同出配對 + 熱度 + 遺漏率 → 選出最佳 8 顆
  List<int> _computeBestPick(BingoPrediction pred) {
    final scoreMap = <int, double>{};
    for (var n = 1; n <= 80; n++) {
      final s = pred.stats[n];
      if (s == null) continue;
      double sc = s.heatScore * 0.4;
      // 遺漏加分：距上次開出越久，越有補開機會
      final gapRatio = s.avgGap > 0 ? (s.gap / s.avgGap).clamp(0.0, 2.0) : 0.0;
      sc += gapRatio * 0.25;
      // 同出（co-occurrence）配對加分
      for (final p in pred.topPairs) {
        if (p.a == n || p.b == n) sc += p.rate * 0.15;
      }
      // 已在 recommended 加分
      if (pred.recommended.contains(n)) sc += 0.2;
      // carryOver 加分
      if (pred.carryOverNumbers.contains(n)) sc += 0.15;
      scoreMap[n] = sc;
    }
    final sorted = scoreMap.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));
    return sorted.take(8).map((e) => e.key).toList()..sort();
  }

  Widget _predictionPanel() {
    final pred = _pred;
    if (pred == null) return const SizedBox();
    final bestPick = _computeBestPick(pred);
    final latestNums = _records.isNotEmpty ? _records.first.numbers.toSet() : <int>{};

    return Container(
      margin: const EdgeInsets.fromLTRB(14, 6, 14, 6),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          colors: [Color(0xFF100828), Color(0xFF0A1535)],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: _gold.withAlpha(100), width: 1.5),
        boxShadow: [BoxShadow(color: _gold.withAlpha(40), blurRadius: 14)],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Text('🎱', style: TextStyle(fontSize: 17)),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  '胖胖最強推薦  ·  第 ${pred.nextDrawNo} 期',
                  style: const TextStyle(
                    color: _gold, fontWeight: FontWeight.w900, fontSize: 16, letterSpacing: 0.5),
                ),
              ),
            ],
          ),
          if (pred.strategy.isNotEmpty) ...[
            const SizedBox(height: 4),
            Text(pred.strategy,
                style: TextStyle(color: _cyan.withAlpha(200), fontSize: 11)),
          ],
          const SizedBox(height: 14),
          // 8 best balls
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceAround,
            children: bestPick.map((n) {
              final s = pred.stats[n]!;
              final isLatest = latestNums.contains(n);
              final c = isLatest ? _colorLatest : _heatColor(s.heatScore);
              return Container(
                width: 50,
                height: 50,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: c,
                  border: Border.all(color: _gold.withAlpha(180), width: 1.8),
                  boxShadow: [BoxShadow(color: c.withAlpha(120), blurRadius: 10)],
                ),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Text(
                      n.toString().padLeft(2, '0'),
                      style: TextStyle(
                        fontSize: 14, fontWeight: FontWeight.w900,
                        color: isLatest ? Colors.black : Colors.white, height: 1),
                    ),
                    Text(
                      s.gap == 0 ? '◎' : '${s.gap}',
                      style: TextStyle(
                        fontSize: 8,
                        color: isLatest ? Colors.black54 : s.gap <= 4 ? Colors.greenAccent : Colors.white54,
                        height: 1.1),
                    ),
                  ],
                ),
              );
            }).toList(),
          ),
          const SizedBox(height: 12),
          Text(
            '★ 綜合同出配對 · 熱度 · 遺漏率三維評分，自動選出最佳 8 顆',
            style: TextStyle(color: Colors.white38, fontSize: 10),
          ),
        ],
      ),
    );
  }

  // ── Hot/Cold Number Lists (替換舊圓球熱力圖) ────────────────────

  Widget _heatmapGrid() {
    final pred = _pred!;
    // 按頻率排序：hotNumbers 已是高→低，coldNumbers 已是低→高
    final hot = pred.hotNumbers;
    final cold = pred.coldNumbers;

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // ── 熱門號碼 ──────────────────────────────────────────
          const Text('🔥 熱門號碼（出現最多 → 最少）',
              style: TextStyle(color: Colors.orangeAccent, fontWeight: FontWeight.w700, fontSize: 13)),
          const SizedBox(height: 8),
          _numberRankList(hot.take(20).toList(), isHot: true, pred: pred),
          const SizedBox(height: 14),
          // ── 冷門號碼 ──────────────────────────────────────────
          const Text('❄️ 冷門號碼（出現最少 → 最多）',
              style: TextStyle(color: Color(0xFF64B5F6), fontWeight: FontWeight.w700, fontSize: 13)),
          const SizedBox(height: 8),
          _numberRankList(cold.take(20).toList(), isHot: false, pred: pred),
        ],
      ),
    );
  }

  Widget _numberRankList(List<int> nums, {required bool isHot, required BingoPrediction pred}) {
    return Wrap(
      spacing: 6,
      runSpacing: 6,
      children: nums.asMap().entries.map((entry) {
        final rank = entry.key + 1;
        final n = entry.value;
        final s = pred.stats[n]!;
        final bg = isHot
            ? Color.lerp(const Color(0xFFE65100), const Color(0xFFFF1800), entry.key / nums.length)!
            : Color.lerp(const Color(0xFF1565C0), const Color(0xFF0D1B4A), entry.key / nums.length)!;
        return Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
          decoration: BoxDecoration(
            color: bg.withAlpha(200),
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: bg.withAlpha(120)),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                '$rank.',
                style: const TextStyle(color: Colors.white38, fontSize: 9, fontWeight: FontWeight.w600),
              ),
              const SizedBox(width: 3),
              Text(
                n.toString().padLeft(2, '0'),
                style: const TextStyle(color: Colors.white, fontSize: 13, fontWeight: FontWeight.w900),
              ),
              const SizedBox(width: 4),
              Text(
                '${s.frequency}次',
                style: const TextStyle(color: Colors.white60, fontSize: 9),
              ),
            ],
          ),
        );
      }).toList(),
    );
  }

  Widget _legendItem(Color c, String label) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
            width: 10,
            height: 10,
            decoration: BoxDecoration(color: c, shape: BoxShape.circle)),
        const SizedBox(width: 3),
        Text(label, style: const TextStyle(color: Colors.white60, fontSize: 9)),
      ],
    );
  }

  // ── Ball Detail Panel ─────────────────────────────────────────

  Widget _ballDetail() {
    final n = _selectedBall!;
    final s = _pred!.stats[n]!;
    final partners = _pred!.topPairs
        .where((p) => p.a == n || p.b == n)
        .take(5)
        .toList();

    return Container(
      margin: const EdgeInsets.fromLTRB(14, 8, 14, 4),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.white.withAlpha(15),
        borderRadius: BorderRadius.circular(12),
        border:
            Border.all(color: Colors.white.withAlpha(40)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 36,
                height: 36,
                decoration: BoxDecoration(
                  color: _heatColor(s.heatScore),
                  shape: BoxShape.circle,
                ),
                alignment: Alignment.center,
                child: Text(
                  n.toString().padLeft(2, '0'),
                  style: const TextStyle(
                      fontWeight: FontWeight.w900,
                      fontSize: 14,
                      color: Colors.white),
                ),
              ),
              const SizedBox(width: 12),
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('號碼 $n 詳細統計',
                      style: const TextStyle(
                          color: _gold,
                          fontWeight: FontWeight.w700,
                          fontSize: 13)),
                  const SizedBox(height: 2),
                  Text(
                    '熱度指數：${(s.heatScore * 100).round()}%  |  '
                    '頻率：${s.frequency} 次 / ${_pred!.analyzedDraws} 局',
                    style: const TextStyle(
                        color: Colors.white70, fontSize: 11),
                  ),
                  Text(
                    '距上次：${s.gapLabel}  |  平均每 ${s.avgGap.toStringAsFixed(1)} 局開一次',
                    style: const TextStyle(
                        color: Colors.white70, fontSize: 11),
                  ),
                ],
              ),
              const Spacer(),
              GestureDetector(
                onTap: () => setState(() => _selectedBall = null),
                child: const Icon(Icons.close,
                    color: Colors.white38, size: 18),
              ),
            ],
          ),
          if (partners.isNotEmpty) ...[
            const SizedBox(height: 10),
            Text('最常一起出現的號碼（連帶）',
                style: TextStyle(
                    color: Colors.purpleAccent.withAlpha(200),
                    fontSize: 11,
                    fontWeight: FontWeight.w600)),
            const SizedBox(height: 6),
            Wrap(
              spacing: 6,
              runSpacing: 4,
              children: partners.map((p) {
                final partner = p.a == n ? p.b : p.a;
                return Container(
                  padding: const EdgeInsets.symmetric(
                      horizontal: 8, vertical: 4),
                  decoration: BoxDecoration(
                    color: Colors.purple.withAlpha(60),
                    borderRadius: BorderRadius.circular(20),
                    border: Border.all(
                        color: Colors.purple.withAlpha(120)),
                  ),
                  child: Text(
                    '${partner.toString().padLeft(2, '0')}  '
                    '${p.count}次 (${(p.rate * 100).round()}%)',
                    style: const TextStyle(
                        color: Colors.white70, fontSize: 10),
                  ),
                );
              }).toList(),
            ),
          ],
        ],
      ),
    );
  }

  // ── Tab Section ───────────────────────────────────────────────

  Widget _tabSection() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 10, 14, 0),
      child: Column(
        children: [
          // Tab bar – scrollable row
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              children: [
                _tabBtn(0, '🔗 連帶'),
                const SizedBox(width: 6),
                _tabBtn(1, '🔢 頭號遺漏'),
                const SizedBox(width: 6),
                _tabBtn(2, '🔢 尾號遺漏'),
                const SizedBox(width: 6),
                _tabBtn(3, '📊 統計'),
                const SizedBox(width: 6),
                _tabBtn(4, '📋 歷史'),
                const SizedBox(width: 6),
                _tabBtn(5, '📈 準確率'),
                const SizedBox(width: 6),
                _tabBtn(6, '🧩 同出/型態'),
                const SizedBox(width: 6),
                _tabBtn(7, '🗺️ 型態分析'),
              ],
            ),
          ),
          const SizedBox(height: 10),
          if (_tab == 0) _coOccurrenceTab(),
          if (_tab == 1) _headGapTab(),
          if (_tab == 2) _tailGapTab(),
          if (_tab == 3) _statsTab(),
          if (_tab == 4) _historyTab(),
          if (_tab == 5) _accuracyTab(),
          if (_tab == 6) _patternTab(),
          if (_tab == 7) _drawPatternTab(),
        ],
      ),
    );
  }

  Widget _patternTab() {
    final pred = _pred!;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          '同出組合與型態未開分析（共 ${pred.analyzedDraws} 局）',
          style: const TextStyle(color: Colors.white54, fontSize: 11),
        ),
        const SizedBox(height: 10),
        _comboSection('二同出', pred.topTwoCombos),
        const SizedBox(height: 10),
        _comboSection('三同出', pred.topThreeCombos),
        const SizedBox(height: 10),
        _comboSection('四同出', pred.topFourCombos),
        const SizedBox(height: 10),
        _balanceSection('大小未開', pred.bigSmallPatterns),
        const SizedBox(height: 10),
        _balanceSection('單雙未開', pred.oddEvenPatterns),
      ],
    );
  }

  Widget _comboSection(String title, List<ComboPatternStat> data) {
    if (data.isEmpty) return _emptyMsg('$title 資料不足');
    return Container(
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: Colors.white.withAlpha(10),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: Colors.white.withAlpha(25)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title,
              style: const TextStyle(
                  color: _gold, fontSize: 12, fontWeight: FontWeight.w700)),
          const SizedBox(height: 6),
          ...data.take(6).map((c) {
            final label = c.numbers.map((n) => n.toString().padLeft(2, '0')).join(' ');
            return Padding(
              padding: const EdgeInsets.only(bottom: 5),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      label,
                      style: const TextStyle(color: Colors.white, fontSize: 11),
                    ),
                  ),
                  Text('出現${c.count}次',
                      style: const TextStyle(color: Colors.white54, fontSize: 10)),
                  const SizedBox(width: 8),
                  Text('未開${c.gap}期',
                      style: const TextStyle(color: Colors.orange, fontSize: 10)),
                  const SizedBox(width: 8),
                  Text(
                    c.suggestAfter == 0 ? '建議下期' : '建議${c.suggestAfter}期後',
                    style: TextStyle(
                      color: c.suggestAfter == 0 ? Colors.greenAccent : Colors.cyanAccent,
                      fontSize: 10,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ],
              ),
            );
          }),
        ],
      ),
    );
  }

  Widget _balanceSection(String title, List<BalancePatternStat> data) {
    if (data.isEmpty) return _emptyMsg('$title 資料不足');
    return Container(
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: Colors.white.withAlpha(10),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: Colors.white.withAlpha(25)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title,
              style: const TextStyle(
                  color: _gold, fontSize: 12, fontWeight: FontWeight.w700)),
          const SizedBox(height: 6),
          ...data.take(6).map((p) {
            return Padding(
              padding: const EdgeInsets.only(bottom: 5),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      p.label,
                      style: const TextStyle(color: Colors.white, fontSize: 11),
                    ),
                  ),
                  Text('出現${p.count}次',
                      style: const TextStyle(color: Colors.white54, fontSize: 10)),
                  const SizedBox(width: 8),
                  Text('未開${p.gap}期',
                      style: const TextStyle(color: Colors.orange, fontSize: 10)),
                  const SizedBox(width: 8),
                  Text(
                    p.suggestAfter == 0 ? '建議下期' : '建議${p.suggestAfter}期後',
                    style: TextStyle(
                      color: p.suggestAfter == 0 ? Colors.greenAccent : Colors.cyanAccent,
                      fontSize: 10,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ],
              ),
            );
          }),
        ],
      ),
    );
  }

  Widget _tabBtn(int idx, String label) {
    final active = _tab == idx;
    return GestureDetector(
      onTap: () => setState(() => _tab = idx),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        decoration: BoxDecoration(
          color: active
              ? _cyan.withAlpha(40)
              : Colors.white.withAlpha(10),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(
              color: active
                  ? _cyan.withAlpha(120)
                  : Colors.white.withAlpha(20)),
        ),
        child: Text(
          label,
          style: TextStyle(
            fontSize: 11,
            fontWeight:
                active ? FontWeight.w700 : FontWeight.normal,
            color: active ? _cyan : Colors.white54,
          ),
        ),
      ),
    );
  }

  // ── 頭號遺漏分析 Tab ───────────────────────────────────────────

  Widget _headGapTab() {
    final pred = _pred!;
    // 1頭(10-19) … 7頭(70-79)，每頭 10 顆，橫排顯示
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          '頭號遺漏分析（1頭–7頭 × 10 星）  ·  共 ${pred.analyzedDraws} 局',
          style: const TextStyle(color: Colors.white54, fontSize: 11),
        ),
        const SizedBox(height: 4),
        Text(
          '數字 = 幾期未開  ·  紅色 = 超過平均間隔，建議關注',
          style: const TextStyle(color: Colors.white38, fontSize: 10),
        ),
        const SizedBox(height: 10),
        ...List.generate(7, (hi) {
          final headDigit = hi + 1; // 1~7
          final numbers = List.generate(
              10, (j) => headDigit * 10 + j); // 10-19, 20-29, ..., 70-79
          return _headGapRow(headDigit, numbers, pred);
        }),
      ],
    );
  }

  Widget _headGapRow(int headDigit, List<int> numbers, BingoPrediction pred) {
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 8),
      decoration: BoxDecoration(
        color: Colors.white.withAlpha(8),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: Colors.white.withAlpha(20)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '$headDigit 頭  (${headDigit}0–${headDigit}9)',
            style: const TextStyle(
                color: _gold, fontSize: 11, fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 6),
          Row(
            children: numbers.map((n) {
              if (n > 80) return const SizedBox();
              final s = pred.stats[n];
              if (s == null) return const SizedBox();
              final isDue = s.gap >= s.avgGap;
              final suggestAfter = isDue
                  ? 0
                  : max(0, (s.avgGap - s.gap).ceil());
              return Expanded(
                child: GestureDetector(
                  onTap: () => setState(() =>
                      _selectedBall = _selectedBall == n ? null : n),
                  child: Container(
                    margin: const EdgeInsets.symmetric(horizontal: 1),
                    padding: const EdgeInsets.symmetric(vertical: 4),
                    decoration: BoxDecoration(
                      color: isDue
                          ? Colors.red.withAlpha(40)
                          : s.gap == 0
                              ? _gold.withAlpha(40)
                              : Colors.white.withAlpha(8),
                      borderRadius: BorderRadius.circular(6),
                      border: Border.all(
                        color: isDue
                            ? Colors.red.withAlpha(100)
                            : s.gap == 0
                                ? _gold.withAlpha(80)
                                : Colors.white.withAlpha(15),
                      ),
                    ),
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Text(
                          n.toString().padLeft(2, '0'),
                          style: TextStyle(
                            fontSize: 9,
                            fontWeight: FontWeight.w800,
                            color: isDue
                                ? Colors.red.shade300
                                : s.gap == 0
                                    ? _gold
                                    : Colors.white70,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          s.gap == 0 ? '◎' : '${s.gap}',
                          style: TextStyle(
                            fontSize: 11,
                            fontWeight: FontWeight.w900,
                            color: isDue
                                ? Colors.red
                                : s.gap == 0
                                    ? _gold
                                    : s.gap <= 4
                                        ? Colors.greenAccent
                                        : Colors.white54,
                          ),
                        ),
                        if (isDue)
                          const Text('▲',
                              style: TextStyle(
                                  color: Colors.red,
                                  fontSize: 7,
                                  height: 1))
                        else
                          Text(
                            suggestAfter <= 0
                                ? ''
                                : '$suggestAfter期',
                            style: const TextStyle(
                                color: Colors.white38,
                                fontSize: 7,
                                height: 1),
                          ),
                      ],
                    ),
                  ),
                ),
              );
            }).toList(),
          ),
        ],
      ),
    );
  }

  // ── 尾號遺漏分析 Tab ───────────────────────────────────────────

  Widget _tailGapTab() {
    final pred = _pred!;
    // 1尾(01,11,...,71) … 9尾(09,19,...,79) + 0尾(10,20,...,80)
    // 直排顯示：每尾一行，8 顆
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          '尾號遺漏分析（1尾–0尾 × 8 星）  ·  共 ${pred.analyzedDraws} 局',
          style: const TextStyle(color: Colors.white54, fontSize: 11),
        ),
        const SizedBox(height: 4),
        Text(
          '數字 = 幾期未開  ·  紅色 = 超過平均間隔，建議關注',
          style: const TextStyle(color: Colors.white38, fontSize: 10),
        ),
        const SizedBox(height: 10),
        // 1尾~9尾, then 0尾
        ...List.generate(10, (ti) {
          final tailDigit = (ti + 1) % 10; // 1,2,...,9,0
          List<int> numbers;
          if (tailDigit == 0) {
            // 0 尾: 10, 20, 30, 40, 50, 60, 70, 80
            numbers = [10, 20, 30, 40, 50, 60, 70, 80];
          } else {
            // N 尾: 0N, 1N, 2N, 3N, 4N, 5N, 6N, 7N
            numbers = List.generate(8, (j) => j * 10 + tailDigit);
            // j=0 → tailDigit (e.g. 01), j=1 → 10+tailDigit, ..., j=7 → 70+tailDigit
          }
          return _tailGapRow(tailDigit, numbers, pred);
        }),
      ],
    );
  }

  Widget _tailGapRow(int tailDigit, List<int> numbers, BingoPrediction pred) {
    return Container(
      margin: const EdgeInsets.only(bottom: 6),
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
      decoration: BoxDecoration(
        color: Colors.white.withAlpha(8),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: Colors.white.withAlpha(20)),
      ),
      child: Row(
        children: [
          // Tail label
          SizedBox(
            width: 40,
            child: Text(
              '$tailDigit 尾',
              style: const TextStyle(
                  color: _gold,
                  fontSize: 11,
                  fontWeight: FontWeight.w700),
            ),
          ),
          // 8 numbers
          ...numbers.map((n) {
            if (n < 1 || n > 80) return const Expanded(child: SizedBox());
            final s = pred.stats[n];
            if (s == null) return const Expanded(child: SizedBox());
            final isDue = s.gap >= s.avgGap;
            final suggestAfter = isDue
                ? 0
                : max(0, (s.avgGap - s.gap).ceil());
            return Expanded(
              child: GestureDetector(
                onTap: () => setState(() =>
                    _selectedBall = _selectedBall == n ? null : n),
                child: Container(
                  margin: const EdgeInsets.symmetric(horizontal: 1),
                  padding: const EdgeInsets.symmetric(vertical: 4),
                  decoration: BoxDecoration(
                    color: isDue
                        ? Colors.red.withAlpha(40)
                        : s.gap == 0
                            ? _gold.withAlpha(40)
                            : Colors.white.withAlpha(8),
                    borderRadius: BorderRadius.circular(6),
                    border: Border.all(
                      color: isDue
                          ? Colors.red.withAlpha(100)
                          : s.gap == 0
                              ? _gold.withAlpha(80)
                              : Colors.white.withAlpha(15),
                    ),
                  ),
                  child: Column(
                    children: [
                      Text(
                        n.toString().padLeft(2, '0'),
                        style: TextStyle(
                          fontSize: 9,
                          fontWeight: FontWeight.w800,
                          color: isDue
                              ? Colors.red.shade300
                              : s.gap == 0
                                  ? _gold
                                  : Colors.white70,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        s.gap == 0 ? '◎' : '${s.gap}',
                        style: TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w900,
                          color: isDue
                              ? Colors.red
                              : s.gap == 0
                                  ? _gold
                                  : s.gap <= 4
                                      ? Colors.greenAccent
                                      : Colors.white54,
                        ),
                      ),
                      if (isDue)
                        const Text('▲',
                            style: TextStyle(
                                color: Colors.red,
                                fontSize: 7,
                                height: 1))
                      else
                        Text(
                          suggestAfter <= 0
                              ? ''
                              : '$suggestAfter期',
                          style: const TextStyle(
                              color: Colors.white38,
                              fontSize: 7,
                              height: 1),
                        ),
                    ],
                  ),
                ),
              ),
            );
          }),
        ],
      ),
    );
  }

  // ── 連帶分析 Tab ──────────────────────────────────────────────

  Widget _coOccurrenceTab() {
    final pairs = _pred!.topPairs.take(15).toList();
    if (pairs.isEmpty) {
      return _emptyMsg('歷史資料不足，無法計算連帶');
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: Text(
            '最常一起出現的號碼組合（共分析 ${_pred!.analyzedDraws} 局）',
            style: const TextStyle(
                color: Colors.white54, fontSize: 11),
          ),
        ),
        ...pairs.asMap().entries.map((e) {
          final rank = e.key + 1;
          final p = e.value;
          final pct = (p.rate * 100).round();
          // bar width
          final barFraction = pairs.first.count > 0
              ? p.count / pairs.first.count
              : 0.0;
          return Container(
            margin: const EdgeInsets.only(bottom: 6),
            padding: const EdgeInsets.symmetric(
                horizontal: 10, vertical: 8),
            decoration: BoxDecoration(
              color: Colors.purple.withAlpha(rank <= 3 ? 40 : 20),
              borderRadius: BorderRadius.circular(10),
              border: Border.all(
                  color: Colors.purple.withAlpha(rank <= 3 ? 80 : 30)),
            ),
            child: Row(
              children: [
                // Rank
                SizedBox(
                  width: 22,
                  child: Text(
                    '$rank',
                    style: TextStyle(
                        color: rank <= 3
                            ? _gold
                            : Colors.white38,
                        fontWeight: FontWeight.w700,
                        fontSize: 12),
                  ),
                ),
                // Ball pair
                _pairBall(p.a),
                const SizedBox(width: 4),
                const Text('+',
                    style: TextStyle(
                        color: Colors.white54, fontSize: 12)),
                const SizedBox(width: 4),
                _pairBall(p.b),
                const SizedBox(width: 10),
                // Count + bar
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '${p.count} 次  ($pct%)',
                        style: const TextStyle(
                            color: Colors.white70,
                            fontSize: 11),
                      ),
                      const SizedBox(height: 3),
                      ClipRRect(
                        borderRadius: BorderRadius.circular(4),
                        child: LinearProgressIndicator(
                          value: barFraction,
                          minHeight: 4,
                          backgroundColor:
                              Colors.purple.withAlpha(30),
                          valueColor:
                              const AlwaysStoppedAnimation<Color>(
                                  Colors.purpleAccent),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          );
        }),
      ],
    );
  }

  Widget _pairBall(int n) {
    final s = _pred!.stats[n]!;
    return Container(
      width: 28,
      height: 28,
      decoration: BoxDecoration(
        color: _heatColor(s.heatScore),
        shape: BoxShape.circle,
      ),
      alignment: Alignment.center,
      child: Text(
        n.toString().padLeft(2, '0'),
        style: const TextStyle(
            fontSize: 9,
            fontWeight: FontWeight.w800,
            color: Colors.white),
      ),
    );
  }

  // ── 號碼統計 Tab ──────────────────────────────────────────────

  Widget _statsTab() {
    final pred = _pred!;
    final statsList = pred.stats.values.toList()
      ..sort((a, b) => b.frequency.compareTo(a.frequency));

    return Column(
      children: statsList.map((s) {
        final barFraction = statsList.first.frequency > 0
            ? s.frequency / statsList.first.frequency
            : 0.0;
        final isHot = pred.hotNumbers.contains(s.number);
        final isCold = pred.coldNumbers.contains(s.number);

        return Container(
          margin: const EdgeInsets.only(bottom: 4),
          padding: const EdgeInsets.symmetric(
              horizontal: 10, vertical: 6),
          decoration: BoxDecoration(
            color: Colors.white.withAlpha(
                s.number % 2 == 0 ? 8 : 5),
            borderRadius: BorderRadius.circular(8),
          ),
          child: Row(
            children: [
              // Ball
              GestureDetector(
                onTap: () {
                  setState(() {
                    _selectedBall = _selectedBall == s.number
                        ? null
                        : s.number;
                  });
                },
                child: Container(
                  width: 28,
                  height: 28,
                  decoration: BoxDecoration(
                    color: _heatColor(s.heatScore),
                    shape: BoxShape.circle,
                    border: _selectedBall == s.number
                        ? Border.all(
                            color: Colors.white, width: 1.5)
                        : null,
                  ),
                  alignment: Alignment.center,
                  child: Text(
                    s.number.toString().padLeft(2, '0'),
                    style: const TextStyle(
                        fontSize: 9,
                        fontWeight: FontWeight.w800,
                        color: Colors.white),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              // Stats
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Text(
                          '${s.frequency} 次  ',
                          style: TextStyle(
                              color: isHot
                                  ? Colors.orange
                                  : isCold
                                      ? _cyan
                                      : Colors.white70,
                              fontSize: 11,
                              fontWeight: FontWeight.w600),
                        ),
                        Text(
                          '最近 ${s.gapLabel}  平均 ${s.avgGap.toStringAsFixed(1)} 局/次',
                          style: const TextStyle(
                              color: Colors.white38,
                              fontSize: 10),
                        ),
                        const Spacer(),
                        if (isHot)
                          const Text('🔥',
                              style: TextStyle(fontSize: 10))
                        else if (isCold)
                          const Text('❄️',
                              style: TextStyle(fontSize: 10)),
                      ],
                    ),
                    const SizedBox(height: 3),
                    ClipRRect(
                      borderRadius: BorderRadius.circular(4),
                      child: LinearProgressIndicator(
                        value: barFraction,
                        minHeight: 3,
                        backgroundColor:
                            Colors.white.withAlpha(15),
                        valueColor: AlwaysStoppedAnimation<Color>(
                            _heatColor(s.heatScore)),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        );
      }).toList(),
    );
  }

  // ── 歷史開獎 Tab ──────────────────────────────────────────────

  Widget _historyTab() {
    if (_records.isEmpty) return _emptyMsg('無歷史資料');
    return Column(
      children: _records.take(15).toList().asMap().entries.map((e) {
        final i = e.key;
        final r = e.value;
        return Container(
          margin: const EdgeInsets.only(bottom: 6),
          padding: const EdgeInsets.all(10),
          decoration: BoxDecoration(
            color: Colors.white.withAlpha(i.isEven ? 10 : 6),
            borderRadius: BorderRadius.circular(10),
            border: Border.all(
                color: Colors.white.withAlpha(i == 0 ? 40 : 12)),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Text(
                    '第 ${r.drawNo} 期  ${r.drawTime}',
                    style: TextStyle(
                        color: i == 0 ? _gold : Colors.white60,
                        fontWeight: FontWeight.w700,
                        fontSize: 11),
                  ),
                  if (r.superNum.isNotEmpty) ...[
                    const Spacer(),
                    Text('超獎 ${r.superNum}',
                        style: const TextStyle(
                            color: Colors.orange, fontSize: 10)),
                  ],
                ],
              ),
              const SizedBox(height: 6),
              Wrap(
                spacing: 3,
                runSpacing: 3,
                children: r.numbers.map((n) {
                  final s = _pred?.stats[n];
                  return Container(
                    width: 26,
                    height: 26,
                    decoration: BoxDecoration(
                      color: s != null
                          ? _heatColor(s.heatScore)
                          : _colorCold,
                      shape: BoxShape.circle,
                    ),
                    alignment: Alignment.center,
                    child: Text(
                      n.toString().padLeft(2, '0'),
                      style: const TextStyle(
                          fontSize: 8,
                          fontWeight: FontWeight.w700,
                          color: Colors.white),
                    ),
                  );
                }).toList(),
              ),
            ],
          ),
        );
      }).toList(),
    );
  }

  // ── 準確率 Tab ────────────────────────────────────────────────

  Widget _accuracyTab() {
    if (_accuracy.isEmpty) {
      return _emptyMsg('資料不足，需要至少 22 局歷史資料');
    }
    final testedDraws = _accuracy.first.testedDraws;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Info bar
        Padding(
          padding: const EdgeInsets.only(bottom: 12),
          child: Text(
            '回測最近 $testedDraws 局 · 每組預測 6 個號碼 · 隨機基準 1.5 個/局',
            style: const TextStyle(color: Colors.white54, fontSize: 11),
          ),
        ),
        ..._accuracy.map((s) => _accuracyCard(s)),
      ],
    );
  }

  Widget _accuracyCard(AccuracySummary s) {
    final above = s.vsBaseline >= 0;
    final vsColor = above ? Colors.greenAccent : Colors.redAccent;
    final dist = s.distribution;
    final maxDist =
        dist.values.isEmpty ? 1 : dist.values.fold(0, (a, b) => a > b ? a : b);

    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.white.withAlpha(10),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: above
              ? Colors.green.withAlpha(60)
              : Colors.white.withAlpha(20),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Title row
          Row(
            children: [
              Text(s.groupLabel,
                  style: const TextStyle(
                      color: Colors.white,
                      fontSize: 13,
                      fontWeight: FontWeight.w700)),
              const Spacer(),
              Text(
                '${s.avgHits.toStringAsFixed(2)} 個/局',
                style: const TextStyle(
                    color: _gold,
                    fontSize: 13,
                    fontWeight: FontWeight.w700),
              ),
            ],
          ),
          const SizedBox(height: 4),
          // Sub info
          Row(
            children: [
              Text(
                '命中率 ${(s.hitRate * 100).toStringAsFixed(1)}%',
                style:
                    const TextStyle(color: Colors.white54, fontSize: 11),
              ),
              const SizedBox(width: 8),
              Text(
                above
                    ? '+${s.vsBaseline.toStringAsFixed(2)} vs 隨機'
                    : '${s.vsBaseline.toStringAsFixed(2)} vs 隨機',
                style: TextStyle(
                    color: vsColor,
                    fontSize: 11,
                    fontWeight: FontWeight.w600),
              ),
            ],
          ),
          const SizedBox(height: 8),
          // Progress bar – actual vs baseline
          Stack(
            children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(4),
                child: LinearProgressIndicator(
                  value: (AccuracySummary.baseline / 6).clamp(0.0, 1.0),
                  minHeight: 8,
                  backgroundColor: Colors.white.withAlpha(15),
                  valueColor:
                      const AlwaysStoppedAnimation<Color>(Colors.white24),
                ),
              ),
              ClipRRect(
                borderRadius: BorderRadius.circular(4),
                child: LinearProgressIndicator(
                  value: s.hitRate.clamp(0.0, 1.0),
                  minHeight: 8,
                  backgroundColor: Colors.transparent,
                  valueColor: AlwaysStoppedAnimation<Color>(
                    above ? Colors.green.shade400 : Colors.orange.shade400,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          // Hit distribution histogram (0–6 hits)
          Text('命中分布（共 ${s.testedDraws} 局）',
              style: const TextStyle(color: Colors.white54, fontSize: 10)),
          const SizedBox(height: 6),
          Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: List.generate(7, (hits) {
              final count = dist[hits] ?? 0;
              final frac = maxDist > 0 ? count / maxDist : 0.0;
              final barColor = hits == 0
                  ? Colors.grey.withAlpha(100)
                  : hits <= 2
                      ? Colors.blue.shade400
                      : hits <= 4
                          ? Colors.orange
                          : Colors.greenAccent;
              return Expanded(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    Container(
                      height: 4 + 28 * frac,
                      margin: const EdgeInsets.symmetric(horizontal: 1.5),
                      decoration: BoxDecoration(
                        color: barColor,
                        borderRadius: BorderRadius.circular(3),
                      ),
                    ),
                    const SizedBox(height: 3),
                    Text('$hits',
                        textAlign: TextAlign.center,
                        style: const TextStyle(
                            color: Colors.white54, fontSize: 9)),
                    Text('$count',
                        textAlign: TextAlign.center,
                        style: const TextStyle(
                            color: Colors.white38, fontSize: 9)),
                  ],
                ),
              );
            }),
          ),
        ],
      ),
    );
  }

  // ── 型態分析 Tab ──────────────────────────────────────────────

  Widget _drawPatternTab() {
    if (_records.length < 5) return _emptyMsg('資料不足，需要至少 5 局歷史記錄');
    final pred = _pred!;

    // 區間分布（近 20 局每區開出球數）
    final profiles = BingoService.drawZoneProfiles(_records, limit: 20);
    final avgDist   = BingoService.avgZoneDistribution(_records, limit: 30);
    final patterns  = BingoService.dominantZonePatterns(_records, limit: 40);

    // 最新一局各區球數
    final latestProfile = profiles.isNotEmpty ? profiles.first : List.filled(8, 0);

    // Top 共現配對（前 15 對）
    final topPairs = pred.topPairs.take(15).toList();

    const zoneLabels = ['01-10','11-20','21-30','31-40','41-50','51-60','61-70','71-80'];

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // ── 最新一局區間分布 ──────────────────────────────────────
        Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: Colors.white.withAlpha(10),
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: Colors.white.withAlpha(25)),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('最新一局區間分布  vs  歷史平均',
                  style: TextStyle(color: _gold, fontSize: 12, fontWeight: FontWeight.w700)),
              const SizedBox(height: 10),
              ...List.generate(8, (z) {
                final latest = latestProfile[z];
                final avg    = avgDist[z];
                final maxVal = 8.0;
                final latestFrac = (latest / maxVal).clamp(0.0, 1.0);
                final avgFrac    = (avg    / maxVal).clamp(0.0, 1.0);
                final isHot = latest > avg + 1;
                final isCold = latest < avg - 1;
                return Padding(
                  padding: const EdgeInsets.only(bottom: 6),
                  child: Row(
                    children: [
                      SizedBox(
                        width: 52,
                        child: Text(zoneLabels[z],
                            style: const TextStyle(color: Colors.white54, fontSize: 10)),
                      ),
                      Expanded(
                        child: Stack(children: [
                          // avg bar (grey)
                          FractionallySizedBox(
                            widthFactor: avgFrac,
                            child: Container(
                              height: 14,
                              decoration: BoxDecoration(
                                color: Colors.white.withAlpha(30),
                                borderRadius: BorderRadius.circular(4),
                              ),
                            ),
                          ),
                          // latest bar (coloured)
                          FractionallySizedBox(
                            widthFactor: latestFrac,
                            child: Container(
                              height: 14,
                              decoration: BoxDecoration(
                                color: isHot
                                    ? _colorHot.withAlpha(200)
                                    : isCold
                                        ? _colorCold.withAlpha(200)
                                        : _cyan.withAlpha(160),
                                borderRadius: BorderRadius.circular(4),
                              ),
                            ),
                          ),
                        ]),
                      ),
                      const SizedBox(width: 8),
                      SizedBox(
                        width: 56,
                        child: Text(
                          '本局$latest  均${avg.toStringAsFixed(1)}',
                          style: TextStyle(
                            color: isHot ? _colorHot : isCold ? _cyan : Colors.white54,
                            fontSize: 9,
                          ),
                        ),
                      ),
                    ],
                  ),
                );
              }),
              const SizedBox(height: 4),
              Row(children: [
                _legendItem(_colorHot, '本局>均+1'),
                const SizedBox(width: 10),
                _legendItem(_cyan, '本局<均-1'),
                const SizedBox(width: 10),
                _legendItem(Colors.white.withAlpha(80), '歷史平均'),
              ]),
            ],
          ),
        ),

        const SizedBox(height: 12),

        // ── 近 20 局區間熱度表 ────────────────────────────────────
        Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: Colors.white.withAlpha(8),
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: Colors.white.withAlpha(20)),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('近 ${profiles.length} 局區間熱力表（每格 = 該區開出球數）',
                  style: const TextStyle(color: _cyan, fontSize: 11, fontWeight: FontWeight.w700)),
              const SizedBox(height: 8),
              // Header row
              Row(
                children: [
                  const SizedBox(width: 28),
                  ...List.generate(8, (z) => Expanded(
                    child: Text(
                      '${z+1}區',
                      textAlign: TextAlign.center,
                      style: const TextStyle(color: Colors.white38, fontSize: 9),
                    ),
                  )),
                ],
              ),
              const SizedBox(height: 4),
              ...profiles.asMap().entries.map((e) {
                final idx = e.key;
                final p   = e.value;
                final drawNo = idx < _records.length ? _records[idx].drawNo : 0;
                return Padding(
                  padding: const EdgeInsets.only(bottom: 2),
                  child: Row(
                    children: [
                      SizedBox(
                        width: 28,
                        child: Text(
                          idx == 0 ? '最新' : '$drawNo',
                          style: TextStyle(
                            color: idx == 0 ? _gold : Colors.white24,
                            fontSize: 8,
                          ),
                        ),
                      ),
                      ...List.generate(8, (z) {
                        final cnt = p[z];
                        final intensity = cnt / 6.0;
                        final bg = cnt == 0
                            ? Colors.white.withAlpha(8)
                            : Color.lerp(_colorCold, _colorHot, intensity)!.withAlpha(180);
                        return Expanded(
                          child: Container(
                            margin: const EdgeInsets.symmetric(horizontal: 1),
                            height: 18,
                            decoration: BoxDecoration(
                              color: bg,
                              borderRadius: BorderRadius.circular(3),
                            ),
                            alignment: Alignment.center,
                            child: Text(
                              '$cnt',
                              style: TextStyle(
                                fontSize: 9,
                                fontWeight: FontWeight.w700,
                                color: cnt == 0 ? Colors.white24 : Colors.white,
                              ),
                            ),
                          ),
                        );
                      }),
                    ],
                  ),
                );
              }),
            ],
          ),
        ),

        const SizedBox(height: 12),

        // ── 常見區間組合型態 ──────────────────────────────────────
        if (patterns.isNotEmpty)
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: Colors.white.withAlpha(8),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: Colors.white.withAlpha(20)),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('常見密集出現區間組合（≥3球/區）',
                    style: TextStyle(color: _gold, fontSize: 12, fontWeight: FontWeight.w700)),
                const SizedBox(height: 8),
                ...(patterns.entries.toList()
                    ..sort((a, b) => b.value.compareTo(a.value)))
                    .take(8)
                    .map((e) {
                  final parts = e.key.split('-');
                  final za = int.tryParse(parts[0]) ?? 0;
                  final zb = int.tryParse(parts[1]) ?? 0;
                  final labelA = za < 8 ? zoneLabels[za] : '?';
                  final labelB = zb < 8 ? zoneLabels[zb] : '?';
                  final maxCount = patterns.values.reduce((a, b) => a > b ? a : b);
                  final frac = e.value / maxCount;
                  return Padding(
                    padding: const EdgeInsets.only(bottom: 6),
                    child: Row(children: [
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                        decoration: BoxDecoration(
                          color: Colors.purpleAccent.withAlpha(40),
                          borderRadius: BorderRadius.circular(6),
                          border: Border.all(color: Colors.purpleAccent.withAlpha(80)),
                        ),
                        child: Text('$labelA + $labelB',
                            style: const TextStyle(color: Colors.purpleAccent, fontSize: 10)),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: ClipRRect(
                          borderRadius: BorderRadius.circular(4),
                          child: LinearProgressIndicator(
                            value: frac.clamp(0.0, 1.0),
                            minHeight: 8,
                            backgroundColor: Colors.white.withAlpha(15),
                            valueColor: const AlwaysStoppedAnimation(Colors.purpleAccent),
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Text('${e.value} 次',
                          style: const TextStyle(color: Colors.white54, fontSize: 10)),
                    ]),
                  );
                }),
              ],
            ),
          ),

        const SizedBox(height: 12),

        // ── 最強共現配對（前 15 對）──────────────────────────────
        Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: Colors.white.withAlpha(8),
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: Colors.white.withAlpha(20)),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('最強共現配對  ·  共分析 ${pred.analyzedDraws} 局',
                  style: const TextStyle(color: _gold, fontSize: 12, fontWeight: FontWeight.w700)),
              const SizedBox(height: 8),
              if (topPairs.isEmpty)
                const Text('資料不足', style: TextStyle(color: Colors.white38, fontSize: 11))
              else
                Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  children: topPairs.map((p) {
                    final pct = (p.rate * 100).round();
                    return Container(
                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
                      decoration: BoxDecoration(
                        color: Colors.indigo.withAlpha(50),
                        borderRadius: BorderRadius.circular(20),
                        border: Border.all(color: Colors.indigoAccent.withAlpha(100)),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          _pairBall(p.a),
                          const SizedBox(width: 3),
                          const Text('+', style: TextStyle(color: Colors.white38, fontSize: 10)),
                          const SizedBox(width: 3),
                          _pairBall(p.b),
                          const SizedBox(width: 6),
                          Text('$pct%',
                              style: const TextStyle(color: Colors.indigoAccent, fontSize: 10,
                                  fontWeight: FontWeight.w700)),
                        ],
                      ),
                    );
                  }).toList(),
                ),
            ],
          ),
        ),
      ],
    );
  }

  // ── Misc ──────────────────────────────────────────────────────

  Widget _emptyMsg(String msg) {
    return Padding(
      padding: const EdgeInsets.all(30),
      child: Center(
          child: Text(msg,
              style: const TextStyle(
                  color: Colors.white38, fontSize: 13))),
    );
  }

  Widget _loadingView() {
    return const Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          CircularProgressIndicator(color: _gold),
          SizedBox(height: 14),
          Text('載入開獎資料…',
              style: TextStyle(color: _gold)),
        ],
      ),
    );
  }

  Widget _errorView() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(30),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.wifi_off, color: Colors.red, size: 48),
            const SizedBox(height: 10),
            Text(_errorMsg,
                textAlign: TextAlign.center,
                style: const TextStyle(color: Colors.white70)),
            const SizedBox(height: 14),
            ElevatedButton(
              onPressed: () => _load(forceRefresh: true),
              style:
                  ElevatedButton.styleFrom(backgroundColor: _gold),
              child: const Text('重新載入',
                  style: TextStyle(color: Colors.black)),
            ),
          ],
        ),
      ),
    );
  }
}
