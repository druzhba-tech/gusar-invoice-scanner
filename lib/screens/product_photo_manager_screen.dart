import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';
import 'package:intl/intl.dart';
import 'package:path_provider/path_provider.dart';

import '../models/product.dart';
import '../services/api_service.dart';
import '../services/local_storage_service.dart';
import '../services/matching_service.dart';
import '../utils/image_utils.dart';
import '../utils/top_notification.dart';
import '../widgets/barcode_scanner_dialog.dart';
import '../widgets/product_image_widget.dart';
import 'add_product_screen.dart';

typedef LinkedProductsScreen = ProductPhotoManagerScreen;

// Модель отображения связи между товаром из приложения (из накладной/чека) и товаром из базы gusar.tj
class LinkedProductRecord {
  final String id;
  final String rawName; // Название из накладной / чека в приложении
  final String supplierName; // Поставщик
  final String invoiceNumber; // Номер накладной
  final DateTime? date; // Дата накладной
  final double? invoicePrice; // Цена закупки в накладной
  final double? quantity; // Количество в накладной
  final String? unit; // Единица измерения
  final Product databaseProduct; // Привязанный товар из базы gusar.tj
  final double confidence; // Точность сопоставления
  final String invoiceId; // ID накладной

  LinkedProductRecord({
    required this.id,
    required this.rawName,
    required this.supplierName,
    required this.invoiceNumber,
    this.date,
    this.invoicePrice,
    this.quantity,
    this.unit,
    required this.databaseProduct,
    this.confidence = 1.0,
    required this.invoiceId,
  });
}

class ProductPhotoManagerScreen extends StatefulWidget {
  const ProductPhotoManagerScreen({super.key});

  @override
  State<ProductPhotoManagerScreen> createState() => _ProductPhotoManagerScreenState();
}

class _ProductPhotoManagerScreenState extends State<ProductPhotoManagerScreen> {
  final ApiService _api = ApiService();
  final LocalStorageService _storage = LocalStorageService();
  final MatchingService _matcher = MatchingService();

  final TextEditingController _searchCtrl = TextEditingController();
  final FocusNode _searchFocusNode = FocusNode();

  List<Product> _allProducts = [];
  List<LinkedProductRecord> _allLinkedRecords = [];
  List<LinkedProductRecord> _filteredLinkedRecords = [];
  List<Product> _filteredCatalogProducts = [];

  bool _isLoading = true;
  // 0 = Связи из накладных приложения (Связанные товары), 1 = Весь каталог базы gusar.tj
  int _selectedTab = 0;

  @override
  void initState() {
    super.initState();
    _loadAllData();
  }

  @override
  void dispose() {
    _searchCtrl.dispose();
    _searchFocusNode.dispose();
    super.dispose();
  }

