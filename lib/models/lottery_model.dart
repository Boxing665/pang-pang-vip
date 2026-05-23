import 'dart:math';

/// 體育賽事紀錄 (替代原本的 DrawRecord)
class SportsMatchRecord {
  const SportsMatchRecord({
    required this.date,
    required this.sportType, // 'soccer', 'basketball', 'baseball'
    required this.homeTeam,
    required this.awayTeam,
    required this.homeScore,
    required this.awayScore,
    required this.spread, // 讓分
  });

  final String date;
  final String sportType;
  final String homeTeam;
  final String awayTeam;
  final int homeScore;
  final int awayScore;
  final double spread;
}

/// 體育賽事預測結果
class SportsPrediction {
  SportsPrediction({
    required this.teamName,
    required this.score,
    required this.reason,
    this.rank = 0,
    this.confidence = 0.0,
    this.mcConsistency = 0.0,
  });

  final String teamName;
  final double score;
  final String reason;
  int rank;

  /// 相對信心度：分數 / 本次分析最高分，0.0–1.0
  double confidence;

  /// 蒙地卡羅一致性：在 5 次子樣本重複分析中出現在前 N 名的比例，0.0–1.0
  double mcConsistency;
}

/// 足球平局預測結果
class SoccerDrawPrediction {
  SoccerDrawPrediction({
    required this.matchName,
    required this.drawProbability,
    required this.reasons,
    this.confidence = 0.0,
  });

  final String matchName;
  final double drawProbability; // 0.0 - 1.0
  final List<String> reasons;
  final double confidence;
}

/// 體育分析引擎：基於戰力與趨勢
class SportsAnalyzer {
  SportsAnalyzer({
    required this.matchRecords,
    required this.teamEloRatings,
    this.teamInjuryImpact = const {}, // 新增：傷病影響權重 (1.0 = 無影響, < 1.0 = 實力下降)
    this.soccerDrawWeights = const {}, // 新增：外部動態權重
    required this.taiwanNow,
  });

  final List<SportsMatchRecord> matchRecords;
  final Map<String, double> teamEloRatings;
  
  final Map<String, double> soccerDrawWeights;

  /// 傷病影響權重 Map。
  /// 例如：{'湖人': 0.85} 代表因核心傷病，戰力僅剩 85%。
  final Map<String, double> teamInjuryImpact;
  
  final DateTime taiwanNow;

  /// 分析主邏輯
  List<SportsPrediction> analyze({
    List<String> focusTeams = const [],
    int topN = 5,
  }) {
    if (matchRecords.isEmpty) return [];

    final scores = <String, double>{};
    final reasons = <String, List<String>>{};
    final allTeams = _extractUniqueTeams();

    for (final team in allTeams) {
      double s = teamEloRatings[team] ?? 1500.0; 
      final tags = <String>[];
      final recentMatches = matchRecords.where((m) => m.homeTeam == team || m.awayTeam == team).take(5).toList();
      int winCount = 0;
      int atsCoverCount = 0; // 贏過盤口的次數

      for (final m in recentMatches) {
        final isHome = m.homeTeam == team;
        final teamScore = isHome ? m.homeScore : m.awayScore;
        final oppScore = isHome ? m.awayScore : m.homeScore;
        
        if (teamScore > oppScore) winCount++;
        
        // ATS (Against The Spread) 分析
        final adjustedScore = isHome ? (teamScore + m.spread) : teamScore.toDouble();
        final opponentAdjusted = isHome ? oppScore.toDouble() : (oppScore + m.spread);
        if (adjustedScore > opponentAdjusted) atsCoverCount++;
      }

      if (winCount >= 4) { s += 100; tags.add('五戰四勝↑'); }
      if (atsCoverCount >= 4) { s += 150; tags.add('盤路強勢'); }
      if (atsCoverCount <= 1) { s -= 100; tags.add('盤路低迷'); }

      // 2. 主場優勢加成
      final homeMatches = recentMatches.where((m) => m.homeTeam == team).toList();
      if (homeMatches.isNotEmpty) {
        final sportType = homeMatches.first.sportType;
        final config = _getHomeAdvantageConfig(sportType);
        double homeWinRate = homeMatches.where((m) => m.homeScore > m.awayScore).length / homeMatches.length;
        if (homeWinRate >= config.threshold) {
          s += config.bonus;
          tags.add('主場強勢(${config.label})');
        }
      }

      // 3. 強制關注隊伍加成
      if (focusTeams.contains(team)) {
        s += 200;
        tags.add('重點追蹤');
      }

      scores[team] = s;
      reasons[team] = tags;
    }
    
    return _finalizePredictions(scores, reasons, topN);
  }

  /// 專門針對足球平局的分析模型
  List<SoccerDrawPrediction> analyzeSoccerDraws({int limit = 5}) {
    final soccerMatches = matchRecords.where((m) => m.sportType == 'soccer').toList();
    final predictions = <SoccerDrawPrediction>[];

    for (final m in soccerMatches) {
      final tags = <String>[];
      
      // 使用精確卜瓦松公式計算 P(X=Y)
      // P(Draw) = Σ [ (e^-λH * λH^k / k!) * (e^-λA * λA^k / k!) ] 對於 k = 0, 1, 2...
      final statsH = _getTeamStats(m.homeTeam);
      final statsA = _getTeamStats(m.awayTeam);
      
      double lambdaH = statsH.avgGoals;
      double lambdaA = statsA.avgGoals;
      
      double drawProb = 0.0;
      for (int k = 0; k <= 5; k++) { // 足球鮮少超過 5 球
        double probH = _poissonPMF(lambdaH, k);
        double probA = _poissonPMF(lambdaA, k);
        drawProb += (probH * probA);
      }

      if (lambdaH < 1.2 && lambdaA < 1.2) tags.add('低均分泊松增益');
      if ((lambdaH - lambdaA).abs() < 0.3) tags.add('均勢對決');

      predictions.add(SoccerDrawPrediction(
        matchName: '${m.homeTeam} vs ${m.awayTeam}',
        drawProbability: drawProb.clamp(0.0, 0.90),
        reasons: tags,
        confidence: (drawProb / 0.4).clamp(0.0, 1.0), // 足球 0.4 以上即屬極高機率
      ));
    }

    predictions.sort((a, b) => b.drawProbability.compareTo(a.drawProbability));
    return predictions.take(limit).toList();
  }

  double _poissonPMF(double lambda, int k) {
    if (lambda <= 0) return k == 0 ? 1.0 : 0.0;
    double factorial = 1.0;
    for (int i = 1; i <= k; i++) { factorial *= i; }
    return (pow(lambda, k) * exp(-lambda)) / factorial;
  }

  /// 獲取球隊進階統計
  _TeamStats _getTeamStats(String teamName) {
    final teamMatches = matchRecords.where((m) => m.homeTeam == teamName || m.awayTeam == teamName).toList();
    if (teamMatches.isEmpty) return const _TeamStats(avgGoals: 2.5, drawRate: 0.25);

    int totalGoals = 0;
    int draws = 0;
    for (final m in teamMatches) {
      totalGoals += (m.homeScore + m.awayScore);
      if (m.homeScore == m.awayScore) draws++;
    }

    return _TeamStats(
      avgGoals: totalGoals / teamMatches.length,
      drawRate: draws / teamMatches.length,
    );
  }

