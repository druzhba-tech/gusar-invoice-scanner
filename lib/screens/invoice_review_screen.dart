import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import '../models/invoice_document.dart';
import '../models/invoice_item.dart';
import '../models/product.dart';
import '../models/supplier.dart';
import '../services/api_service.dart';
import '../services/local_storage_service.dart';
import '../services/matching_service.dart';
import '../services/invoice_template_service.dart';
import 'matching_screen.dart';
import 'barcode_verifier_screen.dart';
import 'discrepancy_screen.dart';
import 'add_product_screen.dart';
import '../widgets/document_photo_viewer_dialog.dart';
import '../utils/top_notification.dart';

class InvoiceReviewScreen extends StatefulWidget {
  final InvoiceDocument document;

  const InvoiceReviewScreen({super.key, required this.document});

  @override
  State<InvoiceReviewScreen> createState() => _InvoiceReviewScreenState();
}

class _InvoiceReviewScreenState extends State<InvoiceReviewScreen> {
  late InvoiceDocument _doc;
  final ApiService _api = ApiService();
  final MatchingService _matcher = MatchingService();
  final LocalStorageService _storage = LocalStorageService();

  bool _isSubmitting = false;
  bool _isDuplicate = false;

  @override
  void initState() {
    super.initState();
    _doc = widget.document;
    _matcher.init();
    _checkDuplicate();
    // Автоматически получаем следующий последовательный системный номер gusar.tj
    if (_doc.invoiceNumber.isEmpty || _doc.invoiceNumber == 'б/н') {
      _api.fetchNextSequentialInvoiceNumber(storeId: _doc.storeId).then((nextSeq) {
        if (mounted && (_doc.invoiceNumber.isEmpty || _doc.invoiceNumber == 'б/н')) {
          setState(() => _doc.invoiceNumber = nextSeq);
          _storage.saveInvoice(_doc);
        }
      }).catchError((_) {});
    }
    // Фоновая загрузка контрагентов при входе в накладную
    _api.getSuppliers().then((_) {
      if (mounted) setState(() {});
    }).catchError((_) {});
  }

  Future<void> _checkDuplicate() async {
    final exists = await _api.checkInvoiceExists(_doc.invoiceNumber, _doc.supplierId);
    if (exists && mounted) {
      setState(() => _isDuplicate = true);
    }
  }

  Future<void> _saveAndRefresh() async {
    await _storage.saveInvoice(_doc);
    if (mounted) setState(() {});
  }

  // Привязка товара к строке накладной
  Future<void> _bindProductToItem(InvoiceItem item, Product product) async {
    setState(() {
      item.matchedProductId = product.id;
      item.matchedProductName = product.name;
      item.matchedBarcode = product.barcode;
      item.currentRetailPrice = product.price;
      item.lastBuyPrice = product.costPrice;
      item.matchConfidence = 1.0;
      item.status = ItemStatus.verified;
    });

    await _matcher.saveAlias(_doc.supplierName, item.rawName, product.id);
    await _saveAndRefresh();

    if (mounted) {
      TopNotification.showSuccess(context, 'Товар "${product.name}" успешно привязан к накладной!');
    }
  }

  // Создание нового товара прямо из накладной
  Future<void> _createNewProductForItem(InvoiceItem item, [String? initialBarcode]) async {
    final ProductType suggestedType = (item.unit == 'кг' || item.rawName.toLowerCase().contains('весов'))
        ? ProductType.weight
        : ProductType.barcode;

    final created = await Navigator.push<Product?>(
      context,
      MaterialPageRoute(
        builder: (_) => AddProductScreen(
          initialName: item.rawName,
          initialCostPrice: item.buyPrice > 0 ? item.buyPrice : null,
          initialBarcode: initialBarcode ?? item.barcode ?? item.matchedBarcode,
          initialType: suggestedType,
        ),
      ),
    );

    if (created != null) {
      await _bindProductToItem(item, created);
    }
  }

