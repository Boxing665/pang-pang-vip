import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'package:flutter/foundation.dart';
import 'package:intl/intl.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/match_fixture.dart';
import '../models/match_prediction.dart';
import '../models/live_match_model.dart';
import '../models/prediction_log.dart';
import '../models/sport_type.dart';
import '../models/team_form.dart';
import '../models/odds_snapshot.dart';
import '../config/app_config.dart';
import 'remote_config_service.dart';
import 'prediction_log_service.dart';
import 'self_learning_service.dart';
import 'real_data_service.dart';
import 'odds_api_service.dart';
import 'lottery_service.dart';
import 'bingo_service.dart';
import 'sports_news_service.dart';

// ============================================
// 🎯 預測引擎相關類別
// ============================================

/// 蒙地卡羅模擬結果（500次隨機 Poisson 模擬）
class _MonteCarloResult {
  const _MonteCarloResult({
    required this.homeWinPct,
    required this.drawPct,
    required this.awayWinPct,
    required this.modeHomeScore,
    required this.modeAwayScore,
    required this.topScores,
  });
  final double homeWinPct;
  final double drawPct;
  final double awayWinPct;
  final int modeHomeScore;
  final int modeAwayScore;
  final List<({int h, int a, double prob})> topScores;
}

/// 泊松精確分佈模型結果（解析計算 P(X=k)）
class _PoissonExactResult {
  const _PoissonExactResult({
    required this.homeWinProb,
    required this.drawProb,
    required this.awayWinProb,
    required this.mostLikelyHomeScore,
    required this.mostLikelyAwayScore,
  });
  final double homeWinProb;
  final double drawProb;
  final double awayWinProb;
  final int mostLikelyHomeScore;
  final int mostLikelyAwayScore;
}

/// Bayesian 後驗機率（先驗 + 新證據）
class _BayesianPosterior {
  const _BayesianPosterior({
    required this.homeProbability,
    required this.drawProbability,
    required this.awayProbability,
  });

  final double homeProbability;
  final double drawProbability;
  final double awayProbability;

  double get drawAdjustedHomeProbability {
    final t = homeProbability + awayProbability;
    return t <= 0 ? 0.5 : homeProbability / t;
  }

  double get drawAdjustedAwayProbability {
    final t = homeProbability + awayProbability;
    return t <= 0 ? 0.5 : awayProbability / t;
  }
}

/// 核心預測演算法
/// 純賭盤退算法（Odds-Inversion Model）
/// 
/// 原理：
///   1. 從主勝/和局/客勝賠率去除莊家抽水 → 取得公正隱含概率 P(H)/P(D)/P(A)
///   2. 從大小分盤口（Over/Under line）取得比賽預期總分
///   3. 依主客強弱比例分配 λ_home / λ_away（Poisson 參數）
///   4. 以確定性 seed 抽樣 Poisson 分佈 → 預測比分
///   
/// 優點：
///   - 不依賴 ESPN 球隊歷史統計
///   - 直接反映全球專業賭盤（bet365 等）對比賽結果的集體判斷
///   - 足球保留平局（H/D/A），棒球/籃球強制分出勝負
class PredictionEngine {
  const PredictionEngine();

  static const _mlbParkFactors = {
    // 顯著打者友善（大分場地）
    'Colorado': 1.20, 'Rockies': 1.20, '科羅拉多': 1.20, '落磯': 1.20,    // Coors Field 高海拔
    'Cincinnati': 1.09, 'Reds': 1.09, '辛辛那提': 1.09, '紅人': 1.09,     // Great American Ball Park
    'Texas': 1.08, 'Rangers': 1.08, '德州': 1.08, '遊騎兵': 1.08,         // Globe Life Field
    'Boston': 1.07, 'Red Sox': 1.07, '波士頓': 1.07, '紅襪': 1.07,        // Fenway Park
    'Yankees': 1.07, '洋基': 1.07,                                         // Yankee Stadium（短左外野）
    'Chicago Cubs': 1.05, '小熊': 1.05,                                    // Wrigley Field
    'Philadelphia': 1.04, 'Phillies': 1.04, '費城': 1.04, '費城人': 1.04, // Citizens Bank Park
    'Baltimore': 1.03, 'Orioles': 1.03, '巴爾的摩': 1.03, '金鶯': 1.03,  // Camden Yards
    'Minnesota': 1.02, 'Twins': 1.02, '明尼蘇達': 1.02, '雙城': 1.02,    // Target Field
    // 中性
    'Detroit': 0.97, 'Tigers': 0.97, '底特律': 0.97, '老虎': 0.97,        // Comerica Park
    'Toronto': 0.97, 'Blue Jays': 0.97, '多倫多': 0.97, '藍鳥': 0.97,    // Rogers Centre（人工草皮）
    'Mets': 0.98, '大都會': 0.98,
    'Astros': 0.97, '太空人': 0.97,                                        // Minute Maid Park（調整後略低）
    'Houston': 0.97, '休士頓': 0.97,
    'Braves': 0.99, '勇士': 0.99,
    'Cardinals': 0.97, '紅雀': 0.97,
    'Rays': 0.97, '光芒': 0.97,
    'Tampa Bay': 0.97, '坦帕灣': 0.97,
    // 投手友善（小分場地）
    'Dodgers': 0.95, '道奇': 0.95,
    'Giants': 0.93, '舊金山巨人': 0.93,                                   // Oracle Park（海風壓制）
    'Padres': 0.91, '教士': 0.91,
    'Oakland': 0.94, '運動家': 0.94,
    'Marlins': 0.94, '馬林魚': 0.94,
    'Miami': 0.94, '邁阿密': 0.94,
    'Seattle': 0.95, 'Mariners': 0.95, '西雅圖': 0.95, '水手': 0.95,
    'Cleveland': 0.96, 'Guardians': 0.96, '克里夫蘭': 0.96, '守護者': 0.96,
  };

  /// 動態球場因子快取（本次 app session 有效）
  static Map<String, double> _dynamicParkFactors = {};

  /// 自適應權重快取：sport.name → (aiWeight, marketWeight, strategyName)
  /// 由外部在 App 啟動 / 每次 SelfLearning 校正後注入
  static Map<String, (double, double, String)> _cachedAdaptiveWeights = {};

  /// 注入最新的自適應策略權重（由 AiPredictionService 在背景校正後呼叫）
  static void setAdaptiveWeights(
      Map<String, (double, double, String)> weights) {
    _cachedAdaptiveWeights = weights;
  }

  static double _getParkFactor(String homeTeamName) {
    // 1. 先查動態因子（由 real_data_service 根據本季實際主場得分推算）
    final lower = homeTeamName.toLowerCase();
    for (final entry in _dynamicParkFactors.entries) {
      if (lower.contains(entry.key.replaceAll('mlb_team_', '').toLowerCase())) {
        return entry.value.clamp(0.75, 1.35);
      }
    }
    // 2. 退回硬編碼基準表
    for (final entry in _mlbParkFactors.entries) {
      if (homeTeamName.contains(entry.key)) return entry.value;
    }
    return 1.0;
  }

  /// 由外部（App 啟動 / 預測前）注入最新動態球場因子
  static void setDynamicParkFactors(Map<String, double> factors) {
    _dynamicParkFactors = factors;
  }

