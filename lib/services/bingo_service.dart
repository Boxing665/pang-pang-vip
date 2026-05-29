import 'dart:convert';
import 'dart:math';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'bingo_animation_pattern_predictor.dart';

// ════════════════════════════════════════════════════════════════
//  資料模型
// ════════════════════════════════════════════════════════════════

/// 單期開獎紀錄
class BingoRecord {
  final int drawNo;        // 期數（int）
  final String drawDate;   // "2026-04-09"
  final String drawTime;   // "23:05"
  final List<int> numbers; // 20 個號碼，已排序
  final String superNum;   // 超級獎號

  const BingoRecord({
    required this.drawNo,
    required this.drawDate,
    required this.drawTime,
    required this.numbers,
    this.superNum = '',
  });

  String get label => '第 $drawNo 期  $drawTime';
}

/// 每個號碼的統計數據
class BingoStats {
  final int number;
  final int frequency;    // 最近 N 局出現次數
  final int gap;          // 距上次開出已幾局（0 = 最新一局開出）
  final double avgGap;    // 歷史平均間隔局數
  final double heatScore; // 0.0 最冷 ~ 1.0 最熱

  const BingoStats({
    required this.number,
    required this.frequency,
    required this.gap,
    required this.avgGap,
    required this.heatScore,
  });

  String get gapLabel => gap == 0 ? '本期' : '$gap 局前';

  BingoStats copyWithHeat(double newHeat) {
    return BingoStats(
      number: number,
      frequency: frequency,
      gap: gap,
      avgGap: avgGap,
      heatScore: newHeat,
    );
  }
}

/// 號碼共同開獎配對
class BingoPair {
  final int a;
  final int b;
  final int count;
  final double rate;

  const BingoPair({
    required this.a,
    required this.b,
    required this.count,
    required this.rate,
  });
}

/// 同出組合統計（2/3/4 同出）
class ComboPatternStat {
  final List<int> numbers;
  final int count;
  final int gap; // 幾期未開
  final double avgGap;
  final int suggestAfter; // 建議幾期後下（0 = 下期）

  const ComboPatternStat({
    required this.numbers,
    required this.count,
    required this.gap,
    required this.avgGap,
    required this.suggestAfter,
  });
}

/// 大小 / 單雙型態統計
class BalancePatternStat {
  final String label;
  final int count;
  final int gap; // 幾期未開
  final double avgGap;
  final int suggestAfter; // 建議幾期後下（0 = 下期）

  const BalancePatternStat({
    required this.label,
    required this.count,
    required this.gap,
    required this.avgGap,
    required this.suggestAfter,
  });
}

/// 回測準確率摘要（每組策略的命中統計）
class AccuracySummary {
  final String groupLabel;
  final double avgHits;         // 平均命中數（每局預測 6 個中幾個）
  final int testedDraws;        // 回測局數
  final List<int> hitsHistory;  // 各局命中數（最新在前）

  const AccuracySummary({
    required this.groupLabel,
    required this.avgHits,
    required this.testedDraws,
    required this.hitsHistory,
  });

  /// 純隨機期望命中：6 個 / 80 × 20 = 1.5
  static const double baseline = 1.5;

  double get vsBaseline => avgHits - baseline;
  double get hitRate => avgHits / 6.0;

  Map<int, int> get distribution {
    final dist = <int, int>{};
    for (final h in hitsHistory) {
      dist[h] = (dist[h] ?? 0) + 1;
    }
    return dist;
  }
}

/// 完整預測結果
class BingoPrediction {
  final Map<int, BingoStats> stats;
  final List<int> hotNumbers;
  final List<int> coldNumbers;
  final List<int> recommended;
  final List<BingoPair> topPairs;
  final int nextDrawNo;
  final String strategy;
  final int analyzedDraws;
  final List<int> carryOverNumbers;      // 連莊預測 6 個號碼
  final double carryOverConfidence;      // 連莊信心度 0.0-1.0
  final List<ComboPatternStat> topTwoCombos;
  final List<ComboPatternStat> topThreeCombos;
  final List<ComboPatternStat> topFourCombos;
  final List<BalancePatternStat> bigSmallPatterns;
  final List<BalancePatternStat> oddEvenPatterns;
  
  // ── 新增：動畫特徵預測（精準3顆） ────────────────────────────
  final List<int> animationPredicted;     // 基於當期開獎動畫特徵預測的3顆號碼
  final String animationVersion;          // 識別的動畫版本
  final double animationConfidence;       // 預測信心度 0.0-1.0

  const BingoPrediction({
    required this.stats,
    required this.hotNumbers,
    required this.coldNumbers,
    required this.recommended,
    required this.topPairs,
    required this.nextDrawNo,
    required this.strategy,
    required this.analyzedDraws,
    this.carryOverNumbers = const [],
    this.carryOverConfidence = 0.0,
    this.topTwoCombos = const [],
    this.topThreeCombos = const [],
    this.topFourCombos = const [],
    this.bigSmallPatterns = const [],
    this.oddEvenPatterns = const [],
    this.animationPredicted = const [],
    this.animationVersion = '',
    this.animationConfidence = 0.0,
  });
}

