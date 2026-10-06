import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';
import '../services/api_service.dart';
import '../services/updater_service.dart';

class StoreOption {
  final int id;
  final String name;
  final String address;

  const StoreOption({required this.id, required this.name, required this.address});
}

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  final ApiService _api = ApiService();
  final UpdaterService _updater = UpdaterService();

  final List<StoreOption> _availableStores = const [
    StoreOption(id: 1, name: 'Магазин Gusar #1 (Центральный)', address: 'г. Душанбе, ул. Рудаки'),
    StoreOption(id: 2, name: 'Магазин Gusar #2 (Сино)', address: 'г. Душанбе, р-н Сино'),
    StoreOption(id: 3, name: 'Магазин Gusar #3 (Фирдавси)', address: 'г. Душанбе, р-н Фирдавси'),
    StoreOption(id: 4, name: 'Магазин Gusar #4 (Шохмансур)', address: 'г. Душанбе, р-н Шохмансур'),
    StoreOption(id: 5, name: 'Основной склад (РЦ)', address: 'Центральный распределительный склад'),
  ];

  int _selectedStoreId = 1;
  String _selectedStoreName = 'Магазин Gusar #1 (Центральный)';

  final TextEditingController _usernameCtrl = TextEditingController();
  final TextEditingController _passwordCtrl = TextEditingController();
  final TextEditingController _geminiKeyCtrl = TextEditingController();
  final TextEditingController _urlCtrl = TextEditingController();

  bool _isLoggingIn = false;
  String? _loginMessage;
  bool _isAuthenticated = false;
  String? _currentUsername;

  @override
  void initState() {
    super.initState();
    _loadSettings();
  }

  void _loadSettings() async {
    final prefs = await SharedPreferences.getInstance();
    setState(() {
      _selectedStoreId = prefs.getInt('store_id') ?? 1;
      _selectedStoreName = prefs.getString('store_name') ?? 'Магазин Gusar #1 (Центральный)';
      _usernameCtrl.text = prefs.getString('saved_username') ?? prefs.getString('logged_username') ?? '';
      _passwordCtrl.text = prefs.getString('saved_password') ?? '';
      _currentUsername = prefs.getString('logged_username') ?? prefs.getString('saved_username');
      _isAuthenticated = prefs.getBool('is_authenticated') ?? false;
      _geminiKeyCtrl.text = prefs.getString('gemini_api_key') ?? '';
      _urlCtrl.text = prefs.getString('api_base_url') ?? 'https://gusar.tj';
    });
  }

  void _onStoreChanged(int? newId) {
    if (newId == null) return;
    final store = _availableStores.firstWhere((s) => s.id == newId, orElse: () => _availableStores.first);
    setState(() {
      _selectedStoreId = store.id;
      _selectedStoreName = store.name;
    });
    _api.updateStore(store.id, store.name);
  }

  Future<void> _handleLogin() async {
    final user = _usernameCtrl.text.trim();
    final pass = _passwordCtrl.text.trim();

    if (user.isEmpty || pass.isEmpty) {
      setState(() {
        _loginMessage = '⚠️ Введите логин и пароль сотрудника.';
      });
      return;
    }

    // Сохраняем логин и пароль навсегда
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('saved_username', user);
    await prefs.setString('saved_password', pass);
    await prefs.setString('logged_username', user);

    setState(() {
      _isLoggingIn = true;
      _loginMessage = null;
    });

    // Сохраняем выбранный магазин перед входом
    await _api.updateStore(_selectedStoreId, _selectedStoreName);

    final result = await _api.login(user, pass);

    setState(() {
      _isLoggingIn = false;
      _isAuthenticated = result['success'] == true;
      if (_isAuthenticated) {
        _currentUsername = user;
        _loginMessage = '✅ ${result['message']}';
      } else {
        _loginMessage = '❌ ${result['message']}';
      }
    });

    if (_isAuthenticated && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Вход выполнен! Магазин: $_selectedStoreName'),
          backgroundColor: const Color(0xFF10B981),
        ),
      );
    }
  }

  Future<void> _handleLogout() async {
    await _api.logout();
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove('saved_password');
    setState(() {
      _isAuthenticated = false;
      _currentUsername = null;
      _passwordCtrl.clear();
      _loginMessage = 'Вы вышли из учетной записи.';
    });
  }

  Future<void> _saveAllSettings() async {
    final prefs = await SharedPreferences.getInstance();
    final user = _usernameCtrl.text.trim();
    final pass = _passwordCtrl.text.trim();

    await _api.updateStore(_selectedStoreId, _selectedStoreName);
    await prefs.setString('gemini_api_key', _geminiKeyCtrl.text.trim());
    await prefs.setString('api_base_url', _urlCtrl.text.trim());
    _api.updateBaseUrl(_urlCtrl.text.trim());

    // Сохраняем логин и пароль в SharedPreferences, чтобы больше не сбрасывались
    if (user.isNotEmpty) {
      await prefs.setString('saved_username', user);
      await prefs.setString('logged_username', user);
    }
    if (pass.isNotEmpty) {
      await prefs.setString('saved_password', pass);
    }

    if (user.isNotEmpty && pass.isNotEmpty) {
      await _api.login(user, pass);
    }

    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('✅ Настройки, логин и пароль успешно сохранены!'),
          backgroundColor: Color(0xFF10B981),
        ),
      );
      Navigator.pop(context);
    }
  }

  void _openGeminiSite() async {
    final uri = Uri.parse('https://aistudio.google.com/app/apikey');
    if (await canLaunchUrl(uri)) {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    }
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
        elevation: 0,
        title: const Text('Настройки и авторизация', style: TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.bold)),
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // ==========================================
            // ШАГ 1: ВЫБОР МАГАЗИНА / СКЛАДА
            // ==========================================
            _sectionHeader(
              stepNumber: '1',
              title: 'ВЫБЕРИТЕ ВАШ МАГАЗИН / СКЛАД',
              subtitle: 'Куда будут оприходоваться принимаемые накладные',
            ),
            const SizedBox(height: 10),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 4),
              decoration: BoxDecoration(
                color: const Color(0xFF1E293B),
                borderRadius: BorderRadius.circular(14),
                border: Border.all(color: const Color(0xFF10B981).withOpacity(0.5), width: 1.5),
              ),
              child: DropdownButtonHideUnderline(
                child: DropdownButton<int>(
                  value: _selectedStoreId,
                  isExpanded: true,
                  dropdownColor: const Color(0xFF1E293B),
                  icon: const Icon(Icons.storefront_rounded, color: Color(0xFF10B981)),
                  items: _availableStores.map((store) {
                    return DropdownMenuItem<int>(
                      value: store.id,
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Text(
                            store.name,
                            style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 14),
                          ),
                          Text(
                            store.address,
                            style: const TextStyle(color: Colors.white54, fontSize: 11),
                          ),
                        ],
                      ),
                    );
                  }).toList(),
                  onChanged: _onStoreChanged,
                ),
              ),
            ),

            const SizedBox(height: 24),

            // ==========================================
            // ШАГ 2: ВХОД СОТРУДНИКА (АВТОРИЗАЦИЯ)
            // ==========================================
            _sectionHeader(
              stepNumber: '2',
              title: 'ВХОД СОТРУДНИКА В СИСТЕМУ',
              subtitle: 'Введите учетные данные для доступа к складу gusar.tj',
            ),
            const SizedBox(height: 12),

            if (_isAuthenticated) ...[
              // Карточка активной сессии
              Container(
                padding: const EdgeInsets.all(14),
                decoration: BoxDecoration(
                  color: const Color(0xFF064E3B).withOpacity(0.6),
                  borderRadius: BorderRadius.circular(14),
                  border: Border.all(color: const Color(0xFF10B981)),
                ),
                child: Column(
                  children: [
                    Row(
                      children: [
                        const CircleAvatar(
                          backgroundColor: Color(0xFF10B981),
                          radius: 20,
                          child: Icon(Icons.check_rounded, color: Colors.white, size: 24),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text('Сотрудник: ${_currentUsername ?? "Товаровед"}',
                                  style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 15)),
                              Text('Привязан к: $_selectedStoreName',
                                  style: const TextStyle(color: Colors.white70, fontSize: 12)),
                            ],
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 12),
                    OutlinedButton.icon(
                      style: OutlinedButton.styleFrom(
                        side: const BorderSide(color: Colors.white30),
                        minimumSize: const Size(double.infinity, 38),
                      ),
                      icon: const Icon(Icons.logout_rounded, color: Colors.white70, size: 18),
                      label: const Text('Сменить пользователя / Выйти', style: TextStyle(color: Colors.white70, fontSize: 12)),
                      onPressed: _handleLogout,
                    ),
                  ],
                ),
              ),
            ] else ...[
              // Форма логина и пароля
              Container(
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: const Color(0xFF1E293B),
                  borderRadius: BorderRadius.circular(14),
                  border: Border.all(color: Colors.white10),
                ),
                child: Column(
                  children: [
                    TextField(
                      controller: _usernameCtrl,
                      style: const TextStyle(color: Colors.white),
                      decoration: const InputDecoration(
                        labelText: 'Логин / Телефон сотрудника',
                        hintText: 'admin или 992...',
                        prefixIcon: Icon(Icons.person_outline_rounded, color: Colors.white54),
                        labelStyle: TextStyle(color: Colors.white54),
                        filled: true,
                        fillColor: Color(0xFF0F172A),
                        border: OutlineInputBorder(borderRadius: BorderRadius.all(Radius.circular(10)), borderSide: BorderSide.none),
                      ),
                    ),
                    const SizedBox(height: 12),
                    TextField(
                      controller: _passwordCtrl,
                      obscureText: true,
                      style: const TextStyle(color: Colors.white),
                      decoration: const InputDecoration(
                        labelText: 'Пароль',
                        prefixIcon: Icon(Icons.lock_outline_rounded, color: Colors.white54),
                        labelStyle: TextStyle(color: Colors.white54),
                        filled: true,
                        fillColor: Color(0xFF0F172A),
                        border: OutlineInputBorder(borderRadius: BorderRadius.all(Radius.circular(10)), borderSide: BorderSide.none),
                      ),
                    ),
                    const SizedBox(height: 16),
                    ElevatedButton.icon(
                      style: ElevatedButton.styleFrom(
                        backgroundColor: const Color(0xFF10B981),
                        foregroundColor: Colors.white,
                        minimumSize: const Size(double.infinity, 46),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                      ),
                      icon: _isLoggingIn
                          ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2))
                          : const Icon(Icons.login_rounded, size: 20),
                      label: Text(_isLoggingIn ? 'Подключение к gusar.tj...' : 'Войти в систему магазина',
                          style: const TextStyle(fontSize: 14, fontWeight: FontWeight.bold)),
                      onPressed: _isLoggingIn ? null : _handleLogin,
                    ),
                    if (_loginMessage != null) ...[
                      const SizedBox(height: 10),
                      Text(
                        _loginMessage!,
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          color: _loginMessage!.startsWith('✅') ? const Color(0xFF10B981) : Colors.redAccent,
                          fontSize: 12,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ],

            const SizedBox(height: 24),

            // ==========================================
            // ШАГ 3: GEMINI VISION AI МОДУЛЬ
            // ==========================================
            _sectionHeader(
              stepNumber: '3',
              title: 'AI МОДУЛЬ РАСПОЗНАВАНИЯ ТАБЛИЦ',
              subtitle: 'Google Gemini 1.5 Flash для быстрого чтения накладных',
            ),
            const SizedBox(height: 10),
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: const Color(0xFF1E293B),
                borderRadius: BorderRadius.circular(14),
                border: Border.all(color: Colors.white10),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  TextField(
                    controller: _geminiKeyCtrl,
                    style: const TextStyle(color: Colors.white),
                    decoration: InputDecoration(
                      labelText: 'Google Gemini API Key',
                      hintText: 'AIzaSy...',
                      labelStyle: const TextStyle(color: Colors.white54),
                      filled: true,
                      fillColor: const Color(0xFF0F172A),
                      border: const OutlineInputBorder(borderRadius: BorderRadius.all(Radius.circular(10)), borderSide: BorderSide.none),
                      suffixIcon: IconButton(
                        icon: const Icon(Icons.open_in_new_rounded, color: Color(0xFF0284C7)),
                        tooltip: 'Получить ключ на сайте Google',
                        onPressed: _openGeminiSite,
                      ),
                    ),
                  ),
                  const SizedBox(height: 8),
                  GestureDetector(
                    onTap: _openGeminiSite,
                    child: const Text(
                      '👉 Нажмите здесь, чтобы бесплатно получить API Key на Google AI Studio (1 минута)',
                      style: TextStyle(color: Color(0xFF38BDF8), fontSize: 12, decoration: TextDecoration.underline),
                    ),
                  ),
                ],
              ),
            ),

            const SizedBox(height: 24),

            // ==========================================
            // ШАГ 4: СЕРВЕР GUSAR И ОБНОВЛЕНИЯ
            // ==========================================
            _sectionHeader(
              stepNumber: '4',
              title: 'СЕРВЕР И ВЕРСИЯ ПРИЛОЖЕНИЯ',
              subtitle: 'Связь с базой и проверка обновлений',
            ),
            const SizedBox(height: 10),
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: const Color(0xFF1E293B),
                borderRadius: BorderRadius.circular(14),
                border: Border.all(color: Colors.white10),
              ),
              child: Column(
                children: [
                  TextField(
                    controller: _urlCtrl,
                    style: const TextStyle(color: Colors.white),
                    decoration: const InputDecoration(
                      labelText: 'URL сервера gusar.tj',
                      hintText: 'https://gusar.tj',
                      labelStyle: TextStyle(color: Colors.white54),
                      filled: true,
                      fillColor: Color(0xFF0F172A),
                      border: OutlineInputBorder(borderRadius: BorderRadius.all(Radius.circular(10)), borderSide: BorderSide.none),
                    ),
                  ),
                  const SizedBox(height: 14),
                  OutlinedButton.icon(
                    style: OutlinedButton.styleFrom(
                      side: const BorderSide(color: Colors.white24),
                      minimumSize: const Size(double.infinity, 44),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                    ),
                    icon: const Icon(Icons.system_update_rounded, color: Colors.white70),
                    label: const Text('Проверить обновление APK (v1.0.1)', style: TextStyle(color: Colors.white70)),
                    onPressed: _checkApkUpdate,
                  ),
                ],
              ),
            ),

            const SizedBox(height: 32),

            // Кнопка сохранения всех настроек
            ElevatedButton(
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFF10B981),
                foregroundColor: Colors.white,
                minimumSize: const Size(double.infinity, 50),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                elevation: 3,
              ),
              onPressed: _saveAllSettings,
              child: const Text('Сохранить все настройки', style: TextStyle(fontSize: 15, fontWeight: FontWeight.bold)),
            ),
            const SizedBox(height: 20),
          ],
        ),
      ),
    );
  }

  Widget _sectionHeader({required String stepNumber, required String title, required String subtitle}) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          width: 24,
          height: 24,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: const Color(0xFF10B981),
            borderRadius: BorderRadius.circular(6),
          ),
          child: Text(stepNumber, style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 13)),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(title, style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 13, letterSpacing: 0.5)),
              const SizedBox(height: 2),
              Text(subtitle, style: const TextStyle(color: Colors.white54, fontSize: 11)),
            ],
          ),
        ),
      ],
    );
  }
}
