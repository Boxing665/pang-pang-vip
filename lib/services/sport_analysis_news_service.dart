import 'dart:math' show min;
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import '../models/match_fixture.dart';
import '../models/sport_type.dart';

// ─── Public result type ───────────────────────────────────────────────────────

class MatchAnalysisResult {
  const MatchAnalysisResult({
    this.homeModifier = 1.0,
    this.awayModifier = 1.0,
    this.summary = '',
  });

  /// Lambda multiplier for home team (1.0 = neutral)
  final double homeModifier;

  /// Lambda multiplier for away team (1.0 = neutral)
  final double awayModifier;

  final String summary;

  static const MatchAnalysisResult neutral = MatchAnalysisResult();
}

// ─── Service ─────────────────────────────────────────────────────────────────

/// Fetches match analysis from nowscore.com (football/basketball) and
/// Yahoo Sports Taiwan (baseball), then exposes per-fixture lambda modifiers
/// for the prediction engine.
///
/// Usage pattern (mirrors SportsNewsService):
///   1. Call [prefetchForFixtures] asynchronously before predictions begin.
///   2. Call [getAnalysis] synchronously inside predictMatch().
class SportAnalysisNewsService {
  static const _cacheTtl = Duration(minutes: 45);

  // Per-fixture analysis cache
  static final Map<String, _CacheEntry> _cache = {};

  // Nowscore article index (fetched once per TTL)
  static final List<_Article> _nowscoreIndex = [];
  static DateTime? _nowscoreIndexTime;

  // Yahoo Sports Taiwan MLB article index
  static final List<_Article> _yahooIndex = [];
  static DateTime? _yahooIndexTime;

  // ── Keyword banks ─────────────────────────────────────────────────────────

  static const _posKeywords = [
    '強', '勝', '優', '佳', '穩', '壓制', '主場優勢', '狀態好', '連勝', '強攻',
    '進攻強', '狀態火熱', '保持', '高效', '主動',
  ];
  static const _negKeywords = [
    '弱', '敗', '疲', '傷', '差', '低迷', '輸球', '連敗', '缺陣', '不穩',
    '受傷', '禁賽', '退出', '傷退', '出走', '沒有狀態',
  ];

  // MLB team canonical keyword sets (Traditional Chinese + English)
  static const Map<String, List<String>> _mlbAliases = {
    '洋基': ['洋基', 'yankees', 'NYY'],
    '光芒': ['光芒', 'rays', 'TB'],
    '紅機': ['紅機', '紅絲機', 'red sox', 'BOS'],
    '藍鳥': ['藍鳥', 'blue jays', 'TOR'],
    '金鶯': ['金鶯', 'orioles', 'BAL'],
    '白機': ['白機', 'white sox', 'CWS'],
    '老虎': ['老虎', 'tigers', 'DET'],
    '皇家': ['皇家', 'royals', 'KC'],
    '雙城': ['雙城', 'twins', 'MIN'],
    '守護者': ['守護者', '印地安', 'guardians', 'CLE'],
    '太空人': ['太空人', 'astros', 'HOU'],
    '天使': ['天使', 'angels', 'LAA'],
    '水手': ['水手', 'mariners', 'SEA'],
    '運動家': ['運動家', '奧克蘭', 'athletics', 'OAK'],
    '遊騎兵': ['遊騎兵', 'rangers', 'TEX'],
    '釀酒人': ['釀酒人', 'brewers', 'MIL'],
    '紅人': ['紅人', 'reds', 'CIN'],
    '海盜': ['海盜', 'pirates', 'PIT'],
    '小熊': ['小熊', 'cubs', 'CHC'],
    '紅雀': ['紅雀', 'cardinals', 'STL'],
    '勇士': ['勇士', 'braves', 'ATL'],
    '費城人': ['費城人', 'phillies', 'PHI'],
    '大都會': ['大都會', 'mets', 'NYM'],
    '馬林魚': ['馬林魚', 'marlins', 'MIA'],
    '國民': ['國民', 'nationals', 'WSH'],
    '道奇': ['道奇', 'dodgers', 'LAD'],
    '巨人': ['巨人', 'giants', 'SF'],
    '教士': ['教士', 'padres', 'SD'],
    '響尾蛇': ['響尾蛇', 'diamondbacks', 'ARI'],
    '落磯': ['落磯', '科羅拉多', 'rockies', 'COL'],
  };

