import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import '../models/invoice_document.dart';
import '../models/invoice_item.dart';
import '../services/api_service.dart';
import '../services/local_storage_service.dart';
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
  final LocalStorageService _storage = LocalStorageService();

  bool _isSubmitting = false;
  bool _isDuplicate = false;

  @override
  void initState() {
    super.initState();
    _doc = widget.document;
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
    setState(() {});
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
          'Товары (${_doc.items.length} поз.) на сумму ${_doc.totalAmount.toStringAsFixed(2)} TJS будут зачислены на баланс магазина gusar.tj.',
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
                // Предупреждение о дубликате
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
                              Text('Дата: ${dateFormat.format(_doc.invoiceDate)}', style: const TextStyle(color: Colors.white54, fontSize: 12)),
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

                      // Статусные чипы
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

                // Список позиций
                Expanded(
                  child: ListView.builder(
                    padding: const EdgeInsets.all(12),
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
                      // Кнопка сопоставления
                      if (_doc.unmatchedCount > 0)
                        Expanded(
                          child: ElevatedButton.icon(
                            style: ElevatedButton.styleFrom(
                              backgroundColor: const Color(0xFFF59E0B),
                              padding: const EdgeInsets.symmetric(vertical: 14),
                              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                            ),
                            icon: const Icon(Icons.link, color: Colors.white, size: 20),
                            label: Text('Связать (${_doc.unmatchedCount})', style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
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

                      // Кнопка оприходования
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
      margin: const EdgeInsets.only(bottom: 8),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(10),
        side: BorderSide(
          color: !item.isMathValid
              ? Colors.red
              : item.hasPriceSpike
                  ? Colors.deepOrange
                  : Colors.white.withOpacity(0.05),
        ),
      ),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      // Название из накладной
                      Text(item.rawName, style: const TextStyle(color: Colors.white, fontSize: 13, fontWeight: FontWeight.bold)),
                      const SizedBox(height: 4),
                      // Привязанный товар из базы
                      if (isMatched)
                        Row(
                          children: [
                            const Icon(Icons.check_circle_rounded, color: Color(0xFF10B981), size: 14),
                            const SizedBox(width: 4),
                            Expanded(
                              child: Text(
                                item.matchedProductName!,
                                style: const TextStyle(color: Color(0xFF10B981), fontSize: 12),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                          ],
                        )
                      else
                        const Row(
                          children: [
                            Icon(Icons.help_outline_rounded, color: Color(0xFFF59E0B), size: 14),
                            SizedBox(width: 4),
                            Text('Не сопоставлен с базой', style: TextStyle(color: Color(0xFFF59E0B), fontSize: 12)),
                          ],
                        ),
                    ],
                  ),
                ),
                // Итоговая сумма
                Text('${item.totalPrice.toStringAsFixed(2)} TJS',
                    style: const TextStyle(color: Colors.white, fontSize: 14, fontWeight: FontWeight.bold)),
              ],
            ),
            const Divider(color: Colors.white12, height: 16),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text('${item.quantity} ${item.unit} × ${item.buyPrice.toStringAsFixed(2)} TJS',
                    style: const TextStyle(color: Colors.white60, fontSize: 12)),
                if (item.hasPriceSpike)
                  Text('⚠️ +${item.priceChangePercent!.toStringAsFixed(0)}% к прошлой цене',
                      style: const TextStyle(color: Colors.deepOrangeAccent, fontSize: 11, fontWeight: FontWeight.bold)),
                if (item.isMarginNegative)
                  const Text('🚨 Отрицательная маржа!',
                      style: TextStyle(color: Colors.redAccent, fontSize: 11, fontWeight: FontWeight.bold)),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
