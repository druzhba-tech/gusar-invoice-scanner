import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';
import 'package:share_plus/share_plus.dart';
import 'package:url_launcher/url_launcher.dart';

import '../models/invoice_document.dart';
import '../models/invoice_item.dart';
import '../models/supplier.dart';
import '../services/api_service.dart';
import '../services/local_storage_service.dart';
import '../utils/top_notification.dart';
import '../widgets/document_photo_viewer_dialog.dart';
import '../widgets/supplier_payment_sheet.dart';

class InvoiceDisplayItem {
  final int? purchaseId;
  final String? localDocId;
  final String invoiceNumber;
  final String incomingNumber;
  final DateTime date;
  final double totalAmount;
  final double paidAmount;
  final double debtAmount;
  final String status; // 'paid', 'debt', 'partial'
  final List<String> photos;
  final List<InvoiceItem> items;
  final String? notes;

  InvoiceDisplayItem({
    this.purchaseId,
    this.localDocId,
    required this.invoiceNumber,
    required this.incomingNumber,
    required this.date,
    required this.totalAmount,
    required this.paidAmount,
    required this.debtAmount,
    required this.status,
    required this.photos,
    required this.items,
    this.notes,
  });
}

class SupplierInvoicesScreen extends StatefulWidget {
  final Supplier supplier;

  const SupplierInvoicesScreen({
    super.key,
    required this.supplier,
  });

  @override
  State<SupplierInvoicesScreen> createState() => _SupplierInvoicesScreenState();
}

class _SupplierInvoicesScreenState extends State<SupplierInvoicesScreen> {
  final ApiService _api = ApiService();
  final LocalStorageService _storage = LocalStorageService();

  late Supplier _currentSupplier;
  List<InvoiceDisplayItem> _invoices = [];
  bool _isLoading = true;
  String _searchQuery = '';
  final TextEditingController _searchCtrl = TextEditingController();

  @override
  void initState() {
    super.initState();
    _currentSupplier = widget.supplier;
    _loadInvoices();
  }

  @override
  void dispose() {
    _searchCtrl.dispose();
    super.dispose();
  }

