import 'dart:math';
import 'package:flutter/material.dart';
import '../models/lottery_model.dart';
import '../services/bingo_service.dart';

// ── 顏色常數 ────────────────────────────────────────────────────
const _kBg      = Color(0xFF0A1020);
const _kBgCard  = Color(0xFF141E35);
const _kGold    = Color(0xFFFFD700);
const _kRedL    = Color(0xFFD32F2F);
const _kBlue    = Color(0xFF0D47A1);
const _kGreen   = Color(0xFF1B5E20);

// ══════════════════════════════════════════════════════════════
//  539 預測卡片
// ══════════════════════════════════════════════════════════════

class Lottery539PredictionCard extends StatelessWidget {
  const Lottery539PredictionCard({
    super.key,
    required this.data,
    required this.taiwanNow,
  });

  final LotteryFetchResult data;
  final DateTime taiwanNow;

  // ── 資料計算 ──────────────────────────────────────────────────

  List<_NS> _hotTop10(List<DrawRecord> records) {
    final freq = <int, int>{};
    for (final r in records.take(20)) {
      for (final n in r.numbers) {
        if (n >= 1 && n <= 39) freq[n] = (freq[n] ?? 0) + 1;
      }
    }
    final sorted = freq.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));
    return sorted.take(10).map((e) => _NS(e.key, e.value)).toList();
  }

  List<_NS> _coldTop10(List<DrawRecord> records) {
    final freq = <int, int>{for (var n = 1; n <= 39; n++) n: 0};
    for (final r in records.take(20)) {
      for (final n in r.numbers) {
        if (n >= 1 && n <= 39) freq[n] = freq[n]! + 1;
      }
    }
    final sorted = freq.entries.toList()
      ..sort((a, b) => a.value.compareTo(b.value));
    return sorted.take(10).map((e) => _NS(e.key, e.value)).toList();
  }

  Map<int, int> _digitDist(List<DrawRecord> records) {
    final dist = <int, int>{for (var i = 0; i <= 9; i++) i: 0};
    for (final r in records.take(20)) {
      for (final n in r.numbers) {
        dist[n % 10] = dist[n % 10]! + 1;
      }
    }
    return dist;
  }

  List<String> _trends(List<DrawRecord> records, DetailedLotteryAnalysis? a) {
    final items = <String>[];
    if (records.length >= 10) {
      final z = [0, 0, 0, 0];
      for (final r in records.take(15)) {
        for (final n in r.numbers) {
          if (n <= 10) { z[0]++; }
          else if (n <= 20) { z[1]++; }
          else if (n <= 30) { z[2]++; }
          else { z[3]++; }
        }
      }
      const lbl = ['01~10', '10~20', '20~30', '30~39'];
      items.add('${lbl[z.indexOf(z.reduce(max))]} 區間持續活躍');
    }
    if (a != null && a.topConsecutivePairs.isNotEmpty) {
      items.add('連號機率上升（常出現${a.topConsecutivePairs.length}連）');
    }
    if (a != null && a.hotTailDigits.isNotEmpty) {
      items.add('尾數偏向：${a.hotTailDigits.map((d) => '$d').join('/')}');
    }
    final highFreq = <int, int>{};
    for (final r in records.take(20)) {
      for (final n in r.numbers) {
        if (n >= 30) highFreq[n] = (highFreq[n] ?? 0) + 1;
      }
    }
    final avgHigh = highFreq.isEmpty
        ? 0.0
        : highFreq.values.fold(0, (a, b) => a + b) / highFreq.length;
    if (avgHigh < 1.5) items.add('30以上有機會插1碼');
    return items.take(4).toList();
  }

  @override
  Widget build(BuildContext context) {
    final records = data.records539;
    if (records.isEmpty) return const SizedBox.shrink();
    final analysis = data.detailedAnalysis;
    final hot    = _hotTop10(records);
    final cold   = _coldTop10(records);
    final digits = _digitDist(records);
    final trends = _trends(records, analysis);
    final top5   = data.results.map((r) => r.number).toList();
    final nextDate = taiwanNow.add(const Duration(days: 1));
    final todayStr = '${taiwanNow.month}/${taiwanNow.day.toString().padLeft(2,'0')}';
    final nextStr  = '${nextDate.month}/${nextDate.day.toString().padLeft(2,'0')}';
    final latestDate = records.isNotEmpty ? records[0].date : '';

    return Container(
      decoration: BoxDecoration(
        color: _kBg,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: _kGold.withAlpha(60)),
      ),
      clipBehavior: Clip.hardEdge,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _buildHeader(todayStr, nextStr, latestDate),
          _buildDataSection(records, hot, cold, digits),
          _buildTrendBar(trends),
          const SizedBox(height: 12),
          _buildTop5Section(top5),
          _buildTips(),
          const SizedBox(height: 12),
        ],
      ),
    );
  }

  // ── Header ──────────────────────────────────────────────────────

  Widget _buildHeader(String today, String next, String latestDate) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          colors: [Color(0xFF1A0A2E), Color(0xFF0D1421)],
          begin: Alignment.topLeft, end: Alignment.bottomRight,
        ),
      ),
      child: Row(children: [
        Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
              decoration: BoxDecoration(color: _kGold, borderRadius: BorderRadius.circular(4)),
              child: const Text('胖胖', style: TextStyle(color: Colors.black, fontWeight: FontWeight.w900, fontSize: 11)),
            ),
            const SizedBox(width: 4),
            const Text('體育', style: TextStyle(color: Colors.white70, fontSize: 11, fontWeight: FontWeight.w600)),
          ]),
        ]),
        const SizedBox(width: 10),
        Expanded(
          child: ShaderMask(
            shaderCallback: (b) => const LinearGradient(
              colors: [Color(0xFFFFD700), Color(0xFFFF9800)],
            ).createShader(b),
            child: Text(
              '$today 539預測更新',
              style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w900, color: Colors.white, letterSpacing: 0.5),
              textAlign: TextAlign.center,
            ),
          ),
        ),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
          decoration: BoxDecoration(
            color: _kRedL.withAlpha(200),
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: _kGold.withAlpha(80)),
          ),
          child: Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
            Text('最新：$latestDate 開獎後', style: const TextStyle(color: Colors.white, fontSize: 9, fontWeight: FontWeight.w600)),
            Text('立即修正明日($next)預測', style: const TextStyle(color: _kGold, fontSize: 9, fontWeight: FontWeight.w600)),
          ]),
        ),
      ]),
    );
  }

  // ── Data Grid ───────────────────────────────────────────────────

  Widget _buildDataSection(List<DrawRecord> records, List<_NS> hot, List<_NS> cold, Map<int, int> digits) {
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      padding: const EdgeInsets.all(10),
      child: IntrinsicHeight(
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _drawHistoryCol(records),
            const SizedBox(width: 8),
            _hotCol(hot),
            const SizedBox(width: 8),
            _coldCol(cold),
            const SizedBox(width: 8),
            _digitCol(digits),
          ],
        ),
      ),
    );
  }

  Widget _colBox({required String title, required Color titleBg, required Widget child}) {
    return Container(
      width: 132,
      decoration: BoxDecoration(
        color: _kBgCard,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: Colors.white12),
      ),
      child: Column(children: [
        Container(
          width: double.infinity,
          padding: const EdgeInsets.symmetric(vertical: 5),
          decoration: BoxDecoration(color: titleBg, borderRadius: const BorderRadius.vertical(top: Radius.circular(10))),
          alignment: Alignment.center,
          child: Text(title, style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w800, fontSize: 10)),
        ),
        Padding(padding: const EdgeInsets.all(7), child: child),
      ]),
    );
  }

  Widget _drawHistoryCol(List<DrawRecord> records) {
    final recent = records.take(8).toList();
    return _colBox(
      title: '最新開獎（前8期）',
      titleBg: const Color(0xFF8B0000),
      child: Column(
        children: recent.asMap().entries.map((e) {
          final r = e.value;
          final isLatest = e.key == 0;
          return Padding(
            padding: const EdgeInsets.only(bottom: 3),
            child: Row(children: [
              SizedBox(
                width: 32,
                child: Text(r.date, style: TextStyle(
                  color: isLatest ? _kGold : Colors.white60, fontSize: 9,
                  fontWeight: isLatest ? FontWeight.w700 : FontWeight.normal,
                )),
              ),
              Expanded(
                child: Text(
                  r.numbers.map((n) => n.toString().padLeft(2,'0')).join(' '),
                  style: TextStyle(
                    color: isLatest ? _kGold : Colors.white70, fontSize: 8.5,
                    fontWeight: isLatest ? FontWeight.w700 : FontWeight.normal,
                    letterSpacing: 0.2,
                  ),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ]),
          );
        }).toList(),
      ),
    );
  }

  Widget _hotCol(List<_NS> hot) {
    return _colBox(
      title: '熱號 TOP 10',
      titleBg: const Color(0xFFB71C1C),
      child: Column(
        children: hot.asMap().entries.map((e) {
          return Padding(
            padding: const EdgeInsets.only(bottom: 2.5),
            child: Row(children: [
              SizedBox(width: 14, child: Text('${e.key+1}', style: const TextStyle(color: Colors.white38, fontSize: 9))),
              Container(
                width: 26, alignment: Alignment.center,
                padding: const EdgeInsets.symmetric(vertical: 1),
                decoration: BoxDecoration(color: _kRedL.withAlpha(180), borderRadius: BorderRadius.circular(4)),
                child: Text(e.value.n.toString().padLeft(2,'0'), style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w800, fontSize: 10)),
              ),
              const SizedBox(width: 4),
              Expanded(child: Text('出現${e.value.count}次', style: const TextStyle(color: Colors.white54, fontSize: 8.5))),
            ]),
          );
        }).toList(),
      ),
    );
  }

  Widget _coldCol(List<_NS> cold) {
    return _colBox(
      title: '冷號 TOP 10',
      titleBg: const Color(0xFF1A237E),
      child: Column(
        children: cold.asMap().entries.map((e) {
          return Padding(
            padding: const EdgeInsets.only(bottom: 2.5),
            child: Row(children: [
              Container(
                width: 26, alignment: Alignment.center,
                padding: const EdgeInsets.symmetric(vertical: 1),
                decoration: BoxDecoration(color: _kBlue.withAlpha(160), borderRadius: BorderRadius.circular(4)),
                child: Text(e.value.n.toString().padLeft(2,'0'), style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w800, fontSize: 10)),
              ),
              const SizedBox(width: 4),
              Expanded(child: Text('目前${e.value.count}次', style: const TextStyle(color: Colors.white54, fontSize: 8.5))),
            ]),
          );
        }).toList(),
      ),
    );
  }

  Widget _digitCol(Map<int, int> dist) {
    final maxVal = dist.values.fold(0, (a, b) => a > b ? a : b);
    return _colBox(
      title: '尾數分佈',
      titleBg: const Color(0xFF1B5E20),
      child: Column(
        children: List.generate(10, (d) {
          final cnt = dist[d] ?? 0;
          final isHot = cnt == maxVal && maxVal > 0;
          return Padding(
            padding: const EdgeInsets.only(bottom: 2.5),
            child: Row(children: [
              SizedBox(width: 28, child: Text('尾$d：', style: const TextStyle(color: Colors.white54, fontSize: 9))),
              Expanded(child: Text('$cnt次', style: TextStyle(
                color: isHot ? _kGold : Colors.white70, fontSize: 9,
                fontWeight: isHot ? FontWeight.w800 : FontWeight.normal,
              ))),
              if (isHot) const Text('★', style: TextStyle(color: _kGold, fontSize: 8)),
            ]),
          );
        }),
      ),
    );
  }

  // ── Trend Bar ───────────────────────────────────────────────────

  Widget _buildTrendBar(List<String> trends) {
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 10),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: _kGreen.withAlpha(200),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: Colors.greenAccent.withAlpha(60)),
      ),
      child: Row(children: [
        const Icon(Icons.track_changes_rounded, color: Colors.greenAccent, size: 16),
        const SizedBox(width: 6),
        const Text('趨勢總結', style: TextStyle(color: Colors.greenAccent, fontWeight: FontWeight.w800, fontSize: 12)),
        const SizedBox(width: 8),
        Expanded(
          child: SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              children: trends.map((t) => Padding(
                padding: const EdgeInsets.only(right: 10),
                child: Row(children: [
                  const Icon(Icons.check_circle_outline, color: Colors.greenAccent, size: 12),
                  const SizedBox(width: 3),
                  Text(t, style: const TextStyle(color: Colors.white, fontSize: 10, fontWeight: FontWeight.w600)),
                ]),
              )).toList(),
            ),
          ),
        ),
      ]),
    );
  }

  // ── 胖胖最強5碼 ─────────────────────────────────────────────────

  Widget _buildTop5Section(List<int> top5) {
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 10),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          colors: [Color(0xFF1A1400), Color(0xFF0A0A00)],
          begin: Alignment.topCenter, end: Alignment.bottomCenter,
        ),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: _kGold.withAlpha(120), width: 1.5),
      ),
      child: Column(children: [
        Row(children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
            decoration: BoxDecoration(color: _kGold, borderRadius: BorderRadius.circular(6)),
            child: const Text('胖胖最強5碼', style: TextStyle(color: Colors.black, fontWeight: FontWeight.w900, fontSize: 13)),
          ),
        ]),
        const SizedBox(height: 10),
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceEvenly,
          children: top5.isEmpty
              ? [const Text('載入中…', style: TextStyle(color: Colors.white38))]
              : top5.map((n) => _NumBallGold(n: n)).toList(),
        ),
        const SizedBox(height: 8),
        Text(
          '配置邏輯：核心熱號＋連動補強＋冷號突破，攻守兼備',
          style: TextStyle(color: _kGold.withAlpha(160), fontSize: 9, fontStyle: FontStyle.italic),
          textAlign: TextAlign.center,
        ),
      ]),
    );
  }

  Widget _buildTips() {
    const tips = ['這5碼可以直接全壓', '或拆成：3碼主攻 + 2碼機動', '想更穩 → 搭配熱力圖冷號回補'];
    return Container(
      margin: const EdgeInsets.fromLTRB(10, 10, 10, 0),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: Colors.white.withAlpha(8),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: Colors.white12),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        const Text('操作建議', style: TextStyle(color: _kGold, fontWeight: FontWeight.w700, fontSize: 12)),
        const SizedBox(height: 6),
        ...tips.map((t) => Padding(
          padding: const EdgeInsets.only(bottom: 3),
          child: Row(children: [
            const Icon(Icons.play_arrow_rounded, color: _kGold, size: 14),
            const SizedBox(width: 4),
            Expanded(child: Text(t, style: const TextStyle(color: Colors.white70, fontSize: 11))),
          ]),
        )),
      ]),
    );
  }
}

