import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart' show kIsWeb, debugPrint;
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import '../models/lottery_model.dart';
import '../models/lottery_fallback_data.dart';

/// 樂透數據抓取服務（Dart port of Swift LotteryFetcher）
///
/// 539 開獎資料來源（優先順序）：
///   1. GitHub raw JSON（由 GitHub Actions 每日 21:15 台灣時間自動更新）
///   2. 本機 SharedPreferences 快取
///   3. 內嵌 fallback 歷史資料
///
/// 其他彩券（大樂透/威力彩）仍從 pilio.idv.tw 抓取
class LotteryService {
  // 539 GitHub Actions 每日更新的 JSON 檔（有 CORS，無需 proxy）
  static const _url539Github =
      'https://raw.githubusercontent.com/Boxing665/pang-pang-sport/main/data/lotto539.json';

  // 原始 URL（大樂透/威力彩）
  static const _urlLottoOrigin  = 'https://www.pilio.idv.tw/ltobig/list.asp';
  static const _urlPowerOrigin  = 'https://www.pilio.idv.tw/lto/list.asp';
  static const _urlDragOrigin   = 'https://www.pilio.idv.tw/lto539/sql23.asp';
  
  bool _isLoading = false;
  String _errorMessage = '';

  static const _cacheKey539 = 'lottery_539_records_v2';