  Future<void> _loadAllData({bool forceRefresh = false}) async {
    setState(() => _isLoading = true);
    try {
      await _matcher.init();
      final prods = await _api.getProducts(forceRefresh: forceRefresh);
      final Map<int, Product> prodMap = {for (var p in prods) p.id: p};

      final invoices = await _storage.getLocalInvoices();
      final aliases = _matcher.aliasDictionary;

      final List<LinkedProductRecord> records = [];
      final Set<String> seenKeys = {};

      // 1. Собираем связки товаров из накладных, добавленных через приложение
      for (final doc in invoices) {
        for (final item in doc.items) {
          if (item.matchedProductId != null && item.matchedProductId! > 0) {
            final key = '${doc.supplierName.trim().toLowerCase()}::${item.rawName.trim().toLowerCase()}';
            if (seenKeys.contains(key)) continue;
            seenKeys.add(key);

            final dbProduct = prodMap[item.matchedProductId] ??
                Product(
                  id: item.matchedProductId!,
                  storeId: doc.storeId,
                  name: item.matchedProductName ?? 'Товар #${item.matchedProductId}',
                  price: item.currentRetailPrice ?? 0.0,
                  costPrice: item.lastBuyPrice ?? (item.price > 0 ? item.price : 0.0),
                  barcode: item.matchedBarcode,
                );

            records.add(LinkedProductRecord(
              id: '${doc.id}_${item.id}',
              rawName: item.rawName,
              supplierName: doc.supplierName,
              invoiceNumber: doc.invoiceNumber.isNotEmpty ? doc.invoiceNumber : 'б/н',
              date: doc.invoiceDate,
              invoicePrice: item.price,
              quantity: item.quantity,
              unit: item.unit,
              databaseProduct: dbProduct,
              confidence: item.matchConfidence,
              invoiceId: doc.id,
            ));
          }
        }
      }

      // 2. Дополняем связками из постоянной памяти сопоставлений matcher'а
      for (final entry in aliases.entries) {
        final fullKey = entry.key;
        final pId = entry.value;
        if (pId <= 0) continue;

        String supName = 'Общий поставщик';
        String rawName = fullKey;
        if (fullKey.startsWith('global::')) {
          rawName = fullKey.substring(8);
        } else if (fullKey.contains('::')) {
          final parts = fullKey.split('::');
          supName = parts[0];
          rawName = parts.sublist(1).join('::');
        }

        final checkKey = '${supName.trim().toLowerCase()}::${rawName.trim().toLowerCase()}';
        if (seenKeys.contains(checkKey)) continue;
        seenKeys.add(checkKey);

        final dbProd = prodMap[pId];
        if (dbProd != null) {
          records.add(LinkedProductRecord(
            id: 'alias_$fullKey',
            rawName: rawName,
            supplierName: supName,
            invoiceNumber: 'Память привязок',
            databaseProduct: dbProd,
            confidence: 1.0,
            invoiceId: '',
          ));
        }
      }

      if (mounted) {
        setState(() {
          _allProducts = prods;
          _allLinkedRecords = records;
          _isLoading = false;
        });
        _applyFilter();
      }
    } catch (e) {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  void _applyFilter() {
    final query = _searchCtrl.text.trim().toLowerCase();
    setState(() {
      // Фильтрация связок
      _filteredLinkedRecords = _allLinkedRecords.where((r) {
        if (query.isEmpty) return true;
        final matchRaw = r.rawName.toLowerCase().contains(query);
        final matchSup = r.supplierName.toLowerCase().contains(query);
        final matchInv = r.invoiceNumber.toLowerCase().contains(query);
        final matchDbName = r.databaseProduct.name.toLowerCase().contains(query);
        final matchDbBarcode = r.databaseProduct.barcode != null && r.databaseProduct.barcode!.contains(query);
        return matchRaw || matchSup || matchInv || matchDbName || matchDbBarcode;
      }).toList();

      // Фильтрация полного каталога
      _filteredCatalogProducts = _allProducts.where((p) {
        if (query.isEmpty) return true;
        final matchName = p.name.toLowerCase().contains(query);
        final matchBarcode = p.barcode != null && p.barcode!.contains(query);
        final matchCat = p.category != null && p.category!.toLowerCase().contains(query);
        return matchName || matchBarcode || matchCat;
      }).toList();
    });
  }

  // Очистка ВСЕХ связанных товаров по запросу пользователя
  Future<void> _confirmClearAllLinks() async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF1E293B),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: const Row(
          children: [
            Icon(Icons.delete_sweep_rounded, color: Colors.redAccent, size: 24),
            SizedBox(width: 10),
            Expanded(
              child: Text(
                'Очистить все связи?',
                style: TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.bold),
              ),
            ),
          ],
        ),
        content: const Text(
          'Все сохранённые привязки между товарами из накладных/чеков и базой gusar.tj будут полностью удалены.\n\nВы сможете привязать товары заново при проверке накладных.',
          style: TextStyle(color: Colors.white70, fontSize: 13, height: 1.4),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Отмена', style: TextStyle(color: Colors.white60)),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.redAccent,
              foregroundColor: Colors.white,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
            ),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Очистить всё', style: TextStyle(fontWeight: FontWeight.bold)),
          ),
        ],
      ),
    );

    if (confirm == true) {
      setState(() => _isLoading = true);
      await _matcher.clearAllAliases();
      await _storage.clearAllItemMatchesInInvoices();
      await _loadAllData();
      if (mounted) {
        TopNotification.showSuccess(context, 'Все связанные товары успешно очищены!');
      }
    }
  }

  // Отвязка конкретного товара
  Future<void> _unlinkRecord(LinkedProductRecord record) async {
    await _matcher.removeAlias(record.supplierName, record.rawName);
    if (record.invoiceId.isNotEmpty) {
      await _storage.unmatchItemInInvoice(record.invoiceId, record.rawName);
    }
    setState(() {
      _allLinkedRecords.removeWhere((r) => r.id == record.id);
      _applyFilter();
    });
    if (mounted) {
      TopNotification.showInfo(context, 'Связка с "${record.rawName}" удалена');
    }
  }

  // Перепривязка товара из накладной к другому товару из базы gusar.tj
  Future<void> _rematchRecord(LinkedProductRecord record) async {
    final pickedProduct = await showModalBottomSheet<Product>(
      context: context,
      isScrollControlled: true,
      backgroundColor: const Color(0xFF1E293B),
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (ctx) => _ProductPickerSheet(
        allProducts: _allProducts,
        rawName: record.rawName,
      ),
    );

    if (pickedProduct != null) {
      await _matcher.saveAlias(record.supplierName, record.rawName, pickedProduct.id);
      if (record.invoiceId.isNotEmpty) {
        await _storage.rematchItemInInvoice(record.invoiceId, record.rawName, pickedProduct);
      }
      await _loadAllData();
      if (mounted) {
        TopNotification.showSuccess(
          context,
          'Товар "${record.rawName}" привязан к "${pickedProduct.name}"!',
        );
      }
    }
  }

  // Сканирование штрихкода камерой для быстрого поиска
  Future<void> _scanBarcodeForSearch() async {
    final scanned = await BarcodeScannerDialog.scan(context);
    if (scanned != null && scanned.isNotEmpty) {
      _searchCtrl.text = scanned;
      _applyFilter();
    }
    if (mounted) {
      _searchFocusNode.requestFocus();
    }
  }

  // Открытие модального окна редактирования товара базы gusar.tj
  Future<void> _openProductEditorSheet(Product product) async {
    await showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: const Color(0xFF1E293B),
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(24))),
      builder: (ctx) => _ProductEditorSheet(
        product: product,
        onProductUpdated: (updatedProduct) {
          _loadAllData();
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF0F172A), // Slate 900
      appBar: AppBar(
        backgroundColor: const Color(0xFF1E293B),
        elevation: 0,
        title: const Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Связанные товары',
              style: TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.bold),
            ),
            Text(
              'Связи товаров из накладных с базой gusar.tj',
              style: TextStyle(color: Color(0xFF38BDF8), fontSize: 11),
            ),
          ],
        ),
        actions: [
          // Кнопка быстрой очистки всех связей
          IconButton(
            icon: const Icon(Icons.delete_sweep_rounded, color: Colors.redAccent),
            tooltip: 'Очистить все связанные товары',
            onPressed: _confirmClearAllLinks,
          ),
          // Добавление нового товара в базу
          IconButton(
            icon: const Icon(Icons.add_box_rounded, color: Color(0xFF10B981)),
            tooltip: 'Добавить новый товар в базу',
            onPressed: () {
              Navigator.push(
                context,
                MaterialPageRoute(builder: (_) => const AddProductScreen()),
              ).then((created) {
                if (created != null) _loadAllData(forceRefresh: true);
              });
            },
          ),
          // Обновление списка
          IconButton(
            icon: const Icon(Icons.refresh_rounded, color: Colors.white70),
            tooltip: 'Обновить список',
            onPressed: () => _loadAllData(forceRefresh: true),
          ),
        ],
      ),
      body: Column(
        children: [
          // 1. Переключатель вкладок
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
            color: const Color(0xFF1E293B),
            child: Row(
              children: [
                Expanded(
                  child: _buildTabButton(
                    0,
                    'Связи из накладных (${_allLinkedRecords.length})',
                    Icons.link_rounded,
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: _buildTabButton(
                    1,
                    'Каталог базы (${_allProducts.length})',
                    Icons.inventory_2_outlined,
                  ),
                ),
              ],
            ),
          ),

          // 2. Поисковая панель (текст + камера-сканер штрихкода)
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            color: const Color(0xFF1E293B).withOpacity(0.5),
            child: Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _searchCtrl,
                    focusNode: _searchFocusNode,
                    textInputAction: TextInputAction.search,
                    style: const TextStyle(color: Colors.white, fontSize: 14),
                    decoration: InputDecoration(
                      hintText: _selectedTab == 0
                          ? 'Поиск по чеку, товару базы или штрихкоду...'
                          : 'Поиск по каталогу gusar.tj...',
                      hintStyle: const TextStyle(color: Colors.white38, fontSize: 13),
                      prefixIcon: const Icon(Icons.search_rounded, color: Color(0xFF10B981), size: 20),
                      suffixIcon: _searchCtrl.text.isNotEmpty
                          ? IconButton(
                              icon: const Icon(Icons.clear, color: Colors.white54, size: 18),
                              onPressed: () {
                                _searchCtrl.clear();
                                _applyFilter();
                              },
                            )
                          : null,
                      filled: true,
                      fillColor: const Color(0xFF0F172A),
                      contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                      border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide.none),
                    ),
                    onChanged: (_) => _applyFilter(),
                  ),
                ),
                const SizedBox(width: 8),
                ElevatedButton.icon(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFF10B981),
                    padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                  ),
                  onPressed: _scanBarcodeForSearch,
                  icon: const Icon(Icons.qr_code_scanner_rounded, color: Colors.white, size: 18),
                  label: const Text('Скан', style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 13)),
                ),
              ],
            ),
          ),

          // 3. Основной список содержимого
          Expanded(
            child: _isLoading
                ? const Center(child: CircularProgressIndicator(color: Color(0xFF10B981)))
                : _selectedTab == 0
                    ? _buildLinkedRecordsView()
                    : _buildCatalogView(),
          ),
        ],
      ),
    );
  }

  Widget _buildTabButton(int index, String label, IconData icon) {
    final isSelected = _selectedTab == index;
    return InkWell(
      borderRadius: BorderRadius.circular(10),
      onTap: () {
        setState(() => _selectedTab = index);
        _applyFilter();
      },
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 8),
        decoration: BoxDecoration(
          color: isSelected ? const Color(0xFF10B981) : const Color(0xFF0F172A),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: isSelected ? Colors.transparent : Colors.white12),
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(icon, color: isSelected ? Colors.white : Colors.white70, size: 16),
            const SizedBox(width: 6),
            Flexible(
              child: Text(
                label,
                style: TextStyle(
                  color: isSelected ? Colors.white : Colors.white70,
                  fontSize: 12,
                  fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        ),
      ),
    );
  }

  // Представление связок товаров: Товар из накладной приложения ⟷ Товар из базы gusar.tj
  Widget _buildLinkedRecordsView() {
    if (_filteredLinkedRecords.isEmpty) {
      return Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Container(
                padding: const EdgeInsets.all(18),
                decoration: BoxDecoration(
                  color: const Color(0xFF1E293B),
                  shape: BoxShape.circle,
                  border: Border.all(color: Colors.white12),
                ),
                child: const Icon(Icons.link_off_rounded, color: Colors.white38, size: 48),
              ),
              const SizedBox(height: 16),
              const Text(
                'Связанные товары очищены',
                style: TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 8),
              const Text(
                'В данный момент нет сохранённых связок. Когда вы сканируете накладные или связываете позиции в приложении, товары из базы будут наглядно показаны здесь.',
                textAlign: TextAlign.center,
                style: TextStyle(color: Colors.white54, fontSize: 13, height: 1.4),
              ),
              const SizedBox(height: 20),
              ElevatedButton.icon(
                style: ElevatedButton.styleFrom(
                  backgroundColor: const Color(0xFF10B981),
                  foregroundColor: Colors.white,
                  padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                ),
                onPressed: () => Navigator.pop(context),
                icon: const Icon(Icons.arrow_back_rounded, size: 18),
                label: const Text('Вернуться к накладным', style: TextStyle(fontWeight: FontWeight.bold)),
              ),
            ],
          ),
        ),
      );
    }

    final dateFormat = DateFormat('dd.MM.yyyy');

    return RefreshIndicator(
      color: const Color(0xFF10B981),
      backgroundColor: const Color(0xFF1E293B),
      onRefresh: () => _loadAllData(forceRefresh: true),
      child: ListView.builder(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        itemCount: _filteredLinkedRecords.length,
        itemBuilder: (ctx, idx) {
          final rec = _filteredLinkedRecords[idx];
          return _buildLinkedCard(rec, dateFormat);
        },
      ),
    );
  }

  // Карточка связи товара
  Widget _buildLinkedCard(LinkedProductRecord rec, DateFormat dateFormat) {
    final dbProd = rec.databaseProduct;
    final hasPhoto = (dbProd.imageUrl != null && dbProd.imageUrl!.isNotEmpty) ||
        (dbProd.localImagePath != null && File(dbProd.localImagePath!).existsSync());

    return Container(
      margin: const EdgeInsets.only(bottom: 14),
      decoration: BoxDecoration(
        color: const Color(0xFF1E293B),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: const Color(0xFF10B981).withOpacity(0.35)),
      ),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // 1. Товар, добавленный через приложение (из накладной/чека)
            Row(
              children: [
                Container(
                  padding: const EdgeInsets.all(6),
                  decoration: BoxDecoration(
                    color: const Color(0xFF38BDF8).withOpacity(0.15),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: const Icon(Icons.receipt_long_rounded, color: Color(0xFF38BDF8), size: 18),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                        'Товар из накладной в приложении:',
                        style: TextStyle(color: Colors.white54, fontSize: 11, fontWeight: FontWeight.w600),
                      ),
                      Text(
                        rec.rawName,
                        style: const TextStyle(color: Colors.white, fontSize: 14, fontWeight: FontWeight.bold),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
                  ),
                ),
                IconButton(
                  icon: const Icon(Icons.link_off_rounded, color: Colors.redAccent, size: 20),
                  tooltip: 'Отвязать товар',
                  onPressed: () => _unlinkRecord(rec),
                ),
              ],
            ),

            const SizedBox(height: 6),

            // Детали накладной (поставщик, номер, дата, закуп)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
              decoration: BoxDecoration(
                color: const Color(0xFF0F172A),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      '${rec.supplierName} • Накл. №${rec.invoiceNumber}${rec.date != null ? " от " + dateFormat.format(rec.date!) : ""}',
                      style: const TextStyle(color: Colors.white70, fontSize: 11),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  if (rec.invoicePrice != null && rec.invoicePrice! > 0)
                    Text(
                      'Закуп: ${rec.invoicePrice!.toStringAsFixed(2)} TJS',
                      style: const TextStyle(color: Color(0xFF38BDF8), fontSize: 11, fontWeight: FontWeight.bold),
                    ),
                ],
              ),
            ),

            const SizedBox(height: 10),

            // Стрелка связки
            Row(
              children: [
                const Icon(Icons.link_rounded, color: Color(0xFF10B981), size: 16),
                const SizedBox(width: 6),
                const Text(
                  'СВЯЗАН С ТОВАРОМ ИЗ БАЗЫ GUSAR.TJ:',
                  style: TextStyle(color: Color(0xFF10B981), fontSize: 10, fontWeight: FontWeight.bold, letterSpacing: 0.5),
                ),
                const Spacer(),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                  decoration: BoxDecoration(
                    color: const Color(0xFF10B981).withOpacity(0.15),
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: const Text('Связано 100%', style: TextStyle(color: Color(0xFF10B981), fontSize: 10)),
                ),
              ],
            ),

            const SizedBox(height: 8),

            // 2. Карточка связанного товара из базы gusar.tj
            Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: const Color(0xFF0F172A),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: Colors.white12),
              ),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // Превью фото товара из базы с возможностью сфотографировать
                  GestureDetector(
                    onTap: () => _openProductEditorSheet(dbProd),
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(10),
                      child: Container(
                        width: 52,
                        height: 52,
                        color: const Color(0xFF1E293B),
                        child: hasPhoto
                            ? ProductImageWidget(
                                imageUrl: dbProd.imageUrl,
                                localImagePath: dbProd.localImagePath,
                                fit: BoxFit.cover,
                                width: 52,
                                height: 52,
                                placeholder: const Icon(Icons.add_a_photo_outlined, color: Color(0xFF10B981), size: 22),
                              )
                            : const Icon(Icons.add_a_photo_outlined, color: Color(0xFF10B981), size: 22),
                      ),
                    ),
                  ),
                  const SizedBox(width: 10),

                  // Данные товара из базы
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          dbProd.name,
                          style: const TextStyle(color: Colors.white, fontSize: 13, fontWeight: FontWeight.bold),
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                        ),
                        const SizedBox(height: 4),
                        Row(
                          children: [
                            if (dbProd.barcode != null && dbProd.barcode!.isNotEmpty) ...[
                              const Icon(Icons.qr_code, color: Colors.white38, size: 12),
                              const SizedBox(width: 4),
                              Text(dbProd.barcode!, style: const TextStyle(color: Colors.white54, fontSize: 11, fontFamily: 'monospace')),
                              const SizedBox(width: 8),
                            ],
                            Text('ID: ${dbProd.id}', style: const TextStyle(color: Colors.white38, fontSize: 10)),
                          ],
                        ),
                        const SizedBox(height: 4),
                        Row(
                          children: [
                            Text(
                              'Розница: ${dbProd.price.toStringAsFixed(2)} TJS',
                              style: const TextStyle(color: Color(0xFF10B981), fontSize: 12, fontWeight: FontWeight.bold),
                            ),
                            if (dbProd.costPrice > 0) ...[
                              const SizedBox(width: 8),
                              Text(
                                'Себест: ${dbProd.costPrice.toStringAsFixed(2)} TJS',
                                style: const TextStyle(color: Colors.white54, fontSize: 11),
                              ),
                            ],
                          ],
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),

            const SizedBox(height: 10),

            // 3. Кнопки действий прямо на карточке связи
            Row(
              children: [
                Expanded(
                  child: ElevatedButton.icon(
                    style: ElevatedButton.styleFrom(
                      backgroundColor: const Color(0xFF38BDF8).withOpacity(0.15),
                      foregroundColor: const Color(0xFF38BDF8),
                      elevation: 0,
                      padding: const EdgeInsets.symmetric(vertical: 8),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                    ),
                    onPressed: () => _openProductEditorSheet(dbProd),
                    icon: const Icon(Icons.edit_rounded, size: 16),
                    label: const Text('Редактировать товар', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 12)),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: ElevatedButton.icon(
                    style: ElevatedButton.styleFrom(
                      backgroundColor: const Color(0xFF10B981).withOpacity(0.15),
                      foregroundColor: const Color(0xFF10B981),
                      elevation: 0,
                      padding: const EdgeInsets.symmetric(vertical: 8),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                    ),
                    onPressed: () => _rematchRecord(rec),
                    icon: const Icon(Icons.sync_alt_rounded, size: 16),
                    label: const Text('Перепривязать', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 12)),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  // Представление каталога товаров
  Widget _buildCatalogView() {
    if (_filteredCatalogProducts.isEmpty) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(Icons.inventory_2_outlined, color: Colors.white24, size: 54),
            const SizedBox(height: 12),
            Text(
              _searchCtrl.text.isNotEmpty
                  ? 'По запросу "${_searchCtrl.text}" товары не найдены'
                  : 'Каталог пуст',
              style: const TextStyle(color: Colors.white54, fontSize: 14),
            ),
          ],
        ),
      );
    }

    return RefreshIndicator(
      color: const Color(0xFF10B981),
      backgroundColor: const Color(0xFF1E293B),
      onRefresh: () => _loadAllData(forceRefresh: true),
      child: ListView.builder(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        itemCount: _filteredCatalogProducts.length,
        itemBuilder: (ctx, idx) {
          final prod = _filteredCatalogProducts[idx];
          final hasPhoto = (prod.imageUrl != null && prod.imageUrl!.isNotEmpty) ||
              (prod.localImagePath != null && File(prod.localImagePath!).existsSync());

          return Container(
            margin: const EdgeInsets.only(bottom: 10),
            decoration: BoxDecoration(
              color: const Color(0xFF1E293B),
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: hasPhoto ? const Color(0xFF10B981).withOpacity(0.3) : Colors.white12),
            ),
            child: ListTile(
              contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
              onTap: () => _openProductEditorSheet(prod),
              leading: ClipRRect(
                borderRadius: BorderRadius.circular(10),
                child: Container(
                  width: 48,
                  height: 48,
                  color: const Color(0xFF0F172A),
                  child: hasPhoto
                      ? ProductImageWidget(
                          imageUrl: prod.imageUrl,
                          localImagePath: prod.localImagePath,
                          fit: BoxFit.cover,
                          width: 48,
                          height: 48,
                          placeholder: const Icon(Icons.add_a_photo_outlined, color: Color(0xFF10B981), size: 22),
                        )
                      : const Icon(Icons.add_a_photo_outlined, color: Color(0xFF10B981), size: 22),
                ),
              ),
              title: Text(
                prod.name,
                style: const TextStyle(color: Colors.white, fontSize: 14, fontWeight: FontWeight.bold),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              subtitle: Row(
                children: [
                  if (prod.barcode != null && prod.barcode!.isNotEmpty) ...[
                    const Icon(Icons.qr_code, color: Colors.white38, size: 12),
                    const SizedBox(width: 4),
                    Text(prod.barcode!, style: const TextStyle(color: Colors.white54, fontSize: 11, fontFamily: 'monospace')),
                    const SizedBox(width: 8),
                  ],
                  Text('${prod.price.toStringAsFixed(2)} TJS', style: const TextStyle(color: Color(0xFF10B981), fontSize: 11, fontWeight: FontWeight.bold)),
                ],
              ),
              trailing: const Icon(Icons.edit_rounded, color: Color(0xFF38BDF8), size: 18),
            ),
          );
        },
      ),
    );
  }
}