// ══════════════════════════════════════════════════════════════
//  賓果賓果預測卡片
// ══════════════════════════════════════════════════════════════

const _kCyan = Color(0xFF00E5FF);

class BingoPredictionCard extends StatelessWidget {
  const BingoPredictionCard({
    super.key,
    required this.records,
    required this.pred,
  });

  final List<BingoRecord> records;
  final BingoPrediction pred;

  List<_NS> _hotTop10() => pred.hotNumbers.take(10)
      .map((n) => _NS(n, pred.stats[n]?.frequency ?? 0))
      .toList();

  List<_NS> _coldTop10() => pred.coldNumbers.take(10)
      .map((n) => _NS(n, pred.stats[n]?.gap ?? 0))
      .toList();

  Map<String, int> _sectionDist() {
    final dist = {'01~20': 0, '21~40': 0, '41~60': 0, '61~80': 0};
    for (final r in records.take(10)) {
      for (final n in r.numbers) {
        if (n <= 20) {
          dist['01~20'] = dist['01~20']! + 1;
        } else if (n <= 40) {
          dist['21~40'] = dist['21~40']! + 1;
        } else if (n <= 60) {
          dist['41~60'] = dist['41~60']! + 1;
        } else {
          dist['61~80'] = dist['61~80']! + 1;
        }
      }
    }
    return dist;
  }