  /// 從本機快取讀取 539 開獎記錄（毫秒級，無網路）
  static Future<List<DrawRecord>> loadCached539() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_cacheKey539);
      if (raw == null || raw.isEmpty) return [];
      final list = jsonDecode(raw) as List<dynamic>;
      return list.map((e) {
        final m = e as Map<String, dynamic>;
        return DrawRecord(
          date: m['date'] as String,
          numbers: (m['numbers'] as List<dynamic>).map((n) => n as int).toList(),
        );
      }).toList();
    } catch (_) {
      return [];
    }
  }

  static Future<void> _saveCache539(List<DrawRecord> records) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final data = records.map((r) => {'date': r.date, 'numbers': r.numbers}).toList();
      await prefs.setString(_cacheKey539, jsonEncode(data));
    } catch (_) {}
  }

  bool get isLoading => _isLoading;
  String get errorMessage => _errorMessage;

  /// 在 Web 平台透過多個 CORS proxy 嘗試，回傳第一個成功的結果
  Future<String?> _fetchWithProxy(String originalUrl) async {
    if (!kIsWeb) return _fetchHtml(originalUrl);

    // 依序嘗試多個 CORS proxy，任一成功即回傳
    final proxies = [
      'https://api.allorigins.win/raw?url=${Uri.encodeComponent(originalUrl)}',
      'https://corsproxy.io/?${Uri.encodeComponent(originalUrl)}',
      'https://thingproxy.freeboard.io/fetch/$originalUrl',
    ];
    for (final url in proxies) {
      final result = await _fetchHtml(url);
      if (result != null && result.length > 200) return result;
    }
    return null;
  }

  /// 從 GitHub raw JSON 抓取 539 開獎記錄（每日 Actions 自動更新，支援 CORS）
  Future<List<DrawRecord>> _fetch539FromGithub() async {
    try {
      final resp = await http.get(
        Uri.parse(_url539Github),
        headers: {'Accept': 'application/json'},
      ).timeout(const Duration(seconds: 10));
      if (resp.statusCode != 200) return [];
      final data = jsonDecode(resp.body) as Map<String, dynamic>;
      final list = (data['records'] as List<dynamic>?) ?? [];
      final records = list.map((e) {
        final m = e as Map<String, dynamic>;
        return DrawRecord(
          date: m['date'] as String,
          numbers: (m['numbers'] as List<dynamic>).map((n) => n as int).toList(),
        );
      }).toList();
      if (records.isNotEmpty) {
        unawaited(_saveCache539(records)); // 同步寫入本機快取
        final updated = data['updated'] as String? ?? '';
        debugPrint('✅ 539 GitHub raw: ${records.length} 筆 ($updated)');
      }
      return records;
    } catch (e) {
      debugPrint('⚠️ 539 GitHub raw 失敗: $e');
      return [];
    }
  }

  /// 同時抓取三種彩券的歷史資料並執行分析
  Future<LotteryFetchResult> fetchAndAnalyze({
    List<int> redHints = const [],
    List<int> excludeNumbers = const [],
    int topN = 5,
    Map<String, double> strategyMultipliers = const {},
    Map<int, double> newspaperBonuses = const {},
  }) async {
    _isLoading = true;
    _errorMessage = '';

    final pages = [1, 2, 3, 4, 5];
    // 同時抓取（分開型別避免 Future.wait 泛型衝突）
    final github539Future = _fetch539FromGithub();
    final htmlResults = await Future.wait([
      Future.wait(pages.map((p) => _fetchWithProxy('$_urlLottoOrigin?indexpage=$p'))),
      Future.wait(pages.map((p) => _fetchWithProxy('$_urlPowerOrigin?indexpage=$p'))),
      Future.wait([_fetchWithProxy(_urlDragOrigin)]),
    ]);
    var records539 = await github539Future;

    List<DrawRecord> mergePages(List<String?> htmlPages, int maxNum) {
      final all = <DrawRecord>[];
      final seen = <String>{};
      for (final html in htmlPages) {
        if (html == null) continue;
        for (final r in _parseHtml(html, maxNum: maxNum, limit: 999)) {
          if (seen.add(r.date + r.numbers.join(','))) all.add(r);
        }
      }
      return all;
    }

    final recordsLotto = mergePages(htmlResults[0], 49);
    final recordsPower = mergePages(htmlResults[1], 38);
    final dragPatterns = _parseDragPatterns(htmlResults[2].first);

    if (records539.isNotEmpty) {
      // GitHub JSON 成功，不需額外處理
    } else {
      // GitHub 失敗 → 嘗試本機快取
      final cached = await loadCached539();
      if (cached.isNotEmpty) {
        records539 = cached;
        _errorMessage = '📲 使用本機快取資料';
      } else if (kIsWeb) {
        records539 = List<DrawRecord>.from(fallback539Records);
        _errorMessage = '📦 使用內嵌歷史資料（最後更新：05/05）';
      } else {
        _errorMessage = '539 資料載入失敗，請檢查網路連線';
      }
    }

    _isLoading = false;

    // 拖牌中「即將命中」的號碼加入 dragBonuses 提升預測分數
    final dragBonuses = <int, double>{};
    for (final p in dragPatterns) {
      if (p.isDueNext) {
        dragBonuses[p.drag] = (dragBonuses[p.drag] ?? 0) + p.hitRate * 60;
      } else if (p.currentGap >= 0 && p.currentGap == p.interval - 1 && p.hitRate >= 0.75) {
        dragBonuses[p.drag] = (dragBonuses[p.drag] ?? 0) + p.hitRate * 30;
      }
    }

    final merged = Map<int, double>.from(newspaperBonuses);
    dragBonuses.forEach((k, v) => merged[k] = (merged[k] ?? 0) + v);

    final analyzer = LotteryAnalyzer(
      records: records539,
      lottoRecords: recordsLotto,
      powerRecords: recordsPower,
      taiwanNow: _taiwanNow,
    );
    final analyzed = analyzer.analyze(
      redHints: redHints,
      excludeNumbers: excludeNumbers,
      topN: topN,
      strategyMultipliers: strategyMultipliers,
      newspaperBonuses: merged,
    );

    final detailedAnalysis = analyzer.generateDetailedAnalysis(
      excludeNumbers: excludeNumbers,
      redHints: redHints,
    );

    return LotteryFetchResult(
      records539: records539.take(10).toList(),
      recordsLotto: recordsLotto.take(10).toList(),
      recordsPower: recordsPower.take(10).toList(),
      results: analyzed,
      dragPatterns: dragPatterns,
      errorMessage: _errorMessage,
      detailedAnalysis: detailedAnalysis,
    );
  }

  // ── 拖牌解析 ──────────────────────────────────────────────────

  List<DragPattern> _parseDragPatterns(String? html) {
    if (html == null || html.isEmpty) return [];
    final patterns = <DragPattern>[];

    // 匹配每個 <tr> 區塊（含 bgcolor）
    final rowRe = RegExp(
      r'<tr[^>]*bgcolor=.?(#[0-9A-Fa-f]{6}).?[^>]*>(.*?)</tr>',
      dotAll: true, caseSensitive: false,
    );
    // 拖牌規則：開 X 後隔 N 期拖出 Y
    final ruleRe = RegExp(r'開\s*(\d+)\s*號?後隔\s*(\d+)\s*期拖出?\s*(\d+)');
    // 命中率
    final rateRe = RegExp(r'(\d+(?:\.\d+)?)\s*%');
    // 命中次數
    final countRe = RegExp(r'(\d+)\s*次');
    // 目前已隔幾期
    final gapRe = RegExp(r'目前已隔\s*(\d+)\s*期');
    // 等待 trigger 再出現
    final waitRe = RegExp(r'目前正等待');

    for (final row in rowRe.allMatches(html)) {
      final color = row.group(1)?.toUpperCase() ?? '';
      final cell = row.group(2) ?? '';
      final plain = cell.replaceAll(RegExp(r'<[^>]+>'), ' ');

      final ruleMatch = ruleRe.firstMatch(plain);
      if (ruleMatch == null) continue;

      final trigger  = int.tryParse(ruleMatch.group(1) ?? '') ?? 0;
      final interval = int.tryParse(ruleMatch.group(2) ?? '') ?? 0;
      final drag     = int.tryParse(ruleMatch.group(3) ?? '') ?? 0;
      if (trigger < 1 || trigger > 39 || drag < 1 || drag > 39 || interval < 1) continue;

      final rateMatch  = rateRe.firstMatch(plain);
      final countMatch = countRe.firstMatch(plain);
      final gapMatch   = gapRe.firstMatch(plain);
      final isWaiting  = waitRe.hasMatch(plain);

      final hitRate  = double.tryParse(rateMatch?.group(1) ?? '') ?? 0;
      final hitCount = int.tryParse(countMatch?.group(1) ?? '') ?? 0;
      final currentGap = isWaiting ? -1 : (int.tryParse(gapMatch?.group(1) ?? '') ?? -1);
      final isDueNext = color == '#FFCCCC';

      patterns.add(DragPattern(
        trigger: trigger,
        interval: interval,
        drag: drag,
        hitRate: hitRate / 100,
        hitCount: hitCount,
        currentGap: currentGap,
        isDueNext: isDueNext,
      ));
    }
    return patterns;
  }

  // ── 私有：網路抓取 ────────────────────────────────────────────

  Future<String?> _fetchHtml(String urlStr) async {
    try {
      final response = await http.get(
        Uri.parse(urlStr),
        headers: {
          'User-Agent':
              'Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X)',
        },
      ).timeout(const Duration(seconds: 20));

      if (response.statusCode != 200) return null;

      // 嘗試 Big5 → UTF-8 fallback
      // http package 自動以 latin1 or utf-8 解碼；pilio 是 Big5
      // 用 latin1 bytes 轉回字串（保留原始 bytes，讓 regex 仍可匹配 ASCII 部分）
      return response.body;
    } catch (_) {
      return null;
    }
  }

  // ── 私有：HTML 解析 ───────────────────────────────────────────

  List<DrawRecord> _parseHtml(String html, {required int maxNum, int limit = 10}) {
    final dateRe = RegExp(
      r'class="date-cell">(.*?)<\/td>',
      dotAll: true,
      caseSensitive: false,
    );
    final numRe = RegExp(
      r'class="number-cell">\s*([\d,\s&nbsp;]+?)\s*<\/td>',
      dotAll: true,
      caseSensitive: false,
    );

    final dates = dateRe.allMatches(html).map((m) => _parseDate(m.group(1) ?? '')).toList();
    final numStrs = numRe.allMatches(html).map((m) => m.group(1) ?? '').toList();

    final results = <DrawRecord>[];
    for (var i = 0; i < dates.length && i < numStrs.length; i++) {
      final nums = _parseNumbers(numStrs[i], maxNum: maxNum);
      if (nums.isEmpty) continue;
      results.add(DrawRecord(date: dates[i], numbers: nums));
    }
    return results.take(limit).toList();
  }

  String _parseDate(String raw) {
    // 只取 MM/DD 部分，避免 Big5 編碼造成的亂碼
    final match = RegExp(r'\d{2}/\d{2}').firstMatch(raw);
    return match?.group(0) ?? raw.replaceAll(RegExp(r'<[^>]+>'), '').trim();
  }

  List<int> _parseNumbers(String raw, {required int maxNum}) {
    // 先把 &nbsp; HTML 實體換成空格，再用逗號或空白分割
    final cleaned = raw
        .replaceAll('&nbsp;', ' ')
        .replaceAll(RegExp(r'<[^>]+>'), ' ');
    return cleaned
        .split(RegExp(r'[,\s\u00A0]+'))
        .map((s) => int.tryParse(s.trim()))
        .whereType<int>()
        .where((n) => n >= 1 && n <= maxNum)
        .toList();
  }

  // ── 台灣時區當前時間 ──────────────────────────────────────────

  DateTime get _taiwanNow {
    final now = DateTime.now().toUtc();
    return now.add(const Duration(hours: 8)); // UTC+8
  }
}
