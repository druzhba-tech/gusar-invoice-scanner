import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import '../models/invoice_document.dart';
import '../models/invoice_item.dart';
import '../models/product.dart';
import '../services/matching_service.dart';
import '../services/api_service.dart';
import '../utils/top_notification.dart';
import 'add_product_screen.dart';

class MatchingScreen extends StatefulWidget {
  final InvoiceDocument document;

  const MatchingScreen({super.key, required this.document});

  @override
  State<MatchingScreen> createState() => _MatchingScreenState();
}

class _MatchingScreenState extends State<MatchingScreen> {
  final MatchingService _matcher = MatchingService();
  final ApiService _api = ApiService();

  List<Product> _catalog = [];
  bool _isLoading = true;
  int _currentIndex = 0;

  bool _isScannerOpen = false;

  @override
  void initState() {
    super.initState();
    _loadCatalog();
  }

  Future<void> _loadCatalog() async {
    final prods = await _api.getProducts();
    setState(() {
      _catalog = prods;
      _isLoading = false;
    });
  }

  List<InvoiceItem> get _unmatchedItems {
    return widget.document.items.where((i) => i.matchedProductId == null).toList();
  }

  void _onBarcodeScanned(String barcode) async {
    setState(() => _isScannerOpen = false);

    final currentList = _unmatchedItems;
    if (currentList.isEmpty || _currentIndex >= currentList.length) return;

    final currentItem = currentList[_currentIndex];

    final matched = await _matcher.bindItemByBarcode(
      item: currentItem,
      barcode: barcode,
      supplierName: widget.document.supplierName,
      catalog: _catalog,
    );

    if (matched) {
      TopNotification.showSuccess(context, 'Связано по штрихкоду с "${currentItem.matchedProductName}" и сохранено в словарь!');
      setState(() {
        if (_currentIndex >= _unmatchedItems.length && _currentIndex > 0) {
          _currentIndex = _unmatchedItems.length - 1;
        }
      });
    } else {
      _showCreateNewProductDialog(currentItem, barcode);
    }
  }

  void _bindProduct(InvoiceItem item, Product product) async {
    _matcher.applyMatch(item, product, confidence: 1.0);
    await _matcher.saveAlias(widget.document.supplierName, item.rawName, product.id);

    TopNotification.showSuccess(context, 'Связано с "${product.name}". В следующий раз свяжется автоматически!');

    setState(() {
      if (_currentIndex >= _unmatchedItems.length && _currentIndex > 0) {
        _currentIndex = _unmatchedItems.length - 1;
      }
    });
  }

  void _showCreateNewProductDialog(InvoiceItem item, [String? initialBarcode]) async {
    final ProductType suggestedType = (item.unit == 'кг' || item.rawName.toLowerCase().contains('весов'))
        ? ProductType.weight
        : ProductType.barcode;

    final created = await Navigator.push<Product?>(
      context,
      MaterialPageRoute(
        builder: (_) => AddProductScreen(
          initialName: item.rawName,
          initialCostPrice: item.buyPrice,
          initialBarcode: initialBarcode ?? item.matchedBarcode ?? item.barcode,
          initialType: suggestedType,
        ),
      ),
    );

    if (created != null) {
      _catalog.add(created);
      _bindProduct(item, created);
    }
  }