// Модальное окно выбора товара для перепривязки
class _ProductPickerSheet extends StatefulWidget {
  final List<Product> allProducts;
  final String rawName;

  const _ProductPickerSheet({required this.allProducts, required this.rawName});

  @override
  State<_ProductPickerSheet> createState() => _ProductPickerSheetState();
}

class _ProductPickerSheetState extends State<_ProductPickerSheet> {
  final TextEditingController _filterCtrl = TextEditingController();
  List<Product> _filtered = [];

  @override
  void initState() {
    super.initState();
    _filtered = List.from(widget.allProducts);
    _filterCtrl.addListener(_onFilter);
  }

  @override
  void dispose() {
    _filterCtrl.dispose();
    super.dispose();
  }

  void _onFilter() {
    final q = _filterCtrl.text.trim().toLowerCase();
    setState(() {
      _filtered = widget.allProducts.where((p) {
        if (q.isEmpty) return true;
        return p.name.toLowerCase().contains(q) ||
            (p.barcode != null && p.barcode!.contains(q)) ||
            p.id.toString() == q;
      }).toList();
    });
  }

  Future<void> _scanBarcode() async {
    final scanned = await BarcodeScannerDialog.scan(context);
    if (scanned != null && scanned.isNotEmpty) {
      _filterCtrl.text = scanned;
    }
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Padding(
        padding: EdgeInsets.only(
          left: 16,
          right: 16,
          top: 16,
          bottom: MediaQuery.of(context).viewInsets.bottom + 16,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(Icons.sync_alt_rounded, color: Color(0xFF10B981), size: 22),
                const SizedBox(width: 8),
                const Expanded(
                  child: Text(
                    'Привязать к товару из базы',
                    style: TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.bold),
                  ),
                ),
                IconButton(
                  icon: const Icon(Icons.close_rounded, color: Colors.white54),
                  onPressed: () => Navigator.pop(context),
                ),
              ],
            ),
            Text(
              'Позиция из накладной: "${widget.rawName}"',
              style: const TextStyle(color: Color(0xFF38BDF8), fontSize: 12),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _filterCtrl,
                    style: const TextStyle(color: Colors.white, fontSize: 14),
                    decoration: InputDecoration(
                      hintText: 'Поиск товара по названию или штрихкоду...',
                      hintStyle: const TextStyle(color: Colors.white38, fontSize: 13),
                      prefixIcon: const Icon(Icons.search_rounded, color: Color(0xFF10B981), size: 20),
                      filled: true,
                      fillColor: const Color(0xFF0F172A),
                      contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                      border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide.none),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                IconButton(
                  style: IconButton.styleFrom(
                    backgroundColor: const Color(0xFF10B981),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                  ),
                  icon: const Icon(Icons.qr_code_scanner_rounded, color: Colors.white),
                  onPressed: _scanBarcode,
                ),
              ],
            ),
            const SizedBox(height: 10),
            ConstrainedBox(
              constraints: BoxConstraints(maxHeight: MediaQuery.of(context).size.height * 0.45),
              child: _filtered.isEmpty
                  ? const Center(
                      child: Padding(
                        padding: EdgeInsets.symmetric(vertical: 24),
                        child: Text('Товары не найдены', style: TextStyle(color: Colors.white54)),
                      ),
                    )
                  : ListView.builder(
                      shrinkWrap: true,
                      itemCount: _filtered.length,
                      itemBuilder: (ctx, idx) {
                        final p = _filtered[idx];
                        return ListTile(
                          contentPadding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
                          title: Text(p.name, style: const TextStyle(color: Colors.white, fontSize: 13, fontWeight: FontWeight.bold)),
                          subtitle: Text(
                            'Штрихкод: ${p.barcode ?? "—"} • Розница: ${p.price.toStringAsFixed(2)} TJS',
                            style: const TextStyle(color: Colors.white54, fontSize: 11),
                          ),
                          trailing: const Icon(Icons.check_circle_outline, color: Color(0xFF10B981)),
                          onTap: () => Navigator.pop(context, p),
                        );
                      },
                    ),
            ),
          ],
        ),
      ),
    );
  }
}

