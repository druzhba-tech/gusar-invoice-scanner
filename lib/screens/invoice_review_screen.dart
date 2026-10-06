import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import '../models/invoice_document.dart';
import '../models/invoice_item.dart';
import '../models/product.dart';
import '../services/api_service.dart';
import '../services/local_storage_service.dart';
import '../services/matching_service.dart';
import 'matching_screen.dart';
import 'barcode_verifier_screen.dart';
import 'discrepancy_screen.dart';

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
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: Row(
                  children: [
                    const Icon(Icons.check_circle, color: Colors.white, size: 20),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text('Связано с: "${matchedProduct.name}" (штрихкод: ${matchedProduct.barcode ?? '-'})'),
                    ),
                  ],
                ),
                backgroundColor: const Color(0xFF10B981),
                duration: const Duration(seconds: 3),
              ),
            );
          }
        },
      ),
    );
  }

  // 2. Выбор товара из базы gusar.tj через поиск
  void _showCatalogPicker(InvoiceItem item) {
    final searchCtrl = TextEditingController();
    List<Product> searchResults = List.from(_api.cachedProducts);

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: const Color(0xFF1E293B),
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (modalCtx) => StatefulBuilder(
        builder: (ctx, setModalState) => Container(
          height: MediaQuery.of(context).size.height * 0.8,
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  const Text('Поиск в базе gusar.tj', style: TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.bold)),
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
                child: searchResults.isEmpty
                    ? Center(
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            const Icon(Icons.inventory_2_outlined, color: Colors.white38, size: 48),
                            const SizedBox(height: 8),
                            const Text('Товары не найдены', style: TextStyle(color: Colors.white54)),
                            const SizedBox(height: 12),
                            ElevatedButton.icon(
                              style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFF10B981)),
                              icon: const Icon(Icons.add, color: Colors.white),
                              label: const Text('Создать такой товар в gusar.tj', style: TextStyle(color: Colors.white)),
                              onPressed: () {
                                Navigator.pop(modalCtx);
                                _showCreateProductDialog(item, initialName: searchCtrl.text.isNotEmpty ? searchCtrl.text : item.rawName);
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
                          return ListTile(
                            contentPadding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                            title: Text(p.name, style: const TextStyle(color: Colors.white, fontSize: 14, fontWeight: FontWeight.w600)),
                            subtitle: Text(
                              'Штрихкод: ${p.barcode ?? 'нет'} • Розница: ${p.price.toStringAsFixed(2)} TJS • Остаток: ${p.stockQuantity}',
                              style: const TextStyle(color: Colors.white54, fontSize: 12),
                            ),
                            trailing: ElevatedButton(
                              style: ElevatedButton.styleFrom(
                                backgroundColor: const Color(0xFF38BDF8),
                                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                              ),
                              onPressed: () async {
                                _matcher.applyMatch(item, p, confidence: 1.0);
                                await _matcher.saveAlias(_doc.supplierName, item.rawName, p.id);
                                Navigator.pop(modalCtx);
                                await _saveAndRefresh();
                                if (mounted) {
                                  ScaffoldMessenger.of(context).showSnackBar(
                                    SnackBar(
                                      content: Text('✅ Позиция привязана к "${p.name}"!'),
                                      backgroundColor: const Color(0xFF10B981),
                                    ),
                                  );
                                }
                              },
                              child: const Text('Связать', style: TextStyle(color: Colors.black, fontWeight: FontWeight.bold, fontSize: 12)),
                            ),
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

  // 3. Создание нового товара на сайте gusar.tj
  void _showCreateProductDialog(InvoiceItem item, {String? initialName, String? initialBarcode}) {
    final nameCtrl = TextEditingController(text: initialName ?? item.rawName);
    final barcodeCtrl = TextEditingController(text: initialBarcode ?? item.barcode ?? '');
    final costCtrl = TextEditingController(text: item.buyPrice.toStringAsFixed(2));
    final retailCtrl = TextEditingController(text: (item.buyPrice * 1.25).toStringAsFixed(2));

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
                controller: retailCtrl,
                keyboardType: TextInputType.number,
                style: const TextStyle(color: Colors.white),
                decoration: const InputDecoration(labelText: 'Розничная цена (продажи), TJS', labelStyle: TextStyle(color: Colors.white60)),
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
              final retail = double.tryParse(retailCtrl.text) ?? (cost * 1.25);

              if (newName.isEmpty) return;

              final created = await _api.createProduct(
                name: newName,
                barcode: newBarcode,
                price: retail,
                costPrice: cost,
              );

              if (created != null) {
                _matcher.applyMatch(item, created, confidence: 1.0);
                await _matcher.saveAlias(_doc.supplierName, item.rawName, created.id);
                Navigator.pop(dlgCtx);
                await _saveAndRefresh();
                if (mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(
                      content: Text('✅ Карточка товара "${created.name}" создана в базе gusar.tj и привязана!'),
                      backgroundColor: const Color(0xFF10B981),
                    ),
                  );
                }
              }
            },
            child: const Text('Создать и привязать', style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
          ),
        ],
      ),
    );
  }

  // 4. Редактирование строки накладной
  void _editItem(InvoiceItem item) {
    final nameCtrl = TextEditingController(text: item.rawName);
    final qtyCtrl = TextEditingController(text: item.quantity.toString());
    final unitCtrl = TextEditingController(text: item.unit);
    final priceCtrl = TextEditingController(text: item.buyPrice.toStringAsFixed(2));

    showDialog(
      context: context,
      builder: (dlgCtx) => AlertDialog(
        backgroundColor: const Color(0xFF1E293B),
        title: const Text('Редактировать строку', style: TextStyle(color: Colors.white, fontSize: 16)),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(controller: nameCtrl, style: const TextStyle(color: Colors.white), decoration: const InputDecoration(labelText: 'Наименование', labelStyle: TextStyle(color: Colors.white60))),
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(child: TextField(controller: qtyCtrl, keyboardType: TextInputType.number, style: const TextStyle(color: Colors.white), decoration: const InputDecoration(labelText: 'Кол-во', labelStyle: TextStyle(color: Colors.white60)))),
                const SizedBox(width: 8),
                SizedBox(width: 60, child: TextField(controller: unitCtrl, style: const TextStyle(color: Colors.white), decoration: const InputDecoration(labelText: 'Ед.', labelStyle: TextStyle(color: Colors.white60)))),
                const SizedBox(width: 8),
                Expanded(child: TextField(controller: priceCtrl, keyboardType: TextInputType.number, style: const TextStyle(color: Colors.white), decoration: const InputDecoration(labelText: 'Цена, TJS', labelStyle: TextStyle(color: Colors.white60)))),
              ],
            ),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(dlgCtx), child: const Text('Отмена', style: TextStyle(color: Colors.white54))),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFF38BDF8)),
            onPressed: () {
              final newName = nameCtrl.text.trim();
              final newQty = double.tryParse(qtyCtrl.text) ?? item.quantity;
              final newPrice = double.tryParse(priceCtrl.text) ?? item.buyPrice;
              if (newName.isNotEmpty) {
                item.rawName = newName;
                item.quantity = newQty;
                item.unit = unitCtrl.text.trim();
                item.buyPrice = newPrice;
                item.totalPrice = newQty * newPrice;
                _doc.totalAmount = _doc.items.fold(0.0, (sum, i) => sum + i.totalPrice);
                Navigator.pop(dlgCtx);
                _saveAndRefresh();
              }
            },
            child: const Text('Сохранить', style: TextStyle(color: Colors.black, fontWeight: FontWeight.bold)),
          ),
        ],
      ),
    );
  }

  // 5. Удаление строки накладной (например, лишний распознанный мусор)
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

  void _submitToInventory() async {
    if (_doc.unmatchedCount > 0) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Внимание! Есть ${_doc.unmatchedCount} непривязанных товаров. Привяжите их перед оприходованием.'),
          backgroundColor: const Color(0xFFF59E0B),
        ),
      );
      return;
    }

    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF1E293B),
        title: const Text('Оприходовать в остатки?', style: TextStyle(color: Colors.white)),
        content: Text(
          'Товары (${_doc.items.length} поз.) на сумму ${_doc.totalAmount.toStringAsFixed(2)} TJS будут зачислены на баланс ${_api.currentStoreName} в системе gusar.tj.',
          style: const TextStyle(color: Colors.white70),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Отмена', style: TextStyle(color: Colors.white54))),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFF10B981)),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Подтвердить', style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
          ),
        ],
      ),
    );

    if (confirm != true) return;

    setState(() => _isSubmitting = true);
    final success = await _api.submitPurchase(_doc);
    setState(() => _isSubmitting = false);

    if (success) {
      _doc.isSynchronized = true;
      _doc.status = DocumentStatus.synced;
      await _storage.saveInvoice(_doc);

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
            content: const Text('Накладная проведена в системе gusar.tj. Остатки магазина обновлены.', style: TextStyle(color: Colors.white70)),
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
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Ошибка отправки в gusar.tj. Проверьте интернет или настройки токена.'), backgroundColor: Colors.red),
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
        title: Text('Накладная №${_doc.invoiceNumber}', style: const TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.bold)),
        actions: [
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
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    children: [
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(_doc.supplierName, style: const TextStyle(color: Colors.white, fontSize: 15, fontWeight: FontWeight.bold)),
                              const SizedBox(height: 2),
                              Text('Дата: ${dateFormat.format(_doc.invoiceDate)} • ${_api.currentStoreName}',
                                  style: const TextStyle(color: Colors.white54, fontSize: 11)),
                            ],
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
                          _chip('${_doc.matchedCount}/${_doc.items.length} привязано',
                              _doc.unmatchedCount == 0 ? const Color(0xFF10B981) : const Color(0xFFF59E0B)),
                          const SizedBox(width: 8),
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
                  icon: const Icon(Icons.edit_outlined, color: Colors.white54, size: 18),
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(),
                  tooltip: 'Редактировать',
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
                  const SizedBox(width: 8),
                  TextButton.icon(
                    style: TextButton.styleFrom(padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4)),
                    icon: const Icon(Icons.swap_horiz, size: 14, color: Color(0xFF38BDF8)),
                    label: const Text('Сменить', style: TextStyle(color: Color(0xFF38BDF8), fontSize: 11)),
                    onPressed: () => _showCatalogPicker(item),
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
              Row(
                children: [
                  // Кнопка 1: ПИКНУТЬ ШТРИХКОД (Главная кнопка)
                  Expanded(
                    flex: 3,
                    child: ElevatedButton.icon(
                      style: ElevatedButton.styleFrom(
                        backgroundColor: const Color(0xFF0284C7),
                        foregroundColor: Colors.white,
                        padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 8),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                        elevation: 2,
                      ),
                      icon: const Icon(Icons.qr_code_scanner, size: 16),
                      label: const Text('Пикнуть штрихкод', style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold)),
                      onPressed: () => _scanAndBindItem(item),
                    ),
                  ),
                  const SizedBox(width: 8),
                  // Кнопка 2: ВЫБРАТЬ ИЗ БАЗЫ GUSAR.TJ
                  Expanded(
                    flex: 2,
                    child: OutlinedButton.icon(
                      style: OutlinedButton.styleFrom(
                        foregroundColor: const Color(0xFF38BDF8),
                        side: const BorderSide(color: Color(0xFF38BDF8)),
                        padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 8),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                      ),
                      icon: const Icon(Icons.search, size: 16),
                      label: const Text('Из базы', style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold)),
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

  void _showNotFoundDialog(String barcode) {
    final nameCtrl = TextEditingController(text: widget.item.rawName);
    final costCtrl = TextEditingController(text: widget.item.buyPrice.toStringAsFixed(2));
    final retailCtrl = TextEditingController(text: (widget.item.buyPrice * 1.25).toStringAsFixed(2));

    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (dlgCtx) => AlertDialog(
        backgroundColor: const Color(0xFF1E293B),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: Row(
          children: [
            const Icon(Icons.info_outline, color: Color(0xFFF59E0B), size: 24),
            const SizedBox(width: 8),
            const Expanded(child: Text('Товар не найден на gusar.tj', style: TextStyle(color: Colors.white, fontSize: 15))),
          ],
        ),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Штрихкод: $barcode', style: const TextStyle(color: Color(0xFF38BDF8), fontWeight: FontWeight.bold, fontSize: 13)),
              const SizedBox(height: 6),
              Text(
                'Товар с таким штрихкодом отсутствует в каталоге ${widget.api.currentStoreName}. Создать его прямо сейчас?',
                style: const TextStyle(color: Colors.white70, fontSize: 12),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: nameCtrl,
                style: const TextStyle(color: Colors.white, fontSize: 13),
                decoration: const InputDecoration(labelText: 'Название товара', labelStyle: TextStyle(color: Colors.white60)),
              ),
              const SizedBox(height: 8),
              Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: costCtrl,
                      keyboardType: TextInputType.number,
                      style: const TextStyle(color: Colors.white, fontSize: 13),
                      decoration: const InputDecoration(labelText: 'Закупка, TJS', labelStyle: TextStyle(color: Colors.white60)),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: TextField(
                      controller: retailCtrl,
                      keyboardType: TextInputType.number,
                      style: const TextStyle(color: Colors.white, fontSize: 13),
                      decoration: const InputDecoration(labelText: 'Розница, TJS', labelStyle: TextStyle(color: Colors.white60)),
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
            child: const Text('Сканировать снова', style: TextStyle(color: Colors.white54)),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFF10B981)),
            onPressed: () async {
              final newName = nameCtrl.text.trim();
              final cost = double.tryParse(costCtrl.text) ?? widget.item.buyPrice;
              final retail = double.tryParse(retailCtrl.text) ?? (cost * 1.25);

              if (newName.isEmpty) return;

              final created = await widget.api.createProduct(
                name: newName,
                barcode: barcode,
                price: retail,
                costPrice: cost,
              );

              if (created != null) {
                widget.matcher.applyMatch(widget.item, created, confidence: 1.0);
                await widget.matcher.saveAlias(widget.supplierName, widget.item.rawName, created.id);

                Navigator.pop(dlgCtx);
                widget.onBound(created);
              }
            },
            child: const Text('Создать в gusar.tj', style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
          ),
        ],
      ),
    );
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

