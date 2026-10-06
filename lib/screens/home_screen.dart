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

  @override
  void initState() {
    super.initState();
    _loadData();
    _checkUpdates();
  }

  Future<void> _loadData() async {
    setState(() => _isLoading = true);
    final prefs = await SharedPreferences.getInstance();
    final localDocs = await _storage.getLocalInvoices();
    String storeName = prefs.getString('store_name') ?? 'База gusar.tj (Основной склад)';
    if (storeName.contains('Центральный') ||
        storeName.contains('Сино') ||
        storeName.contains('Фирдавси') ||
        storeName.contains('Шохмансур')) {
      storeName = 'База gusar.tj (Основной склад)';
      await prefs.setString('store_name', storeName);
    }
    final loggedUser = prefs.getString('logged_username');
    final isAuth = prefs.getBool('is_authenticated') ?? false;

    setState(() {
      _recentInvoices = localDocs;
      _storeName = storeName;
      _loggedUser = loggedUser;
      _isAuthenticated = isAuth;
      _isLoading = false;
    });

    // Фоновое обновление каталога с gusar.tj
    try {
      final products = await _api.getProducts();
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
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('У вас установлена самая актуальная версия!'),
          backgroundColor: Color(0xFF10B981),
        ),
      );
    }
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
                  const Text('Gusar Scanner (tj.gusar)', style: TextStyle(color: Colors.white54, fontSize: 12)),
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
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(
                    content: Text('Обновление отложено. Вы всегда можете запустить его из верхнего меню.'),
                    backgroundColor: Color(0xFF334155),
                    duration: Duration(seconds: 3),
                  ),
                );
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
                onTap: () {
                  Navigator.push(
                    context,
                    MaterialPageRoute(builder: (_) => const SettingsScreen()),
                  ).then((_) {
                    _loadData();
                    _checkUpdates();
                  });
                },
                borderRadius: BorderRadius.circular(8),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        const Text('GUSAR SCANNER', style: TextStyle(color: Colors.white, fontSize: 15, fontWeight: FontWeight.bold)),
                        const SizedBox(width: 6),
                        Container(
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
                      ],
                    ),
                    Text(
                      _storeName ?? 'Магазин Gusar #1 (Центральный)',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(color: Colors.white54, fontSize: 11),
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
                Text('${_recentInvoices.length} документов', style: const TextStyle(color: Colors.white54, fontSize: 12)),
              ],
            ),
            const SizedBox(height: 12),

            // 4. Список недавних накладных
            if (_isLoading)
              const Center(child: Padding(padding: EdgeInsets.all(32), child: CircularProgressIndicator(color: Color(0xFF10B981))))
            else if (_recentInvoices.isEmpty)
              _emptyState()
            else
              ListView.builder(
                shrinkWrap: true,
                physics: const NeverScrollableScrollPhysics(),
                itemCount: _recentInvoices.length,
                itemBuilder: (ctx, index) {
                  final doc = _recentInvoices[index];
                  return _invoiceCard(doc);
                },
              ),
          ],
          ),
        ),
      ),
    );
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

    return Card(
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
        leading: Container(
          padding: const EdgeInsets.all(10),
          decoration: BoxDecoration(
            color: statusColor.withOpacity(0.15),
            borderRadius: BorderRadius.circular(10),
          ),
          child: Icon(Icons.description_outlined, color: statusColor),
        ),
        title: Text(
          doc.supplierName,
          style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 14),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        subtitle: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const SizedBox(height: 4),
            Text('№${doc.invoiceNumber} от ${dateFormat.format(doc.invoiceDate)} • ${doc.items.length} поз.',
                style: const TextStyle(color: Colors.white54, fontSize: 12)),
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
        trailing: Text(
          '${doc.totalAmount.toStringAsFixed(2)} TJS',
          style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 13),
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