// Полнофункциональное модальное окно редактирования товара базы gusar.tj
class _ProductEditorSheet extends StatefulWidget {
  final Product product;
  final ValueChanged<Product> onProductUpdated;

  const _ProductEditorSheet({required this.product, required this.onProductUpdated});

  @override
  State<_ProductEditorSheet> createState() => _ProductEditorSheetState();
}

class _ProductEditorSheetState extends State<_ProductEditorSheet> {
  final ApiService _api = ApiService();
  final ImagePicker _picker = ImagePicker();

  late TextEditingController _nameCtrl;
  late TextEditingController _barcodeCtrl;
  late TextEditingController _priceCtrl;
  late TextEditingController _costPriceCtrl;
  late TextEditingController _wholesalePriceCtrl;
  late TextEditingController _categoryCtrl;
  late String _selectedUnit;

  File? _currentImageFile;
  int _rotationTurns = 0;
  bool _isSaving = false;
  String? _compressionInfo;

  final List<String> _commonUnits = ['шт', 'кг', 'л', 'уп', 'пач', 'кор', 'бутыл'];

  @override
  void initState() {
    super.initState();
    _nameCtrl = TextEditingController(text: widget.product.name);
    _barcodeCtrl = TextEditingController(text: widget.product.barcode ?? '');
    _priceCtrl = TextEditingController(text: widget.product.price.toStringAsFixed(2));
    _costPriceCtrl = TextEditingController(
      text: widget.product.costPrice > 0 ? widget.product.costPrice.toStringAsFixed(2) : '',
    );
    _wholesalePriceCtrl = TextEditingController(
      text: (widget.product.wholesalePrice != null && widget.product.wholesalePrice! > 0)
          ? widget.product.wholesalePrice!.toStringAsFixed(2)
          : '',
    );
    _categoryCtrl = TextEditingController(text: widget.product.category ?? 'Продукты');
    _selectedUnit = widget.product.unit.isNotEmpty ? widget.product.unit : 'шт';

    if (widget.product.localImagePath != null && File(widget.product.localImagePath!).existsSync()) {
      _currentImageFile = File(widget.product.localImagePath!);
    }
  }