  Future<void> _loadInvoices() async {
    setState(() => _isLoading = true);

    try {
      // 1. Обновляем данные поставщика (актуальный долг из базы gusar.tj)
      final allSups = await _api.getSuppliers(forceRefresh: true);
      final refreshed = allSups.firstWhere(
        (s) => s.id == _currentSupplier.id,
        orElse: () => _currentSupplier,
      );
      _currentSupplier = refreshed;
    } catch (_) {}

    try {
      // 2. Получаем накладные с сервера gusar.tj
      final serverPurchases = await _api.fetchSupplierPurchases(_currentSupplier.id);

      // 3. Получаем локальные накладные для привязки фото оригиналов
      final localInvoices = await _storage.getLocalInvoices();
      final supplierLocals = localInvoices.where((doc) {
        if (doc.supplierId != null && doc.supplierId == _currentSupplier.id) return true;
        final cleanDocSup = doc.supplierName.trim().toLowerCase();
        final cleanTarget = _currentSupplier.name.trim().toLowerCase();
        return cleanDocSup.isNotEmpty && (cleanDocSup.contains(cleanTarget) || cleanTarget.contains(cleanDocSup));
      }).toList();

      final Map<String, InvoiceDocument> localMapByNumber = {};
      for (final doc in supplierLocals) {
        final key = doc.invoiceNumber.trim().toLowerCase();
        if (key.isNotEmpty) localMapByNumber[key] = doc;
        final inKey = doc.incomingNumber.trim().toLowerCase();
        if (inKey.isNotEmpty) localMapByNumber[inKey] = doc;
      }

      final List<InvoiceDisplayItem> combined = [];
      final Set<String> matchedLocalIds = {};

      // Обрабатываем накладные с сервера gusar.tj
      for (final p in serverPurchases) {
        final pId = p['id'] is int ? p['id'] as int : int.tryParse(p['id']?.toString() ?? '0');
        final invNum = (p['invoice_number'] ?? p['invoice_no'] ?? p['number'] ?? 'б/н').toString();
        final incNum = (p['incoming_invoice_number'] ?? p['incoming_number'] ?? '').toString();

        final dateStr = (p['purchase_date'] ?? p['date'] ?? p['created_at'])?.toString() ?? '';
        final date = DateTime.tryParse(dateStr) ?? DateTime.now();

        final rawTotal = p['total_amount'] ?? p['total'] ?? p['amount'] ?? 0.0;
        final total = (rawTotal is num) ? rawTotal.toDouble() : double.tryParse(rawTotal.toString()) ?? 0.0;

        final rawPaid = p['paid_amount'] ?? p['amount_paid'] ?? 0.0;
        final paid = (rawPaid is num) ? rawPaid.toDouble() : double.tryParse(rawPaid.toString()) ?? 0.0;

        final rawDebt = p['debt_amount'] ?? p['remaining_amount'] ?? p['unpaid_amount'] ?? (total - paid);
        double debt = (rawDebt is num) ? rawDebt.toDouble() : double.tryParse(rawDebt.toString()) ?? (total - paid);
        if (debt < 0) debt = 0.0;

        final statusStr = p['payment_status']?.toString() ?? (debt > 0.01 ? (paid > 0.01 ? 'partial' : 'debt') : 'paid');

        // Ищем локальные фото накладной
        List<String> photos = [];
        List<InvoiceItem> itemsList = [];
        String? matchedLocalDocId;

        final localMatch = localMapByNumber[invNum.toLowerCase()] ?? (incNum.isNotEmpty ? localMapByNumber[incNum.toLowerCase()] : null);
        if (localMatch != null) {
          photos = List<String>.from(localMatch.pagePhotos);
          itemsList = List<InvoiceItem>.from(localMatch.items);
          matchedLocalDocId = localMatch.id;
          matchedLocalIds.add(localMatch.id);
        }

        // Если фото есть на сервере
        if (photos.isEmpty && p['receipt_url'] != null) {
          photos.add(p['receipt_url'].toString());
        }
        if (photos.isEmpty && p['photo_url'] != null) {
          photos.add(p['photo_url'].toString());
        }

        // Если на сервере есть список товаров
        if (itemsList.isEmpty && p['items'] is List) {
          for (final rawItem in (p['items'] as List)) {
            if (rawItem is Map<String, dynamic>) {
              final rawQty = rawItem['quantity'] ?? rawItem['qty'] ?? 1.0;
              final qty = (rawQty is num) ? rawQty.toDouble() : double.tryParse(rawQty.toString()) ?? 1.0;
              final rawBuy = rawItem['buy_price'] ?? rawItem['price'] ?? rawItem['cost_price'] ?? 0.0;
              final buy = (rawBuy is num) ? rawBuy.toDouble() : double.tryParse(rawBuy.toString()) ?? 0.0;
              final rawName = rawItem['name'] ?? rawItem['product_name'] ?? 'Товар';

              itemsList.add(InvoiceItem(
                id: (rawItem['id'] ?? itemsList.length).toString(),
                rawName: rawName.toString(),
                quantity: qty,
                buyPrice: buy,
                totalPrice: qty * buy,
                unit: (rawItem['unit'] ?? 'шт').toString(),
              ));
            }
          }
        }

        combined.add(InvoiceDisplayItem(
          purchaseId: pId,
          localDocId: matchedLocalDocId,
          invoiceNumber: invNum,
          incomingNumber: incNum,
          date: date,
          totalAmount: total,
          paidAmount: paid,
          debtAmount: debt,
          status: statusStr,
          photos: photos,
          items: itemsList,
          notes: p['notes']?.toString(),
        ));
      }

      // Добавляем оставшиеся локальные накладные, которые ещё не появились на сервере
      for (final doc in supplierLocals) {
        if (!matchedLocalIds.contains(doc.id)) {
          final debt = (doc.totalAmount - doc.paidAmount) > 0 ? (doc.totalAmount - doc.paidAmount) : 0.0;
          combined.add(InvoiceDisplayItem(
            localDocId: doc.id,
            invoiceNumber: doc.invoiceNumber,
            incomingNumber: doc.incomingNumber,
            date: doc.invoiceDate,
            totalAmount: doc.totalAmount,
            paidAmount: doc.paidAmount,
            debtAmount: debt,
            status: debt > 0.01 ? (doc.paidAmount > 0.01 ? 'partial' : 'debt') : 'paid',
            photos: List<String>.from(doc.pagePhotos),
            items: List<InvoiceItem>.from(doc.items),
          ));
        }
      }

      // Строгая хронологическая сортировка: сверху САМЫЕ НОВЫЕ, снизу старые
      combined.sort((a, b) => b.date.compareTo(a.date));

      if (mounted) {
        setState(() {
          _invoices = combined;
          _isLoading = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() => _isLoading = false);
        TopNotification.showError(context, 'Ошибка загрузки накладных: $e');
      }
    }
  }

  void _openPaymentSheet({int? purchaseId, String? invoiceNumber, double? debt}) {
    SupplierPaymentSheet.show(
      context,
      initialSupplier: _currentSupplier,
      purchaseId: purchaseId,
      invoiceNumber: invoiceNumber,
      initialDebt: debt ?? _currentSupplier.balance,
      onPaymentSuccess: () {
        _loadInvoices();
      },
    );
  }

  void _shareReconciliation() {
    final dateFormat = DateFormat('dd.MM.yyyy');
    final totalInvoices = _invoices.length;
    final totalSum = _invoices.fold<double>(0.0, (acc, i) => acc + i.totalAmount);
    final totalPaid = _invoices.fold<double>(0.0, (acc, i) => acc + i.paidAmount);
    final currentDebt = _currentSupplier.balance;

    final buffer = StringBuffer();
    buffer.writeln('📋 АКТ СВЕРКИ ВЗАИМОРАСЧЁТОВ');
    buffer.writeln('Магазин Gusar (gusar.tj)');
    buffer.writeln('Поставщик: ${_currentSupplier.name}');
    if (_currentSupplier.inn != null && _currentSupplier.inn!.isNotEmpty) {
      buffer.writeln('ИНН: ${_currentSupplier.inn}');
    }
    buffer.writeln('Дата формирования: ${dateFormat.format(DateTime.now())}');
    buffer.writeln('--------------------------------');
    buffer.writeln('Всего накладных: $totalInvoices');
    buffer.writeln('Общая сумма поставок: ${totalSum.toStringAsFixed(2)} TJS');
    buffer.writeln('Всего оплачено: ${totalPaid.toStringAsFixed(2)} TJS');
    buffer.writeln('ОСТАТОК ДОЛГА К ВЫПЛАТЕ: ${currentDebt.toStringAsFixed(2)} TJS');
    buffer.writeln('--------------------------------');
    buffer.writeln('Последние накладные:');

    final recent = _invoices.take(5).toList();
    for (final inv in recent) {
      final statusText = inv.debtAmount > 0.01 ? 'ДОЛГ: ${inv.debtAmount.toStringAsFixed(2)} TJS' : 'ОПЛАЧЕНО';
      buffer.writeln('• ${dateFormat.format(inv.date)} | №${inv.invoiceNumber} | ${inv.totalAmount.toStringAsFixed(2)} TJS ($statusText)');
    }

    Share.share(buffer.toString(), subject: 'Акт сверки с ${_currentSupplier.name}');
  }

  void _callSupplier() async {
    final phone = _currentSupplier.contact;
    if (phone == null || phone.trim().isEmpty) {
      TopNotification.show(context, message: 'У поставщика не указан номер телефона');
      return;
    }
    final cleanPhone = phone.replaceAll(RegExp(r'[^0-9+]'), '');
    final uri = Uri.parse('tel:$cleanPhone');
    if (await canLaunchUrl(uri)) {
      await launchUrl(uri);
    } else {
      Clipboard.setData(ClipboardData(text: cleanPhone));
      if (mounted) {
        TopNotification.showSuccess(context, 'Номер $cleanPhone скопирован в буфер обмена');
      }
    }
  }

  void _showInvoiceDetails(InvoiceDisplayItem item) {
    final dateFormat = DateFormat('dd.MM.yyyy HH:mm');
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (ctx) => Container(
        constraints: BoxConstraints(maxHeight: MediaQuery.of(context).size.height * 0.85),
        decoration: const BoxDecoration(
          color: Color(0xFF0F172A),
          borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
          border: Border(top: BorderSide(color: Color(0xFF334155), width: 1.5)),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              margin: const EdgeInsets.only(top: 10, bottom: 6),
              width: 40,
              height: 4,
              decoration: BoxDecoration(color: Colors.white24, borderRadius: BorderRadius.circular(2)),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
              child: Row(
                children: [
                  Container(
                    padding: const EdgeInsets.all(8),
                    decoration: BoxDecoration(
                      color: const Color(0xFF38BDF8).withOpacity(0.18),
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: const Icon(Icons.receipt_long_rounded, color: Color(0xFF38BDF8), size: 22),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Накладная №${item.invoiceNumber}',
                          style: const TextStyle(color: Colors.white, fontSize: 17, fontWeight: FontWeight.bold),
                        ),
                        Text(
                          dateFormat.format(item.date),
                          style: const TextStyle(color: Colors.white54, fontSize: 12),
                        ),
                      ],
                    ),
                  ),
                  IconButton(
                    icon: const Icon(Icons.close_rounded, color: Colors.white54),
                    onPressed: () => Navigator.pop(ctx),
                  ),
                ],
              ),
            ),
            const Divider(color: Color(0xFF1E293B), height: 1),

            Flexible(
              child: SingleChildScrollView(
                padding: const EdgeInsets.all(20),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // Сводка по суммам
                    Container(
                      padding: const EdgeInsets.all(14),
                      decoration: BoxDecoration(
                        color: const Color(0xFF1E293B),
                        borderRadius: BorderRadius.circular(14),
                        border: Border.all(color: const Color(0xFF334155)),
                      ),
                      child: Column(
                        children: [
                          Row(
                            mainAxisAlignment: MainAxisAlignment.spaceBetween,
                            children: [
                              const Text('Общая сумма накладной:', style: TextStyle(color: Colors.white70, fontSize: 13)),
                              Text(
                                '${item.totalAmount.toStringAsFixed(2)} TJS',
                                style: const TextStyle(color: Colors.white, fontSize: 15, fontWeight: FontWeight.bold),
                              ),
                            ],
                          ),
                          const SizedBox(height: 8),
                          Row(
                            mainAxisAlignment: MainAxisAlignment.spaceBetween,
                            children: [
                              const Text('Оплачено:', style: TextStyle(color: Colors.white70, fontSize: 13)),
                              Text(
                                '${item.paidAmount.toStringAsFixed(2)} TJS',
                                style: const TextStyle(color: Color(0xFF10B981), fontSize: 14, fontWeight: FontWeight.bold),
                              ),
                            ],
                          ),
                          const SizedBox(height: 8),
                          Row(
                            mainAxisAlignment: MainAxisAlignment.spaceBetween,
                            children: [
                              const Text('Остаток долга:', style: TextStyle(color: Colors.white70, fontSize: 13)),
                              Text(
                                '${item.debtAmount.toStringAsFixed(2)} TJS',
                                style: TextStyle(
                                  color: item.debtAmount > 0.01 ? const Color(0xFFEF4444) : const Color(0xFF10B981),
                                  fontSize: 16,
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),

                    const SizedBox(height: 16),

                    // Кнопка просмотра оригинального фото накладной
                    if (item.photos.isNotEmpty) ...[
                      InkWell(
                        borderRadius: BorderRadius.circular(12),
                        onTap: () {
                          DocumentPhotoViewerDialog.show(
                            context,
                            photoPaths: item.photos,
                            invoiceNumber: item.invoiceNumber,
                            supplierName: _currentSupplier.name,
                          );
                        },
                        child: Container(
                          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                          decoration: BoxDecoration(
                            gradient: LinearGradient(
                              colors: [
                                const Color(0xFF0284C7).withOpacity(0.2),
                                const Color(0xFF38BDF8).withOpacity(0.1),
                              ],
                            ),
                            borderRadius: BorderRadius.circular(12),
                            border: Border.all(color: const Color(0xFF38BDF8).withOpacity(0.4)),
                          ),
                          child: Row(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              const Icon(Icons.photo_library_rounded, color: Color(0xFF38BDF8), size: 20),
                              const SizedBox(width: 8),
                              Text(
                                'Смотреть фото бумажной накладной (${item.photos.length})',
                                style: const TextStyle(color: Color(0xFF38BDF8), fontSize: 14, fontWeight: FontWeight.bold),
                              ),
                            ],
                          ),
                        ),
                      ),
                      const SizedBox(height: 16),
                    ],

                    // Список товаров в накладной
                    Text(
                      'Товары в накладной (${item.items.length}):',
                      style: const TextStyle(color: Colors.white, fontSize: 15, fontWeight: FontWeight.bold),
                    ),
                    const SizedBox(height: 8),
                    if (item.items.isEmpty)
                      Container(
                        padding: const EdgeInsets.all(16),
                        decoration: BoxDecoration(color: const Color(0xFF1E293B), borderRadius: BorderRadius.circular(12)),
                        child: const Center(
                          child: Text('Детали позиций доступны в системе gusar.tj', style: TextStyle(color: Colors.white54, fontSize: 13)),
                        ),
                      )
                    else
                      ListView.separated(
                        shrinkWrap: true,
                        physics: const NeverScrollableScrollPhysics(),
                        itemCount: item.items.length,
                        separatorBuilder: (_, __) => const SizedBox(height: 6),
                        itemBuilder: (context, idx) {
                          final it = item.items[idx];
                          return Container(
                            padding: const EdgeInsets.all(10),
                            decoration: BoxDecoration(
                              color: const Color(0xFF1E293B),
                              borderRadius: BorderRadius.circular(10),
                              border: Border.all(color: const Color(0xFF334155)),
                            ),
                            child: Row(
                              children: [
                                Container(
                                  padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                                  decoration: BoxDecoration(color: Colors.white10, borderRadius: BorderRadius.circular(4)),
                                  child: Text('${idx + 1}', style: const TextStyle(color: Colors.white54, fontSize: 11)),
                                ),
                                const SizedBox(width: 8),
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment: CrossAxisAlignment.start,
                                    children: [
                                      Text(
                                        it.rawName,
                                        style: const TextStyle(color: Colors.white, fontSize: 13, fontWeight: FontWeight.w600),
                                      ),
                                      Text(
                                        '${it.quantity} ${it.unit} × ${it.buyPrice.toStringAsFixed(2)} TJS',
                                        style: const TextStyle(color: Colors.white54, fontSize: 11),
                                      ),
                                    ],
                                  ),
                                ),
                                Text(
                                  '${it.totalPrice.toStringAsFixed(2)} TJS',
                                  style: const TextStyle(color: Colors.white, fontSize: 13, fontWeight: FontWeight.bold),
                                ),
                              ],
                            ),
                          );
                        },
                      ),

                    const SizedBox(height: 20),

                    // Кнопка оплаты конкретного долга по этой накладной
                    if (item.debtAmount > 0.01) ...[
                      SizedBox(
                        width: double.infinity,
                        height: 50,
                        child: ElevatedButton(
                          style: ElevatedButton.styleFrom(
                            backgroundColor: const Color(0xFF10B981),
                            foregroundColor: Colors.white,
                            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                            elevation: 3,
                          ),
                          onPressed: () {
                            Navigator.pop(ctx);
                            _openPaymentSheet(
                              purchaseId: item.purchaseId,
                              invoiceNumber: item.invoiceNumber,
                              debt: item.debtAmount,
                            );
                          },
                          child: Row(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              const Icon(Icons.payment_rounded, size: 20),
                              const SizedBox(width: 8),
                              Text(
                                'Погасить долг (${item.debtAmount.toStringAsFixed(2)} TJS)',
                                style: const TextStyle(fontSize: 15, fontWeight: FontWeight.bold),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final dateFormat = DateFormat('dd.MM.yyyy');
    final filteredInvoices = _invoices.where((inv) {
      if (_searchQuery.isEmpty) return true;
      final q = _searchQuery.toLowerCase();
      return inv.invoiceNumber.toLowerCase().contains(q) ||
          inv.incomingNumber.toLowerCase().contains(q) ||
          inv.totalAmount.toString().contains(q);
    }).toList();

    return Scaffold(
      backgroundColor: const Color(0xFF0B132B),
      appBar: AppBar(
        backgroundColor: const Color(0xFF0F172A),
        elevation: 0,
        title: Text(
          _currentSupplier.name,
          style: const TextStyle(color: Colors.white, fontSize: 17, fontWeight: FontWeight.bold),
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.share_rounded, color: Color(0xFF38BDF8)),
            tooltip: 'Поделиться актом сверки',
            onPressed: _shareReconciliation,
          ),
          IconButton(
            icon: const Icon(Icons.refresh_rounded, color: Colors.white70),
            tooltip: 'Обновить',
            onPressed: _loadInvoices,
          ),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: _loadInvoices,
        color: const Color(0xFF10B981),
        backgroundColor: const Color(0xFF1E293B),
        child: Column(
          children: [
            // Верхняя плашка контрагента и долга
            Container(
              padding: const EdgeInsets.all(16),
              decoration: const BoxDecoration(
                color: Color(0xFF0F172A),
                border: Border(bottom: BorderSide(color: Color(0xFF1E293B), width: 1.5)),
              ),
              child: Column(
                children: [
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Container(
                        padding: const EdgeInsets.all(12),
                        decoration: BoxDecoration(
                          color: const Color(0xFF1E293B),
                          borderRadius: BorderRadius.circular(14),
                          border: Border.all(color: const Color(0xFF334155)),
                        ),
                        child: const Icon(Icons.business_rounded, color: Color(0xFF38BDF8), size: 28),
                      ),
                      const SizedBox(width: 14),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              _currentSupplier.name,
                              style: const TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.bold),
                            ),
                            const SizedBox(height: 3),
                            if (_currentSupplier.contact != null && _currentSupplier.contact!.isNotEmpty) ...[
                              InkWell(
                                onTap: _callSupplier,
                                child: Row(
                                  children: [
                                    const Icon(Icons.phone_rounded, color: Color(0xFF10B981), size: 14),
                                    const SizedBox(width: 4),
                                    Text(
                                      _currentSupplier.contact!,
                                      style: const TextStyle(color: Color(0xFF10B981), fontSize: 13, fontWeight: FontWeight.w600),
                                    ),
                                  ],
                                ),
                              ),
                              const SizedBox(height: 2),
                            ],
                            if (_currentSupplier.inn != null && _currentSupplier.inn!.isNotEmpty)
                              Text(
                                'ИНН: ${_currentSupplier.inn}',
                                style: const TextStyle(color: Colors.white54, fontSize: 12),
                              ),
                          ],
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 14),

                  // Карточка общего остатка долга с кнопкой оплаты
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        colors: _currentSupplier.balance > 0.01
                            ? [const Color(0xFF7F1D1D).withOpacity(0.35), const Color(0xFF1E293B)]
                            : [const Color(0xFF064E3B).withOpacity(0.35), const Color(0xFF1E293B)],
                      ),
                      borderRadius: BorderRadius.circular(14),
                      border: Border.all(
                        color: _currentSupplier.balance > 0.01 ? const Color(0xFFEF4444).withOpacity(0.5) : const Color(0xFF10B981).withOpacity(0.5),
                      ),
                    ),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              _currentSupplier.balance > 0.01 ? 'Текущий долг перед поставщиком:' : 'Состояние расчётов:',
                              style: const TextStyle(color: Colors.white60, fontSize: 11),
                            ),
                            const SizedBox(height: 2),
                            Text(
                              _currentSupplier.balance > 0.01 ? '${_currentSupplier.balance.toStringAsFixed(2)} TJS' : 'В расчёте (0.00 TJS)',
                              style: TextStyle(
                                color: _currentSupplier.balance > 0.01 ? const Color(0xFFFCA5A5) : const Color(0xFF6EE7B7),
                                fontSize: 18,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                          ],
                        ),
                        ElevatedButton(
                          style: ElevatedButton.styleFrom(
                            backgroundColor: const Color(0xFF10B981),
                            foregroundColor: Colors.white,
                            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                            elevation: 2,
                          ),
                          onPressed: () => _openPaymentSheet(),
                          child: const Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(Icons.payment_rounded, size: 16),
                              SizedBox(width: 6),
                              Text('Оплата', style: TextStyle(fontSize: 13, fontWeight: FontWeight.bold)),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),

            // Поисковая строка накладных
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
              child: TextField(
                controller: _searchCtrl,
                style: const TextStyle(color: Colors.white, fontSize: 13),
                decoration: InputDecoration(
                  filled: true,
                  fillColor: const Color(0xFF1E293B),
                  hintText: 'Поиск накладной по номеру или сумме...',
                  hintStyle: const TextStyle(color: Colors.white38, fontSize: 13),
                  prefixIcon: const Icon(Icons.search_rounded, color: Colors.white54, size: 20),
                  suffixIcon: _searchQuery.isNotEmpty
                      ? IconButton(
                          icon: const Icon(Icons.clear, color: Colors.white54, size: 18),
                          onPressed: () {
                            _searchCtrl.clear();
                            setState(() => _searchQuery = '');
                          },
                        )
                      : null,
                  contentPadding: const EdgeInsets.symmetric(vertical: 0, horizontal: 16),
                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide.none),
                ),
                onChanged: (val) => setState(() => _searchQuery = val.trim()),
              ),
            ),

            // Список накладных (хронология сверху вниз: от новых к старым)
            Expanded(
              child: _isLoading
                  ? const Center(child: CircularProgressIndicator(color: Color(0xFF10B981)))
                  : filteredInvoices.isEmpty
                      ? Center(
                          child: Column(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              Icon(Icons.receipt_long_outlined, size: 54, color: Colors.white.withOpacity(0.2)),
                              const SizedBox(height: 12),
                              const Text('Накладных не найдено', style: TextStyle(color: Colors.white70, fontSize: 16)),
                              const SizedBox(height: 4),
                              const Text(
                                'Принимайте накладные через сканер\nили создавайте в системе gusar.tj',
                                textAlign: TextAlign.center,
                                style: TextStyle(color: Colors.white38, fontSize: 12),
                              ),
                            ],
                          ),
                        )
                      : ListView.builder(
                          padding: const EdgeInsets.fromLTRB(16, 4, 16, 24),
                          itemCount: filteredInvoices.length,
                          itemBuilder: (context, index) {
                            final inv = filteredInvoices[index];
                            final hasPhotos = inv.photos.isNotEmpty;

                            Color statusColor;
                            String statusLabel;
                            if (inv.debtAmount <= 0.01) {
                              statusColor = const Color(0xFF10B981);
                              statusLabel = 'Оплачено';
                            } else if (inv.paidAmount > 0.01) {
                              statusColor = const Color(0xFFF59E0B);
                              statusLabel = 'Долг: ${inv.debtAmount.toStringAsFixed(2)} TJS';
                            } else {
                              statusColor = const Color(0xFFEF4444);
                              statusLabel = 'В долг (${inv.debtAmount.toStringAsFixed(2)} TJS)';
                            }

                            return Container(
                              margin: const EdgeInsets.only(bottom: 10),
                              decoration: BoxDecoration(
                                color: const Color(0xFF1E293B),
                                borderRadius: BorderRadius.circular(14),
                                border: Border.all(color: const Color(0xFF334155)),
                              ),
                              child: InkWell(
                                borderRadius: BorderRadius.circular(14),
                                onTap: () => _showInvoiceDetails(inv),
                                child: Padding(
                                  padding: const EdgeInsets.all(14),
                                  child: Column(
                                    crossAxisAlignment: CrossAxisAlignment.start,
                                    children: [
                                      Row(
                                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                                        children: [
                                          Row(
                                            children: [
                                              Container(
                                                padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
                                                decoration: BoxDecoration(
                                                  color: const Color(0xFF38BDF8).withOpacity(0.18),
                                                  borderRadius: BorderRadius.circular(6),
                                                ),
                                                child: Text(
                                                  '№${inv.invoiceNumber}',
                                                  style: const TextStyle(
                                                    color: Color(0xFF38BDF8),
                                                    fontSize: 13,
                                                    fontWeight: FontWeight.bold,
                                                  ),
                                                ),
                                              ),
                                              if (inv.incomingNumber.isNotEmpty && inv.incomingNumber != inv.invoiceNumber) ...[
                                                const SizedBox(width: 6),
                                                Text(
                                                  '(вх. ${inv.incomingNumber})',
                                                  style: const TextStyle(color: Colors.white54, fontSize: 11),
                                                ),
                                              ],
                                            ],
                                          ),
                                          Text(
                                            dateFormat.format(inv.date),
                                            style: const TextStyle(color: Colors.white54, fontSize: 12),
                                          ),
                                        ],
                                      ),
                                      const SizedBox(height: 10),

                                      Row(
                                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                                        crossAxisAlignment: CrossAxisAlignment.end,
                                        children: [
                                          Column(
                                            crossAxisAlignment: CrossAxisAlignment.start,
                                            children: [
                                              const Text('Сумма накладной:', style: TextStyle(color: Colors.white54, fontSize: 11)),
                                              const SizedBox(height: 2),
                                              Text(
                                                '${inv.totalAmount.toStringAsFixed(2)} TJS',
                                                style: const TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.bold),
                                              ),
                                            ],
                                          ),

                                          // Статус оплаты
                                          Container(
                                            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                                            decoration: BoxDecoration(
                                              color: statusColor.withOpacity(0.18),
                                              borderRadius: BorderRadius.circular(6),
                                              border: Border.all(color: statusColor, width: 0.8),
                                            ),
                                            child: Text(
                                              statusLabel,
                                              style: TextStyle(color: statusColor, fontSize: 11, fontWeight: FontWeight.bold),
                                            ),
                                          ),
                                        ],
                                      ),

                                      // Нижняя панель действий: Просмотр фото и Быстрая оплата
                                      if (hasPhotos || inv.debtAmount > 0.01) ...[
                                        const SizedBox(height: 10),
                                        const Divider(color: Color(0xFF334155), height: 1),
                                        const SizedBox(height: 8),
                                        Row(
                                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                                          children: [
                                            if (hasPhotos)
                                              InkWell(
                                                borderRadius: BorderRadius.circular(6),
                                                onTap: () {
                                                  DocumentPhotoViewerDialog.show(
                                                    context,
                                                    photoPaths: inv.photos,
                                                    invoiceNumber: inv.invoiceNumber,
                                                    supplierName: _currentSupplier.name,
                                                  );
                                                },
                                                child: Padding(
                                                  padding: const EdgeInsets.symmetric(vertical: 4, horizontal: 6),
                                                  child: Row(
                                                    children: [
                                                      const Icon(Icons.camera_alt_outlined, color: Color(0xFF38BDF8), size: 16),
                                                      const SizedBox(width: 4),
                                                      Text(
                                                        'Фото накладной (${inv.photos.length})',
                                                        style: const TextStyle(color: Color(0xFF38BDF8), fontSize: 12, fontWeight: FontWeight.w600),
                                                      ),
                                                    ],
                                                  ),
                                                ),
                                              )
                                            else
                                              const SizedBox.shrink(),

                                            if (inv.debtAmount > 0.01)
                                              InkWell(
                                                borderRadius: BorderRadius.circular(6),
                                                onTap: () => _openPaymentSheet(
                                                  purchaseId: inv.purchaseId,
                                                  invoiceNumber: inv.invoiceNumber,
                                                  debt: inv.debtAmount,
                                                ),
                                                child: Container(
                                                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                                                  decoration: BoxDecoration(
                                                    color: const Color(0xFF10B981).withOpacity(0.18),
                                                    borderRadius: BorderRadius.circular(6),
                                                    border: Border.all(color: const Color(0xFF10B981), width: 0.8),
                                                  ),
                                                  child: const Row(
                                                    mainAxisSize: MainAxisSize.min,
                                                    children: [
                                                      Icon(Icons.payment_rounded, color: Color(0xFF10B981), size: 14),
                                                      SizedBox(width: 4),
                                                      Text(
                                                        'Оплатить',
                                                        style: TextStyle(color: Color(0xFF10B981), fontSize: 12, fontWeight: FontWeight.bold),
                                                      ),
                                                    ],
                                                  ),
                                                ),
                                              ),
                                          ],
                                        ),
                                      ],
                                    ],
                                  ),
                                ),
                              ),
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