  MatchPrediction predictScore(
    MatchFixture fixture, {
    SportBiasData? bias,
    Map<String, double> mlWeights = const {},
    Map<String, double> linearRegressionCoeffs = const {},
    double lineupHomeMultiplier = 1.0,
    double lineupAwayMultiplier = 1.0,
  }) {
    final sport = fixture.sport;
    final profile = _SportProfile.forType(sport);
    final odds = fixture.odds;

    final minS = profile.minimumScore.toDouble();
    final maxS = profile.baseTotalScore * 1.65;

    // ── 特徵工程 1: 公平隱含機率 (Fair Probability) ─────────────────
    // 扣除莊家抽水 (Overround)，取得更接近真實的市場勝率
    var fairHome = odds.fairHomeProb;
    var fairAway = odds.fairAwayProb;
    var fairDraw = odds.fairDrawProb;

    // ── H2H 對戰記錄修正 (Head-to-Head Adjustment) ──────────────────
    // 近 5 場直接對決數據：70% 市場賠率 + 30% H2H 歷史勝率
    final h2hTotal = fixture.h2hHomeWins + fixture.h2hAwayWins + fixture.h2hDraws;
    if (h2hTotal >= 3) {
      final h2hHomeRate = fixture.h2hHomeWins / h2hTotal;
      final h2hAwayRate = fixture.h2hAwayWins / h2hTotal;
      fairHome = fairHome * 0.70 + h2hHomeRate * 0.30;
      fairAway = fairAway * 0.70 + h2hAwayRate * 0.30;
      final sumFA = fairHome + fairAway + fairDraw;
      if (sumFA > 0) { fairHome /= sumFA; fairAway /= sumFA; fairDraw /= sumFA; }
    }
    // ESPN 預測器融合：80% 市場 + 20% ESPN Predictor（當有 ESPN 勝率數據時）
    if (fixture.espnHomePct > 0.01) {
      final espnAwayFair = (1.0 - fixture.espnHomePct - fairDraw).clamp(0.05, 0.90);
      fairHome = (fairHome * 0.80 + fixture.espnHomePct * 0.20).clamp(0.05, 0.90);
      fairAway = (fairAway * 0.80 + espnAwayFair * 0.20).clamp(0.05, 0.90);
      final sumFB = fairHome + fairAway + fairDraw;
      if (sumFB > 0) { fairHome /= sumFB; fairAway /= sumFB; fairDraw /= sumFB; }
    }

    // ── 特徵工程 2: 盤口變動分析 (Market Movement) ─────────────────
    // 足球在各運動區塊內使用 footballMarketFactor；其他運動在 Step 2.8 使用 mm 直接計算

    // ── Step 1: 計算基礎戰力指標 (基於進攻與防守效率) ─────────────────

    final homeEffScored = _rollingWeighted(fixture.homeForm);
    final awayEffScored = _rollingWeighted(fixture.awayForm);
    final homeEffConceded = _rollingWeighted(fixture.homeForm, conceded: true);
    final awayEffConceded = _rollingWeighted(fixture.awayForm, conceded: true);
    double homeLambda = (homeEffScored + awayEffConceded) / 2;
    double awayLambda = (awayEffScored + homeEffConceded) / 2;

    // ── Step 1.1: 加入主場優勢 (Home Advantage Factor) ──────────
    final homeAdv = sport == SportType.basketball ? 1.03 : 1.05;
    homeLambda *= homeAdv;

    // ── Step 1.2: 陣容品質修正 (Lineup Quality Adjustment) ──────────
    // 由 predictMatchWithDetail 傳入；無陣容資料時預設 1.0（無影響）
    homeLambda *= lineupHomeMultiplier;
    awayLambda *= lineupAwayMultiplier;

    // ── Step 1.3: Back-to-Back 疲勞扣分 ──────────────────────────────
    // 連兩天出賽：-3.5% 得分效率（NBA 研究顯示 B2B 場均得分少 ~2-4 分）
    // 休息不足（restDays == 0 即昨天打球）額外 -1%
    if (fixture.homeIsB2B) {
      homeLambda *= (fixture.homeRestDays == 0 ? 0.955 : 0.965);
    }
    if (fixture.awayIsB2B) {
      awayLambda *= (fixture.awayRestDays == 0 ? 0.955 : 0.965);
    }

    // hasFormData：足球用於區分「真實數據」與「模型估算」的壓縮力度
    // 在 Step 2 football 區塊內設定，Step 2.9 防守切換時需要讀取
    bool hasFormData = fixture.homeForm.hasRealStats && fixture.awayForm.hasRealStats;

    // ── Step 2: 專屬運動建模 (Baseball/Soccer/Basketball) ──────────
    if (sport == SportType.baseball) {
      // ⚾ 棒球建模：先發投手（前65%局數）+ 牛棚（後35%局數）
      // 基線 ERA 採 4.50（MLB/NPB/CPBL 整合均值）
      const baselineEra = 4.50;

      // ── 先發投手 (Starting Pitcher) ─────────────────────────────
      const baselineWhip = 1.30; // MLB/CPBL 平均 WHIP
      // 無先發 ERA 時，用近期實際失分均值推導 ERA 代理值（失分 / 0.85 ≈ ERA）
      // 這樣弱投手陣（高失分隊）仍會產生較高 ERA，維持球隊間差異
      double eraProxy(TeamForm f) {
        final r3 = f.last3AvgConceded;
        final r10 = f.last10AvgConceded;
        final base = r3 ?? r10 ?? f.averageConceded;
        return base > 0 ? (base / 0.85).clamp(2.5, 8.0) : baselineEra;
      }
      final homeEraProxy = eraProxy(fixture.homeForm);
      final awayEraProxy = eraProxy(fixture.awayForm);
      final awayStarterEra = (double.tryParse(fixture.awayProbableEra) ?? awayEraProxy).clamp(0.5, 12.0);
      final homeStarterEra = (double.tryParse(fixture.homeProbableEra) ?? homeEraProxy).clamp(0.5, 12.0);
      final awayStarterK9 = (double.tryParse(fixture.awayProbableK9) ?? 8.0).clamp(3.0, 15.0);
      final homeStarterK9 = (double.tryParse(fixture.homeProbableK9) ?? 8.0).clamp(3.0, 15.0);
      // WHIP 越高（差投手）→ factor > 1.0 → 對手得分更多（與 ERA 方向相同）
      final awayStarterWhip = (double.tryParse(fixture.awayProbableWhip) ?? baselineWhip).clamp(0.5, 2.5);
      final homeStarterWhip = (double.tryParse(fixture.homeProbableWhip) ?? baselineWhip).clamp(0.5, 2.5);

      // FIP 近似值：ERA 修正 K/9 技能因子（三振是最純粹的投手技能，不依賴守備）
      // FIP_approx = ERA + (leagueAvgK9 - pitcherK9) × 0.12 + (WHIP - avgWHIP) × 0.30
      // 高 K/9 → FIP 低於 ERA（投手真實能力被守備失誤稀釋）
      const leagueAvgK9 = 8.8;
      const leagueAvgWhip = 1.28;
      final homeFip = (homeStarterEra + (leagueAvgK9 - homeStarterK9) * 0.12
          + (homeStarterWhip - leagueAvgWhip) * 0.30).clamp(1.5, 8.5);
      final awayFip = (awayStarterEra + (leagueAvgK9 - awayStarterK9) * 0.12
          + (awayStarterWhip - leagueAvgWhip) * 0.30).clamp(1.5, 8.5);

      // 使用 FIP 取代 ERA，提高對守備獨立的投手真實評估精度
      final awayStarterEff = (awayFip / baselineEra * 0.55 + (leagueAvgK9 / awayStarterK9) * 0.30 + awayStarterWhip / baselineWhip * 0.15).clamp(0.65, 1.40);
      final homeStarterEff = (homeFip / baselineEra * 0.55 + (leagueAvgK9 / homeStarterK9) * 0.30 + homeStarterWhip / baselineWhip * 0.15).clamp(0.65, 1.40);

      // ── 牛棚 (Bullpen) ───────────────────────────────────────────
      // 用球隊整體 ERA 推算牛棚 ERA（優先使用近期滾動失分，再退回賽季均值）
      // 公式：teamERA = (starterERA × 5.5局 + bullpenERA × 3.5局) / 9局
      // → bullpenERA = (teamERA × 9 − starterERA × 5.5) / 3.5
      final homeTeamEra = homeEraProxy;
      final awayTeamEra = awayEraProxy;

      final homeBullpenEra = ((homeTeamEra * 9 - homeStarterEra * 5.5) / 3.5).clamp(2.0, 8.0);
      final awayBullpenEra = ((awayTeamEra * 9 - awayStarterEra * 5.5) / 3.5).clamp(2.0, 8.0);
      final homeBullpenEff = (homeBullpenEra / baselineEra).clamp(0.78, 1.30);
      final awayBullpenEff = (awayBullpenEra / baselineEra).clamp(0.78, 1.30);

      // ── 整體投球效能 = 先發 65% + 牛棚 35% ──────────────────────
      final awayPitchingEff = awayStarterEff * 0.65 + awayBullpenEff * 0.35;
      final homePitchingEff = homeStarterEff * 0.65 + homeBullpenEff * 0.35;

      // 客隊整體投球壓制主隊得分；主隊整體投球壓制客隊得分
      // 🌟 優化：加大投球效能對 Lambda 的拉伸，使強弱隊 Lambda 產生斷層，減少平手 Mode 出現
      final intensity = 1.25; // 強化係數
      homeLambda *= pow(awayPitchingEff, intensity).toDouble();
      awayLambda *= pow(homePitchingEff, intensity).toDouble();

      // ── 球場效應（Park Factor）─────────────────────────────────────
      // Coors Field(科羅拉多)等高海拔/小場地球場進球顯著偏多
      final parkFactor = _getParkFactor(fixture.homeTeam);
      if (parkFactor != 1.0) {
        homeLambda *= parkFactor;              // 主隊打者在主場得益
        awayLambda *= 1.0 + (parkFactor - 1.0) * 0.80; // 客隊打者同場，實證約為主隊效果的80%
      }

      // 打擊狀態動能 (+1 分動能 ≈ +2% 進攻力)
      homeLambda *= (1.0 + (fixture.homeForm.momentumScore / 50));
      awayLambda *= (1.0 + (fixture.awayForm.momentumScore / 50));

    } else if (sport == SportType.football) {
      // ⚽ 足球建模 ── Dixon-Coles 乘法模型
      // λH = 聯盟均值 × 主攻強度比 × 客防弱度比
      // λA = 聯盟均值 × 客攻強度比 × 主防弱度比
      // 攻防強度分開計算，避免兩隊「均值」時永遠輸出相同 λ
      const leagueAvg = 1.35; // 歐洲主要聯賽平均進球/隊

      // 每隊獨立判斷：averageScored > 0.10 表示已有來自排行榜或近期滾動數據
      // 不再要求雙隊同時有數據，避免「一隊缺數據→整場預測退化」的問題
      double homeAttack, homeDefWeak, awayAttack, awayDefWeak;
      homeAttack = fixture.homeForm.averageScored > 0.10
          ? (fixture.homeForm.averageScored  / leagueAvg).clamp(0.30, 3.0)
          : (0.55 + fairHome * 0.90).clamp(0.40, 1.60);
      homeDefWeak = fixture.homeForm.averageConceded > 0.10
          ? (fixture.homeForm.averageConceded / leagueAvg).clamp(0.20, 3.5)
          : (1.40 - fairHome * 0.50).clamp(0.55, 1.55);
      awayAttack = fixture.awayForm.averageScored > 0.10
          ? (fixture.awayForm.averageScored  / leagueAvg).clamp(0.30, 3.0)
          : (0.55 + fairAway * 0.90).clamp(0.40, 1.60);
      awayDefWeak = fixture.awayForm.averageConceded > 0.10
          ? (fixture.awayForm.averageConceded / leagueAvg).clamp(0.20, 3.5)
          : (1.40 - fairAway * 0.50).clamp(0.55, 1.55);
      // hasFormData 仍用於後段防守校準邏輯（維持兼容）
      hasFormData = fixture.homeForm.averageScored > 0.10 || fixture.awayForm.averageScored > 0.10;

      // Dixon-Coles 核心：進攻強度 × 對方防守弱度
      homeLambda = leagueAvg * homeAttack * awayDefWeak;
      awayLambda = leagueAvg * awayAttack * homeDefWeak;

      // ── 聯賽主場優勢 + 平局削弱 ──────────────────────────────────
      // 不同聯賽主場勝率差異顯著（土超 ~50% vs 歐冠中性場 ~45%）
      // 平局格局高 → 主場優勢縮小（雙方保守互不進攻）
      final leagueHomeBase = _leagueHomeAdvantage(fixture.league);
      final drawAwareHomeAdv =
          (leagueHomeBase - fairDraw * 0.09).clamp(leagueHomeBase * 0.92, leagueHomeBase * 1.02);
      homeLambda *= drawAwareHomeAdv;

      // ── 客隊客場疲勞（Road Fatigue）──────────────────────────────
      // 長途客場或洲際賽事對進攻有額外抑制（跨時區差旅、適應新球場）
      final isIntlComp = fixture.league.contains('Champions') ||
          fixture.league.contains('Europa') ||
          fixture.league.contains('Conference') ||
          fixture.league.contains('歐冠') ||
          fixture.league.contains('歐聯') ||
          fixture.league.contains('World Cup') ||
          fixture.league.contains('世界盃') ||
          fixture.league.contains('Nations League');
      awayLambda *= isIntlComp ? 0.95 : 0.97;

      // 大小分盤校準：將模型總進球向市場期望值靠攏（90% 融合）
      // 再依賠率方向設定目標總進球：推大 → ceil(line)，推小 → floor(line)-0.5
      if (odds.overLine > 1.5) {
        final modelTotal = homeLambda + awayLambda;
        if (modelTotal > 0.3) {
          // 基礎校準：拉向 overLine
          double targetTotal = odds.overLine;
          if (odds.overOdds > 1.0 && odds.underOdds > 1.0 && odds.overOdds != odds.underOdds) {
            // 賭盤有明確方向：目標總進球偏向市場推薦側
            if (odds.overOdds < odds.underOdds) {
              // 推大分：目標 = overLine + 0.6（確保預測總分越過盤口）
              targetTotal = odds.overLine + 0.6;
            } else {
              // 推小分：目標 = overLine - 0.6（確保預測總分落在盤口之下）
              targetTotal = odds.overLine - 0.6;
            }
          }
          final marketRatio = (targetTotal / modelTotal).clamp(0.40, 2.5);
          final calibration = 1.0 + (marketRatio - 1.0) * 0.90;
          homeLambda *= calibration;
          awayLambda *= calibration;
        }
      }

      // 讓分盤校準：用 Bet365 讓分錨定主客進球差期望值（50% 融合）
      // spread > 0 → 主場讓分（主場被看好）；spread < 0 → 客場讓分
      if (odds.spread != 0.0) {
        final marketMargin = odds.spread; // 正值 = 主場預期領先球數
        final currentDiff = homeLambda - awayLambda;
        final targetDiff = currentDiff * 0.50 + marketMargin * 0.50;
        final total = homeLambda + awayLambda;
        homeLambda = ((total + targetDiff) / 2).clamp(0.5, maxS);
        awayLambda = ((total - targetDiff) / 2).clamp(0.5, maxS);
      }

      // 戰術風格修正（僅在有有效數據時套用）
      if (hasFormData) {
        if (fixture.homeForm.averageConceded < 1.0) awayLambda *= 0.88; // 主隊鐵桶陣
        if (fixture.awayForm.averageScored > 1.6)   awayLambda *= 1.12; // 客隊強攻
      }

      // 近期表現 / 動能 / 穩定性：僅在有真實數據時才調整
      // 足球：ESPN 不提供真實球隊近況，近 5 場記錄由勝率模擬，跳過以免引入雜訊
      if (hasFormData) {
        final homeRecentFactor = _recentFormFactor(fixture.homeForm.lastFiveResults);
        final awayRecentFactor = _recentFormFactor(fixture.awayForm.lastFiveResults);
        homeLambda *= homeRecentFactor;
        awayLambda *= awayRecentFactor;

        homeLambda *= (1.0 + (fixture.homeForm.momentumScore - 5.0).clamp(-3.0, 3.0) * 0.013);
        awayLambda *= (1.0 + (fixture.awayForm.momentumScore - 5.0).clamp(-3.0, 3.0) * 0.013);

        final homeConsistency = _parseSeasonConsistency(fixture.homeForm.seasonRecord);
        final awayConsistency = _parseSeasonConsistency(fixture.awayForm.seasonRecord);
        homeLambda *= homeConsistency;
        awayLambda *= awayConsistency;
      }

      // ── 🛡️ 防線崩潰與等級壓制修正 (Defensive Fragility & Class Gap) ──
      // 有真實排行榜數據：失球 > 1.6 確實代表防線崩潰，允許 +10% 加成（真實訊號）
      // 無真實數據：avgConceded 是用勝率估算的，重複加成會放大雜訊，僅加 3%
      final fragBoost = hasFormData ? 1.10 : 1.03;
      if (fixture.awayForm.averageConceded > 1.6) homeLambda *= fragBoost;
      if (fixture.homeForm.averageConceded > 1.6) awayLambda *= fragBoost;

      // 實力斷層：若一隊排名或戰力動能 (momentumScore) 顯著優於對手，觸發「強隊收割」效應
      final classGap = (fixture.homeForm.momentumScore - fixture.awayForm.momentumScore);
      if (classGap > 10.0) {
        homeLambda *= 1.05; // 主隊具備等級壓制，進攻期望值再拉高
      } else if (classGap < -10.0) {
        awayLambda *= 1.05;
      }

      // 市場變動修正
      final footballMarketFactor = (odds.marketMovement * 0.18).clamp(-0.12, 0.12);
      if (odds.hasReverseLineMovement) {
        homeLambda *= (1.0 + footballMarketFactor);
      } else if (odds.marketMovement.abs() > 0.05) {
        final nudge = footballMarketFactor * 0.5;
        if (odds.marketMovement > 0) {
          homeLambda *= (1.0 + nudge);
          awayLambda *= (1.0 - nudge * 0.4);
        } else {
          awayLambda *= (1.0 - nudge);
          homeLambda *= (1.0 + nudge * 0.4);
        }
      }

      // ── xG 期望進球偏差修正 ─────────────────────────────────────────
      // 若實際場均進球遠超賠率隱含攻擊強度 → 運氣成分 → 回歸均值（向下修正）
      // 若實際進球遠低於隱含強度 → 被低估 → 輕微上調
      // 以 odds-implied 強度（fairHome/fairAway 推算）為 xG 代理值
      if (hasFormData) {
        final oddsImpliedHomeStr = (0.40 + fairHome * 1.10).clamp(0.40, 1.80);
        final oddsImpliedAwayStr = (0.40 + fairAway * 1.10).clamp(0.40, 1.80);
        final homeXgRatio = homeAttack / oddsImpliedHomeStr;
        final awayXgRatio = awayAttack / oddsImpliedAwayStr;
        // 超額進球 → 回歸修正，最多 -10%
        if (homeXgRatio > 1.30) {
          homeLambda *= (1.0 - (homeXgRatio - 1.30) * 0.15).clamp(0.90, 1.0);
        }
        if (awayXgRatio > 1.30) {
          awayLambda *= (1.0 - (awayXgRatio - 1.30) * 0.15).clamp(0.90, 1.0);
        }
        // 進球低估 → 輕微上調，最多 +7%
        if (homeXgRatio < 0.72) {
          homeLambda *= (1.0 + (0.72 - homeXgRatio) * 0.12).clamp(1.0, 1.07);
        }
        if (awayXgRatio < 0.72) {
          awayLambda *= (1.0 + (0.72 - awayXgRatio) * 0.12).clamp(1.0, 1.07);
        }
      }

      // ── 戰術相剋：高位逼搶 vs 長傳反擊 → 進球大戰 ─────────────────
      // 高位逼搶型：進攻積極（scored>1.7）但防線也相對暴露（conceded>1.2）
      // 反擊型：進球少但防守穩（scored<1.2 且 conceded<0.95）
      if (hasFormData) {
        final isHomePressStyle   = fixture.homeForm.averageScored > 1.70 &&
            fixture.homeForm.averageConceded > 1.20;
        final isAwayPressStyle   = fixture.awayForm.averageScored > 1.70 &&
            fixture.awayForm.averageConceded > 1.20;
        final isHomeCounterStyle = fixture.homeForm.averageScored < 1.20 &&
            fixture.homeForm.averageConceded < 0.95;
        final isAwayCounterStyle = fixture.awayForm.averageScored < 1.20 &&
            fixture.awayForm.averageConceded < 0.95;
        if ((isHomePressStyle && isAwayCounterStyle) ||
            (isAwayPressStyle && isHomeCounterStyle)) {
          // 相剋格局 → 開放型比賽，雙方進球總量 +8%
          homeLambda *= 1.08;
          awayLambda *= 1.08;
        }
        if (isHomePressStyle && isAwayPressStyle) {
          // 雙逼搶 → 高進球大戰 +10%
          homeLambda *= 1.10;
          awayLambda *= 1.10;
        }
        if (isHomeCounterStyle && isAwayCounterStyle) {
          // 雙反擊 → 低進球、守多攻少 -12%
          homeLambda *= 0.88;
          awayLambda *= 0.88;
        }
      }

      // ── 教練練兵哲學 (Coaching Philosophy) ──────────────────────────
      // 教練風格比短期狀態更穩定，體現在進攻/防守數據的組合模式上
      if (hasFormData) {
        final hScored  = fixture.homeForm.averageScored;
        final hConceded = fixture.homeForm.averageConceded;
        final aScored  = fixture.awayForm.averageScored;
        final aConceded = fixture.awayForm.averageConceded;

        // 全攻型教練（高進 + 高失）：比賽節奏快、開放型
        final homeFullAttack = hScored > 2.0 && hConceded > 1.3;
        final awayFullAttack = aScored > 2.0 && aConceded > 1.3;
        // 鐵板陣教練（極低失 + 低進）：義式防守哲學
        final homeCatenaccio = hConceded < 0.70 && hScored < 1.20;
        final awayCatenaccio = aConceded < 0.70 && aScored < 1.20;
        // 霸主型教練（高進 + 低失）：攻守均衡最強哲學
        final homeDominant = hScored > 1.70 && hConceded < 0.85;
        final awayDominant = aScored > 1.70 && aConceded < 0.85;

        if (homeFullAttack && awayFullAttack) {
          // 雙全攻 → 進球大戰 +10%
          homeLambda *= 1.10; awayLambda *= 1.10;
        }
        if (homeCatenaccio && awayCatenaccio) {
          // 雙鐵板 → 超低進球 -18%
          homeLambda *= 0.82; awayLambda *= 0.82;
        }
        if ((homeFullAttack && awayCatenaccio) || (awayFullAttack && homeCatenaccio)) {
          // 全攻 vs 鐵板 → 互相制約，兩方均壓縮 -12%
          homeLambda *= 0.88; awayLambda *= 0.88;
        }
        if (homeDominant) {
          // 主隊霸主：自身進攻 +8%，壓縮對手 -12%
          homeLambda *= 1.08; awayLambda *= 0.88;
        }
        if (awayDominant) {
          awayLambda *= 1.08; homeLambda *= 0.88;
        }

        // 教練近況穩定性：連贏 4+ 場 = 戰術奏效，連敗 4+ 場 = 被破解
        final homeRecent = fixture.homeForm.lastFiveResults;
        final awayRecent = fixture.awayForm.lastFiveResults;
        if (homeRecent.length >= 4) {
          final hw = homeRecent.where((r) => r == '勝').length;
          final hl = homeRecent.where((r) => r == '負').length;
          if (hw >= 4) homeLambda *= 1.05; // 教練戰術正確
          if (hl >= 4) homeLambda *= 0.95; // 戰術被破解
        }
        if (awayRecent.length >= 4) {
          final aw = awayRecent.where((r) => r == '勝').length;
          final al = awayRecent.where((r) => r == '負').length;
          if (aw >= 4) awayLambda *= 1.05;
          if (al >= 4) awayLambda *= 0.95;
        }
      }

      // ── 比賽情境分類調整 (Game Context Calibration) ──────────────
      // 有真實數據：Dixon-Coles 已捕捉強弱差距，此處僅小幅修正（0.15係數）
      // 無真實數據：模型估算不可靠，係數壓到 0.05，避免雙重放大
      final contextCoeff = hasFormData ? 0.15 : 0.05;
      final homeEdge = fairHome - fairAway;
      if (homeEdge.abs() > 0.22) {
        final surplus = homeEdge.abs() - 0.22;
        final favBoost   = (1.0 + surplus * contextCoeff).clamp(1.0, 1.08);
        final undPenalty = (1.0 - surplus * contextCoeff).clamp(0.92, 1.0);
        if (homeEdge > 0) {
          homeLambda *= favBoost;
          awayLambda *= undPenalty;
        } else {
          awayLambda *= favBoost;
          homeLambda *= undPenalty;
        }
      } else if (fairDraw > 0.30 && homeEdge.abs() < 0.10) {
        // 高度平衡格局 → 雙方謹慎，進球略降
        homeLambda *= 0.92;
        awayLambda *= 0.92;
      }

      // ── 🎯 H2H 歷史對決進球校準（比數命中率核心訊號）──────────────────
      // 直接對決時雙方互知戰術，實際進球往往與聯賽平均有顯著差距。
      // 歷史 ≥3 場 H2H 數據：混入 H2H 平均總進球，校準絕對進球量。
      // H2H 勝負主客比：反映歷史進球分配傾向，微調主客 lambda 比例。
      if (fixture.h2hAvgGoals > 0.3 && h2hTotal >= 3) {
        final currentTotal = homeLambda + awayLambda;
        if (currentTotal > 0.3) {
          // 場次越多，H2H 訊號越可靠：≥5場 30%，3-4場 20%
          final h2hWeight = h2hTotal >= 5 ? 0.30 : 0.20;
          final blendedTotal = currentTotal * (1.0 - h2hWeight) + fixture.h2hAvgGoals * h2hWeight;
          final calibRatio = (blendedTotal / currentTotal).clamp(0.65, 1.50);
          homeLambda *= calibRatio;
          awayLambda *= calibRatio;
        }
      }
      // H2H 主客進球分配校準：歷史主導方（主勝多 vs 客勝多）→ 微調 lambda 比例
      if (h2hTotal >= 3) {
        final h2hHomeDom = (fixture.h2hHomeWins - fixture.h2hAwayWins) / h2hTotal;
        if (h2hHomeDom.abs() > 0.20) {
          // 最多 ±6% 的 lambda 分配調整，避免過度覆蓋賠率訊號
          final adj = (h2hHomeDom * 0.06).clamp(-0.06, 0.06);
          homeLambda *= (1.0 + adj);
          awayLambda *= (1.0 - adj * 0.7);
        }
      }

    } else if (sport == SportType.basketball) {
      // 🏀 籃球建模：球員場均得分與狀態
      // 確保比分符合常規時間 (Regulation Time)，不計入延長賽
      if (homeLambda < 85) homeLambda = 110.0;
      if (awayLambda < 85) awayLambda = 108.0;
      // 確保比分符合常規時間 (Regulation Time)，不計入延長賽，並考慮球員效率值
      final homePer = fixture.homeForm.playerEfficiencyRating; // 新增 PER
      final awayPer = fixture.awayForm.playerEfficiencyRating; // 新增 PER

      // PER 補正：聯盟平均 PER 約 15.0。PER 越高，進攻 λ 越高。
      homeLambda = (homeLambda * 0.7 + (110.0 + (homePer - 15.0) * 2.5) * 0.3).clamp(85.0, 145.0);
      awayLambda = (awayLambda * 0.7 + (108.0 + (awayPer - 15.0) * 2.5) * 0.3).clamp(85.0, 145.0);

      // 若 PER 儲存的是 ORTG 值（>50），表示有進階效率數據，調整 lambda 分配
      if (homePer > 50) {
        // ORTG 模式：以主客 ORTG 差距微調 lambda 比例（最多 ±5%）
        final ortgDiff = (homePer - awayPer) / 200.0;
        homeLambda *= (1.0 + ortgDiff.clamp(-0.05, 0.05));
        awayLambda *= (1.0 - ortgDiff.clamp(-0.05, 0.05));
      }
      
      // 狀態補正：momentumScore 代理了球員近況 (每 +1 動能 ≈ +1.0 分)
      homeLambda += (fixture.homeForm.momentumScore * 1.0);
      awayLambda += (fixture.awayForm.momentumScore * 1.0);
      
      // 延長賽潛力預測 (Overtime Probability)
      // 如果公平機率極其接近 (差<2%) 且總分預期高，標記 OT 可能
      final otPotential = (fairHome - fairAway).abs() < 0.02;
      if (otPotential) {
        // 僅作為信心度參考，不直接加入預測比分，符合使用者「不把延長賽加進去」要求
      }
    }

    // ── Step 2.5: 量化傷兵影響 (模擬 On-Off Court 邊際價值) ──────────
    // 使用加權削減：Out (100% 權重), Questionable (50% 權重)
    final homeInjuries = fixture.homeForm.injuries;
    final awayInjuries = fixture.awayForm.injuries;

    // 模擬 On-Off：如果明星球員 (由 momentumScore 代理) 越多，受傷影響權重越高
    double homePenalty = _calculateMarginalInjuryImpact(homeInjuries, fixture.homeForm.momentumScore, fixture.sport);
    double awayPenalty = _calculateMarginalInjuryImpact(awayInjuries, fixture.awayForm.momentumScore, fixture.sport);

    homeLambda *= (1.0 - homePenalty);
    awayLambda *= (1.0 - awayPenalty);

    // 重新取得隱含市場機率 (僅作為凱利公式對比參考，不參與核心比分生成)
    final probs = _MarketProbabilities.fromOdds(fixture);
    final bayes = _applyBayesianUpdate(fixture, probs);

    // ── Step 2.6: 運動項目專屬模型權重 ─────────────────────────────
    // NBA  → 球星動能（momentumScore 代理球星狀態）
    // 足球 → 防守結構已在 Dixon-Coles 完整計入，此處略過
    // 棒球 → 先發 + 牛棚 ERA 已在 Step 2 完整整合，此處略過
    if (fixture.sport == SportType.basketball) {
      // NBA 球星動能乘數：7.0 為聯盟基線；每 +1 分 ≈ +1.5% λ
      final homeMomentumMult = 1.0 +
          (fixture.homeForm.momentumScore - 7.0).clamp(-4.0, 3.0) * 0.015;
      final awayMomentumMult = 1.0 +
          (fixture.awayForm.momentumScore - 7.0).clamp(-4.0, 3.0) * 0.015;
      homeLambda *= homeMomentumMult;
      awayLambda *= awayMomentumMult;
    }

    // ── Step 2.7: 歷史偏差修正（MC 準確率調控激進度）──────────────
    // 根據紀錄中已回報結果的歷史平均誤差，自動調整 λ
    // MC 準確率高 → 修正更激進（信任模型）；低 → 修正趨保守
    if (bias != null && bias.hasSufficientData) {
      final mcMult = bias.mcConfidenceMultiplier; // 0.7–1.3
      // 將 bias 偏差向 1.0 收斂或擴散，取決於 MC 表現
      final adjHome = 1.0 + (bias.homeLambdaFactor - 1.0) * mcMult;
      final adjAway = 1.0 + (bias.awayLambdaFactor - 1.0) * mcMult;
      homeLambda *= adjHome;
      awayLambda *= adjAway;
    }

    // ── Step 2.7b: 球隊進攻「自我修正」─────────────────────────────
    // 若某隊在過去 3 場以上被連續預測大勝，但實際結果均為平手，
    // 系統自動調降該隊的 λ（進攻權重），防止持續高估同一支球隊。
    if (bias != null) {
      final homeCorr = bias.teamAttackCorrections[fixture.homeTeam];
      final awayCorr = bias.teamAttackCorrections[fixture.awayTeam];
      if (homeCorr != null) homeLambda *= homeCorr;
      if (awayCorr != null) awayLambda *= awayCorr;

      // 迴歸均值：近期表現若偏離長期均值，向平均值拉回，避免被短期連勝/連敗誤導
      final homeReg = _regressionToMeanMultiplier(
        fixture.homeTeam,
        bias.teamPerformanceDb,
      );
      final awayReg = _regressionToMeanMultiplier(
        fixture.awayTeam,
        bias.teamPerformanceDb,
      );
      homeLambda *= homeReg;
      awayLambda *= awayReg;
    }
    
    // ── Step 2.7c: 線性回歸誤差修正 (Linear Regression Error Correction) ──
    // 根據歷史預測誤差，動態調整 λ
    // 係數來自 PredictionLogService 統計的歷史數據
    if (linearRegressionCoeffs.isNotEmpty) {
      final homeIntercept = linearRegressionCoeffs['home_intercept'] ?? 0.0;
      final homeCoeff = linearRegressionCoeffs['home_coeff'] ?? 1.0;
      final awayIntercept = linearRegressionCoeffs['away_intercept'] ?? 0.0;
      final awayCoeff = linearRegressionCoeffs['away_coeff'] ?? 1.0;
      homeLambda = (homeLambda * homeCoeff + homeIntercept).clamp(profile.minimumScore + 0.5, maxS).toDouble();
      awayLambda = (awayLambda * awayCoeff + awayIntercept).clamp(profile.minimumScore + 0.5, maxS).toDouble();
    }

    // 爆冷風險判斷：盤口看好隊（強隊）若有顯著傷兵 → 警示
    final favoredIsHome = probs.homeProbability >= probs.awayProbability;
    final favoredInjuries = favoredIsHome ? homeInjuries : awayInjuries;
    final favoredPenalty = favoredIsHome ? homePenalty : awayPenalty;
    final favoredTeam = favoredIsHome ? fixture.homeTeam : fixture.awayTeam;
    final underdogTeam = favoredIsHome ? fixture.awayTeam : fixture.homeTeam;
    final upsetAlert = favoredInjuries >= 2 || favoredPenalty >= 0.09;
    
    // ── 生成詳細傷兵警示（包含可能缺失位置/球員）────────────────────────
    final String? injuryWarning = upsetAlert
        ? _buildInjuryWarning(
            favoredTeam: favoredTeam,
            underdogTeam: underdogTeam,
            injuryCount: favoredInjuries,
            injuryPenalty: favoredPenalty,
            sport: fixture.sport,
            favoredIsHome: favoredIsHome,
            fixture: fixture,
          )
        : null;

    // ── Step 2.8: 盤口變動方向特徵（Market Movement Feature Engineering）───
    // 偵測「逆向盤口」(Reverse Line Movement)：
    // 大眾資金壓某隊，但博彩公司反而調整賠率對另一隊有利 → 聰明錢訊號
    final mm = fixture.odds.marketMovement; // 正=朝主勝，負=朝客勝
    if (fixture.odds.hasReverseLineMovement && fixture.odds.errorMargin > 0.03) {
      // 逆向盤口 → 聰明錢方向跟隨移動方向
      final boost = (mm.abs() * 0.12).clamp(0.0, 0.06); // 最多 ±6% λ 微調
      if (mm > 0) {
        homeLambda *= (1.0 + boost);
        awayLambda *= (1.0 - boost * 0.5);
      } else {
        awayLambda *= (1.0 + boost);
        homeLambda *= (1.0 - boost * 0.5);
      }
    }

    // Step 3 removed: pulling lambdas toward midpoint caused both to land in [1,2)
    // → Poisson mode = 1 for both → every match predicted as 1-1 draw.

    // ── Step 4: 邊界保護 ─────────────────────────────────────────
    homeLambda = homeLambda.clamp(minS + 0.5, maxS).toDouble();
    awayLambda = awayLambda.clamp(minS + 0.5, maxS).toDouble();

    // ── 計算「莊家的答案」(Market Expectations) ──
    // 有讓分盤時直接聯立 overLine ± spread 解出主客預期得分，比僅用勝率分配更準確
    // ⚠️ 當 bookmakerName='模型推算' 且 overLine 嚴重低於歷史基線時（ESPN 打擊率數據缺失）
    //    改用 baseTotalScore，避免拉低 lambda 至不合理值（如棒球出現 1:0 等足球式比分）
    final double marketTotal;
    if (odds.overLine > 0) {
      final isModelEst = odds.bookmakerName == '模型推算';
      final tooLow = isModelEst && odds.overLine < profile.baseTotalScore * 0.60;
      marketTotal = tooLow ? profile.baseTotalScore : odds.overLine;
    } else {
      marketTotal = profile.baseTotalScore;
    }
    final double marketHomeExp;
    final double marketAwayExp;
    // 棒球標準讓分永遠是 ±1.5（業界慣例），不反映實際期望分差；
    // 只有非標準讓分（例如季後賽 ±2.5）才直接用 spread 切分。
    final bool spreadIsInformative = odds.spread != 0.0 && odds.overLine > 0
        && odds.bookmakerName != '模型推算'
        && (sport != SportType.baseball || odds.spread.abs() != 1.5);
    if (spreadIsInformative) {
      final marketMargin = odds.spread; // 正值 = 主場預期領先（spread > 0 = 主場讓分）
      marketHomeExp = ((marketTotal + marketMargin) / 2)
          .clamp(marketTotal * 0.15, marketTotal * 0.85);
      marketAwayExp = marketTotal - marketHomeExp;
    } else {
      // 無真實賭盤或棒球標準讓分：用勝率比分配總分，讓每場有不同的 lambda 分佈
      final ratioMax = sport == SportType.football ? 0.70 : 0.80;
      final ratio = (fairHome / (fairHome + fairAway)).clamp(0.2, ratioMax);
      marketHomeExp = marketTotal * ratio;
      marketAwayExp = marketTotal - marketHomeExp;
    }

    // ── 🎯 新增：足球「領先轉防守」與「資金壓力」修正 ──────────────
    bool isDefensiveSwitchLikely = false;
    double volumePressure = odds.marketMovement.abs().clamp(0.0, 1.0);

    // ── Step 2.9: 莊家智慧 + AI 模型混合策略 ────────────────────────────
    // 「莊家的答案」是最準確的市場訊號：有讓分+大小分 → 直接解出主客得分期望值
    // 資料品質決定融合比例：
    //   有真實賭盤 + 讓分 + 大小分 → 賭盤主導（88-90%），AI 只負責微調
    //   有真實賭盤 + 僅勝率賠率     → 賭盤較高（78-80%），AI 補充近況
    //   模型推算（無真實賭盤）       → AI 主導（55-60%），賭盤僅輔助
    final bool hasPremiumOdds = odds.isFromBookmaker && odds.bookmakerName != '模型推算';
    // 棒球標準讓分 ±1.5 不算「有讓分資訊」（每場都是 1.5，不反映強弱差距）
    final bool hasSpreadAndLine = hasPremiumOdds && odds.spread != 0.0 && odds.overLine > 1.5
        && (sport != SportType.baseball || odds.spread.abs() != 1.5);
    // 自適應權重：由 SelfLearningService 根據近 20 場策略績效動態調整
    // 有真實盤口時上限為市場主導；無盤口時 AI 主導
    final double marketWeight;
    final String adaptiveStrategy;
    if (hasPremiumOdds) {
      // 向 SelfLearningService 取得自適應策略（同步讀取快取值）
      final adaptive = _cachedAdaptiveWeights[sport.name];
      final baseAiW = adaptive?.$1 ?? (sport == SportType.baseball ? 0.35
          : sport == SportType.basketball ? 0.30 : 0.38);
      adaptiveStrategy = adaptive?.$3 ?? 'strategy_b';
      // hasSpreadAndLine 時往市場方向再推一些，最多讓市場到 88%
      final boostIfSpread = hasSpreadAndLine ? 0.10 : 0.0;
      marketWeight = ((1.0 - baseAiW) + boostIfSpread).clamp(0.50, 0.90);
    } else if (odds.overLine <= 0) {
      // overLine 為 0 → 無真實盤口，用 baseTotalScore 混合只會拉向常數，改為純 AI
      marketWeight = 0.0;
      adaptiveStrategy = 'strategy_c';
    } else {
      // 有自行推算的 overLine（非零）但非真實博彩商 → 輕度混合
      marketWeight = sport == SportType.football ? 0.45
          : sport == SportType.basketball ? 0.40
          : 0.30;
      adaptiveStrategy = 'strategy_c';
    }
    final aiWeight = 1.0 - marketWeight;

    // 保存市場混合前的純 AI lambda（用於大小分判斷）
    // 市場混合後 lambda 會被 overLine 拉近，無法反映模型真實預測
    final aiRawHome = homeLambda;
    final aiRawAway = awayLambda;

    if (sport == SportType.football) {
      // 強隊收力修正：有真實數據時寬鬆（允許打爆），無真實數據時嚴格（防模型膨脹）
      // 有真實排行榜/近況：pivot=2.0，保留 50% 超出量（大比分有根據時可出現）
      // 無真實數據（純估算）：pivot=1.7，保留 30% 超出量（估算不可信，保守壓縮）
      final switchPivot  = hasFormData ? 2.0 : 1.7;
      final switchFactor = hasFormData ? 0.50 : 0.30;
      if ((homeLambda >= switchPivot && fairHome > 0.55) ||
          (awayLambda >= switchPivot && fairAway > 0.55)) {
        isDefensiveSwitchLikely = true;
        if (homeLambda > switchPivot) {
          homeLambda = switchPivot + (homeLambda - switchPivot) * switchFactor;
        }
        if (awayLambda > switchPivot) {
          awayLambda = switchPivot + (awayLambda - switchPivot) * switchFactor;
        }
      }

      // AI + 賭盤混合：50:50 融合，取得平衡的預測
      homeLambda = homeLambda * aiWeight + marketHomeExp * marketWeight;
      awayLambda = awayLambda * aiWeight + marketAwayExp * marketWeight;
    } else if (sport == SportType.basketball) {
      // 籃球也採用 AI + 賭盤混合策略
      homeLambda = homeLambda * aiWeight + marketHomeExp * marketWeight;
      awayLambda = awayLambda * aiWeight + marketAwayExp * marketWeight;
    } else if (sport == SportType.baseball) {
      // 棒球採用 AI + 賭盤混合策略，讓 overLine 錨定預測總分
      homeLambda = homeLambda * aiWeight + marketHomeExp * marketWeight;
      awayLambda = awayLambda * aiWeight + marketAwayExp * marketWeight;
    }

    // AI 模型預測總分：使用市場混合前的純 AI lambda
    // aiRawHome/aiRawAway 反映球隊進攻/防守能力 + park factor，不受 overLine 拉扯
    // 與盤口比較才有意義（若用混合後 lambda，永遠約等於 overLine → 無資訊）
    final double aiTotalExpected = aiRawHome + aiRawAway;
    final double predictedMargin;
    if (sport == SportType.baseball || sport == SportType.basketball) {
      final probDiff = fairHome - fairAway;
      final scale = sport == SportType.baseball ? 8.0 : 40.0;
      predictedMargin = (probDiff * scale).clamp(-6.0, sport == SportType.baseball ? 6.0 : 30.0);
    } else {
      predictedMargin = aiRawHome - aiRawAway;
    }

    // ── Step 5: 蒙地卡羅模擬（N=1000）取 mode 為主要預測比分 ─────────
    // Mode（最常見比分）比單次 Poisson 抽樣更接近期望值，預測更穩定。
    // 改進 Seed 計算：結合球隊名、聯賽、日期，確保不同比賽產生不同預測
    // 種子只用比賽固定資訊（隊名、聯賽、ID），不加時間因子
    // 加入 hourOfDay 會使預測每小時改變，讓用戶在不同時間看到不同比分 → 降低信任度
    final homeHash = fixture.homeTeam.codeUnits.fold(0, (a, b) => (a * 31 + b) & 0x7FFFFFFF);
    final awayHash = fixture.awayTeam.codeUnits.fold(0, (a, b) => (a * 31 + b) & 0x7FFFFFFF);
    final leagueHash = fixture.league.codeUnits.fold(0, (a, b) => (a * 17 + b) & 0xFFFF);
    final fixtureIdHash = fixture.id.codeUnits.fold(0, (a, b) => (a * 13 + b) & 0xFFFFF);

    // 每場比賽都有獨特且穩定的種子，不隨時間漂移
    final mcSeed = ((homeHash ^ awayHash) * 73856093 ^
                    leagueHash * 19349663 ^
                    fixtureIdHash * 83492791) &
                   0x7FFFFFFF;
    final mc = _runMonteCarlo(homeLambda, awayLambda, fixture.sport, mcSeed, simCount: 10000);

    var predictedHomeScore = mc.modeHomeScore.clamp(
      profile.minimumScore, profile.baseTotalScore.round(),
    );
    var predictedAwayScore = mc.modeAwayScore.clamp(
      profile.minimumScore, profile.baseTotalScore.round(),
    );

    if (fixture.sport == SportType.basketball) {
      predictedHomeScore = predictedHomeScore.clamp(80, 155);
      predictedAwayScore = predictedAwayScore.clamp(80, 155);
      final diff = (predictedHomeScore - predictedAwayScore).abs();
      if (diff > 38) {
        if (predictedHomeScore > predictedAwayScore) {
          predictedAwayScore = predictedHomeScore - 38;
        } else {
          predictedHomeScore = predictedAwayScore - 38;
        }
      }

      // 用 Bet365 讓分直接錨定勝分差（最準確的市場訊號）
      // spread > 0 → 主隊讓分（主隊被看好），marketMargin 正值 = 主隊領先幾分
      if (odds.spread != 0.0) {
        final marketMargin = odds.spread.round();
        final currentMargin = predictedHomeScore - predictedAwayScore;
        // 真實賭盤：92% 讓分錨定；模型估算：75% 讓分錨定
        final spreadTrust = hasPremiumOdds ? 0.92 : 0.75;
        final targetMargin = (currentMargin * (1.0 - spreadTrust) + marketMargin * spreadTrust).round();
        final total = predictedHomeScore + predictedAwayScore;
        final newHome = ((total + targetMargin) / 2).round().clamp(80, 155);
        final newAway = (total - newHome).clamp(80, 155);
        predictedHomeScore = newHome;
        predictedAwayScore = newAway;
      }
    }

    // ── 足球：直接採用 MC 模擬 mode 作為預測比分 ─────────────────────
    // 改用 1000 場模擬的眾數（最常出現的 joint score），不使用單次 Poisson 取樣。
    // 原因：單次取樣 Poisson(2.0) 有 ~20% 機率回傳 3，導致多場比賽同時出現 3:0；
    //      眾數反映整體分佈的中心，對於 lambda=1.5~2.5 的比賽能穩定輸出 1:0 或 2:0。
    if (fixture.sport == SportType.football) {
      // MC modeHomeScore / modeAwayScore 已是 1000 次模擬最常見的聯合比分
      if (mc.homeWinPct > mc.drawPct + 0.04 && mc.homeWinPct > mc.awayWinPct) {
        // 主隊勝：確保主隊得分 > 客隊得分
        final hS = mc.modeHomeScore.clamp(1, 5);
        final aS = mc.modeAwayScore.clamp(0, hS - 1);
        predictedHomeScore = hS;
        predictedAwayScore = aS;
      } else if (mc.awayWinPct > mc.drawPct + 0.04 && mc.awayWinPct > mc.homeWinPct) {
        // 客隊勝：確保客隊得分 > 主隊得分
        final aS = mc.modeAwayScore.clamp(1, 5);
        final hS = mc.modeHomeScore.clamp(0, aS - 1);
        predictedHomeScore = hS;
        predictedAwayScore = aS;
      } else {
        // 平局：取雙方 mode 的平均後取整
        final g = ((mc.modeHomeScore + mc.modeAwayScore) / 2).round().clamp(0, 3);
        predictedHomeScore = g;
        predictedAwayScore = g;
      }

      // 有真實讓分+大小分時：直接用莊家隱含比分覆蓋 MC mode（最準確的市場訊號）
      // marketHomeExp = (overLine + spread) / 2，是莊家對主客得分的直接預測
      if (hasSpreadAndLine) {
        final implH = marketHomeExp.round().clamp(0, 6);
        final implA = marketAwayExp.round().clamp(0, 6);
        if (mc.homeWinPct > mc.drawPct + 0.04 && mc.homeWinPct > mc.awayWinPct) {
          predictedHomeScore = implH.clamp(1, 5);
          predictedAwayScore = implA.clamp(0, predictedHomeScore - 1);
        } else if (mc.awayWinPct > mc.drawPct + 0.04 && mc.awayWinPct > mc.homeWinPct) {
          predictedAwayScore = implA.clamp(1, 5);
          predictedHomeScore = implH.clamp(0, predictedAwayScore - 1);
        } else {
          final g = ((implH + implA) / 2).round().clamp(0, 3);
          predictedHomeScore = g;
          predictedAwayScore = g;
        }
      }
    }

    // ── 足球比分合理化 (高頻比分範圍約束) ─────────────────────────
    // 根據比賽情境限制最大比分差，使預測分佈與真實高頻比分一致：
    //   強弱懸殊 → 2:0, 3:0, 3:1（最多 3 球差）
    //   強強對話 → 1:0, 0:1, 1:1（最多 2 球差）
    //   市場大小分盤保護（總進球不超過盤口 +1.5）
    if (fixture.sport == SportType.football) {
      final hEdge = (fairHome - fairAway).abs();
      // 強弱懸殊（賠率差 > 28%）：最多 3 球差
      if (hEdge > 0.28) {
        final diff = (predictedHomeScore - predictedAwayScore).abs();
        if (diff > 3) {
          if (predictedHomeScore > predictedAwayScore) {
            predictedAwayScore = predictedHomeScore - 3;
          } else {
            predictedHomeScore = predictedAwayScore - 3;
          }
        }
      }
      // 競爭格局（賠率差 < 12% 且高平局機率）：最多 2 球差
      if (hEdge < 0.12 && fairDraw > 0.28) {
        final diff = (predictedHomeScore - predictedAwayScore).abs();
        if (diff > 2) {
          if (predictedHomeScore > predictedAwayScore) {
            predictedAwayScore = predictedHomeScore - 2;
          } else {
            predictedHomeScore = predictedAwayScore - 2;
          }
        }
      }
      // 大小分強制對齊：嚴格確保預測比分與市場方向一致
      if (odds.overLine > 1.5 &&
          odds.overOdds > 1.0 && odds.underOdds > 1.0 &&
          odds.overOdds != odds.underOdds) {
        final tot = predictedHomeScore + predictedAwayScore;
        if (odds.overOdds < odds.underOdds) {
          // 市場推大：預測總進球必須 > overLine（至少 ceil(overLine)）
          final minTotal = odds.overLine.ceil();
          if (tot < minTotal) {
            final diff = minTotal - tot;
            if (predictedHomeScore >= predictedAwayScore) {
              predictedHomeScore += diff;
            } else {
              predictedAwayScore += diff;
            }
          }
        } else {
          // 市場推小：預測總進球必須 < overLine（至多 floor(overLine)）
          final maxTotal = odds.overLine.floor();
          if (tot > maxTotal) {
            final excess = tot - maxTotal;
            if (fairHome >= fairAway) {
              predictedAwayScore = (predictedAwayScore - excess).clamp(0, 99);
            } else {
              predictedHomeScore = (predictedHomeScore - excess).clamp(0, 99);
            }
          }
        }
      } else if (odds.overLine > 1.5) {
        // 無明確賠率方向：只做上限保護（overLine + 1.5）
        final maxTotal = (odds.overLine + 1.5).round();
        if (predictedHomeScore + predictedAwayScore > maxTotal) {
          final excess = predictedHomeScore + predictedAwayScore - maxTotal;
          if (fairHome >= fairAway) {
            predictedAwayScore = (predictedAwayScore - excess).clamp(0, 99);
          } else {
            predictedHomeScore = (predictedHomeScore - excess).clamp(0, 99);
          }
        }
      }
    }

    // ── 足球「賭盤錨定」精準比分推算 ────────────────────────────────
    // 方法：直接從賭盤兩個核心數字反推最可能比分
    //   overLine → 目標總進球  ；  spread → 目標分差
    //   聯立：home + away = total, home - away = margin → 解出 home, away
    // 此法準確度遠高於 MC，因為賭盤本身已整合全球最佳預測
    if (fixture.sport == SportType.football &&
        odds.overLine > 1.5 &&
        odds.bookmakerName != '模型推算') {
      // 1. 目標總進球：依賠率方向決定整數目標
      final double targetTotal;
      if (odds.overOdds > 1.0 && odds.underOdds > 1.0 &&
          odds.overOdds != odds.underOdds) {
        targetTotal = odds.overOdds < odds.underOdds
            ? odds.overLine.ceil().toDouble()   // 推大 → ceil（如 2.5→3）
            : odds.overLine.floor().toDouble(); // 推小 → floor（如 2.5→2）
      } else {
        targetTotal = odds.overLine.round().toDouble();
      }

      // 2. 目標分差：讓分盤最準（spread=-1.5 表示主場讓 1.5，即主場領先）
      final double targetMargin;
      if (odds.spread != 0.0) {
        targetMargin = -odds.spread; // 正值 = 主場領先球數
      } else {
        // 無讓分盤：用勝率差估計，係數 2.0 避免高估分差（足球勝 1:0 比 2:1 更常見）
        targetMargin = ((fairHome - fairAway) * 2.0).clamp(-1.5, 1.5);
      }

      // 3. 解方程：rawHome = (total + margin) / 2
      final double rawHome = (targetTotal + targetMargin) / 2;
      final double rawAway = targetTotal - rawHome;

      // 4. 四捨五入並確保非負
      int bookHome = rawHome.round().clamp(0, 6);
      int bookAway = rawAway.round().clamp(0, 6);

      // 5. 修正勝負方向錯誤（勝率差距明顯但分數方向反了）
      // 修正後重新從 targetTotal 計算輸家得分，避免 direction fix 使總進球超出 O/U 約束
      final int tgtTotalInt = targetTotal.round();
      if (fairHome > fairAway + 0.12 && bookHome <= bookAway) {
        bookHome = bookAway + 1;
        bookAway = (tgtTotalInt - bookHome).clamp(0, 6);
      } else if (fairAway > fairHome + 0.12 && bookAway <= bookHome) {
        bookAway = bookHome + 1;
        bookHome = (tgtTotalInt - bookAway).clamp(0, 6);
      }

      // 6. 賭盤直接推算比分：80% 賭盤錨定 + 20% Poisson 微調
      // 賭盤已整合全球資金與情報 → 是最佳預測來源，不應讓隨機 Poisson 主導
      predictedHomeScore =
          ((bookHome * 0.80 + predictedHomeScore * 0.20).round()).clamp(0, 7);
      predictedAwayScore =
          ((bookAway * 0.80 + predictedAwayScore * 0.20).round()).clamp(0, 7);
    }

    // ── 棒球「賭盤錨定」精準比分推算 ────────────────────────────────
    // 只用真實賭盤 overLine（Bet365/Pinnacle 等）進行錨定
    // AI 估算的 overLine（bookmakerName='模型推算'）因 ESPN 數據偶有缺失可達 ~1，不可信
    if (fixture.sport == SportType.baseball &&
        odds.overLine > 0 &&
        odds.bookmakerName != '模型推算') {
      // 1. 目標總得分：依大小分賠率方向微調
      final double targetTotal;
      if (odds.overOdds > 1.0 && odds.underOdds > 1.0 &&
          odds.overOdds != odds.underOdds) {
        targetTotal = odds.overOdds < odds.underOdds
            ? odds.overLine + 0.5   // 推大 → 略超盤口
            : odds.overLine - 0.5;  // 推小 → 略低盤口
      } else {
        targetTotal = odds.overLine;
      }

      // 2. 目標分差：用勝率差估算期望分差
      // MLB 讓分盤永遠是 ±1.5（標準慣例），不能用它判斷實際勝分差大小；
      // 例如 -1.5/-130 與 -1.5/-200 代表完全不同的強度，但 spread 都是 1.5。
      // 改用勝率差線性估算：每 10% 勝率差 ≈ 0.8 分差，上限 6 分。
      // 非標準讓分（≠ ±1.5）才直接錨定，例如季後賽特殊讓分。
      final double targetMargin;
      if (odds.spread != 0.0 && odds.spread.abs() != 1.5) {
        targetMargin = -odds.spread; // 非標準讓分：直接錨定
      } else {
        // 標準讓分或無讓分：用勝率差估算（讓每場比賽有獨特的預測分差）
        targetMargin = ((fairHome - fairAway) * 8.0).clamp(-6.0, 6.0);
      }

      // 3. 解方程：rawHome = (total + margin) / 2
      final double rawHome = (targetTotal + targetMargin) / 2;
      final double rawAway = targetTotal - rawHome;

      int bookHome = rawHome.round().clamp(0, 15);
      int bookAway = rawAway.round().clamp(0, 15);

      // 4. 修正勝負方向錯誤（同樣維持 targetTotal，避免違反 O/U 約束）
      final int baseTgt = targetTotal.round();
      if (fairHome > fairAway + 0.12 && bookHome <= bookAway) {
        bookHome = bookAway + 1;
        bookAway = (baseTgt - bookHome).clamp(0, 15);
      } else if (fairAway > fairHome + 0.12 && bookAway <= bookHome) {
        bookAway = bookHome + 1;
        bookHome = (baseTgt - bookAway).clamp(0, 15);
      }

      // 5. 與 MC 結果 82:18 融合
      predictedHomeScore =
          ((bookHome * 0.82 + predictedHomeScore * 0.18).round()).clamp(0, 15);
      predictedAwayScore =
          ((bookAway * 0.82 + predictedAwayScore * 0.18).round()).clamp(0, 15);
    }

    // ── 棒球 & 籃球：禁止平手（延長賽決勝）───────────────────────
    if (fixture.sport != SportType.football &&
        predictedHomeScore == predictedAwayScore) {
      if (probs.homeProbability >= probs.awayProbability) {
        predictedHomeScore += 1;
      } else {
        predictedAwayScore += 1;
      }
    }

    final total = homeLambda + awayLambda;
    final homeStrength = (total > 0 ? homeLambda / total : 0.5).clamp(0.18, 0.82);
    final awayStrength = (1.0 - homeStrength).clamp(0.18, 0.82);

    // ── Step 5.5: MC 結果已在 Step 5（10,000 次 Poisson 抽樣模擬）取得 ────────────

    // ── Step 5.7: 泊松精確分佈模型（Poisson Exact Distribution）──────
    final poisson = _poissonExact(homeLambda, awayLambda, fixture.sport);

    // ── Step 5.8: 勝分差機率 (僅籃球) ─────────────────────────────
    double basketballSpreadConfidence = 0.0;
    if (fixture.sport == SportType.basketball) {
      // 計算 |λH - λA| 與 標準差 的關係
      final diff = (homeLambda - awayLambda).abs();
      final sigma = sqrt(homeLambda + awayLambda);
      basketballSpreadConfidence = (diff / sigma).clamp(0.0, 1.0);
    }

    final mcWeight = fixture.sport == SportType.basketball ? 0.70 : 0.50;
    final poissonWeight = 1.0 - mcWeight;
    var ensembleHome = mc.homeWinPct * mcWeight + poisson.homeWinProb * poissonWeight;
    var ensembleDraw = mc.drawPct * mcWeight + poisson.drawProb * poissonWeight;
    var ensembleAway = mc.awayWinPct * mcWeight + poisson.awayWinProb * poissonWeight;

    // ── Step 5.8b: Bayesian + 賭盤融合（50:50 混合策略）─────────────────────────
    // Bayesian 後驗融合，同時考慮市場賠率隱含的市場智慧
    // 權重：AI 模型 50% + 賭盤隱含機率 50%
    ensembleHome = ensembleHome * 0.50 + probs.homeProbability * 0.50;
    ensembleDraw = ensembleDraw * 0.50 + probs.drawProbability * 0.50;
    ensembleAway = ensembleAway * 0.50 + probs.awayProbability * 0.50;
    final totalEns = ensembleHome + ensembleDraw + ensembleAway;
    if (totalEns > 0) {
      ensembleHome /= totalEns;
      ensembleDraw /= totalEns;
      ensembleAway /= totalEns;
    }

    // ── Step 5.9: 凱利公式（基於融合機率）─────────────────────────
    // 比較「融合模型機率」與「賭盤賠率隱含機率」，計算正期望值空間
    // f* = (b×p − q) / b：正值代表模型認為比賭盤更有把握
    final kellyHome = _kellyValue(ensembleHome, fixture.odds.homeWin);
    final kellyAway = _kellyValue(ensembleAway, fixture.odds.awayWin);
    final homeValueEdge = ensembleHome - probs.homeProbability;
    final awayValueEdge = ensembleAway - probs.awayProbability;
    final hasValueBetSignal = homeValueEdge >= 0.06 || awayValueEdge >= 0.06;

    // ── 新增：計算模型一致性 (Model Consensus) ──
    final modelAgreement = 1.0 - (mc.homeWinPct - poisson.homeWinProb).abs();

    var confidence = _buildConfidence(
      homeStrength: homeStrength,
      awayStrength: awayStrength,
      // 籃球勝分差信心度
      basketballSpreadConfidence: basketballSpreadConfidence,
      modelAgreement: modelAgreement,
      hasValueBet: hasValueBetSignal,
    );

    // 盤口劇烈震盪 → 降低信心值（莊家掌握我們沒有的資訊）
    final em = fixture.odds.errorMargin;
    if (em > 0.08) {
      confidence = (confidence - (em - 0.08) * 1.5).clamp(0.45, confidence);
    }


    return MatchPrediction(
      predictedHomeScore: predictedHomeScore,
      predictedAwayScore: predictedAwayScore,
      confidence: confidence,
      impliedHomeStrength: homeStrength,
      impliedAwayStrength: awayStrength,
      upsetAlert: upsetAlert,
      injuryWarning: injuryWarning,
      monteCarloHomeWinPct: mc.homeWinPct,
      monteCarloDrawPct: mc.drawPct,
      monteCarloAwayWinPct: mc.awayWinPct,
      kellyHome: kellyHome,
      kellyAway: kellyAway,
      mcModeHomeScore: mc.modeHomeScore,
      mcModeAwayScore: mc.modeAwayScore,
      ensembleHomeWinPct: ensembleHome,
      ensembleDrawPct: ensembleDraw,
      ensembleAwayWinPct: ensembleAway,
      poissonHomeWinPct: poisson.homeWinProb,
      poissonDrawPct: poisson.drawProb,
      poissonAwayWinPct: poisson.awayWinProb,
      marketMovement: mm,
      overround: fixture.odds.overround,
      bayesianHomeWinPct: bayes.homeProbability,
      bayesianDrawPct: bayes.drawProbability,
      bayesianAwayWinPct: bayes.awayProbability,
      homeValueEdge: homeValueEdge,
      awayValueEdge: awayValueEdge,
      hasValueBetSignal: hasValueBetSignal,
      topScores: mc.topScores,
      marketHomeExp: marketHomeExp,
      marketAwayExp: marketAwayExp,
      aiTotalExpected: aiTotalExpected,
      predictedMargin: predictedMargin,
      summary: _buildSummary(
        fixture: fixture,
        homeScore: predictedHomeScore,
        awayScore: predictedAwayScore,
        confidence: confidence,
      ),
      keyFactors: _buildKeyFactors(
        fixture: fixture,
        homeStrength: homeStrength,
        awayStrength: awayStrength,
        probabilities: probs,
        injuryWarning: injuryWarning,
        ensembleHome: ensembleHome,
        ensembleDraw: ensembleDraw,
        ensembleAway: ensembleAway,
        mcWeight: mcWeight,
        poissonWeight: poissonWeight,
        marketMovement: mm,
        overround: fixture.odds.overround,
        bayes: bayes,
        homeValueEdge: homeValueEdge,
        awayValueEdge: awayValueEdge,
        hasValueBetSignal: hasValueBetSignal,
        marketHomeExp: marketHomeExp,
        marketAwayExp: marketAwayExp,
        marketVolumePressure: volumePressure,
        isDefensiveSwitchLikely: isDefensiveSwitchLikely,
        predictedHomeScore: predictedHomeScore,
        adaptiveStrategy: adaptiveStrategy,
      ),
    );
  }

