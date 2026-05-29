import 'dart:math';

/// ════════════════════════════════════════════════════════════════
///  台灣賓果 動畫特徵分析預測器
///  
///  核心理念：四套版本邏輯循環執行，每期只有一套在運行
///  - 第 N 期：識別出當期是四套版本中的哪一套
///  - 基於該版本的邏輯預測第 N+1 期的號碼
///  - 四個版本輪流執行（Version A → B → C → D → A）
///  
///  特性：
///  - 不依賴歷史連貫數據
///  - 每期獨立分析開獎的當期特徵
///  - 根據版本特徵精準預測 3 顆號碼
///  - 相比舊系統的 6 顆預測，精度更高
/// ════════════════════════════════════════════════════════════════

class BingoAnimationPatternPredictor {
  
  /// 四套版本的動畫特徵與號碼對應關係
  static const Map<String, VersionAnimationPattern> versionPatterns = {
    'animation_left_balance': VersionAnimationPattern(
      name: '左側平衡版',
      description: '動畫方向偏左，開獎數字呈平衡分布',
      preferredZones: [1, 3, 5, 7],        // 左側區間：1-10, 21-30, 41-50, 61-70
      oddEvenRatio: 0.5,                   // 單數佔50%
      characteristicNumbers: [
        // 這些號碼在此版本出現概率最高
        5, 15, 25, 35, 45, 55, 65, 75,      // 各區間的"5"
        8, 18, 28, 38, 48, 58, 68, 78,      // 各區間的"8"
      ],
    ),
    'animation_right_odd': VersionAnimationPattern(
      name: '右側單數版',
      description: '動畫方向偏右，偏向單數開獎',
      preferredZones: [2, 4, 6, 8],        // 右側區間：11-20, 31-40, 51-60, 71-80
      oddEvenRatio: 0.6,                   // 單數佔60%
      characteristicNumbers: [
        1, 3, 5, 7, 9, 11, 13, 15,          // 各區間的奇數
        21, 23, 25, 27, 29, 31, 33, 35,
        41, 43, 45, 47, 49, 51, 53, 55,
        61, 63, 65, 67, 69, 71, 73, 75,
      ],
    ),
    'animation_center_even': VersionAnimationPattern(
      name: '中間雙數版',
      description: '動畫在中間運行，偏向雙數開獎',
      preferredZones: [1, 2, 5, 6],        // 中間區間：1-20, 41-60
      oddEvenRatio: 0.4,                   // 雙數佔60%
      characteristicNumbers: [
        2, 4, 6, 8, 10, 12, 14, 16, 18, 20, // 各區間的偶數
        42, 44, 46, 48, 50, 52, 54, 56, 58, 60,
      ],
    ),
    'animation_random_spread': VersionAnimationPattern(
      name: '隨機分散版',
      description: '動畫隨機移動，號碼分散全區間',
      preferredZones: [3, 4, 7, 8],        // 邊界區間
      oddEvenRatio: 0.5,                   // 奇偶均衡
      characteristicNumbers: [
        // 邊界與轉角的號碼容易出現
        10, 20, 30, 40, 50, 60, 70, 80,    // 各區間末尾
        1, 11, 21, 31, 41, 51, 61, 71,     // 各區間開頭
      ],
    ),
  };

  /// ═════════════════════════════════════════════════════════════
  /// 核心預測方法：基於當期特徵預測下期3顆號碼
  /// ═════════════════════════════════════════════════════════════
  /// ═════════════════════════════════════════════════════════════
  /// 根據當期版本邏輯，預測下期最可能的 3 顆號碼
  /// 
  /// 參數：
  ///   - currentNumbers: 當期開獎號碼
  ///   - versionKey: 當期識別出的版本鑰匙
  ///                 ('animation_left_balance' / 'animation_right_odd' / 
  ///                  'animation_center_even' / 'animation_random_spread')
  /// 
  /// 返回：
  ///   - 排序後的 3 顆號碼（最可能在下期出現）
  /// 
  /// 邏輯：
  ///   1. 取得當期版本的偏好區間、奇偶比例、特徵號碼
  ///   2. 根據版本特徵計算每顆號碼的得分
  ///   3. 選出分數最高的 3 顆
  /// ═════════════════════════════════════════════════════════════
  static List<int> predictTopThreeNumbers(
    List<int> currentNumbers, {
    required String versionKey,
  }) {
    if (currentNumbers.isEmpty) return [];

    final pattern = versionPatterns[versionKey];
    if (pattern == null) return [];

    // 分析當期特徵
    final analysis = _analyzeDrawCharacteristics(currentNumbers);

    // 根據版本特徵計算預測分數
    final scoreMap = _calculatePredictionScores(analysis, pattern);

    // 選出分數最高的3顆
    final sorted = scoreMap.entries.toList()
        ..sort((a, b) => b.value.compareTo(a.value));
    
    final topThree = sorted
        .take(3)
        .map((e) => e.key)
        .toList()
        ..sort();

    return topThree;
  }

