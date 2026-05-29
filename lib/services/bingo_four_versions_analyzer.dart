import 'dart:math';

/// 台灣賓果四套版本邏輯分析器
/// 
/// 每套版本都有獨特的開獎機制與動畫特徵：
/// - Version 1 (經典版): 區間均衡，對稱性強
/// - Version 2 (熱線版): 熱區聚集，動畫快速
/// - Version 3 (冷點版): 冷區復活，動畫緩慢
/// - Version 4 (亂數版): 隨機分布，動畫混亂
class BingoFourVersionsAnalyzer {
  /// 當期號碼的動畫特徵集合
  static Map<String, dynamic> analyzeCurrentAnimationFeatures(
    List<int> currentPeriodNumbers,
  ) {
    if (currentPeriodNumbers.length < 20) return {};

    final features = <String, dynamic>{};

    // 1. 區間分布特徵
    features['zoneDistribution'] = _analyzeZoneDistribution(currentPeriodNumbers);

    // 2. 動畫速度特徵
    features['animationSpeed'] = _analyzeAnimationSpeed(currentPeriodNumbers);

    // 3. 號碼集群特徵
    features['clusteringPattern'] = _analyzeClusteringPattern(currentPeriodNumbers);

    // 4. 數值波動特徵
    features['volatilityPattern'] = _analyzeVolatilityPattern(currentPeriodNumbers);

    // 5. 單雙比例特徵
    features['oddEvenRatio'] = _analyzeOddEvenRatio(currentPeriodNumbers);

    // 6. 大小比例特徵
    features['bigSmallRatio'] = _analyzeBigSmallRatio(currentPeriodNumbers);

    // 7. 首尾間距特徵
    features['rangeSpan'] = _analyzeRangeSpan(currentPeriodNumbers);

    // 8. 相鄰號碼密度特徵
    features['adjacencyDensity'] = _analyzeAdjacencyDensity(currentPeriodNumbers);

    return features;
  }

  /// 識別當期是哪一套版本邏輯
  static String identifyVersionLogic(Map<String, dynamic> features) {
    if (features.isEmpty) return 'Unknown';

    final zoneDistribution = features['zoneDistribution'] as Map<int, int>? ?? {};
    final animationSpeed = features['animationSpeed'] as String? ?? '';
    final clustering = features['clusteringPattern'] as String? ?? '';
    final volatility = features['volatilityPattern'] as double? ?? 0.0;
    final oddEvenRatio = features['oddEvenRatio'] as double? ?? 0.5;
    final adjacency = features['adjacencyDensity'] as double? ?? 0.0;

    // Version 1: 經典版 - 均衡對稱
    if (_isBalancedVersion(zoneDistribution, oddEvenRatio)) {
      return 'Version1_Classic';
    }

    // Version 2: 熱線版 - 聚集快速
    if (animationSpeed == 'fast' && clustering == 'tight') {
      return 'Version2_Hotline';
    }

    // Version 3: 冷點版 - 分散緩慢
    if (animationSpeed == 'slow' && clustering == 'scattered') {
      return 'Version3_ColdSpot';
    }

    // Version 4: 亂數版 - 隨機混亂
    if (volatility > 25.0 && adjacency < 0.2) {
      return 'Version4_Random';
    }

    return 'Version4_Random'; // 預設
  }

  /// 基於當期特徵預測下期3顆號碼
  static List<int> predictNextThreeNumbers(
    List<int> currentPeriodNumbers,
    Map<String, dynamic> features,
  ) {
    if (currentPeriodNumbers.length < 20) return [];

    final version = identifyVersionLogic(features);
    final predicted = <int>[];

    switch (version) {
      case 'Version1_Classic':
        predicted.addAll(
          _predictClassicVersion(currentPeriodNumbers, features),
        );
        break;
      case 'Version2_Hotline':
        predicted.addAll(
          _predictHotlineVersion(currentPeriodNumbers, features),
        );
        break;
      case 'Version3_ColdSpot':
        predicted.addAll(
          _predictColdSpotVersion(currentPeriodNumbers, features),
        );
        break;
      case 'Version4_Random':
        predicted.addAll(
          _predictRandomVersion(currentPeriodNumbers, features),
        );
        break;
    }

    return predicted.take(3).toList()..sort();
  }

  /// ════════════════════════════════════════════════════════════
  /// FEATURE ANALYSIS METHODS
  /// ════════════════════════════════════════════════════════════