  // ── 蒙地卡羅 + 凱利 輔助方法 ───────────────────────────────────

  /// 帶隨機數生成器的 Poisson 抽樣（Monte Carlo 用）
  static int _poissonRandom(double lambda, Random rng) {
    if (lambda <= 0) return 0;
    if (lambda > 20) {
      final u1 = (rng.nextDouble() + 1e-10).clamp(1e-10, 1.0);
      final u2 = rng.nextDouble();
      final z = sqrt(-2.0 * log(u1)) * cos(2.0 * pi * u2);
      return max(0, (lambda + z * sqrt(lambda)).round());
    }
    final threshold = exp(-lambda);
    double product = 1.0;
    int k = 0;
    while (k < 100) {
      product *= rng.nextDouble();
      if (product <= threshold) break;
      k++;
    }
    return k;
  }


  /// 蒙地卡羅模擬（N=10,000）
  /// 以最終 λ 值做 Poisson 抽樣，統計主勝/平/客勝機率，並取最常見比分（mode）
  static _MonteCarloResult _runMonteCarlo(
    double homeLambda,
    double awayLambda,
    SportType sport,
    int baseSeed, {
    int simCount = 1000,
  }) {
    final rng = Random(baseSeed);
    var homeWins = 0, draws = 0, awayWins = 0;
    final scoreMap = <String, int>{};
    final isBasketball = sport == SportType.basketball;
    final isFootball = sport == SportType.football;

    for (var i = 0; i < simCount; i++) {
      var h = _poissonRandom(homeLambda, rng);
      var a = _poissonRandom(awayLambda, rng);
      if (isBasketball) {
        h = h.clamp(80, 155);
        a = a.clamp(80, 155);
        final diff = (h - a).abs();
        if (diff > 38) {
          if (h > a) { a = h - 38; } else { h = a - 38; }
        }
        if (h == a) { if (homeLambda >= awayLambda) { h++; } else { a++; } }
      } else if (!isFootball) {
        if (h == a) { if (homeLambda >= awayLambda) { h++; } else { a++; } }
      }
      final key = '$h:$a';
      scoreMap[key] = (scoreMap[key] ?? 0) + 1;
      if (h > a) {
        homeWins++;
      } else if (h < a) {
        awayWins++;
      } else {
        draws++;
      }
    }

    final modeEntry = scoreMap.entries
        .reduce((best, e) => e.value > best.value ? e : best);
    final parts = modeEntry.key.split(':');

    final sortedEntries = scoreMap.entries.toList()
        ..sort((a, b) => b.value.compareTo(a.value));
    final topScores = sortedEntries.take(3).map((e) {
      final scoreParts = e.key.split(':');
      return (h: int.parse(scoreParts[0]), a: int.parse(scoreParts[1]), prob: e.value / simCount);
    }).toList();

    return _MonteCarloResult(
      homeWinPct: homeWins / simCount,
      drawPct: draws / simCount,
      awayWinPct: awayWins / simCount,
      modeHomeScore: int.parse(parts[0]),
      modeAwayScore: int.parse(parts[1]),
      topScores: topScores,
    );
  }

  /// 凱利公式: f* = (b×p − q) / b
  /// b = decimal odds − 1（淨賠率）
  /// p = 模型勝率（來自 Monte Carlo），q = 1 − p
  /// 正值 = 正期望值建議下注；負值 = 賠率不划算
  static double _kellyValue(double modelProb, double decimalOdds) {
    if (decimalOdds <= 1.01 || modelProb <= 0 || modelProb >= 1) return 0.0;
    final b = decimalOdds - 1.0;
    final q = 1.0 - modelProb;
    return ((b * modelProb - q) / b).clamp(-1.0, 1.0);
  }

  static _BayesianPosterior _applyBayesianUpdate(
    MatchFixture fixture,
    _MarketProbabilities probs,
  ) {
    var h = probs.homeProbability;
    var d = probs.drawProbability;
    var a = probs.awayProbability;

    // Likelihood ratio：以即時資訊修正先驗，不直接覆蓋原盤口
    var lrHome = 1.0;
    var lrDraw = 1.0;
    var lrAway = 1.0;

    final injuryDiff = fixture.awayForm.injuries - fixture.homeForm.injuries;
    if (injuryDiff >= 2) {
      lrHome *= 1.15;
      lrAway *= 0.88;
    } else if (injuryDiff <= -2) {
      lrAway *= 1.15;
      lrHome *= 0.88;
    }

    final mm = fixture.odds.marketMovement;
    if (mm.abs() > 0.03) {
      if (mm > 0) {
        lrHome *= 1.08;
        lrAway *= 0.94;
      } else {
        lrAway *= 1.08;
        lrHome *= 0.94;
      }
    }

    // 足球高平局資訊給平局後驗小幅上調
    if (fixture.sport == SportType.football &&
        fixture.odds.overLine <= 2.25 &&
        fixture.odds.underOdds < fixture.odds.overOdds) {
      lrDraw *= 1.10;
    }

    h *= lrHome;
    d *= lrDraw;
    a *= lrAway;
    final t = h + d + a;
    if (t <= 0) {
      return const _BayesianPosterior(
        homeProbability: 0.45,
        drawProbability: 0.10,
        awayProbability: 0.45,
      );
    }

    return _BayesianPosterior(
      homeProbability: h / t,
      drawProbability: d / t,
      awayProbability: a / t,
    );
  }

  /// 近期表現因子：取最近 3 場結果加權
  /// 每場勝 → +4%、負 → -4%，clamp 到 [0.88, 1.12]
  static double _recentFormFactor(List<String> lastFive) {
    if (lastFive.isEmpty) return 1.0;
    final recent = lastFive.take(3).toList();
    final wins   = recent.where((r) => r == '勝').length;
    final losses = recent.where((r) => r == '負').length;
    return (1.0 + (wins - losses) * 0.04).clamp(0.88, 1.12);
  }

  /// 從賽季戰績字串（如 "51-29" 或 "18-5-9"）解析穩定性係數
  /// 勝率高 → 略微提升 λ；勝率低 → 略微壓縮
  static double _parseSeasonConsistency(String seasonRecord) {
    if (seasonRecord.isEmpty) return 1.0;
    final parts = seasonRecord.split('-');
    if (parts.length < 2) return 1.0;
    final wins = int.tryParse(parts[0].trim()) ?? 0;
    // 三欄格式 W-D-L；兩欄格式 W-L
    final losses = parts.length >= 3
        ? (int.tryParse(parts[2].trim()) ?? 0)
        : (int.tryParse(parts[1].trim()) ?? 0);
    final total = wins + losses;
    if (total < 5) return 1.0;
    final winRate = wins / total;
    return (0.92 + winRate * 0.16).clamp(0.92, 1.08);
  }