  // Football team name hints (Traditional/Simplified → English)
  static const Map<String, List<String>> _soccerAliases = {
    '巴塞隆納': ['巴塞', 'barcelona', 'barca'],
    '皇家馬德里': ['皇馬', 'real madrid', 'madrid'],
    '曼城': ['曼城', 'man city', 'manchester city'],
    '利物浦': ['利物浦', 'liverpool'],
    '阿森納': ['阿仙奴', 'arsenal'],
    '切爾西': ['切爾西', '車路士', 'chelsea'],
    '曼聯': ['曼聯', 'man utd', 'manchester united'],
    '熱刺': ['熱刺', 'tottenham', 'spurs'],
    '國際米蘭': ['國際米蘭', '國米', 'inter', 'inter milan'],
    '尤文圖斯': ['尤文', 'juventus', 'juve'],
    'AC米蘭': ['米蘭', 'ac milan', 'milan'],
    '拿坡里': ['拿坡里', '那不勒斯', 'napoli'],
    '拉齊奧': ['拉齊奧', 'lazio'],
    '羅馬': ['羅馬', 'roma', 'as roma'],
    '多特蒙德': ['多特', 'dortmund', 'bvb'],
    '拜仁': ['拜仁', 'bayern', 'munich'],
    '萊比錫': ['萊比錫', 'leipzig', 'rb leipzig'],
    '法蘭克福': ['法蘭克福', 'frankfurt'],
    '大巴黎': ['大巴黎', 'psg', 'paris saint-germain'],
    '馬賽': ['馬賽', 'marseille'],
    '里昂': ['里昂', 'lyon'],
    '本菲卡': ['本菲卡', 'benfica'],
    '波爾圖': ['波爾圖', 'porto'],
    '費內巴切': ['費內巴切', 'fenerbahce'],
    '加拉塔薩雷': ['加拉塔薩雷', 'galatasaray'],
    '費城': ['費城', 'philadelphia'],
    '浦和': ['浦和', '浦和紅鑽', 'urawa'],
    '鹿島': ['鹿島', '鹿島鹿角', 'kashima'],
    '川崎': ['川崎', '川崎前鋒', 'kawasaki'],
    '橫濱': ['橫濱', 'yokohama'],
    '町田': ['町田', '町田澤維亞', 'machida'],
  };

  // ── Public API ────────────────────────────────────────────────────────────

  /// Pre-fetch and cache analysis for all fixtures (call from background).
  static Future<void> prefetchForFixtures(List<MatchFixture> fixtures) async {
    final hasSoccer = fixtures.any(
        (f) => f.sport == SportType.football || f.sport == SportType.basketball);
    final hasBaseball =
        fixtures.any((f) => f.sport == SportType.baseball);

    // Refresh article indexes in parallel
    final indexTasks = <Future<void>>[];
    if (hasSoccer) indexTasks.add(_refreshNowscoreIndex());
    if (hasBaseball) indexTasks.add(_refreshYahooIndex());
    if (indexTasks.isNotEmpty) {
      await Future.wait(indexTasks, eagerError: false);
    }

    // Fetch per-fixture articles in parallel (max 6 concurrent)
    final pending = <Future<void>>[];
    for (final f in fixtures) {
      final key = _key(f);
      if (_cache[key] != null &&
          DateTime.now().difference(_cache[key]!.time) < _cacheTtl) {
        continue;
      }
      pending.add(_analyzeFixture(f));
      if (pending.length >= 6) {
        await Future.wait(pending, eagerError: false);
        pending.clear();
      }
    }
    if (pending.isNotEmpty) await Future.wait(pending, eagerError: false);
  }

  /// Synchronous lookup after prefetch. Returns neutral (1.0, 1.0) if not cached.
  static MatchAnalysisResult getAnalysis(MatchFixture fixture) {
    final entry = _cache[_key(fixture)];
    if (entry == null) return MatchAnalysisResult.neutral;
    if (DateTime.now().difference(entry.time) > _cacheTtl) {
      return MatchAnalysisResult.neutral;
    }
    return entry.result;
  }

