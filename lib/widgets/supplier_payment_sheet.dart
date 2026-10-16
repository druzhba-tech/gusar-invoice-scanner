import 'dart:io';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import '../models/supplier.dart';
import '../services/api_service.dart';
import '../utils/top_notification.dart';

class SupplierPaymentSheet extends StatefulWidget {
  final Supplier? initialSupplier;
  final int? purchaseId;
  final String? invoiceNumber;
  final double? initialDebt;
  final VoidCallback? onPaymentSuccess;

  const SupplierPaymentSheet({
    super.key,
    this.initialSupplier,
    this.purchaseId,
    this.invoiceNumber,
    this.initialDebt,
    this.onPaymentSuccess,
  });

  static Future<void> show(
    BuildContext context, {
    Supplier? initialSupplier,
    int? purchaseId,
    String? invoiceNumber,
    double? initialDebt,
    VoidCallback? onPaymentSuccess,
  }) {
    return showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => SupplierPaymentSheet(
        initialSupplier: initialSupplier,
        purchaseId: purchaseId,
        invoiceNumber: invoiceNumber,
        initialDebt: initialDebt,
        onPaymentSuccess: onPaymentSuccess,
      ),
    );
  }

  @override
  State<SupplierPaymentSheet> createState() => _SupplierPaymentSheetState();
}

class _SupplierPaymentSheetState extends State<SupplierPaymentSheet> {
  final ApiService _api = ApiService();
  final ImagePicker _picker = ImagePicker();

  Supplier? _selectedSupplier;
  List<Supplier> _allSuppliers = [];
  bool _isLoadingSuppliers = false;

  final TextEditingController _amountCtrl = TextEditingController();
  final TextEditingController _notesCtrl = TextEditingController();
  String _paymentSource = 'cash'; // 'cash', 'bank', 'safe'
  File? _receiptPhoto;
  bool _isSubmitting = false;

  @override
  void initState() {
    super.initState();
    _selectedSupplier = widget.initialSupplier;

    // Автоподстановка суммы
    final targetDebt = widget.initialDebt ?? _selectedSupplier?.balance ?? 0.0;
    if (targetDebt > 0) {
      _amountCtrl.text = targetDebt.toStringAsFixed(2);
    }

    if (_selectedSupplier == null) {
      _loadSuppliers();
    }
  }

  @override
  void dispose() {
    _amountCtrl.dispose();
    _notesCtrl.dispose();
    super.dispose();
  }

  Future<void> _loadSuppliers() async {
    setState(() => _isLoadingSuppliers = true);
    try {
      final list = await _api.getSuppliers();
      if (mounted) {
        setState(() {
          _allSuppliers = list;
          _isLoadingSuppliers = false;
        });
      }
    } catch (_) {
      if (mounted) setState(() => _isLoadingSuppliers = false);
    }
  }

  void _setAmount(double amount) {
    if (amount <= 0) return;
    setState(() {
      _amountCtrl.text = amount.toStringAsFixed(2);
    });
  }

  Future<void> _pickReceiptPhoto(ImageSource source) async {
    try {
      final picked = await _picker.pickImage(
        source: source,
        maxWidth: 1600,
        maxHeight: 1600,
        imageQuality: 85,
      );
      if (picked != null) {
        setState(() {
          _receiptPhoto = File(picked.path);
        });
      }
    } catch (e) {
      if (mounted) {
        TopNotification.showError(context, 'Не удалось прикрепить фото: $e');
      }
    }
  }