  /// 聯賽專屬主場優勢係數
  /// 依各聯賽歷史主場勝率統計，主場優勢強度差異顯著
  static double _leagueHomeAdvantage(String league) {
    const table = {
      // 英格蘭
      '英超': 1.08, 'Premier League': 1.08, 'Premier': 1.08,
      'Championship': 1.10,
      // 西班牙
      '西甲': 1.12, 'La Liga': 1.12,
      // 德國
      '德甲': 1.10, 'Bundesliga': 1.10,
      // 義大利
      '意甲': 1.11, 'Serie A': 1.11,
      // 法國
      '法甲': 1.09, 'Ligue 1': 1.09,
      // 葡萄牙
      '葡超': 1.12, 'Primeira Liga': 1.12,
      // 荷蘭
      '荷甲': 1.13, 'Eredivisie': 1.13,
      // 土耳其（主場優勢最強之一）
      '土超': 1.16, 'Süper Lig': 1.16,
      // 希臘
      'Super League': 1.15,
      // 歐洲賽事（主客場效應較弱）
      '歐冠': 1.05, 'Champions League': 1.05, 'UEFA Champions': 1.05,
      '歐洲聯賽': 1.05, '歐聯': 1.05, 'Europa League': 1.05,
      '歐協聯': 1.04, 'Conference League': 1.04,
      // 美洲
      'MLS': 1.15,  // MLS 主場優勢較強（升級至 1.15）
      'Liga MX': 1.13,
      // 亞洲
      'J1': 1.08, 'J League': 1.08,
      'K League': 1.09,
      '中超': 1.12, 'Chinese Super': 1.12,
      // 世界盃 / 國家隊（中立場地居多）
      'World Cup': 1.04, '世界盃': 1.04,
      'Nations League': 1.05,
    };
    for (final entry in table.entries) {
      if (league.contains(entry.key)) return entry.value;
    }
    return 1.07; // 未知聯賽預設值
  }

  /// 解析 "W-L" 或 "W-D-L" 戰績字串 → (勝率, 總場數)
  /// 用於計算主客場實際表現差異
  static (double winRate, int total)? _parseWinRecord(String record) {
    if (record.isEmpty) return null;
    final parts = record.replaceAll(RegExp(r'[^\d-]'), '').split('-');
    if (parts.length < 2) return null;
    final wins   = int.tryParse(parts[0]) ?? 0;
    final losses = parts.length >= 3
        ? (int.tryParse(parts[2]) ?? 0)
        : (int.tryParse(parts[1]) ?? 0);
    final total  = wins + losses;
    if (total < 4) return null;
    return (wins / total, total);
  }

  static double _regressionToMeanMultiplier(
    String team,
    Map<String, TeamPerformanceProfile> db,
  ) {
    final p = db[team];
    if (p == null || p.sampleSize < 5 || p.recentSampleSize < 3) return 1.0;
    if (p.scoredStdDev < 0.35) return 1.0;

    final z = (p.recentAvgScored - p.longAvgScored) / p.scoredStdDev;
    // Outlier 往平均回歸：過熱降權、過冷補權
    if (z >= 1.2) return 0.92;
    if (z >= 0.8) return 0.96;
    if (z <= -1.2) return 1.08;
    if (z <= -0.8) return 1.04;
    return 1.0;
  }

  /// 量化傷兵邊際影響 (Marginal Impact)
  /// 基於 On-Off Court 邏輯：球隊戰力愈依賴核心 (momentumScore高)，傷兵傷害愈大
  static double _calculateMarginalInjuryImpact(int injuryCount, double momentum, SportType sport) {
    if (injuryCount <= 0) return 0.0;

    // [優化] 針對高動能球隊（球星依賴型），傷兵的邊際損害呈指數級上升
    // 例如：獨行俠缺了東契奇 vs 活塞缺了主力
    final starDensity = (momentum / 10.0).clamp(0.5, 1.5);

    // 基礎價值影響
    double baseImpact = sport == SportType.basketball ? 0.07 : 0.04;
    // 明星加成：momentumScore 越高，代表傷員越有可能是核心球員
    double starMultiplier = (momentum / 5.0).clamp(1.0, 2.0);
    
    double totalPenalty = injuryCount * baseImpact * starMultiplier * starDensity;
    return totalPenalty.clamp(0.0, 0.35); // 最高削減 35% 戰力
  }

  /// 生成詳細傷兵警示（包含可能缺失位置或具體球員名字）
  static String _buildInjuryWarning({
    required String favoredTeam,
    required String underdogTeam,
    required int injuryCount,
    required double injuryPenalty,
    required SportType sport,
    required bool favoredIsHome,
    required MatchFixture fixture,
  }) {
    final penaltyPct = (injuryPenalty * 100).toStringAsFixed(1);
    final List<String> details = [];
    
    // ── 根據運動類型列出可能缺失的位置或球員 ────────────────────
    if (sport == SportType.baseball) {
      // 棒球：若主力投手傷 → 直接顯示投手名字
      final injuredPitcher = favoredIsHome 
          ? fixture.homeProbablePitcher 
          : fixture.awayProbablePitcher;
      if (injuredPitcher.isNotEmpty && injuryCount >= 1) {
        details.add('先發投手 $injuredPitcher 可能不上');
      } else if (injuryCount >= 1) {
        details.add('傷兵 $injuryCount 人（可能缺打者）');
      }
    } else if (sport == SportType.basketball) {
      // 籃球：依傷兵數按優先度列出位置
      if (injuryCount == 1) {
        details.add('缺控衛或得分後衛');
      } else if (injuryCount == 2) {
        details.add('缺場上雙星');
      } else {
        details.add('缺傷 $injuryCount 主力');
      }
    } else {
      // 足球：依傷兵數按優先度列出位置
      if (injuryCount == 1) {
        details.add('缺主力前鋒或邊鋒');
      } else if (injuryCount == 2) {
        details.add('缺前鋒 + 邊鋒/中場');
      } else {
        details.add('缺傷 $injuryCount 主力');
      }
    }
    
    // 組合警示訊息
    return '⚠️ $favoredTeam ${details.join('、')} → 進攻削減 ~$penaltyPct%，$underdogTeam 爆冷風險↑';
  }

  // ── 泊松精確分佈模型 ─────────────────────────────────────────────

  /// Poisson 機率質量函數 P(X=k) = e^(-λ) × λ^k / k!
  /// 使用 log 空間計算避免溢位
  static double _poissonPMF(double lambda, int k) {
    if (lambda <= 0) return k == 0 ? 1.0 : 0.0;
    double logP = -lambda + k * log(lambda);
    for (int i = 2; i <= k; i++) {
      logP -= log(i.toDouble());
    }
    return exp(logP);
  }

  /// 泊松精確分佈模型：解析計算主勝/平/客勝精確機率
  ///
  /// 原理：P(主=h, 客=a) = P_poisson(h; λH) × P_poisson(a; λA)
  /// 對所有可能比分 (h, a) 聯合分佈累加 → 精確的勝/平/敗機率
  ///
  /// 足球/棒球：直接計算（低分賽事，Poisson 最適合）
  /// 籃球：λ≈110，採 Normal 近似 N(λ, √λ)
  static _PoissonExactResult _poissonExact(
    double homeLambda,
    double awayLambda,
    SportType sport,
  ) {
    // 籃球：λ 太大（~100-140），Poisson PMF 計算不切實際
    // 改用 Normal 近似 + Φ(z) 累積分佈
    if (sport == SportType.basketball) {
      final diff = homeLambda - awayLambda;
      final stdDev = sqrt(homeLambda + awayLambda);
      if (stdDev <= 0) {
        return const _PoissonExactResult(
          homeWinProb: 0.5, drawProb: 0.0, awayWinProb: 0.5,
          mostLikelyHomeScore: 100, mostLikelyAwayScore: 100,
        );
      }
      final z = diff / stdDev;
      // Logistic sigmoid 近似 Φ(z)：精度足夠（誤差 < 1%）
      final homeWinProb = (1.0 / (1.0 + exp(-1.7 * z))).clamp(0.01, 0.99);
      return _PoissonExactResult(
        homeWinProb: homeWinProb,
        drawProb: 0.0,
        awayWinProb: 1.0 - homeWinProb,
        mostLikelyHomeScore: homeLambda.round(),
        mostLikelyAwayScore: awayLambda.round(),
      );
    }

    // 足球/棒球：精確 Poisson 聯合分佈
    final maxGoals = sport == SportType.baseball ? 15 : 8;

    // 預計算各分數的 Poisson PMF
    final homeProbs = List.generate(maxGoals + 1, (k) => _poissonPMF(homeLambda, k));
    final awayProbs = List.generate(maxGoals + 1, (k) => _poissonPMF(awayLambda, k));

    double homeWin = 0, drawSum = 0, awayWin = 0;
    int bestH = 0, bestA = 0;
    double bestProb = 0;

    for (int h = 0; h <= maxGoals; h++) {
      for (int a = 0; a <= maxGoals; a++) {
        final jointProb = homeProbs[h] * awayProbs[a];
        if (h > a) {
          homeWin += jointProb;
        } else if (h == a) {
          drawSum += jointProb;
        } else {
          awayWin += jointProb;
        }
        if (jointProb > bestProb) {
          bestProb = jointProb;
          bestH = h;
          bestA = a;
        }
      }
    }

    // 正規化（尾部機率忽略不計）
    final totalProb = homeWin + drawSum + awayWin;
    if (totalProb > 0) {
      homeWin /= totalProb;
      drawSum /= totalProb;
      awayWin /= totalProb;
    }

    // 棒球無平局 → 平局機率重新分配
    if (sport == SportType.baseball) {
      final redistrib = drawSum / 2;
      homeWin += redistrib;
      awayWin += redistrib;
      drawSum = 0;
    }

    return _PoissonExactResult(
      homeWinProb: homeWin,
      drawProb: drawSum,
      awayWinProb: awayWin,
      mostLikelyHomeScore: bestH,
      mostLikelyAwayScore: bestA,
    );
  }

  double _buildConfidence({
    required double homeStrength,
    required double awayStrength,
    double basketballSpreadConfidence = 0.0, // 新增籃球勝分差信心度
    required double modelAgreement,
    required bool hasValueBet,
  }) {
    // 1. 實力差距 (Edge): 基礎信心
    final edge = (homeStrength - awayStrength).abs();
    
    // 2. 模型共識 (Consensus): 
    // 如果 Poisson 分佈與 MC 隨機模擬結果愈接近，代表數學模型收斂，信心增加
    final consensusBonus = (modelAgreement - 0.5) * 0.3;

    // 3. 價值空間 (Value Bet):
    // 如果模型計算出的機率遠高於賭盤機率，代表這是高勝率低風險區域
    final valueBonus = hasValueBet ? 0.08 : 0.0;
    // 籃球勝分差信心度加成
    final spreadBonus = basketballSpreadConfidence * 0.05;

    return (0.45 + (edge * 0.35) + consensusBonus + valueBonus + spreadBonus).clamp(0.50, 0.96);
  }

  String _buildSummary({
    required MatchFixture fixture,
    required int homeScore,
    required int awayScore,
    required double confidence,
  }) {
    final confidenceLabel = confidence >= 0.78
        ? '高信心'
        : confidence >= 0.66
            ? '中高信心'
            : '保守觀察';

    switch (fixture.sport) {
      case SportType.football:
        // 足球：可能平局
        final resultLabel = homeScore == awayScore
            ? '平局格局'
            : homeScore > awayScore
                ? '「${fixture.homeTeam}」主勝機率较高'
                : '「${fixture.awayTeam}」客勝機率较高';
        return '$resultLabel，預估比分 $homeScore:$awayScore，語氣屬於$confidenceLabel區間。';

      case SportType.baseball:
        // 棒球：無平局，強調投打概念
        final resultLabel = homeScore > awayScore
            ? '「${fixture.homeTeam}」主隊占優，投手表現預計將是關鍵'
            : '「${fixture.awayTeam}」打擊由強，客隊勝率展望較佳';
        return '$resultLabel，預估比分 $homeScore:$awayScore，棒球無平局規則（延長局決勝），此預測屬於$confidenceLabel。';

      case SportType.basketball:
        // 籃球：高分局，無平局
        final resultLabel = homeScore > awayScore
            ? '盤口隱含「${fixture.homeTeam}」主勝機率較高，預估取勝'
            : '盤口隱含「${fixture.awayTeam}」客勝機率較高，預估取勝';
        final totalScore = homeScore + awayScore;
        final paceLabel = totalScore >= 230 ? '大分局' : totalScore >= 210 ? '中分局' : '小分局';
        return '$resultLabel，預估比分 $homeScore:$awayScore（場均總分$totalScore，屬於$paceLabel），籃球無平局（延長賽決勝）。';
    }
  }

  List<String> _buildKeyFactors({
    required MatchFixture fixture,
    required double homeStrength,
    required double awayStrength,
    required _MarketProbabilities probabilities,
    String? injuryWarning,
    double ensembleHome = 0.0,
    double ensembleDraw = 0.0,
    double ensembleAway = 0.0,
    double mcWeight = 0.5,
    double poissonWeight = 0.5,
    double marketMovement = 0.0,
    double overround = 0.0,
    _BayesianPosterior? bayes,
    double homeValueEdge = 0.0,
    double awayValueEdge = 0.0,
    bool hasValueBetSignal = false,
    double marketHomeExp = 0.0,
    double marketAwayExp = 0.0,
    double marketVolumePressure = 0.0,
    bool isDefensiveSwitchLikely = false,
    int predictedHomeScore = 0,
    String adaptiveStrategy = 'strategy_b',
  }) {
    final factors = <String>[];

    // 自適應策略標記（供 SelfLearningService 讀取，不顯示給用戶）
    factors.add('__adaptive_strategy:$adaptiveStrategy');

    // 傷兵警示（若存在，排在最前面）
    if (injuryWarning != null) {
      factors.add(injuryWarning);
    }

    // ── 資金壓力與管理邏輯 ──
    if (marketVolumePressure > 0.15) {
      factors.add('💰 資金流向警示：偵測到大量投注金額湧入盤口，賠率已產生實質位移，AI 已同步修正比分權重。');
    }

    if (isDefensiveSwitchLikely && fixture.sport == SportType.football) {
      final favoredTeam = probabilities.homeProbability >= probabilities.awayProbability
          ? fixture.homeTeam
          : fixture.awayTeam;
      factors.add('🛡️ 比賽管理模式：AI 判定「$favoredTeam」取得兩球領先後極大機率轉向消極進攻，已壓低大勝比分之機率。');
    }

    // ── 莊家的答案 (Market Logic) ──
    factors.add('🏛️ 莊家原始預期：${fixture.homeTeam} ${marketHomeExp.toStringAsFixed(1)} : ${marketAwayExp.toStringAsFixed(1)} ${fixture.awayTeam}');
    final homeDiff = predictedHomeScore - marketHomeExp;
    if (homeDiff.abs() > 0.5) {
      factors.add('🤖 AI 觀點：${homeDiff > 0 ? "看好" : "看淡"} ${fixture.homeTeam} 攻擊力，相較盤口修正了 ${homeDiff.abs().toStringAsFixed(1)} 分。');
    }

    // ── 特徵工程：公平賠率（去除抽水）────────────────────────────
    if (overround > 0.005) {
      final fH = fixture.odds.fairHomeProb;
      final fD = fixture.odds.fairDrawProb;
      final fA = fixture.odds.fairAwayProb;
      final isFootball = fixture.sport == SportType.football;
      final fairDesc = isFootball
          ? '主勝 ${(fH * 100).toStringAsFixed(0)}% / 平局 ${(fD * 100).toStringAsFixed(0)}% / 客勝 ${(fA * 100).toStringAsFixed(0)}%'
          : '主勝 ${(fH * 100).toStringAsFixed(0)}% / 客勝 ${(fA * 100).toStringAsFixed(0)}%';
      factors.add('📊 公平機率（去除 ${(overround * 100).toStringAsFixed(1)}% 莊家抽水）：$fairDesc');
    }

    // ── 特徵工程：盤口變動方向（Market Movement）──────────────────
    if (marketMovement.abs() > 0.03) {
      final direction = marketMovement > 0 ? '主勝' : '客勝';
      final pctStr = (marketMovement.abs() * 100).toStringAsFixed(1);
      if (fixture.odds.hasReverseLineMovement) {
        factors.add('🔄 逆向盤口訊號：盤口朝「$direction」方向移動 $pctStr%，但初盤看好另一方 → 聰明錢(Smart Money)可能介入，模型已微調 λ。');
      } else {
        factors.add('📈 盤口變動：即時盤比初盤朝「$direction」方向偏移 $pctStr%，市場態度一致。');
      }
    }

    // 盤口強方
    if (homeStrength >= awayStrength) {
      factors.add(
        '「${fixture.homeTeam}」市場隱含勝率較佳，主勝賠率 ${fixture.odds.homeWin.toStringAsFixed(2)}。',
      );
    } else {
      factors.add(
        '「${fixture.awayTeam}」客勝賠率 ${fixture.odds.awayWin.toStringAsFixed(2)}，市場相對看好。',
      );
    }

    // 運動項目專屬因素
    switch (fixture.sport) {
      case SportType.football:
        if (probabilities.drawProbability >= 0.28) {
          factors.add('足球盤口顯示和局機率不低（${(probabilities.drawProbability * 100).toStringAsFixed(0)}%），比分差距預估不會拉開。');
        } else {
          factors.add('和局機率相對低，預估將有一方明顯勝出。');
        }
        if (fixture.odds.overOdds < fixture.odds.underOdds) {
          factors.add('盤口共 ${fixture.odds.overLine.toStringAsFixed(1)} 倡向大分，預期兩隊可能共同投進進攻足球。');
        } else {
          factors.add('盤口對小分有小幅偏好，預期防守成為關鍵。');
        }
        // 足球防守結構模型因素
        final homeDef = fixture.homeForm.averageConceded;
        final awayDef = fixture.awayForm.averageConceded;
        if (homeDef < 1.0) {
          factors.add('「${fixture.homeTeam}」場均失球僅 ${homeDef.toStringAsFixed(1)}，防守結構堅固，壓縮客隊進攻空間。');
        } else if (awayDef < 1.0) {
          factors.add('「${fixture.awayTeam}」場均失球僅 ${awayDef.toStringAsFixed(1)}，防守結構堅固，壓縮主隊進攻空間。');
        }
        // 歷史對戰數據因素（H2H）
        final h2hTotalKF = fixture.h2hHomeWins + fixture.h2hAwayWins + fixture.h2hDraws;
        if (h2hTotalKF >= 3) {
          final h2hWinner = fixture.h2hHomeWins > fixture.h2hAwayWins
              ? '${fixture.homeTeam}（主隊）'
              : fixture.h2hAwayWins > fixture.h2hHomeWins
                  ? '${fixture.awayTeam}（客隊）'
                  : '雙方平分秋色';
          factors.add('⚔️ H2H 近 $h2hTotalKF 場：${fixture.homeTeam} ${fixture.h2hHomeWins}勝 / ${fixture.h2hDraws}平 / ${fixture.h2hAwayWins}勝 ${fixture.awayTeam}，歷史佔優：$h2hWinner。');
          if (fixture.h2hAvgGoals > 0.3) {
            final goalsDesc = fixture.h2hAvgGoals < 2.0 ? '低進球對決' : fixture.h2hAvgGoals < 3.0 ? '中等進球' : '高進球大戰';
            factors.add('📐 H2H 歷史平均總進球 ${fixture.h2hAvgGoals.toStringAsFixed(1)} 球/場（$goalsDesc），已用於校準本場比分預測。');
          }
        }
        // 近期得失分統計（有真實數據時）
        if (fixture.homeForm.hasRealStats) {
          factors.add('📈 近期數據 ${fixture.homeTeam}：場均得 ${fixture.homeForm.averageScored.toStringAsFixed(1)} / 失 ${fixture.homeForm.averageConceded.toStringAsFixed(1)}；${fixture.awayTeam}：場均得 ${fixture.awayForm.averageScored.toStringAsFixed(1)} / 失 ${fixture.awayForm.averageConceded.toStringAsFixed(1)}。');
        }
        break;

      case SportType.baseball:
        // 棒球：強調先發投手、打擊率、延長局
        final homeImplied = (probabilities.homeProbability * 100).toStringAsFixed(0);
        final awayImplied = (probabilities.awayProbability * 100).toStringAsFixed(0);
        factors.add('盤口隱含主勝機率 $homeImplied%，客勝機率 $awayImplied%，以此為比分退算依據。');
        // ── 球場風險警示 ─────────────────────────────────────────────
        final parkF = _getParkFactor(fixture.homeTeam);
        if (parkF >= 1.15) {
          factors.add('⚠️ 高分球場警示：${fixture.homeTeam}主場(Park Factor ${parkF.toStringAsFixed(2)})大幅提升雙方得分，讓分盤口需謹慎，客隊讓分風險極高。');
        } else if (parkF >= 1.06) {
          factors.add('注意：${fixture.homeTeam}主場為打者友善球場(Park Factor ${parkF.toStringAsFixed(2)})，大分機率偏高，客隊讓分需多加考量。');
        }
        if (fixture.odds.overLine > 9.0) {
          factors.add('大小分盤口 ${fixture.odds.overLine.toStringAsFixed(1)} 偏高，莊家預期兩隊進攻火力強，預測傾向大分。');
        } else if (fixture.odds.overLine > 8.5) {
          factors.add('大小分盤口 ${fixture.odds.overLine.toStringAsFixed(1)}，這場合兩隊打擊線皆佳，大分局可能性較高。');
        } else if (fixture.odds.overLine > 0) {
          factors.add('大小分盤口 ${fixture.odds.overLine.toStringAsFixed(1)}，預期投手占優勢，低分結果機率屬「投手戰」。');
        }
        // 先發投手 ERA + WHIP + K/9 因素
        if (fixture.homeProbableEra.isNotEmpty && fixture.homeProbablePitcher.isNotEmpty) {
          final eraVal = double.tryParse(fixture.homeProbableEra);
          if (eraVal != null) {
            final quality = eraVal < 3.0 ? '優秀' : eraVal < 4.0 ? '中上' : '平均';
            final whipStr = fixture.homeProbableWhip.isNotEmpty ? '／WHIP ${fixture.homeProbableWhip}' : '';
            factors.add('主隊先發「${fixture.homeProbablePitcher}」ERA ${fixture.homeProbableEra}$whipStr（$quality），投手模型已套用。');
            final k9Val = double.tryParse(fixture.homeProbableK9);
            if (k9Val != null && k9Val > 0) {
              final k9Quality = k9Val >= 9.0 ? '三振型' : k9Val >= 7.0 ? '壓制型' : '滾地球型';
              factors.add('其三振率 K/9 ${fixture.homeProbableK9} ($k9Quality)，對手打線壓力增加。');
            }
          }
        }
        if (fixture.awayProbableEra.isNotEmpty && fixture.awayProbablePitcher.isNotEmpty) {
          final eraVal = double.tryParse(fixture.awayProbableEra);
          if (eraVal != null) {
            final quality = eraVal < 3.0 ? '優秀' : eraVal < 4.0 ? '中上' : '平均';
            final whipStr = fixture.awayProbableWhip.isNotEmpty ? '／WHIP ${fixture.awayProbableWhip}' : '';
            factors.add('客隊先發「${fixture.awayProbablePitcher}」ERA ${fixture.awayProbableEra}$whipStr（$quality），投手模型已套用。');
            final k9Val = double.tryParse(fixture.awayProbableK9);
            if (k9Val != null && k9Val > 0) {
              final k9Quality = k9Val >= 9.0 ? '三振型' : k9Val >= 7.0 ? '壓制型' : '滾地球型';
              factors.add('其三振率 K/9 ${fixture.awayProbableK9} ($k9Quality)，對手打線壓力增加。');
            }
          }
        }
        factors.add('棒球無平局：常規局平手進入延長（第10局起），盤口賠率已含此預期。');
        break;

      case SportType.basketball:
        // 籃球：強調進攻效率、三分球、節奏
        final totalLine = fixture.odds.overLine > 0 ? fixture.odds.overLine : 226.0;
        if (fixture.odds.overOdds < fixture.odds.underOdds) {
          factors.add('盤口大小分線 ${totalLine.toStringAsFixed(1)}，偏向大分，預期兩隊進攻效率高、節奏快。');
        } else {
          factors.add('盤口大小分線 ${totalLine.toStringAsFixed(1)}，偏向小分，其中一隊防守高壓期參考抗拒率。');
        }
        factors.add('籃球無平局：常規賽平手進入加時（5分鐘），盤口賠率已含此預期。');
        final bHomeImplied = (probabilities.homeProbability * 100).toStringAsFixed(0);
        final bAwayImplied = (probabilities.awayProbability * 100).toStringAsFixed(0);
        factors.add('盤口隱含主勝 $bHomeImplied% / 客勝 $bAwayImplied%，搭配大小分線退算得分分布。');
        // NBA 球星動能模型因素
        final homeMom = fixture.homeForm.momentumScore;
        final awayMom = fixture.awayForm.momentumScore;
        if (homeMom >= 8.5) {
          factors.add('「${fixture.homeTeam}」動能指數 ${homeMom.toStringAsFixed(1)} 分（球星狀態熱），進攻估算已上調。');
        } else if (awayMom >= 8.5) {
          factors.add('「${fixture.awayTeam}」動能指數 ${awayMom.toStringAsFixed(1)} 分（球星狀態熱），進攻估算已上調。');
        }
        // PER 因素
        final homePer = fixture.homeForm.playerEfficiencyRating;
        final awayPer = fixture.awayForm.playerEfficiencyRating;
        if (homePer >= 18.0) factors.add('「${fixture.homeTeam}」球員效率值 PER ${homePer.toStringAsFixed(1)}（高於聯盟平均），進攻端表現穩定。');
        if (awayPer >= 18.0) factors.add('「${fixture.awayTeam}」球員效率值 PER ${awayPer.toStringAsFixed(1)}（高於聯盟平均），進攻端表現穩定。');
        break;
    }

    // ── B2B 疲勞警示 ──────────────────────────────────────────────
    if (fixture.homeIsB2B) {
      factors.add('⚡ ${fixture.homeTeam} 連兩天出賽（B2B），體能可能下滑 3-5%，特別注意第四節表現。');
    }
    if (fixture.awayIsB2B) {
      factors.add('⚡ ${fixture.awayTeam} 連兩天出賽（B2B），長途客場奔波體能消耗更大。');
    }

    // ── 滾動視窗偏離警示 ──────────────────────────────────────────
    final homeL3 = fixture.homeForm.last3AvgScored;
    if (homeL3 != null && fixture.homeForm.averageScored > 0) {
      final div = (homeL3 - fixture.homeForm.averageScored) / fixture.homeForm.averageScored;
      if (div < -0.12) {
        factors.add('📉 ${fixture.homeTeam} 近3場得分（${homeL3.toStringAsFixed(1)}）較全季均值顯著下滑，短線狀態需警惕。');
      } else if (div > 0.12) {
        factors.add('📈 ${fixture.homeTeam} 近3場得分（${homeL3.toStringAsFixed(1)}）熱狀態，短線超越全季均值。');
      }
    }
    final awayL3 = fixture.awayForm.last3AvgScored;
    if (awayL3 != null && fixture.awayForm.averageScored > 0) {
      final div = (awayL3 - fixture.awayForm.averageScored) / fixture.awayForm.averageScored;
      if (div < -0.12) {
        factors.add('📉 ${fixture.awayTeam} 近3場得分（${awayL3.toStringAsFixed(1)}）顯著低於全季均值，短線疲弱。');
      } else if (div > 0.12) {
        factors.add('📈 ${fixture.awayTeam} 近3場進攻火熱，狀態明顯優於賽季平均。');
      }
    }

    // 賠率波動提示
    final em = fixture.odds.errorMargin;
    if (em >= 0.05) {
      final desc = em >= 0.30
          ? '⚠️ 賠率出現異常波動（${(em * 100).toStringAsFixed(0)}%），判斷為大量跟風資金。模型已強力修正回初盤基準。'
          : em >= 0.15
              ? 'ℹ️ 賠率顯著漂移（${(em * 100).toStringAsFixed(0)}%），可能含跟風成分。模型已混合初盤機率修正。'
              : 'ℹ️ 賠率有輕微波動（${(em * 100).toStringAsFixed(0)}%），模型已微調。';
      factors.add(desc);
    }

    // ── 多模型融合（Model Ensemble）結果 ────────────────────────
    if (ensembleHome > 0 || ensembleAway > 0) {
      final mcPct = (mcWeight * 100).toInt();
      final ppPct = (poissonWeight * 100).toInt();
      final isFootball = fixture.sport == SportType.football;
      final ensDesc = isFootball
          ? '主勝 ${(ensembleHome * 100).toStringAsFixed(0)}% / 平 ${(ensembleDraw * 100).toStringAsFixed(0)}% / 客勝 ${(ensembleAway * 100).toStringAsFixed(0)}%'
          : '主勝 ${(ensembleHome * 100).toStringAsFixed(0)}% / 客勝 ${(ensembleAway * 100).toStringAsFixed(0)}%';
      factors.add('🔬 多模型融合：MC模擬($mcPct%) × 泊松精確($ppPct%) → $ensDesc');
    }

    if (bayes != null) {
      final bDesc = fixture.sport == SportType.football
          ? '主 ${(bayes.homeProbability * 100).toStringAsFixed(0)}% / 平 ${(bayes.drawProbability * 100).toStringAsFixed(0)}% / 客 ${(bayes.awayProbability * 100).toStringAsFixed(0)}%'
          : '主 ${(bayes.homeProbability * 100).toStringAsFixed(0)}% / 客 ${(bayes.awayProbability * 100).toStringAsFixed(0)}%';
      factors.add('🧠 Bayesian 更新（先驗+即時證據）→ $bDesc');
    }

    final bestEdge = max(homeValueEdge, awayValueEdge);
    if (hasValueBetSignal) {
      factors.add('✅ 價值下注訊號：模型機率高於莊家隱含機率 ${(bestEdge * 100).toStringAsFixed(1)}%，可考慮出手。');
    } else {
      factors.add('⏸️ 無明顯價值差：模型與莊家隱含機率差距不足（<6%），建議觀望。');
    }

    return factors;
  }