  /// 1. 區間分布特徵（8個十位區間）
  static Map<int, int> _analyzeZoneDistribution(List<int> numbers) {
    final zones = <int, int>{};
    for (var i = 0; i < 8; i++) {
      zones[i] = 0;
    }
    for (final num in numbers) {
      final zone = (num - 1) ~/ 10;
      zones[zone] = (zones[zone] ?? 0) + 1;
    }
    return zones;
  }

  /// 2. 動畫速度特徵
  static String _analyzeAnimationSpeed(List<int> numbers) {
    final avg = numbers.fold(0, (a, b) => a + b) / numbers.length;
    final variance =
        numbers.fold(0.0, (a, b) => a + pow(b - avg, 2)) / numbers.length;
    final stdDev = sqrt(variance);

    // 標準差小 = 號碼分散均勻 = 快速刷新
    if (stdDev < 20) return 'fast';
    if (stdDev > 25) return 'slow';
    return 'medium';
  }

  /// 3. 號碼集群特徵
  static String _analyzeClusteringPattern(List<int> numbers) {
    final sorted = List<int>.from(numbers)..sort();
    final gaps = <int>[];
    for (var i = 0; i < sorted.length - 1; i++) {
      gaps.add(sorted[i + 1] - sorted[i]);
    }

    final avgGap = gaps.fold(0, (a, b) => a + b) / gaps.length;
    final gapVariance =
        gaps.fold(0.0, (a, b) => a + pow(b - avgGap, 2)) / gaps.length;

    // 間距變異小 = 緊密集群
    if (gapVariance < 5) return 'tight';
    if (gapVariance > 15) return 'scattered';
    return 'normal';
  }

  /// 4. 數值波動特徵
  static double _analyzeVolatilityPattern(List<int> numbers) {
    final avg = numbers.fold(0, (a, b) => a + b) / numbers.length;
    final variance =
        numbers.fold(0.0, (a, b) => a + pow(b - avg, 2)) / numbers.length;
    return sqrt(variance);
  }

  /// 5. 單雙比例特徵
  static double _analyzeOddEvenRatio(List<int> numbers) {
    final oddCount = numbers.where((n) => n.isOdd).length;
    return oddCount / numbers.length;
  }

  /// 6. 大小比例特徵
  static double _analyzeBigSmallRatio(List<int> numbers) {
    final bigCount = numbers.where((n) => n > 40).length;
    return bigCount / numbers.length;
  }

  /// 7. 首尾間距特徵
  static int _analyzeRangeSpan(List<int> numbers) {
    return numbers.reduce((a, b) => a > b ? a : b) -
        numbers.reduce((a, b) => a < b ? a : b);
  }

  /// 8. 相鄰號碼密度特徵
  static double _analyzeAdjacencyDensity(List<int> numbers) {
    final sorted = List<int>.from(numbers)..sort();
    var adjacentCount = 0;
    for (var i = 0; i < sorted.length - 1; i++) {
      if (sorted[i + 1] - sorted[i] == 1) {
        adjacentCount++;
      }
    }
    return adjacentCount / (numbers.length - 1);
  }

  /// ════════════════════════════════════════════════════════════
  /// VERSION-SPECIFIC PREDICTION METHODS
  /// ════════════════════════════════════════════════════════════

