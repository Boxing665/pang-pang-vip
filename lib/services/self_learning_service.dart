import 'dart:convert';
import 'dart:math' show sqrt;
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'prediction_log_service.dart';
import '../models/prediction_log.dart';

/// 自我學習服務
///
/// 運作流程：
///   1. 啟動時在背景替「預測中」的場次向 ESPN 拉取最終賽果，自動更新結果
///   2. 對已有結果的預測紀錄，用 Perceptron 規則調整各訊號權重
///   3. 將校正後的權重存入 SharedPreferences，下次預測時自動套用
class SelfLearningService {
  static const _weightsKey  = 'sl_signal_weights_v2';
  static const _lastRunKey  = 'sl_last_calibration';
  static const _minSamples  = 5;   // 最少樣本數才觸發校正
  static const _baseLearningRate = 0.04; // 動態學習率基準值
  static const _maxAge = Duration(days: 60); // 只用近 60 天的紀錄

  /// 動態學習率：樣本越多越收斂（n=10→0.04, n=40→0.02, n=160→0.01）
  static double _dynamicLR(int n) =>
      (_baseLearningRate / (1 + sqrt(n / 10.0))).clamp(0.008, 0.06);

  // 各運動預設權重（odds 主導，其餘輔助）
  static const _defaultWeights = <String, Map<String, double>>{
    'football':   {'odds': 0.40, 'momentum': 0.25, 'wins': 0.15, 'streak': 0.12, 'b2b': 0.08},
    'basketball': {'odds': 0.40, 'momentum': 0.25, 'wins': 0.15, 'streak': 0.12, 'b2b': 0.08},
    'baseball':   {'odds': 0.40, 'momentum': 0.25, 'wins': 0.15, 'streak': 0.12, 'b2b': 0.08},
  };

  // ESPN 聯賽路徑對應表
  static const _leagueToPath = <String, String>{
    'NBA': 'basketball/nba',
    'MLB': 'baseball/mlb',
    'NFL': 'football/nfl',
    '英超': 'soccer/eng.1',
    '西甲': 'soccer/esp.1',
    '德甲': 'soccer/ger.1',
    '意甲': 'soccer/ita.1',
    '法甲': 'soccer/fra.1',
    '日職': 'soccer/jpn.1',
    '澳職': 'soccer/aus.1',
    '韓職': 'soccer/kor.1',
    '歐冠': 'soccer/UEFA.CHAMPIONS',
    '歐霸': 'soccer/UEFA.EUROPA',
    '美職聯': 'soccer/usa.1',
  };

  static final _client = http.Client();

  // ── 對外 API ──────────────────────────────────────────────────────

  /// 載入校正後的權重（無紀錄時回傳預設值）
  static Future<Map<String, double>> loadWeightsFor(String sport) async {
    final all = await _loadAllWeights();
    final key = _normalizeSport(sport);
    return Map<String, double>.from(
      all[key] ?? _defaultWeights['football']!,
    );
  }

  /// 在背景執行：拉取賽果 → 校正權重（15 分鐘內不重複執行）
  static Future<void> runInBackground(PredictionLogService logSvc) async {
    final prefs = await SharedPreferences.getInstance();
    final lastRaw = prefs.getString(_lastRunKey);
    if (lastRaw != null) {
      final last = DateTime.tryParse(lastRaw);
      if (last != null &&
          DateTime.now().difference(last) < const Duration(minutes: 15)) {
        return;
      }
    }
    await _fetchPendingResults(logSvc);
    await _calibrateWeights(logSvc, prefs);
    await prefs.setString(_lastRunKey, DateTime.now().toIso8601String());
  }

  /// 強制執行（不受 15 分鐘防抖限制）：由計時器或賽事結束後觸發
  static Future<void> runForced(PredictionLogService logSvc) async {
    final prefs = await SharedPreferences.getInstance();
    await _fetchPendingResults(logSvc);
    await _calibrateWeights(logSvc, prefs);
    await prefs.setString(_lastRunKey, DateTime.now().toIso8601String());
  }

