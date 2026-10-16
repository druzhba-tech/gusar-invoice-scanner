import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';
import '../services/api_service.dart';
import '../utils/top_notification.dart';
import '../services/ocr_service.dart';
import '../services/updater_service.dart';
import 'login_screen.dart';

class StoreOption {
  final int id;
  final String name;
  final String address;

  const StoreOption({required this.id, required this.name, required this.address});

  Map<String, dynamic> toJson() => {'id': id, 'name': name, 'address': address};
  factory StoreOption.fromJson(Map<String, dynamic> json) => StoreOption(
    id: json['id'] is int ? json['id'] as int : int.tryParse(json['id']?.toString() ?? '1') ?? 1,
    name: json['name']?.toString() ?? 'Магазин gusar.tj',
    address: json['address']?.toString() ?? json['description']?.toString() ?? 'База gusar.tj',
  );
}

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  final ApiService _api = ApiService();
  final UpdaterService _updater = UpdaterService();

  List<StoreOption> _availableStores = [];
  int _selectedStoreId = 0;
  String _selectedStoreName = '';
  bool _isSyncingStores = false;

  final TextEditingController _usernameCtrl = TextEditingController();
  final TextEditingController _passwordCtrl = TextEditingController();
  String _aiProvider = 'gemini';
  final TextEditingController _yandexKeyCtrl = TextEditingController();
  final TextEditingController _yandexFolderIdCtrl = TextEditingController();
  final TextEditingController _geminiKeyCtrl = TextEditingController();
  final TextEditingController _urlCtrl = TextEditingController();

  bool _isLoggingIn = false;
  String? _loginMessage;
  bool _isAuthenticated = false;
  String? _currentUsername;

  static String get defaultGeminiKey => '';
  bool _showGeminiKeyField = false;

  @override
  void initState() {
    super.initState();
    _selectedStoreId = _api.currentStoreId;
    _selectedStoreName = _api.currentStoreName;
    _loadSettings();
  }

  void _loadSettings() async {
    final prefs = await SharedPreferences.getInstance();

    int savedId = prefs.getInt('store_id') ?? _api.currentStoreId;
    String savedName = prefs.getString('store_name') ?? _api.currentStoreName;

    if (savedId <= 0 || savedName.trim().isEmpty) {
      savedId = _api.currentStoreId > 0 ? _api.currentStoreId : 3;
      savedName = _api.currentStoreName.trim().isNotEmpty ? _api.currentStoreName : 'Мағозаи намунавӣ (Тестӣ #3)';
    }

    if (_api.accessibleStores.isNotEmpty && _api.accessibleStores.any((s) => (s['id'] ?? 0) > 0)) {
      _availableStores = _api.accessibleStores
          .where((s) => (s['id'] is int ? s['id'] as int : int.tryParse(s['id']?.toString() ?? '0') ?? 0) > 0)
          .map((s) => StoreOption(
                id: s['id'] is int ? s['id'] as int : int.tryParse(s['id']?.toString() ?? '3') ?? 3,
                name: (s['name'] != null && s['name'].toString().trim().isNotEmpty) ? s['name'].toString().trim() : 'Магазин gusar.tj',
                address: s['address']?.toString() ?? 'Подразделение сотрудника',
              ))
          .toList();
    } else {
      _availableStores = [
        StoreOption(id: savedId, name: savedName, address: 'Подразделение сотрудника'),
      ];
    }

    // Если сохраненного магазина пользователя нет в списке, добавляем его в начало, но ни в коем случае не сбрасываем!
    if (!_availableStores.any((s) => s.id == savedId)) {
      _availableStores.insert(0, StoreOption(id: savedId, name: savedName, address: 'Подразделение сотрудника'));
    }

    setState(() {
      _selectedStoreId = savedId;
      _selectedStoreName = savedName;
      _usernameCtrl.text = prefs.getString('saved_username') ?? prefs.getString('logged_username') ?? '';
      _passwordCtrl.text = prefs.getString('saved_password') ?? '';
      _currentUsername = prefs.getString('logged_username') ?? prefs.getString('saved_username');
      _isAuthenticated = prefs.getBool('is_authenticated') ?? false;
      _aiProvider = prefs.getString('ai_provider') ?? 'yandex';
      final savedYandexKey = prefs.getString('yandex_api_key')?.trim() ?? '';
      _yandexKeyCtrl.text = savedYandexKey.isNotEmpty ? savedYandexKey : OcrService.defaultYandexKey;
      final savedYandexFolder = prefs.getString('yandex_folder_id')?.trim() ?? '';
      _yandexFolderIdCtrl.text = savedYandexFolder.isNotEmpty ? savedYandexFolder : OcrService.defaultYandexFolderId;
      final savedGeminiKey = prefs.getString('gemini_api_key')?.trim() ?? '';
      _geminiKeyCtrl.text = (savedGeminiKey.startsWith('AIza') || savedGeminiKey.startsWith('AQ.') || savedGeminiKey.length > 20) ? savedGeminiKey : '';
      _urlCtrl.text = prefs.getString('api_base_url') ?? 'https://gusar.tj';
    });

    _fetchStoresFromGusar(silent: true);
  }

  Future<void> _fetchStoresFromGusar({bool silent = false}) async {
    setState(() => _isSyncingStores = true);
    final stores = await _api.fetchStores();
    setState(() => _isSyncingStores = false);

    if (stores.isNotEmpty) {
      final newOptions = stores.map((s) => StoreOption(
        id: s['id'] as int,
        name: s['name'] as String,
        address: s['address'] as String,
      )).toList();

      // Гарантируем сохранение активного магазина пользователя
      if (!newOptions.any((s) => s.id == _selectedStoreId) && _selectedStoreId > 0) {
        newOptions.insert(0, StoreOption(id: _selectedStoreId, name: _selectedStoreName, address: 'Подразделение сотрудника'));
      }

      setState(() {
        _availableStores = newOptions;
        if (_selectedStoreId > 0 && _availableStores.any((s) => s.id == _selectedStoreId)) {
          final found = _availableStores.firstWhere((s) => s.id == _selectedStoreId);
          _selectedStoreName = found.name;
        }
      });

      // НЕ вызываем _api.updateStore автоматически! Магазин меняется только по явному выбору пользователя.
      if (!silent && mounted) {
        TopNotification.showSuccess(context, 'Доступные магазины gusar.tj обновлены (${_availableStores.length} точек)');
      }
    }
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

    setState(() {
      _isLoggingIn = true;
      _loginMessage = null;
    });

    final result = await _api.login(user, pass, remember: true);

    setState(() {
      _isLoggingIn = false;
      _isAuthenticated = result['success'] == true;
      if (_isAuthenticated) {
        _currentUsername = user;
        _loginMessage = '✅ ${result["message"]}';
        _selectedStoreName = _api.currentStoreName;
        _selectedStoreId = _api.currentStoreId;
        _availableStores = _api.accessibleStores.map((s) => StoreOption(
          id: s['id'] is int ? s['id'] as int : int.tryParse(s['id']?.toString() ?? '1') ?? 1,
          name: s['name']?.toString() ?? 'Магазин gusar.tj',
          address: s['address']?.toString() ?? 'Подразделение сотрудника',
        )).toList();
      } else {
        _loginMessage = '❌ ${result["message"]}';
      }
    });

    if (_isAuthenticated && mounted) {
      TopNotification.showSuccess(context, 'Вход выполнен! Доступ: $_selectedStoreName');
    }
  }

  Future<void> _handleLogout() async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF1E293B),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: const Row(
          children: [
            Icon(Icons.logout_rounded, color: Colors.orangeAccent),
            SizedBox(width: 8),
            Text('Выход из системы', style: TextStyle(color: Colors.white, fontSize: 16)),
          ],
        ),
        content: const Text(
          'Вы действительно хотите выйти из учетной записи магазина gusar.tj?',
          style: TextStyle(color: Colors.white70, fontSize: 14),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Отмена', style: TextStyle(color: Colors.white60)),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: Colors.redAccent),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Выйти', style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
          ),
        ],
      ),
    );

    if (confirm != true) return;

    await _api.logout();
    if (mounted) {
      Navigator.pushAndRemoveUntil(
        context,
        MaterialPageRoute(builder: (_) => const LoginScreen()),
        (route) => false,
      );
    }
  }

  Future<void> _saveAllSettings() async {
    final prefs = await SharedPreferences.getInstance();
    final user = _usernameCtrl.text.trim();
    final pass = _passwordCtrl.text.trim();

    final storeIdToSave = _selectedStoreId > 0 ? _selectedStoreId : 2;
    final storeNameToSave = _selectedStoreName.trim().isNotEmpty ? _selectedStoreName : 'Мағозаи Арзон';

    await _api.updateStore(storeIdToSave, storeNameToSave);
    await prefs.setString('ai_provider', _aiProvider);
    await prefs.setString('yandex_api_key', _yandexKeyCtrl.text.trim());
    await prefs.setString('yandex_folder_id', _yandexFolderIdCtrl.text.trim());
    final geminiToSave = _geminiKeyCtrl.text.trim();
    await prefs.setString('gemini_api_key', (geminiToSave.startsWith('AIza') || geminiToSave.startsWith('AQ.') || geminiToSave.length > 20) ? geminiToSave : '');
    await prefs.setString('api_base_url', _urlCtrl.text.trim());
    _api.updateBaseUrl(_urlCtrl.text.trim());

    if (user.isNotEmpty) {
      await prefs.setString('saved_username', user);
      await prefs.setString('logged_username', user);
    }
    if (pass.isNotEmpty) {
      await prefs.setString('saved_password', pass);
    }

    if (user.isNotEmpty && pass.isNotEmpty && !_isAuthenticated) {
      await _api.login(user, pass, remember: true);
    }

    if (mounted) {
      TopNotification.showSuccess(context, 'Настройки успешно сохранены!');
      Navigator.pop(context);
    }
  }

  void _openGeminiSite() async {
    final uri = Uri.parse('https://aistudio.google.com/app/apikey');
    if (await canLaunchUrl(uri)) {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    }
  }

  void _openYandexSite() async {
    final uri = Uri.parse('https://cloud.yandex.ru/services/vision');
    if (await canLaunchUrl(uri)) {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    }
  }

  void _checkApkUpdate() async {
    final update = await _updater.checkForUpdate();
    if (update != null && mounted) {
      _updater.showDownloadAndInstallDialog(context, update);
    } else if (mounted) {
      final currentVer = await _updater.getCurrentVersion();
      TopNotification.showSuccess(context, 'У вас установлена самая актуальная версия: v$currentVer!');
    }
  }

  @override
  Widget build(BuildContext context) {
    final displayStoreName = _selectedStoreName.trim().isNotEmpty
        ? _selectedStoreName
        : (_api.currentStoreName.trim().isNotEmpty ? _api.currentStoreName : 'Мағозаи Арзон');
    final displayStoreId = _selectedStoreId > 0
        ? _selectedStoreId
        : (_api.currentStoreId > 0 ? _api.currentStoreId : 2);

    return Scaffold(
      backgroundColor: const Color(0xFF0F172A),
      appBar: AppBar(
        backgroundColor: const Color(0xFF1E293B),
        elevation: 0,
        title: const Text('Настройки и доступ', style: TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.bold)),
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _sectionHeader(
              stepNumber: '1',
              title: 'ВАШ МАГАЗИН GUSAR.TJ',
              subtitle: 'Точка приёмки накладных. Выберите нужный магазин для работы',
            ),
            const SizedBox(height: 10),

            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: const Color(0xFF1E293B),
                borderRadius: BorderRadius.circular(14),
                border: Border.all(color: const Color(0xFF10B981).withOpacity(0.5)),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Container(
                        padding: const EdgeInsets.all(10),
                        decoration: BoxDecoration(
                          color: const Color(0xFF10B981).withOpacity(0.15),
                          borderRadius: BorderRadius.circular(10),
                        ),
                        child: const Icon(Icons.storefront_rounded, color: Color(0xFF10B981), size: 28),
                      ),
                      const SizedBox(width: 14),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              children: [
                                Expanded(
                                  child: Text(
                                    displayStoreName,
                                    style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 15),
                                  ),
                                ),
                                Container(
                                  padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                                  decoration: BoxDecoration(
                                    color: const Color(0xFF10B981).withOpacity(0.2),
                                    borderRadius: BorderRadius.circular(6),
                                  ),
                                  child: Text(
                                    'ID: $displayStoreId',
                                    style: const TextStyle(color: Color(0xFF10B981), fontSize: 11, fontWeight: FontWeight.bold),
                                  ),
                                ),
                              ],
                            ),
                            const SizedBox(height: 4),
                            const Text(
                              'Активная точка приёмки и списания товаров',
                              style: TextStyle(color: Colors.white54, fontSize: 11),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                  if (_availableStores.isNotEmpty) ...[
                    const SizedBox(height: 14),
                    const Divider(color: Colors.white10),
                    const SizedBox(height: 10),
                    const Text(
                      'Переключить магазин / склад:',
                      style: TextStyle(color: Colors.white70, fontSize: 12, fontWeight: FontWeight.w600),
                    ),
                    const SizedBox(height: 6),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                      decoration: BoxDecoration(
                        color: const Color(0xFF0F172A),
                        borderRadius: BorderRadius.circular(10),
                        border: Border.all(color: Colors.white24),
                      ),
                      child: DropdownButtonHideUnderline(
                        child: DropdownButton<int>(
                          value: _availableStores.any((s) => s.id == _selectedStoreId)
                              ? _selectedStoreId
                              : _availableStores.first.id,
                          isExpanded: true,
                          dropdownColor: const Color(0xFF1E293B),
                          icon: const Icon(Icons.keyboard_arrow_down_rounded, color: Color(0xFF10B981)),
                          style: const TextStyle(color: Colors.white, fontSize: 13),
                          items: _availableStores.map((s) => DropdownMenuItem<int>(
                            value: s.id,
                            child: Row(
                              children: [
                                Icon(Icons.storefront_rounded, size: 16, color: s.id == 3 ? const Color(0xFF10B981) : Colors.white70),
                                const SizedBox(width: 8),
                                Expanded(
                                  child: Text(
                                    s.name,
                                    overflow: TextOverflow.ellipsis,
                                    style: TextStyle(
                                      color: Colors.white,
                                      fontWeight: s.id == _selectedStoreId ? FontWeight.bold : FontWeight.normal,
                                    ),
                                  ),
                                ),
                                Container(
                                  margin: const EdgeInsets.only(left: 6),
                                  padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                                  decoration: BoxDecoration(
                                    color: const Color(0xFF10B981).withOpacity(0.15),
                                    borderRadius: BorderRadius.circular(4),
                                  ),
                                  child: Text(
                                    '#${s.id}',
                                    style: const TextStyle(color: Color(0xFF10B981), fontSize: 10, fontWeight: FontWeight.bold),
                                  ),
                                ),
                              ],
                            ),
                          )).toList(),
                          onChanged: (newId) async {
                            if (newId != null && newId != _selectedStoreId) {
                              final st = _availableStores.firstWhere((s) => s.id == newId);
                              setState(() {
                                _selectedStoreId = newId;
                                _selectedStoreName = st.name;
                              });
                              await _api.updateStore(newId, st.name);
                              if (mounted) {
                                TopNotification.showSuccess(context, 'Активный магазин переключен на: ${st.name} (ID: $newId)');
                              }
                            }
                          },
                        ),
                      ),
                    ),
                  ],
                ],
              ),
            ),

            const SizedBox(height: 24),

            _sectionHeader(
              stepNumber: '2',
              title: 'УЧЕТНАЯ ЗАПИСЬ СОТРУДНИКА',
              subtitle: 'Авторизация и привязка к базе gusar.tj',
            ),
            const SizedBox(height: 12),

            if (_isAuthenticated) ...[
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
                              Text('Доступ: $displayStoreName',
                                  style: const TextStyle(color: Colors.white70, fontSize: 12)),
                              if (_availableStores.length > 1) ...[
                                const SizedBox(height: 6),
                                Container(
                                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                                  decoration: BoxDecoration(
                                    color: const Color(0xFF0F172A),
                                    borderRadius: BorderRadius.circular(8),
                                    border: Border.all(color: Colors.white24),
                                  ),
                                  child: DropdownButtonHideUnderline(
                                    child: DropdownButton<int>(
                                      value: _availableStores.any((s) => s.id == _selectedStoreId)
                                          ? _selectedStoreId
                                          : _availableStores.first.id,
                                      isDense: true,
                                      dropdownColor: const Color(0xFF1E293B),
                                      icon: const Icon(Icons.arrow_drop_down, color: Color(0xFF10B981)),
                                      style: const TextStyle(color: Colors.white, fontSize: 12),
                                      items: _availableStores.map((s) => DropdownMenuItem<int>(
                                        value: s.id,
                                        child: Text('${s.name} (ID: ${s.id})', style: const TextStyle(color: Colors.white, fontSize: 12)),
                                      )).toList(),
                                      onChanged: (newId) async {
                                        if (newId != null && newId != _selectedStoreId) {
                                          final st = _availableStores.firstWhere((s) => s.id == newId);
                                          setState(() {
                                            _selectedStoreId = newId;
                                            _selectedStoreName = st.name;
                                          });
                                          await _api.updateStore(newId, st.name);
                                          if (mounted) {
                                            TopNotification.showSuccess(context, 'Магазин изменен на: ${st.name}');
                                          }
                                        }
                                      },
                                    ),
                                  ),
                                ),
                              ],
                            ],
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 14),
                    ElevatedButton.icon(
                      style: ElevatedButton.styleFrom(
                        backgroundColor: Colors.redAccent.withOpacity(0.85),
                        foregroundColor: Colors.white,
                        minimumSize: const Size(double.infinity, 40),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                      ),
                      icon: const Icon(Icons.logout_rounded, size: 18),
                      label: const Text('Сменить пользователя / Выйти из аккаунта', style: TextStyle(fontSize: 13, fontWeight: FontWeight.bold)),
                      onPressed: _handleLogout,
                    ),
                  ],
                ),
              ),
            ] else ...[
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
            // ШАГ 3: AI МОДУЛЬ РАСПОЗНАВАНИЯ ТАБЛИЦ (КИРИЛЛИЦА)
            // ==========================================
            _sectionHeader(
              stepNumber: '3',
              title: 'AI МОДУЛЬ РАСПОЗНАВАНИЯ ТАБЛИЦ (КИРИЛЛИЦА)',
              subtitle: 'Яндекс Vision (для РФ и РТ) или Google Gemini',
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
                  const Text(
                    'Сервис распознавания текста и таблиц:',
                    style: TextStyle(color: Colors.white70, fontSize: 13, fontWeight: FontWeight.w600),
                  ),
                  const SizedBox(height: 10),
                  Row(
                    children: [
                      Expanded(
                        child: ChoiceChip(
                          label: const Center(
                            child: Text('🇷🇺 Яндекс AI', style: TextStyle(fontSize: 13, fontWeight: FontWeight.bold)),
                          ),
                          selected: _aiProvider == 'yandex',
                          selectedColor: const Color(0xFF10B981),
                          backgroundColor: const Color(0xFF0F172A),
                          labelStyle: TextStyle(color: _aiProvider == 'yandex' ? Colors.white : Colors.white60),
                          onSelected: (val) => setState(() => _aiProvider = 'yandex'),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: ChoiceChip(
                          label: const Center(
                            child: Text('🌐 Google Gemini', style: TextStyle(fontSize: 13, fontWeight: FontWeight.bold)),
                          ),
                          selected: _aiProvider == 'gemini',
                          selectedColor: const Color(0xFF10B981),
                          backgroundColor: const Color(0xFF0F172A),
                          labelStyle: TextStyle(color: _aiProvider == 'gemini' ? Colors.white : Colors.white60),
                          onSelected: (val) => setState(() => _aiProvider = 'gemini'),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 14),

                  if (_aiProvider == 'yandex') ...[
                    Container(
                      padding: const EdgeInsets.all(10),
                      decoration: BoxDecoration(
                        color: const Color(0xFF0F172A),
                        borderRadius: BorderRadius.circular(10),
                        border: Border.all(color: const Color(0xFF10B981).withOpacity(0.3)),
                      ),
                      child: const Row(
                        children: [
                          Icon(Icons.verified_rounded, color: Color(0xFF10B981), size: 18),
                          SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              'Яндекс Vision специально обучен на кириллице (русский и таджикский языки) и идеально распознаёт печатные таблицы накладных.',
                              style: TextStyle(color: Colors.white70, fontSize: 11),
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 12),
                    TextField(
                      controller: _yandexKeyCtrl,
                      style: const TextStyle(color: Colors.white),
                      decoration: InputDecoration(
                        labelText: 'Yandex Cloud API-Key',
                        hintText: 'AQVN...',
                        labelStyle: const TextStyle(color: Colors.white54),
                        filled: true,
                        fillColor: const Color(0xFF0F172A),
                        border: const OutlineInputBorder(borderRadius: BorderRadius.all(Radius.circular(10)), borderSide: BorderSide.none),
                        suffixIcon: IconButton(
                          icon: const Icon(Icons.open_in_new_rounded, color: Color(0xFF0284C7)),
                          tooltip: 'Открыть сайт Yandex Cloud',
                          onPressed: _openYandexSite,
                        ),
                      ),
                    ),
                    const SizedBox(height: 10),
                    TextField(
                      controller: _yandexFolderIdCtrl,
                      style: const TextStyle(color: Colors.white),
                      decoration: const InputDecoration(
                        labelText: 'Folder ID каталога Yandex (необязательно)',
                        hintText: 'b1g...',
                        labelStyle: TextStyle(color: Colors.white54),
                        filled: true,
                        fillColor: Color(0xFF0F172A),
                        border: OutlineInputBorder(borderRadius: BorderRadius.all(Radius.circular(10)), borderSide: BorderSide.none),
                      ),
                    ),
                    const SizedBox(height: 8),
                    GestureDetector(
                      onTap: _openYandexSite,
                      child: const Text(
                        '👉 Нажмите здесь, чтобы получить ключ Yandex Cloud Vision (cloud.yandex.ru)',
                        style: TextStyle(color: Color(0xFF38BDF8), fontSize: 12, decoration: TextDecoration.underline),
                      ),
                    ),
                  ] else ...[
                    Container(
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: const Color(0xFF0F172A),
                        borderRadius: BorderRadius.circular(10),
                        border: Border.all(color: const Color(0xFF10B981).withOpacity(0.3)),
                      ),
                      child: Row(
                        children: [
                          Icon(
                            _geminiKeyCtrl.text.trim().startsWith('AIzaSy')
                                ? Icons.verified_rounded
                                : Icons.bolt_rounded,
                            color: const Color(0xFF10B981),
                            size: 22,
                          ),
                          const SizedBox(width: 10),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  _geminiKeyCtrl.text.trim().startsWith('AIzaSy')
                                      ? 'Google Gemini Vision AI подключен'
                                      : '⚡ Быстрый режим (Google ML Kit)',
                                  style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 13),
                                ),
                                const SizedBox(height: 2),
                                Text(
                                  _geminiKeyCtrl.text.trim().startsWith('AIzaSy')
                                      ? 'Автоматический разбор таблиц через облачную нейросеть Google.'
                                      : 'Молниеносное распознавание за 1.5 сек. Работает офлайн без интернета!',
                                  style: const TextStyle(color: Colors.white70, fontSize: 11),
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 10),
                    if (!_showGeminiKeyField) ...[
                      Align(
                        alignment: Alignment.centerLeft,
                        child: TextButton.icon(
                          onPressed: () => setState(() => _showGeminiKeyField = true),
                          icon: const Icon(Icons.key_rounded, size: 16, color: Color(0xFF38BDF8)),
                          label: Text(
                            _geminiKeyCtrl.text.trim().startsWith('AIzaSy')
                                ? 'Сменить ключ Gemini API'
                                : 'Ввести свой ключ Google Gemini API...',
                            style: const TextStyle(color: Color(0xFF38BDF8), fontSize: 12),
                          ),
                        ),
                      ),
                    ] else ...[
                      TextField(
                        controller: _geminiKeyCtrl,
                        style: const TextStyle(color: Colors.white),
                        decoration: InputDecoration(
                          labelText: 'Google Gemini API Key (необязательно)',
                          hintText: 'AIzaSy...',
                          labelStyle: const TextStyle(color: Colors.white54),
                          filled: true,
                          fillColor: const Color(0xFF0F172A),
                          border: const OutlineInputBorder(borderRadius: BorderRadius.all(Radius.circular(10)), borderSide: BorderSide.none),
                          suffixIcon: IconButton(
                            icon: const Icon(Icons.close_rounded, color: Colors.white54),
                            onPressed: () => setState(() => _showGeminiKeyField = false),
                          ),
                        ),
                      ),
                      const SizedBox(height: 6),
                      const Text(
                        '💡 Без ключа сканер работает в автономном режиме Google ML Kit (1.5 сек, как в v1.4.10).',
                        style: TextStyle(color: Colors.white54, fontSize: 11),
                      ),
                    ],
                  ],
                ],
              ),
            ),

            const SizedBox(height: 24),

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
                  FutureBuilder<String>(
                    future: _updater.getCurrentVersion(),
                    builder: (ctx, snapshot) {
                      final ver = snapshot.data ?? '1.0.9';
                      return Column(
                        children: [
                          Row(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              const Icon(Icons.verified, color: Color(0xFF10B981), size: 16),
                              const SizedBox(width: 6),
                              Text('Установленная версия: v$ver', style: const TextStyle(color: Colors.white70, fontSize: 13, fontWeight: FontWeight.bold)),
                            ],
                          ),
                          const SizedBox(height: 10),
                          OutlinedButton.icon(
                            style: OutlinedButton.styleFrom(
                              side: const BorderSide(color: Color(0xFF38BDF8), width: 1.5),
                              foregroundColor: const Color(0xFF38BDF8),
                              minimumSize: const Size(double.infinity, 44),
                              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                            ),
                            icon: const Icon(Icons.system_update_rounded),
                            label: const Text('Проверить и скачать обновление APK', style: TextStyle(fontWeight: FontWeight.bold)),
                            onPressed: _checkApkUpdate,
                          ),
                        ],
                      );
                    },
                  ),
                ],
              ),
            ),

            const SizedBox(height: 32),

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