  @override
  void dispose() {
    _nameCtrl.dispose();
    _barcodeCtrl.dispose();
    _priceCtrl.dispose();
    _costPriceCtrl.dispose();
    _wholesalePriceCtrl.dispose();
    _categoryCtrl.dispose();
    super.dispose();
  }

  Future<void> _scanBarcode() async {
    final scanned = await BarcodeScannerDialog.scan(context);
    if (scanned != null && scanned.isNotEmpty) {
      setState(() => _barcodeCtrl.text = scanned);
      HapticFeedback.selectionClick();
    }
  }

  Future<void> _pickAndCompressImage(ImageSource source) async {
    try {
      final picked = await _picker.pickImage(
        source: source,
        maxWidth: 1600,
        maxHeight: 1600,
        imageQuality: 92,
      );

      if (picked != null) {
        final originalFile = File(picked.path);
        final originalSize = await originalFile.length();

        final appDir = await getApplicationDocumentsDirectory();
        final fileName = 'prod_${widget.product.id}_${DateTime.now().millisecondsSinceEpoch}.jpg';
        final targetPath = '${appDir.path}/$fileName';

        // Строгий квадрат 1:1 со сжатием строго до 40 КБ
        final savedFile = await ImageUtils.cropToSquareAndCompress(
          originalFile,
          targetPath,
          maxSize: 550,
          quality: 80,
          maxKb: 40,
        );
        final compressedSize = await savedFile.length();

        final origMb = (originalSize / (1024 * 1024)).toStringAsFixed(1);
        final compKb = (compressedSize / 1024).toStringAsFixed(0);

        setState(() {
          _currentImageFile = savedFile;
          _rotationTurns = 0;
          _compressionInfo = 'Формат 1:1 (квадрат) • ${origMb} МБ ➔ ${compKb} КБ (≤ 40 КБ)';
        });

        HapticFeedback.mediumImpact();
      }
    } catch (e) {
      TopNotification.showError(context, 'Ошибка съёмки/выбора фото: $e');
    }
  }