  List<SportsPrediction> _finalizePredictions(
    Map<String, double> scores, 
    Map<String, List<String>> reasons, 
    int topN
  ) {

    final sorted = scores.entries.toList()..sort((a, b) => b.value.compareTo(a.value));
    final maxScore = sorted.isNotEmpty ? sorted.first.value : 1.0;

    return sorted.take(topN).toList().asMap().entries.map((e) {
      return SportsPrediction(
        teamName: e.value.key,
        score: e.value.value,
        reason: (reasons[e.value.key] ?? []).join('・'),
        rank: e.key + 1,
        confidence: (e.value.value / maxScore).clamp(0.0, 1.0),
      );
    }).toList();
  }

  Set<String> _extractUniqueTeams() {
    final teams = <String>{};
    for (final m in matchRecords) {
      teams.add(m.homeTeam);
      teams.add(m.awayTeam);
    }
    return teams;
  }

  /// 根據運動種類獲取主場優勢配置
  _HomeAdvConfig _getHomeAdvantageConfig(String sportType) {
    switch (sportType) {
      case 'basketball':
        // 籃球主場效應最強，門檻設為 65%
        return const _HomeAdvConfig(threshold: 0.65, bonus: 85.0, label: '魔鬼主場');
      case 'soccer':
        // 足球考慮到平局多，勝率門檻略低
        return const _HomeAdvConfig(threshold: 0.60, bonus: 65.0, label: '堅固主場');
      case 'baseball':
        // 棒球主場優勢相對較小，門檻與加分微調
        return const _HomeAdvConfig(threshold: 0.55, bonus: 40.0, label: '最後打擊權');
      default:
        return const _HomeAdvConfig(threshold: 0.70, bonus: 50.0, label: '主場龍');
    }
  }
}

class _HomeAdvConfig {
  final double threshold;
  final double bonus;
  final String label;
  const _HomeAdvConfig({required this.threshold, required this.bonus, required this.label});
}

class _TeamStats {
  final double avgGoals;
  final double drawRate;
  const _TeamStats({required this.avgGoals, required this.drawRate});
}

/// 539 開獎紀錄
class DrawRecord {
  const DrawRecord({
    required this.date,
    required this.numbers,
  });

  final String date; // MM/DD
  final List<int> numbers; // 1..39

  String get displayNumbers =>
      numbers.map((n) => n.toString().padLeft(2, '0')).join('  ');
}

/// 539 推薦結果
class LotteryResult {
  LotteryResult({
    required this.number,
    required this.score,
    required this.reason,
    this.rank = 0,
    this.confidence = 0,
    this.mcConsistency = 0,
  });

  final int number;
  final double score;
  final String reason;
  int rank;
  double confidence;
  double mcConsistency;

  String get displayNumber => number.toString().padLeft(2, '0');
}

/// 拖牌記錄：開出 trigger 號後隔 interval 期拖出 drag 號
class DragPattern {
  const DragPattern({
    required this.trigger,
    required this.interval,
    required this.drag,
    required this.hitRate,
    required this.hitCount,
    required this.currentGap,   // 目前已隔幾期（-1 = 等待 trigger 再出現）
    required this.isDueNext,    // 是否本期命中（紅框）
  });

  final int trigger;
  final int interval;
  final int drag;
  final double hitRate;
  final int hitCount;
  final int currentGap;
  final bool isDueNext;

  String get description =>
      '開${trigger.toString().padLeft(2, '0')}後隔$interval期拖${drag.toString().padLeft(2, '0')}（命中率${(hitRate * 100).toStringAsFixed(0)}%，$hitCount次）';
}

/// 樂透獲取與分析結果封裝
class LotteryFetchResult {
  final List<LotteryResult> results;
  final List<DrawRecord> records539;
  final List<DrawRecord> recordsLotto;
  final List<DrawRecord> recordsPower;
  final List<DragPattern> dragPatterns;
  final String errorMessage;
  final DetailedLotteryAnalysis? detailedAnalysis;

  const LotteryFetchResult({
    required this.results,
    required this.records539,
    required this.recordsLotto,
    required this.recordsPower,
    this.dragPatterns = const [],
    this.errorMessage = '',
    this.detailedAnalysis,
  });

  bool get hasError => errorMessage.isNotEmpty;

  /// 本期即將命中的拖牌號碼（紅框優先，再加高命中率但差一期者）
  List<int> get activeDragNumbers {
    final due = dragPatterns.where((p) => p.isDueNext).map((p) => p.drag).toSet();
    // 命中率 >= 75% 且差 1 期即到達的補充
    final nearDue = dragPatterns
        .where((p) => !p.isDueNext && p.hitRate >= 0.75 && p.currentGap >= 0 && p.currentGap == p.interval - 1)
        .map((p) => p.drag);
    return {...due, ...nearDue}.toList()..sort();
  }
}

/// 539 分析引擎
class LotteryAnalyzer {
  LotteryAnalyzer({
    required this.records,
    required this.lottoRecords,
    required this.powerRecords,
    required this.taiwanNow,
  });

  final List<DrawRecord> records; // 539
  final List<DrawRecord> lottoRecords; // 大樂透
  final List<DrawRecord> powerRecords; // 威力彩
  final DateTime taiwanNow;

