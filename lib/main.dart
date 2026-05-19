import 'package:flutter/material.dart';
import 'package:firebase_core/firebase_core.dart';
import 'screens/main_navigation_screen.dart';
import 'services/pang_pang_sports_service.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  try {
    await Firebase.initializeApp();
  } catch (e) {
    debugPrint('⚠️ Firebase 初始化跳過：$e');
  }
  PangPangSportsService();
  runApp(const PangPangApp());
}

class PangPangApp extends StatelessWidget {
  const PangPangApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: '胖胖體育',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        brightness: Brightness.dark,
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF3DDC97),
          brightness: Brightness.dark,
          primary: const Color(0xFF3DDC97),
          secondary: const Color(0xFFFFD700),
        ),
        scaffoldBackgroundColor: const Color(0xFF050E24),
        appBarTheme: const AppBarTheme(
          backgroundColor: Colors.transparent,
          elevation: 0,
          centerTitle: true,
          titleTextStyle: TextStyle(
            fontSize: 20,
            fontWeight: FontWeight.w800,
            color: Colors.white,
          ),
        ),
        tabBarTheme: const TabBarThemeData(
          indicatorColor: Color(0xFF3DDC97),
          labelColor: Color(0xFF3DDC97),
          unselectedLabelColor: Colors.white54,
          labelStyle: TextStyle(fontWeight: FontWeight.w700, fontSize: 14),
        ),
      ),
      home: const _LoginScreen(),
    );
  }
}

// ── 密碼登入畫面 ────────────────────────────────────────────────────

