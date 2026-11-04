import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../services/api_service.dart';
import '../utils/top_notification.dart';
import 'home_screen.dart';

class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key});

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final ApiService _api = ApiService();

  final TextEditingController _usernameCtrl = TextEditingController();
  final TextEditingController _passwordCtrl = TextEditingController();
  final FocusNode _usernameFocus = FocusNode();

  List<Map<String, dynamic>> _stores = [];
  int? _selectedStoreId;
  bool _userExplicitlySelectedStore = false;
  bool _loadingStores = true;

  List<Map<String, dynamic>> _savedAccounts = [];
  bool _showSavedAccountsList = false;

  bool _rememberPassword = true;
  bool _obscurePassword = true;
  bool _isLoading = false;
  String? _errorMessage;

  @override
  void initState() {
    super.initState();
    _usernameFocus.addListener(() {
      if (_usernameFocus.hasFocus && mounted) {
        setState(() => _showSavedAccountsList = true);
      }
    });
    _loadStores();
  }

  Future<void> _loadStores() async {
    setState(() => _loadingStores = true);
    final prefs = await SharedPreferences.getInstance();
    final savedStoreId = prefs.getInt('store_id');

    List<Map<String, dynamic>> storesList = [];
    try {
      storesList = await _api.fetchStores();
    } catch (_) {}

    if (storesList.isEmpty && _api.accessibleStores.isNotEmpty) {
      storesList = _api.accessibleStores;
    }

    if (storesList.isEmpty) {
      storesList = [
        {'id': 2, 'name': 'Мағозаи Арзон', 'is_active': true},
        {'id': 3, 'name': 'Мағозаи намунавӣ (Тестӣ #3)', 'is_active': true},
        {'id': 7, 'name': 'Алкомаркет №7', 'is_active': true},
      ];
    }

    int? defaultId = savedStoreId;
    if (defaultId == null || !storesList.any((s) => s['id'] == defaultId)) {
      if (storesList.any((s) => s['id'] == 2)) {
        defaultId = 2;
      } else if (storesList.any((s) => s['id'] == 3)) {
        defaultId = 3;
      } else {
        defaultId = storesList.first['id'] as int;
      }
    }

    if (mounted) {
      setState(() {
        _stores = storesList;
        _selectedStoreId = defaultId;
        _loadingStores = false;
      });
      _loadSavedCredentials(storeId: defaultId);
    }
  }

  Future<void> _loadSavedCredentials({int? storeId}) async {
    final prefs = await SharedPreferences.getInstance();
    final targetStoreId = storeId ?? _selectedStoreId ?? prefs.getInt('store_id');
    final accounts = await _api.getSavedAccounts(filterStoreId: targetStoreId);
    String savedUser = prefs.getString('saved_username') ?? prefs.getString('logged_username') ?? '';
    String savedPass = prefs.getString('saved_password') ?? '';
    final remember = prefs.getBool('remember_credentials') ?? true;

    // Подбираем сохранённый аккаунт именно для выбранного магазина
    if (targetStoreId != null && targetStoreId > 0) {
      final storeAccWithPass = accounts.firstWhere(
        (a) => a['store_id'] == targetStoreId && (a['password'] ?? '').toString().isNotEmpty,
        orElse: () => accounts.firstWhere((a) => a['store_id'] == targetStoreId, orElse: () => {}),
      );
      if (storeAccWithPass.isNotEmpty) {
        savedUser = (storeAccWithPass['username'] ?? '').toString();
        savedPass = (storeAccWithPass['password'] ?? '').toString();
      }
    } else if ((savedUser.isEmpty || savedPass.isEmpty) && accounts.isNotEmpty) {
      final firstWithPass = accounts.firstWhere(
        (a) => (a['password'] ?? '').toString().isNotEmpty,
        orElse: () => accounts.first,
      );
      savedUser = (firstWithPass['username'] ?? '').toString();
      savedPass = (firstWithPass['password'] ?? '').toString();
    }

    if (mounted) {
      setState(() {
        _savedAccounts = accounts;
        if (savedUser.isNotEmpty) {
          _usernameCtrl.text = savedUser;
        }
        if (savedPass.isNotEmpty) {
          _passwordCtrl.text = savedPass;
        }
        _rememberPassword = remember;
      });
    }
  }

  void _applySavedAccount(Map<String, dynamic> acc, {bool autoLogin = false}) {
    final user = (acc['username'] ?? '').toString().trim();
    final pass = (acc['password'] ?? '').toString();
    final accStoreId = acc['store_id'] is int
        ? acc['store_id'] as int
        : int.tryParse(acc['store_id']?.toString() ?? '');

    setState(() {
      _usernameCtrl.text = user;
      _passwordCtrl.text = pass;
      if (accStoreId != null && accStoreId > 0 && _stores.any((s) => s['id'] == accStoreId)) {
        _selectedStoreId = accStoreId;
      }
      _showSavedAccountsList = false;
      _errorMessage = null;
    });
    FocusScope.of(context).unfocus();

    if (autoLogin && user.isNotEmpty && pass.isNotEmpty) {
      _handleLogin();
    }
  }

  Future<void> _deleteSavedAccount(String username) async {
    await _api.removeSavedAccount(username);
    final updated = await _api.getSavedAccounts();
    if (mounted) {
      setState(() {
        _savedAccounts = updated;
        if (_savedAccounts.isEmpty) {
          _showSavedAccountsList = false;
        }
      });
    }
  }

  Future<void> _handleLogin() async {
    final username = _usernameCtrl.text.trim();
    final password = _passwordCtrl.text.trim();

    if (username.isEmpty || password.isEmpty) {
      setState(() {
        _errorMessage = 'Пожалуйста, введите логин и пароль сотрудника.';
      });
      TopNotification.showWarning(context, 'Введите логин и пароль сотрудника');
      return;
    }

    setState(() {
      _isLoading = true;
      _errorMessage = null;
      _showSavedAccountsList = false;
    });

    final result = await _api.login(
      username,
      password,
      preferredStoreId: _selectedStoreId,
      userExplicitlySelectedStore: _userExplicitlySelectedStore,
      remember: _rememberPassword,
    );

    if (!mounted) return;

    setState(() {
      _isLoading = false;
    });

    if (result['success'] == true) {
      TextInput.finishAutofillContext();
      final storeName = result['store_name'] ?? _api.currentStoreName;
      TopNotification.showSuccess(context, 'Вход выполнен! Магазин: $storeName');

      Navigator.pushReplacement(
        context,
        MaterialPageRoute(builder: (_) => const HomeScreen()),
      );
    } else {
      final errMsg = result['message'] ?? 'Неверный логин или пароль.';
      setState(() {
        _errorMessage = errMsg;
      });
      TopNotification.showError(context, errMsg);
    }
  }

  @override
  void dispose() {
    _usernameFocus.dispose();
    _usernameCtrl.dispose();
    _passwordCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF0F172A), // Slate 900
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 20),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                // Логотип и брендинг Gusar
                Container(
                  padding: const EdgeInsets.all(18),
                  decoration: BoxDecoration(
                    color: const Color(0xFF10B981).withOpacity(0.12),
                    shape: BoxShape.circle,
                    border: Border.all(color: const Color(0xFF10B981).withOpacity(0.3), width: 2),
                  ),
                  child: const Icon(Icons.qr_code_scanner_rounded, color: Color(0xFF10B981), size: 48),
                ),
                const SizedBox(height: 16),
                const Text(
                  'GScan',
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 26,
                    fontWeight: FontWeight.bold,
                    letterSpacing: 1.2,
                  ),
                ),
                const SizedBox(height: 6),
                const Text(
                  'Терминал приёмки накладных для сети gusar.tj',
                  style: TextStyle(color: Colors.white54, fontSize: 13),
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 32),

                // Карточка формы входа
                Container(
                  padding: const EdgeInsets.all(22),
                  decoration: BoxDecoration(
                    color: const Color(0xFF1E293B),
                    borderRadius: BorderRadius.circular(18),
                    border: Border.all(color: Colors.white10),
                    boxShadow: [
                      BoxShadow(
                        color: Colors.black.withOpacity(0.35),
                        blurRadius: 20,
                        offset: const Offset(0, 10),
                      ),
                    ],
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                        'Вход сотрудника',
                        style: TextStyle(color: Colors.white, fontSize: 17, fontWeight: FontWeight.bold),
                      ),
                      const SizedBox(height: 4),
                      const SizedBox(height: 16),

                      // Выбор магазина / склада приёмки
                      const Text(
                        'Магазин / Склад приёмки:',
                        style: TextStyle(color: Colors.white70, fontSize: 13, fontWeight: FontWeight.w600),
                      ),
                      const SizedBox(height: 6),
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                        decoration: BoxDecoration(
                          color: const Color(0xFF0F172A),
                          borderRadius: BorderRadius.circular(12),
                          border: Border.all(color: const Color(0xFF10B981).withOpacity(0.5)),
                        ),
                        child: _loadingStores
                            ? const Padding(
                                padding: EdgeInsets.symmetric(vertical: 10),
                                child: Row(
                                  children: [
                                    SizedBox(
                                      width: 16,
                                      height: 16,
                                      child: CircularProgressIndicator(strokeWidth: 2, color: Color(0xFF10B981)),
                                    ),
                                    SizedBox(width: 10),
                                    Text('Загрузка магазинов gusar.tj...', style: TextStyle(color: Colors.white54, fontSize: 13)),
                                  ],
                                ),
                              )
                            : DropdownButtonHideUnderline(
                                child: DropdownButton<int>(
                                  value: _selectedStoreId,
                                  isExpanded: true,
                                  dropdownColor: const Color(0xFF1E293B),
                                  icon: const Icon(Icons.keyboard_arrow_down_rounded, color: Color(0xFF10B981)),
                                  style: const TextStyle(color: Colors.white, fontSize: 14),
                                  items: _stores.map((s) {
                                    final id = s['id'] is int ? s['id'] as int : int.tryParse(s['id']?.toString() ?? '1') ?? 1;
                                    final name = s['name']?.toString() ?? 'Магазин #$id';
                                    return DropdownMenuItem<int>(
                                      value: id,
                                      child: Row(
                                        children: [
                                          const Icon(Icons.storefront_rounded, size: 18, color: Color(0xFF10B981)),
                                          const SizedBox(width: 8),
                                          Expanded(
                                            child: Text(
                                              name,
                                              overflow: TextOverflow.ellipsis,
                                              style: TextStyle(
                                                color: Colors.white,
                                                fontWeight: id == 3 ? FontWeight.bold : FontWeight.normal,
                                              ),
                                            ),
                                          ),
                                          Container(
                                            margin: const EdgeInsets.only(left: 6),
                                            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                                            decoration: BoxDecoration(
                                              color: const Color(0xFF10B981).withOpacity(0.2),
                                              borderRadius: BorderRadius.circular(6),
                                            ),
                                            child: Text(
                                              '#$id',
                                              style: const TextStyle(color: Color(0xFF10B981), fontSize: 11, fontWeight: FontWeight.bold),
                                            ),
                                          ),
                                        ],
                                      ),
                                    );
                                  }).toList(),
                                  onChanged: (newId) {
                                    if (newId != null) {
                                      setState(() {
                                        _selectedStoreId = newId;
                                        _userExplicitlySelectedStore = true;
                                      });
                                      _loadSavedCredentials(storeId: newId);
                                    }
                                  },
                                ),
                              ),
                      ),
                      const SizedBox(height: 16),

                      // Быстрый выбор сохранённых аккаунтов (логинов и паролей)
                      if (_savedAccounts.isNotEmpty) ...[
                        Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            const Row(
                              children: [
                                Icon(Icons.vpn_key_rounded, size: 14, color: Color(0xFF10B981)),
                                SizedBox(width: 6),
                                Text(
                                  'Сохранённые аккаунты (быстрый вход):',
                                  style: TextStyle(color: Colors.white70, fontSize: 12, fontWeight: FontWeight.w600),
                                ),
                              ],
                            ),
                            Text(
                              '${_savedAccounts.length}',
                              style: const TextStyle(color: Color(0xFF10B981), fontSize: 11, fontWeight: FontWeight.bold),
                            ),
                          ],
                        ),
                        const SizedBox(height: 8),
                        SingleChildScrollView(
                          scrollDirection: Axis.horizontal,
                          child: Row(
                            children: _savedAccounts.map((acc) {
                              final accUser = (acc['username'] ?? '').toString();
                              final accStoreName = (acc['store_name'] ?? '').toString();
                              final hasPass = (acc['password'] ?? '').toString().isNotEmpty;
                              final isCurrent = _usernameCtrl.text.trim().toLowerCase() == accUser.trim().toLowerCase();
                              return Container(
                                margin: const EdgeInsets.only(right: 8),
                                child: InkWell(
                                  borderRadius: BorderRadius.circular(10),
                                  onTap: () => _applySavedAccount(acc),
                                  child: Container(
                                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                                    decoration: BoxDecoration(
                                      color: isCurrent
                                          ? const Color(0xFF10B981).withOpacity(0.2)
                                          : const Color(0xFF0F172A),
                                      borderRadius: BorderRadius.circular(10),
                                      border: Border.all(
                                        color: isCurrent
                                            ? const Color(0xFF10B981)
                                            : (hasPass ? const Color(0xFF10B981).withOpacity(0.4) : Colors.white12),
                                        width: isCurrent ? 1.4 : 1.0,
                                      ),
                                    ),
                                    child: Row(
                                      mainAxisSize: MainAxisSize.min,
                                      children: [
                                        Icon(
                                          hasPass ? Icons.vpn_key_rounded : Icons.account_circle_rounded,
                                          size: 15,
                                          color: hasPass
                                              ? const Color(0xFF10B981)
                                              : (isCurrent ? const Color(0xFF10B981) : const Color(0xFF38BDF8)),
                                        ),
                                        const SizedBox(width: 6),
                                        Column(
                                          crossAxisAlignment: CrossAxisAlignment.start,
                                          mainAxisSize: MainAxisSize.min,
                                          children: [
                                            Text(
                                              accUser,
                                              style: TextStyle(
                                                color: Colors.white,
                                                fontSize: 12,
                                                fontWeight: isCurrent ? FontWeight.bold : FontWeight.w600,
                                              ),
                                            ),
                                            if (accStoreName.isNotEmpty)
                                              Text(
                                                accStoreName.length > 22 ? '${accStoreName.substring(0, 22)}…' : accStoreName,
                                                style: const TextStyle(color: Colors.white54, fontSize: 9.5),
                                              ),
                                          ],
                                        ),
                                        if (hasPass) ...[
                                          const SizedBox(width: 6),
                                          InkWell(
                                            onTap: () => _applySavedAccount(acc, autoLogin: true),
                                            borderRadius: BorderRadius.circular(6),
                                            child: Container(
                                              padding: const EdgeInsets.all(3),
                                              decoration: BoxDecoration(
                                                color: const Color(0xFF10B981).withOpacity(0.25),
                                                borderRadius: BorderRadius.circular(6),
                                              ),
                                              child: const Icon(Icons.login_rounded, size: 13, color: Color(0xFF10B981)),
                                            ),
                                          ),
                                        ],
                                      ],
                                    ),
                                  ),
                                ),
                              );
                            }).toList(),
                          ),
                        ),
                        const SizedBox(height: 12),
                      ],

                      AutofillGroup(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            // Поле логина
                            TextField(
                              controller: _usernameCtrl,
                              focusNode: _usernameFocus,
                              autofillHints: const [AutofillHints.username],
                              textInputAction: TextInputAction.next,
                              style: const TextStyle(color: Colors.white),
                              onTap: () {
                                if (_savedAccounts.isNotEmpty) {
                                  setState(() => _showSavedAccountsList = true);
                                }
                              },
                              onChanged: (_) {
                                setState(() {});
                              },
                              decoration: InputDecoration(
                                labelText: 'Логин / Телефон',
                                labelStyle: const TextStyle(color: Colors.white60),
                                prefixIcon: const Icon(Icons.person_outline_rounded, color: Color(0xFF38BDF8)),
                                suffixIcon: Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    if (_usernameCtrl.text.isNotEmpty)
                                      IconButton(
                                        icon: const Icon(Icons.clear_rounded, color: Colors.white38, size: 18),
                                        tooltip: 'Очистить поле',
                                        onPressed: () {
                                          setState(() {
                                            _usernameCtrl.clear();
                                            _passwordCtrl.clear();
                                            if (_savedAccounts.isNotEmpty) {
                                              _showSavedAccountsList = true;
                                            }
                                          });
                                        },
                                      ),
                                    if (_savedAccounts.isNotEmpty)
                                      IconButton(
                                        icon: Icon(
                                          _showSavedAccountsList
                                              ? Icons.keyboard_arrow_up_rounded
                                              : Icons.keyboard_arrow_down_rounded,
                                          color: const Color(0xFF10B981),
                                        ),
                                        tooltip: 'Выбрать сохранённый логин и пароль',
                                        onPressed: () {
                                          setState(() => _showSavedAccountsList = !_showSavedAccountsList);
                                        },
                                      ),
                                  ],
                                ),
                                filled: true,
                                fillColor: const Color(0xFF0F172A),
                                border: OutlineInputBorder(
                                  borderRadius: BorderRadius.circular(12),
                                  borderSide: BorderSide.none,
                                ),
                                enabledBorder: OutlineInputBorder(
                                  borderRadius: BorderRadius.circular(12),
                                  borderSide: const BorderSide(color: Colors.white12),
                                ),
                                focusedBorder: OutlineInputBorder(
                                  borderRadius: BorderRadius.circular(12),
                                  borderSide: const BorderSide(color: Color(0xFF10B981), width: 1.5),
                                ),
                              ),
                            ),

                            // Выпадающий список сохранённых логинов и паролей при нажатии на поле логина
                            if (_showSavedAccountsList && _savedAccounts.isNotEmpty) ...[
                              const SizedBox(height: 6),
                              Container(
                                decoration: BoxDecoration(
                                  color: const Color(0xFF0F172A),
                                  borderRadius: BorderRadius.circular(12),
                                  border: Border.all(color: const Color(0xFF10B981).withOpacity(0.5)),
                                ),
                                child: Column(
                                  mainAxisSize: MainAxisSize.min,
                                  children: _savedAccounts.map((acc) {
                                    final accUser = (acc['username'] ?? '').toString();
                                    final accStore = (acc['store_name'] ?? '').toString();
                                    final hasPass = (acc['password'] ?? '').toString().isNotEmpty;
                                    return ListTile(
                                      dense: true,
                                      contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 2),
                                      leading: Icon(
                                        hasPass ? Icons.vpn_key_rounded : Icons.person_outline_rounded,
                                        color: hasPass ? const Color(0xFF10B981) : const Color(0xFF38BDF8),
                                        size: 18,
                                      ),
                                      title: Text(
                                        accUser,
                                        style: const TextStyle(color: Colors.white, fontSize: 13, fontWeight: FontWeight.bold),
                                      ),
                                      subtitle: Text(
                                        hasPass
                                            ? (accStore.isNotEmpty ? '$accStore • Пароль сохранён' : 'Пароль сохранён (••••••••)')
                                            : (accStore.isNotEmpty ? '$accStore • Нажмите для подстановки логина' : 'Сотрудник магазина'),
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        style: TextStyle(
                                          color: hasPass ? const Color(0xFF34D399) : Colors.white54,
                                          fontSize: 11,
                                        ),
                                      ),
                                      trailing: Row(
                                        mainAxisSize: MainAxisSize.min,
                                        children: [
                                          if (hasPass) ...[
                                            IconButton(
                                              icon: const Icon(Icons.login_rounded, color: Color(0xFF10B981), size: 18),
                                              tooltip: 'Войти сразу',
                                              constraints: const BoxConstraints(),
                                              padding: const EdgeInsets.all(4),
                                              onPressed: () => _applySavedAccount(acc, autoLogin: true),
                                            ),
                                            const SizedBox(width: 4),
                                          ],
                                          IconButton(
                                            icon: const Icon(Icons.close_rounded, color: Colors.white38, size: 16),
                                            tooltip: 'Удалить из списка',
                                            constraints: const BoxConstraints(),
                                            padding: const EdgeInsets.all(4),
                                            onPressed: () => _deleteSavedAccount(accUser),
                                          ),
                                        ],
                                      ),
                                      onTap: () => _applySavedAccount(acc),
                                    );
                                  }).toList(),
                                ),
                              ),
                            ],

                            const SizedBox(height: 14),

                            // Поле пароля
                            TextField(
                              controller: _passwordCtrl,
                              obscureText: _obscurePassword,
                              autofillHints: const [AutofillHints.password],
                              textInputAction: TextInputAction.done,
                              onSubmitted: (_) => _handleLogin(),
                              style: const TextStyle(color: Colors.white),
                              decoration: InputDecoration(
                                labelText: 'Пароль',
                                labelStyle: const TextStyle(color: Colors.white60),
                                prefixIcon: const Icon(Icons.lock_outline_rounded, color: Color(0xFF38BDF8)),
                                suffixIcon: IconButton(
                                  icon: Icon(
                                    _obscurePassword ? Icons.visibility_off_outlined : Icons.visibility_outlined,
                                    color: Colors.white54,
                                  ),
                                  onPressed: () => setState(() => _obscurePassword = !_obscurePassword),
                                ),
                                filled: true,
                                fillColor: const Color(0xFF0F172A),
                                border: OutlineInputBorder(
                                  borderRadius: BorderRadius.circular(12),
                                  borderSide: BorderSide.none,
                                ),
                                enabledBorder: OutlineInputBorder(
                                  borderRadius: BorderRadius.circular(12),
                                  borderSide: const BorderSide(color: Colors.white12),
                                ),
                                focusedBorder: OutlineInputBorder(
                                  borderRadius: BorderRadius.circular(12),
                                  borderSide: const BorderSide(color: Color(0xFF10B981), width: 1.5),
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 12),

                      // Чекбокс: Сохранить пароль
                      Row(
                        children: [
                          SizedBox(
                            width: 24,
                            height: 24,
                            child: Checkbox(
                              value: _rememberPassword,
                              activeColor: const Color(0xFF10B981),
                              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(4)),
                              onChanged: (val) {
                                setState(() => _rememberPassword = val ?? true);
                              },
                            ),
                          ),
                          const SizedBox(width: 8),
                          GestureDetector(
                            onTap: () {
                              setState(() => _rememberPassword = !_rememberPassword);
                            },
                            child: const Text(
                              'Сохранить пароль (входить автоматически)',
                              style: TextStyle(color: Colors.white70, fontSize: 12),
                            ),
                          ),
                        ],
                      ),

                      if (_errorMessage != null) ...[
                        const SizedBox(height: 14),
                        Container(
                          width: double.infinity,
                          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                          decoration: BoxDecoration(
                            color: Colors.red.withOpacity(0.12),
                            borderRadius: BorderRadius.circular(10),
                            border: Border.all(color: Colors.red.withOpacity(0.3)),
                          ),
                          child: Row(
                            children: [
                              const Icon(Icons.error_outline_rounded, color: Colors.redAccent, size: 20),
                              const SizedBox(width: 8),
                              Expanded(
                                child: Text(
                                  _errorMessage!,
                                  style: const TextStyle(color: Colors.redAccent, fontSize: 12),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],

                      const SizedBox(height: 20),

                      // Кнопка входа
                      SizedBox(
                        width: double.infinity,
                        height: 50,
                        child: ElevatedButton(
                          style: ElevatedButton.styleFrom(
                            backgroundColor: const Color(0xFF10B981),
                            foregroundColor: Colors.white,
                            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                            elevation: 3,
                          ),
                          onPressed: _isLoading ? null : _handleLogin,
                          child: _isLoading
                              ? const SizedBox(
                                  width: 22,
                                  height: 22,
                                  child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2.5),
                                )
                              : const Row(
                                  mainAxisAlignment: MainAxisAlignment.center,
                                  children: [
                                    Icon(Icons.login_rounded, size: 20),
                                    SizedBox(width: 8),
                                    Text(
                                      'Войти в систему',
                                      style: TextStyle(fontSize: 15, fontWeight: FontWeight.bold),
                                    ),
                                  ],
                                ),
                        ),
                      ),
                    ],
                  ),
                ),

                const SizedBox(height: 20),

                // Подсказка о безопасности и магазинах
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                  decoration: BoxDecoration(
                    color: const Color(0xFF1E293B).withOpacity(0.6),
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(color: Colors.white10),
                  ),
                  child: const Row(
                    children: [
                      Icon(Icons.security_rounded, color: Color(0xFF10B981), size: 18),
                      SizedBox(width: 10),
                      Expanded(
                        child: Text(
                          'Вам будет доступен только ваш магазин. Доступ к чужим магазинам закрыт.',
                          style: TextStyle(color: Colors.white54, fontSize: 11, height: 1.3),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
