import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../services/api_service.dart';
import '../services/updater_service.dart';

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  final ApiService _api = ApiService();
  final UpdaterService _updater = UpdaterService();

  final TextEditingController _urlCtrl = TextEditingController();
  final TextEditingController _geminiKeyCtrl = TextEditingController();
  final TextEditingController _usernameCtrl = TextEditingController();
  final TextEditingController _passwordCtrl = TextEditingController();
  int _storeId = 1;

  bool _isTestingConnection = false;
  String? _connectionStatus;

  @override
  void initState() {
    super.initState();
    _loadSettings();
  }

  void _loadSettings() async {
    final prefs = await SharedPreferences.getInstance();
    setState(() {
      _urlCtrl.text = prefs.getString('api_base_url') ?? 'https://gusar.tj';
      _geminiKeyCtrl.text = prefs.getString('gemini_api_key') ?? '';
      _storeId = prefs.getInt('store_id') ?? 1;
    });
  }

  void _saveSettings() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('api_base_url', _urlCtrl.text.trim());
    await prefs.setString('gemini_api_key', _geminiKeyCtrl.text.trim());
    await prefs.setInt('store_id', _storeId);

    _api.updateBaseUrl(_urlCtrl.text.trim());
    _api.updateStoreId(_storeId);

    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Настройки успешно сохранены!'), backgroundColor: Color(0xFF10B981)),
      );
      Navigator.pop(context);
    }
  }

  void _testLogin() async {
    setState(() {
      _isTestingConnection = true;
      _connectionStatus = null;
    });

    final success = await _api.login(_usernameCtrl.text.trim(), _passwordCtrl.text.trim());

    setState(() {
      _isTestingConnection = false;
      _connectionStatus = success ? '✅ Связь с gusar.tj установлена!' : '❌ Ошибка авторизации. Проверьте логин и пароль.';
    });
  }

  void _checkApkUpdate() async {
    final update = await _updater.checkForUpdate();
    if (update != null && mounted) {
      showDialog(
        context: context,
        builder: (ctx) => AlertDialog(
          backgroundColor: const Color(0xFF1E293B),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
          title: Text('🚀 Доступно обновление v${update.version}', style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('Вышла новая версия приложения Gusar Scanner. Вы можете установить её прямо сейчас или отложить на потом.',
                  style: TextStyle(color: Colors.white70, fontSize: 13)),
              const SizedBox(height: 12),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(color: const Color(0xFF0F172A), borderRadius: BorderRadius.circular(8)),
                child: Text(
                  update.releaseNotes.isEmpty ? 'Плановые оптимизации и исправления' : update.releaseNotes,
                  style: const TextStyle(color: Colors.white60, fontSize: 12),
                ),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('Позже (я решу сам)', style: TextStyle(color: Colors.white54)),
            ),
            ElevatedButton(
              style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFF10B981)),
              onPressed: () {
                Navigator.pop(ctx);
                _updater.launchDownload(update.downloadUrl);
              },
              child: const Text('Обновить сейчас', style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
            ),
          ],
        ),
      );
    } else if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('У вас установлена самая актуальная версия приложения!'),
          backgroundColor: Color(0xFF10B981),
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF0F172A),
      appBar: AppBar(
        backgroundColor: const Color(0xFF1E293B),
        title: const Text('Настройки системы', style: TextStyle(color: Colors.white, fontSize: 16)),
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // 1. Блок API gusar.tj
            const Text('СЕРВЕР УЧЕТА GUSAR (gusar.tj)',
                style: TextStyle(color: Colors.white54, fontSize: 11, fontWeight: FontWeight.bold, letterSpacing: 1.1)),
            const SizedBox(height: 10),
            TextField(
              controller: _urlCtrl,
              style: const TextStyle(color: Colors.white),
              decoration: const InputDecoration(
                labelText: 'URL сервера',
                hintText: 'https://gusar.tj',
                labelStyle: TextStyle(color: Colors.white54),
                filled: true,
                fillColor: Color(0xFF1E293B),
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _usernameCtrl,
              style: const TextStyle(color: Colors.white),
              decoration: const InputDecoration(
                labelText: 'Логин сотрудника / телефон',
                labelStyle: TextStyle(color: Colors.white54),
                filled: true,
                fillColor: Color(0xFF1E293B),
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _passwordCtrl,
              obscureText: true,
              style: const TextStyle(color: Colors.white),
              decoration: const InputDecoration(
                labelText: 'Пароль',
                labelStyle: TextStyle(color: Colors.white54),
                filled: true,
                fillColor: Color(0xFF1E293B),
              ),
            ),
            const SizedBox(height: 10),
            Row(
              children: [
                ElevatedButton(
                  style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFF0284C7)),
                  onPressed: _isTestingConnection ? null : _testLogin,
                  child: _isTestingConnection
                      ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2))
                      : const Text('Проверить связь', style: TextStyle(color: Colors.white)),
                ),
                const SizedBox(width: 12),
                if (_connectionStatus != null)
                  Expanded(
                    child: Text(
                      _connectionStatus!,
                      style: TextStyle(
                        color: _connectionStatus!.startsWith('✅') ? const Color(0xFF10B981) : Colors.redAccent,
                        fontSize: 12,
                      ),
                    ),
                  ),
              ],
            ),

            const SizedBox(height: 24),

            // 2. Блок Gemini Vision AI
            const Text('AI МОДУЛЬ РАСПОЗНАВАНИЯ (GEMINI VISION)',
                style: TextStyle(color: Colors.white54, fontSize: 11, fontWeight: FontWeight.bold, letterSpacing: 1.1)),
            const SizedBox(height: 10),
            TextField(
              controller: _geminiKeyCtrl,
              style: const TextStyle(color: Colors.white),
              decoration: const InputDecoration(
                labelText: 'Google Gemini API Key',
                hintText: 'AIzaSy...',
                labelStyle: TextStyle(color: Colors.white54),
                filled: true,
                fillColor: Color(0xFF1E293B),
              ),
            ),
            const SizedBox(height: 6),
            const Text('Используется для точного разбора таблиц, чеков и накладных на таджикском и русском языках.',
                style: TextStyle(color: Colors.white38, fontSize: 11)),

            const SizedBox(height: 24),

            // 3. Выбор магазина
            const Text('ТЕКУЩИЙ МАГАЗИН / СКЛАД',
                style: TextStyle(color: Colors.white54, fontSize: 11, fontWeight: FontWeight.bold, letterSpacing: 1.1)),
            const SizedBox(height: 10),
            DropdownButtonFormField<int>(
              value: _storeId,
              dropdownColor: const Color(0xFF1E293B),
              style: const TextStyle(color: Colors.white),
              decoration: const InputDecoration(filled: true, fillColor: Color(0xFF1E293B)),
              items: const [
                DropdownMenuItem(value: 1, child: Text('Магазин Gusar #1 (Центральный)')),
                DropdownMenuItem(value: 2, child: Text('Магазин Gusar #2')),
                DropdownMenuItem(value: 3, child: Text('Основной склад')),
              ],
              onChanged: (val) {
                if (val != null) setState(() => _storeId = val);
              },
            ),

            const SizedBox(height: 32),

            // 4. Кнопка сохранения
            ElevatedButton(
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFF10B981),
                minimumSize: const Size(double.infinity, 48),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
              ),
              onPressed: _saveSettings,
              child: const Text('Сохранить настройки', style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
            ),

            const SizedBox(height: 20),

            // 5. Проверка обновлений
            OutlinedButton.icon(
              style: OutlinedButton.styleFrom(
                side: const BorderSide(color: Colors.white24),
                minimumSize: const Size(double.infinity, 44),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
              ),
              icon: const Icon(Icons.system_update_rounded, color: Colors.white70),
              label: const Text('Проверить обновление APK на GitHub', style: TextStyle(color: Colors.white70)),
              onPressed: _checkApkUpdate,
            ),
          ],
        ),
      ),
    );
  }
}
