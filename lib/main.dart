import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'services/api_service.dart';
import 'services/matching_service.dart';
import 'screens/home_screen.dart';
import 'screens/login_screen.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Глобальный перехватчик ошибок для абсолютной стабильности:
  // Приложение НЕ должно падать ни при каких обстоятельствах!
  FlutterError.onError = (FlutterErrorDetails details) {
    debugPrint('FLUTTER SHIELD CAUGHT ERROR: ${details.exceptionAsString()}');
  };

  WidgetsBinding.instance.platformDispatcher.onError = (Object error, StackTrace stack) {
    debugPrint('ASYNC SHIELD CAUGHT ERROR: $error\n$stack');
    return true; // Возвращаем true, чтобы предотвратить краш процесса приложения
  };

  // Защита от «красного экрана смерти»: при любой ошибке UI показывается безопасная карточка
  ErrorWidget.builder = (FlutterErrorDetails details) {
    return Material(
      color: const Color(0xFF0F172A),
      child: Center(
        child: Padding(
          padding: const EdgeInsets.all(20.0),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.shield_outlined, color: Color(0xFF10B981), size: 40),
              const SizedBox(height: 10),
              const Text(
                'Защита стабильности GScan',
                style: TextStyle(color: Colors.white, fontSize: 15, fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 6),
              const Text(
                'Временный сбой элемента интерфейса. Все данные сохранены, приложение продолжает работу.',
                textAlign: TextAlign.center,
                style: TextStyle(color: Colors.white60, fontSize: 12),
              ),
            ],
          ),
        ),
      ),
    );
  };

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
      title: 'GScan',
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