  /// ═════════════════════════════════════════════════════════════
  /// 分析當期開獎的特徵（公開方法）
  /// ═════════════════════════════════════════════════════════════

  static Map<String, dynamic> analyzeCurrentDrawCharacteristics(List<int> numbers) {
    return _analyzeDrawCharacteristics(numbers);
  }

  /// ═════════════════════════════════════════════════════════════
  /// 分析當期開獎的特徵（私有方法）
  /// ═════════════════════════════════════════════════════════════

  static Map<String, dynamic> _analyzeDrawCharacteristics(List<int> numbers) {
    // 1. 區間分布
    final zoneCount = Map<int, int>.fromIterable(
      List.generate(8, (i) => i + 1),
      value: (_) => 0,
    );
    for (final num in numbers) {
      final zone = (num - 1) ~/ 10 + 1;
      zoneCount[zone] = (zoneCount[zone] ?? 0) + 1;
    }

    // 2. 奇偶分布
    final oddCount = numbers.where((n) => n % 2 == 1).length;
    final evenCount = numbers.length - oddCount;

    // 3. 號碼和
    final sum = numbers.fold(0, (a, b) => a + b);

    // 4. 號碼範圍
    final minNum = numbers.reduce((a, b) => a < b ? a : b);
    final maxNum = numbers.reduce((a, b) => a > b ? a : b);
    final range = maxNum - minNum;

    // 5. 連號分析
    final consecutive = _findConsecutivePatterns(numbers);

    // 6. 缺失區間
    final missingZones = <int>[];
    for (int z = 1; z <= 8; z++) {
      if ((zoneCount[z] ?? 0) == 0) {
        missingZones.add(z);
      }
    }

    // 7. 集中度：號碼集中在某些區間的程度
    final concentration = zoneCount.values.reduce(max).toDouble() / numbers.length;

    return {
      'zoneCount': zoneCount,
      'oddCount': oddCount,
      'evenCount': evenCount,
      'sum': sum,
      'minNum': minNum,
      'maxNum': maxNum,
      'range': range,
      'consecutive': consecutive,
      'missingZones': missingZones,
      'concentration': concentration,
      'avgNumPerZone': numbers.length / 8.0,
    };
  }

  /// ═════════════════════════════════════════════════════════════
  /// 根據版本模式計算每個號碼的預測分數
  /// ═════════════════════════════════════════════════════════════

  static Map<int, double> _calculatePredictionScores(
    Map<String, dynamic> analysis,
    VersionAnimationPattern pattern,
  ) {
    final scores = <int, double>{};

    // 初始化所有號碼
    for (int n = 1; n <= 80; n++) {
      scores[n] = 0.0;
    }

    final zoneCount = analysis['zoneCount'] as Map<int, int>;
    final missingZones = analysis['missingZones'] as List<int>;
    final oddCount = analysis['oddCount'] as int;
    final concentration = analysis['concentration'] as double;

    // ─ 策略 1：補全缺失的區間 ─────────────────────────────────
    // 缺失的區間號碼下期更容易出現
    for (final zone in missingZones) {
      for (int n = 1; n <= 80; n++) {
        final nZone = (n - 1) ~/ 10 + 1;
        if (nZone == zone) {
          scores[n] = scores[n]! + 40.0;  // 高優先級
        }
      }
    }

    // ─ 策略 2：版本偏好區間 ────────────────────────────────────
    // 根據版本的偏好區間加分
    for (final prefZone in pattern.preferredZones) {
      for (int n = 1; n <= 80; n++) {
        final nZone = (n - 1) ~/ 10 + 1;
        if (nZone == prefZone) {
          scores[n] = scores[n]! + 25.0;
        }
      }
    }

    // ─ 策略 3：特徵號碼 ─────────────────────────────────────
    // 該版本的特徵號碼直接加分
    for (final charNum in pattern.characteristicNumbers) {
      if (charNum >= 1 && charNum <= 80) {
        scores[charNum] = scores[charNum]! + 35.0;
      }
    }

    // ─ 策略 4：奇偶調整 ───────────────────────────────────
    // 當期奇數多 → 下期可能偏雙
    // 當期雙數多 → 下期可能偏奇
    if (oddCount > 10) {
      // 本期偏奇 → 下期加分偶數
      for (int n = 1; n <= 80; n++) {
        if (n % 2 == 0) {
          scores[n] = scores[n]! + pattern.oddEvenRatio < 0.5 ? 20.0 : 5.0;
        }
      }
    } else {
      // 本期偏雙 → 下期加分奇數
      for (int n = 1; n <= 80; n++) {
        if (n % 2 == 1) {
          scores[n] = scores[n]! + pattern.oddEvenRatio >= 0.5 ? 20.0 : 5.0;
        }
      }
    }

    // ─ 策略 5：集中度補償 ──────────────────────────────────
    // 當期集中度高 → 下期號碼可能分散
    if (concentration > 0.35) {
      // 當期集中 → 下期偏好低出現區間的號碼
      for (int zone = 1; zone <= 8; zone++) {
        final count = zoneCount[zone] ?? 0;
        if (count == 0) {
          // 零出現的區間，下期加分
          for (int n = 1; n <= 80; n++) {
            final nZone = (n - 1) ~/ 10 + 1;
            if (nZone == zone) {
              scores[n] = scores[n]! + 15.0;
            }
          }
        }
      }
    }

    // ─ 策略 6：連號補全 ────────────────────────────────────
    // 補充斷開的連號
    final consecutive = analysis['consecutive'] as List<List<int>>;
    for (final seq in consecutive) {
      if (seq.length >= 2) {
        // 在連號前後尋找相鄰號碼
        final first = seq.first;
        final last = seq.last;
        if (first > 1) scores[first - 1] = scores[first - 1]! + 10.0;
        if (last < 80) scores[last + 1] = scores[last + 1]! + 10.0;
      }
    }

    return scores;
  }

