import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import '../models/invoice_document.dart';
import '../models/invoice_item.dart';

class BarcodeVerifierScreen extends StatefulWidget {
  final InvoiceDocument document;

  const BarcodeVerifierScreen({super.key, required this.document});

  @override
  State<BarcodeVerifierScreen> createState() => _BarcodeVerifierScreenState();
}

class _BarcodeVerifierScreenState extends State<BarcodeVerifierScreen> {
  final MobileScannerController _scannerController = MobileScannerController();
  String? _lastScannedBarcode;
  String _alertMessage = 'Наведите камеру на штрихкод товара';
  Color _alertColor = Colors.white70;

  DateTime? _lastScanTime;

  void _onDetect(BarcodeCapture capture) {
    final now = DateTime.now();
    if (_lastScanTime != null && now.difference(_lastScanTime!).inMilliseconds < 1000) {
      return; // Защита от дребезга сканера
    }

    final barcodes = capture.barcodes;
    if (barcodes.isEmpty || barcodes.first.rawValue == null) return;

    final rawBarcode = barcodes.first.rawValue!.trim();
    _lastScanTime = now;
    _processBarcode(rawBarcode);
  }

  void _processBarcode(String barcode) {
    HapticFeedback.mediumImpact();

    // 1. Проверяем, не весовой ли это штрихкод (префикс 20...29)
    double? variableWeight;
    String cleanBarcode = barcode;

    if (barcode.length == 13 && barcode.startsWith(RegExp(r'2[0-9]'))) {
      // Пример: 20 + 5 знаков артикул + 5 знаков вес (граммы) + 1 контрольный
      final weightGramsStr = barcode.substring(7, 12);
      final grams = double.tryParse(weightGramsStr);
      if (grams != null) {
        variableWeight = grams / 1000.0; // переводим в кг
      }
    }

    // 2. Ищем товар в накладной по штрихкоду
    InvoiceItem? targetItem;
    for (var it in widget.document.items) {
      if (it.matchedBarcode == cleanBarcode || it.barcode == cleanBarcode) {
        targetItem = it;
        break;
      }
    }

    setState(() {
      _lastScannedBarcode = barcode;

      if (targetItem != null) {
        if (variableWeight != null) {
          targetItem.verifiedQuantity += variableWeight;
        } else {
          targetItem.verifiedQuantity += 1.0;
        }

        targetItem.status = ItemStatus.verified;
        _alertColor = const Color(0xFF10B981);
        _alertMessage = '✅ Принято: ${targetItem.matchedProductName ?? targetItem.rawName} (${targetItem.verifiedQuantity}/${targetItem.quantity} ${targetItem.unit})';
      } else {
        // Сигнал тревоги: пересорт или чужой товар
        HapticFeedback.heavyImpact();
        _alertColor = Colors.redAccent;
        _alertMessage = '🚨 ВНИМАНИЕ! Штрихкод $barcode отсутствует в этой накладной!';
      }
    });
  }

  void _showDefectDialog(InvoiceItem item) {
    final defectQtyCtrl = TextEditingController(text: '1');
    final notesCtrl = TextEditingController(text: 'Повреждена упаковка / бой');

    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF1E293B),
        title: const Text('⚠️ Зафиксировать брак / недостачу', style: TextStyle(color: Colors.white, fontSize: 16)),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(item.matchedProductName ?? item.rawName, style: const TextStyle(color: Colors.white70, fontWeight: FontWeight.bold)),
            const SizedBox(height: 12),
            TextField(
              controller: defectQtyCtrl,
              keyboardType: TextInputType.number,
              style: const TextStyle(color: Colors.white),
              decoration: InputDecoration(
                labelText: 'Количество брака (${item.unit})',
                labelStyle: const TextStyle(color: Colors.white54),
              ),
            ),
            const SizedBox(height: 8),
            TextField(
              controller: notesCtrl,
              style: const TextStyle(color: Colors.white),
              decoration: const InputDecoration(
                labelText: 'Причина брака',
                labelStyle: TextStyle(color: Colors.white54),
              ),
            ),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Отмена', style: TextStyle(color: Colors.white54))),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: Colors.redAccent),
            onPressed: () {
              setState(() {
                item.defectiveQuantity = double.tryParse(defectQtyCtrl.text) ?? 1.0;
                item.defectNotes = notesCtrl.text;
                item.status = ItemStatus.discrepancy;
              });
              Navigator.pop(ctx);
            },
            child: const Text('Зафиксировать', style: TextStyle(color: Colors.white)),
          ),
        ],
      ),
    );
  }

  @override
  void dispose() {
    _scannerController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final verifiedCount = widget.document.items.where((i) => i.isFullyVerified).length;

    return Scaffold(
      backgroundColor: const Color(0xFF0F172A),
      appBar: AppBar(
        backgroundColor: const Color(0xFF1E293B),
        title: Text('Сверка: $verifiedCount из ${widget.document.items.length} готово',
            style: const TextStyle(color: Colors.white, fontSize: 15, fontWeight: FontWeight.bold)),
        actions: [
          IconButton(
            icon: const Icon(Icons.flash_on, color: Colors.white),
            onPressed: () => _scannerController.toggleTorch(),
          ),
        ],
      ),
      body: Column(
        children: [
          // 1. Окно потокового сканера
          SizedBox(
            height: 240,
            child: Stack(
              children: [
                MobileScanner(
                  controller: _scannerController,
                  onDetect: _onDetect,
                ),
                Center(
                  child: Container(
                    width: 250,
                    height: 120,
                    decoration: BoxDecoration(
                      border: Border.all(color: _alertColor, width: 2.5),
                      borderRadius: BorderRadius.circular(12),
                    ),
                  ),
                ),
              ],
            ),
          ),

          // 2. Баннер обратной связи (HUD)
          Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
            color: const Color(0xFF1E293B),
            child: Text(
              _alertMessage,
              style: TextStyle(color: _alertColor, fontSize: 13, fontWeight: FontWeight.bold),
              textAlign: TextAlign.center,
              maxLines: 2,
            ),
          ),

          // 3. Список позиций накладной со статусами сверки
          Expanded(
            child: ListView.builder(
              padding: const EdgeInsets.all(12),
              itemCount: widget.document.items.length,
              itemBuilder: (ctx, index) {
                final item = widget.document.items[index];
                final isDone = item.isFullyVerified;
                final hasDefect = item.defectiveQuantity > 0;

                return Card(
                  color: isDone
                      ? const Color(0xFF064E3B)
                      : hasDefect
                          ? const Color(0xFF7F1D1D)
                          : const Color(0xFF1E293B),
                  margin: const EdgeInsets.only(bottom: 8),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                  child: ListTile(
                    contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                    title: Text(
                      item.matchedProductName ?? item.rawName,
                      style: const TextStyle(color: Colors.white, fontSize: 13, fontWeight: FontWeight.bold),
                    ),
                    subtitle: Text(
                      'Факт: ${item.verifiedQuantity} / ${item.quantity} ${item.unit} ${hasDefect ? "• Брак: ${item.defectiveQuantity}" : ""}',
                      style: TextStyle(color: isDone ? Colors.greenAccent : Colors.white60, fontSize: 12),
                    ),
                    trailing: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        if (isDone)
                          const Icon(Icons.check_circle, color: Color(0xFF10B981), size: 24)
                        else
                          IconButton(
                            icon: const Icon(Icons.report_problem_outlined, color: Colors.amberAccent, size: 22),
                            tooltip: 'Отметить брак',
                            onPressed: () => _showDefectDialog(item),
                          ),
                      ],
                    ),
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}