  /// Version 1: 經典版 - 均衡對稱
  /// 特性：區間均勻分布，號碼對稱，動畫穩定
  /// 預測策略：補全缺失區間，維持平衡
  static List<int> _predictClassicVersion(
    List<int> numbers,
    Map<String, dynamic> features,
  ) {
    final zones = features['zoneDistribution'] as Map<int, int>? ?? {};
    final zoneNums = _getNumbersByZones();
    final predicted = <int>[];

    // 找出缺失或最少的區間
    final zoneScores = <int, double>{};
    for (var z = 0; z < 8; z++) {
      zoneScores[z] = 2.5 - (zones[z] ?? 0); // 理想每區2.5個
    }

    // 從最缺的區間中選號
    final sortedZones = zoneScores.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));

    for (final entry in sortedZones.take(3)) {
      final z = entry.key;
      final zoneNumList = zoneNums[z] ?? [];
      if (zoneNumList.isNotEmpty) {
        // 選擇不在當期的號碼
        for (final num in zoneNumList) {
          if (!numbers.contains(num) && !predicted.contains(num)) {
            predicted.add(num);
            break;
          }
        }
      }
    }

    return predicted;
  }

  /// Version 2: 熱線版 - 聚集快速
  /// 特性：號碼聚集在某些區間，動畫快速
  /// 預測策略：繼續聚集，補強熱區
  static List<int> _predictHotlineVersion(
    List<int> numbers,
    Map<String, dynamic> features,
  ) {
    final zones = features['zoneDistribution'] as Map<int, int>? ?? {};
    final zoneNums = _getNumbersByZones();
    final predicted = <int>[];

    // 找出最熱的區間（球數最多）
    final hotZones = zones.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));

    // 從最熱區間中選擇相鄰號碼（延續熱勢）
    for (final zoneEntry in hotZones.take(2)) {
      final z = zoneEntry.key;
      final zoneNumList = zoneNums[z] ?? [];

      for (final num in zoneNumList) {
        if (!numbers.contains(num) && !predicted.contains(num)) {
          // 優先選擇與當期號碼相鄰的
          final isAdjacent = numbers.any((n) => (n - num).abs() == 1);
          if (isAdjacent) {
            predicted.add(num);
            break;
          }
        }
      }
    }

    // 填補不足的數量
    while (predicted.length < 3) {
      for (var n = 1; n <= 80; n++) {
        if (!numbers.contains(n) && !predicted.contains(n)) {
          predicted.add(n);
          break;
        }
      }
    }

    return predicted;
  }

  /// Version 3: 冷點版 - 分散緩慢
  /// 特性：號碼分散，缺失區多，動畫緩慢
  /// 預測策略：填補冷區，促進循環
  static List<int> _predictColdSpotVersion(
    List<int> numbers,
    Map<String, dynamic> features,
  ) {
    final zones = features['zoneDistribution'] as Map<int, int>? ?? {};
    final zoneNums = _getNumbersByZones();
    final predicted = <int>[];

    // 找出最冷的區間（球數最少或為0）
    final coldZones = zones.entries.toList()
      ..sort((a, b) => a.value.compareTo(b.value));

    // 從冷區中選號
    for (final zoneEntry in coldZones.take(3)) {
      final z = zoneEntry.key;
      final zoneNumList = zoneNums[z] ?? [];

      if (zoneNumList.isNotEmpty && predicted.length < 3) {
        for (final num in zoneNumList) {
          if (!numbers.contains(num) && !predicted.contains(num)) {
            predicted.add(num);
            break;
          }
        }
      }
    }

    return predicted;
  }

  /// Version 4: 亂數版 - 隨機混亂
  /// 特性：號碼隨機分布，動畫混亂，無明顯規律
  /// 預測策略：反向補償，尋找遺漏號碼
  static List<int> _predictRandomVersion(
    List<int> numbers,
    Map<String, dynamic> features,
  ) {
    final predicted = <int>[];
    final appearanceCount = <int, int>{};

    // 計算每個號碼在當期出現頻率（基於特徵）
    for (var n = 1; n <= 80; n++) {
      appearanceCount[n] = numbers.contains(n) ? 1 : 0;
    }

    // 選擇完全沒出現的號碼（遺漏最久的）
    final missingNumbers = <int>[];
    for (var n = 1; n <= 80; n++) {
      if (!numbers.contains(n)) {
        missingNumbers.add(n);
      }
    }

    // 隨機選擇3個遺漏號碼
    missingNumbers.shuffle();
    predicted.addAll(missingNumbers.take(3));

    return predicted;
  }

  /// ════════════════════════════════════════════════════════════
  /// HELPER METHODS
  /// ════════════════════════════════════════════════════════════

  /// 將80個號碼分組到8個區間
  static Map<int, List<int>> _getNumbersByZones() {
    return {
      0: List.generate(10, (i) => i + 1),      // 1-10
      1: List.generate(10, (i) => i + 11),     // 11-20
      2: List.generate(10, (i) => i + 21),     // 21-30
      3: List.generate(10, (i) => i + 31),     // 31-40
      4: List.generate(10, (i) => i + 41),     // 41-50
      5: List.generate(10, (i) => i + 51),     // 51-60
      6: List.generate(10, (i) => i + 61),     // 61-70
      7: List.generate(10, (i) => i + 71),     // 71-80
    };
  }

  /// 檢查是否為均衡版本
  static bool _isBalancedVersion(
    Map<int, int> zoneDistribution,
    double oddEvenRatio,
  ) {
    // 每區球數相近（2-3個）
    final counts = zoneDistribution.values.toList();
    final minCount = counts.reduce((a, b) => a < b ? a : b);
    final maxCount = counts.reduce((a, b) => a > b ? a : b);

    final isZoneBalanced = (maxCount - minCount) <= 2;
    final isOddEvenBalanced = (oddEvenRatio - 0.5).abs() < 0.15;

    return isZoneBalanced && isOddEvenBalanced;
  }
}