  List<String> _trends() {
    final items = <String>[];
    final zones = [0, 0, 0, 0];
    for (final n in pred.hotNumbers.take(10)) {
      if (n <= 20) { zones[0]++; }
      else if (n <= 40) { zones[1]++; }
      else if (n <= 60) { zones[2]++; }
      else { zones[3]++; }
    }
    const zLabels = ['01~20', '21~40', '41~60', '61~80'];
    items.add('${zLabels[zones.indexOf(zones.reduce(max))]} 熱號集中');
    final bigGap = pred.coldNumbers.take(5)
        .where((n) => (pred.stats[n]?.gap ?? 0) > 8).length;
    if (bigGap >= 3) items.add('多顆冷號遺漏即將補開');
    if (pred.carryOverConfidence > 0.55) {
      items.add('連莊訊號：信心${(pred.carryOverConfidence * 100).toStringAsFixed(0)}%');
    }
    items.add('熱號連帶關係強');
    return items.take(4).toList();
  }

  @override
  Widget build(BuildContext context) {
    if (records.isEmpty) return const SizedBox.shrink();
    final hot    = _hotTop10();
    final cold   = _coldTop10();
    final dist   = _sectionDist();
    final trends = _trends();
    final topRec = pred.recommended.take(6).toList();
    final latest = records.first;

    return Container(
      decoration: BoxDecoration(
        color: _kBg,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: _kCyan.withAlpha(60)),
      ),
      clipBehavior: Clip.hardEdge,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _buildBingoHeader(latest),
          _buildBingoDataSection(records, hot, cold, dist),
          _buildBingoTrendBar(trends),
          const SizedBox(height: 12),
          _buildBingoTopSection(topRec),
          _buildBingoTips(),
          const SizedBox(height: 12),
        ],
      ),
    );
  }

  Widget _buildBingoHeader(BingoRecord latest) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          colors: [Color(0xFF001433), Color(0xFF000D24)],
          begin: Alignment.topLeft, end: Alignment.bottomRight,
        ),
      ),
      child: Row(children: [
        Row(children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
            decoration: BoxDecoration(color: _kCyan, borderRadius: BorderRadius.circular(4)),
            child: const Text('胖胖', style: TextStyle(color: Colors.black, fontWeight: FontWeight.w900, fontSize: 11)),
          ),
          const SizedBox(width: 4),
          const Text('體育', style: TextStyle(color: Colors.white70, fontSize: 11, fontWeight: FontWeight.w600)),
        ]),
        const SizedBox(width: 10),
        Expanded(
          child: ShaderMask(
            shaderCallback: (b) => const LinearGradient(
              colors: [_kCyan, Color(0xFF40C4FF)],
            ).createShader(b),
            child: Text(
              '賓果賓果 第${pred.nextDrawNo}期預測',
              style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w900, color: Colors.white),
              textAlign: TextAlign.center,
            ),
          ),
        ),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
          decoration: BoxDecoration(
            color: const Color(0xFF002855),
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: _kCyan.withAlpha(80)),
          ),
          child: Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
            Text('最新：第${latest.drawNo}期 ${latest.drawTime}',
                style: const TextStyle(color: Colors.white70, fontSize: 9, fontWeight: FontWeight.w600)),
            const Text('下一期分析更新中',
                style: TextStyle(color: _kCyan, fontSize: 9, fontWeight: FontWeight.w600)),
          ]),
        ),
      ]),
    );
  }

  Widget _buildBingoDataSection(List<BingoRecord> records, List<_NS> hot, List<_NS> cold, Map<String, int> dist) {
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      padding: const EdgeInsets.all(10),
      child: IntrinsicHeight(
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _bingoDrawCol(records),
            const SizedBox(width: 8),
            _bingoHotCol(hot),
            const SizedBox(width: 8),
            _bingoColdCol(cold),
            const SizedBox(width: 8),
            _bingoSectionCol(dist),
          ],
        ),
      ),
    );
  }

  Widget _bingoColBox({required String title, required Color titleBg, required Widget child}) {
    return Container(
      width: 132,
      decoration: BoxDecoration(
        color: _kBgCard,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: Colors.white12),
      ),
      child: Column(children: [
        Container(
          width: double.infinity,
          padding: const EdgeInsets.symmetric(vertical: 5),
          decoration: BoxDecoration(color: titleBg, borderRadius: const BorderRadius.vertical(top: Radius.circular(10))),
          alignment: Alignment.center,
          child: Text(title, style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w800, fontSize: 10)),
        ),
        Padding(padding: const EdgeInsets.all(7), child: child),
      ]),
    );
  }

  Widget _bingoDrawCol(List<BingoRecord> records) {
    final recent = records.take(5).toList();
    return _bingoColBox(
      title: '最新開獎（前5局）',
      titleBg: const Color(0xFF00695C),
      child: Column(
        children: recent.asMap().entries.map((e) {
          final r = e.value;
          final isLatest = e.key == 0;
          final shown = r.numbers.take(10).map((n) => n.toString().padLeft(2,'0')).join(' ');
          return Padding(
            padding: const EdgeInsets.only(bottom: 4),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(r.drawTime, style: TextStyle(
                color: isLatest ? _kGold : Colors.white54, fontSize: 8,
                fontWeight: isLatest ? FontWeight.w700 : FontWeight.normal,
              )),
              Text('$shown…', style: TextStyle(
                color: isLatest ? Colors.white : Colors.white60, fontSize: 8, letterSpacing: 0.2,
              )),
            ]),
          );
        }).toList(),
      ),
    );
  }

  Widget _bingoHotCol(List<_NS> hot) {
    return _bingoColBox(
      title: '熱號 TOP 10',
      titleBg: const Color(0xFFB71C1C),
      child: Column(
        children: hot.asMap().entries.map((e) {
          return Padding(
            padding: const EdgeInsets.only(bottom: 2.5),
            child: Row(children: [
              SizedBox(width: 14, child: Text('${e.key+1}', style: const TextStyle(color: Colors.white38, fontSize: 9))),
              Container(
                width: 26, alignment: Alignment.center,
                padding: const EdgeInsets.symmetric(vertical: 1),
                decoration: BoxDecoration(color: _kRedL.withAlpha(200), borderRadius: BorderRadius.circular(4)),
                child: Text(e.value.n.toString().padLeft(2,'0'), style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w800, fontSize: 10)),
              ),
              const SizedBox(width: 4),
              Expanded(child: Text('${e.value.count}次', style: const TextStyle(color: Colors.white54, fontSize: 8.5))),
            ]),
          );
        }).toList(),
      ),
    );
  }

  Widget _bingoColdCol(List<_NS> cold) {
    return _bingoColBox(
      title: '冷號 TOP 10',
      titleBg: const Color(0xFF1A237E),
      child: Column(
        children: cold.asMap().entries.map((e) {
          return Padding(
            padding: const EdgeInsets.only(bottom: 2.5),
            child: Row(children: [
              Container(
                width: 26, alignment: Alignment.center,
                padding: const EdgeInsets.symmetric(vertical: 1),
                decoration: BoxDecoration(color: _kBlue.withAlpha(160), borderRadius: BorderRadius.circular(4)),
                child: Text(e.value.n.toString().padLeft(2,'0'), style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w800, fontSize: 10)),
              ),
              const SizedBox(width: 4),
              Expanded(child: Text('遺漏${e.value.count}局', style: const TextStyle(color: Colors.white54, fontSize: 8.5))),
            ]),
          );
        }).toList(),
      ),
    );
  }

  Widget _bingoSectionCol(Map<String, int> dist) {
    final maxVal = dist.values.fold(0, (a, b) => a > b ? a : b);
    return _bingoColBox(
      title: '段位分佈',
      titleBg: const Color(0xFF1B5E20),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
        children: dist.entries.map((e) {
          final isHot = e.value == maxVal && maxVal > 0;
          return Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(e.key, style: const TextStyle(color: Colors.white54, fontSize: 9)),
              const SizedBox(height: 2),
              Row(children: [
                Expanded(
                  child: LinearProgressIndicator(
                    value: maxVal > 0 ? e.value / maxVal : 0,
                    backgroundColor: Colors.white12,
                    valueColor: AlwaysStoppedAnimation(isHot ? _kGold : _kCyan),
                    minHeight: 4,
                  ),
                ),
                const SizedBox(width: 4),
                Text('${e.value}', style: TextStyle(
                  color: isHot ? _kGold : Colors.white70, fontSize: 9,
                  fontWeight: isHot ? FontWeight.w700 : FontWeight.normal,
                )),
              ]),
            ]),
          );
        }).toList(),
      ),
    );
  }

  Widget _buildBingoTrendBar(List<String> trends) {
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 10),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: const Color(0xFF004D40),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: _kCyan.withAlpha(60)),
      ),
      child: Row(children: [
        const Icon(Icons.analytics_outlined, color: _kCyan, size: 16),
        const SizedBox(width: 6),
        const Text('趨勢總結', style: TextStyle(color: _kCyan, fontWeight: FontWeight.w800, fontSize: 12)),
        const SizedBox(width: 8),
        Expanded(
          child: SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              children: trends.map((t) => Padding(
                padding: const EdgeInsets.only(right: 10),
                child: Row(children: [
                  const Icon(Icons.check_circle_outline, color: _kCyan, size: 12),
                  const SizedBox(width: 3),
                  Text(t, style: const TextStyle(color: Colors.white, fontSize: 10, fontWeight: FontWeight.w600)),
                ]),
              )).toList(),
            ),
          ),
        ),
      ]),
    );
  }

  Widget _buildBingoTopSection(List<int> topRec) {
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 10),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          colors: [Color(0xFF001433), Color(0xFF000820)],
          begin: Alignment.topCenter, end: Alignment.bottomCenter,
        ),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: _kCyan.withAlpha(120), width: 1.5),
      ),
      child: Column(children: [
        Row(children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
            decoration: BoxDecoration(color: _kCyan, borderRadius: BorderRadius.circular(6)),
            child: const Text('胖胖最強推薦', style: TextStyle(color: Colors.black, fontWeight: FontWeight.w900, fontSize: 13)),
          ),
        ]),
        const SizedBox(height: 10),
        Wrap(
          spacing: 8, runSpacing: 8,
          alignment: WrapAlignment.center,
          children: topRec.map((n) => _NumBallCyan(n: n)).toList(),
        ),
        const SizedBox(height: 8),
        Text(
          '配置邏輯：熱號主力＋連帶補強＋冷號回補，全覆蓋策略',
          style: TextStyle(color: _kCyan.withAlpha(160), fontSize: 9, fontStyle: FontStyle.italic),
          textAlign: TextAlign.center,
        ),
      ]),
    );
  }

  Widget _buildBingoTips() {
    const tips = ['6碼可直接全壓覆蓋', '或拆成：4碼主攻 + 2碼機動', '想更穩 → 熱號組 + 連帶組混搭'];
    return Container(
      margin: const EdgeInsets.fromLTRB(10, 10, 10, 0),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: Colors.white.withAlpha(8),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: Colors.white12),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        const Text('操作建議', style: TextStyle(color: _kCyan, fontWeight: FontWeight.w700, fontSize: 12)),
        const SizedBox(height: 6),
        ...tips.map((t) => Padding(
          padding: const EdgeInsets.only(bottom: 3),
          child: Row(children: [
            const Icon(Icons.play_arrow_rounded, color: _kCyan, size: 14),
            const SizedBox(width: 4),
            Expanded(child: Text(t, style: const TextStyle(color: Colors.white70, fontSize: 11))),
          ]),
        )),
      ]),
    );
  }
}