  // 1. Привязка позиции по пику штрихкода (Scan to Bind)
  void _scanAndBindItem(InvoiceItem item) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (sheetCtx) => _ItemBarcodeScannerModal(
        item: item,
        supplierName: _doc.supplierName,
        api: _api,
        matcher: _matcher,
        onBound: (Product matchedProduct) async {
          Navigator.pop(sheetCtx);
          await _saveAndRefresh();
          if (mounted) {
            TopNotification.showSuccess(context, 'Связано с: "${matchedProduct.name}" (штрихкод: ${matchedProduct.barcode ?? "-"})');
          }
        },
      ),
    );
  }

  // 2. Выбор товара из базы gusar.tj через поиск
  void _showCatalogPicker(InvoiceItem item) {
    final searchCtrl = TextEditingController();
    bool isSyncing = false;
    List<Product> searchResults = List.from(_api.cachedProducts);

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: const Color(0xFF1E293B),
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (modalCtx) => StatefulBuilder(
        builder: (ctx, setModalState) {
          // Если локальный каталог пуст, подгружаем онлайн с сервера gusar.tj
          if (searchResults.isEmpty && !isSyncing) {
            isSyncing = true;
            _api.getProducts().then((prods) {
              if (modalCtx.mounted) {
                setModalState(() {
                  isSyncing = false;
                  searchResults = prods;
                });
              }
            });
          }

          return Container(
            height: MediaQuery.of(context).size.height * 0.82,
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Text('Поиск в базе gusar.tj', style: TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.bold)),
                          Text('Склад: ${_api.currentStoreName}', style: const TextStyle(color: Color(0xFF10B981), fontSize: 11)),
                        ],
                      ),
                    ),
                    ElevatedButton.icon(
                      style: ElevatedButton.styleFrom(
                        backgroundColor: const Color(0xFF10B981),
                        foregroundColor: Colors.white,
                        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                      ),
                      icon: const Icon(Icons.add, size: 16),
                      label: const Text('Создать', style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold)),
                      onPressed: () {
                        Navigator.pop(modalCtx);
                        _createNewProductForItem(item, item.barcode);
                      },
                    ),
                    const SizedBox(width: 4),
                    IconButton(
                      icon: isSyncing
                          ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2, color: Color(0xFF10B981)))
                          : const Icon(Icons.sync_rounded, color: Color(0xFF10B981), size: 22),
                      tooltip: 'Обновить товары с сервера gusar.tj',
                      onPressed: isSyncing
                          ? null
                          : () async {
                              setModalState(() => isSyncing = true);
                              final prods = await _api.getProducts(forceRefresh: true);
                              if (modalCtx.mounted) {
                                setModalState(() {
                                  isSyncing = false;
                                  searchResults = prods;
                                });
                              }
                            },
                    ),
                    IconButton(
                      icon: const Icon(Icons.close, color: Colors.white54),
                      onPressed: () => Navigator.pop(modalCtx),
                    ),
                  ],
                ),
                Text(
                  'Привязка позиции: "${item.rawName}"',
                  style: const TextStyle(color: Color(0xFF38BDF8), fontSize: 13),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: searchCtrl,
                  style: const TextStyle(color: Colors.white),
                  decoration: InputDecoration(
                    hintText: 'Поиск по названию или штрихкоду...',
                    hintStyle: const TextStyle(color: Colors.white38),
                    prefixIcon: const Icon(Icons.search, color: Color(0xFF38BDF8)),
                    filled: true,
                    fillColor: const Color(0xFF0F172A),
                    border: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: BorderSide.none),
                  ),
                  onChanged: (val) async {
                    final results = await _api.searchProducts(val);
                    setModalState(() {
                      searchResults = results;
                    });
                  },
                ),
                const SizedBox(height: 12),
                Expanded(
                  child: isSyncing
                      ? const Center(
                          child: Column(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              CircularProgressIndicator(color: Color(0xFF10B981)),
                              SizedBox(height: 12),
                              Text('Загрузка товаров из базы gusar.tj...', style: TextStyle(color: Colors.white70)),
                            ],
                          ),
                        )
                      : searchResults.isEmpty
                          ? Center(
                              child: Column(
                                mainAxisAlignment: MainAxisAlignment.center,
                                children: [
                                  const Icon(Icons.inventory_2_outlined, color: Colors.white38, size: 48),
                                  const SizedBox(height: 8),
                                  Text(
                                    searchCtrl.text.isEmpty
                                        ? 'В вашем магазине на gusar.tj пока нет товаров или требуется войти в систему (Настройки).'
                                        : 'Товар "${searchCtrl.text}" не найден в базе магазина',
                                    textAlign: TextAlign.center,
                                    style: const TextStyle(color: Colors.white54, fontSize: 13),
                                  ),
                                  const SizedBox(height: 12),
                                  ElevatedButton.icon(
                                    style: ElevatedButton.styleFrom(
                                      backgroundColor: const Color(0xFF10B981),
                                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                                      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                                    ),
                                    icon: const Icon(Icons.add_circle_outline, color: Colors.white),
                                    label: const Text('Создать новый товар', style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
                                    onPressed: () {
                                      Navigator.pop(modalCtx);
                                      _createNewProductForItem(item, item.barcode);
                                    },
                                  ),
                                ],
                              ),
                            )
                          : ListView.separated(
                              itemCount: searchResults.length,
                              separatorBuilder: (_, __) => const Divider(color: Colors.white10),
                              itemBuilder: (ctx, i) {
                                final p = searchResults[i];

                                InvoiceItem? boundItem;
                                int boundIndex = -1;
                                for (int idx = 0; idx < _doc.items.length; idx++) {
                                  if (_doc.items[idx].matchedProductId == p.id) {
                                    boundItem = _doc.items[idx];
                                    boundIndex = idx + 1;
                                    break;
                                  }
                                }

                                final bool isBoundToThis = item.matchedProductId == p.id;
                                final bool isBoundToOther = boundItem != null && !isBoundToThis;

                                return Container(
                                  decoration: BoxDecoration(
                                    color: isBoundToThis
                                        ? const Color(0xFF10B981).withOpacity(0.12)
                                        : isBoundToOther
                                            ? Colors.amber.withOpacity(0.08)
                                            : Colors.transparent,
                                    borderRadius: BorderRadius.circular(8),
                                  ),
                                  child: ListTile(
                                    contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                                    title: Row(
                                      children: [
                                        Expanded(
                                          child: Text(
                                            p.name,
                                            style: const TextStyle(color: Colors.white, fontSize: 14, fontWeight: FontWeight.w600),
                                          ),
                                        ),
                                        if (isBoundToThis)
                                          Container(
                                            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                                            decoration: BoxDecoration(
                                              color: const Color(0xFF10B981).withOpacity(0.25),
                                              borderRadius: BorderRadius.circular(4),
                                              border: Border.all(color: const Color(0xFF10B981).withOpacity(0.5)),
                                            ),
                                            child: const Text('Текущий выбор', style: TextStyle(color: Color(0xFF10B981), fontSize: 10, fontWeight: FontWeight.bold)),
                                          )
                                        else if (isBoundToOther)
                                          Container(
                                            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                                            decoration: BoxDecoration(
                                              color: Colors.amber.withOpacity(0.2),
                                              borderRadius: BorderRadius.circular(4),
                                              border: Border.all(color: Colors.amber.withOpacity(0.5)),
                                            ),
                                            child: Text('Уже в накл. #$boundIndex', style: const TextStyle(color: Colors.amber, fontSize: 10, fontWeight: FontWeight.bold)),
                                          ),
                                      ],
                                    ),
                                    subtitle: Column(
                                      crossAxisAlignment: CrossAxisAlignment.start,
                                      children: [
                                        const SizedBox(height: 2),
                                        Text(
                                          'Штрихкод: ${p.barcode ?? 'нет'} • Розница: ${p.price.toStringAsFixed(2)} TJS • Остаток: ${p.stockQuantity}',
                                          style: const TextStyle(color: Colors.white54, fontSize: 12),
                                        ),
                                        if (isBoundToOther && boundItem != null) ...[
                                          const SizedBox(height: 2),
                                          Text(
                                            '⚠️ Привязан к строке #$boundIndex: "${boundItem.rawName}"',
                                            style: const TextStyle(color: Colors.amberAccent, fontSize: 11, fontWeight: FontWeight.w500),
                                            maxLines: 1,
                                            overflow: TextOverflow.ellipsis,
                                          ),
                                        ],
                                      ],
                                    ),
                                    trailing: ElevatedButton(
                                      style: ElevatedButton.styleFrom(
                                        backgroundColor: isBoundToThis
                                            ? const Color(0xFF10B981)
                                            : isBoundToOther
                                                ? Colors.amber.shade700
                                                : const Color(0xFF38BDF8),
                                        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                                      ),
                                      onPressed: () async {
                                        if (isBoundToThis) {
                                          Navigator.pop(modalCtx);
                                          return;
                                        }

                                        if (isBoundToOther && boundItem != null) {
                                          final confirm = await showDialog<bool>(
                                            context: modalCtx,
                                            builder: (c) => AlertDialog(
                                              backgroundColor: const Color(0xFF1E293B),
                                              title: const Text('Товар уже используется', style: TextStyle(color: Colors.white)),
                                              content: Text(
                                                'Товар "${p.name}" уже привязан к строке #$boundIndex ("${boundItem!.rawName}").\n\nПерепривязать к "${item.rawName}"?',
                                                style: const TextStyle(color: Colors.white70),
                                              ),
                                              actions: [
                                                TextButton(
                                                  onPressed: () => Navigator.pop(c, false),
                                                  child: const Text('Отмена', style: TextStyle(color: Colors.white54)),
                                                ),
                                                ElevatedButton(
                                                  style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFF10B981)),
                                                  onPressed: () => Navigator.pop(c, true),
                                                  child: const Text('Перепривязать', style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
                                                ),
                                              ],
                                            ),
                                          );
                                          if (confirm != true) return;
                                          boundItem!.matchedProductId = null;
                                          boundItem!.matchedProductName = null;
                                          boundItem!.matchedBarcode = null;
                                        }

                                        _matcher.applyMatch(item, p, confidence: 1.0);
                                        await _matcher.saveAlias(_doc.supplierName, item.rawName, p.id);
                                        Navigator.pop(modalCtx);
                                        await _saveAndRefresh();
                                        if (mounted) {
                                          TopNotification.showSuccess(
                                            context,
                                            isBoundToOther
                                                ? 'Товар привязан к "${p.name}" (перенесен со строки #$boundIndex)!'
                                                : 'Позиция привязана к "${p.name}"!',
                                          );
                                        }
                                      },
                                      child: Text(
                                        isBoundToThis
                                            ? 'Выбран'
                                            : isBoundToOther
                                                ? 'Занят (#$boundIndex)'
                                                : 'Связать',
                                        style: TextStyle(
                                          color: isBoundToOther || isBoundToThis ? Colors.white : Colors.black,
                                          fontWeight: FontWeight.bold,
                                          fontSize: 12,
                                        ),
                                      ),
                                    ),
                                  ),
                                );
                              },
                            ),
                ),
              ],
            ),
          );
        },
      ),
    );
  }

  // 3. Создание нового товара на сайте gusar.tj
  void _showCreateProductDialog(InvoiceItem item, {String? initialName, String? initialBarcode}) {
    final nameCtrl = TextEditingController(text: initialName ?? item.rawName);
    final barcodeCtrl = TextEditingController(text: initialBarcode ?? item.barcode ?? '');
    final costCtrl = TextEditingController(text: item.buyPrice > 0 ? item.buyPrice.toStringAsFixed(2) : '');
    final wholesaleCtrl = TextEditingController();
    final retailCtrl = TextEditingController();

    showDialog(
      context: context,
      builder: (dlgCtx) => AlertDialog(
        backgroundColor: const Color(0xFF1E293B),
        title: const Text('Новый товар в gusar.tj', style: TextStyle(color: Colors.white, fontSize: 16)),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: nameCtrl,
                style: const TextStyle(color: Colors.white),
                decoration: const InputDecoration(labelText: 'Название товара', labelStyle: TextStyle(color: Colors.white60)),
              ),
              const SizedBox(height: 8),
              TextField(
                controller: barcodeCtrl,
                style: const TextStyle(color: Colors.white),
                decoration: const InputDecoration(labelText: 'Штрихкод', labelStyle: TextStyle(color: Colors.white60)),
              ),
              const SizedBox(height: 8),
              TextField(
                controller: costCtrl,
                keyboardType: TextInputType.number,
                style: const TextStyle(color: Colors.white),
                decoration: const InputDecoration(labelText: 'Себестоимость (закупка), TJS', labelStyle: TextStyle(color: Colors.white60)),
              ),
              const SizedBox(height: 8),
              TextField(
                controller: wholesaleCtrl,
                keyboardType: TextInputType.number,
                style: const TextStyle(color: Color(0xFF38BDF8)),
                decoration: const InputDecoration(labelText: 'Оптовая цена, TJS', labelStyle: TextStyle(color: Colors.white60)),
              ),
              const SizedBox(height: 8),
              TextField(
                controller: retailCtrl,
                keyboardType: TextInputType.number,
                style: const TextStyle(color: Color(0xFF10B981)),
                decoration: const InputDecoration(labelText: 'Розничная цена (продажа), TJS', labelStyle: TextStyle(color: Colors.white60)),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(dlgCtx), child: const Text('Отмена', style: TextStyle(color: Colors.white54))),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFF10B981)),
            onPressed: () async {
              final newName = nameCtrl.text.trim();
              final newBarcode = barcodeCtrl.text.trim();
              final cost = double.tryParse(costCtrl.text) ?? item.buyPrice;
              final wholesale = double.tryParse(wholesaleCtrl.text);
              final retail = double.tryParse(retailCtrl.text) ?? 0.0;

              if (newName.isEmpty) return;

              final created = await _api.createProduct(
                name: newName,
                barcode: newBarcode,
                price: retail,
                wholesalePrice: wholesale,
                costPrice: cost,
              );

              if (created != null) {
                _matcher.applyMatch(item, created, confidence: 1.0);
                await _matcher.saveAlias(_doc.supplierName, item.rawName, created.id);
                Navigator.pop(dlgCtx);
                await _saveAndRefresh();
                if (mounted) {
                  TopNotification.showSuccess(context, 'Карточка товара "${created.name}" создана в базе gusar.tj и привязана!');
                }
              }
            },
            child: const Text('Создать и привязать', style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
          ),
        ],
      ),
    );
  }

  // 4. Редактирование строки накладной с самообучением и живым подсчетом
  void _editItem(InvoiceItem item) {
    final nameCtrl = TextEditingController(text: item.rawName);
    final qtyCtrl = TextEditingController(text: item.quantity.toString());
    final unitCtrl = TextEditingController(text: item.unit);
    final priceCtrl = TextEditingController(text: item.buyPrice.toStringAsFixed(2));

    showDialog(
      context: context,
      builder: (dlgCtx) => StatefulBuilder(
        builder: (ctx, setDlgState) {
          final curQty = double.tryParse(qtyCtrl.text) ?? 0.0;
          final curPrice = double.tryParse(priceCtrl.text) ?? 0.0;
          final curTotal = curQty * curPrice;

          return AlertDialog(
            backgroundColor: const Color(0xFF1E293B),
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
            title: const Row(
              children: [
                Icon(Icons.edit_note_rounded, color: Color(0xFF38BDF8), size: 22),
                SizedBox(width: 8),
                Text('Редактировать товар', style: TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.bold)),
              ],
            ),
            content: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  TextField(
                    controller: nameCtrl,
                    style: const TextStyle(color: Colors.white),
                    decoration: const InputDecoration(
                      labelText: 'Наименование товара',
                      labelStyle: TextStyle(color: Colors.white60),
                      border: OutlineInputBorder(),
                    ),
                  ),
                  const SizedBox(height: 12),
                  Row(
                    children: [
                      Expanded(
                        flex: 3,
                        child: TextField(
                          controller: qtyCtrl,
                          keyboardType: const TextInputType.numberWithOptions(decimal: true),
                          style: const TextStyle(color: Colors.white),
                          decoration: const InputDecoration(
                            labelText: 'Кол-во',
                            labelStyle: TextStyle(color: Colors.white60),
                            border: OutlineInputBorder(),
                          ),
                          onChanged: (_) => setDlgState(() {}),
                        ),
                      ),
                      const SizedBox(width: 8),
                      SizedBox(
                        width: 70,
                        child: TextField(
                          controller: unitCtrl,
                          style: const TextStyle(color: Colors.white),
                          decoration: const InputDecoration(
                            labelText: 'Ед.',
                            labelStyle: TextStyle(color: Colors.white60),
                            border: OutlineInputBorder(),
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        flex: 3,
                        child: TextField(
                          controller: priceCtrl,
                          keyboardType: const TextInputType.numberWithOptions(decimal: true),
                          style: const TextStyle(color: Colors.white),
                          decoration: const InputDecoration(
                            labelText: 'Цена, TJS',
                            labelStyle: TextStyle(color: Colors.white60),
                            border: OutlineInputBorder(),
                          ),
                          onChanged: (_) => setDlgState(() {}),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 14),
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                    decoration: BoxDecoration(
                      color: const Color(0xFF0F172A),
                      borderRadius: BorderRadius.circular(10),
                      border: Border.all(color: Colors.white12),
                    ),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        const Text('Сумма строки:', style: TextStyle(color: Colors.white70, fontSize: 13)),
                        Text(
                          '${curTotal.toStringAsFixed(2)} TJS',
                          style: const TextStyle(color: Color(0xFF10B981), fontSize: 16, fontWeight: FontWeight.bold),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 8),
                  const Row(
                    children: [
                      Icon(Icons.psychology_outlined, color: Color(0xFF38BDF8), size: 14),
                      SizedBox(width: 4),
                      Expanded(
                        child: Text(
                          'Приложение запомнит это исправление для последующих накладных',
                          style: TextStyle(color: Colors.white38, fontSize: 11),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(dlgCtx),
                child: const Text('Отмена', style: TextStyle(color: Colors.white54)),
              ),
              ElevatedButton.icon(
                style: ElevatedButton.styleFrom(
                  backgroundColor: const Color(0xFF10B981),
                  foregroundColor: Colors.white,
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                ),
                icon: const Icon(Icons.check, size: 18),
                label: const Text('Сохранить и запомнить', style: TextStyle(fontWeight: FontWeight.bold)),
                onPressed: () async {
                  final originalRawName = item.rawName;
                  final newName = nameCtrl.text.trim();
                  final newQty = double.tryParse(qtyCtrl.text) ?? item.quantity;
                  final newPrice = double.tryParse(priceCtrl.text) ?? item.buyPrice;

                  if (newName.isNotEmpty) {
                    item.rawName = newName;
                    item.quantity = newQty;
                    item.unit = unitCtrl.text.trim().isNotEmpty ? unitCtrl.text.trim() : item.unit;
                    item.buyPrice = newPrice;
                    item.totalPrice = newQty * newPrice;

                    // 1. Пересчет точного итога накладной
                    _doc.totalAmount = _doc.items.fold(0.0, (sum, i) => sum + i.totalPrice);

                    // 2. Обучение памяти OCR исправлений
                    if (originalRawName != newName) {
                      await _matcher.learnCorrection(rawOcrText: originalRawName, cleanText: newName);
                    }

                    // 3. Если товар уже привязан к карточке gusar.tj, запоминаем новое название в синонимы
                    if (item.matchedProductId != null) {
                      await _matcher.saveAlias(_doc.supplierName, newName, item.matchedProductId!);
                    } else {
                      // Если не привязан, пробуем сопоставить по выученным правилам
                      _matcher.autoMatchDocument(_doc, _api.cachedProducts);
                    }

                    Navigator.pop(dlgCtx);
                    await _saveAndRefresh();

                    if (mounted) {
                      TopNotification.showSuccess(context, 'Товар обновлен! Приложение запомнило исправление.');
                    }
                  }
                },
              ),
            ],
          );
        },
      ),
    );
  }

  // 5. Отвязка товара от номенклатуры gusar.tj
  void _unlinkItem(InvoiceItem item) async {
    setState(() {
      item.matchedProductId = null;
      item.matchedProductName = null;
      item.matchedBarcode = null;
      item.currentRetailPrice = null;
      item.lastBuyPrice = null;
      item.matchConfidence = 0.0;
      item.status = ItemStatus.pending;
    });
    await _saveAndRefresh();
    if (mounted) {
      TopNotification.showInfo(context, 'Связка отменена. Позиция свободна для выбора.');
    }
  }

  // 6. Удаление строки накладной (например, лишний распознанный мусор)
  void _deleteItem(InvoiceItem item, int index) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF1E293B),
        title: const Text('Удалить позицию?', style: TextStyle(color: Colors.white)),
        content: Text('Удалить "${item.rawName}" из накладной?', style: const TextStyle(color: Colors.white70)),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Отмена', style: TextStyle(color: Colors.white54))),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: Colors.redAccent),
            onPressed: () {
              Navigator.pop(ctx);
              setState(() {
                _doc.items.removeAt(index);
                _doc.totalAmount = _doc.items.fold(0.0, (s, i) => s + i.totalPrice);
              });
              _saveAndRefresh();
            },
            child: const Text('Удалить', style: TextStyle(color: Colors.white)),
          ),
        ],
      ),
    );
  }

  // 6. Добавление позиции вручную
  void _addNewItem() {
    final nameCtrl = TextEditingController();
    final qtyCtrl = TextEditingController(text: '1');
    final priceCtrl = TextEditingController(text: '0');

    showDialog(
      context: context,
      builder: (dlgCtx) => AlertDialog(
        backgroundColor: const Color(0xFF1E293B),
        title: const Text('Добавить товар вручную', style: TextStyle(color: Colors.white, fontSize: 16)),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(controller: nameCtrl, style: const TextStyle(color: Colors.white), decoration: const InputDecoration(labelText: 'Наименование', labelStyle: TextStyle(color: Colors.white60))),
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(child: TextField(controller: qtyCtrl, keyboardType: TextInputType.number, style: const TextStyle(color: Colors.white), decoration: const InputDecoration(labelText: 'Количество', labelStyle: TextStyle(color: Colors.white60)))),
                const SizedBox(width: 12),
                Expanded(child: TextField(controller: priceCtrl, keyboardType: TextInputType.number, style: const TextStyle(color: Colors.white), decoration: const InputDecoration(labelText: 'Цена закупки, TJS', labelStyle: TextStyle(color: Colors.white60)))),
              ],
            ),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(dlgCtx), child: const Text('Отмена', style: TextStyle(color: Colors.white54))),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFF10B981)),
            onPressed: () {
              final name = nameCtrl.text.trim();
              final qty = double.tryParse(qtyCtrl.text) ?? 1.0;
              final price = double.tryParse(priceCtrl.text) ?? 0.0;
              if (name.isNotEmpty) {
                final newItem = InvoiceItem(
                  id: 'manual_${DateTime.now().millisecondsSinceEpoch}',
                  rawName: name,
                  quantity: qty,
                  buyPrice: price,
                  totalPrice: qty * price,
                );
                setState(() {
                  _doc.items.add(newItem);
                  _doc.totalAmount = _doc.items.fold(0.0, (s, i) => s + i.totalPrice);
                });
                Navigator.pop(dlgCtx);
                _saveAndRefresh();
              }
            },
            child: const Text('Добавить', style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
          ),
        ],
      ),
    );
  }

  // 7. Выбор контрагента из базы магазина на gusar.tj
  void _showCounterpartyPicker() {
    final searchCtrl = TextEditingController();
    bool isSyncing = _api.cachedSuppliers.isEmpty;
    List<Supplier> suppliersList = List.from(_api.cachedSuppliers);

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: const Color(0xFF1E293B),
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (modalCtx) => StatefulBuilder(
        builder: (ctx, setModalState) {
          if (isSyncing && suppliersList.isEmpty) {
            _api.getSuppliers().then((sups) {
              if (modalCtx.mounted) {
                setModalState(() {
                  isSyncing = false;
                  suppliersList = sups;
                });
              }
            }).catchError((_) {
              if (modalCtx.mounted) {
                setModalState(() => isSyncing = false);
              }
            });
          }

          return Container(
            height: MediaQuery.of(context).size.height * 0.82,
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Text('Контрагенты базы gusar.tj', style: TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.bold)),
                          Text('Склад: ${_api.currentStoreName}', style: const TextStyle(color: Color(0xFF10B981), fontSize: 11)),
                        ],
                      ),
                    ),
                    IconButton(
                      icon: isSyncing
                          ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2, color: Color(0xFF10B981)))
                          : const Icon(Icons.sync_rounded, color: Color(0xFF10B981), size: 22),
                      tooltip: 'Обновить контрагентов с сервера',
                      onPressed: isSyncing
                          ? null
                          : () async {
                              setModalState(() => isSyncing = true);
                              final sups = await _api.getSuppliers(forceRefresh: true);
                              if (modalCtx.mounted) {
                                setModalState(() {
                                  isSyncing = false;
                                  suppliersList = sups;
                                });
                              }
                            },
                    ),
                    IconButton(
                      icon: const Icon(Icons.close, color: Colors.white54),
                      onPressed: () => Navigator.pop(modalCtx),
                    ),
                  ],
                ),
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Expanded(
                      child: Text(
                        _doc.supplierId != null
                            ? 'Привязан к базе: "${_doc.supplierName}" (ID: ${_doc.supplierId})'
                            : 'Текущий по накладной: "${_doc.supplierName}" (Не привязан)',
                        style: TextStyle(
                          color: _doc.supplierId != null ? const Color(0xFF10B981) : const Color(0xFFF59E0B),
                          fontSize: 13,
                          fontWeight: FontWeight.bold,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    if (_doc.supplierId != null)
                      TextButton.icon(
                        style: TextButton.styleFrom(
                          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                          visualDensity: VisualDensity.compact,
                        ),
                        icon: const Icon(Icons.link_off_rounded, color: Colors.redAccent, size: 16),
                        label: const Text('Отвязать', style: TextStyle(color: Colors.redAccent, fontSize: 11)),
                        onPressed: () async {
                          setState(() {
                            _doc.supplierId = null;
                          });
                          Navigator.pop(modalCtx);
                          await _saveAndRefresh();
                          if (mounted) {
                            TopNotification.showInfo(context, 'Связка с контрагентом базы удалена.');
                          }
                        },
                      ),
                  ],
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: searchCtrl,
                  style: const TextStyle(color: Colors.white),
                  decoration: InputDecoration(
                    hintText: 'Поиск контрагента по названию или ИНН...',
                    hintStyle: const TextStyle(color: Colors.white38),
                    prefixIcon: const Icon(Icons.search, color: Color(0xFF38BDF8)),
                    filled: true,
                    fillColor: const Color(0xFF0F172A),
                    border: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: BorderSide.none),
                  ),
                  onChanged: (val) async {
                    final results = await _api.searchSuppliers(val);
                    setModalState(() {
                      suppliersList = results;
                    });
                  },
                ),
                const SizedBox(height: 12),
                Expanded(
                  child: isSyncing
                      ? const Center(
                          child: CircularProgressIndicator(color: Color(0xFF10B981)),
                        )
                      : suppliersList.isEmpty
                          ? Center(
                              child: Column(
                                mainAxisAlignment: MainAxisAlignment.center,
                                children: [
                                  const Icon(Icons.business_outlined, color: Colors.white38, size: 48),
                                  const SizedBox(height: 8),
                                  Text(
                                    searchCtrl.text.isEmpty
                                        ? 'Контрагенты не найдены в базе'
                                        : 'Контрагент "${searchCtrl.text}" не найден в базе',
                                    style: const TextStyle(color: Colors.white54, fontSize: 13),
                                  ),
                                  const SizedBox(height: 16),
                                  Wrap(
                                    spacing: 10,
                                    runSpacing: 10,
                                    alignment: WrapAlignment.center,
                                    children: [
                                      ElevatedButton.icon(
                                        style: ElevatedButton.styleFrom(
                                          backgroundColor: const Color(0xFF0284C7),
                                          foregroundColor: Colors.white,
                                          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                                        ),
                                        icon: const Icon(Icons.sync_rounded, size: 18),
                                        label: const Text('Обновить с gusar.tj'),
                                        onPressed: () async {
                                          setModalState(() => isSyncing = true);
                                          final sups = await _api.getSuppliers(forceRefresh: true);
                                          if (modalCtx.mounted) {
                                            setModalState(() {
                                              isSyncing = false;
                                              suppliersList = sups;
                                            });
                                          }
                                        },
                                      ),
                                      ElevatedButton.icon(
                                        style: ElevatedButton.styleFrom(
                                          backgroundColor: const Color(0xFF10B981),
                                          foregroundColor: Colors.white,
                                          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                                        ),
                                        icon: const Icon(Icons.add, size: 18),
                                        label: const Text('Создать контрагента'),
                                        onPressed: () {
                                          Navigator.pop(modalCtx);
                                          _showCreateSupplierDialog(initialName: searchCtrl.text.isNotEmpty ? searchCtrl.text : _doc.supplierName);
                                        },
                                      ),
                                    ],
                                  ),
                                ],
                              ),
                            )
                          : ListView.separated(
                              itemCount: suppliersList.length,
                              separatorBuilder: (_, __) => const Divider(color: Colors.white10),
                              itemBuilder: (ctx, i) {
                                final s = suppliersList[i];
                                final isCurrent = _doc.supplierId == s.id;
                                return ListTile(
                                  contentPadding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                                  leading: CircleAvatar(
                                    backgroundColor: isCurrent ? const Color(0xFF10B981) : const Color(0xFF0F172A),
                                    child: Icon(
                                      isCurrent ? Icons.check : Icons.business_rounded,
                                      color: isCurrent ? Colors.white : const Color(0xFF38BDF8),
                                      size: 20,
                                    ),
                                  ),
                                  title: Text(s.name, style: const TextStyle(color: Colors.white, fontSize: 14, fontWeight: FontWeight.w600)),
                                  subtitle: Text(
                                    '${s.inn != null ? 'ИНН: ${s.inn} • ' : ''}${s.contact ?? s.address ?? 'База gusar.tj'}',
                                    style: const TextStyle(color: Colors.white54, fontSize: 12),
                                  ),
                                  trailing: ElevatedButton(
                                    style: ElevatedButton.styleFrom(
                                      backgroundColor: isCurrent ? const Color(0xFF10B981) : const Color(0xFF0284C7),
                                      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                                    ),
                                    onPressed: () async {
                                      final oldName = _doc.supplierName;
                                      setState(() {
                                        _doc.supplierId = s.id;
                                        _doc.supplierName = s.name;
                                      });
                                      await _matcher.saveSupplierAlias(oldName, s.id, s.name);
                                      try {
                                        _matcher.autoMatchDocument(_doc, _api.cachedProducts);
                                      } catch (_) {}
                                      Navigator.pop(modalCtx);
                                      await _saveAndRefresh();
                                      if (mounted) {
                                        TopNotification.showSuccess(context, 'Поставщик привязан: "${s.name}" (ID: ${s.id})!');
                                      }
                                    },
                                    child: Text(isCurrent ? 'Привязан' : 'Связать',
                                        style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 12)),
                                  ),
                                );
                              },
                            ),
                ),
                const SizedBox(height: 8),
                SizedBox(
                  width: double.infinity,
                  child: OutlinedButton.icon(
                    style: OutlinedButton.styleFrom(
                      foregroundColor: const Color(0xFF10B981),
                      side: const BorderSide(color: Color(0xFF10B981)),
                      padding: const EdgeInsets.symmetric(vertical: 12),
                    ),
                    icon: const Icon(Icons.add, size: 18),
                    label: const Text('Создать нового контрагента в gusar.tj', style: TextStyle(fontWeight: FontWeight.bold)),
                    onPressed: () {
                      Navigator.pop(modalCtx);
                      _showCreateSupplierDialog(initialName: _doc.supplierName);
                    },
                  ),
                ),
              ],
            ),
          );
        },
      ),
    );
  }

  // 8. Диалог создания нового контрагента в gusar.tj
  void _showCreateSupplierDialog({String? initialName}) {
    final nameCtrl = TextEditingController(text: initialName ?? _doc.supplierName);
    final phoneCtrl = TextEditingController();
    final innCtrl = TextEditingController();
    final addrCtrl = TextEditingController();

    showDialog(
      context: context,
      builder: (dlgCtx) => AlertDialog(
        backgroundColor: const Color(0xFF1E293B),
        title: const Text('Новый контрагент в gusar.tj', style: TextStyle(color: Colors.white, fontSize: 16)),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: nameCtrl,
                style: const TextStyle(color: Colors.white),
                decoration: const InputDecoration(labelText: 'Наименование организации / ИП', labelStyle: TextStyle(color: Colors.white60)),
              ),
              const SizedBox(height: 8),
              TextField(
                controller: phoneCtrl,
                keyboardType: TextInputType.phone,
                style: const TextStyle(color: Colors.white),
                decoration: const InputDecoration(labelText: 'Телефон / Контакт', labelStyle: TextStyle(color: Colors.white60)),
              ),
              const SizedBox(height: 8),
              TextField(
                controller: innCtrl,
                keyboardType: TextInputType.number,
                style: const TextStyle(color: Colors.white),
                decoration: const InputDecoration(labelText: 'ИНН организации', labelStyle: TextStyle(color: Colors.white60)),
              ),
              const SizedBox(height: 8),
              TextField(
                controller: addrCtrl,
                style: const TextStyle(color: Colors.white),
                decoration: const InputDecoration(labelText: 'Адрес / Город', labelStyle: TextStyle(color: Colors.white60)),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(dlgCtx), child: const Text('Отмена', style: TextStyle(color: Colors.white54))),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFF10B981)),
            onPressed: () async {
              final newName = nameCtrl.text.trim();
              if (newName.isEmpty) return;

              final cleanNewName = newName.toLowerCase().replaceAll(RegExp(r'["«»„“\s]+'), '');
              final cleanInn = innCtrl.text.replaceAll(RegExp(r'\D'), '').trim();
              final cleanPhone = phoneCtrl.text.replaceAll(RegExp(r'\D'), '').trim();

              // ПРАВИЛО ДУБЛИКАТОВ: проверяем наличие контрагента в базе магазина
              Supplier? duplicateSupplier;
              for (final s in _api.cachedSuppliers) {
                final sNameClean = s.name.toLowerCase().replaceAll(RegExp(r'["«»„“\s]+'), '');
                final sInnClean = s.inn?.replaceAll(RegExp(r'\D'), '').trim() ?? '';
                final sPhoneClean = s.contact?.replaceAll(RegExp(r'\D'), '').trim() ?? '';

                if (cleanNewName.isNotEmpty && (cleanNewName == sNameClean || sNameClean.contains(cleanNewName) || cleanNewName.contains(sNameClean))) {
                  duplicateSupplier = s;
                  break;
                }
                if (cleanInn.isNotEmpty && sInnClean.isNotEmpty && cleanInn == sInnClean) {
                  duplicateSupplier = s;
                  break;
                }
                if (cleanPhone.length >= 6 && sPhoneClean.length >= 6 && sPhoneClean.contains(cleanPhone)) {
                  duplicateSupplier = s;
                  break;
                }
              }

              if (duplicateSupplier != null) {
                final Supplier foundDuplicate = duplicateSupplier;
                final useExisting = await showDialog<bool>(
                  context: dlgCtx,
                  builder: (warnCtx) => AlertDialog(
                    backgroundColor: const Color(0xFF1E293B),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                    title: const Row(
                      children: [
                        Icon(Icons.warning_amber_rounded, color: Colors.amberAccent, size: 24),
                        SizedBox(width: 8),
                        Expanded(child: Text('Контрагент уже есть в базе!', style: TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.bold))),
                      ],
                    ),
                    content: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('В базе магазина уже зарегистрирован контрагент:\n\n• "${foundDuplicate.name}" (ID: ${foundDuplicate.id})',
                            style: const TextStyle(color: Colors.white70, fontSize: 13)),
                        if (foundDuplicate.inn != null && foundDuplicate.inn!.isNotEmpty)
                          Padding(
                            padding: const EdgeInsets.only(top: 4),
                            child: Text('• ИНН: ${foundDuplicate.inn}', style: const TextStyle(color: Colors.white54, fontSize: 12)),
                          ),
                        const SizedBox(height: 12),
                        const Text(
                          'Правило учета: создание дубликатов контрагентов запрещено.\nВыбрать существующего контрагента?',
                          style: TextStyle(color: Color(0xFF10B981), fontSize: 12, fontWeight: FontWeight.bold),
                        ),
                      ],
                    ),
                    actions: [
                      TextButton(
                        onPressed: () => Navigator.pop(warnCtx, false),
                        child: const Text('Отмена', style: TextStyle(color: Colors.white54)),
                      ),
                      ElevatedButton(
                        style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFF10B981)),
                        onPressed: () => Navigator.pop(warnCtx, true),
                        child: const Text('Выбрать существующего', style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
                      ),
                    ],
                  ),
                );

                if (useExisting == true) {
                  final oldName = _doc.supplierName;
                  setState(() {
                    _doc.supplierId = foundDuplicate.id;
                    _doc.supplierName = foundDuplicate.name;
                  });
                  await _matcher.saveSupplierAlias(oldName, foundDuplicate.id, foundDuplicate.name);
                  Navigator.pop(dlgCtx);
                  await _saveAndRefresh();
                  if (mounted) {
                    TopNotification.showSuccess(context, 'Выбран существующий контрагент: "${foundDuplicate.name}" (ID: ${foundDuplicate.id})');
                  }
                  return;
                } else {
                  return; // Не разрешаем создавать дубликат
                }
              }

              final created = await _api.createSupplier(
                newName,
                contact: phoneCtrl.text.trim(),
                address: addrCtrl.text.trim(),
                inn: innCtrl.text.trim(),
              );
              if (created != null && created.id > 0 && created.id < 1000000) {
                final oldName = _doc.supplierName;
                setState(() {
                  _doc.supplierId = created.id;
                  _doc.supplierName = created.name;
                });
                await _matcher.saveSupplierAlias(oldName, created.id, created.name);
                Navigator.pop(dlgCtx);
                await _saveAndRefresh();
                if (mounted) {
                  TopNotification.showSuccess(context, 'Контрагент "${created.name}" создан в базе и привязан (ID: ${created.id})!');
                }
              } else {
                setState(() {
                  _doc.supplierId = null;
                  _doc.supplierName = newName;
                });
                Navigator.pop(dlgCtx);
                await _saveAndRefresh();
                if (mounted) {
                  TopNotification.showInfo(context, 'Поставщик сохранён: "$newName" (будет синхронизирован при оприходовании).');
                }
              }
            },
            child: const Text('Создать и выбрать', style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
          ),
        ],
      ),
    );
  }

  void _submitToInventory() async {
    _doc.storeId = _api.currentStoreId;

    if (_doc.unmatchedCount > 0) {
      final autoCreateAndProceed = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          backgroundColor: const Color(0xFF1E293B),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
          title: const Row(
            children: [
              Icon(Icons.auto_awesome, color: Color(0xFF38BDF8), size: 24),
              SizedBox(width: 8),
              Expanded(
                child: Text('Автосоздание товаров', style: TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.bold)),
              ),
            ],
          ),
          content: Text(
            'В накладной есть ${_doc.unmatchedCount} непривязанных товаров.\n\nСоздать карточки товаров автоматически на складе "${_api.currentStoreName}" (ID: ${_api.currentStoreId}) и сразу оприходовать накладную?',
            style: const TextStyle(color: Colors.white70, fontSize: 14),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Привязать вручную', style: TextStyle(color: Colors.white60)),
            ),
            ElevatedButton.icon(
              style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFF10B981)),
              onPressed: () => Navigator.pop(ctx, true),
              icon: const Icon(Icons.check_circle_rounded, color: Colors.white, size: 18),
              label: const Text('Создать и оприходовать', style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
            ),
          ],
        ),
      );

      if (autoCreateAndProceed != true) {
        TopNotification.showWarning(context, 'В накладной есть ${_doc.unmatchedCount} непривязанных товаров. Привяжите их или подтвердите автосоздание.');
        return;
      }
    }

    // Если контрагент не привязан к базе gusar.tj текущего магазина
    if (_doc.supplierId == null) {
      final pickNow = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          backgroundColor: const Color(0xFF1E293B),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
          title: const Row(
            children: [
              Icon(Icons.warning_amber_rounded, color: Color(0xFFEF4444)),
              SizedBox(width: 8),
              Expanded(
                child: Text('Контрагент для магазина', style: TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.bold)),
              ),
            ],
          ),
          content: Text(
            'Поставщик "${_doc.supplierName}" не привязан к базе "${_api.currentStoreName}".\n\nСоздать контрагента на сервере автоматически или выбрать существующего?',
            style: const TextStyle(color: Colors.white70, fontSize: 14),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Выбрать из списка', style: TextStyle(color: Colors.white54)),
            ),
            ElevatedButton(
              style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFF10B981)),
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Создать автоматически', style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
            ),
          ],
        ),
      );

      if (pickNow == false) {
        _showCounterpartyPicker();
        return;
      } else if (pickNow == true) {
        final newSup = await _api.createSupplier(_doc.supplierName);
        if (newSup != null && newSup.id > 0) {
          _doc.supplierId = newSup.id;
          _doc.supplierName = newSup.name;
          await _saveAndRefresh();
        }
      } else {
        return;
      }
    }

    final double totalInvoiceSum = _doc.totalAmount > 0 ? _doc.totalAmount : _doc.calculatedTotal;

    // Модальное окно статуса оплаты: Оплачено (ввод суммы, частичная оплата с расчётом долга) или В долг
    final paymentResult = await showModalBottomSheet<Map<String, dynamic>>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      enableDrag: true,
      builder: (bSheetCtx) => _InvoicePaymentSheet(
        totalInvoiceSum: totalInvoiceSum,
        storeName: _api.currentStoreName,
        supplierName: _doc.supplierName,
        initialInvoiceNumber: _doc.invoiceNumber,
        initialIncomingNumber: _doc.incomingNumber,
        initialPaidAmount: _doc.paidAmount,
        initiallyDebt: _doc.paidAmount <= 0.001 && _doc.status != DocumentStatus.draft,
      ),
    );

    if (paymentResult == null) return;

    final String finalInvoiceNum = (paymentResult['invoice_number'] as String?) ?? '';
    final String finalIncomingNum = (paymentResult['incoming_number'] as String?) ?? '';
    final double finalPaidAmount = (paymentResult['paid_amount'] as double?) ?? 0.0;

    setState(() {
      if (finalInvoiceNum.isNotEmpty) {
        _doc.invoiceNumber = finalInvoiceNum;
      }
      if (finalIncomingNum.isNotEmpty) {
        _doc.incomingNumber = finalIncomingNum;
      }
      _doc.paidAmount = finalPaidAmount;
      // Гарантированная санитаризация: сбрасываем старые псевдо-ID перед отправкой
      if (_doc.supplierId != null && (_doc.supplierId! <= 0 || _doc.supplierId! >= 1000000)) {
        _doc.supplierId = null;
      }
      _isSubmitting = true;
    });

    await _storage.saveInvoice(_doc);
    final success = await _api.submitPurchase(_doc);
    setState(() => _isSubmitting = false);

    if (success) {
      _doc.isSynchronized = true;
      _doc.status = DocumentStatus.synced;
      await _storage.saveInvoice(_doc);
      // Обучаем память шаблона формата накладной этого поставщика для ускорения повторных закупок
      try {
        await InvoiceTemplateService().learnFromInvoice(_doc);
      } catch (_) {}

      if (mounted) {
        showDialog(
          context: context,
          builder: (ctx) => AlertDialog(
            backgroundColor: const Color(0xFF1E293B),
            title: const Row(
              children: [
                Icon(Icons.check_circle, color: Color(0xFF10B981), size: 28),
                SizedBox(width: 10),
                Text('Успешно оприходовано!', style: TextStyle(color: Colors.white)),
              ],
            ),
            content: Builder(
              builder: (c) {
                final double totalDone = _doc.totalAmount > 0 ? _doc.totalAmount : _doc.calculatedTotal;
                final double debtDone = (totalDone - _doc.paidAmount) > 0.001 ? (totalDone - _doc.paidAmount) : 0.0;
                String payInfo;
                if (_doc.paidAmount <= 0.001) {
                  payInfo = '• Оплата: В ДОЛГ (0.00 TJS)\n• Задолженность: ${debtDone.toStringAsFixed(2)} TJS сохранена в базе.';
                } else if (debtDone > 0.001) {
                  payInfo = '• Оплачено сейчас: ${_doc.paidAmount.toStringAsFixed(2)} TJS\n• Остаток в долг: ${debtDone.toStringAsFixed(2)} TJS сохранен в базе.';
                } else {
                  payInfo = '• Оплата: ПОЛНОСТЬЮ ОПЛАЧЕНО (${_doc.paidAmount.toStringAsFixed(2)} TJS). Долг: 0.00 TJS.';
                }

                return Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text('Накладная проведена в системе gusar.tj. Остатки магазина обновлены.', style: TextStyle(color: Colors.white70)),
                    const SizedBox(height: 12),
                    Container(
                      padding: const EdgeInsets.all(10),
                      decoration: BoxDecoration(
                        color: const Color(0xFF0F172A),
                        borderRadius: BorderRadius.circular(10),
                        border: Border.all(color: Colors.white12),
                      ),
                      child: Text(
                        payInfo,
                        style: const TextStyle(color: Color(0xFF38BDF8), fontSize: 13, height: 1.4),
                      ),
                    ),
                  ],
                );
              },
            ),
            actions: [
              ElevatedButton(
                style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFF10B981)),
                onPressed: () {
                  Navigator.pop(ctx);
                  Navigator.pop(context);
                },
                child: const Text('В журнал', style: TextStyle(color: Colors.white)),
              ),
            ],
          ),
        );
      }
    } else {
      // Офлайн-обработка: сохраняем в очередь отложенной отправки
      _doc.isSynchronized = false;
      _doc.status = DocumentStatus.approved;
      await _storage.saveInvoice(_doc);
      // Обучаем память шаблона поставщика и при офлайн-сохранении
      try {
        await InvoiceTemplateService().learnFromInvoice(_doc);
      } catch (_) {}

      if (mounted) {
        showDialog(
          context: context,
          builder: (ctx) => AlertDialog(
            backgroundColor: const Color(0xFF1E293B),
            title: const Row(
              children: [
                Icon(Icons.cloud_off_rounded, color: Colors.orangeAccent, size: 28),
                SizedBox(width: 10),
                Text('Сохранено в офлайн-очередь', style: TextStyle(color: Colors.white, fontSize: 16)),
              ],
            ),
            content: Text(
              _api.lastSubmitError != null
                  ? '${_api.lastSubmitError}\n\nНакладная сохранена локально и будет отправлена автоматически, как только появится связь.'
                  : 'Связь с gusar.tj временно недоступна. Накладная сохранена локально и будет отправлена автоматически, как только появится интернет.',
              style: const TextStyle(color: Colors.white70),
            ),
            actions: [
              ElevatedButton(
                style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFF0284C7)),
                onPressed: () {
                  Navigator.pop(ctx);
                  Navigator.pop(context);
                },
                child: const Text('Понятно, в журнал', style: TextStyle(color: Colors.white)),
              ),
            ],
          ),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final dateFormat = DateFormat('dd.MM.yyyy');

    return Scaffold(
      backgroundColor: const Color(0xFF0F172A),
      appBar: AppBar(
        backgroundColor: const Color(0xFF1E293B),
        elevation: 0,
        title: InkWell(
          onTap: _doc.pagePhotos.isNotEmpty
              ? () => DocumentPhotoViewerDialog.show(
                    context,
                    photoPaths: _doc.pagePhotos,
                    invoiceNumber: _doc.invoiceNumber,
                    supplierName: _doc.supplierName,
                  )
              : null,
          borderRadius: BorderRadius.circular(8),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Flexible(
                child: Text(
                  'Накладная №${_doc.invoiceNumber}',
                  style: const TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.bold),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              if (_doc.pagePhotos.isNotEmpty) ...[
                const SizedBox(width: 6),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                  decoration: BoxDecoration(
                    color: const Color(0xFF3B82F6).withOpacity(0.25),
                    borderRadius: BorderRadius.circular(6),
                    border: Border.all(color: const Color(0xFF3B82F6), width: 0.8),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(Icons.photo_library_outlined, size: 12, color: Color(0xFF60A5FA)),
                      const SizedBox(width: 3),
                      Text('Фото (${_doc.pagePhotos.length})',
                          style: const TextStyle(color: Color(0xFF60A5FA), fontSize: 10, fontWeight: FontWeight.bold)),
                    ],
                  ),
                ),
              ],
            ],
          ),
        ),
        actions: [
          if (_doc.pagePhotos.isNotEmpty)
            IconButton(
              icon: const Icon(Icons.photo_library_outlined, color: Color(0xFF38BDF8)),
              tooltip: 'Открыть фото накладной',
              onPressed: () => DocumentPhotoViewerDialog.show(
                context,
                photoPaths: _doc.pagePhotos,
                invoiceNumber: _doc.invoiceNumber,
                supplierName: _doc.supplierName,
              ),
            ),
          IconButton(
            icon: const Icon(Icons.add, color: Color(0xFF38BDF8)),
            tooltip: 'Добавить строку вручную',
            onPressed: _addNewItem,
          ),
          IconButton(
            icon: const Icon(Icons.assignment_late_outlined, color: Colors.amberAccent),
            tooltip: 'Акт расхождений',
            onPressed: () {
              Navigator.push(
                context,
                MaterialPageRoute(builder: (_) => DiscrepancyScreen(document: _doc)),
              ).then((_) => _saveAndRefresh());
            },
          ),
        ],
      ),
      body: _isSubmitting
          ? const Center(child: CircularProgressIndicator(color: Color(0xFF10B981)))
          : Column(
              children: [
                if (_isDuplicate)
                  Container(
                    width: double.infinity,
                    color: Colors.red.shade900,
                    padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 16),
                    child: const Row(
                      children: [
                        Icon(Icons.warning_amber_rounded, color: Colors.white, size: 20),
                        SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            'Внимание! Накладная с таким номером уже была принята ранее!',
                            style: TextStyle(color: Colors.white, fontSize: 12, fontWeight: FontWeight.bold),
                          ),
                        ),
                      ],
                    ),
                  ),

                // Сводка накладной
                Container(
                  color: const Color(0xFF1E293B),
                  padding: const EdgeInsets.all(14),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      // Интерактивная карточка поставщика с привязкой к базе gusar.tj
                      InkWell(
                        onTap: _showCounterpartyPicker,
                        borderRadius: BorderRadius.circular(12),
                        child: Container(
                          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                          decoration: BoxDecoration(
                            color: const Color(0xFF0F172A),
                            borderRadius: BorderRadius.circular(12),
                            border: Border.all(
                              color: _doc.supplierId != null
                                  ? const Color(0xFF10B981).withOpacity(0.4)
                                  : const Color(0xFFF59E0B).withOpacity(0.4),
                              width: 1.2,
                            ),
                          ),
                          child: Row(
                            children: [
                              Container(
                                padding: const EdgeInsets.all(8),
                                decoration: BoxDecoration(
                                  color: _doc.supplierId != null
                                      ? const Color(0xFF10B981).withOpacity(0.15)
                                      : const Color(0xFFF59E0B).withOpacity(0.15),
                                  borderRadius: BorderRadius.circular(8),
                                ),
                                child: Icon(
                                  _doc.supplierId != null ? Icons.verified_rounded : Icons.business_rounded,
                                  color: _doc.supplierId != null ? const Color(0xFF10B981) : const Color(0xFFF59E0B),
                                  size: 22,
                                ),
                              ),
                              const SizedBox(width: 12),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Row(
                                      children: [
                                        const Text(
                                          'ПОСТАВЩИК',
                                          style: TextStyle(
                                            color: Colors.white54,
                                            fontSize: 10,
                                            fontWeight: FontWeight.bold,
                                            letterSpacing: 0.5,
                                          ),
                                        ),
                                        const SizedBox(width: 6),
                                        Container(
                                          padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1.5),
                                          decoration: BoxDecoration(
                                            color: (_doc.supplierId != null && _doc.supplierId! > 0 && _doc.supplierId! < 1000000)
                                                ? const Color(0xFF10B981).withOpacity(0.2)
                                                : const Color(0xFFF59E0B).withOpacity(0.2),
                                            borderRadius: BorderRadius.circular(4),
                                          ),
                                          child: Text(
                                            (_doc.supplierId != null && _doc.supplierId! > 0 && _doc.supplierId! < 1000000)
                                                ? 'В БАЗЕ GUSAR.TJ (ID: ${_doc.supplierId})'
                                                : 'НЕ ПРИВЯЗАН К БАЗЕ',
                                            style: TextStyle(
                                              color: (_doc.supplierId != null && _doc.supplierId! > 0 && _doc.supplierId! < 1000000) ? const Color(0xFF10B981) : const Color(0xFFF59E0B),
                                              fontSize: 9,
                                              fontWeight: FontWeight.bold,
                                            ),
                                          ),
                                        ),
                                      ],
                                    ),
                                    const SizedBox(height: 2),
                                    Text(
                                      _doc.supplierName,
                                      style: const TextStyle(
                                        color: Colors.white,
                                        fontSize: 14,
                                        fontWeight: FontWeight.bold,
                                      ),
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                  ],
                                ),
                              ),
                              const SizedBox(width: 8),
                              ElevatedButton.icon(
                                style: ElevatedButton.styleFrom(
                                  backgroundColor: _doc.supplierId != null ? const Color(0xFF334155) : const Color(0xFF0284C7),
                                  foregroundColor: Colors.white,
                                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                                  elevation: 0,
                                ),
                                icon: Icon(
                                  _doc.supplierId != null ? Icons.swap_horiz_rounded : Icons.link_rounded,
                                  size: 16,
                                  color: Colors.white,
                                ),
                                label: Text(
                                  _doc.supplierId != null ? 'Сменить' : 'Связать',
                                  style: const TextStyle(fontSize: 11, fontWeight: FontWeight.bold),
                                ),
                                onPressed: _showCounterpartyPicker,
                              ),
                            ],
                          ),
                        ),
                      ),
                      const SizedBox(height: 12),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          InkWell(
                            onTap: _doc.pagePhotos.isNotEmpty
                                ? () => DocumentPhotoViewerDialog.show(
                                      context,
                                      photoPaths: _doc.pagePhotos,
                                      invoiceNumber: _doc.invoiceNumber,
                                      supplierName: _doc.supplierName,
                                    )
                                : null,
                            borderRadius: BorderRadius.circular(6),
                            child: Padding(
                              padding: const EdgeInsets.symmetric(vertical: 2, horizontal: 4),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Row(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      Text(
                                        'Накладная №${_doc.invoiceNumber}',
                                        style: const TextStyle(color: Color(0xFF38BDF8), fontSize: 13, fontWeight: FontWeight.bold),
                                      ),
                                      if (_doc.pagePhotos.isNotEmpty) ...[
                                        const SizedBox(width: 6),
                                        Container(
                                          padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1.5),
                                          decoration: BoxDecoration(
                                            color: const Color(0xFF3B82F6).withOpacity(0.2),
                                            borderRadius: BorderRadius.circular(4),
                                            border: Border.all(color: const Color(0xFF3B82F6).withOpacity(0.5), width: 0.8),
                                          ),
                                          child: Row(
                                            mainAxisSize: MainAxisSize.min,
                                            children: [
                                              const Icon(Icons.photo_library_outlined, size: 11, color: Color(0xFF60A5FA)),
                                              const SizedBox(width: 3),
                                              Text(
                                                'Оригинал (${_doc.pagePhotos.length})',
                                                style: const TextStyle(color: Color(0xFF60A5FA), fontSize: 10, fontWeight: FontWeight.bold),
                                              ),
                                            ],
                                          ),
                                        ),
                                      ],
                                    ],
                                  ),
                                  const SizedBox(height: 2),
                                  Text(
                                    'Дата: ${dateFormat.format(_doc.invoiceDate)} • ${_api.currentStoreName}',
                                    style: const TextStyle(color: Colors.white54, fontSize: 11),
                                  ),
                                ],
                              ),
                            ),
                          ),
                          Column(
                            crossAxisAlignment: CrossAxisAlignment.end,
                            children: [
                              Text('${_doc.totalAmount.toStringAsFixed(2)} TJS',
                                  style: const TextStyle(color: Color(0xFF10B981), fontSize: 18, fontWeight: FontWeight.bold)),
                              if (!_doc.isTotalConsistent)
                                const Text('⚠️ Сумма строк расходится', style: TextStyle(color: Colors.amber, fontSize: 10)),
                            ],
                          ),
                        ],
                      ),
                      const SizedBox(height: 12),
                      Row(
                        children: [
                          if (_doc.isSynchronized) ...[
                            _chip(
                              _doc.isDebt ? '⏳ В долг (0 TJS)' : '💳 Оплачено (${_doc.paidAmount.toStringAsFixed(2)} TJS)',
                              _doc.isDebt ? Colors.redAccent : const Color(0xFF10B981),
                            ),
                            const SizedBox(width: 8),
                          ],
                          _chip('${_doc.matchedCount}/${_doc.items.length} привязано',
                              _doc.unmatchedCount == 0 ? const Color(0xFF10B981) : const Color(0xFFF59E0B)),
                          const SizedBox(width: 8),
                          if (_matcher.rememberedAliasesCount > 0 || _matcher.rememberedCorrectionsCount > 0) ...[
                            _chip('🧠 Память: ${_matcher.rememberedAliasesCount + _matcher.rememberedCorrectionsCount} правил', const Color(0xFF38BDF8)),
                            const SizedBox(width: 8),
                          ],
                          if (_doc.priceSpikeCount > 0) ...[
                            _chip('${_doc.priceSpikeCount} скачок цен', Colors.deepOrange),
                            const SizedBox(width: 8),
                          ],
                          if (_doc.mathErrorCount > 0)
                            _chip('${_doc.mathErrorCount} ошибка счета', Colors.red),
                        ],
                      ),
                    ],
                  ),
                ),

                // Заголовок списка позиций
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text('Позиции накладной (${_doc.items.length}):',
                          style: const TextStyle(color: Colors.white70, fontSize: 13, fontWeight: FontWeight.bold)),
                      InkWell(
                        onTap: _addNewItem,
                        child: const Row(
                          children: [
                            Icon(Icons.add_circle_outline, color: Color(0xFF38BDF8), size: 16),
                            SizedBox(width: 4),
                            Text('Добавить', style: TextStyle(color: Color(0xFF38BDF8), fontSize: 12, fontWeight: FontWeight.bold)),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),

                // Список позиций
                Expanded(
                  child: _doc.items.isEmpty
                      ? Center(
                          child: Column(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              const Icon(Icons.receipt_long_outlined, color: Colors.white38, size: 60),
                              const SizedBox(height: 12),
                              const Text('В накладной пока нет позиций', style: TextStyle(color: Colors.white54)),
                              const SizedBox(height: 12),
                              ElevatedButton.icon(
                                style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFF38BDF8)),
                                icon: const Icon(Icons.add, color: Colors.black),
                                label: const Text('Добавить первую позицию', style: TextStyle(color: Colors.black, fontWeight: FontWeight.bold)),
                                onPressed: _addNewItem,
                              ),
                            ],
                          ),
                        )
                      : ListView.builder(
                          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                          itemCount: _doc.items.length,
                          itemBuilder: (ctx, index) {
                            final item = _doc.items[index];
                            return _itemCard(item, index);
                          },
                        ),
                ),

                // Нижняя панель действий
                Container(
                  color: const Color(0xFF1E293B),
                  padding: const EdgeInsets.all(16),
                  child: Row(
                    children: [
                      if (_doc.unmatchedCount > 0)
                        Expanded(
                          child: ElevatedButton.icon(
                            style: ElevatedButton.styleFrom(
                              backgroundColor: const Color(0xFFF59E0B),
                              padding: const EdgeInsets.symmetric(vertical: 14),
                              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                            ),
                            icon: const Icon(Icons.link, color: Colors.white, size: 20),
                            label: Text('Связать все (${_doc.unmatchedCount})', style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
                            onPressed: () {
                              Navigator.push(
                                context,
                                MaterialPageRoute(builder: (_) => MatchingScreen(document: _doc)),
                              ).then((_) => _saveAndRefresh());
                            },
                          ),
                        )
                      else
                        Expanded(
                          child: ElevatedButton.icon(
                            style: ElevatedButton.styleFrom(
                              backgroundColor: const Color(0xFF0284C7),
                              padding: const EdgeInsets.symmetric(vertical: 14),
                              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                            ),
                            icon: const Icon(Icons.qr_code_scanner, color: Colors.white, size: 20),
                            label: const Text('Сверить коробки', style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
                            onPressed: () {
                              Navigator.push(
                                context,
                                MaterialPageRoute(builder: (_) => BarcodeVerifierScreen(document: _doc)),
                              ).then((_) => _saveAndRefresh());
                            },
                          ),
                        ),

                      const SizedBox(width: 12),

                      Expanded(
                        child: ElevatedButton.icon(
                          style: ElevatedButton.styleFrom(
                            backgroundColor: _doc.isSynchronized ? Colors.grey.shade700 : const Color(0xFF10B981),
                            padding: const EdgeInsets.symmetric(vertical: 14),
                            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                          ),
                          icon: Icon(_doc.isSynchronized ? Icons.check : Icons.arrow_upward_rounded, color: Colors.white, size: 20),
                          label: Text(_doc.isSynchronized ? 'Оприходовано' : 'В остатки',
                              style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
                          onPressed: _doc.isSynchronized ? null : _submitToInventory,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
    );
  }

  Widget _chip(String text, Color color) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: color.withOpacity(0.15),
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: color.withOpacity(0.4)),
      ),
      child: Text(text, style: TextStyle(color: color, fontSize: 11, fontWeight: FontWeight.bold)),
    );
  }

  Widget _itemCard(InvoiceItem item, int index) {
    final isMatched = item.matchedProductId != null;

    return Card(
      color: const Color(0xFF1E293B),
      margin: const EdgeInsets.only(bottom: 10),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(
          color: isMatched
              ? const Color(0xFF10B981).withOpacity(0.35)
              : const Color(0xFFF59E0B).withOpacity(0.4),
          width: 1.2,
        ),
      ),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Верхняя строка: Номер, Название из накладной, Кнопки ред/удал
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                  decoration: BoxDecoration(color: Colors.white10, borderRadius: BorderRadius.circular(4)),
                  child: Text('#${index + 1}', style: const TextStyle(color: Colors.white54, fontSize: 11, fontWeight: FontWeight.bold)),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    item.rawName,
                    style: const TextStyle(color: Colors.white, fontSize: 14, fontWeight: FontWeight.bold),
                  ),
                ),
                IconButton(
                  icon: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
                    decoration: BoxDecoration(
                      color: const Color(0xFF38BDF8).withOpacity(0.15),
                      borderRadius: BorderRadius.circular(6),
                      border: Border.all(color: const Color(0xFF38BDF8).withOpacity(0.4)),
                    ),
                    child: const Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.edit, size: 12, color: Color(0xFF38BDF8)),
                        SizedBox(width: 4),
                        Text('Изменить', style: TextStyle(color: Color(0xFF38BDF8), fontSize: 11, fontWeight: FontWeight.bold)),
                      ],
                    ),
                  ),
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(),
                  tooltip: 'Редактировать товар',
                  onPressed: () => _editItem(item),
                ),
                const SizedBox(width: 8),
                IconButton(
                  icon: const Icon(Icons.delete_outline, color: Colors.redAccent, size: 18),
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(),
                  tooltip: 'Удалить строку',
                  onPressed: () => _deleteItem(item, index),
                ),
              ],
            ),
            const SizedBox(height: 8),

            // Количество и Суммы
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  '${item.quantity} ${item.unit} × ${item.buyPrice.toStringAsFixed(2)} TJS',
                  style: const TextStyle(color: Colors.white70, fontSize: 12),
                ),
                Text(
                  '${item.totalPrice.toStringAsFixed(2)} TJS',
                  style: const TextStyle(color: Color(0xFF10B981), fontSize: 15, fontWeight: FontWeight.bold),
                ),
              ],
            ),

            const Divider(color: Colors.white12, height: 16),

            // Блок статуса связки с базой gusar.tj
            if (isMatched) ...[
              Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: const Color(0xFF10B981).withOpacity(0.08),
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: const Color(0xFF10B981).withOpacity(0.25)),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        const Icon(Icons.check_circle_rounded, color: Color(0xFF10B981), size: 16),
                        const SizedBox(width: 6),
                        Expanded(
                          child: Text(
                            'В базе: ${item.matchedProductName!}',
                            style: const TextStyle(color: Color(0xFF10B981), fontSize: 12, fontWeight: FontWeight.bold),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 4),
                    Row(
                      children: [
                        Text('Штрихкод: ${item.matchedBarcode ?? 'не указан'}',
                            style: const TextStyle(color: Colors.white60, fontSize: 11)),
                        const Spacer(),
                        if (item.currentRetailPrice != null)
                          Text('Розница: ${item.currentRetailPrice!.toStringAsFixed(2)} TJS',
                              style: const TextStyle(color: Color(0xFF38BDF8), fontSize: 11, fontWeight: FontWeight.w600)),
                      ],
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 8),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  TextButton.icon(
                    style: TextButton.styleFrom(padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4)),
                    icon: const Icon(Icons.qr_code_scanner, size: 14, color: Colors.white60),
                    label: const Text('Пикнуть другой', style: TextStyle(color: Colors.white60, fontSize: 11)),
                    onPressed: () => _scanAndBindItem(item),
                  ),
                  const SizedBox(width: 6),
                  TextButton.icon(
                    style: TextButton.styleFrom(padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4)),
                    icon: const Icon(Icons.swap_horiz, size: 14, color: Color(0xFF38BDF8)),
                    label: const Text('Сменить', style: TextStyle(color: Color(0xFF38BDF8), fontSize: 11)),
                    onPressed: () => _showCatalogPicker(item),
                  ),
                  const SizedBox(width: 6),
                  TextButton.icon(
                    style: TextButton.styleFrom(padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4)),
                    icon: const Icon(Icons.link_off, size: 14, color: Colors.redAccent),
                    label: const Text('Отвязать', style: TextStyle(color: Colors.redAccent, fontSize: 11)),
                    onPressed: () => _unlinkItem(item),
                  ),
                ],
              ),
            ] else ...[
              // Товар НЕ привязан: ПРЯМЫЕ КНОПКИ СВЯЗКИ
              Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: const Color(0xFFF59E0B).withOpacity(0.08),
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: const Color(0xFFF59E0B).withOpacity(0.2)),
                ),
                child: const Row(
                  children: [
                    Icon(Icons.help_outline_rounded, color: Color(0xFFF59E0B), size: 16),
                    SizedBox(width: 6),
                    Text('Не привязан к номенклатуре магазина', style: TextStyle(color: Color(0xFFF59E0B), fontSize: 11)),
                  ],
                ),
              ),
              const SizedBox(height: 10),
              // Кнопка 1: СОЗДАТЬ НОВЫЙ ТОВАР (если товара ещё нет в базе)
              ElevatedButton.icon(
                style: ElevatedButton.styleFrom(
                  backgroundColor: const Color(0xFF10B981),
                  foregroundColor: Colors.white,
                  minimumSize: const Size(double.infinity, 42),
                  padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 12),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                  elevation: 2,
                ),
                icon: const Icon(Icons.add_circle_outline_rounded, size: 18),
                label: const Text('Создать новый товар', style: TextStyle(fontSize: 13, fontWeight: FontWeight.bold)),
                onPressed: () => _createNewProductForItem(item),
              ),
              const SizedBox(height: 8),
              Row(
                children: [
                  // Кнопка 2: ПИКНУТЬ ШТРИХКОД
                  Expanded(
                    flex: 3,
                    child: OutlinedButton.icon(
                      style: OutlinedButton.styleFrom(
                        foregroundColor: const Color(0xFF38BDF8),
                        side: const BorderSide(color: Color(0xFF38BDF8)),
                        padding: const EdgeInsets.symmetric(vertical: 9, horizontal: 8),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                      ),
                      icon: const Icon(Icons.qr_code_scanner, size: 16),
                      label: const Text('Пикнуть штрихкод', style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold)),
                      onPressed: () => _scanAndBindItem(item),
                    ),
                  ),
                  const SizedBox(width: 8),
                  // Кнопка 3: ВЫБРАТЬ ИЗ БАЗЫ
                  Expanded(
                    flex: 2,
                    child: OutlinedButton.icon(
                      style: OutlinedButton.styleFrom(
                        foregroundColor: Colors.white70,
                        side: const BorderSide(color: Colors.white24),
                        padding: const EdgeInsets.symmetric(vertical: 9, horizontal: 8),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                      ),
                      icon: const Icon(Icons.search, size: 16),
                      label: const Text('Из базы', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600)),
                      onPressed: () => _showCatalogPicker(item),
                    ),
                  ),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }
}