  // ── 私有：拉取賽果 ────────────────────────────────────────────────

  static Future<void> _fetchPendingResults(PredictionLogService logSvc) async {
    final logs = await logSvc.loadByType(PredictionType.sport);
    final pending = logs
        .where((l) =>
            l.outcome == PredictionOutcome.pending &&
            DateTime.now().difference(l.createdAt) > const Duration(hours: 3))
        .toList();

    for (final log in pending) {
      final matchId = log.details['matchId'] as String?;
      final league  = log.details['league']  as String?;
      if (matchId == null || league == null) continue;

      final result = await _fetchESPNScores(matchId, league);
      if (result == null) continue;

      final predicted = log.details['winner'] as String?;
      if (predicted == null || predicted.isEmpty) continue;

      final correct = result.winner == predicted;
      log.actualResult = result.winner;
      log.outcome      = correct ? PredictionOutcome.correct : PredictionOutcome.incorrect;
      log.accuracyScore = correct ? 1.0 : 0.0;
      await logSvc.save(log);
      await _autoLearnFromLog(log);

      // ── 大小分追蹤 ────────────────────────────────────────────
      final sport    = log.details['sport'] as String? ?? league;
      final overLine = (log.details['overLine'] as num?)?.toDouble() ?? 0.0;
      if (overLine > 0) {
        final predH     = (log.details['predictedHomeScore'] as num?)?.toDouble() ?? 0.0;
        final predA     = (log.details['predictedAwayScore'] as num?)?.toDouble() ?? 0.0;
        final predOver  = (predH + predA) > overLine;
        final actualOver = (result.homeScore + result.awayScore) > overLine;
        await recordOUPrediction(sport, predOver, actualOver);
      }

      // ── 放水/輪替偵測 ─────────────────────────────────────────
      // 若強隊（勝率預測>60%）輸分差過大(>15分)，記錄可能輪替場次
      final predWinProb = (log.details['mcHomeWinPct'] as num?)?.toDouble() ?? 0.5;
      final homeFav     = predWinProb > 0.60;
      final actualDiff  = (result.homeScore - result.awayScore).abs();
      final predDiff    = ((log.details['predictedHomeScore'] as num?)?.toDouble() ?? 0) -
                          ((log.details['predictedAwayScore'] as num?)?.toDouble() ?? 0);
      // 預測強隊贏但實際輸，且分差超過預測值 15 分以上 → 可能放水/輪替
      if (homeFav && result.winner != 'home' && actualDiff + predDiff.abs() > 15) {
        await _recordRestGame(league, matchId);
      }
    }
  }

  static const _restGamesKey = 'sl_rest_games_v1';

  static Future<void> _recordRestGame(String league, String matchId) async {
    final prefs = await SharedPreferences.getInstance();
    final raw   = prefs.getString(_restGamesKey);
    final data  = raw != null
        ? Map<String, dynamic>.from(jsonDecode(raw) as Map)
        : <String, dynamic>{};
    final List<String> ids = ((data[league] as List?)?.cast<String>()) ?? [];
    if (!ids.contains(matchId)) {
      ids.add(matchId);
      if (ids.length > 50) ids.removeAt(0); // 只保留近50筆
      data[league] = ids;
      await prefs.setString(_restGamesKey, jsonEncode(data));
    }
  }

  /// 取得各聯賽近期可能放水/輪替場次數量（供 UI 顯示）
  static Future<Map<String, int>> getRestGameCounts() async {
    final prefs = await SharedPreferences.getInstance();
    final raw   = prefs.getString(_restGamesKey);
    if (raw == null) return {};
    final data  = Map<String, dynamic>.from(jsonDecode(raw) as Map);
    return data.map((k, v) => MapEntry(k, ((v as List?)?.length) ?? 0));
  }