  void _rotateImage() {
    setState(() => _rotationTurns = (_rotationTurns + 1) % 4);
    HapticFeedback.selectionClick();
  }

  void _removePhoto() {
    setState(() {
      _currentImageFile = null;
      _rotationTurns = 0;
      _compressionInfo = null;
    });
  }

  Future<void> _saveAllChanges() async {
    final name = _nameCtrl.text.trim();
    if (name.isEmpty) {
      TopNotification.showError(context, 'Укажите название товара');
      return;
    }

    final price = double.tryParse(_priceCtrl.text.replaceAll(',', '.').trim());
    if (price == null || price < 0) {
      TopNotification.showError(context, 'Укажите корректную розничную цену');
      return;
    }

    final costPrice = double.tryParse(_costPriceCtrl.text.replaceAll(',', '.').trim()) ?? 0.0;
    final wholesalePrice = double.tryParse(_wholesalePriceCtrl.text.replaceAll(',', '.').trim());
    final barcode = _barcodeCtrl.text.trim().isNotEmpty ? _barcodeCtrl.text.trim() : null;

    setState(() => _isSaving = true);

    try {
      Product updated = widget.product.copyWith(
        name: name,
        price: price,
        costPrice: costPrice,
        wholesalePrice: wholesalePrice,
        barcode: barcode,
        unit: _selectedUnit,
        category: _categoryCtrl.text.trim().isNotEmpty ? _categoryCtrl.text.trim() : 'Продукты',
      );

      // 1. Обновляем реквизиты на сервере (PUT /api/products/:id)
      final res = await _api.updateProduct(updated);
      if (res != null) updated = res;

      // 2. Если фото выбрано/повернуто, отправляем на сервер (PATCH /api/products/:id/image)
      if (_currentImageFile != null) {
        File fileToUpload = _currentImageFile!;
        if (_rotationTurns != 0) {
          final appDir = await getApplicationDocumentsDirectory();
          final rotName = 'rot_${widget.product.id}_${DateTime.now().millisecondsSinceEpoch}.jpg';
          fileToUpload = await ImageUtils.cropToSquareAndCompress(
            _currentImageFile!,
            '${appDir.path}/$rotName',
            quarterTurns: _rotationTurns,
            maxSize: 550,
            quality: 80,
            maxKb: 40,
          );
        }

        final photoUpdated = await _api.uploadProductImage(
          widget.product.id,
          fileToUpload.path,
        );
        if (photoUpdated != null) updated = photoUpdated;
      }

      setState(() => _isSaving = false);

      if (mounted) {
        TopNotification.showSuccess(context, 'Товар "$name" успешно обновлен в gusar.tj!');
        widget.onProductUpdated(updated);
        Navigator.pop(context);
      }
    } catch (e) {
      setState(() => _isSaving = false);
      if (mounted) {
        TopNotification.showError(context, 'Ошибка сохранения: $e');
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Padding(
        padding: EdgeInsets.only(
          left: 20,
          right: 20,
          top: 16,
          bottom: MediaQuery.of(context).viewInsets.bottom + 20,
        ),
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Container(
                    padding: const EdgeInsets.all(8),
                    decoration: BoxDecoration(
                      color: const Color(0xFF38BDF8).withOpacity(0.15),
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: const Icon(Icons.edit_note_rounded, color: Color(0xFF38BDF8), size: 22),
                  ),
                  const SizedBox(width: 10),
                  const Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('Редактирование товара', style: TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.bold)),
                        Text('Синхронизация с базой gusar.tj', style: TextStyle(color: Colors.white54, fontSize: 11)),
                      ],
                    ),
                  ),
                  IconButton(
                    icon: const Icon(Icons.close_rounded, color: Colors.white54),
                    onPressed: () => Navigator.pop(context),
                  ),
                ],
              ),
              const SizedBox(height: 14),

              // Фото карточка
              Container(
                width: double.infinity,
                height: 160,
                decoration: BoxDecoration(
                  color: const Color(0xFF0F172A),
                  borderRadius: BorderRadius.circular(14),
                  border: Border.all(color: Colors.white12),
                ),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(14),
                  child: _currentImageFile != null
                      ? Stack(
                          alignment: Alignment.center,
                          children: [
                            RotatedBox(
                              quarterTurns: _rotationTurns,
                              child: Image.file(_currentImageFile!, fit: BoxFit.contain, width: double.infinity, height: 160),
                            ),
                            Positioned(
                              top: 8,
                              right: 8,
                              child: IconButton(
                                style: IconButton.styleFrom(backgroundColor: Colors.black54),
                                icon: const Icon(Icons.rotate_right_rounded, color: Colors.white),
                                tooltip: 'Повернуть на 90°',
                                onPressed: _rotateImage,
                              ),
                            ),
                          ],
                        )
                      : (widget.product.imageUrl != null && widget.product.imageUrl!.isNotEmpty)
                          ? ProductImageWidget(
                              imageUrl: widget.product.imageUrl,
                              localImagePath: widget.product.localImagePath,
                              fit: BoxFit.contain,
                              placeholder: const Center(
                                child: Text('Фотография не привязана', style: TextStyle(color: Colors.white38, fontSize: 12)),
                              ),
                            )
                          : const Center(
                              child: Text('Фотография не привязана', style: TextStyle(color: Colors.white38, fontSize: 12)),
                            ),
                ),
              ),

              if (_compressionInfo != null) ...[
                const SizedBox(height: 6),
                Text(_compressionInfo!, style: const TextStyle(color: Color(0xFF34D399), fontSize: 11)),
              ],

              const SizedBox(height: 10),

              Row(
                children: [
                  Expanded(
                    child: OutlinedButton.icon(
                      style: OutlinedButton.styleFrom(
                        side: const BorderSide(color: Color(0xFF10B981)),
                        foregroundColor: const Color(0xFF10B981),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                      ),
                      onPressed: () => _pickAndCompressImage(ImageSource.camera),
                      icon: const Icon(Icons.camera_alt_rounded, size: 16),
                      label: const Text('Камера', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 12)),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: OutlinedButton.icon(
                      style: OutlinedButton.styleFrom(
                        side: const BorderSide(color: Color(0xFF38BDF8)),
                        foregroundColor: const Color(0xFF38BDF8),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                      ),
                      onPressed: () => _pickAndCompressImage(ImageSource.gallery),
                      icon: const Icon(Icons.photo_library_rounded, size: 16),
                      label: const Text('Галерея', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 12)),
                    ),
                  ),
                  if (_currentImageFile != null) ...[
                    const SizedBox(width: 8),
                    IconButton(
                      icon: const Icon(Icons.delete_outline_rounded, color: Colors.redAccent),
                      tooltip: 'Удалить фото',
                      onPressed: _removePhoto,
                    ),
                  ],
                ],
              ),

              const SizedBox(height: 14),

              const Text('Название товара *', style: TextStyle(color: Colors.white70, fontSize: 12, fontWeight: FontWeight.bold)),
              const SizedBox(height: 4),
              TextField(
                controller: _nameCtrl,
                style: const TextStyle(color: Colors.white, fontSize: 14),
                decoration: InputDecoration(
                  filled: true,
                  fillColor: const Color(0xFF0F172A),
                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: BorderSide.none),
                  contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                ),
              ),

              const SizedBox(height: 12),

              const Text('Штрихкод', style: TextStyle(color: Colors.white70, fontSize: 12, fontWeight: FontWeight.bold)),
              const SizedBox(height: 4),
              TextField(
                controller: _barcodeCtrl,
                style: const TextStyle(color: Colors.white, fontSize: 14, fontFamily: 'monospace'),
                decoration: InputDecoration(
                  filled: true,
                  fillColor: const Color(0xFF0F172A),
                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: BorderSide.none),
                  contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                  suffixIcon: IconButton(
                    icon: const Icon(Icons.qr_code_scanner_rounded, color: Color(0xFF10B981)),
                    tooltip: 'Сканировать штрихкод камерой',
                    onPressed: _scanBarcode,
                  ),
                ),
              ),

              const SizedBox(height: 12),

              Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text('Розничная цена (TJS) *', style: TextStyle(color: Color(0xFF10B981), fontSize: 12, fontWeight: FontWeight.bold)),
                        const SizedBox(height: 4),
                        TextField(
                          controller: _priceCtrl,
                          keyboardType: const TextInputType.numberWithOptions(decimal: true),
                          style: const TextStyle(color: Colors.white, fontSize: 14, fontWeight: FontWeight.bold),
                          decoration: InputDecoration(
                            filled: true,
                            fillColor: const Color(0xFF0F172A),
                            border: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: BorderSide.none),
                            contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text('Себестоимость (закуп)', style: TextStyle(color: Color(0xFF38BDF8), fontSize: 12, fontWeight: FontWeight.bold)),
                        const SizedBox(height: 4),
                        TextField(
                          controller: _costPriceCtrl,
                          keyboardType: const TextInputType.numberWithOptions(decimal: true),
                          style: const TextStyle(color: Colors.white, fontSize: 14),
                          decoration: InputDecoration(
                            filled: true,
                            fillColor: const Color(0xFF0F172A),
                            border: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: BorderSide.none),
                            contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),

              const SizedBox(height: 12),

              Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text('Оптовая цена (TJS)', style: TextStyle(color: Colors.white70, fontSize: 12, fontWeight: FontWeight.bold)),
                        const SizedBox(height: 4),
                        TextField(
                          controller: _wholesalePriceCtrl,
                          keyboardType: const TextInputType.numberWithOptions(decimal: true),
                          style: const TextStyle(color: Colors.white, fontSize: 14),
                          decoration: InputDecoration(
                            filled: true,
                            fillColor: const Color(0xFF0F172A),
                            border: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: BorderSide.none),
                            contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text('Единица изм.', style: TextStyle(color: Colors.white70, fontSize: 12, fontWeight: FontWeight.bold)),
                        const SizedBox(height: 4),
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 10),
                          decoration: BoxDecoration(
                            color: const Color(0xFF0F172A),
                            borderRadius: BorderRadius.circular(10),
                          ),
                          child: DropdownButtonHideUnderline(
                            child: DropdownButton<String>(
                              isExpanded: true,
                              value: _commonUnits.contains(_selectedUnit) ? _selectedUnit : _commonUnits.first,
                              dropdownColor: const Color(0xFF1E293B),
                              style: const TextStyle(color: Colors.white, fontSize: 14),
                              items: _commonUnits
                                  .map((u) => DropdownMenuItem(value: u, child: Text(u)))
                                  .toList(),
                              onChanged: (val) {
                                if (val != null) setState(() => _selectedUnit = val);
                              },
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),

              const SizedBox(height: 12),

              const Text('Категория', style: TextStyle(color: Colors.white70, fontSize: 12, fontWeight: FontWeight.bold)),
              const SizedBox(height: 4),
              TextField(
                controller: _categoryCtrl,
                style: const TextStyle(color: Colors.white, fontSize: 14),
                decoration: InputDecoration(
                  filled: true,
                  fillColor: const Color(0xFF0F172A),
                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: BorderSide.none),
                  contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                ),
              ),

              const SizedBox(height: 18),

              ElevatedButton(
                style: ElevatedButton.styleFrom(
                  backgroundColor: const Color(0xFF10B981),
                  minimumSize: const Size(double.infinity, 48),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                ),
                onPressed: _isSaving ? null : _saveAllChanges,
                child: _isSaving
                    ? const SizedBox(
                        height: 20,
                        width: 20,
                        child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2),
                      )
                    : const Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Icon(Icons.save_rounded, color: Colors.white, size: 20),
                          SizedBox(width: 8),
                          Text('Сохранить изменения в gusar.tj', style: TextStyle(color: Colors.white, fontSize: 15, fontWeight: FontWeight.bold)),
                        ],
                      ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