// -------------------------------------------------------------
// Модальное окно сканирования штрихкода для привязки конкретного товара
// -------------------------------------------------------------
class _ItemBarcodeScannerModal extends StatefulWidget {
  final InvoiceItem item;
  final String supplierName;
  final ApiService api;
  final MatchingService matcher;
  final Function(Product matchedProduct) onBound;

  const _ItemBarcodeScannerModal({
    required this.item,
    required this.supplierName,
    required this.api,
    required this.matcher,
    required this.onBound,
  });

  @override
  State<_ItemBarcodeScannerModal> createState() => _ItemBarcodeScannerModalState();
}

class _ItemBarcodeScannerModalState extends State<_ItemBarcodeScannerModal> {
  final MobileScannerController _scannerCtrl = MobileScannerController();
  final TextEditingController _manualBarcodeCtrl = TextEditingController();
  bool _isSearching = false;
  DateTime? _lastDetected;

  @override
  void dispose() {
    _scannerCtrl.dispose();
    _manualBarcodeCtrl.dispose();
    super.dispose();
  }

  void _onDetect(BarcodeCapture capture) {
    final now = DateTime.now();
    if (_lastDetected != null && now.difference(_lastDetected!).inMilliseconds < 1200) {
      return;
    }

    final barcodes = capture.barcodes;
    if (barcodes.isEmpty || barcodes.first.rawValue == null) return;

    final code = barcodes.first.rawValue!.trim();
    if (code.isNotEmpty) {
      _lastDetected = now;
      _processBarcode(code);
    }
  }