// ══════════════════════════════════════════════════════════════
//  共用元件
// ══════════════════════════════════════════════════════════════

class _NS {
  final int n;
  final int count;
  const _NS(this.n, this.count);
}

class _NumBallGold extends StatelessWidget {
  const _NumBallGold({required this.n});
  final int n;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 48, height: 48,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        gradient: const LinearGradient(
          colors: [Color(0xFFFFD700), Color(0xFFFF8F00)],
          begin: Alignment.topLeft, end: Alignment.bottomRight,
        ),
        boxShadow: [BoxShadow(color: _kGold.withAlpha(120), blurRadius: 8, spreadRadius: 1)],
      ),
      alignment: Alignment.center,
      child: Text(n.toString().padLeft(2,'0'),
          style: const TextStyle(color: Colors.black, fontWeight: FontWeight.w900, fontSize: 15)),
    );
  }
}

class _NumBallCyan extends StatelessWidget {
  const _NumBallCyan({required this.n});
  final int n;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 44, height: 44,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        gradient: const LinearGradient(
          colors: [_kCyan, Color(0xFF0097A7)],
          begin: Alignment.topLeft, end: Alignment.bottomRight,
        ),
        boxShadow: [BoxShadow(color: _kCyan.withAlpha(100), blurRadius: 8, spreadRadius: 1)],
      ),
      alignment: Alignment.center,
      child: Text(n.toString().padLeft(2,'0'),
          style: const TextStyle(color: Colors.black, fontWeight: FontWeight.w900, fontSize: 14)),
    );
  }
}