  // ── Internal helpers ──────────────────────────────────────────────────────

  static String _key(MatchFixture f) {
    final date = f.startTime.toIso8601String().substring(0, 10);
    return '${f.sport.name}:${f.homeTeam}_${f.awayTeam}_$date';
  }

  // ── Article index refresh ─────────────────────────────────────────────────

  static Future<void> _refreshNowscoreIndex() async {
    if (_nowscoreIndexTime != null &&
        DateTime.now().difference(_nowscoreIndexTime!) < _cacheTtl) {
      return;
    }

    for (final url in [
      'https://www.nowscore.com/news/list.aspx',
      'https://www.nowscore.com/',
    ]) {
      try {
        final resp = await http.get(Uri.parse(url), headers: {
          'User-Agent': 'Mozilla/5.0 (compatible)',
          'Accept-Language': 'zh-TW,zh;q=0.9,en;q=0.8',
        }).timeout(const Duration(seconds: 8));
        if (resp.statusCode != 200) continue;
        final articles = _extractNowscoreLinks(resp.body);
        if (articles.isEmpty) continue;
        _nowscoreIndex
          ..clear()
          ..addAll(articles);
        _nowscoreIndexTime = DateTime.now();
        debugPrint('📊 Nowscore index: ${articles.length} articles');
        return;
      } catch (e) {
        debugPrint('⚠️ Nowscore index failed ($url): $e');
      }
    }
  }

  static List<_Article> _extractNowscoreLinks(String html) {
    final out = <_Article>[];
    // Match: href="//news.nowscore.com/NNNN.htm" or /news/NNNN.htm
    final re = RegExp(
        r'href="(?:https?:)?//(?:news\.)?nowscore\.com/news/(\d+)\.htm"[^>]*>([^<]{4,60})<');
    for (final m in re.allMatches(html)) {
      final id = m.group(1)!;
      final title = m.group(2)!.trim();
      if (title.isNotEmpty) out.add(_Article(id: id, title: title));
    }
    return out;
  }

  static Future<void> _refreshYahooIndex() async {
    if (_yahooIndexTime != null &&
        DateTime.now().difference(_yahooIndexTime!) < _cacheTtl) {
      return;
    }

    try {
      final resp = await http.get(
        Uri.parse('https://tw.sports.yahoo.com/mlb'),
        headers: {
          'User-Agent':
              'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36',
          'Accept-Language': 'zh-TW,zh;q=0.9',
        },
      ).timeout(const Duration(seconds: 8));
      if (resp.statusCode != 200) return;
      final articles = _extractYahooLinks(resp.body);
      _yahooIndex
        ..clear()
        ..addAll(articles);
      _yahooIndexTime = DateTime.now();
      debugPrint('📊 Yahoo MLB index: ${articles.length} articles');
    } catch (e) {
      debugPrint('⚠️ Yahoo MLB index failed: $e');
    }
  }

  static List<_Article> _extractYahooLinks(String html) {
    final out = <_Article>[];
    final re = RegExp(
        r'href="(https://tw\.sports\.yahoo\.com/news/[^"]{10,})"[^>]*>([^<]{4,80})<');
    for (final m in re.allMatches(html)) {
      final url = m.group(1)!;
      final title = m.group(2)!.trim();
      if (title.isNotEmpty) out.add(_Article(id: url, title: title));
    }
    return out;
  }

  // ── Per-fixture analysis ──────────────────────────────────────────────────

  static Future<void> _analyzeFixture(MatchFixture fixture) async {
    if (fixture.sport == SportType.baseball) {
      await _analyzeFromYahoo(fixture);
    } else {
      await _analyzeFromNowscore(fixture);
    }
  }

  // ── Nowscore (football / basketball) ─────────────────────────────────────