/// 回測結果 — 用歷史過去局來評估各組預測命中率
class BacktestResult {
  /// 每組平均命中顆數（6 顆中猜中幾顆）
  final List<double> avgHitsPerGroup;
  /// 共回測幾局
  final int testedDraws;

  const BacktestResult({
    required this.avgHitsPerGroup,
    required this.testedDraws,
  });
}

// ════════════════════════════════════════════════════════════════
//  服務
// ════════════════════════════════════════════════════════════════

/// 台灣賓果賓果數據服務
///
/// 主要源：https://bingo.kuaishou1688.com/api/get_data（JSON，速度快）
/// 備援源：https://lotto.auzo.tw/bingobingo.php（HTML 解析）
class BingoService {
  static const _primaryBase = 'https://bingo.kuaishou1688.com';
  static const _fallbackUrl = 'https://lotto.auzo.tw/bingobingo.php';
  static const _fetchCount = 120; // 分析用局數（足夠轉移矩陣且加載快）
  static const _prefsKey = 'bingo_records_cache_v2';

  List<BingoRecord> _cache = [];
  DateTime? _lastFetch;

  // ── 公開：取得最新資料 ─────────────────────────────────────────

  Future<List<BingoRecord>> fetchRecent({bool forceRefresh = false}) async {
    final now = DateTime.now();
    final valid = _lastFetch != null &&
        now.difference(_lastFetch!).inMinutes < 5;
    if (!forceRefresh && valid && _cache.isNotEmpty) return _cache;

    // 首次冷啟動：從 SharedPreferences 即時讀出上次快取，馬上回傳
    if (_cache.isEmpty) {
      final persisted = await _loadPersistedCache();
      if (persisted.isNotEmpty) {
        _cache = persisted;
        debugPrint('📦 Bingo 離線快取: ${_cache.length} 筆');
        // 背景刷新，不阻塞 UI
        _fetchAndPersist();
        return _cache;
      }
    }

    return _fetchAndPersist();
  }

  Future<List<BingoRecord>> _fetchAndPersist() async {
    final now = DateTime.now();
    final primary = await _fetchFromKuaishou(_fetchCount);
    if (primary.length >= 80) {
      _cache = primary.take(_fetchCount).toList();
      _lastFetch = now;
      _persistCache(_cache);
      return _cache;
    }

    // 主來源不足時才抓備援
    final fallback = await _fetchFromAuzo();
    final merged = <int, BingoRecord>{};
    for (final r in primary) { merged[r.drawNo] = r; }
    for (final r in fallback) { merged.putIfAbsent(r.drawNo, () => r); }

    final result = (merged.values.toList()
          ..sort((a, b) => b.drawNo.compareTo(a.drawNo)))
        .take(_fetchCount)
        .toList();

    if (result.isNotEmpty) {
      _cache = result;
      _lastFetch = now;
      _persistCache(_cache);
      return _cache;
    }
    return _cache;
  }

