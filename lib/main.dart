import 'package:flutter/material.dart';
import 'package:firebase_core/firebase_core.dart';
import 'screens/main_navigation_screen.dart';
import 'services/pang_pang_sports_service.dart';

void main() async {
  // 確保 Flutter 引擎已初始化
  WidgetsFlutterBinding.ensureInitialized();
  
  // 初始化 Firebase (若專案已設定則啟用，這對 Remote Config ML 權重很重要)
  try {
    await Firebase.initializeApp();
  } catch (e) {
    debugPrint('⚠️ Firebase 初始化跳過：$e');
  }

  // 初始化體育預測單例服務，觸發背景緩存預熱與歷史偏差載入
  // 這能確保使用者「開起 APP」時，數據分析已經在後台運作
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
        // 採用 APP 統一配色：薄荷綠 (數據感) + 財神金 (樂透感)
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
      home: const _DisclaimerWrapper(),
    );
  }
}

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
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                decoration: BoxDecoration(
                  color: Color(0xFF1A2F5E),
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(color: Color(0xFFFFD700).withAlpha(80), width: 1),
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
                    style: TextStyle(fontWeight: FontWeight.w800, fontSize: 15),
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

class PasswordLockScreen extends StatefulWidget {
  const PasswordLockScreen({super.key});

  @override
  State<PasswordLockScreen> createState() => _PasswordLockScreenState();
}

class _PasswordLockScreenState extends State<PasswordLockScreen> {
  bool isAuthorized = false;
  final TextEditingController _passwordController = TextEditingController();
  
  // 🔒 密碼已經幫你改成專屬的這一長串了！
  final String correctPassword = "Boxeo@881219@Boxing24614360"; 

  @override
  Widget build(BuildContext context) {
    if (!isAuthorized) {
      return Scaffold(
        backgroundColor: const Color(0xFF121212),
        body: Center(
          child: Container(
            padding: const EdgeInsets.all(32),
            constraints: const BoxConstraints(maxWidth: 360),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.security, size: 70, color: Colors.orangeAccent),
                const SizedBox(height: 20),
                const Text(
                  "Pang Pang Sport 內部系統",
                  style: TextStyle(color: Colors.white, fontSize: 20, fontWeight: FontWeight.bold),
                ),
                const SizedBox(height: 30),
                TextField(
                  controller: _passwordController,
                  obscureText: true, // 自動把輸入的密碼遮起來
                  style: const TextStyle(color: Colors.white),
                  decoration: const InputDecoration(
                    labelText: "請輸入存取密碼",
                    labelStyle: TextStyle(color: Colors.grey),
                    focusedBorder: OutlineInputBorder(borderSide: BorderSide(color: Colors.orangeAccent)),
                  ),
                ),
                const SizedBox(height: 20),
                SizedBox(
                  width: double.infinity,
                  height: 45,
                  child: ElevatedButton(
                    style: ElevatedButton.styleFrom(backgroundColor: Colors.orangeAccent),
                    onPressed: () {
                      if (_passwordController.text == correctPassword) {
                        setState(() {
                          isAuthorized = true;
                        });
                      } else {
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(backgroundColor: Colors.redAccent, content: Text("密碼錯誤！")),
                        );
                      }
                    },
                    child: const Text("驗證並登入", style: TextStyle(color: Colors.black, fontWeight: FontWeight.bold)),
                  ),
                ),
              ],
            ),
          ),
        ),
      );
    }
    
    // 🔑 解鎖成功後，直接進入你原本的免責聲明主畫面
    return const Scaffold(body: Center(child: Text("解鎖成功！", style: TextStyle(color: Colors.white))));

 
  }
}