  void _showPhotoOptions() {
    showModalBottomSheet(
      context: context,
      backgroundColor: const Color(0xFF1E293B),
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (ctx) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 16, horizontal: 20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text(
                'Прикрепить квитанцию / чек',
                style: TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 16),
              ListTile(
                leading: Container(
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(color: const Color(0xFF10B981).withOpacity(0.2), borderRadius: BorderRadius.circular(10)),
                  child: const Icon(Icons.camera_alt_rounded, color: Color(0xFF10B981)),
                ),
                title: const Text('Сфотографировать чек', style: TextStyle(color: Colors.white)),
                onTap: () {
                  Navigator.pop(ctx);
                  _pickReceiptPhoto(ImageSource.camera);
                },
              ),
              ListTile(
                leading: Container(
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(color: const Color(0xFF38BDF8).withOpacity(0.2), borderRadius: BorderRadius.circular(10)),
                  child: const Icon(Icons.photo_library_rounded, color: Color(0xFF38BDF8)),
                ),
                title: const Text('Выбрать из галереи', style: TextStyle(color: Colors.white)),
                onTap: () {
                  Navigator.pop(ctx);
                  _pickReceiptPhoto(ImageSource.gallery);
                },
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _submitPayment() async {
    final sup = _selectedSupplier;
    if (sup == null) {
      TopNotification.showError(context, 'Пожалуйста, выберите поставщика');
      return;
    }

    final enteredAmount = double.tryParse(_amountCtrl.text.replaceAll(',', '.')) ?? 0.0;
    if (enteredAmount <= 0) {
      TopNotification.showError(context, 'Введите корректную сумму оплаты больше 0');
      return;
    }

    setState(() => _isSubmitting = true);

    try {
      final res = await _api.paySupplierDebt(
        supplierId: sup.id,
        purchaseId: widget.purchaseId,
        amount: enteredAmount,
        source: _paymentSource,
        notes: _notesCtrl.text.trim().isNotEmpty ? _notesCtrl.text.trim() : null,
        receiptPhotoPath: _receiptPhoto?.path,
      );

      if (mounted) {
        setState(() => _isSubmitting = false);

        if (res['success'] == true) {
          TopNotification.showSuccess(
            context,
            res['message']?.toString() ?? 'Оплата на сумму ${enteredAmount.toStringAsFixed(2)} TJS успешно проведена!',
          );
          widget.onPaymentSuccess?.call();
          Navigator.pop(context, true);
        } else {
          TopNotification.showError(
            context,
            res['message']?.toString() ?? 'Не удалось провести оплату на сервере gusar.tj',
          );
        }
      }
    } catch (e) {
      if (mounted) {
        setState(() => _isSubmitting = false);
        TopNotification.showError(context, 'Ошибка сети: $e');
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final curDebt = widget.initialDebt ?? _selectedSupplier?.balance ?? 0.0;

    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom),
      child: Container(
        constraints: BoxConstraints(maxHeight: MediaQuery.of(context).size.height * 0.88),
        decoration: const BoxDecoration(
          color: Color(0xFF0F172A),
          borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
          border: Border(top: BorderSide(color: Color(0xFF334155), width: 1.5)),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // Верхняя полоска-индикатор
            Container(
              margin: const EdgeInsets.only(top: 10, bottom: 6),
              width: 40,
              height: 4,
              decoration: BoxDecoration(color: Colors.white24, borderRadius: BorderRadius.circular(2)),
            ),

            // Заголовок
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
              child: Row(
                children: [
                  Container(
                    padding: const EdgeInsets.all(8),
                    decoration: BoxDecoration(
                      color: const Color(0xFF10B981).withOpacity(0.18),
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: const Icon(Icons.payment_rounded, color: Color(0xFF10B981), size: 22),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text(
                          'Оплата поставщику',
                          style: TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.bold),
                        ),
                        Text(
                          widget.purchaseId != null
                              ? 'Погашение по накладной №${widget.invoiceNumber ?? widget.purchaseId}'
                              : 'Взаиморасчёт и списание долга в gusar.tj',
                          style: const TextStyle(color: Colors.white54, fontSize: 12),
                        ),
                      ],
                    ),
                  ),
                  IconButton(
                    icon: const Icon(Icons.close_rounded, color: Colors.white54),
                    onPressed: () => Navigator.pop(context),
                  ),
                ],
              ),
            ),
            const Divider(color: Color(0xFF1E293B), height: 1),

            Flexible(
              child: SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(20, 16, 20, 24),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // 1. Выбор или отображение поставщика
                    if (widget.initialSupplier != null) ...[
                      Container(
                        padding: const EdgeInsets.all(14),
                        decoration: BoxDecoration(
                          color: const Color(0xFF1E293B),
                          borderRadius: BorderRadius.circular(14),
                          border: Border.all(color: const Color(0xFF334155)),
                        ),
                        child: Row(
                          children: [
                            Container(
                              padding: const EdgeInsets.all(8),
                              decoration: BoxDecoration(
                                color: const Color(0xFF38BDF8).withOpacity(0.15),
                                borderRadius: BorderRadius.circular(8),
                              ),
                              child: const Icon(Icons.storefront_rounded, color: Color(0xFF38BDF8), size: 20),
                            ),
                            const SizedBox(width: 12),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    widget.initialSupplier!.name,
                                    style: const TextStyle(color: Colors.white, fontSize: 15, fontWeight: FontWeight.bold),
                                  ),
                                  if (widget.initialSupplier!.contact != null && widget.initialSupplier!.contact!.isNotEmpty)
                                    Text(
                                      widget.initialSupplier!.contact!,
                                      style: const TextStyle(color: Colors.white54, fontSize: 12),
                                    ),
                                ],
                              ),
                            ),
                            Container(
                              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                              decoration: BoxDecoration(
                                color: curDebt > 0 ? const Color(0xFFEF4444).withOpacity(0.18) : const Color(0xFF10B981).withOpacity(0.18),
                                borderRadius: BorderRadius.circular(8),
                                border: Border.all(color: curDebt > 0 ? const Color(0xFFEF4444) : const Color(0xFF10B981), width: 0.8),
                              ),
                              child: Text(
                                curDebt > 0 ? 'Долг: ${curDebt.toStringAsFixed(2)} TJS' : 'В расчёте',
                                style: TextStyle(
                                  color: curDebt > 0 ? const Color(0xFFFCA5A5) : const Color(0xFF6EE7B7),
                                  fontSize: 12,
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ] else ...[
                      const Text(
                        'Выберите поставщика:',
                        style: TextStyle(color: Colors.white70, fontSize: 13, fontWeight: FontWeight.bold),
                      ),
                      const SizedBox(height: 6),
                      if (_isLoadingSuppliers)
                        const Center(child: Padding(padding: EdgeInsets.all(12), child: CircularProgressIndicator(strokeWidth: 2)))
                      else
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 12),
                          decoration: BoxDecoration(
                            color: const Color(0xFF1E293B),
                            borderRadius: BorderRadius.circular(12),
                            border: Border.all(color: const Color(0xFF334155)),
                          ),
                          child: DropdownButtonHideUnderline(
                            child: DropdownButton<Supplier>(
                              isExpanded: true,
                              dropdownColor: const Color(0xFF1E293B),
                              hint: const Text('Выберите контрагента...', style: TextStyle(color: Colors.white54)),
                              value: _selectedSupplier,
                              items: _allSuppliers.map((s) {
                                return DropdownMenuItem<Supplier>(
                                  value: s,
                                  child: Row(
                                    children: [
                                      Expanded(
                                        child: Text(
                                          s.name,
                                          style: const TextStyle(color: Colors.white, fontSize: 14),
                                          overflow: TextOverflow.ellipsis,
                                        ),
                                      ),
                                      if (s.balance > 0)
                                        Container(
                                          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                                          decoration: BoxDecoration(
                                            color: const Color(0xFFEF4444).withOpacity(0.18),
                                            borderRadius: BorderRadius.circular(6),
                                          ),
                                          child: Text(
                                            '${s.balance.toStringAsFixed(0)} TJS',
                                            style: const TextStyle(color: Color(0xFFFCA5A5), fontSize: 11, fontWeight: FontWeight.bold),
                                          ),
                                        ),
                                    ],
                                  ),
                                );
                              }).toList(),
                              onChanged: (val) {
                                setState(() {
                                  _selectedSupplier = val;
                                  if (val != null && val.balance > 0) {
                                    _amountCtrl.text = val.balance.toStringAsFixed(2);
                                  }
                                });
                              },
                            ),
                          ),
                        ),
                    ],

                    const SizedBox(height: 16),

                    // 2. Ввод суммы оплаты
                    const Text(
                      'Сумма к оплате (сомони):',
                      style: TextStyle(color: Colors.white70, fontSize: 13, fontWeight: FontWeight.bold),
                    ),
                    const SizedBox(height: 6),
                    TextField(
                      controller: _amountCtrl,
                      keyboardType: const TextInputType.numberWithOptions(decimal: true),
                      style: const TextStyle(color: Colors.white, fontSize: 22, fontWeight: FontWeight.bold),
                      decoration: InputDecoration(
                        filled: true,
                        fillColor: const Color(0xFF1E293B),
                        suffixText: 'TJS',
                        suffixStyle: const TextStyle(color: Color(0xFF10B981), fontSize: 18, fontWeight: FontWeight.bold),
                        prefixIcon: const Icon(Icons.attach_money_rounded, color: Color(0xFF10B981)),
                        enabledBorder: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(12),
                          borderSide: const BorderSide(color: Color(0xFF334155)),
                        ),
                        focusedBorder: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(12),
                          borderSide: const BorderSide(color: Color(0xFF10B981), width: 1.5),
                        ),
                        contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
                      ),
                    ),

                    // Быстрые кнопки пресетов сумм
                    if (curDebt > 0) ...[
                      const SizedBox(height: 8),
                      SingleChildScrollView(
                        scrollDirection: Axis.horizontal,
                        child: Row(
                          children: [
                            _presetChip('Весь долг (${curDebt.toStringAsFixed(2)})', () => _setAmount(curDebt)),
                            const SizedBox(width: 6),
                            _presetChip('50% (${(curDebt / 2).toStringAsFixed(2)})', () => _setAmount(curDebt / 2)),
                            const SizedBox(width: 6),
                            if (curDebt > 100) ...[
                              _presetChip('100 TJS', () => _setAmount(100.0)),
                              const SizedBox(width: 6),
                            ],
                            if (curDebt > 500) ...[
                              _presetChip('500 TJS', () => _setAmount(500.0)),
                              const SizedBox(width: 6),
                            ],
                            if (curDebt > 1000) ...[
                              _presetChip('1000 TJS', () => _setAmount(1000.0)),
                            ],
                          ],
                        ),
                      ),
                    ],

                    const SizedBox(height: 18),

                    // 3. Источник списания средств
                    const Text(
                      'Источник выплаты:',
                      style: TextStyle(color: Colors.white70, fontSize: 13, fontWeight: FontWeight.bold),
                    ),
                    const SizedBox(height: 8),
                    Row(
                      children: [
                        Expanded(
                          child: _sourceOption(
                            id: 'cash',
                            label: 'Касса',
                            icon: Icons.point_of_sale_rounded,
                            color: const Color(0xFF10B981),
                          ),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: _sourceOption(
                            id: 'bank',
                            label: 'Банк / Р/С',
                            icon: Icons.account_balance_rounded,
                            color: const Color(0xFF38BDF8),
                          ),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: _sourceOption(
                            id: 'safe',
                            label: 'Сейф',
                            icon: Icons.lock_clock_rounded,
                            color: const Color(0xFFF59E0B),
                          ),
                        ),
                      ],
                    ),

                    const SizedBox(height: 16),

                    // 4. Примечание
                    const Text(
                      'Комментарий / Номер перевода (необязательно):',
                      style: TextStyle(color: Colors.white70, fontSize: 13, fontWeight: FontWeight.bold),
                    ),
                    const SizedBox(height: 6),
                    TextField(
                      controller: _notesCtrl,
                      style: const TextStyle(color: Colors.white, fontSize: 14),
                      decoration: InputDecoration(
                        filled: true,
                        fillColor: const Color(0xFF1E293B),
                        hintText: 'Например: Перевод через Алиф, курьеру в руки...',
                        hintStyle: const TextStyle(color: Colors.white38, fontSize: 13),
                        enabledBorder: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(12),
                          borderSide: const BorderSide(color: Color(0xFF334155)),
                        ),
                        focusedBorder: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(12),
                          borderSide: const BorderSide(color: Color(0xFF38BDF8)),
                        ),
                        contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                      ),
                    ),

                    const SizedBox(height: 16),

                    // 5. Фото квитанции / чека
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        const Text(
                          'Квитанция / Чек оплаты:',
                          style: TextStyle(color: Colors.white70, fontSize: 13, fontWeight: FontWeight.bold),
                        ),
                        if (_receiptPhoto != null)
                          GestureDetector(
                            onTap: () => setState(() => _receiptPhoto = null),
                            child: const Text('Удалить', style: TextStyle(color: Colors.redAccent, fontSize: 12)),
                          ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    if (_receiptPhoto == null) ...[
                      InkWell(
                        borderRadius: BorderRadius.circular(12),
                        onTap: _showPhotoOptions,
                        child: Container(
                          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                          decoration: BoxDecoration(
                            color: const Color(0xFF1E293B),
                            borderRadius: BorderRadius.circular(12),
                            border: Border.all(color: const Color(0xFF334155), style: BorderStyle.solid),
                          ),
                          child: const Row(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              Icon(Icons.add_a_photo_outlined, color: Color(0xFF38BDF8), size: 20),
                              SizedBox(width: 8),
                              Text(
                                'Прикрепить фото чека или квитанции',
                                style: TextStyle(color: Color(0xFF38BDF8), fontSize: 13, fontWeight: FontWeight.w600),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ] else ...[
                      Container(
                        padding: const EdgeInsets.all(8),
                        decoration: BoxDecoration(
                          color: const Color(0xFF1E293B),
                          borderRadius: BorderRadius.circular(12),
                          border: Border.all(color: const Color(0xFF10B981).withOpacity(0.5)),
                        ),
                        child: Row(
                          children: [
                            ClipRRect(
                              borderRadius: BorderRadius.circular(8),
                              child: Image.file(_receiptPhoto!, width: 50, height: 50, fit: BoxFit.cover),
                            ),
                            const SizedBox(width: 12),
                            const Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    'Фото прикреплено',
                                    style: TextStyle(color: Colors.white, fontSize: 13, fontWeight: FontWeight.bold),
                                  ),
                                  Text(
                                    'Будет сжато и отправлено в базу gusar.tj',
                                    style: TextStyle(color: Colors.white54, fontSize: 11),
                                  ),
                                ],
                              ),
                            ),
                            IconButton(
                              icon: const Icon(Icons.refresh, color: Colors.white70, size: 20),
                              tooltip: 'Переснять',
                              onPressed: _showPhotoOptions,
                            ),
                          ],
                        ),
                      ),
                    ],

                    const SizedBox(height: 24),

                    // Кнопка подтверждения оплаты
                    SizedBox(
                      width: double.infinity,
                      height: 52,
                      child: ElevatedButton(
                        style: ElevatedButton.styleFrom(
                          backgroundColor: const Color(0xFF10B981),
                          disabledBackgroundColor: Colors.grey.shade800,
                          foregroundColor: Colors.white,
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                          elevation: 4,
                        ),
                        onPressed: _isSubmitting ? null : _submitPayment,
                        child: _isSubmitting
                            ? const Row(
                                mainAxisAlignment: MainAxisAlignment.center,
                                children: [
                                  SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2.5, color: Colors.white)),
                                  SizedBox(width: 12),
                                  Text('Проведение оплаты на gusar.tj...', style: TextStyle(fontSize: 15, fontWeight: FontWeight.bold)),
                                ],
                              )
                            : Row(
                                mainAxisAlignment: MainAxisAlignment.center,
                                children: [
                                  const Icon(Icons.check_circle_rounded, size: 22),
                                  const SizedBox(width: 8),
                                  Text(
                                    'Провести оплату (${_amountCtrl.text.isNotEmpty ? _amountCtrl.text : '0.00'} TJS)',
                                    style: const TextStyle(fontSize: 15, fontWeight: FontWeight.bold),
                                  ),
                                ],
                              ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _presetChip(String label, VoidCallback onTap) {
    return InkWell(
      borderRadius: BorderRadius.circular(8),
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(
          color: const Color(0xFF1E293B),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: const Color(0xFF38BDF8).withOpacity(0.4)),
        ),
        child: Text(
          label,
          style: const TextStyle(color: Color(0xFF38BDF8), fontSize: 12, fontWeight: FontWeight.bold),
        ),
      ),
    );
  }

  Widget _sourceOption({
    required String id,
    required String label,
    required IconData icon,
    required Color color,
  }) {
    final isSelected = _paymentSource == id;
    return InkWell(
      borderRadius: BorderRadius.circular(12),
      onTap: () => setState(() => _paymentSource = id),
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 8),
        decoration: BoxDecoration(
          color: isSelected ? color.withOpacity(0.18) : const Color(0xFF1E293B),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: isSelected ? color : const Color(0xFF334155),
            width: isSelected ? 1.5 : 1.0,
          ),
        ),
        child: Column(
          children: [
            Icon(icon, color: isSelected ? color : Colors.white60, size: 22),
            const SizedBox(height: 4),
            Text(
              label,
              style: TextStyle(
                color: isSelected ? Colors.white : Colors.white60,
                fontSize: 12,
                fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