  @override
  Widget build(BuildContext context) {
    final unmatched = _unmatchedItems;

    return Scaffold(
      backgroundColor: const Color(0xFF0F172A),
      appBar: AppBar(
        backgroundColor: const Color(0xFF1E293B),
        title: const Text('Привязка товаров', style: TextStyle(color: Colors.white, fontSize: 16)),
        actions: [
          IconButton(
            icon: const Icon(Icons.qr_code_scanner, color: Color(0xFF10B981)),
            tooltip: 'Сканировать штрихкод коробки',
            onPressed: () => setState(() => _isScannerOpen = !_isScannerOpen),
          ),
        ],
      ),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator(color: Color(0xFF10B981)))
          : unmatched.isEmpty
              ? _allMatchedView()
              : Column(
                  children: [
                    // Видоискатель быстрого сканирования (Scan to Bind)
                    if (_isScannerOpen)
                      SizedBox(
                        height: 200,
                        child: MobileScanner(
                          onDetect: (capture) {
                            final barcodes = capture.barcodes;
                            if (barcodes.isNotEmpty && barcodes.first.rawValue != null) {
                              _onBarcodeScanned(barcodes.first.rawValue!);
                            }
                          },
                        ),
                      ),

                    // Индикатор прогресса
                    LinearProgressIndicator(
                      value: (widget.document.items.length - unmatched.length) / widget.document.items.length,
                      backgroundColor: Colors.white10,
                      valueColor: const AlwaysStoppedAnimation(Color(0xFF10B981)),
                    ),

                    // Карточка текущего непривязанного товара
                    Expanded(
                      child: SingleChildScrollView(
                        padding: const EdgeInsets.all(16),
                        child: _itemMatchingCard(unmatched[_currentIndex], unmatched.length),
                      ),
                    ),
                  ],
                ),
    );
  }

  Widget _itemMatchingCard(InvoiceItem item, int totalRemaining) {
    final candidates = _matcher.getCandidates(item.rawName, _catalog, limit: 3);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Счетчик
        Text(
          'Осталось привязать: $totalRemaining позиций',
          style: const TextStyle(color: Colors.white54, fontSize: 12, fontWeight: FontWeight.bold),
        ),
        const SizedBox(height: 12),

        // Исходная строка из накладной
        Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: const Color(0xFF1E293B),
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: const Color(0xFFF59E0B), width: 1.5),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Row(
                children: [
                  Icon(Icons.receipt_outlined, color: Color(0xFFF59E0B), size: 18),
                  SizedBox(width: 8),
                  Text('ИЗ НАКЛАДНОЙ ПОСТАВЩИКА:', style: TextStyle(color: Color(0xFFF59E0B), fontSize: 11, fontWeight: FontWeight.bold)),
                ],
              ),
              const SizedBox(height: 8),
              Text(item.rawName, style: const TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.bold)),
              const SizedBox(height: 6),
              Text('Количество: ${item.quantity} ${item.unit} • Цена: ${item.buyPrice.toStringAsFixed(2)} TJS',
                  style: const TextStyle(color: Colors.white60, fontSize: 13)),
            ],
          ),
        ),

        const SizedBox(height: 16),

        // Кнопка 1: Создать как новый товар (Главная)
        ElevatedButton.icon(
          style: ElevatedButton.styleFrom(
            backgroundColor: const Color(0xFF10B981),
            minimumSize: const Size(double.infinity, 46),
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
            elevation: 2,
          ),
          icon: const Icon(Icons.add_circle_outline_rounded, color: Colors.white, size: 20),
          label: const Text('Создать как новый товар в каталоге', style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 14)),
          onPressed: () => _showCreateNewProductDialog(item),
        ),

        const SizedBox(height: 10),

        // Кнопка 2: "Пикнуть" штрихкод с коробки
        OutlinedButton.icon(
          style: OutlinedButton.styleFrom(
            side: const BorderSide(color: Color(0xFF0284C7)),
            minimumSize: const Size(double.infinity, 44),
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
          ),
          icon: const Icon(Icons.qr_code_scanner, color: Color(0xFF38BDF8)),
          label: const Text('«Пикнуть» штрихкод с коробки', style: TextStyle(color: Color(0xFF38BDF8), fontWeight: FontWeight.bold)),
          onPressed: () => setState(() => _isScannerOpen = true),
        ),

        const SizedBox(height: 20),

        // AI Подсказки похожих товаров из базы
        const Text('AI ПОДХОДЯЩИЕ ВАРИАНТЫ ИЗ БАЗЫ GUSAR:',
            style: TextStyle(color: Colors.white54, fontSize: 11, fontWeight: FontWeight.bold, letterSpacing: 1.1)),
        const SizedBox(height: 10),

        if (candidates.isEmpty)
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: const Color(0xFF1E293B),
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: Colors.white12),
            ),
            child: Column(
              children: [
                const Icon(Icons.inventory_2_outlined, color: Colors.white38, size: 40),
                const SizedBox(height: 10),
                const Text(
                  'Этого товара нет в базе gusar.tj.\nСоздайте карточку товара прямо сейчас:',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: Colors.white70, fontSize: 13),
                ),
                const SizedBox(height: 14),
                ElevatedButton.icon(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFF10B981),
                    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                  ),
                  icon: const Icon(Icons.add, color: Colors.white),
                  label: const Text('Создать карточку товара', style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
                  onPressed: () => _showCreateNewProductDialog(item),
                ),
              ],
            ),
          )
        else
          ...candidates.map((cand) {
            final percent = (cand.score * 100).toInt();
            return Card(
              color: const Color(0xFF1E293B),
              margin: const EdgeInsets.only(bottom: 10),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
              child: ListTile(
                contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
                title: Text(cand.product.name, style: const TextStyle(color: Colors.white, fontSize: 13, fontWeight: FontWeight.bold)),
                subtitle: Text('Штрихкод: ${cand.product.barcode ?? "—"} • Розница: ${cand.product.price} TJS',
                    style: const TextStyle(color: Colors.white54, fontSize: 11)),
                trailing: ElevatedButton(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFF10B981),
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                  ),
                  onPressed: () => _bindProduct(item, cand.product),
                  child: Text('$percent% Привязать', style: const TextStyle(color: Colors.white, fontSize: 11, fontWeight: FontWeight.bold)),
                ),
              ),
            );
          }),
      ],
    );
  }

  Widget _allMatchedView() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(Icons.check_circle_outline_rounded, color: Color(0xFF10B981), size: 72),
            const SizedBox(height: 16),
            const Text('Все товары сопоставлены!', style: TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.bold)),
            const SizedBox(height: 8),
            const Text('Все позиции накладной успешно связаны с номенклатурой базы gusar.tj',
                textAlign: TextAlign.center, style: TextStyle(color: Colors.white54, fontSize: 13)),
            const SizedBox(height: 24),
            ElevatedButton(
              style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFF10B981), padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12)),
              onPressed: () => Navigator.pop(context),
              child: const Text('Вернуться к накладной', style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
            ),
          ],
        ),
      ),
    );
  }
}