  /// 滾動式數據加權（Rolling Windows）
  /// 偏離度大時重壓短線，正常時三段平衡加權
  static double _rollingWeighted(TeamForm form, {bool conceded = false}) {
    final season = conceded ? form.averageConceded : form.averageScored;
    if (season <= 0) return season;
    final last3 = conceded ? form.last3AvgConceded : form.last3AvgScored;
    final last10 = conceded ? form.last10AvgConceded : form.last10AvgScored;
    if (last3 == null && last10 == null) return season;
    final l3 = last3 ?? season;
    final l10 = last10 ?? season;
    final divergence = (l3 - season).abs() / season;
    if (divergence > 0.10) {
      // 大偏離（>10%）：重壓短線 70% + 全季 30%
      return l3 * 0.70 + season * 0.30;
    } else {
      // 常態：近3場 40% + 近10場 35% + 全季 25%
      return l3 * 0.40 + l10 * 0.35 + season * 0.25;
    }
  }

}

/// 市場概率計算
class _MarketProbabilities {
  const _MarketProbabilities({
    required this.homeProbability,
    required this.drawProbability,
    required this.awayProbability,
    required this.drawAdjustedHomeProbability,
    required this.drawAdjustedAwayProbability,
  });

  factory _MarketProbabilities.fromOdds(MatchFixture fixture) {
    final home = 1 / fixture.odds.homeWin;
    final draw = fixture.odds.draw > 0 ? 1 / fixture.odds.draw : 0.0;
    final away = 1 / fixture.odds.awayWin;
    final total = home + draw + away;

    var normalizedHome = home / total;
    var normalizedDraw = draw / total;
    var normalizedAway = away / total;

    // ── 盲目跟風過濾（error_margin 修正）────────────────────────
    // 若即時盤與初盤的隱含機率漂移 > 5%，將部分機率混回初盤數值，
    // 防止系統過度追蹤由散戶盲目跟風引起的賠率波動噪音。
    // blendWeight: 0% (em≤0.05) → 最高 40% (em≥0.18)
    final em = fixture.odds.errorMargin;
    if (em > 0.05) {
      final oh = 1 / fixture.odds.openingHomeWin;
      final od = fixture.odds.openingDraw > 0 ? 1 / fixture.odds.openingDraw : 0.0;
      final oa = 1 / fixture.odds.openingAwayWin;
      final ot = oh + od + oa;
      final blendWeight = ((em - 0.05) * 3.0).clamp(0.0, 0.40);
      normalizedHome = normalizedHome * (1 - blendWeight) + (oh / ot) * blendWeight;
      normalizedDraw = normalizedDraw * (1 - blendWeight) + (od / ot) * blendWeight;
      normalizedAway = normalizedAway * (1 - blendWeight) + (oa / ot) * blendWeight;
    }

    final decisionTotal = normalizedHome + normalizedAway;
    return _MarketProbabilities(
      homeProbability: normalizedHome,
      drawProbability: normalizedDraw,
      awayProbability: normalizedAway,
      drawAdjustedHomeProbability: decisionTotal == 0
          ? 0.5
          : normalizedHome / decisionTotal,
      drawAdjustedAwayProbability: decisionTotal == 0
          ? 0.5
          : normalizedAway / decisionTotal,
    );
  }

  final double homeProbability;
  final double drawProbability;
  final double awayProbability;
  final double drawAdjustedHomeProbability;
  final double drawAdjustedAwayProbability;
}

/// 運動類型概況
class _SportProfile {
  const _SportProfile({
    required this.baseScorePerSide,
    required this.baseTotalScore,
    required this.minimumScore,
    required this.volatility,
  });

  factory _SportProfile.forType(SportType sport) {
    switch (sport) {
      case SportType.football:
        // 足球：平均每隊進球 ~1.35，場均總進球 ~2.7，和局約佔 25-28%
        return const _SportProfile(
          baseScorePerSide: 1.35,
          baseTotalScore: 2.7,
          minimumScore: 0,
          volatility: 0.35,
        );
      case SportType.baseball:
        // MLB 棒球：2024-25 場均每隊得分 ~4.3，無和局（延長局決勝）
        // 得分範圍通常 0-15，強投對決低分，爆打可達 15+
        return const _SportProfile(
          baseScorePerSide: 4.3,
          baseTotalScore: 8.6,
          minimumScore: 0,
          volatility: 1.2,
        );
      case SportType.basketball:
        // NBA 籃球：2024-25 場均每隊得分 ~113，無和局（延長賽決勝）
        // 得分範圍通常 95-135 per team
        return const _SportProfile(
          baseScorePerSide: 113.0,
          baseTotalScore: 226.0,
          minimumScore: 85,
          volatility: 8.0,
        );
    }
  }

  final double baseScorePerSide;
  final double baseTotalScore;
  final int minimumScore;
  final double volatility;
}

// ============================================
// 💾 存檔管理相關類別
// ============================================

/// 已結束比賽的存檔模型
class ArchivedMatch {
  final String id;
  final MatchFixture fixture;
  final int homeScore;
  final int awayScore;
  final DateTime completionTime;
  final String status; // 'completed', 'postponed', 'cancelled'
  final Map<String, dynamic> seasonStats;

  ArchivedMatch({
    required this.id,
    required this.fixture,
    required this.homeScore,
    required this.awayScore,
    required this.completionTime,
    required this.status,
    this.seasonStats = const {},
  });

  bool get isWin => homeScore > awayScore;
  bool get isDraw => homeScore == awayScore;
  bool get isLoss => homeScore < awayScore;
  
  String get scoreLine => '$homeScore - $awayScore';
  
  String get formattedDate => DateFormat('yyyy-MM-dd').format(completionTime);
  
  String get formattedTime => DateFormat('HH:mm').format(completionTime);

  Map<String, dynamic> toJson() => {
    'id': id,
    'fixture_id': fixture.id,
    'home_team': fixture.homeTeam,
    'away_team': fixture.awayTeam,
    'league': fixture.league,
    'sport': fixture.sport.toString(),
    'home_score': homeScore,
    'away_score': awayScore,
    'completion_time': completionTime.toIso8601String(),
    'status': status,
    'season_stats': seasonStats,
  };

  factory ArchivedMatch.fromJson(Map<String, dynamic> json, MatchFixture fixture) {
    return ArchivedMatch(
      id: json['id'] as String,
      fixture: fixture,
      homeScore: json['home_score'] as int,
      awayScore: json['away_score'] as int,
      completionTime: DateTime.parse(json['completion_time'] as String),
      status: json['status'] as String? ?? 'completed',
      seasonStats: json['season_stats'] as Map<String, dynamic>? ?? {},
    );
  }
}

/// 比賽存檔管理
class _MatchArchiveService {
  final List<ArchivedMatch> _archive = [];

  /// 將比賽標記為完成並存檔
  void archiveMatch({
    required MatchFixture fixture,
    required int homeScore,
    required int awayScore,
    String status = 'completed',
  }) {
    final archivedMatch = ArchivedMatch(
      id: 'archive_${fixture.id}_${DateTime.now().millisecondsSinceEpoch}',
      fixture: fixture,
      homeScore: homeScore,
      awayScore: awayScore,
      completionTime: DateTime.now(),
      status: status,
    );

    _archive.add(archivedMatch);
    _printArchiveLog('已存檔比賽: ${fixture.homeTeam} vs ${fixture.awayTeam} (${archivedMatch.scoreLine})');
  }

  /// 獲取特定日期的存檔比賽
  List<ArchivedMatch> getArchiveByDate(DateTime date) {
    final dateOnly = DateTime(date.year, date.month, date.day);
    return _archive.where((match) {
      final completionDate = DateTime(
        match.completionTime.year,
        match.completionTime.month,
        match.completionTime.day,
      );
      return completionDate == dateOnly;
    }).toList();
  }

  /// 獲取特定聯賽的存檔
  List<ArchivedMatch> getArchiveByLeague(String league) {
    return _archive.where((match) => match.fixture.league == league).toList();
  }

  /// 獲取最近N場已結束的比賽
  List<ArchivedMatch> getRecentArchive({int limit = 10}) {
    final sorted = _archive.toList()..sort((a, b) => b.completionTime.compareTo(a.completionTime));
    return sorted.take(limit).toList();
  }

  /// 獲取某支球隊的所有比賽記錄
  List<ArchivedMatch> getTeamArchive(String teamName) {
    return _archive.where((match) {
      return match.fixture.homeTeam == teamName || match.fixture.awayTeam == teamName;
    }).toList();
  }

  /// 計算球隊的戰績統計
  Map<String, dynamic> getTeamStats(String teamName) {
    final teamMatches = getTeamArchive(teamName);
    
    int wins = 0;
    int losses = 0;
    int draws = 0;
    int totalGoalsFor = 0;
    int totalGoalsAgainst = 0;

    for (final match in teamMatches) {
      if (match.fixture.homeTeam == teamName) {
        totalGoalsFor += match.homeScore;
        totalGoalsAgainst += match.awayScore;
        if (match.isWin) {
          wins++;
        } else if (match.isDraw) {
          draws++;
        } else {
          losses++;
        }
      } else {
        totalGoalsFor += match.awayScore;
        totalGoalsAgainst += match.homeScore;
        if (match.isLoss) {
          wins++;
        } else if (match.isDraw) {
          draws++;
        } else {
          losses++;
        }
      }
    }

    return {
      'team_name': teamName,
      'total_matches': teamMatches.length,
      'wins': wins,
      'losses': losses,
      'draws': draws,
      'win_rate': teamMatches.isEmpty ? 0.0 : wins / teamMatches.length,
      'goals_for': totalGoalsFor,
      'goals_against': totalGoalsAgainst,
      'goal_difference': totalGoalsFor - totalGoalsAgainst,
      'average_goals_for': teamMatches.isEmpty ? 0.0 : totalGoalsFor / teamMatches.length,
      'average_goals_against': teamMatches.isEmpty ? 0.0 : totalGoalsAgainst / teamMatches.length,
    };
  }

  /// 獲取聯賽排行榜
  List<Map<String, dynamic>> getLeagueStandings(String league) {
    final leagueMatches = getArchiveByLeague(league);
    final teams = <String>{};
    
    for (final match in leagueMatches) {
      teams.add(match.fixture.homeTeam);
      teams.add(match.fixture.awayTeam);
    }

    final standings = teams.map((team) => getTeamStats(team)).toList();
    standings.sort((a, b) {
      final aPoints = a['wins'] * 3 + a['draws'];
      final bPoints = b['wins'] * 3 + b['draws'];
      return bPoints.compareTo(aPoints);
    });

    return standings;
  }

  /// 清空所有存檔
  void clearArchive() {
    _archive.clear();
    _printArchiveLog('已清空所有存檔');
  }

  /// 獲取所有存檔
  List<ArchivedMatch> getAllArchive() => List.unmodifiable(_archive);

  /// 獲取存檔統計
  Map<String, dynamic> getArchiveStats() {
    return {
      'total_archived_matches': _archive.length,
      'leagues_count': _archive.map((m) => m.fixture.league).toSet().length,
      'teams_count': {
        'home': _archive.map((m) => m.fixture.homeTeam).toSet().length,
        'away': _archive.map((m) => m.fixture.awayTeam).toSet().length,
      },
      'oldest_archive': _archive.isEmpty ? null : _archive.reduce((a, b) => 
        a.completionTime.compareTo(b.completionTime) < 0 ? a : b).formattedDate,
      'newest_archive': _archive.isEmpty ? null : _archive.reduce((a, b) => 
        a.completionTime.compareTo(b.completionTime) > 0 ? a : b).formattedDate,
    };
  }

  /// 打印存檔日誌
  void _printArchiveLog(String message) {
    debugPrint('[MatchArchive] $message - 當前存檔數: ${_archive.length}');
  }

  /// 導出存檔為JSON
  List<Map<String, dynamic>> exportToJson() {
    return _archive.map((match) => match.toJson()).toList();
  }
}

// ============================================
// 📊 模擬數據服務
// ============================================

class _MockDataService {
  const _MockDataService();

  List<MatchFixture> getTodaysFixtures() {
    final now = DateTime.now();
    final dateTag = '${now.year}${now.month.toString().padLeft(2,'0')}${now.day.toString().padLeft(2,'0')}';
    // 日期驅動的每日微波動：讓同一對陣每天呈現不同狀態
    final d = now.day;
    final soccerDrift  = (d % 7 - 3) * 0.07;   // ±0.21 goals
    final baseballDrift = (d % 9 - 4) * 0.15;  // ±0.60 runs
    final nbaDrift      = (d % 11 - 5) * 1.2;  // ±6.0 pts
    final cbaDrift      = (d % 11 - 5) * 1.0;  // ±5.0 pts

    debugPrint('📊 生成新模擬數據 - 當前時間: ${now.toIso8601String()}');

    return [
      MatchFixture(
        id: 'soccer-j1-001-$dateTag',
        sport: SportType.football,
        league: '日本職業足球甲級聯賽',
        startTime: DateTime(now.year, now.month, now.day, 18, 0),
        homeTeam: '橫濱水手',
        awayTeam: '川崎前鋒',
        homeForm: TeamForm(
          teamName: '橫濱水手',
          lastFiveResults: const ['W', 'D', 'W', 'L', 'W'],
          averageScored: (1.8 + soccerDrift).clamp(1.0, 2.8),
          averageConceded: (1.1 - soccerDrift * 0.5).clamp(0.6, 1.8),
          injuries: 1,
          momentumScore: 7.8,
        ),
        awayForm: TeamForm(
          teamName: '川崎前鋒',
          lastFiveResults: const ['D', 'W', 'L', 'W', 'D'],
          averageScored: (1.5 - soccerDrift * 0.6).clamp(0.8, 2.4),
          averageConceded: (1.3 + soccerDrift * 0.4).clamp(0.7, 2.0),
          injuries: 2,
          momentumScore: 6.9,
        ),
        odds: const OddsSnapshot(
          homeWin: 2.08,
          draw: 3.35,
          awayWin: 3.10,
          overLine: 2.5,
          overOdds: 1.87,
          underOdds: 1.93,
        ),
        analystNote: '台灣市場熱門對戰，主隊主場節奏積極，但川崎反擊效率仍具威脅。',
      ),
      MatchFixture(
        id: 'baseball-cpbl-001-$dateTag',
        sport: SportType.baseball,
        league: '中華職棒',
        startTime: DateTime(now.year, now.month, now.day, 18, 35),
        homeTeam: '中信兄弟',
        awayTeam: '樂天桃猿',
        homeForm: TeamForm(
          teamName: '中信兄弟',
          lastFiveResults: const ['W', 'W', 'L', 'W', 'W', 'L', 'W', 'W', 'L', 'W'],
          averageScored: (5.6 + baseballDrift).clamp(3.5, 7.5),
          averageConceded: (3.9 - baseballDrift * 0.4).clamp(2.2, 5.8),
          injuries: 1,
          momentumScore: 8.1,
          hasRealStats: true,
        ),
        awayForm: TeamForm(
          teamName: '樂天桃猿',
          lastFiveResults: const ['L', 'W', 'W', 'L', 'W', 'L', 'W', 'W', 'L', 'W'],
          averageScored: (5.1 - baseballDrift * 0.7).clamp(3.0, 7.0),
          averageConceded: (4.6 + baseballDrift * 0.5).clamp(2.8, 6.5),
          injuries: 2,
          momentumScore: 7.2,
          hasRealStats: true,
        ),
        odds: const OddsSnapshot(
          homeWin: 1.72,
          draw: 9.50,
          awayWin: 2.05,
          overLine: 8.5,
          overOdds: 1.79,
          underOdds: 1.97,
        ),
        analystNote: '兄弟牛棚穩定度較高，桃猿打線爆發力強，大小分關注度高。',
      ),
      MatchFixture(
        id: 'basketball-nba-001-$dateTag',
        sport: SportType.basketball,
        league: 'NBA 美國職籃',
        startTime: DateTime(now.year, now.month, now.day, 10, 30),
        homeTeam: '洛杉磯湖人',
        awayTeam: '金州勇士',
        homeForm: TeamForm(
          teamName: '洛杉磯湖人',
          lastFiveResults: const ['W', 'W', 'W', 'L', 'W', 'W', 'L', 'W', 'W', 'L'],
          averageScored: (114.8 + nbaDrift).clamp(100.0, 130.0),
          averageConceded: (109.6 - nbaDrift * 0.5).clamp(98.0, 122.0),
          injuries: 2,
          momentumScore: 8.4,
          hasRealStats: true,
        ),
        awayForm: TeamForm(
          teamName: '金州勇士',
          lastFiveResults: const ['L', 'W', 'W', 'W', 'L', 'W', 'L', 'W', 'W', 'L'],
          averageScored: (112.1 - nbaDrift * 0.6).clamp(98.0, 128.0),
          averageConceded: (111.4 + nbaDrift * 0.4).clamp(100.0, 125.0),
          injuries: 1,
          momentumScore: 7.5,
          hasRealStats: true,
        ),
        odds: const OddsSnapshot(
          homeWin: 1.91,
          draw: 15.00,
          awayWin: 1.95,
          overLine: 228.5,
          overOdds: 1.88,
          underOdds: 1.88,
        ),
        analystNote: '兩隊節奏都快，若外線手感升溫，比分有機會突破市場中位數。',
      ),
      MatchFixture(
        id: 'soccer-j2-001-$dateTag',
        sport: SportType.football,
        league: '日本職業足球乙級聯賽',
        startTime: DateTime(now.year, now.month, now.day, 15, 0),
        homeTeam: '愛媛FC',
        awayTeam: '京都不死鳥',
        homeForm: TeamForm(
          teamName: '愛媛FC',
          lastFiveResults: const ['W', 'L', 'W', 'W', 'L'],
          averageScored: (1.6 + soccerDrift * 0.8).clamp(0.8, 2.5),
          averageConceded: (1.4 - soccerDrift * 0.4).clamp(0.7, 2.2),
          injuries: 0,
          momentumScore: 7.2,
        ),
        awayForm: TeamForm(
          teamName: '京都不死鳥',
          lastFiveResults: const ['D', 'W', 'D', 'L', 'W'],
          averageScored: (1.5 - soccerDrift * 0.5).clamp(0.7, 2.4),
          averageConceded: (1.2 + soccerDrift * 0.3).clamp(0.6, 2.0),
          injuries: 1,
          momentumScore: 6.8,
        ),
        odds: const OddsSnapshot(
          homeWin: 2.42,
          draw: 3.20,
          awayWin: 2.58,
          overLine: 2.5,
          overOdds: 1.90,
          underOdds: 1.90,
        ),
        analystNote: '乙級聯賽對戰，雙方呈勢均力敵局面，比數可能偏低。',
      ),
      MatchFixture(
        id: 'baseball-npb-001-$dateTag',
        sport: SportType.baseball,
        league: '日本職棒',
        startTime: DateTime(now.year, now.month, now.day, 17, 45),
        homeTeam: '讀賣巨人',
        awayTeam: '阪神虎',
        homeForm: TeamForm(
          teamName: '讀賣巨人',
          lastFiveResults: const ['L', 'W', 'W', 'W', 'L', 'W', 'L', 'W', 'W', 'L'],
          averageScored: (4.3 + baseballDrift * 0.9).clamp(2.5, 6.5),
          averageConceded: (3.8 - baseballDrift * 0.3).clamp(2.0, 5.5),
          injuries: 2,
          momentumScore: 6.8,
          hasRealStats: true,
        ),
        awayForm: TeamForm(
          teamName: '阪神虎',
          lastFiveResults: const ['W', 'W', 'L', 'W', 'W', 'L', 'W', 'W', 'L', 'W'],
          averageScored: (4.8 - baseballDrift * 0.6).clamp(2.8, 7.0),
          averageConceded: (3.4 + baseballDrift * 0.4).clamp(2.0, 5.5),
          injuries: 1,
          momentumScore: 7.6,
          hasRealStats: true,
        ),
        odds: const OddsSnapshot(
          homeWin: 2.12,
          draw: 8.80,
          awayWin: 1.78,
          overLine: 7.5,
          overOdds: 1.95,
          underOdds: 1.81,
        ),
        analystNote: '阪神先發壓制力略優，巨人若前段局數無法上壘，總分可能偏低。',
      ),
      MatchFixture(
        id: 'basketball-cba-001-$dateTag',
        sport: SportType.basketball,
        league: 'CBA 中國職籃',
        startTime: DateTime(now.year, now.month, now.day, 20, 0),
        homeTeam: '靴島浙江',
        awayTeam: '上海鯊魚',
        homeForm: TeamForm(
          teamName: '靴島浙江',
          lastFiveResults: const ['W', 'W', 'L', 'W', 'W', 'L', 'W', 'W', 'L', 'W'],
          averageScored: (108.2 + cbaDrift).clamp(94.0, 124.0),
          averageConceded: (105.1 - cbaDrift * 0.5).clamp(93.0, 118.0),
          injuries: 1,
          momentumScore: 8.1,
          hasRealStats: true,
        ),
        awayForm: TeamForm(
          teamName: '上海鯊魚',
          lastFiveResults: const ['L', 'W', 'W', 'L', 'W', 'L', 'W', 'W', 'L', 'W'],
          averageScored: (105.4 - cbaDrift * 0.6).clamp(92.0, 120.0),
          averageConceded: (107.8 + cbaDrift * 0.4).clamp(95.0, 122.0),
          injuries: 2,
          momentumScore: 7.0,
          hasRealStats: true,
        ),
        odds: const OddsSnapshot(
          homeWin: 1.88,
          draw: 12.00,
          awayWin: 2.00,
          overLine: 214.5,
          overOdds: 1.86,
          underOdds: 1.92,
        ),
        analystNote: '浙江主場優勢明顯，上海防線較弱，比分可能偏高。',
      ),
    ];
  }
}

// ============================================
// 📊 歷史偏差修正係數
// ============================================

/// 基於歷史紀錄計算的比分偏差修正係數
/// 由 [PangPangSportsService._loadBiasData()] 動態計算，
/// 在預測時傳入 [PredictionEngine.predictScore] 修正 λ
class SportBiasData {
  const SportBiasData({
    this.homeLambdaFactor = 1.0,
    this.awayLambdaFactor = 1.0,
    this.sampleCount = 0,
    this.teamAttackCorrections = const {},
    this.teamPerformanceDb = const {},
    this.mcAccuracyRate = 0.0,
    this.mcSampleCount = 0,
  });

  /// 主場得分 λ 乘數（<1 降低過高估計，>1 補足低估）
  final double homeLambdaFactor;
  /// 客場得分 λ 乘數
  final double awayLambdaFactor;
  /// 計算此修正值所用的樣本數
  final int sampleCount;
  /// 自我修正：球隊名稱 → 進攻 λ 修正係數（< 1.0 代表長期高估進攻）
  /// 連續 ≥3 場大勝預測→平手時自動生成，每多一場減 7%（上限 -25%）
  final Map<String, double> teamAttackCorrections;
  /// 簡易球隊資料庫：最近10場進/失分均值與標準差，供迴歸均值使用
  final Map<String, TeamPerformanceProfile> teamPerformanceDb;
  /// 蒙地卡羅勝負方向預測準確率（0.0–1.0），用於調控修正激進度
  final double mcAccuracyRate;
  /// 蒙地卡羅有效樣本數
  final int mcSampleCount;