  List<LotteryResult> analyze({
    List<int> redHints = const [],
    List<int> excludeNumbers = const [],
    int topN = 5,
    Map<String, double> strategyMultipliers = const {},
    Map<int, double> newspaperBonuses = const {},
  }) {
    if (records.isEmpty) return [];

    final scores = <int, double>{for (var n = 1; n <= 39; n++) n: 0};
    final reasons = <int, List<String>>{for (var n = 1; n <= 39; n++) n: []};
    final recent = records.take(35).toList();

    // ── 預計算：歷史平均開獎間隔（個化化的「到點」基準）──────────────
    // 每個號碼的平均間隔 = 歷史期數 / 出現次數（最多200期）
    final longHistory = records.take(200).toList();
    final avgInterval = <int, double>{};
    for (var n = 1; n <= 39; n++) {
      final appearances = longHistory.where((r) => r.numbers.contains(n)).length;
      avgInterval[n] = appearances > 0
          ? (longHistory.length / appearances).clamp(2.0, 35.0)
          : 35.0;
    }

    // ── Step 0: 尾數分析 (Last Digit Analysis) ──────────────────
    // 統計 0-9 尾數的近期熱度規律，用以縮小號碼範圍
    final digitStats = _analyzeLastDigits(records.take(50).toList());
    final lastDigitScores = <int, double>{};
    for (var n = 1; n <= 39; n++) {
      final digit = n % 10;
      final stat = digitStats[digit] ?? {'heat': 0.0, 'gap': 0.0};
      
      // 尾數熱度權重 (基於近期出現頻率與遺漏回補)
      double ds = (stat['heat']! * 28.0) + (stat['gap']! >= 5 ? 12.0 : 0.0);
      lastDigitScores[n] = ds;
      if (stat['heat']! > 0.75) reasons[n]!.add('熱門尾數($digit尾)');
    }

    // ── 冷號分析（未開或超久未開的號碼） ──────────────────────
    final lastAppearance = <int, int>{for (var n = 1; n <= 39; n++) n: recent.length}; // 初始化為未出現
    for (var i = 0; i < recent.length; i++) {
      for (final n in recent[i].numbers) {
        if (n >= 1 && n <= 39 && lastAppearance[n] == recent.length) {
          lastAppearance[n] = i; // 記錄最近一次出現的位置（0 = 最新期）
        }
      }
    }

    // 找出冷號配對傾向 - 分析超級冷號（未開15+期）最常與哪些號一起開
    final coldNumberPairs = _findColdNumberPairs(recent, lastAppearance);

    // ── Step 1: 多期拖牌分析 Lag 1-8 (Multi-Lag Drag Pattern) ──────
    // 比單期拖牌更能捕捉中距離規律：追蹤號碼在 1-8 期後的轉移機率矩陣，
    // 並按 1/lag 遞減加權，lag=1 貢獻最大。
    final lastDrawNumbers = records.isNotEmpty ? records[0].numbers : <int>[];
    final multiLagBoost = <int, double>{for (var n = 1; n <= 39; n++) n: 0.0};
    final maxLag = min(8, records.length - 1);
    final histForLag = records.take(200).toList();

    for (var lag = 1; lag <= maxLag; lag++) {
      final fromCounts = <int, Map<int, int>>{};
      for (var i = 0; i + lag < histForLag.length; i++) {
        for (final f in histForLag[i + lag].numbers) {
          if (f < 1 || f > 39) continue;
          fromCounts.putIfAbsent(f, () => {});
          for (final t in histForLag[i].numbers) {
            if (t >= 1 && t <= 39) {
              fromCounts[f]![t] = (fromCounts[f]![t] ?? 0) + 1;
            }
          }
        }
      }
      if (lag - 1 >= records.length) continue;
      final lagWeight = 1.0 / lag;
      for (final fromNum in records[lag - 1].numbers) {
        final targets = fromCounts[fromNum] ?? {};
        final total = targets.values.fold(0, (a, b) => a + b);
        if (total == 0) continue;
        for (final entry in targets.entries) {
          final rate = entry.value / total;
          if (rate >= 0.12) { // 高於隨機基準率 5/39 ≈ 12.8% 才算有效信號
            multiLagBoost[entry.key] = (multiLagBoost[entry.key] ?? 0) +
                rate * lagWeight * 32.0;
          }
        }
      }
    }
    for (var n = 1; n <= 39; n++) {
      final boost = multiLagBoost[n] ?? 0.0;
      if (boost <= 0) continue;
      scores[n] = (scores[n] ?? 0) + boost + (lastDigitScores[n] ?? 0);
      final digit = n % 10;
      final isHotDigit = (digitStats[digit]?['heat'] ?? 0) > 0.65;
      if (isHotDigit && boost > 8.0) reasons[n]!.add('拖牌+尾數共振');
    }

    // ── Step 1.5: 連號分析 (Consecutive Pair Analysis) ───────────
    // 分析歷史開獎中「相鄰號碼」同時出現的頻率，例如 (12, 13)
    final consecutiveFreq = _analyzeConsecutivePairs(records.take(200).toList());
    final maxPairFreq = consecutiveFreq.values.fold(1, (a, b) => a > b ? a : b);
    
    for (var n = 1; n <= 38; n++) {
      final freq = consecutiveFreq[n] ?? 0;
      if (freq > 0) {
        // 基礎連號權重 (基於歷史出現次數)
        final pairBonus = (freq / maxPairFreq) * 14.0;
        
        // 連號共振效應：如果兩個相鄰號碼在「拖牌」或「尾數」分析中都已經有不錯的分數 (>45)
        // 則代表這組連號在當前趨勢下極其強勢，給予二次加成
        if ((scores[n] ?? 0) > 45 && (scores[n+1] ?? 0) > 45) {
          final synergy = pairBonus * 2.4;
          scores[n] = (scores[n] ?? 0) + synergy;
          scores[n+1] = (scores[n+1] ?? 0) + synergy;
          if (synergy > 18) {
            reasons[n]!.add('連號趨勢(${n.toString().padLeft(2, '0')},${(n+1).toString().padLeft(2, '0')})');
            reasons[n+1]!.add('連號趨勢(${n.toString().padLeft(2, '0')},${(n+1).toString().padLeft(2, '0')})');
          }
        }
      }
    }

    // ── Step 1.6: 同期共現關聯加成 ──────────────────────────────────
    // 分析過去50期，哪些號碼最常與「上期號碼」同一注出現，作為協同推薦依據
    if (lastDrawNumbers.isNotEmpty) {
      final coOccurrence = <int, int>{for (var n = 1; n <= 39; n++) n: 0};
      final coHistory = records.take(50).toList();
      for (final draw in coHistory) {
        if (!draw.numbers.any((n) => lastDrawNumbers.contains(n))) continue;
        for (final n in draw.numbers) {
          if (!lastDrawNumbers.contains(n) && n >= 1 && n <= 39) {
            coOccurrence[n] = (coOccurrence[n] ?? 0) + 1;
          }
        }
      }
      final maxCoFreq = coOccurrence.values.fold(0, (a, b) => a > b ? a : b);
      if (maxCoFreq > 0) {
        for (var n = 1; n <= 39; n++) {
          final coFreq = coOccurrence[n] ?? 0;
          if (coFreq >= 5) {
            scores[n] = (scores[n] ?? 0) + (coFreq / maxCoFreq) * 18.0;
            if (coFreq >= 8) reasons[n]!.add('高度共現關聯');
          }
        }
      }
    }

    // 1) 近期熱度（指數衰減加權：第1期×1.0，每期衰減8%）
    final freq = <int, int>{for (var n = 1; n <= 39; n++) n: 0};
    final weightedFreq = <int, double>{for (var n = 1; n <= 39; n++) n: 0.0};
    for (var i = 0; i < recent.length; i++) {
      final decay = pow(0.92, i).toDouble();
      for (final n in recent[i].numbers) {
        if (n >= 1 && n <= 39) {
          freq[n] = (freq[n] ?? 0) + 1;
          weightedFreq[n] = (weightedFreq[n] ?? 0) + decay;
        }
      }
    }
    for (var n = 1; n <= 39; n++) {
      scores[n] = (scores[n] ?? 0) + (weightedFreq[n] ?? 0.0) * 9.5;
      if ((freq[n] ?? 0) >= 6) reasons[n]!.add('近期熱號');
    }

    // 2) 遺漏期（沒開越久，小幅追補）
    final missCount = <int, int>{for (var n = 1; n <= 39; n++) n: recent.length};
    for (var i = 0; i < recent.length; i++) {
      for (final n in recent[i].numbers) {
        if (missCount[n] == recent.length) {
          missCount[n] = i;
        }
      }
    }
    for (var n = 1; n <= 39; n++) {
      final miss = missCount[n] ?? 0;
      final missBoost = (miss * 2.2).clamp(0, 24).toDouble();
      scores[n] = (scores[n] ?? 0) + missBoost;

      // ── 歷史平均間隔判斷：個化化的「到點」信號 ──────────────────
      // 每個號碼有自己的平均出現週期；超過自身均值的遺漏才算真正「到點」
      final avg = avgInterval[n] ?? 10.0;
      if (miss >= avg && avg < recent.length.toDouble()) {
        final overdue = (miss - avg).clamp(0.0, 15.0);
        scores[n] = (scores[n] ?? 0) + overdue * 4.5;
        if (overdue >= 3) reasons[n]!.add('間隔到點(+${overdue.toStringAsFixed(0)})');
      }

      // miss 1-3 只給極小加成（短暫休息，非冷號訊號）
      if (miss >= 1 && miss <= 3) {
        scores[n] = (scores[n] ?? 0) + 5.0;
      }

      if (miss >= 5) reasons[n]!.add('遺漏追補');

      // ── 超級冷號加權 ──────────────────────────────────────────
      if (miss >= 15) {
        scores[n] = (scores[n] ?? 0) + 45.0;
        reasons[n]!.add('超級冷號($miss期未開)');
        final partners = coldNumberPairs[n] ?? [];
        if (partners.isNotEmpty) {
          reasons[n]!.add('建議搭配→${partners.first.number.toString().padLeft(2, '0')}');
        }
      } else if (miss >= 10) {
        scores[n] = (scores[n] ?? 0) + 28.0;
        reasons[n]!.add('冷號($miss期未開)');
      }
    }

    // ── Step 1.7: 相生相剋（全局共現親合力）──────────────────────────
    // 相生：與目前得分前10名高度共現的號碼額外加分
    // 相剋：與前10名幾乎無共現的號碼小幅扣分
    {
      final coLimit = min(100, records.length);
      final coMatrix = <int, Map<int, int>>{};
      final rawFreqLocal = <int, int>{for (var n = 1; n <= 39; n++) n: 0};
      for (var i = 0; i < coLimit; i++) {
        final nums = records[i].numbers.where((n) => n >= 1 && n <= 39).toList();
        for (final n in nums) { rawFreqLocal[n] = rawFreqLocal[n]! + 1; }
        for (var j = 0; j < nums.length; j++) {
          for (var k = j + 1; k < nums.length; k++) {
            final a = nums[j], b = nums[k];
            coMatrix.putIfAbsent(a, () => <int, int>{})[b] =
                (coMatrix[a]![b] ?? 0) + 1;
            coMatrix.putIfAbsent(b, () => <int, int>{})[a] =
                (coMatrix[b]![a] ?? 0) + 1;
          }
        }
      }
      final seedsSorted = scores.entries.toList()
        ..sort((a, b) => b.value.compareTo(a.value));
      final seeds = seedsSorted.take(10).map((e) => e.key).toSet();
      for (var n = 1; n <= 39; n++) {
        final nFreq = rawFreqLocal[n]!.clamp(1, 999);
        double affinity = 0.0;
        int pairCount = 0;
        for (final seed in seeds) {
          final co = coMatrix[seed]?[n] ?? 0;
          if (co > 0) {
            affinity += co / sqrt(nFreq * rawFreqLocal[seed]!.clamp(1, 999));
            pairCount++;
          }
        }
        if (pairCount > 0) {
          scores[n] = (scores[n] ?? 0) + (affinity / seeds.length) * 20.0;
          if (pairCount >= 5) reasons[n]!.add('相生共振');
        } else {
          scores[n] = (scores[n] ?? 0) - 3.0; // 相剋：幾乎不與熱號同開
        }
      }
    }

    // ── Step 2.5: 奇偶與大小平衡修正 ────────────────────────────────
    // 539 每期5球中歷史均值約：奇偶各2.5顆、大號(21-39)小號(1-20)各2.5顆
    // 最近10期若嚴重偏向一方，對另一方補位號碼加成
    if (recent.length >= 5) {
      int recentOdd = 0, recentHigh = 0, total = 0;
      for (final r in recent.take(10)) {
        for (final n in r.numbers) {
          if (n >= 1 && n <= 39) {
            recentOdd += n % 2 != 0 ? 1 : 0;
            recentHigh += n >= 21 ? 1 : 0;
            total++;
          }
        }
      }
      if (total > 0) {
        final oddRatio = recentOdd / total;
        final highRatio = recentHigh / total;
        for (var n = 1; n <= 39; n++) {
          if (oddRatio > 0.60 && n % 2 == 0) {
            scores[n] = (scores[n] ?? 0) + 9.0;
            reasons[n]!.add('偶數補位');
          } else if (oddRatio < 0.40 && n % 2 != 0) {
            scores[n] = (scores[n] ?? 0) + 9.0;
            reasons[n]!.add('奇數補位');
          }
          if (highRatio > 0.60 && n < 21) {
            scores[n] = (scores[n] ?? 0) + 9.0;
            reasons[n]!.add('小號補位');
          } else if (highRatio < 0.40 && n >= 21) {
            scores[n] = (scores[n] ?? 0) + 9.0;
            reasons[n]!.add('大號補位');
          }
        }
      }
    }

    // ── Step 2.7: 和值中心修正 (Sum Center Correction) ────────────────
    // 539 每期 5 球理論平均和值 ≈ (1+39)/2 × 5 = 100
    // 近 15 期和值若持續偏高/偏低，對補位方向的號碼輕微加成（最多 8 分）
    if (recent.length >= 10) {
      final recentSums = recent.take(15).map(
        (r) => r.numbers.where((n) => n >= 1 && n <= 39).fold(0, (a, b) => a + b),
      ).toList();
      final avgSum = recentSums.fold(0, (a, b) => a + b) / recentSums.length;
      const center = 100.0;
      final dev = avgSum - center;
      if (dev > 8) {
        for (var n = 1; n <= 15; n++) {
          scores[n] = (scores[n] ?? 0) + 8.0;
          reasons[n]!.add('和值回補(偏高→小號)');
        }
      } else if (dev < -8) {
        for (var n = 25; n <= 39; n++) {
          scores[n] = (scores[n] ?? 0) + 8.0;
          reasons[n]!.add('和值回補(偏低→大號)');
        }
      }
    }

    // 3) 連莊號碼權重（最近兩期、三期）
    final latest = records.isNotEmpty ? records[0].numbers.toSet() : <int>{};
    final second = records.length > 1 ? records[1].numbers.toSet() : <int>{};
    final third = records.length > 2 ? records[2].numbers.toSet() : <int>{};
    final streak2 = latest.intersection(second);
    final streak3 = streak2.intersection(third);
    for (final n in latest) {
      scores[n] = (scores[n] ?? 0) + 7;
    }
    for (final n in streak2) {
      scores[n] = (scores[n] ?? 0) + 26;
      reasons[n]!.add('連莊觀察');
    }
    for (final n in streak3) {
      scores[n] = (scores[n] ?? 0) + 44;
      reasons[n]!.add('連三期強關注');
    }

    // 4) 紅框輸入（獨支 / 二中一 / 三中一）
    for (var i = 0; i < redHints.length; i++) {
      final n = redHints[i];
      if (n < 1 || n > 39) continue;
      final bonus = i == 0 ? 165.0 : (i <= 2 ? 105.0 : 80.0);
      scores[n] = (scores[n] ?? 0) + bonus;
      if (i == 0) reasons[n]!.add('獨支加成');
      if (i >= 1 && i <= 2) reasons[n]!.add('二中一加成');
      if (i >= 3) reasons[n]!.add('三中一加成');
    }

    // 5) 報紙額外號碼加成
    newspaperBonuses.forEach((n, b) {
      if (n < 1 || n > 39) return;
      scores[n] = (scores[n] ?? 0) + b;
      reasons[n]!.add('報紙加權');
    });

    // 6) 跨彩種微量影響（只看號碼重疊，不主導結果）
    final lottoFreq = _collectCrossGameFreq(lottoRecords, maxNum: 39);
    final powerFreq = _collectCrossGameFreq(powerRecords, maxNum: 39);
    for (var n = 1; n <= 39; n++) {
      final boost = (lottoFreq[n]! * 2.2) + (powerFreq[n]! * 1.8);
      if (boost > 0) {
        scores[n] = (scores[n] ?? 0) + boost;
      }
    }

    // 7) 乘上策略倍率（來自歷史失敗分析）
    final hotMul = strategyMultipliers['hot'] ?? 1.0;
    final missMul = strategyMultipliers['missing'] ?? 1.0;
    for (var n = 1; n <= 39; n++) {
      var s = scores[n] ?? 0;
      if ((freq[n] ?? 0) >= 5) s *= hotMul;
      if ((missCount[n] ?? 0) >= 5) s *= missMul;
      scores[n] = s;
    }

    // 8) 歷史命中強化（反饋學習）─────────────────────────────────
    // 快速回測最近 5 期：找演算法成功預測到的號碼，本期再追加獎勵
    if (records.length >= 6) {
      final rawFreqLocal = <int, int>{for (var n = 1; n <= 39; n++) n: 0};
      for (final r in records.take(50)) {
        for (final n in r.numbers.where((x) => x >= 1 && x <= 39)) {
          rawFreqLocal[n] = rawFreqLocal[n]! + 1;
        }
      }
      for (var lag = 1; lag <= min(5, records.length - 1); lag++) {
        final hist = records.sublist(lag);
        if (hist.length < 10) break;
        // 快速拖牌 + 熱度分數
        final qs = <int, double>{for (var n = 1; n <= 39; n++) n: 0.0};
        for (final n in hist[0].numbers.where((x) => x >= 1 && x <= 39)) {
          int tot = 0;
          final toC = <int, int>{};
          for (var i = 1; i < hist.length; i++) {
            if (!hist[i].numbers.contains(n)) continue;
            tot++;
            for (final t in hist[i - 1].numbers.where((x) => x >= 1 && x <= 39)) {
              toC[t] = (toC[t] ?? 0) + 1;
            }
          }
          if (tot == 0) continue;
          for (final e in toC.entries) {
            qs[e.key] = qs[e.key]! + e.value / tot;
          }
        }
        for (var n = 1; n <= 39; n++) {
          qs[n] = qs[n]! + (rawFreqLocal[n]! / 50.0) * 2.0;
        }
        final qTop = (qs.entries.toList()
              ..sort((a, b) => b.value.compareTo(a.value)))
            .take(12)
            .map((e) => e.key)
            .toSet();
        final actualSet =
            records[lag - 1].numbers.where((x) => x >= 1 && x <= 39).toSet();
        final reward = exp(-0.35 * (lag - 1)) * 12.0;
        for (final h in qTop.intersection(actualSet)) {
          scores[h] = (scores[h] ?? 0) + reward;
          if (lag == 1) reasons[h]!.add('命中強化');
        }
      }
    }

    final sorted = scores.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));
    // 排除指定號碼（如今日尾數排除），排除後再取 topN
    final eligible = excludeNumbers.isEmpty
        ? sorted
        : sorted.where((e) => !excludeNumbers.contains(e.key)).toList();
    final top = eligible.take(topN).toList();

    // ── 信心指數演算法改進：斷層掃描 ──
    // 計算 Top 5 平均分與 Top 6-10 平均分的差距
    final maxScore = top.isNotEmpty ? top.first.value : 1;
    double significanceBonus = 0.0;
    if (eligible.length > topN + 1) {
      final rank5Score = eligible[topN - 1].value;
      final rank6Score = eligible[topN].value;
      // 如果第五名與第六名有顯著分數斷層，代表這五顆號碼非常突出
      significanceBonus = (rank5Score - rank6Score) / 50.0;
    }

    return top.asMap().entries.map((e) {
      final n = e.value.key;
      final s = e.value.value;
      final consistency = _estimateConsistency(
        n: n,
        freq: freq[n] ?? 0,
        miss: missCount[n] ?? 0,
        isStreak: streak2.contains(n),
      );
      return LotteryResult(
        number: n,
        score: s,
        reason: (reasons[n] ?? const []).toSet().join('・'),
        rank: e.key + 1,
        confidence: ((s / maxScore) * 0.8 + significanceBonus).clamp(0.0, 1.0),
        mcConsistency: consistency,
      );
    }).toList();
  }

  /// 分析尾數 (Last Digit) 的分佈規律
  Map<int, Map<String, double>> _analyzeLastDigits(List<DrawRecord> history) {
    final freq = <int, int>{for (var i = 0; i <= 9; i++) i: 0};
    final lastSeen = <int, int>{for (var i = 0; i <= 9; i++) i: -1};
    
    for (var i = 0; i < history.length; i++) {
      for (final n in history[i].numbers) {
        final d = n % 10;
        freq[d] = (freq[d] ?? 0) + 1;
        if (lastSeen[d] == -1) lastSeen[d] = i;
      }
    }
    
    final maxFreq = freq.values.fold(1, (a, b) => a > b ? a : b);
    final result = <int, Map<String, double>>{};
    
    for (var i = 0; i <= 9; i++) {
      result[i] = {
        'heat': freq[i]! / maxFreq,
        'gap': (lastSeen[i] == -1 ? history.length : lastSeen[i]!).toDouble(),
      };
    }
    return result;
  }

  Map<int, double> _collectCrossGameFreq(List<DrawRecord> data, {required int maxNum}) {
    final result = <int, double>{for (var n = 1; n <= maxNum; n++) n: 0};
    final recent = data.take(30).toList();
    for (final r in recent) {
      for (final n in r.numbers) {
        if (n >= 1 && n <= maxNum) {
          result[n] = (result[n] ?? 0) + 1;
        }
      }
    }
    return result;
  }

  /// 分析歷史連號頻率
  Map<int, int> _analyzeConsecutivePairs(List<DrawRecord> history) {
    final pairFreq = <int, int>{for (var i = 1; i <= 38; i++) i: 0};
    for (final draw in history) {
      final nums = draw.numbers.toList()..sort();
      for (var i = 0; i < nums.length - 1; i++) {
        if (nums[i + 1] - nums[i] == 1) {
          pairFreq[nums[i]] = (pairFreq[nums[i]] ?? 0) + 1;
        }
      }
    }
    return pairFreq;
  }

  double _estimateConsistency({
    required int n,
    required int freq,
    required int miss,
    required bool isStreak,
  }) {
    var score = 0.35 + (freq / 12.0) + (miss >= 5 ? 0.1 : 0);
    if (isStreak) score += 0.2;
    return score.clamp(0.0, 1.0);
  }

  /// 分析超級冷號的搭配夥伴
  /// 
  /// 對於未開15+期的超級冷號，分析歷史上這些號最常與哪些號一起開，
  /// 用來預測下一次冷號開出時的可能搭配。
  /// 
  /// 返回值：Map<冷號, 列表<(搭配號, 出現次數)>>
  Map<int, List<_NumberPartner>> _findColdNumberPairs(
    List<DrawRecord> recent,
    Map<int, int> lastAppearance,
  ) {
    final result = <int, List<_NumberPartner>>{};
    
    // 找出所有超級冷號（未開15+期）
    final coldNumbers = <int>{};
    for (var n = 1; n <= 39; n++) {
      if ((lastAppearance[n] ?? recent.length) >= 15) {
        coldNumbers.add(n);
      }
    }
    
    if (coldNumbers.isEmpty) return result;
    
    // 對每個冷號，分析它在更早期間（更多歷史記錄）時常與哪些號搭配
    // 如果我們有超過 35 期的記錄，使用全量記錄；否則使用現有記錄
    final allHistoryToAnalyze = records.take(100).toList(); // 使用最多100期歷史
    
    for (final coldNum in coldNumbers) {
      final pairCounts = <int, int>{for (var n = 1; n <= 39; n++) n: 0};
      var appearanceCount = 0;
      
      // 查找冷號在歷史上開出的期次及其搭配號
      for (final draw in allHistoryToAnalyze) {
        if (draw.numbers.contains(coldNum)) {
          appearanceCount++;
          // 記錄與冷號同期開出的其他號
          for (final num in draw.numbers) {
            if (num != coldNum && num >= 1 && num <= 39) {
              pairCounts[num] = (pairCounts[num] ?? 0) + 1;
            }
          }
        }
      }
      
      // 轉換為 _NumberPartner 列表並排序
      final partners = pairCounts.entries
          .where((e) => e.value > 0)
          .map((e) => _NumberPartner(
            number: e.key,
            frequency: e.value,
            appearanceRate: appearanceCount > 0 
              ? (e.value / appearanceCount * 100).toStringAsFixed(1)
              : '0.0'
          ))
          .toList();
      
      // 按出現次數降序排列
      partners.sort((a, b) => b.frequency.compareTo(a.frequency));
      
      // 只保留出現率在30%以上的搭配夥伴（最常見的組合）
      result[coldNum] = partners
          .where((p) => double.parse(p.appearanceRate) >= 30.0)
          .take(5) // 最多顯示5個最常見的搭配
          .toList();
    }
    
    return result;
  }
}