  Future<void> _processBarcode(String barcode) async {
    if (_isSearching) return;
    HapticFeedback.mediumImpact();

    setState(() => _isSearching = true);

    try {
      // 1. Поиск товара в базе магазина на сайте gusar.tj
      final product = await widget.api.findProductByBarcode(barcode);

      if (product != null) {
        // Успешно найден товар на gusar.tj! Привязываем его!
        widget.matcher.applyMatch(widget.item, product, confidence: 1.0);
        await widget.matcher.saveAlias(widget.supplierName, widget.item.rawName, product.id);

        if (mounted) {
          setState(() => _isSearching = false);
          widget.onBound(product);
        }
      } else {
        // Товар со штрихкодом не найден в базе магазина
        if (mounted) {
          setState(() => _isSearching = false);
          _showNotFoundDialog(barcode);
        }
      }
    } catch (e) {
      if (mounted) {
        setState(() => _isSearching = false);
        _showNotFoundDialog(barcode);
      }
    }
  }

  void _showNotFoundDialog(String barcode) async {
    final created = await Navigator.push<Product?>(
      context,
      MaterialPageRoute(
        builder: (_) => AddProductScreen(
          initialName: widget.item.rawName,
          initialCostPrice: widget.item.buyPrice > 0 ? widget.item.buyPrice : null,
          initialBarcode: barcode,
        ),
      ),
    );

    if (created != null) {
      widget.matcher.applyMatch(widget.item, created, confidence: 1.0);
      await widget.matcher.saveAlias(widget.supplierName, widget.item.rawName, created.id);
      widget.onBound(created);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      height: MediaQuery.of(context).size.height * 0.88,
      decoration: const BoxDecoration(
        color: Color(0xFF0F172A),
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      child: Column(
        children: [
          // Шапка
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
            decoration: const BoxDecoration(
              color: Color(0xFF1E293B),
              borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
            ),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text('Связка товара по штрихкоду', style: TextStyle(color: Colors.white54, fontSize: 11)),
                      const SizedBox(height: 2),
                      Text(
                        widget.item.rawName,
                        style: const TextStyle(color: Colors.white, fontSize: 15, fontWeight: FontWeight.bold),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      const SizedBox(height: 2),
                      Text(
                        '${widget.item.quantity} ${widget.item.unit} • Закупка: ${widget.item.buyPrice.toStringAsFixed(2)} TJS',
                        style: const TextStyle(color: Color(0xFF38BDF8), fontSize: 11),
                      ),
                    ],
                  ),
                ),
                IconButton(
                  icon: const Icon(Icons.flash_on, color: Colors.amberAccent),
                  onPressed: () => _scannerCtrl.toggleTorch(),
                  tooltip: 'Вспышка / фонарик',
                ),
                IconButton(
                  icon: const Icon(Icons.close, color: Colors.white),
                  onPressed: () => Navigator.pop(context),
                ),
              ],
            ),
          ),