  static const empty = SportBiasData();

  /// 至少 5 場已回報結果才啟用修正，防止樣本太少造成過擬合
  bool get hasSufficientData => sampleCount >= 5;

  /// MC 準確率信心倍數：準確率 > 60% → 修正更激進；< 40% → 修正趨保守
  double get mcConfidenceMultiplier {
    if (mcSampleCount < 5) return 1.0; // 樣本不足，不調控
    // 以 50% 為基線，偏差 ±10% 各對應 ±15% 修正強度
    return (1.0 + (mcAccuracyRate - 0.5) * 1.5).clamp(0.7, 1.3);
  }

  @override
  String toString() =>
      'SportBiasData(home×${homeLambdaFactor.toStringAsFixed(3)}, '
      'away×${awayLambdaFactor.toStringAsFixed(3)}, n=$sampleCount, '
      'mc=${(mcAccuracyRate * 100).toStringAsFixed(0)}%/$mcSampleCount, '
      'teamCorrections=${teamAttackCorrections.length}, '
      'teamDb=${teamPerformanceDb.length})';
}

/// 球隊最近10場簡易統計（作為本地小型資料庫）
class TeamPerformanceProfile {
  const TeamPerformanceProfile({
    required this.longAvgScored,
    required this.longAvgConceded,
    required this.scoredStdDev,
    required this.concededStdDev,
    required this.recentAvgScored,
    required this.sampleSize,
    required this.recentSampleSize,
  });

  final double longAvgScored;
  final double longAvgConceded;
  final double scoredStdDev;
  final double concededStdDev;
  final double recentAvgScored;
  final int sampleSize;
  final int recentSampleSize;
}

/// 樂透 / 賓果 AI 學習結果
/// 從歷史預測命中情況自動計算，供推薦引擎加權參考
class LotteryLearningData {
  const LotteryLearningData({
    this.hitRate = 0.0,
    this.sampleCount = 0,
    this.avgHitCount = 0.0,
    this.rangeHitRates = const {},
    this.strategyHitRates = const {},
    this.hotLearned = const [],
  });

  /// 整體有中任一號碼的比例
  final double hitRate;
  final int sampleCount;
  /// 每期平均命中號碼數
  final double avgHitCount;
  /// 各區間命中率：例如 {'1-13': 0.42, '14-26': 0.35, '27-39': 0.23}
  final Map<String, double> rangeHitRates;
  /// 各策略/組別命中率（賓果用）：{'熱門補缺': 0.55, '冷熱均衡': 0.48, ...}
  final Map<String, double> strategyHitRates;
  /// AI 從歷史中找出最常命中的號碼（前 10）
  final List<int> hotLearned;

  String get bestStrategy {
    if (strategyHitRates.isEmpty) return '';
    return strategyHitRates.entries
        .reduce((a, b) => a.value >= b.value ? a : b)
        .key;
  }
}

// ============================================
// 🏋️ 胖胖體育 - 統一主服務
// ============================================

/// 🏋️ 胖胖體育 - 統一主服務
/// 
/// 包含應用所有功能：
/// - 📊 數據管理（真實/模擬數據自動切換）
/// - 🎯 賽事預測（高精度算法）
/// - ⚡ 直播追蹤（實時更新）
/// - 💾 存檔管理（歷史數據統計）
class PangPangSportsService {
  static final PangPangSportsService _instance =
      PangPangSportsService._internal();

  // 離線備援持久化 Key
  static const String _persistentMatchesKey = 'offline_matches_backup';
  static const String _persistentTimestampKey = 'offline_matches_timestamp';

  // 核心組件  
  late final PredictionEngine _predictionEngine;
  late final _MatchArchiveService _archiveService;
  late final _MockDataService _mockDataService;
  final _oddsApi = OddsApiService();

  // 配置
  var _useRealData = AppConfig.useRealDataByDefault;
  Timer? _liveUpdateTimer;
  Timer? _dailyUpdateTimer;
  bool _isDailyUpdateEnabled = true;
  final Map<String, StreamController<LiveMatchUpdate>> _liveStreams = {};
  final Map<String, LiveMatchUpdate> _cachedLiveMatches = {};

  // 快取
  final Map<String, List<PredictionResult>> _predictionCache = {};
  DateTime? _lastCacheDate;
  DateTime? _lastDailyUpdateDate;

  // 比賽數據快取（避免重複 API 呼叫）
  List<MatchFixture>? _matchCache;
  DateTime? _matchCacheTime;
  // 改為 30 秒快取，確保賭盤賠率即時同步
  static const _matchCacheTtl = Duration(seconds: 30);
  
  // 賭盤賠率實時更新機制：每 15 秒強制更新一次
  DateTime? _lastOddsUpdateTime;
  static const _oddsCacheTtl = Duration(seconds: 15);

  /// 各運動歷史偏差修正係數（由歷史紀錄動態計算）
  Map<SportType, SportBiasData> _biasDataByType = {};

  /// 大小分 AI 偏差乘數（預載入，供同步 predictMatch 使用）
  Map<SportType, double> _ouBiasMultipliers = {};

  /// 樂透/賓果 AI 學習結果（'lottery539' / 'bingo'）
  final Map<String, LotteryLearningData> _lotteryLearningByType = {};

  Map<String, Map<String, double>> _leagueRegressionCoeffs = {}; // 優化：改為以聯賽為 Key

  /// 同賽區完賽通知：當某聯賽有比賽結束時 value 遞增，HomeScreen 監聽後自動刷新預測
  final ValueNotifier<int> predictionRefreshNotifier = ValueNotifier(0);

  PangPangSportsService._internal() {
    _initializeServices();
  }

  factory PangPangSportsService() {
    return _instance;
  }

  void _initializeServices() {
    _predictionEngine = const PredictionEngine();
    _archiveService = _MatchArchiveService();
    _mockDataService = const _MockDataService();
    
    // 使用 Future.microtask 避免阻塞建構子，確保單例安全建立
    Future.microtask(() async {
      try {
        // 啟動每日更新
        _startDailyUpdateCheck();
        // 從歷史紀錄載入線性回歸係數
        await _loadLinearRegressionCoeffs();
        // 從歷史紀錄載入偏差修正係數
        await _loadBiasData();
        // 預載大小分偏差乘數（AI 訓練結果）
        await _loadOUBiasMultipliers();
      } catch (e) {
        debugPrint('⚠️ 體育服務背景初始化異常: $e');
      }
    });
  }

  /// 啟動每日自動更新檢查（每分鐘檢查一次是否跨越午夜）
  void _startDailyUpdateCheck() {
    if (!_isDailyUpdateEnabled) return;
    
    // 立即執行一次
    _checkAndUpdateDaily();
    
    // 每分鐘檢查一次（午夜時自動更新）
    _dailyUpdateTimer = Timer.periodic(
      const Duration(minutes: 1),
      (_) => _checkAndUpdateDaily(),
    );
    debugPrint('✅ 每日自動更新已啟動');
  }

  /// 檢查是否進入新的一天，如果是則自動更新
  Future<void> _checkAndUpdateDaily() async {
    final today = DateTime.now();
    final todayDateKey = _formatDate(today);
    
    // 如果是新的一天，執行更新
    if (_lastDailyUpdateDate == null ||
        _formatDate(_lastDailyUpdateDate!) != todayDateKey) {
      await _performDailyUpdate();
      _lastDailyUpdateDate = today;
    }
  }

  /// 執行每日更新：清除快取並重新獲取所有運動的比賽數據
  Future<void> _performDailyUpdate() async {
    debugPrint('🔄 開始每日自動更新...');
    
    // 清除快取
    clearCache();

    // 清除舊的直播串流與快取數據，防止記憶體隨日期增長而堆積
    _clearLiveResources();
    
    // 只抓一次所有比賽，避免重複 API 呼叫
    try {
      final allMatches = await getTodaysMatches();
      final football = allMatches.where((m) => m.sport == SportType.football).length;
      final baseball = allMatches.where((m) => m.sport == SportType.baseball).length;
      final basketball = allMatches.where((m) => m.sport == SportType.basketball).length;
      debugPrint('⚽ 已更新足球比賽: $football 場');
      debugPrint('⚾ 已更新棒球比賽: $baseball 場');
      debugPrint('🏀 已更新籃球比賽: $basketball 場');

      // 用已拿到的數據產生預測（不再重新 fetch）
      await getTodaysPredictions();
      
      debugPrint('✅ 每日自動更新完成！');
    } catch (e) {
      debugPrint('❌ 每日更新失敗: $e');
    }
  }

  // ==================== 📊 歷史偏差修正 ====================

  /// 從歷史預測紀錄計算各運動的比分偏差修正係數
  ///
  /// 計算原理：
  ///   bias = actualAvg / predictedAvg
  ///   若籃球預測平均 133:110，實際平均 112:105
  ///   → homeFactor = 112/133 ≈ 0.842（系統長期高估主場），awayFactor = 105/110 ≈ 0.955
  ///
  /// 需要 ≥ 5 筆已回報的比賽才會套用修正，防止樣本過少導致過擬合
  Future<void> _loadBiasData() async {
    try {
      final logSvc = PredictionLogService();
      final logs = await logSvc.loadByType(PredictionType.sport);

      // 收集各運動樣本，包含預測與實際比分，並加入「勝分差分」紀錄
      // 元組結構：(預測主, 預測客, 實際主, 實際客, 預測分差, 實際分差)
      // 這能幫助模型識別：是單純得分預估錯誤，還是對兩隊「相對實力差」的誤判
      final data = <SportType, List<(int, int, int, int, int, int)>>{};

      for (final log in logs) {
        if (log.outcome == PredictionOutcome.pending) continue;
        final actualStr = log.actualResult ?? '';
        if (actualStr.isEmpty) continue;

        final pred = _parseScoreStr(log.predictedResult);
        final actual = _parseScoreStr(actualStr);
        if (pred == null || actual == null) continue;

        final sportStr = (log.details['sport'] as String?) ?? 'football';
        final sport = _sportTypeFromString(sportStr);

        final predMargin = pred.$1 - pred.$2;
        final actMargin = actual.$1 - actual.$2;

        data.putIfAbsent(sport, () => []).add(
          (pred.$1, pred.$2, actual.$1, actual.$2, predMargin, actMargin)
        );
      }

      final bias = <SportType, SportBiasData>{};
      final teamPerformanceDb = _buildTeamPerformanceDb(logs);

      // ── 蒙地卡羅準確率統計（用於調控偏差修正激進度）──────────────
      // 從歷史 log 的 details['mcCorrect'] 計算各運動 MC 勝負方向準確率
      final mcStats = <SportType, (int correct, int total)>{};
      for (final log in logs) {
        if (log.outcome == PredictionOutcome.pending) continue;
        final mcCorrectVal = log.details['mcCorrect'];
        if (mcCorrectVal == null) continue;
        final sportStr = (log.details['sport'] as String?) ?? 'football';
        final sport = _sportTypeFromString(sportStr);
        final prev = mcStats[sport] ?? (0, 0);
        final isCorrect = mcCorrectVal == true || mcCorrectVal == 'true';
        mcStats[sport] = (prev.$1 + (isCorrect ? 1 : 0), prev.$2 + 1);
      }
      for (final e in mcStats.entries) {
        final rate = e.value.$2 > 0 ? e.value.$1 / e.value.$2 : 0.0;
        debugPrint('🎲 [${e.key.name}] MC準確率: '
            '${(rate * 100).toStringAsFixed(1)}% '
            '(${e.value.$1}/${e.value.$2})');
      }

      for (final entry in data.entries) {
        final samples = entry.value;
        if (samples.isEmpty) continue;

        // ── 💡 優化：引入時間權重衰減 (Exponential Weighting) ──────────
        // 讓最近期的比賽對偏差修正的影響力更大，防止 AI 學習到過時的規律
        double wPredH = 0, wPredA = 0, wActH = 0, wActA = 0, wMarginErr = 0;
        double totalWeight = 0;

        for (int i = 0; i < samples.length; i++) {
          // 權重公式：0.92 的 (距離現在第幾場) 次方。最新的一場權重為 1.0
          double weight = pow(0.92, samples.length - 1 - i).toDouble();
          wPredH += samples[i].$1 * weight;
          wPredA += samples[i].$2 * weight;
          wActH += samples[i].$3 * weight;
          wActA += samples[i].$4 * weight;
          
          // 加權勝分差誤差：實際分差 - 預測分差 (正值代表主隊比預期更強)
          wMarginErr += (samples[i].$6 - samples[i].$5) * weight;
          totalWeight += weight;
        }

        // 1. 基礎得分率修正：直接修正主客得分的預估誤差
        double homeFactor = wPredH > 0 ? (wActH / wPredH) : 1.0;
        double awayFactor = wPredA > 0 ? (wActA / wPredA) : 1.0;

        // 2. 勝分差分修正：校準主客隊相對強度偏差
        // 如果加權平均後的實際分差大於預測 (marginErr > 0)，說明模型低估了主隊的優勢
        if (totalWeight > 0) {
          final avgMarginErr = wMarginErr / totalWeight;
          final marginAdj = (avgMarginErr * 0.05).clamp(-0.15, 0.15); // 補償係數
          homeFactor = (homeFactor + marginAdj).clamp(0.70, 1.30);
          awayFactor = (awayFactor - marginAdj).clamp(0.70, 1.30);
        }

        // MC 準確率資料
        final mc = mcStats[entry.key];
        final mcRate = mc != null && mc.$2 > 0 ? mc.$1 / mc.$2 : 0.0;
        final mcN = mc?.$2 ?? 0;

        bias[entry.key] = SportBiasData(
          homeLambdaFactor: homeFactor,
          awayLambdaFactor: awayFactor,
          sampleCount: samples.length,
          teamPerformanceDb: teamPerformanceDb,
          mcAccuracyRate: mcRate,
          mcSampleCount: mcN,
        );
        debugPrint('📊 [${entry.key.name}] 偏差修正: '
            'home×${homeFactor.toStringAsFixed(3)}, '
            'away×${awayFactor.toStringAsFixed(3)} (n=${samples.length})');
      }

      // ── 自我修正：連續大勝預測→平手 → 降低進攻權重 ──────────────
      // 若某隊被連續 ≥3 場預測大勝（分差 ≥2），但實際結果均為平手，
      // 代表模型長期高估該隊進攻火力，自動調降 λ 係數。
      // 每多一場這樣的紀錄 → -7%（最多 -25%）
      final teamAttackCorrections = <String, double>{};
      // 以 title 解析 homeTeam（"A vs B" 格式），最新在前，需最舊先排
      final allSportLogs = logs
          .where((l) => l.outcome != PredictionOutcome.pending)
          .toList()
        ..sort((a, b) => a.createdAt.compareTo(b.createdAt)); // oldest first

      // 分組：teamName → [(predictedMarginForTeam, actualIsDraw)]
      final teamSeqMap = <String, List<(int, bool)>>{};
      for (final log in allSportLogs) {
        final pred   = _parseScoreStr(log.predictedResult);
        final actual = _parseScoreStr(log.actualResult ?? '');
        if (pred == null || actual == null) continue;
        final homeTeam = (log.details['homeTeam'] as String?) ?? '';
        final awayTeam = (log.details['awayTeam'] as String?) ?? '';
        if (homeTeam.isEmpty) continue;
        final actualIsDraw = actual.$1 == actual.$2;
        // 主隊角度：預期大勝分差 ≥ 2
        teamSeqMap.putIfAbsent(homeTeam, () => [])
            .add((pred.$1 - pred.$2, actualIsDraw));
        // 客隊角度：預期大勝分差 ≥ 2
        teamSeqMap.putIfAbsent(awayTeam, () => [])
            .add((pred.$2 - pred.$1, actualIsDraw));
      }

      for (final entry in teamSeqMap.entries) {
        final records = entry.value.reversed.toList(); // newest first
        var consecutiveMisses = 0;
        for (final (predMargin, isDraw) in records) {
          if (predMargin >= 2 && isDraw) {
            consecutiveMisses++;
          } else {
            break;
          }
        }
        if (consecutiveMisses >= 4) { // 門檻提高到 4 場，防止過度反應
          final correction =
              (1.0 - (consecutiveMisses - 3) * 0.05).clamp(0.82, 0.98);
          teamAttackCorrections[entry.key] = correction.toDouble();
          debugPrint('🔧 自我學習優化：${entry.key} 表現低於預期，微調進攻權重至'
              ' ${(correction * 100).toStringAsFixed(0)}%');
        }
      }

      // 將 teamAttackCorrections 注入每個 SportBiasData
      if (teamAttackCorrections.isNotEmpty) {
        for (final key in bias.keys.toList()) {
          final existing = bias[key]!;
          bias[key] = SportBiasData(
            homeLambdaFactor: existing.homeLambdaFactor,
            awayLambdaFactor: existing.awayLambdaFactor,
            sampleCount: existing.sampleCount,
            mcAccuracyRate: existing.mcAccuracyRate,
            mcSampleCount: existing.mcSampleCount,
            teamAttackCorrections: teamAttackCorrections,
            teamPerformanceDb: existing.teamPerformanceDb,
          );
        }
        // 若某個 sport 還沒進 bias map，建立一個僅含 teamCorrections 的記錄
        for (final sport in SportType.values) {
          if (!bias.containsKey(sport)) {
            final mc = mcStats[sport];
            final mcRate = mc != null && mc.$2 > 0 ? mc.$1 / mc.$2 : 0.0;
            final mcN = mc?.$2 ?? 0;
            bias[sport] = SportBiasData(
              teamAttackCorrections: teamAttackCorrections,
              teamPerformanceDb: teamPerformanceDb,
              mcAccuracyRate: mcRate,
              mcSampleCount: mcN,
            );
          }
        }
      }

      // 沒有觸發自我修正時，也保留 teamPerformanceDb 供迴歸均值使用
      if (teamAttackCorrections.isEmpty) {
        for (final key in bias.keys.toList()) {
          final existing = bias[key]!;
          bias[key] = SportBiasData(
            homeLambdaFactor: existing.homeLambdaFactor,
            awayLambdaFactor: existing.awayLambdaFactor,
            sampleCount: existing.sampleCount,
            mcAccuracyRate: existing.mcAccuracyRate,
            mcSampleCount: existing.mcSampleCount,
            teamPerformanceDb: teamPerformanceDb,
          );
        }
      }

      _biasDataByType = bias;
      if (bias.isNotEmpty) {
        debugPrint('✅ 歷史偏差修正已載入：${bias.length} 個運動');
      }
    } catch (e) {
      debugPrint('⚠️ 載入偏差數據失敗: $e');
      _biasDataByType = {};
    }
  }

  /// 預載各運動大小分偏差乘數（來自 SelfLearningService AI 訓練結果）
  Future<void> _loadOUBiasMultipliers() async {
    _ouBiasMultipliers = {
      SportType.basketball: await SelfLearningService.getOUBiasMultiplier('basketball'),
      SportType.baseball:   await SelfLearningService.getOUBiasMultiplier('baseball'),
      SportType.football:   await SelfLearningService.getOUBiasMultiplier('football'),
    };
    debugPrint('📊 O/U 偏差乘數: ${_ouBiasMultipliers.values.map((v) => v.toStringAsFixed(3)).join(', ')}');
  }

  /// 從歷史樂透 / 賓果預測學習命中規律
  /// 分析每期預測號碼 vs 實際開獎，統計：
  ///   • 整體命中率（有中任一號）
  ///   • 各區間命中率（539: 1-13 / 14-26 / 27-39；賓果: 1-20 / 21-40 / 41-60 / 61-80）
  ///   • 賓果：各推薦策略的命中率
  Future<void> _loadLotteryLearning() async {
    try {
      final logSvc = PredictionLogService();
      final lotteryLogs = await logSvc.loadByType(PredictionType.lottery);
      final bingoLogs   = await logSvc.loadByType(PredictionType.bingo);

      // ── 解析號碼字串 ────────────────────────────────────────────
      List<int> parseNums(String s) {
        if (s.isEmpty) return [];
        return s.split(' ')
            .map((t) => int.tryParse(t.trim()))
            .whereType<int>()
            .toList();
      }

      // ── 539 學習 ─────────────────────────────────────────────────
      {
        final judged = lotteryLogs
            .where((l) => l.outcome != PredictionOutcome.pending &&
                (l.actualResult ?? '').isNotEmpty)
            .toList();

        if (judged.isNotEmpty) {
          int totalHit = 0;
          double totalHitCount = 0;
          final rangeCounts  = {'1-13': 0, '14-26': 0, '27-39': 0};
          final rangeHits    = {'1-13': 0, '14-26': 0, '27-39': 0};
          final numHitCount  = <int, int>{for (var n = 1; n <= 39; n++) n: 0};

          for (final log in judged) {
            final pred   = parseNums(log.predictedResult);
            final actual = parseNums(log.actualResult ?? '');
            if (pred.isEmpty || actual.isEmpty) continue;

            final hits = pred.where((n) => actual.contains(n)).toSet();
            if (hits.isNotEmpty) totalHit++;
            totalHitCount += hits.length;

            for (final n in pred) {
              final rangeKey = n <= 13 ? '1-13' : n <= 26 ? '14-26' : '27-39';
              rangeCounts[rangeKey] = (rangeCounts[rangeKey] ?? 0) + 1;
            }
            for (final n in hits) {
              final rangeKey = n <= 13 ? '1-13' : n <= 26 ? '14-26' : '27-39';
              rangeHits[rangeKey] = (rangeHits[rangeKey] ?? 0) + 1;
              numHitCount[n] = (numHitCount[n] ?? 0) + 1;
            }
          }

          final n = judged.length;
          final rangeHitRates = <String, double>{};
          for (final k in rangeCounts.keys) {
            final cnt = rangeCounts[k]!;
            rangeHitRates[k] = cnt > 0 ? (rangeHits[k]! / cnt) : 0.0;
          }
          final hotLearned = (numHitCount.entries.toList()
                ..sort((a, b) => b.value.compareTo(a.value)))
              .take(10)
              .map((e) => e.key)
              .toList();

          _lotteryLearningByType['lottery539'] = LotteryLearningData(
            hitRate: totalHit / n,
            sampleCount: n,
            avgHitCount: totalHitCount / n,
            rangeHitRates: rangeHitRates,
            hotLearned: hotLearned,
          );
          debugPrint('🎯 539 學習: 命中率=${(totalHit / n * 100).toStringAsFixed(1)}% '
              '(n=$n, 平均${(totalHitCount / n).toStringAsFixed(2)}球)');
        }
      }

      // ── 賓果學習 ─────────────────────────────────────────────────
      {
        final judged = bingoLogs
            .where((l) => l.outcome != PredictionOutcome.pending &&
                (l.actualResult ?? '').isNotEmpty)
            .toList();

        if (judged.isNotEmpty) {
          int totalHit = 0;
          double totalHitCount = 0;
          final rangeCounts  = {'1-20': 0, '21-40': 0, '41-60': 0, '61-80': 0};
          final rangeHits    = {'1-20': 0, '21-40': 0, '41-60': 0, '61-80': 0};
          final numHitCount  = <int, int>{for (var n = 1; n <= 80; n++) n: 0};
          final strategyHits = <String, (int hit, int total)>{};

          for (final log in judged) {
            final pred   = parseNums(log.predictedResult);
            final actual = parseNums(log.actualResult ?? '');
            if (pred.isEmpty || actual.isEmpty) continue;

            final hits = pred.where((n) => actual.contains(n)).toSet();
            if (hits.isNotEmpty) totalHit++;
            totalHitCount += hits.length;

            // 策略標籤來自 subtitle（例如 "熱門補缺 | 高頻 14 + 久未開出 6"）
            final strategyKey = log.subtitle.split('|').first.trim();
            if (strategyKey.isNotEmpty) {
              final prev = strategyHits[strategyKey] ?? (0, 0);
              strategyHits[strategyKey] =
                  (prev.$1 + (hits.isNotEmpty ? 1 : 0), prev.$2 + 1);
            }

            for (final n in pred) {
              final k = n <= 20 ? '1-20' : n <= 40 ? '21-40' : n <= 60 ? '41-60' : '61-80';
              rangeCounts[k] = (rangeCounts[k] ?? 0) + 1;
            }
            for (final n in hits) {
              final k = n <= 20 ? '1-20' : n <= 40 ? '21-40' : n <= 60 ? '41-60' : '61-80';
              rangeHits[k] = (rangeHits[k] ?? 0) + 1;
              numHitCount[n] = (numHitCount[n] ?? 0) + 1;
            }
          }

          final nb = judged.length;
          final rangeHitRates = <String, double>{};
          for (final k in rangeCounts.keys) {
            final cnt = rangeCounts[k]!;
            rangeHitRates[k] = cnt > 0 ? (rangeHits[k]! / cnt) : 0.0;
          }
          final strategyRates = strategyHits.map(
              (k, v) => MapEntry(k, v.$2 > 0 ? v.$1 / v.$2 : 0.0));
          final hotLearned = (numHitCount.entries.toList()
                ..sort((a, b) => b.value.compareTo(a.value)))
              .take(10)
              .map((e) => e.key)
              .toList();

          _lotteryLearningByType['bingo'] = LotteryLearningData(
            hitRate: totalHit / nb,
            sampleCount: nb,
            avgHitCount: totalHitCount / nb,
            rangeHitRates: rangeHitRates,
            strategyHitRates: strategyRates,
            hotLearned: hotLearned,
          );
          debugPrint('🎯 賓果學習: 命中率=${(totalHit / nb * 100).toStringAsFixed(1)}% '
              '(n=$nb, 最佳策略=${_lotteryLearningByType['bingo']!.bestStrategy})');
        }
      }
    } catch (e) {
      debugPrint('⚠️ 樂透/賓果學習失敗: $e');
    }
  }

