import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:intl/intl.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/invoice_document.dart';
import '../services/api_service.dart';
import '../services/local_storage_service.dart';
import '../services/updater_service.dart';
import 'camera_scanner_screen.dart';
import 'invoice_review_screen.dart';
import 'settings_screen.dart';
import 'add_product_screen.dart';
import 'product_photo_manager_screen.dart';
import '../widgets/document_photo_viewer_dialog.dart';
import '../utils/top_notification.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  final ApiService _api = ApiService();
  final LocalStorageService _storage = LocalStorageService();
  final UpdaterService _updater = UpdaterService();

  List<InvoiceDocument> _recentInvoices = [];
  bool _isLoading = true;
  String? _storeName = 'Магазин Gusar #1 (Центральный)';
  String? _loggedUser;
  bool _isAuthenticated = false;
  UpdateInfo? _availableUpdate;

  // Быстрый поиск и фильтрация накладных
  final TextEditingController _searchCtrl = TextEditingController();
  String _searchQuery = '';
  String? _selectedSupplierFilter;
  String _dateFilterType = 'all'; // 'all', 'today', 'yesterday', 'week', 'month', 'custom'
  DateTimeRange? _customDateRange;
  String _amountFilterType = 'all'; // 'all', 'under500', '500_2000', '2000_10000', 'over10000'

  @override
  void initState() {
    super.initState();
    _searchCtrl.addListener(() {
      if (_searchQuery != _searchCtrl.text) {
        setState(() => _searchQuery = _searchCtrl.text);
      }
    });
    _loadData();
    _checkUpdates();
  }

  @override
  void dispose() {
    _searchCtrl.dispose();
    super.dispose();
  }

  List<String> get _availableSuppliers {
    final Set<String> suppliers = {};
    for (var doc in _recentInvoices) {
      final name = doc.supplierName.trim();
      if (name.isNotEmpty && name != 'Неизвестный поставщик') {
        suppliers.add(name);
      }
    }
    final list = suppliers.toList();
    list.sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));
    return list;
  }

  List<InvoiceDocument> get _filteredInvoices {
    final query = _searchQuery.toLowerCase().trim();
    final now = DateTime.now();
    final todayStart = DateTime(now.year, now.month, now.day);
    final yesterdayStart = todayStart.subtract(const Duration(days: 1));
    final weekStart = todayStart.subtract(const Duration(days: 7));
    final monthStart = todayStart.subtract(const Duration(days: 30));

    return _recentInvoices.where((doc) {
      // 1. Текстовый поиск (по системному номеру, входящему номеру, поставщику, сумме)
      if (query.isNotEmpty) {
        final invNum = doc.invoiceNumber.toLowerCase();
        final inNum = doc.incomingNumber.toLowerCase();
        final supName = doc.supplierName.toLowerCase();
        final totalStr = doc.totalAmount.toStringAsFixed(2);
        final matches = invNum.contains(query) ||
            inNum.contains(query) ||
            supName.contains(query) ||
            totalStr.contains(query);
        if (!matches) return false;
      }

      // 2. Фильтр по контрагенту
      if (_selectedSupplierFilter != null && _selectedSupplierFilter!.isNotEmpty) {
        if (doc.supplierName.trim().toLowerCase() != _selectedSupplierFilter!.trim().toLowerCase()) {
          return false;
        }
      }

      // 3. Фильтр по дате
      final docDate = doc.invoiceDate;
      if (_dateFilterType == 'today') {
        if (docDate.isBefore(todayStart)) return false;
      } else if (_dateFilterType == 'yesterday') {
        if (docDate.isBefore(yesterdayStart) || docDate.isAfter(todayStart)) return false;
      } else if (_dateFilterType == 'week') {
        if (docDate.isBefore(weekStart)) return false;
      } else if (_dateFilterType == 'month') {
        if (docDate.isBefore(monthStart)) return false;
      } else if (_dateFilterType == 'custom' && _customDateRange != null) {
        final start = DateTime(_customDateRange!.start.year, _customDateRange!.start.month, _customDateRange!.start.day);
        final end = DateTime(_customDateRange!.end.year, _customDateRange!.end.month, _customDateRange!.end.day, 23, 59, 59);
        if (docDate.isBefore(start) || docDate.isAfter(end)) return false;
      }

      // 4. Фильтр по сумме
      final amount = doc.totalAmount > 0 ? doc.totalAmount : doc.calculatedTotal;
      if (_amountFilterType == 'under500') {
        if (amount >= 500) return false;
      } else if (_amountFilterType == '500_2000') {
        if (amount < 500 || amount > 2000) return false;
      } else if (_amountFilterType == '2000_10000') {
        if (amount < 2000 || amount > 10000) return false;
      } else if (_amountFilterType == 'over10000') {
        if (amount <= 10000) return false;
      }

      return true;
    }).toList();
  }

  bool get _hasActiveFilters {
    return _searchQuery.isNotEmpty ||
        _selectedSupplierFilter != null ||
        _dateFilterType != 'all' ||
        _amountFilterType != 'all';
  }

  int get _activeFiltersCount {
    int c = 0;
    if (_searchQuery.isNotEmpty) c++;
    if (_selectedSupplierFilter != null) c++;
    if (_dateFilterType != 'all') c++;
    if (_amountFilterType != 'all') c++;
    return c;
  }

  void _resetAllFilters() {
    setState(() {
      _searchCtrl.clear();
      _searchQuery = '';
      _selectedSupplierFilter = null;
      _dateFilterType = 'all';
      _customDateRange = null;
      _amountFilterType = 'all';
    });
  }

  void _showSupplierFilterPicker() {
    final suppliers = _availableSuppliers;
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: const Color(0xFF1E293B),
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (ctx) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  const Icon(Icons.person_search_rounded, color: Color(0xFF10B981), size: 24),
                  const SizedBox(width: 10),
                  const Text('Фильтр по контрагенту', style: TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.bold)),
                  const Spacer(),
                  IconButton(
                    icon: const Icon(Icons.close_rounded, color: Colors.white54),
                    onPressed: () => Navigator.pop(ctx),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: const Icon(Icons.all_inclusive_rounded, color: Color(0xFF10B981)),
                title: const Text('Все контрагенты', style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
                trailing: _selectedSupplierFilter == null ? const Icon(Icons.check, color: Color(0xFF10B981)) : null,
                onTap: () {
                  setState(() => _selectedSupplierFilter = null);
                  Navigator.pop(ctx);
                },
              ),
              const Divider(color: Colors.white12),
              if (suppliers.isEmpty)
                const Padding(
                  padding: EdgeInsets.symmetric(vertical: 20),
                  child: Center(child: Text('Нет сохранённых контрагентов в накладных', style: TextStyle(color: Colors.white54))),
                )
              else
                ConstrainedBox(
                  constraints: BoxConstraints(maxHeight: MediaQuery.of(context).size.height * 0.45),
                  child: ListView.builder(
                    shrinkWrap: true,
                    itemCount: suppliers.length,
                    itemBuilder: (c, idx) {
                      final sup = suppliers[idx];
                      final count = _recentInvoices.where((d) => d.supplierName.trim().toLowerCase() == sup.toLowerCase()).length;
                      final isSelected = _selectedSupplierFilter == sup;
                      return ListTile(
                        contentPadding: EdgeInsets.zero,
                        title: Text(sup, style: TextStyle(color: isSelected ? const Color(0xFF10B981) : Colors.white, fontWeight: isSelected ? FontWeight.bold : FontWeight.normal)),
                        trailing: Container(
                          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                          decoration: BoxDecoration(
                            color: isSelected ? const Color(0xFF10B981) : Colors.white10,
                            borderRadius: BorderRadius.circular(12),
                          ),
                          child: Text(
                            '$count накл.',
                            style: TextStyle(color: isSelected ? Colors.white : Colors.white60, fontSize: 11),
                          ),
                        ),
                        onTap: () {
                          setState(() => _selectedSupplierFilter = sup);
                          Navigator.pop(ctx);
                        },
                      );
                    },
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  void _showDateFilterPicker() async {
    showModalBottomSheet(
      context: context,
      backgroundColor: const Color(0xFF1E293B),
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (ctx) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  const Icon(Icons.date_range_rounded, color: Color(0xFF38BDF8), size: 24),
                  const SizedBox(width: 10),
                  const Text('Фильтр по дате накладной', style: TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.bold)),
                  const Spacer(),
                  IconButton(
                    icon: const Icon(Icons.close_rounded, color: Colors.white54),
                    onPressed: () => Navigator.pop(ctx),
                  ),
                ],
              ),
              const SizedBox(height: 10),
              _dateOption(ctx, 'all', 'Все даты'),
              _dateOption(ctx, 'today', 'Сегодня'),
              _dateOption(ctx, 'yesterday', 'Вчера'),
              _dateOption(ctx, 'week', 'Последние 7 дней'),
              _dateOption(ctx, 'month', 'Последние 30 дней'),
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: const Icon(Icons.edit_calendar_rounded, color: Color(0xFF38BDF8)),
                title: Text(
                  _customDateRange != null
                      ? '${DateFormat("dd.MM.yyyy").format(_customDateRange!.start)} — ${DateFormat("dd.MM.yyyy").format(_customDateRange!.end)}'
                      : 'Выбрать произвольный период...',
                  style: const TextStyle(color: Colors.white),
                ),
                trailing: _dateFilterType == 'custom' ? const Icon(Icons.check, color: Color(0xFF10B981)) : null,
                onTap: () async {
                  Navigator.pop(ctx);
                  final picked = await showDateRangePicker(
                    context: context,
                    firstDate: DateTime(2023),
                    lastDate: DateTime.now().add(const Duration(days: 365)),
                    initialDateRange: _customDateRange ?? DateTimeRange(
                      start: DateTime.now().subtract(const Duration(days: 7)),
                      end: DateTime.now(),
                    ),
                    builder: (context, child) => Theme(
                      data: ThemeData.dark().copyWith(
                        colorScheme: const ColorScheme.dark(
                          primary: Color(0xFF10B981),
                          onPrimary: Colors.white,
                          surface: Color(0xFF1E293B),
                          onSurface: Colors.white,
                        ),
                      ),
                      child: child!,
                    ),
                  );
                  if (picked != null) {
                    setState(() {
                      _dateFilterType = 'custom';
                      _customDateRange = picked;
                    });
                  }
                },
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _dateOption(BuildContext ctx, String type, String label) {
    final isSelected = _dateFilterType == type;
    return ListTile(
      contentPadding: EdgeInsets.zero,
      title: Text(label, style: TextStyle(color: isSelected ? const Color(0xFF10B981) : Colors.white, fontWeight: isSelected ? FontWeight.bold : FontWeight.normal)),
      trailing: isSelected ? const Icon(Icons.check, color: Color(0xFF10B981)) : null,
      onTap: () {
        setState(() {
          _dateFilterType = type;
          if (type != 'custom') _customDateRange = null;
        });
        Navigator.pop(ctx);
      },
    );
  }

  void _showAmountFilterPicker() {
    showModalBottomSheet(
      context: context,
      backgroundColor: const Color(0xFF1E293B),
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (ctx) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  const Icon(Icons.payments_outlined, color: Color(0xFFF59E0B), size: 24),
                  const SizedBox(width: 10),
                  const Text('Фильтр по сумме накладной', style: TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.bold)),
                  const Spacer(),
                  IconButton(
                    icon: const Icon(Icons.close_rounded, color: Colors.white54),
                    onPressed: () => Navigator.pop(ctx),
                  ),
                ],
              ),
              const SizedBox(height: 10),
              _amountOption(ctx, 'all', 'Любая сумма'),
              _amountOption(ctx, 'under500', 'До 500 TJS'),
              _amountOption(ctx, '500_2000', 'От 500 до 2 000 TJS'),
              _amountOption(ctx, '2000_10000', 'От 2 000 до 10 000 TJS'),
              _amountOption(ctx, 'over10000', 'Более 10 000 TJS'),
            ],
          ),
        ),
      ),
    );
  }

  Widget _amountOption(BuildContext ctx, String type, String label) {
    final isSelected = _amountFilterType == type;
    return ListTile(
      contentPadding: EdgeInsets.zero,
      title: Text(label, style: TextStyle(color: isSelected ? const Color(0xFFF59E0B) : Colors.white, fontWeight: isSelected ? FontWeight.bold : FontWeight.normal)),
      trailing: isSelected ? const Icon(Icons.check, color: Color(0xFFF59E0B)) : null,
      onTap: () {
        setState(() => _amountFilterType = type);
        Navigator.pop(ctx);
      },
    );
  }

  Future<void> _loadData() async {
    setState(() => _isLoading = true);
    final prefs = await SharedPreferences.getInstance();
    final localDocs = await _storage.getLocalInvoices();
    String storeName = _api.currentStoreName.isNotEmpty ? _api.currentStoreName : (prefs.getString('store_name') ?? 'Склад gusar.tj');
    final loggedUser = prefs.getString('logged_username') ?? prefs.getString('saved_username');
    final isAuth = prefs.getBool('is_authenticated') ?? false;

    setState(() {
      _recentInvoices = localDocs;
      _storeName = storeName;
      _loggedUser = loggedUser;
      _isAuthenticated = isAuth;
      _isLoading = false;
    });

    // Фоновое обновление каталога с gusar.tj (с подтягиванием актуальных фото)
    try {
      final products = await _api.getProducts(forceRefresh: true);
      if (products.isNotEmpty) {
        await _storage.cacheProducts(products);
      }
    } catch (_) {}
  }

  Future<void> _checkUpdates({bool manual = false}) async {
    final update = await _updater.checkForUpdate();
    if (update != null && mounted) {
      setState(() => _availableUpdate = update);
      final isPostponed = await _updater.isUpdatePostponed(update.version);
      // Если пользователь не откладывал или нажал вручную — показываем уведомление
      if (!isPostponed || manual) {
        _showUpdateDialog(update);
      }
    } else if (manual && mounted) {
      TopNotification.showSuccess(context, 'У вас установлена самая актуальная версия!');
    }
  }

  void _showStoreSwitcherDialog() async {
    List<Map<String, dynamic>> stores = [];
    try {
      stores = await _api.fetchStores();
    } catch (_) {}
    if (stores.isEmpty) {
      stores = _api.accessibleStores;
    }
    if (stores.isEmpty) {
      stores = [
        {'id': 3, 'name': 'Мағозаи намунавӣ (Тестӣ #3)'},
        {'id': 2, 'name': 'Мағозаи Арзон'},
      ];
    }

    if (!mounted) return;
    showModalBottomSheet(
      context: context,
      backgroundColor: const Color(0xFF1E293B),
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (ctx) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  const Icon(Icons.storefront_rounded, color: Color(0xFF10B981), size: 24),
                  const SizedBox(width: 10),
                  const Text('Выберите магазин приёмки', style: TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.bold)),
                  const Spacer(),
                  IconButton(
                    icon: const Icon(Icons.close_rounded, color: Colors.white54),
                    onPressed: () => Navigator.pop(ctx),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              const Text('Накладные и товары будут привязаны к выбранному магазину:', style: TextStyle(color: Colors.white54, fontSize: 12)),
              const SizedBox(height: 12),
              ...stores.map((s) {
                final id = s['id'] is int ? s['id'] as int : int.tryParse(s['id']?.toString() ?? '1') ?? 1;
                final name = s['name']?.toString() ?? 'Магазин #$id';
                final isSelected = id == _api.currentStoreId;
                return ListTile(
                  contentPadding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                  leading: CircleAvatar(
                    backgroundColor: isSelected ? const Color(0xFF10B981) : const Color(0xFF0F172A),
                    radius: 18,
                    child: Icon(Icons.store, color: isSelected ? Colors.white : Colors.white70, size: 18),
                  ),
                  title: Text(
                    name,
                    style: TextStyle(
                      color: Colors.white,
                      fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
                    ),
                  ),
                  subtitle: Text('ID: $id', style: const TextStyle(color: Colors.white54, fontSize: 11)),
                  trailing: isSelected ? const Icon(Icons.check_circle_rounded, color: Color(0xFF10B981)) : null,
                  onTap: () async {
                    Navigator.pop(ctx);
                    await _api.updateStore(id, name);
                    await _loadData();
                    if (mounted) {
                      TopNotification.showSuccess(context, 'Активный магазин переключен на: $name (ID: $id)');
                    }
                  },
                );
              }),
            ],
          ),
        ),
      ),
    );
  }

  void _showUpdateDialog(UpdateInfo update) {
    showDialog(
      context: context,
      barrierDismissible: true,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF1E293B),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: Row(
          children: [
            Container(
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: const Color(0xFF10B981).withOpacity(0.2),
                borderRadius: BorderRadius.circular(10),
              ),
              child: const Icon(Icons.rocket_launch_rounded, color: Color(0xFF10B981), size: 24),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Обновление v${update.version}', style: const TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.bold)),
                  const Text('GScan (tj.gusar)', style: TextStyle(color: Colors.white54, fontSize: 12)),
                ],
              ),
            ),
          ],
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Вышла новая версия приложения. Вы можете обновиться прямо сейчас или завершить текущую приёмку и обновиться в любое удобное время.',
              style: TextStyle(color: Colors.white70, fontSize: 13, height: 1.4),
            ),
            const SizedBox(height: 14),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: const Color(0xFF0F172A),
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: Colors.white12),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('Что нового в этой версии:', style: TextStyle(color: Color(0xFF10B981), fontSize: 12, fontWeight: FontWeight.bold)),
                  const SizedBox(height: 6),
                  Text(
                    update.releaseNotes.isEmpty ? 'Плановое повышение стабильности и скорости распознавания' : update.releaseNotes,
                    maxLines: 6,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(color: Colors.white60, fontSize: 12),
                  ),
                ],
              ),
            ),
          ],
        ),
        actionsPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        actions: [
          TextButton(
            onPressed: () async {
              Navigator.pop(ctx);
              await _updater.postponeUpdate(update.version);
              if (mounted) {
                TopNotification.showInfo(context, 'Обновление отложено. Вы всегда можете запустить его из верхнего меню.');
              }
            },
            child: const Text('Позже (я решу сам)', style: TextStyle(color: Colors.white60)),
          ),
          ElevatedButton.icon(
            style: ElevatedButton.styleFrom(
              backgroundColor: const Color(0xFF10B981),
              foregroundColor: Colors.white,
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
            ),
            icon: const Icon(Icons.download_rounded, size: 18),
            label: const Text('Обновить сейчас', style: TextStyle(fontWeight: FontWeight.bold)),
            onPressed: () async {
              Navigator.pop(ctx);
              await _updater.clearPostponedUpdate();
              _updater.showDownloadAndInstallDialog(context, update);
            },
          ),
        ],
      ),
    );
  }

  void _openScanOptions() {
    // Сразу открываем камеру телефона без лишних всплывающих меню
    Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => const CameraScannerScreen(autoLaunchNativeCamera: true)),
    ).then((_) => _loadData());
  }

  void _pickFromGallery() async {
    final picker = ImagePicker();
    final images = await picker.pickMultiImage();
    if (images.isNotEmpty && mounted) {
      final paths = images.map((e) => e.path).toList();
      Navigator.push(
        context,
        MaterialPageRoute(
          builder: (_) => CameraScannerScreen(preselectedImages: paths),
        ),
      ).then((_) => _loadData());
    }
  }

  @override
  Widget build(BuildContext context) {
    final totalSumToday = _recentInvoices.fold(0.0, (s, doc) => s + doc.totalAmount);
    final totalItemsToday = _recentInvoices.fold(0, (s, doc) => s + doc.items.length);

    return Scaffold(
      backgroundColor: const Color(0xFF0F172A),
      appBar: AppBar(
        backgroundColor: const Color(0xFF1E293B),
        elevation: 0,
        title: Row(
          children: [
            Container(
              padding: const EdgeInsets.all(6),
              decoration: BoxDecoration(
                color: const Color(0xFF10B981).withOpacity(0.2),
                borderRadius: BorderRadius.circular(8),
              ),
              child: const Icon(Icons.qr_code_scanner_rounded, color: Color(0xFF10B981), size: 24),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: InkWell(
                onTap: _showStoreSwitcherDialog,
                borderRadius: BorderRadius.circular(8),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        const Text('GScan', style: TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.bold)),
                        const SizedBox(width: 6),
                        GestureDetector(
                          onTap: () {
                            Navigator.push(
                              context,
                              MaterialPageRoute(builder: (_) => const SettingsScreen()),
                            ).then((_) {
                              _loadData();
                              _checkUpdates();
                            });
                          },
                          child: Container(
                            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                            decoration: BoxDecoration(
                              color: _isAuthenticated ? const Color(0xFF10B981).withOpacity(0.2) : Colors.orange.withOpacity(0.2),
                              borderRadius: BorderRadius.circular(4),
                            ),
                            child: Text(
                              _isAuthenticated ? (_loggedUser ?? 'Вход OK') : 'Войти ⚙️',
                              style: TextStyle(
                                color: _isAuthenticated ? const Color(0xFF10B981) : Colors.orangeAccent,
                                fontSize: 10,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                    Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Flexible(
                          child: Text(
                            _storeName ?? 'Мағозаи намунавӣ (Тестӣ #3)',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(color: Color(0xFF38BDF8), fontSize: 11, fontWeight: FontWeight.w600),
                          ),
                        ),
                        const SizedBox(width: 2),
                        const Icon(Icons.arrow_drop_down, color: Color(0xFF38BDF8), size: 16),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
        actions: [
          if (_availableUpdate != null)
            IconButton(
              icon: const Badge(
                backgroundColor: Color(0xFF10B981),
                smallSize: 8,
                child: Icon(Icons.rocket_launch_rounded, color: Color(0xFF10B981)),
              ),
              tooltip: 'Доступно обновление v${_availableUpdate!.version}',
              onPressed: () => _showUpdateDialog(_availableUpdate!),
            ),
          IconButton(
            icon: const Icon(Icons.refresh, color: Colors.white70),
            tooltip: 'Обновить данные',
            onPressed: () {
              _loadData();
              _checkUpdates(manual: true);
            },
          ),
          IconButton(
            icon: const Icon(Icons.add_box_rounded, color: Color(0xFF10B981)),
            tooltip: 'Добавить новый товар',
            onPressed: () {
              Navigator.push(
                context,
                MaterialPageRoute(builder: (_) => const AddProductScreen()),
              ).then((created) {
                if (created != null) _loadData();
              });
            },
          ),
          IconButton(
            icon: const Icon(Icons.settings_outlined, color: Colors.white70),
            tooltip: 'Настройки',
            onPressed: () {
              Navigator.push(
                context,
                MaterialPageRoute(builder: (_) => const SettingsScreen()),
              ).then((_) {
                _loadData();
                _checkUpdates();
              });
            },
          ),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: () async {
          await _loadData();
          await _checkUpdates(manual: true);
        },
        color: const Color(0xFF10B981),
        backgroundColor: const Color(0xFF1E293B),
        child: SingleChildScrollView(
          physics: const AlwaysScrollableScrollPhysics(),
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
            // 0. Информационный баннер об обновлении (если отложено пользователем)
            if (_availableUpdate != null)
              Container(
                margin: const EdgeInsets.only(bottom: 16),
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    colors: [
                      const Color(0xFF064E3B).withOpacity(0.8),
                      const Color(0xFF0F766E).withOpacity(0.5),
                    ],
                  ),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: const Color(0xFF10B981).withOpacity(0.6)),
                ),
                child: Row(
                  children: [
                    const Icon(Icons.rocket_launch_rounded, color: Color(0xFF34D399), size: 22),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'Доступна версия ${_availableUpdate!.version}',
                            style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 13),
                          ),
                          const Text(
                            'Нажмите для обновления, когда закончите приёмку',
                            style: TextStyle(color: Colors.white70, fontSize: 11),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(width: 8),
                    ElevatedButton(
                      style: ElevatedButton.styleFrom(
                        backgroundColor: const Color(0xFF10B981),
                        foregroundColor: Colors.white,
                        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                        minimumSize: Size.zero,
                        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                      ),
                      onPressed: () => _showUpdateDialog(_availableUpdate!),
                      child: const Text('Обновить', style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold)),
                    ),
                  ],
                ),
              ),

            // 1. Главные кнопки действия
            Row(
              children: [
                Expanded(
                  child: _actionCard(
                    title: 'Сканировать\nнакладную',
                    subtitle: 'Камера / Чек',
                    icon: Icons.camera_alt_rounded,
                    color: const Color(0xFF10B981),
                    onTap: _openScanOptions,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: _actionCard(
                    title: 'Импорт из\nWhatsApp',
                    subtitle: 'Фото / PDF',
                    icon: Icons.attach_file_rounded,
                    color: const Color(0xFF0284C7),
                    onTap: _pickFromGallery,
                  ),
                ),
              ],
            ),

            const SizedBox(height: 12),

            // Кнопка быстрого добавления нового товара в каталог
            InkWell(
              borderRadius: BorderRadius.circular(16),
              onTap: () {
                Navigator.push(
                  context,
                  MaterialPageRoute(builder: (_) => const AddProductScreen()),
                ).then((created) {
                  if (created != null) _loadData();
                });
              },
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    colors: [
                      const Color(0xFF1E293B),
                      const Color(0xFF0F172A).withOpacity(0.9),
                    ],
                  ),
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(color: const Color(0xFF10B981).withOpacity(0.35)),
                ),
                child: Row(
                  children: [
                    Container(
                      padding: const EdgeInsets.all(10),
                      decoration: BoxDecoration(
                        color: const Color(0xFF10B981).withOpacity(0.18),
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: const Icon(Icons.add_business_rounded, color: Color(0xFF10B981), size: 22),
                    ),
                    const SizedBox(width: 12),
                    const Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            '+ Добавить новый товар',
                            style: TextStyle(color: Colors.white, fontSize: 14, fontWeight: FontWeight.bold),
                          ),
                          SizedBox(height: 2),
                          Text(
                            'Штрихкод, весовой (кг) или внутренний артикул с фото',
                            style: TextStyle(color: Colors.white54, fontSize: 11),
                          ),
                        ],
                      ),
                    ),
                    const Icon(Icons.arrow_forward_ios_rounded, color: Colors.white38, size: 14),
                  ],
                ),
              ),
            ),

            const SizedBox(height: 10),

            // Кнопка быстрого добавления и сжатия фото к товарам
            InkWell(
              borderRadius: BorderRadius.circular(16),
              onTap: () {
                Navigator.push(
                  context,
                  MaterialPageRoute(builder: (_) => const ProductPhotoManagerScreen()),
                ).then((_) => _loadData());
              },
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    colors: [
                      const Color(0xFF1E293B),
                      const Color(0xFF0F172A).withOpacity(0.9),
                    ],
                  ),
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(color: const Color(0xFF0284C7).withOpacity(0.4)),
                ),
                child: Row(
                  children: [
                    Container(
                      padding: const EdgeInsets.all(10),
                      decoration: BoxDecoration(
                        color: const Color(0xFF0284C7).withOpacity(0.18),
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: const Icon(Icons.add_a_photo_rounded, color: Color(0xFF38BDF8), size: 22),
                    ),
                    const SizedBox(width: 12),
                    const Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            '📸 Добавить фото к товарам',
                            style: TextStyle(color: Colors.white, fontSize: 14, fontWeight: FontWeight.bold),
                          ),
                          SizedBox(height: 2),
                          Text(
                            'Поиск по штрихкоду/названию, авто-сжатие без потери качества',
                            style: TextStyle(color: Colors.white54, fontSize: 11),
                          ),
                        ],
                      ),
                    ),
                    const Icon(Icons.arrow_forward_ios_rounded, color: Colors.white38, size: 14),
                  ],
                ),
              ),
            ),

            const SizedBox(height: 18),

            // 2. Статистика смены
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: const Color(0xFF1E293B),
                borderRadius: BorderRadius.circular(16),
                border: Border.all(color: Colors.white.withOpacity(0.05)),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('ИТОГИ ПРИЁМКИ (СЕГОДНЯ)', style: TextStyle(color: Colors.white54, fontSize: 11, fontWeight: FontWeight.bold, letterSpacing: 1.1)),
                  const SizedBox(height: 12),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      _statItem('Накладных', '${_recentInvoices.length} шт', Icons.receipt_long),
                      _statItem('Товаров', '$totalItemsToday поз.', Icons.inventory_2_outlined),
                      _statItem('Сумма', '${totalSumToday.toStringAsFixed(0)} TJS', Icons.account_balance_wallet_outlined),
                    ],
                  ),
                ],
              ),
            ),

            const SizedBox(height: 22),

            // 3. Заголовок списка накладных
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                const Text('Журнал накладных', style: TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.bold)),
                Row(
                  children: [
                    Text(
                      _hasActiveFilters
                          ? '${_filteredInvoices.length} из ${_recentInvoices.length} накл.'
                          : '${_recentInvoices.length} документов',
                      style: TextStyle(
                        color: _hasActiveFilters ? const Color(0xFF10B981) : Colors.white54,
                        fontSize: 12,
                        fontWeight: _hasActiveFilters ? FontWeight.bold : FontWeight.normal,
                      ),
                    ),
                    if (_recentInvoices.isNotEmpty) ...[
                      const SizedBox(width: 8),
                      IconButton(
                        icon: const Icon(Icons.delete_sweep_outlined, color: Colors.redAccent, size: 20),
                        tooltip: 'Очистить весь журнал',
                        padding: EdgeInsets.zero,
                        constraints: const BoxConstraints(),
                        onPressed: _confirmClearAllInvoices,
                      ),
                    ],
                  ],
                ),
              ],
            ),
            const SizedBox(height: 10),

            // Поле быстрого поиска и фильтры
            if (_recentInvoices.isNotEmpty) ...[
              TextField(
                controller: _searchCtrl,
                style: const TextStyle(color: Colors.white, fontSize: 14),
                decoration: InputDecoration(
                  filled: true,
                  fillColor: const Color(0xFF1E293B),
                  hintText: 'Поиск по номеру накладной, поставщику, сумме...',
                  hintStyle: const TextStyle(color: Colors.white38, fontSize: 13),
                  prefixIcon: const Icon(Icons.search_rounded, color: Color(0xFF10B981), size: 20),
                  suffixIcon: _searchQuery.isNotEmpty
                      ? IconButton(
                          icon: const Icon(Icons.clear_rounded, color: Colors.white54, size: 18),
                          onPressed: () {
                            _searchCtrl.clear();
                            setState(() => _searchQuery = '');
                          },
                        )
                      : null,
                  contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                    borderSide: BorderSide(color: Colors.white.withOpacity(0.08)),
                  ),
                  enabledBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                    borderSide: BorderSide(color: Colors.white.withOpacity(0.08)),
                  ),
                  focusedBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                    borderSide: const BorderSide(color: Color(0xFF10B981), width: 1.2),
                  ),
                ),
              ),
              const SizedBox(height: 10),

              // Полоса быстрых фильтров (Контрагенты, Даты, Суммы, Сброс)
              SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: Row(
                  children: [
                    // Фильтр по Контрагенту
                    InkWell(
                      onTap: _showSupplierFilterPicker,
                      borderRadius: BorderRadius.circular(10),
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                        decoration: BoxDecoration(
                          color: _selectedSupplierFilter != null ? const Color(0xFF10B981).withOpacity(0.2) : const Color(0xFF1E293B),
                          borderRadius: BorderRadius.circular(10),
                          border: Border.all(
                            color: _selectedSupplierFilter != null ? const Color(0xFF10B981) : Colors.white12,
                          ),
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(Icons.person_outline_rounded, size: 15, color: _selectedSupplierFilter != null ? const Color(0xFF10B981) : Colors.white70),
                            const SizedBox(width: 5),
                            Text(
                              _selectedSupplierFilter != null ? _selectedSupplierFilter! : 'Контрагент',
                              style: TextStyle(
                                color: _selectedSupplierFilter != null ? const Color(0xFF10B981) : Colors.white70,
                                fontSize: 12,
                                fontWeight: _selectedSupplierFilter != null ? FontWeight.bold : FontWeight.normal,
                              ),
                            ),
                            const SizedBox(width: 4),
                            Icon(Icons.arrow_drop_down, size: 16, color: _selectedSupplierFilter != null ? const Color(0xFF10B981) : Colors.white54),
                          ],
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),

                    // Фильтр по Дате
                    InkWell(
                      onTap: _showDateFilterPicker,
                      borderRadius: BorderRadius.circular(10),
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                        decoration: BoxDecoration(
                          color: _dateFilterType != 'all' ? const Color(0xFF38BDF8).withOpacity(0.2) : const Color(0xFF1E293B),
                          borderRadius: BorderRadius.circular(10),
                          border: Border.all(
                            color: _dateFilterType != 'all' ? const Color(0xFF38BDF8) : Colors.white12,
                          ),
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(Icons.calendar_today_rounded, size: 13, color: _dateFilterType != 'all' ? const Color(0xFF38BDF8) : Colors.white70),
                            const SizedBox(width: 5),
                            Text(
                              _dateFilterType == 'today'
                                  ? 'Сегодня'
                                  : (_dateFilterType == 'yesterday'
                                      ? 'Вчера'
                                      : (_dateFilterType == 'week'
                                          ? '7 дней'
                                          : (_dateFilterType == 'month'
                                              ? '30 дней'
                                              : (_dateFilterType == 'custom' && _customDateRange != null
                                                  ? '${DateFormat("dd.MM").format(_customDateRange!.start)} - ${DateFormat("dd.MM").format(_customDateRange!.end)}'
                                                  : 'Дата')))),
                              style: TextStyle(
                                color: _dateFilterType != 'all' ? const Color(0xFF38BDF8) : Colors.white70,
                                fontSize: 12,
                                fontWeight: _dateFilterType != 'all' ? FontWeight.bold : FontWeight.normal,
                              ),
                            ),
                            const SizedBox(width: 4),
                            Icon(Icons.arrow_drop_down, size: 16, color: _dateFilterType != 'all' ? const Color(0xFF38BDF8) : Colors.white54),
                          ],
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),

                    // Фильтр по Сумме
                    InkWell(
                      onTap: _showAmountFilterPicker,
                      borderRadius: BorderRadius.circular(10),
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                        decoration: BoxDecoration(
                          color: _amountFilterType != 'all' ? const Color(0xFFF59E0B).withOpacity(0.2) : const Color(0xFF1E293B),
                          borderRadius: BorderRadius.circular(10),
                          border: Border.all(
                            color: _amountFilterType != 'all' ? const Color(0xFFF59E0B) : Colors.white12,
                          ),
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(Icons.payments_outlined, size: 14, color: _amountFilterType != 'all' ? const Color(0xFFF59E0B) : Colors.white70),
                            const SizedBox(width: 5),
                            Text(
                              _amountFilterType == 'under500'
                                  ? '< 500 TJS'
                                  : (_amountFilterType == '500_2000'
                                      ? '500 - 2 000 TJS'
                                      : (_amountFilterType == '2000_10000'
                                          ? '2 000 - 10 000 TJS'
                                          : (_amountFilterType == 'over10000' ? '> 10 000 TJS' : 'Сумма'))),
                              style: TextStyle(
                                color: _amountFilterType != 'all' ? const Color(0xFFF59E0B) : Colors.white70,
                                fontSize: 12,
                                fontWeight: _amountFilterType != 'all' ? FontWeight.bold : FontWeight.normal,
                              ),
                            ),
                            const SizedBox(width: 4),
                            Icon(Icons.arrow_drop_down, size: 16, color: _amountFilterType != 'all' ? const Color(0xFFF59E0B) : Colors.white54),
                          ],
                        ),
                      ),
                    ),

                    // Кнопка сброса всех фильтров
                    if (_hasActiveFilters) ...[
                      const SizedBox(width: 8),
                      InkWell(
                        onTap: _resetAllFilters,
                        borderRadius: BorderRadius.circular(10),
                        child: Container(
                          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                          decoration: BoxDecoration(
                            color: Colors.redAccent.withOpacity(0.18),
                            borderRadius: BorderRadius.circular(10),
                            border: Border.all(color: Colors.redAccent.withOpacity(0.5)),
                          ),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              const Icon(Icons.close_rounded, size: 13, color: Colors.redAccent),
                              const SizedBox(width: 4),
                              Text('Сбросить (${_activeFiltersCount})', style: const TextStyle(color: Colors.redAccent, fontSize: 11, fontWeight: FontWeight.bold)),
                            ],
                          ),
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              const SizedBox(height: 10),

              if (_hasActiveFilters)
                Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: Builder(
                    builder: (context) {
                      final filtered = _filteredInvoices;
                      final sum = filtered.fold<double>(0.0, (s, d) => s + (d.totalAmount > 0 ? d.totalAmount : d.calculatedTotal));
                      return Row(
                        children: [
                          const Icon(Icons.filter_alt_outlined, size: 13, color: Color(0xFF10B981)),
                          const SizedBox(width: 4),
                          Text(
                            'Найдено: ${filtered.length} документов на ${sum.toStringAsFixed(2)} TJS',
                            style: const TextStyle(color: Color(0xFF10B981), fontSize: 11, fontWeight: FontWeight.bold),
                          ),
                        ],
                      );
                    },
                  ),
                ),
            ],
            const SizedBox(height: 6),

            // 4. Список недавних накладных
            if (_isLoading)
              const Center(child: Padding(padding: EdgeInsets.all(32), child: CircularProgressIndicator(color: Color(0xFF10B981))))
            else if (_recentInvoices.isEmpty)
              _emptyState()
            else if (_filteredInvoices.isEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 36, horizontal: 16),
                child: Center(
                  child: Column(
                    children: [
                      const Icon(Icons.search_off_rounded, size: 48, color: Colors.white24),
                      const SizedBox(height: 12),
                      const Text('По выбранным фильтрам накладных не найдено', style: TextStyle(color: Colors.white70, fontSize: 14)),
                      const SizedBox(height: 12),
                      ElevatedButton.icon(
                        style: ElevatedButton.styleFrom(
                          backgroundColor: const Color(0xFF1E293B),
                          foregroundColor: const Color(0xFF10B981),
                          side: const BorderSide(color: Color(0xFF10B981), width: 1),
                        ),
                        icon: const Icon(Icons.refresh_rounded, size: 16),
                        label: const Text('Сбросить фильтры поиска'),
                        onPressed: _resetAllFilters,
                      ),
                    ],
                  ),
                ),
              )
            else
              Builder(
                builder: (context) {
                  final list = _filteredInvoices;
                  return ListView.builder(
                    shrinkWrap: true,
                    physics: const NeverScrollableScrollPhysics(),
                    itemCount: list.length,
                    itemBuilder: (ctx, index) {
                      final doc = list[index];
                      return _invoiceCard(doc);
                    },
                  );
                },
              ),
          ],
        ),
      ),
    ),
  );
}

  Future<bool> _confirmDeleteInvoice(InvoiceDocument doc) async {
    final result = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF1E293B),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: const Row(
          children: [
            Icon(Icons.delete_forever_rounded, color: Colors.redAccent, size: 24),
            SizedBox(width: 8),
            Text('Удалить накладную?', style: TextStyle(color: Colors.white, fontSize: 16)),
          ],
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Вы действительно хотите удалить накладную №${doc.invoiceNumber} поставщика "${doc.supplierName}" на сумму ${doc.totalAmount.toStringAsFixed(2)} TJS?',
              style: const TextStyle(color: Colors.white70, fontSize: 13),
            ),
            const SizedBox(height: 10),
            const Text(
              'Документ будет безвозвратно удален из локального журнала терминала.',
              style: TextStyle(color: Colors.white38, fontSize: 11),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Отмена', style: TextStyle(color: Colors.white60)),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: Colors.redAccent),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Удалить', style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
          ),
        ],
      ),
    );

    if (result == true) {
      await _storage.deleteInvoice(doc.id);
      await _loadData();
      if (mounted) {
        TopNotification.showSuccess(context, 'Накладная №${doc.invoiceNumber} удалена из журнала');
      }
      return true;
    }
    return false;
  }

  Future<void> _confirmClearAllInvoices() async {
    final result = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF1E293B),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: const Row(
          children: [
            Icon(Icons.warning_amber_rounded, color: Colors.orangeAccent, size: 24),
            SizedBox(width: 8),
            Text('Очистить весь журнал?', style: TextStyle(color: Colors.white, fontSize: 16)),
          ],
        ),
        content: Text(
          'Удалить все ${_recentInvoices.length} накладных из журнала терминала? Это действие нельзя отменить.',
          style: const TextStyle(color: Colors.white70, fontSize: 13),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Отмена', style: TextStyle(color: Colors.white60)),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: Colors.redAccent),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Очистить всё', style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
          ),
        ],
      ),
    );

    if (result == true) {
      await _storage.clearAllInvoices();
      await _loadData();
      if (mounted) {
        TopNotification.showSuccess(context, 'Журнал накладных очищен');
      }
    }
  }

  Widget _actionCard({
    required String title,
    required String subtitle,
    required IconData icon,
    required Color color,
    required VoidCallback onTap,
  }) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(16),
      child: Container(
        padding: const EdgeInsets.all(16),
        height: 130,
        decoration: BoxDecoration(
          gradient: LinearGradient(
            colors: [color.withOpacity(0.85), color],
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
          ),
          borderRadius: BorderRadius.circular(16),
          boxShadow: [
            BoxShadow(
              color: color.withOpacity(0.3),
              blurRadius: 10,
              offset: const Offset(0, 4),
            ),
          ],
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Container(
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: Colors.black.withOpacity(0.2),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Icon(icon, color: Colors.white, size: 24),
            ),
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: const TextStyle(color: Colors.white, fontSize: 15, fontWeight: FontWeight.bold, height: 1.2)),
                const SizedBox(height: 2),
                Text(subtitle, style: const TextStyle(color: Colors.white70, fontSize: 11)),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _statItem(String label, String value, IconData icon) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Icon(icon, color: const Color(0xFF10B981), size: 14),
            const SizedBox(width: 4),
            Text(label, style: const TextStyle(color: Colors.white54, fontSize: 11)),
          ],
        ),
        const SizedBox(height: 4),
        Text(value, style: const TextStyle(color: Colors.white, fontSize: 15, fontWeight: FontWeight.bold)),
      ],
    );
  }

  Widget _invoiceCard(InvoiceDocument doc) {
    final dateFormat = DateFormat('dd.MM.yyyy');

    Color statusColor;
    String statusText;

    if (doc.isSynchronized) {
      statusColor = const Color(0xFF10B981);
      statusText = 'Оприходовано';
    } else if (doc.unmatchedCount > 0) {
      statusColor = const Color(0xFFF59E0B);
      statusText = 'Требует привязки';
    } else {
      statusColor = const Color(0xFF3B82F6);
      statusText = 'Готов к отправке';
    }

    return Dismissible(
      key: Key(doc.id),
      direction: DismissDirection.endToStart,
      confirmDismiss: (_) => _confirmDeleteInvoice(doc),
      background: Container(
        margin: const EdgeInsets.only(bottom: 10),
        alignment: Alignment.centerRight,
        padding: const EdgeInsets.symmetric(horizontal: 20),
        decoration: BoxDecoration(
          color: Colors.redAccent.withOpacity(0.85),
          borderRadius: BorderRadius.circular(12),
        ),
        child: const Row(
          mainAxisAlignment: MainAxisAlignment.end,
          children: [
            Icon(Icons.delete_outline_rounded, color: Colors.white, size: 24),
            SizedBox(width: 8),
            Text('Удалить', style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
          ],
        ),
      ),
      child: Card(
        color: const Color(0xFF1E293B),
        margin: const EdgeInsets.only(bottom: 10),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        child: ListTile(
          contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          onTap: () {
            Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => InvoiceReviewScreen(document: doc)),
            ).then((_) => _loadData());
          },
          leading: InkWell(
            onTap: doc.pagePhotos.isNotEmpty
                ? () => DocumentPhotoViewerDialog.show(
                      context,
                      photoPaths: doc.pagePhotos,
                      invoiceNumber: doc.invoiceNumber,
                      supplierName: doc.supplierName,
                    )
                : null,
            borderRadius: BorderRadius.circular(10),
            child: Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: statusColor.withOpacity(0.15),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Icon(
                doc.pagePhotos.isNotEmpty ? Icons.photo_library_outlined : Icons.description_outlined,
                color: statusColor,
              ),
            ),
          ),
          title: Row(
            children: [
              Expanded(
                child: Text(
                  doc.supplierName,
                  style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 14),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              if (doc.supplierId != null) ...[
                const SizedBox(width: 4),
                const Icon(Icons.verified_rounded, color: Color(0xFF10B981), size: 14),
              ],
            ],
          ),
          subtitle: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const SizedBox(height: 5),
              Row(
                children: [
                  InkWell(
                    onTap: doc.pagePhotos.isNotEmpty
                        ? () => DocumentPhotoViewerDialog.show(
                              context,
                              photoPaths: doc.pagePhotos,
                              invoiceNumber: doc.invoiceNumber,
                              supplierName: doc.supplierName,
                            )
                        : null,
                    borderRadius: BorderRadius.circular(6),
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                      decoration: BoxDecoration(
                        color: const Color(0xFF3B82F6).withOpacity(0.2),
                        borderRadius: BorderRadius.circular(6),
                        border: Border.all(color: const Color(0xFF3B82F6).withOpacity(0.4), width: 0.8),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const Icon(Icons.description_rounded, size: 12, color: Color(0xFF60A5FA)),
                          const SizedBox(width: 4),
                          Text(
                            '№${doc.invoiceNumber}',
                            style: const TextStyle(color: Color(0xFF93C5FD), fontSize: 12, fontWeight: FontWeight.bold),
                          ),
                          if (doc.incomingNumber.isNotEmpty && doc.incomingNumber != doc.invoiceNumber) ...[
                            const SizedBox(width: 6),
                            Container(
                              padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
                              decoration: BoxDecoration(
                                color: Colors.white.withOpacity(0.08),
                                borderRadius: BorderRadius.circular(4),
                              ),
                              child: Text(
                                'Вх: ${doc.incomingNumber}',
                                style: const TextStyle(color: Colors.white70, fontSize: 10, fontWeight: FontWeight.w500),
                              ),
                            ),
                          ],
                          if (doc.pagePhotos.isNotEmpty) ...[
                            const SizedBox(width: 4),
                            Container(
                              padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
                              decoration: BoxDecoration(
                                color: const Color(0xFF10B981).withOpacity(0.3),
                                borderRadius: BorderRadius.circular(4),
                              ),
                              child: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  const Icon(Icons.image_outlined, size: 10, color: Color(0xFF6EE7B7)),
                                  const SizedBox(width: 2),
                                  Text(
                                    '${doc.pagePhotos.length} ф.',
                                    style: const TextStyle(color: Color(0xFF6EE7B7), fontSize: 9, fontWeight: FontWeight.bold),
                                  ),
                                ],
                              ),
                            ),
                          ],
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      '${dateFormat.format(doc.invoiceDate)} • ${doc.items.length} поз.',
                      style: const TextStyle(color: Colors.white54, fontSize: 11),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 6),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                decoration: BoxDecoration(
                  color: statusColor.withOpacity(0.2),
                  borderRadius: BorderRadius.circular(4),
                ),
                child: Text(statusText, style: TextStyle(color: statusColor, fontSize: 10, fontWeight: FontWeight.bold)),
              ),
            ],
          ),
          trailing: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                '${doc.totalAmount.toStringAsFixed(2)} TJS',
                style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 13),
              ),
              const SizedBox(width: 4),
              IconButton(
                icon: const Icon(Icons.delete_outline_rounded, color: Colors.white38, size: 20),
                tooltip: 'Удалить накладную',
                onPressed: () => _confirmDeleteInvoice(doc),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _emptyState() {
    return Container(
      padding: const EdgeInsets.all(32),
      decoration: BoxDecoration(
        color: const Color(0xFF1E293B),
        borderRadius: BorderRadius.circular(16),
      ),
      child: Center(
        child: Column(
          children: [
            Icon(Icons.inventory_rounded, color: Colors.white.withOpacity(0.2), size: 48),
            const SizedBox(height: 12),
            const Text('Нет принятых накладных', style: TextStyle(color: Colors.white70, fontSize: 14, fontWeight: FontWeight.bold)),
            const SizedBox(height: 6),
            const Text('Сфотографируйте бумажную накладную или чек экспедитора для начала приёмки',
                textAlign: TextAlign.center, style: TextStyle(color: Colors.white38, fontSize: 12)),
          ],
        ),
      ),
    );
  }
}