// ══════════════════════════════════════════════════════════════
// 五星智能推薦 — 資料模型
// ══════════════════════════════════════════════════════════════

/// 一組五星號碼推薦
class FiveStarCombo {
  const FiveStarCombo({
    required this.numbers,
    required this.strategy,
    required this.rationale,
    required this.sumTotal,
    required this.oddCount,
    required this.highCount,
  });

  final List<int> numbers;   // 已排序的 5 個號碼
  final String strategy;     // 策略名稱（指令一/二/三）
  final String rationale;    // 選號理由說明
  final int sumTotal;
  final int oddCount;        // 奇數個數
  final int highCount;       // 大號（21–39）個數

  String get displayNumbers =>
      numbers.map((n) => n.toString().padLeft(2, '0')).join('  ');
  String get oddEvenLabel => '奇$oddCount偶${5 - oddCount}';
  String get bigSmallLabel => '大$highCount小${5 - highCount}';
}

/// 完整走勢分析（用於 UI 顯示）
class DetailedLotteryAnalysis {
  const DetailedLotteryAnalysis({
    required this.hotTailDigits,
    required this.coldNumbers,
    required this.oddEvenTrend,
    required this.bigSmallTrend,
    required this.recommendedCombos,
    required this.topSameTailPairs,
    required this.topConsecutivePairs,
    required this.avgSum,
    required this.recentOddRatio,
    required this.recentHighRatio,
  });