  /// 從歷史預測紀錄計算線性回歸係數
  ///
  /// 目標：學習 `actual_score = intercept + coeff * predicted_score`
  /// 這樣在預測時，可以將 `predicted_lambda` 調整為 `predicted_lambda * coeff + intercept`
  Future<void> _loadLinearRegressionCoeffs() async {
    try {
      final logSvc = PredictionLogService();
      final logs = await logSvc.loadByType(PredictionType.sport);

      // 將數據依「聯賽」分組
      final leagueData = <String, List<(double, double, double, double)>>{};

      for (final log in logs) {
        if (log.outcome == PredictionOutcome.pending) continue;
        final actualStr = log.actualResult ?? '';
        if (actualStr.isEmpty) continue;

        final pred = _parseScoreStr(log.predictedResult);
        final actual = _parseScoreStr(actualStr);
        if (pred == null || actual == null) continue;

        final league = (log.details['league'] as String?) ?? 'unknown';
        leagueData.putIfAbsent(league, () => []).add((
          pred.$1.toDouble(),
          pred.$2.toDouble(),
          actual.$1.toDouble(),
          actual.$2.toDouble(),
        ));
      }

      final coeffs = <String, Map<String, double>>{};
      for (final entry in leagueData.entries) {
        final leagueName = entry.key;
        final samples = entry.value;
        if (samples.length < 5) continue; 

        // ── 計算聯賽特性：波動率 (Volatility) ──
        final errors = samples.map((s) => (s.$1 - s.$3).abs() + (s.$2 - s.$4).abs()).toList();
        final meanError = errors.reduce((a, b) => a + b) / errors.length;
        final volatility = sqrt(errors.map((e) => pow(e - meanError, 2)).reduce((a, b) => a + b) / errors.length);

        // ── 自動調整學習速率 ──
        // 樣本越多速率越穩，波動越大速率越慢 (防止被爆冷場次帶偏)
        final baseLR = 0.005; // [修正] 降低基礎學習率，避免過度擬合近期異常比分
        final learningRate = (baseLR / (sqrt(samples.length) * (1 + volatility))).clamp(0.0005, 0.02);

        // 執行梯度下降優化
        final homeReg = _gradientDescentRegression(
          samples.map((s) => s.$1).toList(), 
          samples.map((s) => s.$3).toList(),
          learningRate,
        );
        final awayReg = _gradientDescentRegression(
          samples.map((s) => s.$2).toList(), 
          samples.map((s) => s.$4).toList(),
          learningRate,
        );

        coeffs[leagueName] = {
          'home_intercept': homeReg.intercept,
          'home_coeff': homeReg.slope,
          'away_intercept': awayReg.intercept,
          'away_coeff': awayReg.slope,
          'lr': learningRate,
        };
        
        debugPrint('📈 [$leagueName] 學習完成 (LR: ${learningRate.toStringAsFixed(4)}, Vol: ${volatility.toStringAsFixed(2)})');
      }
      _leagueRegressionCoeffs = coeffs;
    } catch (e) {
      debugPrint('⚠️ 載入線性回歸係數失敗: $e');
      _leagueRegressionCoeffs = {};
    }
  }

  /// 梯度下降線性回歸
  _RegressionResult _gradientDescentRegression(List<double> x, List<double> y, double lr) {
    double m = 1.0; // 初始斜率
    double b = 0.0; // 初始截距
    const iterations = 500;
    final n = x.length;

    for (int i = 0; i < iterations; i++) {
      double mGradient = 0;
      double bGradient = 0;
      for (int j = 0; j < n; j++) {
        final prediction = m * x[j] + b;
        mGradient += -(2 / n) * x[j] * (y[j] - prediction);
        bGradient += -(2 / n) * (y[j] - prediction);
      }
      m -= mGradient * lr;
      b -= bGradient * lr;
    }
    return _RegressionResult(slope: m, intercept: b);
  }

  static (int, int)? _parseScoreStr(String s) {
    final parts = s.trim().split(RegExp(r'[:：]'));
    if (parts.length < 2) return null;
    final a = int.tryParse(parts[0].trim());
    final b = int.tryParse(parts[1].trim());
    if (a == null || b == null) return null;
    return (a, b);
  }

  static SportType _sportTypeFromString(String s) => switch (s) {
    'basketball' => SportType.basketball,
    'baseball'   => SportType.baseball,
    _            => SportType.football,
  };

  /// 建立簡易球隊資料庫：最近10場進/失分平均、標準差與近3場平均
  static Map<String, TeamPerformanceProfile> _buildTeamPerformanceDb(
    List<PredictionLog> logs,
  ) {
    final scoredByTeam = <String, List<double>>{};
    final concededByTeam = <String, List<double>>{};

    final settled = logs
        .where((l) => l.outcome != PredictionOutcome.pending)
        .toList()
      ..sort((a, b) => a.createdAt.compareTo(b.createdAt));

    for (final log in settled) {
      final actual = _parseScoreStr(log.actualResult ?? '');
      if (actual == null) continue;
      final home = (log.details['homeTeam'] as String?) ?? '';
      final away = (log.details['awayTeam'] as String?) ?? '';
      if (home.isEmpty || away.isEmpty) continue;

      scoredByTeam.putIfAbsent(home, () => []).add(actual.$1.toDouble());
      concededByTeam.putIfAbsent(home, () => []).add(actual.$2.toDouble());
      scoredByTeam.putIfAbsent(away, () => []).add(actual.$2.toDouble());
      concededByTeam.putIfAbsent(away, () => []).add(actual.$1.toDouble());
    }

    final db = <String, TeamPerformanceProfile>{};
    for (final team in scoredByTeam.keys) {
      final scoredAll = scoredByTeam[team] ?? const <double>[];
      final concededAll = concededByTeam[team] ?? const <double>[];
      if (scoredAll.isEmpty || concededAll.isEmpty) continue;

      final scored = scoredAll.length > 10
          ? scoredAll.sublist(scoredAll.length - 10)
          : scoredAll;
      final conceded = concededAll.length > 10
          ? concededAll.sublist(concededAll.length - 10)
          : concededAll;
      final recent = scored.length > 3
          ? scored.sublist(scored.length - 3)
          : scored;

      db[team] = TeamPerformanceProfile(
        longAvgScored: scored.reduce((a, b) => a + b) / scored.length,
        longAvgConceded: conceded.reduce((a, b) => a + b) / conceded.length,
        scoredStdDev: _stdDev(scored),
        concededStdDev: _stdDev(conceded),
        recentAvgScored: recent.reduce((a, b) => a + b) / recent.length,
        sampleSize: scored.length,
        recentSampleSize: recent.length,
      );
    }
    return db;
  }

  static double _stdDev(List<double> values) {
    if (values.length <= 1) return 0;
    final mean = values.reduce((a, b) => a + b) / values.length;
    final variance = values
            .map((v) => (v - mean) * (v - mean))
            .reduce((a, b) => a + b) /
        values.length;
    return sqrt(variance);
  }

  // ==================== 📊 數據獲取 ====================

  /// 獲取今天的所有比賽（30 秒快取，賭盤賠率 15 秒實時更新）
  Future<List<MatchFixture>> getTodaysMatches({bool forceRefresh = false}) async {
    // 賭盤賠率實時更新：每 15 秒強制重新抓取賠率數據
    final shouldRefreshOdds = forceRefresh ||
        _lastOddsUpdateTime == null ||
        DateTime.now().difference(_lastOddsUpdateTime!) > _oddsCacheTtl;
    
    // 快取命中：30 秒內且賠率不需要更新時使用快取
    if (!forceRefresh &&
        !shouldRefreshOdds &&
        _matchCache != null &&
        _matchCacheTime != null &&
        DateTime.now().difference(_matchCacheTime!) < _matchCacheTtl) {
      return _matchCache!;
    }
    
    // 如果只是賭盤賠率過期，刷新賠率但保留其他數據
    if (!forceRefresh &&
        shouldRefreshOdds &&
        _matchCache != null &&
        DateTime.now().difference(_matchCacheTime!) < _matchCacheTtl) {
      debugPrint('🔄 正在實時同步賭盤賠率...');
      final updatedMatches = await _refreshOddsOnly(_matchCache!);
      _matchCache = updatedMatches;
      _lastOddsUpdateTime = DateTime.now();
      return updatedMatches;
    }
    
    try {
      debugPrint('🌐 正在從 ESPN 獲取即時比賽數據...');
      var realMatches = await RealDataService.fetchTodaysMatches();

      // Bet365 賠率回填：批次抓取各聯賽賠率後逐場比對
      if (_oddsApi.isConfigured && realMatches.isNotEmpty) {
        final sportKeys = <String>{};
        for (final m in realMatches) {
          final k = OddsApiService.leagueToSportKey[m.league];
          if (k != null) sportKeys.add(k);
        }
        if (sportKeys.isNotEmpty) {
          final fetched = await Future.wait(sportKeys.map(_oddsApi.fetchSport));
          final oddsMap = Map.fromIterables(sportKeys, fetched);
          realMatches = realMatches.map((m) {
            if (m.odds.isFromBookmaker) return m;
            final k = OddsApiService.leagueToSportKey[m.league];
            if (k == null) return m;
            final bet365 = _oddsApi.findInEvents(oddsMap[k]!, m.homeTeam, m.awayTeam);
            return bet365 != null
                ? m.copyWith(odds: bet365, analystNote: 'Bet365 即時賠率')
                : m;
          }).toList();
        }
      }

      if (realMatches.isNotEmpty) {
        // 最終去重：不同資料源可能仍帶入同一場比賽
        final deduped = <MatchFixture>[];
        for (final m in realMatches) {
          final dup = deduped.cast<MatchFixture?>().firstWhere(
            (e) => e != null && _isSameMatch(e, m),
            orElse: () => null,
          );
          if (dup == null) {
            deduped.add(m);
          } else if (!dup.odds.isFromBookmaker && m.odds.isFromBookmaker) {
            deduped[deduped.indexOf(dup)] = m;
          }
        }
        realMatches = deduped;

        realMatches.sort((a, b) => a.startTime.compareTo(b.startTime));
        debugPrint('✅ 成功獲取 ${realMatches.length} 場真實比賽數據');
        _matchCache = realMatches;
        _matchCacheTime = DateTime.now();

        // 背景預取各隊最新新聞（不阻塞 UI）
        SportsNewsService.prefetchForFixtures(realMatches);

        // 🚀 成功後自動更新離線備援
        _saveToPersistentCache(realMatches);

        return realMatches;
      }
      debugPrint('⚠ 網路數據為空，切換到模擬數據');
    } catch (e) {
      debugPrint('❌ 獲取數據失敗: $e，切換到模擬數據');
      // 網路失敗時回傳舊快取（若有）
      if (_matchCache != null && _matchCache!.isNotEmpty) {
        debugPrint('📦 使用上次快取的 ${_matchCache!.length} 場比賽');
        return _matchCache!;
      }

      // 🚀 核心離線機制：網路與記憶體都失敗時，讀取持久化備援
      final offlineBackup = await _loadFromPersistentCache();
      if (offlineBackup != null && offlineBackup.isNotEmpty) {
        debugPrint('📦 從離線備援恢復了 ${offlineBackup.length} 場賽事資料');
        _matchCache = offlineBackup;
        return offlineBackup;
      }
    }
    return _mockDataService.getTodaysFixtures();
  }

  /// 僅刷新 Bet365 賠率，保留快取中的所有其他欄位。
  Future<List<MatchFixture>> _refreshOddsOnly(List<MatchFixture> cached) async {
    if (!_oddsApi.isConfigured) return cached;
    try {
      final sportKeys = <String>{};
      for (final m in cached) {
        final k = OddsApiService.leagueToSportKey[m.league];
        if (k != null) sportKeys.add(k);
      }
      if (sportKeys.isEmpty) return cached;
      final fetched = await Future.wait(sportKeys.map(_oddsApi.fetchSport));
      final oddsMap = Map.fromIterables(sportKeys, fetched);
      return cached.map((m) {
        final k = OddsApiService.leagueToSportKey[m.league];
        if (k == null) return m;
        final bet365 = _oddsApi.findInEvents(oddsMap[k]!, m.homeTeam, m.awayTeam);
        return bet365 != null ? m.copyWith(odds: bet365) : m;
      }).toList();
    } catch (e) {
      debugPrint('⚠ 賠率刷新失敗: $e，保留舊賠率');
      return cached;
    }
  }

  /// 獲取未來 [days] 天的比賽（預設5天）
  Future<List<MatchFixture>> getMatchesForDays({int days = 5}) async {
    try {
      debugPrint('🌐 正在從 ESPN 獲取 $days 天比賽數據...');
      final realMatches = await RealDataService.fetchMatchesForDays(days: days);
      if (realMatches.isNotEmpty) {
        debugPrint('✅ 成功獲取 ${realMatches.length} 場真實比賽數據（$days天）');
        
        // 獲取多日賽程時也同步更新備援
        _saveToPersistentCache(realMatches);
        
        return realMatches;
      }
      debugPrint('⚠ 網路數據為空，切換到模擬數據');
    } catch (e) {
      debugPrint('❌ 獲取數據失敗: $e，切換到模擬數據');
      // 嘗試載入離線備援
      final offlineBackup = await _loadFromPersistentCache();
      if (offlineBackup != null && offlineBackup.isNotEmpty) {
        return offlineBackup;
      }
    }
    return _mockDataService.getTodaysFixtures();
  }

  /// 獲取特定運動的比賽
  Future<List<MatchFixture>> getMatchesBySport(SportType sport) async {
    final allMatches = await getTodaysMatches();
    return allMatches.where((m) => m.sport == sport).toList();
  }

  /// 獲取足球比賽
  Future<List<MatchFixture>> getFootballMatches() =>
      getMatchesBySport(SportType.football);

  /// 獲取籃球比賽
  Future<List<MatchFixture>> getBasketballMatches() =>
      getMatchesBySport(SportType.basketball);

  /// 獲取棒球比賽
  Future<List<MatchFixture>> getBaseballMatches() =>
      getMatchesBySport(SportType.baseball);

  // ==================== 🎯 預測功能 ====================

  /// App session 級預測快取：確保同一場比賽在所有頁面顯示完全相同的數據
  /// key = fixture.id；app 重啟後清空，符合「每次開啟重新算」的預期
  static final Map<String, MatchPrediction> _sessionPredCache = {};

  /// 清除 session 快取（測試 / 強制刷新用）
  static void clearPredictionCache() => _sessionPredCache.clear();

  /// 預測單場比賽（自動套用歷史偏差修正與 Remote Config ML 權重）
  /// 同一 fixture.id 在同一 session 內只計算一次，所有頁面共用同一結果
  MatchPrediction predictMatch(MatchFixture fixture) {
    final cached = _sessionPredCache[fixture.id];
    if (cached != null) return cached;
    final bias = _biasDataByType[fixture.sport];
    final mlWeights = RemoteConfigService().soccerWeightsNotifier.value;
    final lrCoeffs = _leagueRegressionCoeffs[fixture.league] ?? {};
    final homeNewsMult = SportsNewsService.getNewsModifier(
        fixture.homeForm.teamId, fixture.sport, league: fixture.league);
    final awayNewsMult = SportsNewsService.getNewsModifier(
        fixture.awayForm.teamId, fixture.sport, league: fixture.league);
    // 大小分 AI 偏差修正（學習莊家開分習慣）
    final ouMult = _ouBiasMultipliers[fixture.sport] ?? 1.0;
    final result = _predictionEngine.predictScore(
      fixture,
      bias: bias,
      mlWeights: mlWeights,
      linearRegressionCoeffs: lrCoeffs,
      lineupHomeMultiplier: homeNewsMult * ouMult,
      lineupAwayMultiplier: awayNewsMult * ouMult,
    );
    _sessionPredCache[fixture.id] = result;
    return result;
  }

  /// 帶陣容資料的加強版預測：根據實際球員數據微調 λ，提升命中率
  MatchPrediction predictMatchWithDetail(
    MatchFixture fixture, {
    BasketballGameDetail? basketballDetail,
    BaseballGameDetail? baseballDetail,
    SoccerGameDetail? soccerDetail,
  }) {
    // 新聞修正係數（傷兵/利多訊號）
    double homeMult = SportsNewsService.getNewsModifier(
        fixture.homeForm.teamId, fixture.sport, league: fixture.league);
    double awayMult = SportsNewsService.getNewsModifier(
        fixture.awayForm.teamId, fixture.sport, league: fixture.league);
    final coreInjuryDetails = <String>[];

    switch (fixture.sport) {
      case SportType.basketball:
        if (basketballDetail != null) {
          // ── 核心球員受傷鑑定 (Basketball Core Impact) ──────────────
          void checkBasketballCore(List<BaseballInjury> injuries, bool isHome) {
            for (final inj in injuries) {
              final ppgStr = basketballDetail.playerAvgPointsById[inj.playerName] ?? '0';
              final ppg = double.tryParse(ppgStr) ?? 0.0;
              // 門檻：場均 18 分以上或 PER > 20 被視為進攻核心
              if (ppg >= 18.0) {
                final penalty = (ppg / 100.0).clamp(0.08, 0.22);
                if (isHome) { homeMult *= (1.0 - penalty); } else { awayMult *= (1.0 - penalty); }
                coreInjuryDetails.add('🏀 ${isHome ? "主" : "客"}隊核心「${inj.playerName}」($ppg PPG) 缺陣，進攻體系受創。');
              }
            }
          }
          final homeInjs = basketballDetail.injuries.where((i) => i.team.contains(fixture.homeTeam)).toList();
          final awayInjs = basketballDetail.injuries.where((i) => i.team.contains(fixture.awayTeam)).toList();
          checkBasketballCore(homeInjs, true);
          checkBasketballCore(awayInjs, false);

          // ── PER 修正（聯盟基準 15.0）────────────────────────────
          final homePer = basketballDetail.homePlayerEfficiencyRating;
          final awayPer = basketballDetail.awayPlayerEfficiencyRating;
          if (homePer > 0) homeMult *= (0.90 + (homePer / 15.0) * 0.10).clamp(0.85, 1.15);
          if (awayPer > 0) awayMult *= (0.90 + (awayPer / 15.0) * 0.10).clamp(0.85, 1.15);

          // ── 球星 PPG（前三主力，頂級球星 ≥ 25 PPG）────────────
          final homeScores = (basketballDetail.homeLineup
              .map((p) => double.tryParse(p.avgPoints) ?? 0.0)
              .toList()..sort((a, b) => b.compareTo(a)));
          final awayScores = (basketballDetail.awayLineup
              .map((p) => double.tryParse(p.avgPoints) ?? 0.0)
              .toList()..sort((a, b) => b.compareTo(a)));
          if (homeScores.isNotEmpty) {
            final starAvg = homeScores.take(3).fold(0.0, (s, v) => s + v) /
                homeScores.take(3).length;
            homeMult *= (0.92 + (starAvg / 25.0) * 0.08).clamp(0.90, 1.10);
          }
          if (awayScores.isNotEmpty) {
            final starAvg = awayScores.take(3).fold(0.0, (s, v) => s + v) /
                awayScores.take(3).length;
            awayMult *= (0.92 + (starAvg / 25.0) * 0.08).clamp(0.90, 1.10);
          }

          // ── 四因子分析 (Four Factors) ─────────────────────────
          double statVal(Map<String, String> stats, List<String> keys) {
            for (final k in keys) {
              final v = double.tryParse(stats[k] ?? '');
              if (v != null && v > 0) return v;
            }
            return -1.0;
          }

          final homeEfg = statVal(basketballDetail.homeTeamStats,
              ['eFGPct', 'eFG%', 'eFG', 'effectiveFieldGoalPct']);
          final awayEfg = statVal(basketballDetail.awayTeamStats,
              ['eFGPct', 'eFG%', 'eFG', 'effectiveFieldGoalPct']);
          // eFG% 聯盟均值 ~51% (0.51)；ESPN 有時以百分比整數格式提供
          if (homeEfg > 0) {
            final efg = homeEfg > 1.0 ? homeEfg / 100 : homeEfg;
            homeMult *= (efg / 0.51).clamp(0.88, 1.12);
          }
          if (awayEfg > 0) {
            final efg = awayEfg > 1.0 ? awayEfg / 100 : awayEfg;
            awayMult *= (efg / 0.51).clamp(0.88, 1.12);
          }

          final homeTov = statVal(basketballDetail.homeTeamStats,
              ['TOV%', 'tovPct', 'turnoverPct', 'TOV']);
          final awayTov = statVal(basketballDetail.awayTeamStats,
              ['TOV%', 'tovPct', 'turnoverPct', 'TOV']);
          // TOV% 聯盟均值 ~13%；超過 → 進攻效率下降
          if (homeTov > 0) {
            homeMult *= (1.0 - ((homeTov > 1 ? homeTov : homeTov * 100) - 13.0)
                .clamp(0.0, 8.0) * 0.006).clamp(0.93, 1.0);
          }
          if (awayTov > 0) {
            awayMult *= (1.0 - ((awayTov > 1 ? awayTov : awayTov * 100) - 13.0)
                .clamp(0.0, 8.0) * 0.006).clamp(0.93, 1.0);
          }
          // 崩盤係數：失誤率差距 > 5% → 高失誤隊被拉開
          if (homeTov > 0 && awayTov > 0) {
            final hTov = homeTov > 1 ? homeTov : homeTov * 100;
            final aTov = awayTov > 1 ? awayTov : awayTov * 100;
            if (hTov - aTov > 5.0) { homeMult *= 0.95; awayMult *= 1.03; }
            else if (aTov - hTov > 5.0) { awayMult *= 0.95; homeMult *= 1.03; }
          }

          final homeOrb = statVal(basketballDetail.homeTeamStats,
              ['ORB%', 'orbPct', 'offensiveReboundPct', 'ORB']);
          final awayOrb = statVal(basketballDetail.awayTeamStats,
              ['ORB%', 'orbPct', 'offensiveReboundPct', 'ORB']);
          // ORB% 聯盟均值 ~23%；高 ORB → 更多二次進攻機會
          if (homeOrb > 0) {
            final orb = homeOrb > 1 ? homeOrb : homeOrb * 100;
            homeMult *= (1.0 + (orb - 23.0).clamp(-8.0, 8.0) * 0.003).clamp(0.95, 1.05);
          }
          if (awayOrb > 0) {
            final orb = awayOrb > 1 ? awayOrb : awayOrb * 100;
            awayMult *= (1.0 + (orb - 23.0).clamp(-8.0, 8.0) * 0.003).clamp(0.95, 1.05);
          }

          // ── Pace 節奏（雙方平均 → 影響總分）────────────────────
          final homePace = statVal(basketballDetail.homeTeamStats,
              ['pace', 'PACE', 'possessions']);
          final awayPace = statVal(basketballDetail.awayTeamStats,
              ['pace', 'PACE', 'possessions']);
          if (homePace > 50 && awayPace > 50) {
            // NBA 均值 ~100 poss/48min；高節奏 → 雙方分數同步提升
            final avgPace = (homePace + awayPace) / 2;
            final paceFactor = (avgPace / 100.0).clamp(0.93, 1.08);
            homeMult *= paceFactor;
            awayMult *= paceFactor;
          }

          // ── 主客場實際戰績修正 ───────────────────────────────────
          final homeRec = PredictionEngine._parseWinRecord(basketballDetail.homeHomeRecord);
          final awayRec = PredictionEngine._parseWinRecord(basketballDetail.awayRoadRecord);
          if (homeRec != null) {
            homeMult *= (1.0 + (homeRec.$1 - 0.60) * 0.25).clamp(0.92, 1.12);
          }
          if (awayRec != null) {
            final penalty = (0.40 - awayRec.$1) * 0.25;
            if (penalty > 0) awayMult *= (1.0 - penalty).clamp(0.90, 1.0);
          }
        }

      case SportType.baseball:
        if (baseballDetail != null) {
          // ── 投手與強棒鑑定 (Baseball Core Impact) ────────────────
          void checkBaseballCore(List<BaseballInjury> injuries, bool isHome) {
            final probablePitcher = isHome ? fixture.homeProbablePitcher : fixture.awayProbablePitcher;
            for (final inj in injuries) {
              if (inj.playerName == probablePitcher && probablePitcher.isNotEmpty) {
                // 主力投手缺陣：自己防守變弱（對手 λ 上調），自己進攻信心也降
                if (isHome) { awayMult *= 1.15; homeMult *= 0.95; } else { homeMult *= 1.15; awayMult *= 0.95; }
                coreInjuryDetails.add('⚾ ${isHome ? "主" : "客"}隊先發投手「${inj.playerName}」臨時缺陣，防線面臨壓力。');
              }
              final avg = double.tryParse(baseballDetail.batterAvgByPlayerId[inj.playerName] ?? '0') ?? 0.0;
              if (avg >= 0.280) {
                if (isHome) { homeMult *= 0.93; } else { awayMult *= 0.93; }
                coreInjuryDetails.add('⚾ ${isHome ? "主" : "客"}隊強棒「${inj.playerName}」(AVG $avg) 缺陣，火力銜接恐斷層。');
              }
            }
          }
          checkBaseballCore(baseballDetail.injuries, true);
          checkBaseballCore(baseballDetail.injuries, false);

          // 打線整體打擊率（聯盟均值 ~0.250）：每 0.010 差異 ≈ 4% λ 調整
          final homeLineup = baseballDetail.homeLineup;
          final awayLineup = baseballDetail.awayLineup;
          if (homeLineup.isNotEmpty) {
            final avg = homeLineup
                    .map((p) => double.tryParse(p.battingAvg) ?? 0.250)
                    .fold(0.0, (s, v) => s + v) /
                homeLineup.length;
            homeMult *= (1.0 + (avg - 0.250) * 4.0).clamp(0.88, 1.12);
          }
          if (awayLineup.isNotEmpty) {
            final avg = awayLineup
                    .map((p) => double.tryParse(p.battingAvg) ?? 0.250)
                    .fold(0.0, (s, v) => s + v) /
                awayLineup.length;
            awayMult *= (1.0 + (avg - 0.250) * 4.0).clamp(0.88, 1.12);
          }

          // ── 主客場實際戰績修正 ──────────────────────────────────
          // MLB/CPBL 主場平均勝率 ~54%；反映球場熟悉度與主場打擊優勢
          final homeRec = PredictionEngine._parseWinRecord(baseballDetail.homeHomeRecord);
          final awayRec = PredictionEngine._parseWinRecord(baseballDetail.awayRoadRecord);
          if (homeRec != null) {
            final bonus = (homeRec.$1 - 0.54) * 0.30;
            homeMult *= (1.0 + bonus).clamp(0.90, 1.10);
          }
          if (awayRec != null) {
            final penalty = (0.46 - awayRec.$1) * 0.25;
            if (penalty > 0) awayMult *= (1.0 - penalty).clamp(0.90, 1.0);
          }
        }

      case SportType.football:
        if (soccerDetail != null) {
          // ── 進球機器鑑定 (Soccer Core Impact) ───────────────────
          for (final inj in soccerDetail.injuries) {
            final player = [...soccerDetail.homeLineup, ...soccerDetail.awayLineup]
                .firstWhere((p) => p.name == inj.playerName, orElse: () => const SoccerPlayer(name: '', playerId: '', position: '', jerseyNumber: '', goals: '', assists: '', isStarter: false));
            final goals = int.tryParse(player.goals) ?? 0;
            if (goals >= 8) {
              final isHome = soccerDetail.homeLineup.any((p) => p.name == inj.playerName);
              if (isHome) { homeMult *= 0.90; } else { awayMult *= 0.90; }
              coreInjuryDetails.add('⚽ ${isHome ? "主" : "客"}隊射手「${inj.playerName}」(本季 $goals 球) 缺陣，得分效率將下降。');
            }
          }

          final homeStarters = soccerDetail.homeLineup.where((p) => p.isStarter).toList();
          final awayStarters = soccerDetail.awayLineup.where((p) => p.isStarter).toList();

          // ── 禁賽球員：每人削減 4% 進攻力 ───────────────────────────
          final homeSuspended = soccerDetail.suspensions.where((s) => s.teamSide == 'home').length;
          final awaySuspended = soccerDetail.suspensions.where((s) => s.teamSide == 'away').length;
          homeMult *= (1.0 - homeSuspended * 0.04).clamp(0.84, 1.0);
          awayMult *= (1.0 - awaySuspended * 0.04).clamp(0.84, 1.0);

          // ── 位置判斷工具 ──────────────────────────────────────────
          bool isGK(SoccerPlayer p) {
            final pos = p.position.toUpperCase();
            return pos == 'GK' || pos == 'G' || pos == 'POR';
          }
          bool isCB(SoccerPlayer p) {
            final pos = p.position.toUpperCase();
            return pos == 'CB' || pos == 'DC' || pos == 'CD' ||
                pos == 'CB' || pos == 'SW' || pos == 'LCB' || pos == 'RCB';
          }
          bool isMidOrAtt(SoccerPlayer p) => !isGK(p) && !isCB(p) &&
              !p.position.toUpperCase().contains('RB') &&
              !p.position.toUpperCase().contains('LB');
          bool isFW(SoccerPlayer p) {
            final pos = p.position.toUpperCase();
            return pos == 'ST' || pos == 'CF' || pos == 'SS' ||
                pos == 'FW' || pos == 'LW' || pos == 'RW' ||
                pos == 'ATT' || pos == 'F';
          }

          // ── GK / 後防領袖（決定「零封」能力）────────────────────
          final homeHasGK = homeStarters.isEmpty || homeStarters.any(isGK);
          final awayHasGK = awayStarters.isEmpty || awayStarters.any(isGK);
          final homeCBs = homeStarters.where(isCB).length;
          final awayCBs = awayStarters.where(isCB).length;

          // 無 GK 上場 → 對手進球率 +12%
          if (!homeHasGK) awayMult *= 1.12;
          if (!awayHasGK) homeMult *= 1.12;
          // 中衛不足（正常 2 人）→ 每缺 1 人 +6% 對手進球
          if (homeStarters.isNotEmpty && homeCBs < 2) {
            awayMult *= (1.0 + (2 - homeCBs) * 0.06).clamp(1.0, 1.12);
          }
          if (awayStarters.isNotEmpty && awayCBs < 2) {
            homeMult *= (1.0 + (2 - awayCBs) * 0.06).clamp(1.0, 1.12);
          }

          // ── 中場大腦（進攻上限）─────────────────────────────────
          // 高助攻中前場球員（≥ 5 次助攻）= 關鍵餵球手
          final homePlaymakers = homeStarters
              .where((p) => isMidOrAtt(p) && (int.tryParse(p.assists) ?? 0) >= 5)
              .length;
          final awayPlaymakers = awayStarters
              .where((p) => isMidOrAtt(p) && (int.tryParse(p.assists) ?? 0) >= 5)
              .length;
          // 每名主力餵球手 +5% 進攻力
          homeMult *= (1.0 + homePlaymakers * 0.05).clamp(1.0, 1.10);
          awayMult *= (1.0 + awayPlaymakers * 0.05).clamp(1.0, 1.10);

          // ── 關鍵射手（破門能力）─────────────────────────────────
          // 賽季 ≥ 8 球的前鋒 → 各加 3% 進攻力
          final homeKeyScorers = homeStarters
              .where((p) => (int.tryParse(p.goals) ?? 0) >= 8).length;
          final awayKeyScorers = awayStarters
              .where((p) => (int.tryParse(p.goals) ?? 0) >= 8).length;
          homeMult *= (1.0 + homeKeyScorers * 0.03).clamp(1.0, 1.09);
          awayMult *= (1.0 + awayKeyScorers * 0.03).clamp(1.0, 1.09);

          // ── 前鋒火力充足 → 破密集防守能力 ──────────────────────
          final homeFWGoals = homeStarters.where(isFW)
              .fold(0, (sum, p) => sum + (int.tryParse(p.goals) ?? 0));
          final awayFWGoals = awayStarters.where(isFW)
              .fold(0, (sum, p) => sum + (int.tryParse(p.goals) ?? 0));
          if (homeFWGoals > 15) homeMult *= 1.05;
          if (awayFWGoals > 15) awayMult *= 1.05;

          // ── xG 直接代理（若 ESPN 提供本場預期進球數）───────────
          final homeXg = double.tryParse(
              soccerDetail.homeTeamStats['expectedGoals'] ??
              soccerDetail.homeTeamStats['xG'] ?? '');
          final awayXg = double.tryParse(
              soccerDetail.awayTeamStats['expectedGoals'] ??
              soccerDetail.awayTeamStats['xG'] ?? '');
          if (homeXg != null && homeXg > 0.2) {
            // 高 xG → 進攻火力確實強；低 xG → 運氣進球 → 修正
            homeMult *= (homeXg / 1.35).clamp(0.80, 1.20);
          }
          if (awayXg != null && awayXg > 0.2) {
            awayMult *= (awayXg / 1.35).clamp(0.80, 1.20);
          }

          // ── 盃賽 / 歐冠淘汰賽 → 雙方保守，進球偏低 ───────────
          final isCupTie = fixture.league.contains('Cup') ||
              fixture.league.contains('盃') ||
              fixture.league.contains('Copa') ||
              fixture.league.contains('Coupe') ||
              fixture.league.contains('Pokal') ||
              fixture.league.contains('Champions') ||
              fixture.league.contains('Europa') ||
              fixture.league.contains('歐冠') ||
              fixture.league.contains('歐聯') ||
              fixture.league.contains('Conference');
          if (isCupTie) {
            homeMult *= 0.93;
            awayMult *= 0.93;
          }
        }
    }

    final bias = _biasDataByType[fixture.sport];
    final mlWeights = RemoteConfigService().soccerWeightsNotifier.value;
    final lrCoeffs = _leagueRegressionCoeffs[fixture.league] ?? {};
    final prediction = _predictionEngine.predictScore(
      fixture,
      bias: bias,
      mlWeights: mlWeights,
      linearRegressionCoeffs: lrCoeffs,
      lineupHomeMultiplier: homeMult,
      lineupAwayMultiplier: awayMult,
    );

    // 注入核心傷兵與詳細名單細節
    final allInjuryNotes = <String>[
      ...coreInjuryDetails,
      if (soccerDetail != null)
        for (final inj in soccerDetail.injuries)
          if (inj.playerName.isNotEmpty)
            '⛑️ 傷兵：${inj.team.isNotEmpty ? "${inj.team} " : ""}${inj.playerName}${inj.status.isNotEmpty ? " — ${inj.status}" : ""}${inj.description.isNotEmpty ? " (${inj.description})" : ""}',
    ];
    if (allInjuryNotes.isNotEmpty) {
      prediction.keyFactors.insertAll(0, allInjuryNotes);
    }

    // 注入新聞標題摘要（各隊最多 2 則）
    final homeNews = SportsNewsService.getCachedNews(
        fixture.homeForm.teamId, fixture.sport);
    final awayNews = SportsNewsService.getCachedNews(
        fixture.awayForm.teamId, fixture.sport);
    final newsNotes = <String>[
      for (final n in homeNews.take(2))
        '${n.isNegative ? "⚠️" : n.isPositive ? "✅" : "📰"} ${fixture.homeTeam}：${n.headline}',
      for (final n in awayNews.take(2))
        '${n.isNegative ? "⚠️" : n.isPositive ? "✅" : "📰"} ${fixture.awayTeam}：${n.headline}',
    ];
    if (newsNotes.isNotEmpty) {
      prediction.keyFactors.addAll(newsNotes);
    }

    return prediction;
  }