  /// ═════════════════════════════════════════════════════════════
  /// 輔助方法：尋找連號模式
  /// ═════════════════════════════════════════════════════════════

  static List<List<int>> _findConsecutivePatterns(List<int> numbers) {
    final sorted = List<int>.from(numbers)..sort();
    final patterns = <List<int>>[];
    var current = <int>[];

    for (final num in sorted) {
      if (current.isEmpty) {
        current.add(num);
      } else if (num == current.last + 1) {
        current.add(num);
      } else {
        if (current.length >= 2) {
          patterns.add(List<int>.from(current));
        }
        current = [num];
      }
    }

    if (current.length >= 2) {
      patterns.add(current);
    }

    return patterns;
  }

  /// ═════════════════════════════════════════════════════════════
  /// 自動識別版本（基於當期特徵）
  /// ═════════════════════════════════════════════════════════════

  /// ═════════════════════════════════════════════════════════════
  /// 識別當期是四套版本中的哪一套
  /// 
  /// 流程：
  ///   1. 分析當期開獎號碼的特徵（區間分布、奇偶比例等）
  ///   2. 根據特徵判斷是四套版本中的哪一套
  ///   3. 返回版本鑰匙 (version key)
  /// 
  /// 使用場景：
  ///   - 每期開獎結束後，分析當期號碼
  ///   - 識別出當期動畫是哪一套版本
  ///   - 用該版本的邏輯預測下期號碼
  /// ═════════════════════════════════════════════════════════════
  static String identifyVersion(List<int> currentDrawNumbers) {
    if (currentDrawNumbers.isEmpty) return 'animation_random_spread';

    final analysis = _analyzeDrawCharacteristics(currentDrawNumbers);
    final zoneCount = analysis['zoneCount'] as Map<int, int>;
    final oddCount = analysis['oddCount'] as int;
    final concentration = (analysis['concentration'] as double).clamp(0.0, 1.0);

    // 計算左/右側的號碼數
    var leftCount = 0;  // Zone 1, 3, 5, 7
    var rightCount = 0; // Zone 2, 4, 6, 8

    for (int z = 1; z <= 8; z++) {
      final cnt = zoneCount[z] ?? 0;
      if (z == 1 || z == 3 || z == 5 || z == 7) {
        leftCount += cnt;
      } else {
        rightCount += cnt;
      }
    }

    // 判斷版本：集中度也影響版本判定
    // 高集中度表示特徵明顯，低集中度表示分散
    if (leftCount > rightCount && oddCount < 12) {
      return 'animation_left_balance';
    } else if (rightCount > leftCount && oddCount > 12) {
      return 'animation_right_odd';
    } else if (((zoneCount[1] ?? 0) + (zoneCount[2] ?? 0) > 6 ||
               (zoneCount[5] ?? 0) + (zoneCount[6] ?? 0) > 6) || concentration > 0.4) {
      return 'animation_center_even';
    } else {
      return 'animation_random_spread';
    }
  }
}

/// ════════════════════════════════════════════════════════════════
/// 版本動畫模式特徵類
/// ════════════════════════════════════════════════════════════════

class VersionAnimationPattern {
  final String name;
  final String description;
  final List<int> preferredZones;  // 1-8 的區間號碼
  final double oddEvenRatio;       // 奇數佔比
  final List<int> characteristicNumbers; // 該版本的特徵號碼

  const VersionAnimationPattern({
    required this.name,
    required this.description,
    required this.preferredZones,
    required this.oddEvenRatio,
    required this.characteristicNumbers,
  });
}