  final List<int> hotTailDigits;           // 前 2 熱門尾數
  final List<int> coldNumbers;             // 最冷 5 個號碼
  final String oddEvenTrend;               // e.g. '近期偏奇（建議加偶）'
  final String bigSmallTrend;
  final List<FiveStarCombo> recommendedCombos; // 3 組推薦
  final List<List<int>> topSameTailPairs;  // 高頻同尾對
  final List<List<int>> topConsecutivePairs; // 高頻連號對
  final double avgSum;
  final double recentOddRatio;
  final double recentHighRatio;
}

// ── generateDetailedAnalysis 擴充至 LotteryAnalyzer ────────────

extension LotteryAnalyzerExtension on LotteryAnalyzer {
  /// 執行完整分析並產生三組五星推薦組合
  DetailedLotteryAnalysis generateDetailedAnalysis({
    List<int> excludeNumbers = const [],
    List<int> redHints = const [],
  }) {
    final recent = records.take(35).toList();
    final longHistory = records.take(200).toList();

    if (recent.length < 10) {
      return const DetailedLotteryAnalysis(
        hotTailDigits: [],
        coldNumbers: [],
        oddEvenTrend: '資料不足',
        bigSmallTrend: '資料不足',
        recommendedCombos: [],
        topSameTailPairs: [],
        topConsecutivePairs: [],
        avgSum: 100,
        recentOddRatio: 0.5,
        recentHighRatio: 0.5,
      );
    }

    // ── 1. 尾數分析 ──────────────────────────────────────────────
    final digitFreq = <int, int>{for (var i = 0; i <= 9; i++) i: 0};
    for (final r in records.take(50)) {
      for (final n in r.numbers) {
        digitFreq[n % 10] = (digitFreq[n % 10] ?? 0) + 1;
      }
    }
    final sortedTails = List.generate(10, (i) => i)
      ..sort((a, b) => (digitFreq[b] ?? 0).compareTo(digitFreq[a] ?? 0));
    final hotTailDigits = sortedTails.take(2).toList();

    // ── 2. 遺漏期計算 ───────────────────────────────────────────
    final missCount = <int, int>{for (var n = 1; n <= 39; n++) n: recent.length};
    for (var i = 0; i < recent.length; i++) {
      for (final n in recent[i].numbers) {
        if (n >= 1 && n <= 39 && missCount[n] == recent.length) {
          missCount[n] = i;
        }
      }
    }
    final coldNumbers = (List.generate(39, (i) => i + 1)
          ..sort((a, b) => (missCount[b] ?? 0).compareTo(missCount[a] ?? 0)))
        .take(5)
        .toList();

    // ── 3. 奇偶 / 大小比例 ──────────────────────────────────────
    int recentOdd = 0, recentHigh = 0, totalBalls = 0;
    for (final r in recent.take(10)) {
      for (final n in r.numbers) {
        if (n >= 1 && n <= 39) {
          if (n % 2 != 0) recentOdd++;
          if (n >= 21) recentHigh++;
          totalBalls++;
        }
      }
    }
    final oddRatio = totalBalls > 0 ? recentOdd / totalBalls : 0.5;
    final highRatio = totalBalls > 0 ? recentHigh / totalBalls : 0.5;
    final oddEvenTrend = oddRatio > 0.58
        ? '近期偏奇（建議加偶）'
        : (oddRatio < 0.42 ? '近期偏偶（建議加奇）' : '奇偶均衡');
    final bigSmallTrend = highRatio > 0.58
        ? '近期偏大（建議加小）'
        : (highRatio < 0.42 ? '近期偏小（建議加大）' : '大小均衡');

    // ── 4. 連號頻率 ─────────────────────────────────────────────
    final consecutiveFreq = <int, int>{};
    for (final draw in longHistory) {
      final nums = draw.numbers.toList()..sort();
      for (var i = 0; i < nums.length - 1; i++) {
        if (nums[i + 1] - nums[i] == 1) {
          consecutiveFreq[nums[i]] = (consecutiveFreq[nums[i]] ?? 0) + 1;
        }
      }
    }
    final topConsecutivePairs = (consecutiveFreq.entries.toList()
          ..sort((a, b) => b.value.compareTo(a.value)))
        .where((e) => e.value >= 3)
        .take(5)
        .map((e) => [e.key, e.key + 1])
        .toList();

    // ── 5. 同尾對 ───────────────────────────────────────────────
    final topSameTailPairs = <List<int>>[];
    for (var digit = 1; digit <= 9; digit++) {
      final nums = List.generate(39, (i) => i + 1)
          .where((n) => n % 10 == digit)
          .toList();
      if (nums.length >= 2) topSameTailPairs.add(nums.take(2).toList());
    }

    // ── 6. 簡化評分（用於組合生成） ──────────────────────────────
    final scores = <int, double>{};
    final wFreq = <int, double>{for (var n = 1; n <= 39; n++) n: 0.0};
    for (var i = 0; i < recent.length; i++) {
      final decay = pow(0.92, i).toDouble();
      for (final n in recent[i].numbers) {
        if (n >= 1 && n <= 39) {
          wFreq[n] = (wFreq[n] ?? 0) + decay;
        }
      }
    }
    for (var n = 1; n <= 39; n++) {
      final heat = (digitFreq[n % 10] ?? 0) / (digitFreq.values.reduce(max) + 1);
      scores[n] = (wFreq[n] ?? 0) * 9.0 +
          (missCount[n] ?? 0) * 2.2 +
          heat * 22.0;
    }
    // 紅框加成
    for (var i = 0; i < redHints.length; i++) {
      final n = redHints[i];
      if (n >= 1 && n <= 39) scores[n] = (scores[n] ?? 0) + (i == 0 ? 120 : 70);
    }

    final sorted = scores.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));
    final eligible = excludeNumbers.isEmpty
        ? sorted
        : sorted.where((e) => !excludeNumbers.contains(e.key)).toList();

    // ── 平均和值 ─────────────────────────────────────────────────
    final recentSums = recent.take(15).map((r) =>
        r.numbers.where((n) => n >= 1 && n <= 39).fold(0, (a, b) => a + b));
    final avgSum = recentSums.isEmpty ? 100.0 : recentSums.reduce((a, b) => a + b) / recentSums.length;

    // ── 生成三組推薦 ────────────────────────────────────────────
    final combo1 = _buildCombo1(eligible, oddRatio, highRatio, hotTailDigits, avgSum);
    final combo2 = _buildCombo2(eligible, topConsecutivePairs, topSameTailPairs, combo1.numbers);
    final combo3 = _buildCombo3(eligible, coldNumbers, combo1.numbers, combo2.numbers, avgSum);

    return DetailedLotteryAnalysis(
      hotTailDigits: hotTailDigits,
      coldNumbers: coldNumbers,
      oddEvenTrend: oddEvenTrend,
      bigSmallTrend: bigSmallTrend,
      recommendedCombos: [combo1, combo2, combo3],
      topSameTailPairs: topSameTailPairs,
      topConsecutivePairs: topConsecutivePairs,
      avgSum: avgSum,
      recentOddRatio: oddRatio,
      recentHighRatio: highRatio,
    );
  }

  // ── 指令一：綜合機率組合 ─────────────────────────────────────
  FiveStarCombo _buildCombo1(
    List<MapEntry<int, double>> eligible,
    double oddRatio,
    double highRatio,
    List<int> hotTails,
    double avgSum,
  ) {
    final targetOdd = oddRatio > 0.58 ? 2 : (oddRatio < 0.42 ? 3 : 2);
    final targetHigh = highRatio > 0.58 ? 2 : (highRatio < 0.42 ? 3 : 2);
    final combo = <int>[];
    int oddC = 0, highC = 0;
    final reasons = <String>[];

    // 先優先選含熱門尾數的高分號碼
    for (final e in eligible) {
      if (combo.length >= 5) break;
      final n = e.key;
      if (hotTails.contains(n % 10)) {
        combo.add(n);
        if (n % 2 != 0) oddC++;
        if (n >= 21) highC++;
        reasons.add('${n.toString().padLeft(2, '0')}=${n % 10}尾熱');
      }
    }
    // 補齊至 5 個，同時修正奇偶/大小
    for (final e in eligible) {
      if (combo.length >= 5) break;
      final n = e.key;
      if (combo.contains(n)) continue;
      final wouldOdd = n % 2 != 0;
      final wouldHigh = n >= 21;
      // 偏差修正：不要讓奇偶嚴重失衡
      final curOddOk = oddC <= targetOdd + 1 || !wouldOdd;
      final curHighOk = highC <= targetHigh + 1 || !wouldHigh;
      if (curOddOk && curHighOk) {
        combo.add(n);
        if (wouldOdd) oddC++;
        if (wouldHigh) highC++;
      }
    }
    // 最終保底
    for (final e in eligible) {
      if (combo.length >= 5) break;
      if (!combo.contains(e.key)) combo.add(e.key);
    }

    combo.sort();
    final sum = combo.fold(0, (a, b) => a + b);
    final sumNote = sum < 75
        ? '和值偏低($sum)'
        : (sum > 125 ? '和值偏高($sum)' : '和值$sum（標準）');
    final tailNote = hotTails.map((d) => '$d尾').join('、');
    return FiveStarCombo(
      numbers: combo,
      strategy: '指令一：綜合機率',
      rationale: '熱門尾數$tailNote・$sumNote・$oddC奇${5 - oddC}偶',
      sumTotal: sum,
      oddCount: oddC,
      highCount: highC,
    );
  }

  // ── 指令二：尾數 + 連號組合 ─────────────────────────────────
  FiveStarCombo _buildCombo2(
    List<MapEntry<int, double>> eligible,
    List<List<int>> consecutivePairs,
    List<List<int>> sameTailPairs,
    List<int> exclude1,
  ) {
    final combo = <int>[];
    String pairNote = '';

    // 找最高分的連號對（且不在 combo1 裡）
    for (final pair in consecutivePairs) {
      if (eligible.any((e) => e.key == pair[0]) &&
          eligible.any((e) => e.key == pair[1])) {
        combo.addAll(pair);
        pairNote = '連號${pair[0].toString().padLeft(2, '0')}-${pair[1].toString().padLeft(2, '0')}';
        break;
      }
    }
    // 找最高分的同尾對
    String tailPairNote = '';
    for (final pair in sameTailPairs) {
      if (combo.contains(pair[0]) || combo.contains(pair[1])) continue;
      if (eligible.any((e) => e.key == pair[0]) &&
          eligible.any((e) => e.key == pair[1])) {
        combo.addAll(pair);
        tailPairNote = '同尾${pair[0].toString().padLeft(2, '0')}&${pair[1].toString().padLeft(2, '0')}';
        break;
      }
    }
    // 補齊
    for (final e in eligible) {
      if (combo.length >= 5) break;
      if (!combo.contains(e.key)) combo.add(e.key);
    }

    combo.sort();
    if (combo.length > 5) combo.removeRange(5, combo.length);
    final sum = combo.fold(0, (a, b) => a + b);
    final oddC = combo.where((n) => n % 2 != 0).length;
    final highC = combo.where((n) => n >= 21).length;
    final noteParts = <String>[
      if (pairNote.isNotEmpty) pairNote,
      if (tailPairNote.isNotEmpty) tailPairNote,
      '和值$sum',
      '$oddC奇${5 - oddC}偶',
    ];
    return FiveStarCombo(
      numbers: combo,
      strategy: '指令二：尾數＋連號',
      rationale: noteParts.join('・'),
      sumTotal: sum,
      oddCount: oddC,
      highCount: highC,
    );
  }

  // ── 指令三：排除冷號・和值 75–125 ────────────────────────────
  FiveStarCombo _buildCombo3(
    List<MapEntry<int, double>> eligible,
    List<int> coldNumbers,
    List<int> exclude1,
    List<int> exclude2,
    double avgSum,
  ) {
    // 移除超級冷號（未開 >= 10 期的那批），讓剩餘熱/暖號組合
    final pool = eligible
        .where((e) => !coldNumbers.contains(e.key))
        .map((e) => e.key)
        .toList();

    // 嘗試找和值 75–125 的 5 組合（前 15 個候選中排列）
    final candidates = pool.take(15).toList();
    List<int> best = [];
    int bestDiff = 9999;
    final targetSum = avgSum.round().clamp(85, 115);

    for (var a = 0; a < candidates.length; a++) {
      for (var b = a + 1; b < candidates.length; b++) {
        for (var c = b + 1; c < candidates.length; c++) {
          for (var d = c + 1; d < candidates.length; d++) {
            for (var e = d + 1; e < candidates.length; e++) {
              final s = candidates[a] + candidates[b] + candidates[c] +
                  candidates[d] + candidates[e];
              if (s < 75 || s > 125) continue;
              final diff = (s - targetSum).abs();
              if (diff < bestDiff) {
                bestDiff = diff;
                best = [
                  candidates[a], candidates[b], candidates[c],
                  candidates[d], candidates[e]
                ];
              }
            }
          }
        }
      }
    }

    if (best.isEmpty) {
      // 若沒找到滿足條件的，fallback 到評分前 5 非冷號
      best = pool.take(5).toList();
    }

    best.sort();
    final sum = best.fold(0, (a, b) => a + b);
    final coldStr = coldNumbers.take(5).map((n) => n.toString().padLeft(2, '0')).join(' ');
    final oddC = best.where((n) => n % 2 != 0).length;
    final highC = best.where((n) => n >= 21).length;
    return FiveStarCombo(
      numbers: best,
      strategy: '指令三：排除冷號',
      rationale: '已排除冷號[$coldStr]・和值$sum（目標$targetSum）・$oddC奇${5 - oddC}偶',
      sumTotal: sum,
      oddCount: oddC,
      highCount: highC,
    );
  }
}