class _LoginScreen extends StatefulWidget {
  const _LoginScreen();
  @override
  State<_LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<_LoginScreen> {
  static const _correctPassword = 'Boxeo@12191999';

  final _ctrl = TextEditingController();
  final _focus = FocusNode();
  bool _obscure = true;
  String _status = '';   // '' | 'ok' | 'wrong'
  bool _shaking = false;

  @override
  void dispose() {
    _ctrl.dispose();
    _focus.dispose();
    super.dispose();
  }

  void _submit() {
    final input = _ctrl.text.trim();
    if (input == _correctPassword) {
      setState(() => _status = 'ok');
      Future.delayed(const Duration(milliseconds: 500), () {
        if (!mounted) return;
        Navigator.of(context).pushReplacement(
          MaterialPageRoute(builder: (_) => const _DisclaimerWrapper()),
        );
      });
    } else {
      setState(() { _status = 'wrong'; _shaking = true; });
      Future.delayed(const Duration(milliseconds: 600), () {
        if (mounted) setState(() => _shaking = false);
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF050E24),
      body: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.symmetric(horizontal: 32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // 棒球 icon
              const Text('⚾', style: TextStyle(fontSize: 72)),
              const SizedBox(height: 16),
              const Text(
                '胖胖體育',
                style: TextStyle(
                  fontSize: 28,
                  fontWeight: FontWeight.w900,
                  color: Color(0xFFFFD700),
                  letterSpacing: 2,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                '請輸入密碼以進入',
                style: TextStyle(
                  fontSize: 14,
                  color: Colors.white.withAlpha(140),
                ),
              ),
              const SizedBox(height: 36),

              // 密碼輸入框（搖晃動畫）
              AnimatedSlide(
                offset: _shaking ? const Offset(0.03, 0) : Offset.zero,
                duration: const Duration(milliseconds: 80),
                curve: Curves.elasticOut,
                child: TextField(
                  controller: _ctrl,
                  focusNode: _focus,
                  obscureText: _obscure,
                  style: const TextStyle(color: Colors.white, fontSize: 16),
                  onSubmitted: (_) => _submit(),
                  decoration: InputDecoration(
                    hintText: '密碼',
                    hintStyle: TextStyle(color: Colors.white.withAlpha(80)),
                    filled: true,
                    fillColor: const Color(0xFF0D1E4A),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(12),
                      borderSide: BorderSide.none,
                    ),
                    enabledBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(12),
                      borderSide: BorderSide(
                        color: _status == 'wrong'
                            ? Colors.redAccent
                            : _status == 'ok'
                                ? const Color(0xFF3DDC97)
                                : const Color(0xFF1A3A7A),
                        width: 1.5,
                      ),
                    ),
                    focusedBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(12),
                      borderSide: BorderSide(
                        color: _status == 'wrong'
                            ? Colors.redAccent
                            : const Color(0xFFFFD700),
                        width: 2,
                      ),
                    ),
                    prefixIcon: const Icon(Icons.lock_outline,
                        color: Color(0xFFFFD700), size: 20),
                    suffixIcon: IconButton(
                      icon: Icon(
                        _obscure ? Icons.visibility_off : Icons.visibility,
                        color: Colors.white38,
                        size: 20,
                      ),
                      onPressed: () => setState(() => _obscure = !_obscure),
                    ),
                  ),
                ),
              ),

              const SizedBox(height: 12),

              // 狀態提示
              AnimatedSwitcher(
                duration: const Duration(milliseconds: 250),
                child: _status == 'wrong'
                    ? Row(
                        key: const ValueKey('wrong'),
                        mainAxisSize: MainAxisSize.min,
                        children: const [
                          Icon(Icons.cancel, color: Colors.redAccent, size: 16),
                          SizedBox(width: 6),
                          Text(
                            '密碼錯誤，請再試一次',
                            style: TextStyle(
                                color: Colors.redAccent,
                                fontSize: 13,
                                fontWeight: FontWeight.w600),
                          ),
                        ],
                      )
                    : _status == 'ok'
                        ? Row(
                            key: const ValueKey('ok'),
                            mainAxisSize: MainAxisSize.min,
                            children: const [
                              Icon(Icons.check_circle,
                                  color: Color(0xFF3DDC97), size: 16),
                              SizedBox(width: 6),
                              Text(
                                '密碼正確，進入中…',
                                style: TextStyle(
                                    color: Color(0xFF3DDC97),
                                    fontSize: 13,
                                    fontWeight: FontWeight.w600),
                              ),
                            ],
                          )
                        : const SizedBox(key: ValueKey('empty'), height: 20),
              ),

              const SizedBox(height: 20),

              // 確認按鈕
              SizedBox(
                width: double.infinity,
                child: ElevatedButton(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFFFFD700),
                    foregroundColor: Colors.black,
                    padding: const EdgeInsets.symmetric(vertical: 14),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                  ),
                  onPressed: _status == 'ok' ? null : _submit,
                  child: const Text(
                    '確認登入',
                    style: TextStyle(fontWeight: FontWeight.w800, fontSize: 16),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ── 免責聲明彈窗（密碼正確後顯示）────────────────────────────────────

class _DisclaimerWrapper extends StatefulWidget {
  const _DisclaimerWrapper();
  @override
  State<_DisclaimerWrapper> createState() => _DisclaimerWrapperState();
}

class _DisclaimerWrapperState extends State<_DisclaimerWrapper> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _showDisclaimer());
  }

  void _showDisclaimer() {
    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => Dialog(
        backgroundColor: const Color(0xFF0D1E4A),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(24, 28, 24, 20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text('⚾', style: TextStyle(fontSize: 48)),
              const SizedBox(height: 12),
              const Text(
                '胖胖體育',
                style: TextStyle(
                  fontSize: 22,
                  fontWeight: FontWeight.w900,
                  color: Color(0xFFFFD700),
                ),
              ),
              const SizedBox(height: 16),
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                decoration: BoxDecoration(
                  color: const Color(0xFF1A2F5E),
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(
                      color: const Color(0xFFFFD700).withAlpha(80), width: 1),
                ),
                child: const Text(
                  '⚠️  免責聲明\n\n本應用程式所有內容均為統計模型預測，'
                  '不構成任何投注建議。\n\n'
                  '以上皆為預測，盈虧自負。',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: 14,
                    color: Colors.white,
                    height: 1.6,
                  ),
                ),
              ),
              const SizedBox(height: 20),
              SizedBox(
                width: double.infinity,
                child: ElevatedButton(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFFFFD700),
                    foregroundColor: Colors.black,
                    padding: const EdgeInsets.symmetric(vertical: 14),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(10),
                    ),
                  ),
                  onPressed: () => Navigator.of(ctx).pop(),
                  child: const Text(
                    '我已了解，進入應用',
                    style:
                        TextStyle(fontWeight: FontWeight.w800, fontSize: 15),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) => const MainNavigationScreen();
}
