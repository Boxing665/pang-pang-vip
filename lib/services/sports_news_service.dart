import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import '../models/match_fixture.dart';
import '../models/sport_type.dart';

class NewsItem {
  const NewsItem({
    required this.headline,
    this.description = '',
    required this.teamId,
    this.impact = 0.0,
  });

  final String headline;
  final String description;
  final String teamId;
  final double impact; // negative = bad for team, positive = good

  bool get isNegative => impact < -0.02;
  bool get isPositive => impact > 0.02;
}

class _CacheEntry {
  _CacheEntry(this.news, this.fetchedAt);
  final List<NewsItem> news;
  final DateTime fetchedAt;
}

/// 體育新聞服務：從 ESPN 抓取各隊最新新聞，解析傷兵/利多訊號，
/// 並輸出 Lambda 修正係數供預測引擎使用。
class SportsNewsService {
  static const _base = 'https://site.api.espn.com/apis/site/v2/sports';
  static const _cacheTtl = Duration(minutes: 30);

  static final _cache = <String, _CacheEntry>{};

  // 負面關鍵詞 (傷兵、禁賽、缺陣)
  static const _negWords = [
    'injur', ' out ', 'doubtful', 'questionable', 'suspended', 'suspension',
    'scratch', ' il ', ' dl ', 'disabled list', 'day-to-day', 'missed',
    'hamstring', 'concussion', 'fracture', 'ankle', 'knee', 'shoulder',
    '傷', '缺陣', '禁賽', '退出', '傷退', '手術', '骨折', '扭傷',
    '韌帶', '缺席', '受傷', '拉傷', '不上場', '肌肉', '傷病',
  ];

  // 正面關鍵詞 (復出、解禁)
  static const _posWords = [
    'return', 'activated', 'cleared', 'healthy', 'off il', 'off dl',
    'reinstated', 'back from',
    '復出', '歸隊', '解禁', '回歸', '復健完成', '已出院',
  ];

  // 足球聯賽 → ESPN API 路徑
  static const _soccerLeaguePaths = <String, String>{
    '英超':  'soccer/eng.1',
    '西甲':  'soccer/esp.1',
    '德甲':  'soccer/ger.1',
    '意甲':  'soccer/ita.1',
    '法甲':  'soccer/fra.1',
    '歐冠':  'soccer/UEFA.CHAMPIONS',
    '歐霸':  'soccer/UEFA.EUROPA',
    '美職聯': 'soccer/usa.1',
    '日職':  'soccer/jpn.1',
    '澳職':  'soccer/aus.1',
    '韓職':  'soccer/kor.1',
  };

  /// 批次預取所有比賽隊伍的新聞（背景執行，不阻塞 UI）
  static Future<void> prefetchForFixtures(List<MatchFixture> fixtures) async {
    final tasks = <Future<void>>[];
    final seen = <String>{};
    for (final f in fixtures) {
      // 足球：用聯賽名稱決定 ESPN 路徑；其他運動沿用 sport-level 路徑
      final soccerPath = f.sport == SportType.football
          ? _soccerLeaguePaths[f.league]
          : null;
      for (final form in [f.homeForm, f.awayForm]) {
        final teamId = form.teamId;
        if (teamId.isEmpty) continue;
        final cacheKey = '${f.league}:$teamId';
        if (seen.contains(cacheKey)) continue;
        seen.add(cacheKey);
        if (soccerPath != null) {
          tasks.add(_fetchTeamNewsWithPath(teamId, soccerPath, f.league));
        } else {
          tasks.add(fetchTeamNews(teamId, f.sport));
        }
      }
    }
    if (tasks.isEmpty) return;
    await Future.wait(tasks, eagerError: false);
  }