  /// 取得大小分偏差乘數（供 predictScore 套用）
  /// 若過去 O/U 命中率低，代表 lambda 系統性偏高/低，適度修正
  static Future<double> getOUBiasMultiplier(String sport) async {
    final acc = await getOUAccuracy(sport);
    if (acc == null) return 1.0;
    if (acc < 0.38) return 0.93; // 大幅低估/高估 → 縮減
    if (acc < 0.48) return 0.97;
    if (acc > 0.72) return 1.03; // 準確率高 → 輕微加成信心
    return 1.0;
  }

  /// 向 ESPN 查詢已完賽事的勝負 + 比分
  static Future<({String winner, double homeScore, double awayScore})?> _fetchESPNScores(
      String eventId, String league) async {
    final path = _leagueToPath[league];
    if (path == null) return null;

    try {
      final uri = Uri.parse(
        'https://site.api.espn.com/apis/site/v2/sports/$path/summary?event=$eventId',
      );
      final resp = await _client
          .get(uri, headers: const {'Accept': 'application/json'})
          .timeout(const Duration(seconds: 8));
      if (resp.statusCode != 200) return null;

      final data     = jsonDecode(resp.body) as Map<String, dynamic>;
      final compList = data['header']?['competitions'] as List?;
      final comps    = (compList != null && compList.isNotEmpty ? compList.first : null)
          as Map<String, dynamic>?;
      if (comps == null) return null;

      final finished =
          (comps['status']?['type'] as Map<String, dynamic>?)?['completed'] as bool? ?? false;
      if (!finished) return null;

      double? homeScore, awayScore;
      for (final c in (comps['competitors'] as List? ?? [])) {
        final comp   = c as Map<String, dynamic>;
        final isHome = (comp['homeAway'] as String?) == 'home';
        final score  = double.tryParse(comp['score']?.toString() ?? '');
        if (isHome) { homeScore = score; } else { awayScore = score; }
      }
      if (homeScore == null || awayScore == null) return null;

      final winner = homeScore > awayScore ? 'home' : awayScore > homeScore ? 'away' : 'draw';
      return (winner: winner, homeScore: homeScore, awayScore: awayScore);
    } catch (_) {
      return null;
    }
  }

  // ── 私有：Perceptron 權重校正 ──────────────────────────────────────

  static Future<void> _calibrateWeights(
      PredictionLogService logSvc, SharedPreferences prefs) async {
    final logs = await logSvc.loadByType(PredictionType.sport);
    final cutoff = DateTime.now().subtract(_maxAge);
    final decided = logs
        .where((l) =>
            l.outcome != PredictionOutcome.pending &&
            l.createdAt.isAfter(cutoff) &&
            l.details.containsKey('edge'))
        .toList();

    if (decided.length < _minSamples) return;

    final weights = await _loadAllWeights();

    for (final log in decided) {
      final sport = _normalizeSport(log.details['sport'] as String? ?? '');
      final w     = weights[sport];
      if (w == null) continue;

      final correct    = log.outcome == PredictionOutcome.correct;
      // 信心加權：高信心預測錯誤懲罰更重；高信心正確更強化
      final confidence = ((log.details['confidence'] as num?)?.toDouble() ?? 0.6).clamp(0.4, 1.0);
      final reward     = correct ? confidence : -confidence;
      // 動態學習率：樣本越多越收斂
      final lr = _dynamicLR(decided.length);

      final edge   = (log.details['edge']               as num?)?.toDouble() ?? 0.0;
      final nOdds  = (log.details['normalizedOdds']     as num?)?.toDouble() ?? 0.0;
      final nMom   = (log.details['normalizedMomentum'] as num?)?.toDouble() ?? 0.0;
      final nWins  = (log.details['normalizedWins']     as num?)?.toDouble() ?? 0.0;
      final nStr   = (log.details['normalizedStreak']   as num?)?.toDouble() ?? 0.0;
      final b2b    = (log.details['b2bEdge']            as num?)?.toDouble() ?? 0.0;

      if (edge == 0) continue;
      final edgeSign = edge > 0 ? 1.0 : -1.0;

      // Perceptron 更新：訊號與 edge 同向 → 加強；反向 → 削弱
      void update(String key, double sig) {
        final aligned = (sig >= 0 ? 1.0 : -1.0) == edgeSign ? 1.0 : -1.0;
        w[key] = (w[key]! + lr * reward * aligned * sig.abs())
            .clamp(0.05, 0.70);
      }

      update('odds',     nOdds);
      update('momentum', nMom);
      update('wins',     nWins);
      update('streak',   nStr);
      update('b2b',      b2b);
    }

    // 每個運動的權重正規化到加總 = 1.0
    for (final sport in weights.keys) {
      final total = weights[sport]!.values.reduce((a, b) => a + b);
      if (total > 0) {
        for (final k in weights[sport]!.keys) {
          weights[sport]![k] = weights[sport]![k]! / total;
        }
      }
    }

    await prefs.setString(_weightsKey, jsonEncode(weights));
  }