/// 號碼搭配夥伴（用於冷號分析）
class _NumberPartner {
  final int number;
  final int frequency; // 出現次數
  final String appearanceRate; // 出現率百分比字符串
  
  _NumberPartner({
    required this.number,
    required this.frequency,
    required this.appearanceRate,
  });
  
  @override
  String toString() => '${number.toString().padLeft(2, '0')}($frequency次,$appearanceRate%)';
}

// ══════════════════════════════════════════════════════════════
// 539 數據分析師：頻率統計 + 優質組合篩選器
// ══════════════════════════════════════════════════════════════

/// 一組優質組合（已通過奇偶/尾數過濾）
class FilteredCombo {
  const FilteredCombo({
    required this.numbers,
    required this.oddCount,
    required this.evenCount,
    required this.score,
  });
  final List<int> numbers;
  final int oddCount;
  final int evenCount;
  final double score;

  String get display => numbers.map((n) => n.toString().padLeft(2, '0')).join('  ');
  String get oddEvenLabel => '奇$oddCount偶$evenCount';
  String get tailDisplay => numbers.map((n) => '${n % 10}').join('/');
}

/// 539 數據分析師結果
class Analyst539Result {
  const Analyst539Result({
    required this.hotTop10,
    required this.coldTop10,
    required this.selectedPool,
    required this.totalCombinations,
    required this.validCombinations,
    required this.topCombos,
  });

