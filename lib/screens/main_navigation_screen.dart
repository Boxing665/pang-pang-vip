import 'package:flutter/material.dart';
import 'home_screen.dart';
import 'latest_matches_screen.dart';
import 'lottery_screen.dart';
import 'bingo_screen.dart';
import 'chart_analysis_screen.dart';
import 'unified_prediction_screen.dart';

class MainNavigationScreen extends StatefulWidget {
  const MainNavigationScreen({super.key});

  @override
  State<MainNavigationScreen> createState() => _MainNavigationScreenState();
}

class _MainNavigationScreenState extends State<MainNavigationScreen> {
  int _selectedIndex = 0;

  static const List<Widget> _screens = [
    LatestMatchesScreen(),
    HomeScreen(),
    LotteryScreen(),
    BingoScreen(),
    UnifiedPredictionScreen(),
  ];

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: _screens[_selectedIndex],
      bottomNavigationBar: BottomNavigationBar(
        currentIndex: _selectedIndex,
        onTap: (index) => setState(() => _selectedIndex = index),
        backgroundColor: const Color(0xFF1E1E1E),
        selectedItemColor: const Color(0xFF3DDC97),
        unselectedItemColor: Colors.grey.shade600,
        type: BottomNavigationBarType.fixed,
        items: const [
          BottomNavigationBarItem(
            icon: Icon(Icons.new_releases),
            label: '所有比賽',
          ),
          BottomNavigationBarItem(
            icon: Icon(Icons.sports_basketball),
            label: '體育',
          ),
          BottomNavigationBarItem(
            icon: Icon(Icons.confirmation_number_rounded),
            label: '樂透',
          ),
          BottomNavigationBarItem(
            icon: Icon(Icons.casino_outlined),
            label: '台灣賓果',
          ),
          BottomNavigationBarItem(
            icon: Icon(Icons.auto_awesome),
            label: '統合預測',
          ),
        ],
      ),
    );
  }
}