  // ── 私有：輔助工具 ─────────────────────────────────────────────────

  static Future<Map<String, Map<String, double>>> _loadAllWeights() async {
    final prefs = await SharedPreferences.getInstance();
    final raw   = prefs.getString(_weightsKey);
    final result = <String, Map<String, double>>{
      for (final e in _defaultWeights.entries)
        e.key: Map<String, double>.from(e.value),
    };
    if (raw == null) return result;
    try {
      final decoded = jsonDecode(raw) as Map<String, dynamic>;
      for (final sport in result.keys) {
        final sm = decoded[sport] as Map<String, dynamic>?;
        if (sm == null) continue;
        for (final signal in result[sport]!.keys) {
          final v = (sm[signal] as num?)?.toDouble();
          if (v != null) result[sport]![signal] = v;
        }
      }
    } catch (_) {}
    return result;
  }

  static String _normalizeSport(String raw) {
    if (raw.contains('basketball') || raw == 'basketball') return 'basketball';
    if (raw.contains('baseball')   || raw == 'baseball')   return 'baseball';
    return 'football';
  }

  // ══════════════════════════════════════════════════════════════════
  // ── 自適應策略系統（Adaptive Strategy Engine）──────────────────────
  // ══════════════════════════════════════════════════════════════════

  static const _ouAccKey          = 'sl_ou_accuracy_v2';   // 大小分命中率
  static const _strategyPerfKey   = 'sl_strategy_perf_v2'; // 策略績效
  static const _parkFactorKey     = 'sl_park_factors_v2';  // 動態球場因子
  static const _bingoStratKey     = 'sl_bingo_strat_v2';   // 賓果策略
  static const _lottery539StratKey = 'sl_539_strat_v2';    // 539策略
  static const _strategyWindow    = 20; // 滾動視窗大小

  // ── 大小分命中率追蹤 ──────────────────────────────────────────────

  /// 記錄大小分預測結果（由 PredictionLogService 結算後呼叫）
  static Future<void> recordOUPrediction(
      String sport, bool predictedOver, bool actualOver) async {
    final prefs = await SharedPreferences.getInstance();
    final raw   = prefs.getString(_ouAccKey);
    final data  = raw != null
        ? Map<String, dynamic>.from(jsonDecode(raw) as Map)
        : <String, dynamic>{};
    final key = _normalizeSport(sport);
    final List<int> history = ((data[key] as List?)?.cast<int>()) ?? [];
    history.add((predictedOver == actualOver) ? 1 : 0);
    if (history.length > _strategyWindow) history.removeAt(0);
    data[key] = history;
    await prefs.setString(_ouAccKey, jsonEncode(data));
  }

  /// 取得指定運動的大小分近期命中率（0.0~1.0），樣本不足回傳 null
  static Future<double?> getOUAccuracy(String sport) async {
    final prefs = await SharedPreferences.getInstance();
    final raw   = prefs.getString(_ouAccKey);
    if (raw == null) return null;
    final data    = Map<String, dynamic>.from(jsonDecode(raw) as Map);
    final history = ((data[_normalizeSport(sport)] as List?)?.cast<int>()) ?? [];
    if (history.length < 5) return null;
    return history.reduce((a, b) => a + b) / history.length;
  }