  final List<({int number, int frequency})> hotTop10;
  final List<({int number, int frequency})> coldTop10;
  final List<int> selectedPool; // 8 numbers selected for combinations
  final int totalCombinations;  // C(8,5) = 56
  final int validCombinations;  // after filter
  final List<FilteredCombo> topCombos; // top 5 best combos
}

/// 根據歷史記錄執行 Python-style 頻率分析 + 組合篩選
/// strategy: 'balanced'(熱5冷3) | 'hot'(熱6冷2) | 'cold'(熱3冷5) | 'pattern'(熱4中2冷2)
Analyst539Result compute539Analysis(List<DrawRecord> records, {String strategy = 'balanced'}) {
  final history = records.take(100).toList();
  if (history.isEmpty) {
    return const Analyst539Result(
      hotTop10: [], coldTop10: [], selectedPool: [],
      totalCombinations: 0, validCombinations: 0, topCombos: [],
    );
  }

  // ── 1. 計算每個號碼出現頻率 ──────────────────────────────────
  final freq = <int, int>{for (var n = 1; n <= 39; n++) n: 0};
  for (final r in history) {
    for (final n in r.numbers) {
      if (n >= 1 && n <= 39) freq[n] = freq[n]! + 1;
    }
  }

  // ── 2. 熱門前10 / 冷門前10 ────────────────────────────────────
  final sorted = freq.entries.toList()..sort((a, b) => b.value.compareTo(a.value));
  final hotTop10 = sorted.take(10).map((e) => (number: e.key, frequency: e.value)).toList();
  final coldTop10 = sorted.reversed.take(10).toList().map((e) => (number: e.key, frequency: e.value)).toList();

  // ── 3. 依策略選出 8 個候選號碼 ────────────────────────────────
  // balanced: 熱5+冷3 | hot: 熱6+冷2 | cold: 熱3+冷5 | pattern: 熱4+中段2+冷2
  final List<int> pool;
  switch (strategy) {
    case 'hot':
      pool = [
        ...hotTop10.take(6).map((e) => e.number),
        ...coldTop10.take(2).map((e) => e.number),
      ]..sort();
    case 'cold':
      pool = [
        ...hotTop10.take(3).map((e) => e.number),
        ...coldTop10.take(5).map((e) => e.number),
      ]..sort();
    case 'pattern':
      // 中頻段（排名 5-8，介於熱冷之間）
      final midRange = sorted.skip(4).take(4).map((e) => e.key).toList();
      pool = [
        ...hotTop10.take(4).map((e) => e.number),
        ...midRange.take(2),
        ...coldTop10.take(2).map((e) => e.number),
      ]..sort();
    default: // balanced
      pool = [
        ...hotTop10.take(5).map((e) => e.number),
        ...coldTop10.take(3).map((e) => e.number),
      ]..sort();
  }

  // ── 4. 生成所有 C(8,5) = 56 組合 ────────────────────────────
  final allCombos = _combinations(pool, 5);
  final totalCombinations = allCombos.length;

  // ── 5. 過濾：奇偶比不能 5:0 或 0:5，尾數不能全同 ───────────
  bool isValid(List<int> comb) {
    final odds = comb.where((x) => x % 2 != 0).length;
    if (odds == 0 || odds == 5) return false;
    final tails = comb.map((x) => x % 10).toSet();
    if (tails.length == 1) return false;
    return true;
  }

  final validCombos = allCombos.where(isValid).toList();

  // ── 6. 評分：熱門號碼越多分越高 ─────────────────────────────
  final hotSet = hotTop10.take(5).map((e) => e.number).toSet();
  double scoreCombo(List<int> c) {
    double sc = 0;
    for (final n in c) {
      sc += (freq[n] ?? 0).toDouble();
      if (hotSet.contains(n)) sc += 5;
    }
    // 奇偶均衡加分
    final odds = c.where((x) => x % 2 != 0).length;
    if (odds == 2 || odds == 3) sc += 3;
    return sc;
  }

  final scored = validCombos.map((c) {
    final odds = c.where((x) => x % 2 != 0).length;
    return FilteredCombo(
      numbers: c,
      oddCount: odds,
      evenCount: 5 - odds,
      score: scoreCombo(c),
    );
  }).toList()..sort((a, b) => b.score.compareTo(a.score));

  return Analyst539Result(
    hotTop10: hotTop10,
    coldTop10: coldTop10,
    selectedPool: pool,
    totalCombinations: totalCombinations,
    validCombinations: validCombos.length,
    topCombos: scored.take(5).toList(),
  );
}

/// 從 items 中取出所有長度為 r 的組合
List<List<T>> _combinations<T>(List<T> items, int r) {
  if (r == 0) return [[]];
  if (items.isEmpty || r > items.length) return [];
  final result = <List<T>>[];
  for (var i = 0; i <= items.length - r; i++) {
    for (final rest in _combinations(items.sublist(i + 1), r - 1)) {
      result.add([items[i], ...rest]);
    }
  }
  return result;
}