          // Окно видеоискателя камеры
          Expanded(
            child: Stack(
              alignment: Alignment.center,
              children: [
                MobileScanner(
                  controller: _scannerCtrl,
                  onDetect: _onDetect,
                ),

                // Рамка прицела штрихкода
                Container(
                  width: 280,
                  height: 160,
                  decoration: BoxDecoration(
                    border: Border.all(color: const Color(0xFF10B981), width: 2.5),
                    borderRadius: BorderRadius.circular(16),
                    boxShadow: [
                      BoxShadow(
                        color: const Color(0xFF10B981).withOpacity(0.25),
                        blurRadius: 16,
                        spreadRadius: 2,
                      ),
                    ],
                  ),
                  child: Stack(
                    alignment: Alignment.center,
                    children: [
                      Container(
                        height: 2,
                        width: 250,
                        color: Colors.redAccent.withOpacity(0.8),
                      ),
                    ],
                  ),
                ),

                // Индикатор поиска в базе
                if (_isSearching)
                  Container(
                    color: Colors.black54,
                    child: const Center(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          CircularProgressIndicator(color: Color(0xFF10B981)),
                          SizedBox(height: 12),
                          Text('Поиск товара на gusar.tj...', style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
                        ],
                      ),
                    ),
                  ),

                // Подсказка снизу
                Positioned(
                  bottom: 16,
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                    decoration: BoxDecoration(
                      color: Colors.black.withOpacity(0.75),
                      borderRadius: BorderRadius.circular(20),
                    ),
                    child: const Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.center_focus_strong, color: Color(0xFF10B981), size: 16),
                        SizedBox(width: 8),
                        Text('Наведите рамку на штрихкод товара на коробке',
                            style: TextStyle(color: Colors.white, fontSize: 12, fontWeight: FontWeight.w600)),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),

          // Поле ручного ввода штрихкода
          Container(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 20),
            color: const Color(0xFF1E293B),
            child: Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _manualBarcodeCtrl,
                    keyboardType: TextInputType.number,
                    style: const TextStyle(color: Colors.white, fontSize: 13),
                    decoration: InputDecoration(
                      hintText: 'Или введите цифры штрихкода...',
                      hintStyle: const TextStyle(color: Colors.white38, fontSize: 12),
                      filled: true,
                      fillColor: const Color(0xFF0F172A),
                      contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                      border: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: BorderSide.none),
                    ),
                    onSubmitted: (code) {
                      if (code.trim().isNotEmpty) _processBarcode(code.trim());
                    },
                  ),
                ),
                const SizedBox(width: 8),
                ElevatedButton(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFF0284C7),
                    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                  ),
                  onPressed: () {
                    final code = _manualBarcodeCtrl.text.trim();
                    if (code.isNotEmpty) _processBarcode(code);
                  },
                  child: const Text('Найти', style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _InvoicePaymentSheet extends StatefulWidget {
  final double totalInvoiceSum;
  final String storeName;
  final String supplierName;
  final String initialInvoiceNumber;
  final String initialIncomingNumber;
  final double initialPaidAmount;
  final bool initiallyDebt;

  const _InvoicePaymentSheet({
    required this.totalInvoiceSum,
    required this.storeName,
    required this.supplierName,
    required this.initialInvoiceNumber,
    this.initialIncomingNumber = '',
    required this.initialPaidAmount,
    required this.initiallyDebt,
  });

  @override
  State<_InvoicePaymentSheet> createState() => _InvoicePaymentSheetState();
}

class _InvoicePaymentSheetState extends State<_InvoicePaymentSheet> {
  late bool _isDebtSelected;
  late TextEditingController _payAmountCtrl;
  late TextEditingController _invoiceNumCtrl;
  late TextEditingController _incomingNumCtrl;
  bool _isLoadingNextNum = false;

  @override
  void initState() {
    super.initState();
    _isDebtSelected = widget.initiallyDebt || widget.initialPaidAmount <= 0.001;
    final initialText = _isDebtSelected
        ? ''
        : (widget.initialPaidAmount > 0
            ? widget.initialPaidAmount.toStringAsFixed(2)
            : widget.totalInvoiceSum.toStringAsFixed(2));
    _payAmountCtrl = TextEditingController(text: initialText);
    _invoiceNumCtrl = TextEditingController(text: widget.initialInvoiceNumber);
    _incomingNumCtrl = TextEditingController(
      text: widget.initialIncomingNumber.isNotEmpty
          ? widget.initialIncomingNumber
          : (widget.initialInvoiceNumber != 'б/н' ? widget.initialInvoiceNumber : ''),
    );
    _payAmountCtrl.addListener(_onAmountChanged);

    if (_invoiceNumCtrl.text.isEmpty || _invoiceNumCtrl.text == 'б/н') {
      _reloadNextNumber();
    }
  }

  Future<void> _reloadNextNumber() async {
    setState(() => _isLoadingNextNum = true);
    try {
      final nextSeq = await ApiService().fetchNextSequentialInvoiceNumber();
      if (mounted) {
        setState(() {
          _invoiceNumCtrl.text = nextSeq;
          _isLoadingNextNum = false;
        });
      }
    } catch (_) {
      if (mounted) setState(() => _isLoadingNextNum = false);
    }
  }

  void _onAmountChanged() {
    setState(() {});
  }

  @override
  void dispose() {
    _payAmountCtrl.removeListener(_onAmountChanged);
    _payAmountCtrl.dispose();
    _invoiceNumCtrl.dispose();
    _incomingNumCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final double rawPaid = double.tryParse(_payAmountCtrl.text.replaceAll(',', '.').trim()) ?? 0.0;
    final double currentPaid = _isDebtSelected ? 0.0 : rawPaid;
    final double remainingDebt = (widget.totalInvoiceSum - currentPaid) > 0.001
        ? (widget.totalInvoiceSum - currentPaid)
        : 0.0;

    return Container(
      padding: EdgeInsets.only(
        bottom: MediaQuery.of(context).viewInsets.bottom + 20,
        top: 20,
        left: 20,
        right: 20,
      ),
      decoration: const BoxDecoration(
        color: Color(0xFF1E293B),
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Center(
              child: Container(
                width: 40,
                height: 4,
                decoration: BoxDecoration(
                  color: Colors.white24,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
            const SizedBox(height: 16),
            Row(
              children: [
                Container(
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: const Color(0xFF10B981).withOpacity(0.15),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: const Icon(Icons.receipt_long_rounded, color: Color(0xFF10B981), size: 24),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                        'Оприходование и статус оплаты',
                        style: TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.bold),
                      ),
                      Text(
                        '${widget.storeName} • ${widget.supplierName}',
                        style: const TextStyle(color: Colors.white60, fontSize: 12),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),

            // Итого по накладной
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: const Color(0xFF0F172A),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: Colors.white12),
              ),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  const Text('Итого к оплате:', style: TextStyle(color: Colors.white70, fontSize: 13)),
                  Text(
                    '${widget.totalInvoiceSum.toStringAsFixed(2)} TJS',
                    style: const TextStyle(color: Color(0xFF10B981), fontSize: 16, fontWeight: FontWeight.bold),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 16),

            // 1. Основной номер накладной в системе gusar.tj (последовательный)
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                const Text(
                  '1. Номер в системе gusar.tj (основной):',
                  style: TextStyle(color: Colors.white, fontSize: 13, fontWeight: FontWeight.bold),
                ),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                  decoration: BoxDecoration(
                    color: const Color(0xFF10B981).withOpacity(0.15),
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: const Text('Сквозной порядок gusar.tj', style: TextStyle(color: Color(0xFF10B981), fontSize: 10, fontWeight: FontWeight.w600)),
                ),
              ],
            ),
            const SizedBox(height: 6),
            TextField(
              controller: _invoiceNumCtrl,
              keyboardType: TextInputType.text,
              style: const TextStyle(color: Colors.white, fontSize: 15, fontWeight: FontWeight.bold),
              decoration: InputDecoration(
                filled: true,
                fillColor: const Color(0xFF0F172A),
                prefixIcon: const Icon(Icons.tag_rounded, color: Color(0xFF10B981), size: 20),
                suffixIcon: IconButton(
                  icon: _isLoadingNextNum
                      ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2, color: Color(0xFF10B981)))
                      : const Icon(Icons.sync_rounded, color: Color(0xFF10B981), size: 20),
                  tooltip: 'Получить следующий номер из gusar.tj',
                  onPressed: _isLoadingNextNum ? null : _reloadNextNumber,
                ),
                hintText: 'Например: 46',
                hintStyle: const TextStyle(color: Colors.white38),
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide.none),
                contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
              ),
            ),
            const SizedBox(height: 14),

            // 2. Номер на самой бумажной накладной
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                const Text(
                  '2. Номер на самой накладной (с бумаги):',
                  style: TextStyle(color: Colors.white70, fontSize: 12, fontWeight: FontWeight.w600),
                ),
                const Text('Для информации', style: TextStyle(color: Colors.white38, fontSize: 10)),
              ],
            ),
            const SizedBox(height: 6),
            TextField(
              controller: _incomingNumCtrl,
              style: const TextStyle(color: Colors.white, fontSize: 14),
              decoration: InputDecoration(
                filled: true,
                fillColor: const Color(0xFF0F172A),
                prefixIcon: const Icon(Icons.receipt_long_outlined, color: Color(0xFF38BDF8), size: 18),
                hintText: 'Номер со скана, например: №182-А или б/н',
                hintStyle: const TextStyle(color: Colors.white38),
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide.none),
                contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
              ),
            ),
            const SizedBox(height: 16),

            const Text(
              'Статус расчёта с поставщиком:',
              style: TextStyle(color: Colors.white70, fontSize: 12, fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 8),

            // Переключатель Оплачено / В долг
            Row(
              children: [
                Expanded(
                  child: InkWell(
                    onTap: () {
                      setState(() {
                        _isDebtSelected = false;
                        if (_payAmountCtrl.text.trim().isEmpty) {
                          _payAmountCtrl.text = widget.totalInvoiceSum.toStringAsFixed(2);
                        }
                      });
                    },
                    borderRadius: BorderRadius.circular(12),
                    child: Container(
                      padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 8),
                      decoration: BoxDecoration(
                        color: !_isDebtSelected ? const Color(0xFF10B981).withOpacity(0.18) : const Color(0xFF0F172A),
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(
                          color: !_isDebtSelected ? const Color(0xFF10B981) : Colors.white12,
                          width: !_isDebtSelected ? 1.8 : 1.0,
                        ),
                      ),
                      child: Column(
                        children: [
                          Icon(
                            Icons.check_circle_rounded,
                            color: !_isDebtSelected ? const Color(0xFF10B981) : Colors.white38,
                            size: 24,
                          ),
                          const SizedBox(height: 6),
                          Text(
                            'Оплата (полная/часть)',
                            style: TextStyle(
                              color: !_isDebtSelected ? Colors.white : Colors.white60,
                              fontWeight: FontWeight.bold,
                              fontSize: 12,
                            ),
                            textAlign: TextAlign.center,
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: InkWell(
                    onTap: () {
                      setState(() {
                        _isDebtSelected = true;
                        _payAmountCtrl.clear();
                      });
                    },
                    borderRadius: BorderRadius.circular(12),
                    child: Container(
                      padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 8),
                      decoration: BoxDecoration(
                        color: _isDebtSelected ? const Color(0xFFEF4444).withOpacity(0.18) : const Color(0xFF0F172A),
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(
                          color: _isDebtSelected ? const Color(0xFFEF4444) : Colors.white12,
                          width: _isDebtSelected ? 1.8 : 1.0,
                        ),
                      ),
                      child: Column(
                        children: [
                          Icon(
                            Icons.hourglass_bottom_rounded,
                            color: _isDebtSelected ? const Color(0xFFEF4444) : Colors.white38,
                            size: 24,
                          ),
                          const SizedBox(height: 6),
                          Text(
                            'Взято в долг',
                            style: TextStyle(
                              color: _isDebtSelected ? Colors.white : Colors.white60,
                              fontWeight: FontWeight.bold,
                              fontSize: 12,
                            ),
                            textAlign: TextAlign.center,
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 14),

            if (!_isDebtSelected) ...[
              const Text(
                'Сумма фактической оплаты (сомони):',
                style: TextStyle(color: Colors.white70, fontSize: 12),
              ),
              const SizedBox(height: 6),
              TextField(
                controller: _payAmountCtrl,
                keyboardType: const TextInputType.numberWithOptions(decimal: true),
                style: const TextStyle(color: Colors.white, fontSize: 15, fontWeight: FontWeight.bold),
                decoration: InputDecoration(
                  filled: true,
                  fillColor: const Color(0xFF0F172A),
                  prefixIcon: const Icon(Icons.payments_outlined, color: Color(0xFF10B981)),
                  suffixText: 'сомони',
                  suffixStyle: const TextStyle(color: Colors.white54),
                  hintText: 'Введите сумму оплаты',
                  hintStyle: const TextStyle(color: Colors.white38),
                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide.none),
                ),
              ),
              const SizedBox(height: 8),
              Row(
                children: [
                  InkWell(
                    onTap: () => _payAmountCtrl.text = widget.totalInvoiceSum.toStringAsFixed(2),
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                      decoration: BoxDecoration(
                        color: const Color(0xFF0284C7).withOpacity(0.2),
                        borderRadius: BorderRadius.circular(6),
                        border: Border.all(color: const Color(0xFF0284C7).withOpacity(0.4)),
                      ),
                      child: const Text('100% Вся сумма', style: TextStyle(color: Color(0xFF38BDF8), fontSize: 11, fontWeight: FontWeight.bold)),
                    ),
                  ),
                  const SizedBox(width: 8),
                  InkWell(
                    onTap: () => _payAmountCtrl.text = (widget.totalInvoiceSum / 2).toStringAsFixed(2),
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                      decoration: BoxDecoration(
                        color: Colors.white10,
                        borderRadius: BorderRadius.circular(6),
                      ),
                      child: const Text('50% Половина', style: TextStyle(color: Colors.white70, fontSize: 11)),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),

              // Живой расчет долга при частичной оплате
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: remainingDebt > 0.001
                      ? const Color(0xFFD97706).withOpacity(0.15)
                      : const Color(0xFF10B981).withOpacity(0.12),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(
                    color: remainingDebt > 0.001
                        ? const Color(0xFFF59E0B).withOpacity(0.4)
                        : const Color(0xFF10B981).withOpacity(0.3),
                  ),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        const Text('Оплачено сейчас:', style: TextStyle(color: Colors.white70, fontSize: 12)),
                        Text(
                          '${currentPaid.toStringAsFixed(2)} TJS',
                          style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 13),
                        ),
                      ],
                    ),
                    const SizedBox(height: 4),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Text(
                          remainingDebt > 0.001 ? 'Остаток в долг:' : 'Долг по накладной:',
                          style: TextStyle(
                            color: remainingDebt > 0.001 ? const Color(0xFFFBBF24) : const Color(0xFF34D399),
                            fontSize: 12,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        Text(
                          '${remainingDebt.toStringAsFixed(2)} TJS',
                          style: TextStyle(
                            color: remainingDebt > 0.001 ? const Color(0xFFF87171) : const Color(0xFF34D399),
                            fontWeight: FontWeight.bold,
                            fontSize: 14,
                          ),
                        ),
                      ],
                    ),
                    if (remainingDebt > 0.001) ...[
                      const SizedBox(height: 6),
                      const Text(
                        '⚠️ Частичная оплата: остаток долга автоматически зафиксируется в базе gusar.tj перед контрагентом.',
                        style: TextStyle(color: Color(0xFFFDE68A), fontSize: 11),
                      ),
                    ] else ...[
                      const SizedBox(height: 6),
                      const Text(
                        '✅ Накладная закрыта полностью, задолженность отсутствует.',
                        style: TextStyle(color: Color(0xFFA7F3D0), fontSize: 11),
                      ),
                    ],
                  ],
                ),
              ),
            ] else ...[
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: const Color(0xFFEF4444).withOpacity(0.12),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: const Color(0xFFEF4444).withOpacity(0.3)),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Row(
                      children: [
                        Icon(Icons.hourglass_bottom_rounded, color: Color(0xFFEF4444), size: 20),
                        SizedBox(width: 8),
                        Text(
                          'Товары взяты полностью в долг',
                          style: TextStyle(color: Color(0xFFFCA5A5), fontWeight: FontWeight.bold, fontSize: 13),
                        ),
                      ],
                    ),
                    const SizedBox(height: 6),
                    Text(
                      'Ячейка оплаты: 0.00 TJS.\nВся сумма накладной (${widget.totalInvoiceSum.toStringAsFixed(2)} TJS) запишется в задолженность магазина перед контрагентом.',
                      style: const TextStyle(color: Colors.white70, fontSize: 12),
                    ),
                  ],
                ),
              ),
            ],

            const SizedBox(height: 24),

            // Кнопки
            Row(
              children: [
                Expanded(
                  child: TextButton(
                    onPressed: () => Navigator.pop(context),
                    child: const Text('Отмена', style: TextStyle(color: Colors.white60)),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  flex: 2,
                  child: ElevatedButton(
                    style: ElevatedButton.styleFrom(
                      backgroundColor: const Color(0xFF10B981),
                      padding: const EdgeInsets.symmetric(vertical: 14),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                    ),
                    onPressed: () {
                      final double finalPaid = _isDebtSelected ? 0.0 : currentPaid;
                      final double finalDebt = (widget.totalInvoiceSum - finalPaid) > 0.001
                          ? (widget.totalInvoiceSum - finalPaid)
                          : 0.0;
                      Navigator.pop(context, {
                        'is_debt': _isDebtSelected || finalPaid <= 0.001,
                        'paid_amount': finalPaid,
                        'debt_amount': finalDebt,
                        'invoice_number': _invoiceNumCtrl.text.trim(),
                        'incoming_number': _incomingNumCtrl.text.trim(),
                      });
                    },
                    child: const Text(
                      'Подтвердить и оприходовать',
                      style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 14),
                    ),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}