  // ── 策略績效追蹤（三種策略輪替）─────────────────────────────────────
  // strategy_a = 市場主導 (aiW=0.22, mktW=0.78)
  // strategy_b = 均衡   (aiW=0.40, mktW=0.60)
  // strategy_c = AI主導  (aiW=0.60, mktW=0.40)

  static const _strategyProfiles = {
    'strategy_a': (aiW: 0.22, mktW: 0.78),
    'strategy_b': (aiW: 0.40, mktW: 0.60),
    'strategy_c': (aiW: 0.60, mktW: 0.40),
  };

  /// 記錄某策略的預測結果
  static Future<void> recordStrategyOutcome(
      String sport, String strategyUsed, bool correct) async {
    final prefs = await SharedPreferences.getInstance();
    final raw   = prefs.getString(_strategyPerfKey);
    final data  = raw != null
        ? Map<String, dynamic>.from(jsonDecode(raw) as Map)
        : <String, dynamic>{};
    final sKey  = _normalizeSport(sport);
    final sData = Map<String, dynamic>.from(
        (data[sKey] as Map<dynamic, dynamic>?) ?? {});
    final List<int> hist =
        ((sData[strategyUsed] as List?)?.cast<int>()) ?? [];
    hist.add(correct ? 1 : 0);
    if (hist.length > _strategyWindow) hist.removeAt(0);
    sData[strategyUsed] = hist;
    data[sKey] = sData;
    await prefs.setString(_strategyPerfKey, jsonEncode(data));
  }

  /// 取得建議的自適應權重（aiWeight / marketWeight）
  /// 若樣本不足，依運動回傳安全預設值
  static Future<({double aiWeight, double marketWeight, String strategy})>
      getAdaptiveWeights(String sport) async {
    final prefs = await SharedPreferences.getInstance();
    final raw   = prefs.getString(_strategyPerfKey);
    if (raw == null) return _defaultAdaptiveWeights(sport);
    final data  = Map<String, dynamic>.from(jsonDecode(raw) as Map);
    final sKey  = _normalizeSport(sport);
    final sData = Map<String, dynamic>.from(
        (data[sKey] as Map<dynamic, dynamic>?) ?? {});

    String bestStrategy = 'strategy_b';
    double bestRate = -1;
    for (final strategy in _strategyProfiles.keys) {
      final hist = ((sData[strategy] as List?)?.cast<int>()) ?? [];
      if (hist.length < 5) continue; // 不足樣本跳過
      final rate = hist.reduce((a, b) => a + b) / hist.length;
      if (rate > bestRate) {
        bestRate   = rate;
        bestStrategy = strategy;
      }
    }
    // 若最佳策略勝率不到 38%，升級探索下一個策略（避免卡死）
    if (bestRate >= 0 && bestRate < 0.38) {
      final keys = _strategyProfiles.keys.toList();
      final idx  = keys.indexOf(bestStrategy);
      bestStrategy = keys[(idx + 1) % keys.length];
    }
    final profile = _strategyProfiles[bestStrategy]!;
    return (
      aiWeight: profile.aiW,
      marketWeight: profile.mktW,
      strategy: bestStrategy,
    );
  }

  static ({double aiWeight, double marketWeight, String strategy})
      _defaultAdaptiveWeights(String sport) {
    final s = _normalizeSport(sport);
    if (s == 'baseball')   return (aiWeight: 0.35, marketWeight: 0.65, strategy: 'strategy_b');
    if (s == 'basketball') return (aiWeight: 0.30, marketWeight: 0.70, strategy: 'strategy_b');
    return (aiWeight: 0.38, marketWeight: 0.62, strategy: 'strategy_b');
  }

  // ── 動態球場因子（Dynamic Park Factor）──────────────────────────────
  // 由 real_data_service 計算並存入；優先級高於硬編碼表

