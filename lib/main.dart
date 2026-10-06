import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'services/api_service.dart';
import 'services/matching_service.dart';
import 'screens/home_screen.dart';
import 'screens/login_screen.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Безопасная инициализация сервисов
  try {
    await ApiService().init();
  } catch (e) {
    debugPrint('ApiService init warning: $e');
  }

  try {
    await MatchingService().init();
  } catch (e) {
    debugPrint('MatchingService init warning: $e');
  }

  final prefs = await SharedPreferences.getInstance();
  final isAuth = prefs.getBool('is_authenticated') ?? false;

  runApp(GusarScannerApp(isAuthenticated: isAuth));
}

class GusarScannerApp extends StatelessWidget {
  final bool isAuthenticated;
  const GusarScannerApp({super.key, required this.isAuthenticated});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Gusar Scanner',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        brightness: Brightness.dark,
        scaffoldBackgroundColor: const Color(0xFF0F172A), // Slate 900
        primaryColor: const Color(0xFF10B981), // Emerald 500
        colorScheme: const ColorScheme.dark(
          primary: Color(0xFF10B981),
          secondary: Color(0xFF0284C7),
          surface: Color(0xFF1E293B),
          error: Colors.redAccent,
        ),
        textTheme: GoogleFonts.interTextTheme(ThemeData.dark().textTheme),
        appBarTheme: const AppBarTheme(
          backgroundColor: Color(0xFF1E293B),
          elevation: 0,
          centerTitle: false,
        ),
        cardTheme: CardTheme(
          color: const Color(0xFF1E293B),
          elevation: 0,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        ),
      ),
      home: isAuthenticated ? const HomeScreen() : const LoginScreen(),
    );
  }
}