  static Future<void> _analyzeFromNowscore(MatchFixture fixture) async {
    final key = _key(fixture);
    final homeKws = _keywords(fixture.homeTeam, fixture.sport);
    final awayKws = _keywords(fixture.awayTeam, fixture.sport);

    _Article? best;
    int bestScore = 0;

    for (final article in _nowscoreIndex) {
      final t = article.title.toLowerCase();
      int score = 0;
      for (final kw in homeKws) {
        if (t.contains(kw.toLowerCase())) score += 2;
      }
      for (final kw in awayKws) {
        if (t.contains(kw.toLowerCase())) score += 2;
      }
      if (score > bestScore) {
        bestScore = score;
        best = article;
      }
    }

    if (best == null || bestScore < 2) {
      _cache[key] = _CacheEntry(MatchAnalysisResult.neutral);
      return;
    }

    try {
      final url = 'https://news.nowscore.com/${best.id}.htm';
      final resp = await http.get(Uri.parse(url), headers: {
        'User-Agent': 'Mozilla/5.0 (compatible)',
        'Accept-Language': 'zh-TW,zh;q=0.9',
      }).timeout(const Duration(seconds: 8));
      if (resp.statusCode != 200) {
        _cache[key] = _CacheEntry(MatchAnalysisResult.neutral);
        return;
      }
      final result = _parseArticle(resp.body, homeKws, awayKws);
      _cache[key] = _CacheEntry(result);
      debugPrint(
          '📊 Nowscore [${fixture.homeTeam} vs ${fixture.awayTeam}] '
          'h×${result.homeModifier.toStringAsFixed(2)} '
          'a×${result.awayModifier.toStringAsFixed(2)} "${result.summary}"');
    } catch (e) {
      debugPrint('⚠️ Nowscore article fetch failed (${best.id}): $e');
      _cache[key] = _CacheEntry(MatchAnalysisResult.neutral);
    }
  }

  // ── Yahoo Sports Taiwan (baseball) ───────────────────────────────────────

  static Future<void> _analyzeFromYahoo(MatchFixture fixture) async {
    final key = _key(fixture);
    final homeKws = _keywords(fixture.homeTeam, SportType.baseball);
    final awayKws = _keywords(fixture.awayTeam, SportType.baseball);

    _Article? best;
    int bestScore = 0;

    for (final article in _yahooIndex) {
      final t = article.title.toLowerCase();
      int score = 0;
      for (final kw in homeKws) {
        if (t.contains(kw.toLowerCase())) score++;
      }
      for (final kw in awayKws) {
        if (t.contains(kw.toLowerCase())) score++;
      }
      if (score > bestScore) {
        bestScore = score;
        best = article;
      }
    }

    if (best == null || bestScore < 1) {
      _cache[key] = _CacheEntry(MatchAnalysisResult.neutral);
      return;
    }

    try {
      final resp = await http.get(Uri.parse(best.id), headers: {
        'User-Agent':
            'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36',
        'Accept-Language': 'zh-TW,zh;q=0.9',
      }).timeout(const Duration(seconds: 8));
      if (resp.statusCode != 200) {
        _cache[key] = _CacheEntry(MatchAnalysisResult.neutral);
        return;
      }
      final result = _parseArticle(resp.body, homeKws, awayKws);
      _cache[key] = _CacheEntry(result);
      debugPrint(
          '📊 Yahoo MLB [${fixture.homeTeam} vs ${fixture.awayTeam}] '
          'h×${result.homeModifier.toStringAsFixed(2)} '
          'a×${result.awayModifier.toStringAsFixed(2)} "${result.summary}"');
    } catch (e) {
      debugPrint('⚠️ Yahoo article fetch failed: $e');
      _cache[key] = _CacheEntry(MatchAnalysisResult.neutral);
    }
  }

  // ── Article parsing ───────────────────────────────────────────────────────