  /// 儲存由實際得失分推算的動態球場因子
  static Future<void> storeDynamicParkFactor(
      String teamKey, double factor) async {
    final prefs = await SharedPreferences.getInstance();
    final raw   = prefs.getString(_parkFactorKey);
    final data  = raw != null
        ? Map<String, dynamic>.from(jsonDecode(raw) as Map)
        : <String, dynamic>{};
    data[teamKey.toLowerCase()] = factor.clamp(0.75, 1.35);
    await prefs.setString(_parkFactorKey, jsonEncode(data));
  }

  /// 取得所有動態球場因子（供 PredictionEngine 使用）
  static Future<Map<String, double>> getAllDynamicParkFactors() async {
    final prefs = await SharedPreferences.getInstance();
    final raw   = prefs.getString(_parkFactorKey);
    if (raw == null) return {};
    try {
      final data = Map<String, dynamic>.from(jsonDecode(raw) as Map);
      return {
        for (final e in data.entries)
          e.key: (e.value as num).toDouble(),
      };
    } catch (_) { return {}; }
  }

  // ── 賓果自適應策略 ──────────────────────────────────────────────────
  // 策略：'frequency'（高頻熱號）| 'gap'（遺漏冷號）
  //      | 'transition'（轉移矩陣）| 'balanced'（綜合）

  static const _bingoStrategies = ['balanced', 'frequency', 'gap', 'transition'];
  static const _bingoZoneKey    = 'sl_bingo_zone_v1';   // 區間命中率
  static const _bingoHitListKey = 'sl_bingo_hitlist_v1'; // 每局命中數列表

  /// 記錄賓果策略命中情況（hitCount = 本次預測有幾個號碼中獎）
  static Future<void> recordBingoStrategy(
      String strategyUsed, int hitCount) async {
    final prefs = await SharedPreferences.getInstance();
    final raw   = prefs.getString(_bingoStratKey);
    final data  = raw != null
        ? Map<String, dynamic>.from(jsonDecode(raw) as Map)
        : <String, dynamic>{};
    // 用 hitCount>0 視為命中
    final List<int> hist =
        ((data[strategyUsed] as List?)?.cast<int>()) ?? [];
    hist.add(hitCount > 0 ? 1 : 0);
    if (hist.length > _strategyWindow) hist.removeAt(0);
    data[strategyUsed] = hist;
    await prefs.setString(_bingoStratKey, jsonEncode(data));
  }

  /// 記錄賓果詳細命中（含區間統計），由 BingoScreen 在開獎後自動呼叫
  /// 回傳 true 代表策略已自動切換（呼叫端可重新預測）
  static Future<bool> recordBingoDetail({
    required int drawNo,
    required List<int> predicted,
    required List<int> actual,
    required String strategy,
  }) async {
    final hitCount = predicted.where((n) => actual.contains(n)).length;
    await recordBingoStrategy(strategy, hitCount);

    final prefs = await SharedPreferences.getInstance();

    // ── 區間命中統計（zone 0–7：每區 10 個號碼）──────────────────
    final zoneRaw  = prefs.getString(_bingoZoneKey);
    final zoneData = zoneRaw != null
        ? Map<String, dynamic>.from(jsonDecode(zoneRaw) as Map)
        : <String, dynamic>{};
    for (var z = 0; z < 8; z++) {
      final zStart = z * 10 + 1;
      final zEnd   = z * 10 + 10;
      final predInZone = predicted.where((n) => n >= zStart && n <= zEnd).length;
      final hitInZone  = predicted.where((n) => n >= zStart && n <= zEnd && actual.contains(n)).length;
      final List<int> zh = ((zoneData['z$z'] as List?)?.cast<int>()) ?? [];
      zh.add(predInZone > 0 && hitInZone > 0 ? 1 : (predInZone == 0 ? -1 : 0));
      if (zh.length > 30) zh.removeAt(0);
      zoneData['z$z'] = zh;
    }
    await prefs.setString(_bingoZoneKey, jsonEncode(zoneData));

    // ── 每局命中數列表（供圖表趨勢顯示）────────────────────────────
    final hlRaw  = prefs.getString(_bingoHitListKey);
    final hlData = hlRaw != null
        ? Map<String, dynamic>.from(jsonDecode(hlRaw) as Map)
        : <String, dynamic>{};
    final List<int> hitList = ((hlData['hits'] as List?)?.cast<int>()) ?? [];
    hitList.add(hitCount);
    if (hitList.length > 50) hitList.removeAt(0);
    hlData['hits'] = hitList;
    hlData['lastDrawNo'] = drawNo;
    await prefs.setString(_bingoHitListKey, jsonEncode(hlData));

    // ── 自動切換策略：近 5 局平均命中 < 1.5 顆 → 自動換策略 ─────────
    if (hitList.length >= 5) {
      final recent5 = hitList.sublist(hitList.length - 5);
      final avg5 = recent5.reduce((a, b) => a + b) / 5.0;
      if (avg5 < 1.5) {
        await forceNextBingoStrategy();
        return true; // 已自動切換
      }
    }
    return false;
  }