  Future<void> _persistCache(List<BingoRecord> records) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final json = records.map((r) => {
        'drawNo': r.drawNo, 'drawDate': r.drawDate,
        'drawTime': r.drawTime, 'numbers': r.numbers, 'superNum': r.superNum,
      }).toList();
      await prefs.setString(_prefsKey, jsonEncode(json));
    } catch (_) {}
  }

  Future<List<BingoRecord>> _loadPersistedCache() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final str = prefs.getString(_prefsKey);
      if (str == null) return [];
      final list = jsonDecode(str) as List<dynamic>;
      return list.map((m) {
        final item = m as Map<String, dynamic>;
        return BingoRecord(
          drawNo: (item['drawNo'] as num).toInt(),
          drawDate: item['drawDate'] as String? ?? '',
          drawTime: item['drawTime'] as String? ?? '',
          numbers: (item['numbers'] as List<dynamic>).map((n) => (n as num).toInt()).toList(),
          superNum: item['superNum'] as String? ?? '',
        );
      }).toList();
    } catch (_) {
      return [];
    }
  }

  // ── 公開：分析統計 ────────────────────────────────────────────

  /// strategyMode: 'balanced'（預設）| 'frequency'（熱號）| 'gap'（冷號）| 'transition'（轉移矩陣）
  /// zoneMultipliers: zone 0–7 的命中乘數（由 SelfLearningService.getBingoZoneMultipliers() 傳入）
  /// 由 SelfLearningService.getRecommendedBingoStrategy() 在呼叫前取得並傳入
  static BingoPrediction analyze(List<BingoRecord> records,
      {int seed = 0,
      String strategyMode = 'balanced',
      Map<int, double> zoneMultipliers = const {}}) {
    if (records.isEmpty) {
      return const BingoPrediction(
        stats: {},
        hotNumbers: [],
        coldNumbers: [],
        recommended: [],
        topPairs: [],
        nextDrawNo: 0,
        strategy: '無資料',
        analyzedDraws: 0,
      );
    }

    // 最多只用最近 60 局做分析（速度優化：過舊資料對預測貢獻極低）
    final workRecords = records.length > 60 ? records.sublist(0, 60) : records;
    final N = workRecords.length;
    final rawFreq = <int, int>{for (var n = 1; n <= 80; n++) n: 0};
    final lastSeen = <int, int>{};

    for (var i = 0; i < N; i++) {
      for (final n in workRecords[i].numbers) {
        rawFreq[n] = rawFreq[n]! + 1;
        lastSeen[n] ??= i;
      }
    }

    // gap = draws since last seen (0 = latest draw)
    final gapMap = <int, int>{
      for (var n = 1; n <= 80; n++) n: lastSeen[n] ?? N
    };

    // ── 指數衰減頻率：近期自然遞減，half-life ≈ 11 局 ─────────────
    const decayRate = 0.06;
    final expWeighted = <int, double>{for (var n = 1; n <= 80; n++) n: 0.0};
    for (var i = 0; i < N; i++) {
      final w = exp(-decayRate * i);
      for (final n in workRecords[i].numbers) {
        expWeighted[n] = expWeighted[n]! + w;
      }
    }
    final maxWeighted = expWeighted.values.fold(0.0, max).clamp(0.1, 999);

    final statsMap = <int, BingoStats>{};

    for (var n = 1; n <= 80; n++) {
      final freq = rawFreq[n]!;
      final gap = gapMap[n]!;
      final avgGap = freq > 0 ? N / freq : N.toDouble();
      // 使用動態權重計算熱度
      final heat = ((expWeighted[n]! / maxWeighted) * 0.6 + 0.4 / (gap + 1)).clamp(0.0, 1.0);
      statsMap[n] = BingoStats(
        number: n,
        frequency: freq,
        gap: gap, 
        avgGap: avgGap,
        heatScore: heat,
      );
    }

    // ── 拖牌預測強化 (Next-Draw Tuo Pai) ─────────────────────────
    final tuoPaiStats = <int, double>{for (var n = 1; n <= 80; n++) n: 0.0};
    if (workRecords.length >= 2) {
      final lastNumbers = workRecords.first.numbers;
      for (int i = workRecords.length - 1; i > 0; i--) {
        final prevMatchCount = workRecords[i].numbers.where((n) => lastNumbers.contains(n)).length;
        if (prevMatchCount >= 5) {
          final nextDraw = workRecords[i - 1].numbers;
          for (final n in nextDraw) {
            tuoPaiStats[n] = (tuoPaiStats[n] ?? 0.0) + (prevMatchCount / 20.0);
          }
        }
      }
    }

    // 修正 heatScore 加入拖牌權重
    for (var n = 1; n <= 80; n++) {
      final tpEffect = (tuoPaiStats[n] ?? 0.0).clamp(0.0, 0.5);
      // 三期內沒開 (gap 1~3) 的號碼給予額外 20% 熱度補償
      double missBonus = (gapMap[n]! >= 1 && gapMap[n]! <= 3) ? 0.2 : 0.0;
      
      final originalHeat = statsMap[n]!.heatScore;
      statsMap[n] = statsMap[n]!.copyWithHeat(
        (originalHeat * 0.7 + tpEffect * 0.2 + missBonus * 0.1).clamp(0.0, 1.0)
      );
    }

    final byFreq = statsMap.values.toList()
      ..sort((a, b) => b.frequency.compareTo(a.frequency));
    final hotNumbers = byFreq.take(20).map((s) => s.number).toList()..sort();
    final coldNumbers =
        byFreq.reversed.take(20).map((s) => s.number).toList()..sort();

    // ── 共同開獎配對 ──────────────────────────────────────────────
    final pairCount = <int, int>{};
    for (final r in workRecords) {
      final nums = List<int>.from(r.numbers)..sort();
      for (var i = 0; i < nums.length; i++) {
        for (var j = i + 1; j < nums.length; j++) {
          final key = nums[i] * 100 + nums[j];
          pairCount[key] = (pairCount[key] ?? 0) + 1;
        }
      }
    }
    final sortedPairs = pairCount.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));
    final topPairs = sortedPairs.take(30).map((e) => BingoPair(
          a: e.key ~/ 100,
          b: e.key % 100,
          count: e.value,
          rate: e.value / N,
        )).toList();

    // ── 同出模式（先算，供評分系統使用）──────────────────────────
    final twoCombos = _computeComboStats(workRecords, size: 2, top: 12);
    final threeCombos = _computeComboStats(workRecords, size: 3, top: 12);
    final fourCombos = _computeComboStats(workRecords, size: 4, top: 12);
    final bigSmall = _computeBalancePatterns(workRecords, oddEven: false, top: 10);
    final oddEven = _computeBalancePatterns(workRecords, oddEven: true, top: 10);

    // ══════════════════════════════════════════════════════════════
    //  多維度評分：拖牌法 + 同出到期 + 個人間隔到期 + 近期熱度
    //  不依賴上期連莊，改用歷史 lag-N 轉移概率與組合到期信號
    // ══════════════════════════════════════════════════════════════

    final predictScores = <int, double>{for (var n = 1; n <= 80; n++) n: 0.0};

    // ── Part 1: 拖牌法（Lag-N 轉移概率）──────────────────────────
    final maxLag = min(10, N - 1);
    for (var lag = 1; lag <= maxLag; lag++) {
      final fromToCount = <int, Map<int, int>>{};
      final fromTotal = <int, int>{};

      for (var i = 0; i + lag < N; i++) {
        final fromNums = workRecords[i + lag].numbers;
        final toSet = workRecords[i].numbers.toSet();
        for (final from in fromNums) {
          fromTotal[from] = (fromTotal[from] ?? 0) + 1;
          fromToCount.putIfAbsent(from, () => {});
          for (final to in toSet) {
            fromToCount[from]![to] = (fromToCount[from]![to] ?? 0) + 1;
          }
        }
      }

      if (lag - 1 >= N) continue;
      final lagWeight = 1.0 / lag;
      for (final fromNum in workRecords[lag - 1].numbers) {
        final total = fromTotal[fromNum] ?? 0;
        if (total < 5) continue;
        final toMap = fromToCount[fromNum] ?? {};
        for (final entry in toMap.entries) {
          final rate = entry.value / total;
          // 閾值降低至 0.15（超過隨機基準 20/80=25%... 的 60%即算有效訊號）
          if (rate >= 0.15) {
            predictScores[entry.key] = (predictScores[entry.key] ?? 0) +
                rate * lagWeight * 20.0;
          }
        }
      }
    }

    // 拖牌法單獨的前 6 名（供 UI 單獨顯示）
    final dragSorted = predictScores.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));
    final dragPrediction = dragSorted.take(6).map((e) => e.key).toList()..sort();

    // ── 自適應策略倍率（由 SelfLearningService 根據命中率選出）────────────
    // 各 Part 的基礎權重乘以對應策略倍率，實現「失敗就換套路」
    final wTransition = strategyMode == 'transition' ? 1.8
        : strategyMode == 'frequency'  ? 0.6
        : strategyMode == 'gap'        ? 0.7
        : 1.0; // balanced
    final wGap = strategyMode == 'gap'        ? 2.2
        : strategyMode == 'transition' ? 0.6
        : strategyMode == 'frequency'  ? 0.5
        : 1.0;
    final wHeat = strategyMode == 'frequency' ? 2.0
        : strategyMode == 'gap'        ? 0.5
        : strategyMode == 'transition' ? 0.7
        : 1.0;
    // 重新套用自適應倍率（覆蓋 Part 1 的拖牌法分數）
    for (var n = 1; n <= 80; n++) {
      predictScores[n] = predictScores[n]! * wTransition;
    }

    // ── Part 2: 同出到期（suggestAfter==0 = 已超過平均間隔，建議下期出）
    for (final combo in twoCombos) {
      if (combo.suggestAfter == 0 && combo.count >= 3) {
        final bonus = combo.count * 2.5;
        for (final n in combo.numbers) {
          predictScores[n] = (predictScores[n] ?? 0) + bonus;
        }
      }
    }
    for (final combo in threeCombos) {
      if (combo.suggestAfter == 0 && combo.count >= 2) {
        final bonus = combo.count * 4.0;
        for (final n in combo.numbers) {
          predictScores[n] = (predictScores[n] ?? 0) + bonus;
        }
      }
    }
    for (final combo in fourCombos) {
      if (combo.suggestAfter == 0) {
        final bonus = combo.count * 6.0;
        for (final n in combo.numbers) {
          predictScores[n] = (predictScores[n] ?? 0) + bonus;
        }
      }
    }

    // ── Part 3: 個人間隔到期（wGap 倍率：gap 策略強化）────────────
    for (var n = 1; n <= 80; n++) {
      final s = statsMap[n]!;
      if (s.gap >= s.avgGap) {
        final overdue = (s.gap - s.avgGap).clamp(0.0, 20.0);
        predictScores[n] = (predictScores[n] ?? 0) + overdue * 1.5 * wGap;
      }
    }

    // ── Part 4: 指數衰減熱度加成（wHeat 倍率：frequency 策略強化）──
    for (var n = 1; n <= 80; n++) {
      predictScores[n] = (predictScores[n] ?? 0) + statsMap[n]!.heatScore * 8.0 * wHeat;
    }

    // ── Part 4b: 圖表命中率區間乘數（來自 SelfLearningService 歷史命中回饋）──
    if (zoneMultipliers.isNotEmpty) {
      for (var n = 1; n <= 80; n++) {
        final z    = (n - 1) ~/ 10;
        final mult = zoneMultipliers[z] ?? 1.0;
        predictScores[n] = predictScores[n]! * mult;
      }
    }

    // ── Part 5: 連開熱勢（近 5 期高頻號碼）─────────────────────────
    final streak5 = <int, int>{for (var n = 1; n <= 80; n++) n: 0};
    for (final r in workRecords.take(5)) {
      for (final n in r.numbers) {
        streak5[n] = streak5[n]! + 1;
      }
    }
    for (var n = 1; n <= 80; n++) {
      final cnt = streak5[n]!;
      if (cnt >= 3) {
        predictScores[n] = predictScores[n]! + cnt * 9.0; // 強熱勢
      } else if (cnt == 2) {
        predictScores[n] = predictScores[n]! + cnt * 4.5; // 中熱勢
      }
    }

    // ── Part 6: 區間熱度（近 10 期各十位區間出現頻率）────────────
    final zoneCount = List.filled(8, 0.0);
    for (var i = 0; i < min(10, N); i++) {
      final w = exp(-0.10 * i);
      for (final n in workRecords[i].numbers) {
        zoneCount[(n - 1) ~/ 10] += w;
      }
    }
    final maxZone = zoneCount.reduce(max).clamp(0.1, 999);
    for (var n = 1; n <= 80; n++) {
      predictScores[n] = predictScores[n]! +
          (zoneCount[(n - 1) ~/ 10] / maxZone) * 5.0;
    }

    // ── Part 7: 相生相剋（共現親合力）──────────────────────────
    // 相生：與已得分前20名高度共現的號碼額外加分
    // 相剋：與前20名共現率極低的號碼小幅扣分（避免組出歷史少見組合）
    // 共現矩陣（取近 30 局，速度優化）
    final coLimit = min(30, N);
    final coOccur = <int, Map<int, int>>{};
    for (var i = 0; i < coLimit; i++) {
      final nums = workRecords[i].numbers;
      for (var j = 0; j < nums.length; j++) {
        for (var k = j + 1; k < nums.length; k++) {
          final a = nums[j], b = nums[k];
          coOccur.putIfAbsent(a, () => <int, int>{})[b] =
              (coOccur[a]![b] ?? 0) + 1;
          coOccur.putIfAbsent(b, () => <int, int>{})[a] =
              (coOccur[b]![a] ?? 0) + 1;
        }
      }
    }
    // 以目前得分前 20 名作為「種子集合」
    final seedSorted = predictScores.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));
    final seeds = seedSorted.take(20).map((e) => e.key).toSet();

    for (var n = 1; n <= 80; n++) {
      final nFreq = rawFreq[n]!.clamp(1, 999);
      double affinity = 0.0;
      int pairCount = 0;
      for (final seed in seeds) {
        final co = coOccur[seed]?[n] ?? 0;
        final seedFreq = rawFreq[seed]!.clamp(1, 999);
        if (co > 0) {
          // Jaccard 相似度：共現次數 / 各自出現次數之幾何均值
          affinity += co / sqrt(nFreq * seedFreq);
          pairCount++;
        }
      }
      if (pairCount > 0) {
        predictScores[n] = predictScores[n]! + (affinity / seeds.length) * 18.0;
      } else {
        // 相剋：與種子集合完全無共現 → 小幅扣分
        predictScores[n] = predictScores[n]! - 2.0;
      }
    }

    // ── Part 8: 歷史命中強化（反饋學習）──────────────────────────
    if (N >= 6) {
      for (var lag = 1; lag <= min(5, N - 1); lag++) {
        final hist = workRecords.sublist(lag);
        if (hist.length < 15) break;

        final qs = <int, double>{for (var n = 1; n <= 80; n++) n: 0.0};
        final prev = hist[0].numbers;
        final fromTotal = <int, int>{};
        final toCount = <int, Map<int, int>>{};
        for (var i = 1; i < hist.length; i++) {
          for (final f in hist[i].numbers) {
            fromTotal[f] = (fromTotal[f] ?? 0) + 1;
            toCount.putIfAbsent(f, () => <int, int>{});
            for (final t in hist[i - 1].numbers) {
              toCount[f]![t] = (toCount[f]![t] ?? 0) + 1;
            }
          }
        }
        for (final f in prev) {
          final tot = fromTotal[f] ?? 0;
          if (tot < 3) continue;
          for (final e in (toCount[f] ?? {}).entries) {
            qs[e.key] = qs[e.key]! + e.value / tot;
          }
        }
        for (var n = 1; n <= 80; n++) {
          qs[n] = qs[n]! + statsMap[n]!.heatScore * 3.0;
        }

        final qSorted = qs.entries.toList()
          ..sort((a, b) => b.value.compareTo(a.value));
        final predicted = qSorted.take(15).map((e) => e.key).toSet();
        final actualSet = workRecords[lag - 1].numbers.toSet();
        final hits = predicted.intersection(actualSet);

        final reward = exp(-0.35 * (lag - 1)) * 7.0;
        for (final h in hits) {
          predictScores[h] = predictScores[h]! + reward;
        }
      }
    }

    // ════════════════════════════════════════════════════════════════
    // 基於當期動畫特徵的精準 3 顆預測
    // 每期都是新開始，不依賴歷史，只看當期動畫特徵
    // ════════════════════════════════════════════════════════════════
    
    final latestNumbers = workRecords.isNotEmpty ? workRecords.first.numbers : <int>[];
    List<int> recommended = [];
    String strategy = '';
    String animationVersion = '';
    double animationConfidence = 0.0;
    
    if (latestNumbers.isNotEmpty) {
      // 1. 識別當期的四套版本邏輯
      animationVersion = BingoAnimationPatternPredictor.identifyVersion(latestNumbers);
      
      // 2. 根據當期特徵預測下期的 3 顆高精準號碼
      recommended = BingoAnimationPatternPredictor.predictTopThreeNumbers(
        latestNumbers,
        versionKey: animationVersion,
      );
      
      // 3. 計算預測信心度
      final analysis = BingoAnimationPatternPredictor.analyzeCurrentDrawCharacteristics(latestNumbers);
      final concentration = (analysis['concentration'] as double? ?? 0.0).clamp(0.0, 1.0);
      animationConfidence = (0.3 + concentration * 0.7).clamp(0.4, 0.95);
      
      // 4. 生成策略描述
      strategy = '四套版本動畫特徵精準預測 (版本: $animationVersion, 信心度: ${(animationConfidence * 100).toStringAsFixed(0)}%)';
    } else {
      // 降級：無當期數據時使用歷史方法
      final finalSorted = predictScores.entries.toList()
        ..sort((a, b) => b.value.compareTo(a.value));
      
      // 選出得分最高的 3 顆
      recommended = finalSorted.take(3).map((e) => e.key).toList()..sort();
      strategy = '歷史評分預測 (3 顆號碼)';
      animationVersion = 'fallback';
      animationConfidence = 0.5;
    }

    return BingoPrediction(
      stats: statsMap,
      hotNumbers: hotNumbers,
      coldNumbers: coldNumbers,
      recommended: recommended,
      topPairs: topPairs,
      nextDrawNo: workRecords.first.drawNo + 1,
      strategy: strategy,
      analyzedDraws: N,
      carryOverNumbers: dragPrediction,
      carryOverConfidence: _computeCarryOverConfidence(dragPrediction, statsMap),
      topTwoCombos: twoCombos,
      topThreeCombos: threeCombos,
      topFourCombos: fourCombos,
      bigSmallPatterns: bigSmall,
      oddEvenPatterns: oddEven,
      animationPredicted: recommended,
      animationVersion: animationVersion,
      animationConfidence: animationConfidence,
    );
  }

  static List<ComboPatternStat> _computeComboStats(
    List<BingoRecord> records, {
    required int size,
    int top = 10,
  }) {
    if (records.isEmpty || size < 2 || size > 4) return const [];

    final occur = <String, List<int>>{};

    void dfs(List<int> nums, int start, int k, List<int> path, int drawIndex) {
      if (path.length == k) {
        final key = path.join('-');
        occur.putIfAbsent(key, () => []).add(drawIndex);
        return;
      }
      for (var i = start; i <= nums.length - (k - path.length); i++) {
        path.add(nums[i]);
        dfs(nums, i + 1, k, path, drawIndex);
        path.removeLast();
      }
    }

    for (var i = 0; i < records.length; i++) {
      final nums = List<int>.from(records[i].numbers)..sort();
      dfs(nums, 0, size, <int>[], i);
    }

    final stats = <ComboPatternStat>[];
    for (final e in occur.entries) {
      final idxs = e.value;
      idxs.sort(); // 0=最新，index 越大越舊
      final count = idxs.length;
      final gap = idxs.first;
      final avgGap = count <= 1
          ? records.length.toDouble()
          : List.generate(count - 1, (i) => idxs[i + 1] - idxs[i])
                  .reduce((a, b) => a + b) /
              (count - 1);

      final suggestAfter = gap >= avgGap * 1.15
          ? 0
          : max(0, (avgGap - gap).ceil());

      final nums = e.key.split('-').map(int.parse).toList();
      stats.add(ComboPatternStat(
        numbers: nums,
        count: count,
        gap: gap,
        avgGap: avgGap,
        suggestAfter: suggestAfter,
      ));
    }

    stats.sort((a, b) {
      final scoreA = a.count * 2.0 + (a.gap / max(1.0, a.avgGap));
      final scoreB = b.count * 2.0 + (b.gap / max(1.0, b.avgGap));
      return scoreB.compareTo(scoreA);
    });

    return stats.take(top).toList();
  }

  static List<BalancePatternStat> _computeBalancePatterns(
    List<BingoRecord> records, {
    required bool oddEven,
    int top = 8,
  }) {
    if (records.isEmpty) return const [];

    final occur = <String, List<int>>{};

    for (var i = 0; i < records.length; i++) {
      final nums = records[i].numbers;
      final a = oddEven
          ? nums.where((n) => n.isOdd).length
          : nums.where((n) => n > 40).length;
      final b = 20 - a;
      final label = oddEven ? '單$a 雙$b' : '大$a 小$b';
      occur.putIfAbsent(label, () => []).add(i);
    }

    final stats = <BalancePatternStat>[];
    for (final e in occur.entries) {
      final idxs = e.value..sort();
      final count = idxs.length;
      final gap = idxs.first;
      final avgGap = count <= 1
          ? records.length.toDouble()
          : List.generate(count - 1, (i) => idxs[i + 1] - idxs[i])
                  .reduce((a, b) => a + b) /
              (count - 1);
      final suggestAfter = gap >= avgGap * 1.15
          ? 0
          : max(0, (avgGap - gap).ceil());

      stats.add(BalancePatternStat(
        label: e.key,
        count: count,
        gap: gap,
        avgGap: avgGap,
        suggestAfter: suggestAfter,
      ));
    }

    stats.sort((a, b) {
      final scoreA = a.count * 1.5 + (a.gap / max(1.0, a.avgGap));
      final scoreB = b.count * 1.5 + (b.gap / max(1.0, b.avgGap));
      return scoreB.compareTo(scoreA);
    });

    return stats.take(top).toList();
  }

  static double _computeCarryOverConfidence(
    List<int> numbers,
    Map<int, BingoStats> stats,
  ) {
    if (numbers.isEmpty) return 0.0;
    double sum = 0;
    for (final n in numbers) {
      final s = stats[n];
      if (s != null) sum += s.heatScore;
    }
    return (sum / numbers.length).clamp(0.0, 1.0);
  }

  // ── 回測：評估連莊命中率 ──────────────────────────────────────

  /// 對最近 [testDraws] 局進行回測：
  /// 每局用「該局之前的歷史資料」生成連莊預測，
  /// 再與該局實際開獎比對命中顆數，計算平均值。
  static BacktestResult backtest(List<BingoRecord> records,
      {int testDraws = 10}) {
    double hitsSum = 0;
    int count = 0;

    final maxTest = testDraws.clamp(0, records.length - 20);
    for (var i = 0; i < maxTest; i++) {
      final historical = records.sublist(i + 1);
      if (historical.length < 20) break;
      final pred = analyze(historical);
      if (pred.carryOverNumbers.isEmpty) continue;
      final actual = records[i].numbers.toSet();
      hitsSum += pred.carryOverNumbers
          .where((n) => actual.contains(n))
          .length
          .toDouble();
      count++;
    }

    return BacktestResult(
      avgHitsPerGroup: [count > 0 ? hitsSum / count : 0.0],
      testedDraws: count,
    );
  }

  // ── 回測準確率 ────────────────────────────────────────────────

  /// 回測最近 [testDraws] 局的預測命中率。
  /// 對每一局，以其之後的歷史資料進行分析，比對四組六星預測與實際開獎。
  static List<AccuracySummary> computeAccuracy(
    List<BingoRecord> records, {
    int testDraws = 20,
  }) {
    if (records.length < 22) return [];
    final actual = (records.length - 20).clamp(0, testDraws);
    if (actual <= 0) return [];

    final hits = <int>[];

    for (var i = 0; i < actual; i++) {
      final history = records.sublist(i + 1);
      if (history.isEmpty) break;
      final pred = analyze(history, seed: 0);
      final drawnSet = records[i].numbers.toSet();
      hits.add(
          pred.carryOverNumbers.where((n) => drawnSet.contains(n)).length);
    }

    if (hits.isEmpty) {
      return [
        const AccuracySummary(
          groupLabel: '🔁 連莊預測',
          avgHits: 0,
          testedDraws: 0,
          hitsHistory: [],
        )
      ];
    }

    final avg = hits.fold(0, (a, b) => a + b) / hits.length;
    return [
      AccuracySummary(
        groupLabel: '🔁 連莊預測',
        avgHits: avg,
        testedDraws: hits.length,
        hitsHistory: hits,
      )
    ];
  }

  // ── 開獎型態分析（Draw Pattern Analysis）────────────────────────

  /// 計算每一局的區間分布（zone 0–7，每區10球）
  /// 回傳：每局的 8 個區間各開出幾球，最新一局在 index 0
  static List<List<int>> drawZoneProfiles(List<BingoRecord> records, {int limit = 20}) {
    return records.take(limit).map((r) {
      final zones = List.filled(8, 0);
      for (final n in r.numbers) {
        zones[(n - 1) ~/ 10]++;
      }
      return zones;
    }).toList();
  }

  /// 計算近 N 局各區間的平均開出球數
  static List<double> avgZoneDistribution(List<BingoRecord> records, {int limit = 30}) {
    if (records.isEmpty) return List.filled(8, 0);
    final profiles = drawZoneProfiles(records, limit: limit);
    final totals = List.filled(8, 0.0);
    for (final p in profiles) {
      for (var z = 0; z < 8; z++) { totals[z] += p[z]; }
    }
    return List.generate(8, (z) => totals[z] / profiles.length);
  }

  /// 計算最常出現的區間型態（連續2-3個號碼），供「同出型態」分析
  /// 回傳：各型態出現頻率，key = zone-combo 字串（如 "1-2" 代表 zone1+zone2 同局均有≥2球）
  static Map<String, int> dominantZonePatterns(List<BingoRecord> records, {int limit = 40}) {
    final profiles = drawZoneProfiles(records, limit: limit);
    final patternCount = <String, int>{};
    for (final p in profiles) {
      // 找出球數≥2的區間組合（代表那幾區在同一局密集出現）
      final hotZones = <int>[];
      for (var z = 0; z < 8; z++) {
        if (p[z] >= 3) hotZones.add(z);
      }
      if (hotZones.length >= 2) {
        for (var i = 0; i < hotZones.length - 1; i++) {
          final key = '${hotZones[i]}-${hotZones[i + 1]}';
          patternCount[key] = (patternCount[key] ?? 0) + 1;
        }
      }
    }
    return patternCount;
  }

  // ── 計時輔助 ──────────────────────────────────────────────────

  static DateTime nextDrawTime() {
    final tw = _taiwanNow(); // UTC DateTime，數值代表台灣時間
    // 全部用 DateTime.utc 確保與 tw 的比較正確（避免 UTC vs Local 誤判）
    final dayStart = DateTime.utc(tw.year, tw.month, tw.day, 7, 30);
    final dayEnd   = DateTime.utc(tw.year, tw.month, tw.day, 23, 55);

    if (tw.isBefore(dayStart)) {
      return dayStart; // 07:30 今天
    }
    if (tw.isAfter(dayEnd)) {
      // 23:55 後 → 隔天 07:30（用 add(1 day) 避免月底 day+1 溢位）
      final tomorrow = DateTime.utc(tw.year, tw.month, tw.day + 1);
      return DateTime.utc(tomorrow.year, tomorrow.month, tomorrow.day, 7, 30);
    }

    final minuteOfDay = tw.hour * 60 + tw.minute;
    const start = 7 * 60 + 30;
    final step = ((minuteOfDay - start) ~/ 5) + 1;
    final nextMinuteOfDay = start + step * 5;

    final nextHour = nextMinuteOfDay ~/ 60;
    final nextMin = nextMinuteOfDay % 60;
    final next = DateTime.utc(tw.year, tw.month, tw.day, nextHour, nextMin);
    if (next.isAfter(dayEnd)) {
      final tomorrow = DateTime.utc(tw.year, tw.month, tw.day + 1);
      return DateTime.utc(tomorrow.year, tomorrow.month, tomorrow.day, 7, 30);
    }
    return next;
  }

  static int secondsToNextDraw() =>
      nextDrawTime().difference(_taiwanNow()).inSeconds.clamp(0, 24 * 3600);

  static DateTime _taiwanNow() =>
      DateTime.now().toUtc().add(const Duration(hours: 8));

  // ── 私有：kuaishou JSON API ───────────────────────────────────

  Future<List<BingoRecord>> _fetchFromKuaishou(int count) async {
    try {
      final resp = await http
          .post(
            Uri.parse('$_primaryBase/api/get_data'),
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode({'count': count}),
          )
          .timeout(const Duration(seconds: 6));

      if (resp.statusCode != 200) return [];
      final json =
          jsonDecode(utf8.decode(resp.bodyBytes)) as Map<String, dynamic>;
      if (json['success'] != true) return [];

      final records = <BingoRecord>[];
      for (final raw in (json['data'] as List<dynamic>)) {
        final item = raw as Map<String, dynamic>;
        final numStrs = item['一般獎號'] as List<dynamic>?;
        if (numStrs == null) continue;
        final numbers = numStrs
            .map((s) => int.tryParse(s.toString()) ?? 0)
            .where((n) => n >= 1 && n <= 80)
            .toList()
          ..sort();
        if (numbers.length < 15) continue;
        records.add(BingoRecord(
          drawNo: (item['期數'] as num).toInt(),
          drawDate: item['開獎日期']?.toString() ?? '',
          drawTime: item['開獎時間']?.toString() ?? '',
          numbers: numbers,
          superNum: item['超級獎號']?.toString() ?? '',
        ));
      }
      return records;
    } catch (_) {
      return [];
    }
  }

  // ── 私有：auzo.tw 備援 ────────────────────────────────────────

  Future<List<BingoRecord>> _fetchFromAuzo() async {
    try {
      final resp = await http.get(Uri.parse(_fallbackUrl), headers: {
        'User-Agent':
            'Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X)',
      }).timeout(const Duration(seconds: 8));
      if (resp.statusCode != 200) return [];
      return _parseAuzoHtml(resp.body);
    } catch (_) {
      return [];
    }
  }

  List<BingoRecord> _parseAuzoHtml(String html) {
    final records = <BingoRecord>[];
    final re = RegExp(
        r'(\d{9,12})\s+(\d{2}:\d{2})\s*((?:\d{2}\s*){20})',
        caseSensitive: false);
    for (final m in re.allMatches(html)) {
      final drawNo = int.tryParse(m.group(1) ?? '') ?? 0;
      final nums = (m.group(3) ?? '')
          .trim()
          .split(RegExp(r'\s+'))
          .map((s) => int.tryParse(s) ?? 0)
          .where((n) => n >= 1 && n <= 80)
          .toSet()
          .toList()
        ..sort();
      if (drawNo > 0 && nums.length >= 15) {
        records.add(BingoRecord(
          drawNo: drawNo,
          drawDate: '',
          drawTime: m.group(2) ?? '',
          numbers: nums.take(20).toList(),
        ));
      }
    }
    return records.take(180).toList();
  }

}