  static MatchAnalysisResult _parseArticle(
      String html, List<String> homeKws, List<String> awayKws) {
    // Strip script/style blocks and HTML tags, normalize whitespace
    final text = html
        .replaceAll(RegExp(r'<script[^>]*>.*?</script>', dotAll: true), ' ')
        .replaceAll(RegExp(r'<style[^>]*>.*?</style>', dotAll: true), ' ')
        .replaceAll(RegExp(r'<[^>]+>'), ' ')
        .replaceAll(RegExp(r'&[a-z]+;'), ' ')
        .replaceAll(RegExp(r'\s+'), ' ');

    double homeMod = 1.0;
    double awayMod = 1.0;
    final notes = <String>[];

    // Sentence-level sentiment (each sentence affects whichever team it mentions)
    final sentences = text.split(RegExp(r'[。！？.!?\n]'));
    for (final raw in sentences) {
      final s = raw.trim();
      if (s.length < 4) continue;

      final mHome = homeKws.any((kw) => s.contains(kw));
      final mAway = awayKws.any((kw) => s.contains(kw));
      final pos = _posKeywords.any((kw) => s.contains(kw));
      final neg = _negKeywords.any((kw) => s.contains(kw));

      if (mHome && pos && !neg) homeMod = (homeMod + 0.03).clamp(0.85, 1.15);
      if (mHome && neg && !pos) homeMod = (homeMod - 0.03).clamp(0.85, 1.15);
      if (mAway && pos && !neg) awayMod = (awayMod + 0.03).clamp(0.85, 1.15);
      if (mAway && neg && !pos) awayMod = (awayMod - 0.03).clamp(0.85, 1.15);
    }

    // Explicit prediction keywords
    if (_containsAny(text, ['推薦主勝', '看好主隊', '主場勝', '主勝'])) {
      homeMod = (homeMod + 0.06).clamp(0.85, 1.15);
      awayMod = (awayMod - 0.02).clamp(0.85, 1.15);
      notes.add('主勝');
    } else if (_containsAny(text, ['推薦客勝', '看好客隊', '客場勝', '客勝'])) {
      awayMod = (awayMod + 0.06).clamp(0.85, 1.15);
      homeMod = (homeMod - 0.02).clamp(0.85, 1.15);
      notes.add('客勝');
    }

    // Injury / missing player signals (absolute, not team-specific)
    final injuryCount = RegExp(r'缺陣|受傷|傷退|禁賽').allMatches(text).length;
    if (injuryCount >= 2) {
      // Multiple injury mentions skew towards away team (home injuries more reported)
      homeMod = (homeMod - 0.03 * injuryCount.clamp(1, 3)).clamp(0.85, 1.15);
      notes.add('傷兵$injuryCount');
    }

    return MatchAnalysisResult(
      homeModifier: homeMod,
      awayModifier: awayMod,
      summary: notes.join(', '),
    );
  }

  static bool _containsAny(String text, List<String> keywords) =>
      keywords.any((kw) => text.contains(kw));

  // ── Keyword extraction ────────────────────────────────────────────────────

  /// Extract a set of keywords from a team name (original + aliases + sub-tokens).
  static List<String> _keywords(String teamName, SportType sport) {
    final out = <String>{};

    // Always include the original name
    out.add(teamName);

    // For baseball: check MLB alias table first
    if (sport == SportType.baseball) {
      for (final entry in _mlbAliases.entries) {
        if (entry.value.any((kw) =>
            teamName.toLowerCase().contains(kw.toLowerCase()))) {
          out.addAll(entry.value);
          break;
        }
        if (teamName.contains(entry.key)) {
          out.addAll(entry.value);
          break;
        }
      }
    }

    // For soccer: check soccer alias table
    if (sport == SportType.football || sport == SportType.basketball) {
      for (final entry in _soccerAliases.entries) {
        if (entry.value.any((kw) =>
            teamName.toLowerCase().contains(kw.toLowerCase()))) {
          out.addAll(entry.value);
          break;
        }
        if (teamName.contains(entry.key)) {
          out.addAll(entry.value);
          break;
        }
      }
    }

    // Add English word tokens (for names like "Los Angeles Dodgers")
    for (final part in teamName.split(RegExp(r'\s+'))) {
      if (part.length >= 3) out.add(part);
    }

    // Add Chinese 2-char prefix if applicable
    final cjk = RegExp(r'[一-鿿]');
    if (cjk.hasMatch(teamName) && teamName.length >= 2) {
      out.add(teamName.substring(0, min(4, teamName.length)));
    }

    return out.where((s) => s.length >= 2).toList();
  }
}

// ─── Private helpers ──────────────────────────────────────────────────────────

class _Article {
  const _Article({required this.id, required this.title});
  final String id; // article ID (nowscore) or full URL (yahoo)
  final String title;
}

class _CacheEntry {
  _CacheEntry(this.result) : time = DateTime.now();
  final MatchAnalysisResult result;
  final DateTime time;
}