  /// 取得各區間命中乘數（zone 0–7 → 0.85–1.20），供 BingoService 調整評分
  static Future<Map<int, double>> getBingoZoneMultipliers() async {
    final prefs = await SharedPreferences.getInstance();
    final raw   = prefs.getString(_bingoZoneKey);
    if (raw == null) return {};
    final data = Map<String, dynamic>.from(jsonDecode(raw) as Map);
    final result = <int, double>{};
    for (var z = 0; z < 8; z++) {
      final hist = ((data['z$z'] as List?)?.cast<int>())
          ?.where((v) => v >= 0) // 排除 -1（未預測該區）
          .toList() ?? [];
      if (hist.length < 5) continue;
      final rate = hist.reduce((a, b) => a + b) / hist.length;
      result[z] = (0.85 + rate * 0.35).clamp(0.85, 1.20);
    }
    return result;
  }

  /// 取得近期賓果每局命中數列表（最新在後，最多 50 局）
  static Future<({List<int> hits, double avgHits})> getBingoHitHistory() async {
    final prefs = await SharedPreferences.getInstance();
    final raw   = prefs.getString(_bingoHitListKey);
    if (raw == null) return (hits: <int>[], avgHits: 0.0);
    final data  = Map<String, dynamic>.from(jsonDecode(raw) as Map);
    final hits  = List<int>.from((data['hits'] as List?) ?? <int>[]);
    if (hits.isEmpty) return (hits: hits, avgHits: 0.0);
    final avg = hits.reduce((a, b) => a + b) / hits.length;
    return (hits: hits, avgHits: avg);
  }

  /// 取得各策略近期命中率（供圖表顯示），key=strategyName, value=rate 0.0-1.0
  static Future<Map<String, double>> getBingoStrategyRates() async {
    final prefs = await SharedPreferences.getInstance();
    final raw   = prefs.getString(_bingoStratKey);
    if (raw == null) return {};
    final data  = Map<String, dynamic>.from(jsonDecode(raw) as Map);
    final result = <String, double>{};
    for (final s in _bingoStrategies) {
      final hist = ((data[s] as List?)?.cast<int>()) ?? [];
      if (hist.isEmpty) continue;
      result[s] = hist.reduce((a, b) => a + b) / hist.length;
    }
    return result;
  }

  /// 強制切換至下一個賓果策略（使用者手動觸發或命中率長期低落）
  static Future<String> forceNextBingoStrategy() async {
    final current = await getRecommendedBingoStrategy();
    final prefs   = await SharedPreferences.getInstance();
    final raw     = prefs.getString(_bingoStratKey);
    final data    = raw != null
        ? Map<String, dynamic>.from(jsonDecode(raw) as Map)
        : <String, dynamic>{};
    // 強制壓低當前策略分數以觸發切換
    data[current] = <int>[0, 0, 0, 0, 0];
    await prefs.setString(_bingoStratKey, jsonEncode(data));
    final idx  = _bingoStrategies.indexOf(current);
    return _bingoStrategies[(idx + 1) % _bingoStrategies.length];
  }