  /// 以指定路徑抓取球隊新聞（用於足球各聯賽）
  static Future<void> _fetchTeamNewsWithPath(
      String teamId, String sportPath, String league) async {
    final key = '$league:$teamId';
    final entry = _cache[key];
    if (entry != null &&
        DateTime.now().difference(entry.fetchedAt) < _cacheTtl) {
      return;
    }
    try {
      final url = Uri.parse('$_base/$sportPath/teams/$teamId/news?limit=6');
      final resp = await http
          .get(url, headers: {'Accept': 'application/json'})
          .timeout(const Duration(seconds: 5));
      if (resp.statusCode != 200) return;
      final data = jsonDecode(resp.body) as Map<String, dynamic>;
      final articles = (data['articles'] as List<dynamic>?) ?? [];
      final news = articles.map((a) => _parse(a as Map<String, dynamic>, teamId)).toList();
      _cache[key] = _CacheEntry(news, DateTime.now());
      debugPrint('📰 足球新聞 $teamId ($league): ${news.length} 則');
    } catch (e) {
      debugPrint('⚠️ 足球新聞失敗 ($teamId/$league): $e');
    }
  }

  /// 非同步取得某隊新聞（有快取）
  static Future<List<NewsItem>> fetchTeamNews(
      String teamId, SportType sport) async {
    final key = '${sport.name}:$teamId';
    final entry = _cache[key];
    if (entry != null &&
        DateTime.now().difference(entry.fetchedAt) < _cacheTtl) {
      return entry.news;
    }

    final sportPath = _espnPath(sport);
    if (sportPath == null) return [];

    try {
      final url = Uri.parse('$_base/$sportPath/teams/$teamId/news?limit=6');
      final resp = await http
          .get(url, headers: {'Accept': 'application/json'})
          .timeout(const Duration(seconds: 5));
      if (resp.statusCode != 200) return [];

      final data = jsonDecode(resp.body) as Map<String, dynamic>;
      final articles = (data['articles'] as List<dynamic>?) ?? [];
      final news =
          articles.map((a) => _parse(a as Map<String, dynamic>, teamId)).toList();
      _cache[key] = _CacheEntry(news, DateTime.now());
      debugPrint('📰 新聞 $teamId (${sport.name}): ${news.length} 則');
      return news;
    } catch (e) {
      debugPrint('⚠️ 新聞失敗 ($teamId): $e');
      return [];
    }
  }

  /// 同步取得快取中的新聞標題（供 UI 顯示）
  /// 先查 sport-level 快取；足球按聯賽名稱查
  static List<NewsItem> getCachedNews(String teamId, SportType sport,
      {String league = ''}) {
    if (league.isNotEmpty) {
      final leagueNews = _cache['$league:$teamId']?.news;
      if (leagueNews != null && leagueNews.isNotEmpty) return leagueNews;
    }
    return _cache['${sport.name}:$teamId']?.news ?? [];
  }

  /// 同步取得新聞 Lambda 修正係數（1.0 = 無影響）
  /// 用於在呼叫 predictScore 前乘上 homeMult / awayMult
  static double getNewsModifier(String teamId, SportType sport,
      {String league = ''}) {
    final news = getCachedNews(teamId, sport, league: league);
    if (news.isEmpty) return 1.0;
    final total = news.fold(0.0, (s, n) => s + n.impact);
    return (1.0 + total.clamp(-0.18, 0.06));
  }

  static NewsItem _parse(Map<String, dynamic> a, String teamId) {
    final headline = (a['headline'] as String? ?? '').trim();
    final desc = (a['description'] as String? ?? '').trim();
    final combined = '$headline $desc'.toLowerCase();

    final hasNeg = _negWords.any((w) => combined.contains(w));
    final hasPos = _posWords.any((w) => combined.contains(w));

    double impact = 0.0;
    if (hasNeg && !hasPos) {
      impact = -0.07;
    } else if (hasPos && !hasNeg) {
      impact = 0.04;
    }

    return NewsItem(
        headline: headline,
        description: desc,
        teamId: teamId,
        impact: impact);
  }

  static String? _espnPath(SportType sport) {
    switch (sport) {
      case SportType.basketball:
        return 'basketball/nba';
      case SportType.baseball:
        return 'baseball/mlb';
      case SportType.football:
        return null; // 足球聯賽種類多，不做 team-level news
    }
  }
}