  /// 取得目前各運動的偏差修正狀態
  Map<SportType, SportBiasData> getBiasDataSnapshot() => Map.unmodifiable(_biasDataByType);

  /// 強制重新從歷史紀錄學習所有預測偏差（體育 + 539 + 賓果）
  Future<void> triggerBiasRefresh() async {
    try {
      debugPrint('🤖 AI 正在自主抓取結束比賽及開獎號碼進行學習...');
      final sportsMatches = await RealDataService.fetchMatchesForDays(days: 5);
      final lotteryData = await LotteryService().fetchAndAnalyze();
      final bingoRecords = await BingoService().fetchRecent(forceRefresh: true);

      final sportScores = <String, (int, int)>{};
      for (final m in sportsMatches) {
        if (m.status == MatchStatus.completed) {
          sportScores[m.id] = (m.homeScore, m.awayScore);
        }
      }

      final lottoByDate = <String, List<int>>{};
      for (final r in lotteryData.records539) {
        if (r.date.isNotEmpty && r.numbers.isNotEmpty) lottoByDate[r.date] = r.numbers;
      }

      final bingoByDrawNo = <int, List<int>>{};
      for (final r in bingoRecords) {
        if (r.numbers.isNotEmpty) bingoByDrawNo[r.drawNo] = r.numbers;
      }

      final logSvc = PredictionLogService();
      await logSvc.autoReportSportsByMatchId(sportScores);
      await logSvc.autoReportLotteryByDate(lottoByDate);
      await logSvc.autoReportBingoByDrawNo(bingoByDrawNo);
    } catch (e) {
      debugPrint('⚠️ AI 自主學習抓取失敗: $e');
    }

    await Future.wait([_loadBiasData(), _loadLotteryLearning()]);
  }

  /// 取得樂透 / 賓果 AI 學習結果快照（'lottery539' / 'bingo'）
  Map<String, LotteryLearningData> getLotteryLearningSnapshot() =>
      Map.unmodifiable(_lotteryLearningByType);

  /// 獲取所有今日預測
  Future<List<PredictionResult>> getTodaysPredictions() async {
    final today = DateTime.now();
    final dateKey = _formatDate(today);

    // 檢查快取
    if (_lastCacheDate != null &&
        _formatDate(_lastCacheDate!) == dateKey &&
        _predictionCache.containsKey(dateKey)) {
      return _predictionCache[dateKey]!;
    }

    // 獲取今天的比賽，先去重再預測（同一場只留一個）
    final rawMatches = await getTodaysMatches();
    final matches = <MatchFixture>[];
    for (final m in rawMatches) {
      final dup = matches.cast<MatchFixture?>().firstWhere(
        (e) => e != null && _isSameMatch(e, m),
        orElse: () => null,
      );
      if (dup == null) {
        matches.add(m);
      } else if (!dup.odds.isFromBookmaker && m.odds.isFromBookmaker) {
        // 以有真實賭盤賠率的資料源取代
        matches[matches.indexOf(dup)] = m;
      }
    }
    final predictions = <PredictionResult>[];

    for (final match in matches) {
      try {
        final prediction = predictMatch(match);
        predictions.add(
          PredictionResult(
            fixture: match,
            prediction: LiveMatchPrediction(
              matchId: match.id,
              predictedHomeScore: prediction.predictedHomeScore,
              predictedAwayScore: prediction.predictedAwayScore,
              confidence: prediction.confidence,
              impliedHomeStrength: prediction.impliedHomeStrength,
              impliedAwayStrength: prediction.impliedAwayStrength,
              summary: prediction.summary,
              keyFactors: prediction.keyFactors,
              upsetAlert: prediction.upsetAlert,
              injuryWarning: prediction.injuryWarning,
              kellyHome: prediction.kellyHome,
              kellyAway: prediction.kellyAway,
              mcModeHomeScore: prediction.mcModeHomeScore,
              mcModeAwayScore: prediction.mcModeAwayScore,
              ensembleHomeWinPct: prediction.ensembleHomeWinPct,
              ensembleDrawPct: prediction.ensembleDrawPct,
              ensembleAwayWinPct: prediction.ensembleAwayWinPct,
              poissonHomeWinPct: prediction.poissonHomeWinPct,
              poissonDrawPct: prediction.poissonDrawPct,
              poissonAwayWinPct: prediction.poissonAwayWinPct,
              marketMovement: prediction.marketMovement,
              overround: prediction.overround,
              lastUpdate: DateTime.now(),
            ),
            predictionTime: DateTime.now(),
            predictionDate: dateKey,
          ),
        );
      } catch (e) {
        debugPrint('❌ 預測比賽 ${match.id} 失敗: $e');
      }
    }

    // 快取結果
    _predictionCache[dateKey] = predictions;
    _lastCacheDate = today;
    
    // 🚀 依信心指數由高到低排序：讓使用者一開起 APP 就能看到最有把握的比賽
    predictions.sort((a, b) => b.prediction.confidence.compareTo(a.prediction.confidence));

    debugPrint('✅ 成功預測 ${predictions.length} 場比賽');
    return predictions;
  }

  /// 獲取特定日期的預測
  Future<List<PredictionResult>> getPredictionsForDate(DateTime date) async {
    final dateKey = _formatDate(date);

    if (_predictionCache.containsKey(dateKey)) {
      return _predictionCache[dateKey]!;
    }

    // 返回空列表（歷史預測需要從存檔中讀取）
    return [];
  }

  // ==================== ⚡ 直播追蹤 ====================

  /// 開始追蹤直播比賽
  void startLiveTracking() {
    if (_liveUpdateTimer != null) return;

    _liveUpdateTimer = Timer.periodic(
      const Duration(seconds: 30),
      (_) async {
        final matches = await getTodaysMatches();
        for (final match in matches) {
          // 構造直播更新
          final update = LiveMatchUpdate(
            matchId: match.id,
            homeTeam: match.homeTeam,
            awayTeam: match.awayTeam,
            homeScore: 0,
            awayScore: 0,
            matchStatus: 'scheduled',
            updateTime: DateTime.now(),
          );

          _cachedLiveMatches[match.id] = update;

          // 發送到訂閱者
          if (_liveStreams.containsKey(match.id)) {
            _liveStreams[match.id]!.add(update);
          }
        }
      },
    );
    debugPrint('✅ 直播追蹤已啟動');
  }

  /// 停止直播追蹤
  void stopLiveTracking() {
    _liveUpdateTimer?.cancel();
    _liveUpdateTimer = null;
    debugPrint('⏹️ 直播追蹤已停止');
  }

  /// 獲取直播比賽列表
  Future<List<MatchFixture>> getLiveMatches() => getTodaysMatches();

  /// 訂閱特定比賽的直播更新
  Stream<LiveMatchUpdate> subscribeLiveMatch(String matchId) {
    if (!_liveStreams.containsKey(matchId)) {
      _liveStreams[matchId] = StreamController<LiveMatchUpdate>.broadcast();
    }

    // 如果已有快取，立即發送
    if (_cachedLiveMatches.containsKey(matchId)) {
      _liveStreams[matchId]!.add(_cachedLiveMatches[matchId]!);
    }

    return _liveStreams[matchId]!.stream;
  }

  // ==================== 💾 存檔管理 ====================

  /// 保存已完成的比賽
  void archiveMatch({
    required MatchFixture fixture,
    required int homeScore,
    required int awayScore,
    String status = 'completed',
  }) {
    _archiveService.archiveMatch(
      fixture: fixture,
      homeScore: homeScore,
      awayScore: awayScore,
      status: status,
    );
    debugPrint('✅ 比賽已存檔: ${fixture.homeTeam} vs ${fixture.awayTeam}');
  }

  /// 獲取所有存檔比賽
  List<ArchivedMatch> getAllArchivedMatches() {
    return _archiveService.getAllArchive();
  }

  /// 獲取特定日期的存檔
  List<ArchivedMatch> getArchivedMatchesByDate(DateTime date) {
    return _archiveService.getArchiveByDate(date);
  }

  /// 獲取特定聯賽的存檔
  List<ArchivedMatch> getArchivedMatchesByLeague(String league) {
    return _archiveService.getArchiveByLeague(league);
  }

  /// 獲取最近的比賽
  List<ArchivedMatch> getRecentMatches({int limit = 10}) {
    return _archiveService.getRecentArchive(limit: limit);
  }

  /// 獲取球隊的所有比賽記錄
  List<ArchivedMatch> getTeamMatches(String teamName) {
    return _archiveService.getTeamArchive(teamName);
  }

  /// 獲取球隊統計
  Map<String, dynamic> getTeamStats(String teamName) {
    return _archiveService.getTeamStats(teamName);
  }

  /// 獲取聯賽排行榜
  List<Map<String, dynamic>> getLeagueStandings(String league) {
    return _archiveService.getLeagueStandings(league);
  }

  /// 獲取存檔統計信息
  Map<String, dynamic> getArchiveStats() {
    final all = getAllArchivedMatches();
    return {
      'total_matches': all.length,
      'last_update': DateTime.now().toIso8601String(),
    };
  }

  // ==================== ⚙️ 配置管理 ====================

  /// 切換數據源
  void switchDataSource(bool useReal) {
    _useRealData = useReal;
    clearCache();
    debugPrint('🔄 已切換至${useReal ? '真實' : '模擬'}數據源');
  }

  /// 私有方法：清理直播相關的控制器與快取
  void _clearLiveResources() {
    for (final controller in _liveStreams.values) {
      controller.close();
    }
    _liveStreams.clear();
    _cachedLiveMatches.clear();
    debugPrint('🗑️ 已清理直播相關資源 (Streams & Live Cache)');
  }

  /// 清除所有快取
  void clearCache() {
    _predictionCache.clear();
    _lastCacheDate = null;
    _matchCache = null;
    _matchCacheTime = null;
    debugPrint('🗑️ 快取已清除');
  }

  /// 同賽區完賽通知：由 LatestMatchesScreen 呼叫
  /// 當偵測到某聯賽有「新完賽」比賽時，清除快取並通知 HomeScreen 刷新預測
  void notifyLeagueMatchCompleted(String league) {
    clearCache();
    // 重新計算偏差修正（新比賽完賽後結果會更新）
    _loadBiasData();
    predictionRefreshNotifier.value++;
    debugPrint('🔔 [$league] 有比賽結束，已通知 HomeScreen 刷新預測 (count=${predictionRefreshNotifier.value})');
  }

  /// 啟用每日自動更新
  void enableDailyUpdates() {
    if (_isDailyUpdateEnabled) return;
    _isDailyUpdateEnabled = true;
    _startDailyUpdateCheck();
    debugPrint('📅 每日自動更新已啟用');
  }

  /// 禁用每日自動更新
  void disableDailyUpdates() {
    if (!_isDailyUpdateEnabled) return;
    _isDailyUpdateEnabled = false;
    _dailyUpdateTimer?.cancel();
    _dailyUpdateTimer = null;
    debugPrint('📅 每日自動更新已禁用');
  }

  /// 手動觸發一次每日更新（用於測試或立即更新）
  Future<void> manualDailyUpdate() async {
    debugPrint('🔄 手動觸發每日更新...');
    await _performDailyUpdate();
  }

  /// 獲取每日更新狀態
  Map<String, dynamic> getDailyUpdateStatus() {
    final today = DateTime.now();
    return {
      'dailyUpdatesEnabled': _isDailyUpdateEnabled,
      'lastUpdateDate': _lastDailyUpdateDate?.toIso8601String(),
      'currentDate': today.toIso8601String(),
      'nextUpdateTime': _lastDailyUpdateDate == null
          ? '立即更新'
          : _formatDate(_lastDailyUpdateDate!) == _formatDate(today)
              ? '明天午夜'
              : '立即更新',
    };
  }

  /// 刷新所有數據
  Future<void> refreshAllData() async {
    clearCache();
    await Future.wait([
      getTodaysMatches(),
      getTodaysPredictions(),
      getLiveMatches(),
    ]);
    debugPrint('🔄 所有數據已刷新');
  }

  /// 獲取應用信息
  Map<String, dynamic> getAppInfo() {
    return {
      'appName': '🏋️ 胖胖體育',
      'version': '1.0.0',
      'useRealData': _useRealData,
      'cachedPredictions': _predictionCache.length,
      'archivedMatches': getAllArchivedMatches().length,
      'dailyUpdatesEnabled': _isDailyUpdateEnabled,
      'lastDailyUpdateDate': _lastDailyUpdateDate?.toIso8601String(),
      'timestamp': DateTime.now().toIso8601String(),
    };
  }

  /// 獲取服務健康狀態
  Future<Map<String, bool>> getServiceHealth() async {
    return {
      'dataService': true,
      'predictionEngine': true,
      'archiveService': true,
      'liveTracking': _liveUpdateTimer != null,
    };
  }

  // ==================== 🛠️ 工具方法 ====================

  /// 🚀 離線備援：將賽事列表序列化並保存至本地磁碟
  Future<void> _saveToPersistentCache(List<MatchFixture> matches) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      
      // 安全檢查：若模型未實作 toJson 則跳過，防止背景崩潰
      final List<Map<String, dynamic>> jsonList = matches
          .map((m) {
            try {
              return (m as dynamic).toJson() as Map<String, dynamic>;
            } catch (_) { return null; }
          })
          .whereType<Map<String, dynamic>>()
          .toList();
      
      await prefs.setString(_persistentMatchesKey, jsonEncode(jsonList));
      await prefs.setInt(_persistentTimestampKey, DateTime.now().millisecondsSinceEpoch);
      debugPrint('💾 離線備援數據已同步至本地存儲');
    } catch (e) {
      debugPrint('⚠️ 無法保存離線備援 (可能 MatchFixture 缺少 toJson): $e');
    }
  }

  /// 🚀 離線備援：從本地磁碟載入歷史賽事數據
  Future<List<MatchFixture>?> _loadFromPersistentCache() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final jsonStr = prefs.getString(_persistentMatchesKey);
      final timestamp = prefs.getInt(_persistentTimestampKey);
      
      if (jsonStr == null || timestamp == null) return null;

      // 效度檢查：如果離線數據超過 48 小時，則視為過期（賽事已無時效性）
      final savedDate = DateTime.fromMillisecondsSinceEpoch(timestamp);
      if (DateTime.now().difference(savedDate).inHours > 48) {
        debugPrint('ℹ️ 離線備援數據已超過 48 小時，放棄採用');
        return null;
      }

      final List<dynamic> decoded = jsonDecode(jsonStr);
      // 假設 MatchFixture 已實作 fromJson 工廠方法
      return decoded.map((item) {
        try {
          return MatchFixture.fromJson(item as Map<String, dynamic>);
        } catch (_) {
          return null;
        }
      }).whereType<MatchFixture>().toList();
    } catch (e) {
      debugPrint('⚠️ 讀取離線備援失敗: $e');
      return null;
    }
  }

  String _formatDate(DateTime date) {
    return '${date.year}-${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')}';
  }

  // ── 比賽合併工具 ───────────────────────────────────────────────

  /// 球隊名模糊比對：取第一個單詞比對，忽略大小寫
  /// 判斷兩場比賽是否為同一場（跨資料來源去重）
  /// 條件：同運動 + 開賽時間差 ≤90 分鐘 + 主客隊名稱任一方向吻合
  bool _isSameMatch(MatchFixture a, MatchFixture b) {
    if (a.sport != b.sport) return false;
    if (a.startTime.difference(b.startTime).inMinutes.abs() > 90) return false;
    // 正向比對
    if (_nameMatch(a.homeTeam, b.homeTeam) && _nameMatch(a.awayTeam, b.awayTeam)) return true;
    // 容錯：主客對調（某些資料源主客定義不同）
    if (_nameMatch(a.homeTeam, b.awayTeam) && _nameMatch(a.awayTeam, b.homeTeam)) return true;
    return false;
  }

  bool _nameMatch(String a, String b) {
    if (a == b) return true;
    final aL = a.toLowerCase();
    final bL = b.toLowerCase();
    if (aL.contains(bL) || bL.contains(aL)) return true;
    final aKey = aL.split(' ').first;
    final bKey = bL.split(' ').first;
    return aKey == bKey && aKey.length >= 3;
  }

  /// 清理資源
  void dispose() {
    stopLiveTracking();
    disableDailyUpdates();
    for (final controller in _liveStreams.values) {
      controller.close();
    }
    _liveStreams.clear();
    predictionRefreshNotifier.dispose();
    debugPrint('🧹 已清理所有資源');
  }
}

// ============================================
// 📱 支援類別
// ============================================

/// 直播比賽更新
class LiveMatchUpdate {
  const LiveMatchUpdate({
    required this.matchId,
    required this.homeTeam,
    required this.awayTeam,
    required this.homeScore,
    required this.awayScore,
    required this.matchStatus,
    required this.updateTime,
  });

  final String matchId;
  final String homeTeam;
  final String awayTeam;
  final int homeScore;
  final int awayScore;
  final String matchStatus; // 'scheduled', 'live', 'finished'
  final DateTime updateTime;

  @override
  String toString() =>
      '$homeTeam $homeScore : $awayScore $awayTeam [$matchStatus]';
}

/// 預測結果
class PredictionResult {
  const PredictionResult({
    required this.fixture,
    required this.prediction,
    required this.predictionTime,
    required this.predictionDate,
  });

  final MatchFixture fixture;
  final LiveMatchPrediction prediction;
  final DateTime predictionTime;
  final String predictionDate; // YYYY-MM-DD 格式
}

class _RegressionResult {
  final double slope;
  final double intercept;
  const _RegressionResult({required this.slope, required this.intercept});
}