  /// 取得建議的賓果策略名稱
  static Future<String> getRecommendedBingoStrategy() async {
    final prefs = await SharedPreferences.getInstance();
    final raw   = prefs.getString(_bingoStratKey);
    if (raw == null) return 'balanced';
    final data  = Map<String, dynamic>.from(jsonDecode(raw) as Map);
    String best = 'balanced';
    double bestRate = -1;
    for (final s in _bingoStrategies) {
      final hist = ((data[s] as List?)?.cast<int>()) ?? [];
      if (hist.length < 4) continue;
      final rate = hist.reduce((a, b) => a + b) / hist.length;
      if (rate > bestRate) { bestRate = rate; best = s; }
    }
    // 若最佳策略連續失敗（<20%命中），換策略探索
    if (bestRate >= 0 && bestRate < 0.20) {
      final idx = _bingoStrategies.indexOf(best);
      best = _bingoStrategies[(idx + 1) % _bingoStrategies.length];
    }
    return best;
  }

  // ── 539 自適應策略 ───────────────────────────────────────────────────

  static const _lottery539Strategies = ['balanced', 'hot', 'cold', 'pattern'];

  static Future<void> record539Strategy(
      String strategyUsed, int hitCount) async {
    final prefs = await SharedPreferences.getInstance();
    final raw   = prefs.getString(_lottery539StratKey);
    final data  = raw != null
        ? Map<String, dynamic>.from(jsonDecode(raw) as Map)
        : <String, dynamic>{};
    final List<int> hist =
        ((data[strategyUsed] as List?)?.cast<int>()) ?? [];
    hist.add(hitCount > 0 ? 1 : 0);
    if (hist.length > _strategyWindow) hist.removeAt(0);
    data[strategyUsed] = hist;
    await prefs.setString(_lottery539StratKey, jsonEncode(data));
  }

  static Future<String> getRecommended539Strategy() async {
    final prefs = await SharedPreferences.getInstance();
    final raw   = prefs.getString(_lottery539StratKey);
    if (raw == null) return 'balanced';
    final data  = Map<String, dynamic>.from(jsonDecode(raw) as Map);
    String best = 'balanced';
    double bestRate = -1;
    for (final s in _lottery539Strategies) {
      final hist = ((data[s] as List?)?.cast<int>()) ?? [];
      if (hist.length < 4) continue;
      final rate = hist.reduce((a, b) => a + b) / hist.length;
      if (rate > bestRate) { bestRate = rate; best = s; }
    }
    if (bestRate >= 0 && bestRate < 0.20) {
      final idx = _lottery539Strategies.indexOf(best);
      best = _lottery539Strategies[(idx + 1) % _lottery539Strategies.length];
    }
    return best;
  }

  // ── 結算時自動觸發學習 ───────────────────────────────────────────────

  /// 在 _fetchPendingResults 結算後呼叫：自動記錄大小分/策略結果
  static Future<void> _autoLearnFromLog(PredictionLog log) async {
    final sport = log.details['sport'] as String? ?? '';
    if (sport.isEmpty) return;

    // 大小分學習
    final predictedOver = log.details['ouCall'] as String?; // 'over' | 'under'
    final actualH = (log.details['actualHomeScore'] as num?)?.toDouble();
    final actualA = (log.details['actualAwayScore'] as num?)?.toDouble();
    final overLine = (log.details['overLine'] as num?)?.toDouble();
    if (predictedOver != null && actualH != null && actualA != null && overLine != null && overLine > 0) {
      final actualOver = (actualH + actualA) > overLine;
      await recordOUPrediction(sport, predictedOver == 'over', actualOver);
    }

    // 策略學習
    final strategy = log.details['adaptiveStrategy'] as String? ?? 'strategy_b';
    final correct  = log.outcome == PredictionOutcome.correct;
    await recordStrategyOutcome(sport, strategy, correct);
  }
}
