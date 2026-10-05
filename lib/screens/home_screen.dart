import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:intl/intl.dart';
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
  String? _storeName = 'Магазин Gusar #1';

  @override
  void initState() {
    super.initState();
    _loadData();
    _checkUpdates();
  }

  Future<void> _loadData() async {
    setState(() => _isLoading = true);
    final localDocs = await _storage.getLocalInvoices();
    setState(() {
      _recentInvoices = localDocs;
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

  Future<void> _checkUpdates() async {
    final update = await _updater.checkForUpdate();
    if (update != null && mounted) {
      showDialog(
        context: context,
        builder: (ctx) => AlertDialog(
          backgroundColor: const Color(0xFF1E293B),
          title: Text('🚀 Доступно обновление ${update.version}', style: const TextStyle(color: Colors.white)),
          content: Text(update.releaseNotes, style: const TextStyle(color: Colors.white70)),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('Позже', style: TextStyle(color: Colors.white54)),
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
    }
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
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('GUSAR SCANNER', style: TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.bold)),
                Text(_storeName!, style: const TextStyle(color: Colors.white54, fontSize: 12)),
              ],
            ),
          ],
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh, color: Colors.white70),
            onPressed: _loadData,
          ),
          IconButton(
            icon: const Icon(Icons.settings_outlined, color: Colors.white70),
            onPressed: () {
              Navigator.push(
                context,
                MaterialPageRoute(builder: (_) => const SettingsScreen()),
              ).then((_) => _loadData());
            },
          ),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: _loadData,
        color: const Color(0xFF10B981),
        backgroundColor: const Color(0xFF1E293B),
        child: SingleChildScrollView(
          physics: const AlwaysScrollableScrollPhysics(),
          padding: const EdgeInsets.all(16),
          children: [
            // 1. Главные кнопки действия
            Row(
              children: [
                Expanded(
                  child: _actionCard(
                    title: 'Сканировать\nнакладную',
                    subtitle: 'Камера / Чек',
                    icon: Icons.camera_alt_rounded,
                    color: const Color(0xFF10B981),
                    onTap: () {
                      Navigator.push(
                        context,
                        MaterialPageRoute(builder: (_) => const CameraScannerScreen()),
                      ).then((_) => _loadData());
                    },
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
