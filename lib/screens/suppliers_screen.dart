import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';

import '../models/supplier.dart';
import '../services/api_service.dart';
import '../utils/top_notification.dart';
import '../widgets/supplier_payment_sheet.dart';
import 'supplier_invoices_screen.dart';

class SuppliersScreen extends StatefulWidget {
  const SuppliersScreen({super.key});

  @override
  State<SuppliersScreen> createState() => _SuppliersScreenState();
}

class _SuppliersScreenState extends State<SuppliersScreen> {
  final ApiService _api = ApiService();

  List<Supplier> _suppliers = [];
  bool _isLoading = true;
  String _searchQuery = '';
  String _filterType = 'all'; // 'all', 'debt', 'settled'
  final TextEditingController _searchCtrl = TextEditingController();

  @override
  void initState() {
    super.initState();
    _loadSuppliers();
  }

  @override
  void dispose() {
    _searchCtrl.dispose();
    super.dispose();
  }

  Future<void> _loadSuppliers() async {
    setState(() => _isLoading = true);
    try {
      final list = await _api.getSuppliers(forceRefresh: true);
      // Сортируем: сначала те, у кого есть долг (по убыванию суммы долга), затем остальные по алфавиту
      list.sort((a, b) {
        if (a.balance > 0.01 && b.balance <= 0.01) return -1;
        if (a.balance <= 0.01 && b.balance > 0.01) return 1;
        if (a.balance > 0.01 && b.balance > 0.01) {
          return b.balance.compareTo(a.balance);
        }
        return a.name.compareTo(b.name);
      });

      if (mounted) {
        setState(() {
          _suppliers = list;
          _isLoading = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() => _isLoading = false);
        TopNotification.showError(context, 'Ошибка загрузки контрагентов: $e');
      }
    }
  }

  void _openGeneralPaymentSheet() {
    SupplierPaymentSheet.show(
      context,
      onPaymentSuccess: _loadSuppliers,
    );
  }

  void _callSupplier(Supplier supplier) async {
    final phone = supplier.contact;
    if (phone == null || phone.trim().isEmpty) {
      TopNotification.show(context, message: 'У контрагента не указан телефон');
      return;
    }
    final cleanPhone = phone.replaceAll(RegExp(r'[^0-9+]'), '');
    final uri = Uri.parse('tel:$cleanPhone');
    if (await canLaunchUrl(uri)) {
      await launchUrl(uri);
    } else {
      Clipboard.setData(ClipboardData(text: cleanPhone));
      if (mounted) {
        TopNotification.showSuccess(context, 'Телефон $cleanPhone скопирован в буфер');
      }
    }
  }

  void _showCreateSupplierDialog() {
    final nameCtrl = TextEditingController();
    final phoneCtrl = TextEditingController();
    final innCtrl = TextEditingController();
    final addrCtrl = TextEditingController();
    bool isSaving = false;

    showDialog(
      context: context,
      builder: (dlgCtx) => StatefulBuilder(
        builder: (ctx, setDlgState) => AlertDialog(
          backgroundColor: const Color(0xFF1E293B),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
          title: const Row(
            children: [
              Icon(Icons.person_add_rounded, color: Color(0xFF10B981), size: 22),
              SizedBox(width: 8),
              Text('Новый поставщик', style: TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.bold)),
            ],
          ),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextField(
                  controller: nameCtrl,
                  style: const TextStyle(color: Colors.white),
                  decoration: const InputDecoration(
                    labelText: 'Название или ФИО *',
                    labelStyle: TextStyle(color: Colors.white60),
                    border: OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 10),
                TextField(
                  controller: phoneCtrl,
                  keyboardType: TextInputType.phone,
                  style: const TextStyle(color: Colors.white),
                  decoration: const InputDecoration(
                    labelText: 'Телефон',
                    labelStyle: TextStyle(color: Colors.white60),
                    border: OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 10),
                TextField(
                  controller: innCtrl,
                  keyboardType: TextInputType.number,
                  style: const TextStyle(color: Colors.white),
                  decoration: const InputDecoration(
                    labelText: 'ИНН',
                    labelStyle: TextStyle(color: Colors.white60),
                    border: OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 10),
                TextField(
                  controller: addrCtrl,
                  style: const TextStyle(color: Colors.white),
                  decoration: const InputDecoration(
                    labelText: 'Город / Адрес',
                    labelStyle: TextStyle(color: Colors.white60),
                    border: OutlineInputBorder(),
                  ),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dlgCtx),
              child: const Text('Отмена', style: TextStyle(color: Colors.white54)),
            ),
            ElevatedButton(
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFF10B981),
                foregroundColor: Colors.white,
              ),
              onPressed: isSaving
                  ? null
                  : () async {
                      final n = nameCtrl.text.trim();
                      if (n.isEmpty) {
                        TopNotification.showError(context, 'Введите название поставщика');
                        return;
                      }
                      setDlgState(() => isSaving = true);
                      try {
                        final created = await _api.createSupplier(
                          n,
                          contact: phoneCtrl.text.trim().isNotEmpty ? phoneCtrl.text.trim() : null,
                          inn: innCtrl.text.trim().isNotEmpty ? innCtrl.text.trim() : null,
                          address: addrCtrl.text.trim().isNotEmpty ? addrCtrl.text.trim() : null,
                        );
                        if (mounted) {
                          Navigator.pop(dlgCtx);
                          if (created != null) {
                            TopNotification.showSuccess(context, 'Поставщик "${created.name}" добавлен в базу gusar.tj');
                            _loadSuppliers();
                          }
                        }
                      } catch (e) {
                        setDlgState(() => isSaving = false);
                        TopNotification.showError(context, 'Ошибка: $e');
                      }
                    },
              child: isSaving
                  ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                  : const Text('Создать'),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    // Расчёт общей статистики
    final totalDebt = _suppliers.fold<double>(0.0, (acc, s) => acc + (s.balance > 0 ? s.balance : 0.0));
    final suppliersWithDebt = _suppliers.where((s) => s.balance > 0.01).length;
    final settledCount = _suppliers.where((s) => s.balance <= 0.01).length;

    // Фильтрация
    final filtered = _suppliers.where((s) {
      if (_filterType == 'debt' && s.balance <= 0.01) return false;
      if (_filterType == 'settled' && s.balance > 0.01) return false;
      if (_searchQuery.isNotEmpty) {
        final q = _searchQuery.toLowerCase();
        final nameM = s.name.toLowerCase().contains(q);
        final phoneM = s.contact != null && s.contact!.toLowerCase().contains(q);
        final innM = s.inn != null && s.inn!.contains(q);
        return nameM || phoneM || innM;
      }
      return true;
    }).toList();

    return Scaffold(
      backgroundColor: const Color(0xFF0B132B),
      appBar: AppBar(
        backgroundColor: const Color(0xFF0F172A),
        elevation: 0,
        title: const Text(
          'Поставщики',
          style: TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.bold),
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.person_add_rounded, color: Color(0xFF10B981)),
            tooltip: 'Добавить поставщика',
            onPressed: _showCreateSupplierDialog,
          ),
          IconButton(
            icon: const Icon(Icons.refresh_rounded, color: Colors.white70),
            tooltip: 'Обновить',
            onPressed: _loadSuppliers,
          ),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: _loadSuppliers,
        color: const Color(0xFF10B981),
        backgroundColor: const Color(0xFF1E293B),
        child: Column(
          children: [
            // 1. Верхний баннер общего долга и кнопка оплаты
            Container(
              padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
              decoration: const BoxDecoration(
                color: Color(0xFF0F172A),
                border: Border(bottom: BorderSide(color: Color(0xFF1E293B), width: 1.5)),
              ),
              child: Column(
                children: [
                  Container(
                    padding: const EdgeInsets.all(14),
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        colors: totalDebt > 0.01
                            ? [
                                const Color(0xFF7F1D1D).withOpacity(0.4),
                                const Color(0xFF1E293B),
                              ]
                            : [
                                const Color(0xFF064E3B).withOpacity(0.4),
                                const Color(0xFF1E293B),
                              ],
                      ),
                      borderRadius: BorderRadius.circular(16),
                      border: Border.all(
                        color: totalDebt > 0.01 ? const Color(0xFFEF4444).withOpacity(0.5) : const Color(0xFF10B981).withOpacity(0.5),
                        width: 1.2,
                      ),
                    ),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              const Text(
                                'Общий долг магазина перед поставщиками:',
                                style: TextStyle(color: Colors.white60, fontSize: 11),
                              ),
                              const SizedBox(height: 3),
                              Text(
                                '${totalDebt.toStringAsFixed(2)} TJS',
                                style: TextStyle(
                                  color: totalDebt > 0.01 ? const Color(0xFFFCA5A5) : const Color(0xFF6EE7B7),
                                  fontSize: 22,
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                              const SizedBox(height: 3),
                              Text(
                                'С задолженностью: $suppliersWithDebt из ${_suppliers.length}',
                                style: const TextStyle(color: Colors.white38, fontSize: 11),
                              ),
                            ],
                          ),
                        ),

                        // Кнопка оплаты поставщику вверху экрана
                        ElevatedButton.styleFrom(
                          backgroundColor: const Color(0xFF10B981),
                          foregroundColor: Colors.white,
                          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                          elevation: 3,
                        ),
                        onPressed: _openGeneralPaymentSheet,
                        child: const Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(Icons.payment_rounded, size: 20),
                            SizedBox(height: 2),
                            Text('Оплата', style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold)),
                          ],
                        ),
                      ],
                    ),
                  ),

                  const SizedBox(height: 12),

                  // Строка поиска
                  TextField(
                    controller: _searchCtrl,
                    style: const TextStyle(color: Colors.white, fontSize: 13),
                    decoration: InputDecoration(
                      filled: true,
                      fillColor: const Color(0xFF1E293B),
                      hintText: 'Поиск по названию, телефону, ИНН...',
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

                  const SizedBox(height: 10),

                  // Фильтры-чипы
                  Row(
                    children: [
                      _filterChip('all', 'Все (${_suppliers.length})'),
                      const SizedBox(width: 8),
                      _filterChip('debt', 'С долгом ($suppliersWithDebt)', isDebtBadge: true),
                      const SizedBox(width: 8),
                      _filterChip('settled', 'В расчёте ($settledCount)'),
                    ],
                  ),
                ],
              ),
            ),

            // 2. Список поставщиков
            Expanded(
              child: _isLoading
                  ? const Center(child: CircularProgressIndicator(color: Color(0xFF10B981)))
                  : filtered.isEmpty
                      ? Center(
                          child: Column(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              Icon(Icons.storefront_outlined, size: 54, color: Colors.white.withOpacity(0.2)),
                              const SizedBox(height: 12),
                              const Text('Поставщиков не найдено', style: TextStyle(color: Colors.white70, fontSize: 16)),
                              const SizedBox(height: 4),
                              const Text(
                                'Добавьте поставщика или измените фильтр поиска',
                                textAlign: TextAlign.center,
                                style: TextStyle(color: Colors.white38, fontSize: 12),
                              ),
                            ],
                          ),
                        )
                      : ListView.builder(
                          padding: const EdgeInsets.fromLTRB(16, 10, 16, 24),
                          itemCount: filtered.length,
                          itemBuilder: (context, index) {
                            final s = filtered[index];
                            final hasDebt = s.balance > 0.01;

                            return Container(
                              margin: const EdgeInsets.only(bottom: 10),
                              decoration: BoxDecoration(
                                color: const Color(0xFF1E293B),
                                borderRadius: BorderRadius.circular(14),
                                border: Border.all(
                                  color: hasDebt ? const Color(0xFFEF4444).withOpacity(0.35) : const Color(0xFF334155),
                                ),
                              ),
                              child: InkWell(
                                borderRadius: BorderRadius.circular(14),
                                onTap: () {
                                  Navigator.push(
                                    context,
                                    MaterialPageRoute(builder: (_) => SupplierInvoicesScreen(supplier: s)),
                                  ).then((_) => _loadSuppliers());
                                },
                                child: Padding(
                                  padding: const EdgeInsets.all(14),
                                  child: Column(
                                    children: [
                                      Row(
                                        crossAxisAlignment: CrossAxisAlignment.start,
                                        children: [
                                          Container(
                                            padding: const EdgeInsets.all(10),
                                            decoration: BoxDecoration(
                                              color: hasDebt
                                                  ? const Color(0xFFEF4444).withOpacity(0.15)
                                                  : const Color(0xFF38BDF8).withOpacity(0.15),
                                              borderRadius: BorderRadius.circular(10),
                                            ),
                                            child: Icon(
                                              Icons.storefront_rounded,
                                              color: hasDebt ? const Color(0xFFF87171) : const Color(0xFF38BDF8),
                                              size: 22,
                                            ),
                                          ),
                                          const SizedBox(width: 12),
                                          Expanded(
                                            child: Column(
                                              crossAxisAlignment: CrossAxisAlignment.start,
                                              children: [
                                                Text(
                                                  s.name,
                                                  style: const TextStyle(
                                                    color: Colors.white,
                                                    fontSize: 15,
                                                    fontWeight: FontWeight.bold,
                                                  ),
                                                ),
                                                const SizedBox(height: 3),
                                                if (s.contact != null && s.contact!.isNotEmpty) ...[
                                                  InkWell(
                                                    onTap: () => _callSupplier(s),
                                                    child: Row(
                                                      children: [
                                                        const Icon(Icons.phone_rounded, color: Color(0xFF10B981), size: 13),
                                                        const SizedBox(width: 4),
                                                        Text(
                                                          s.contact!,
                                                          style: const TextStyle(
                                                            color: Color(0xFF10B981),
                                                            fontSize: 12,
                                                            fontWeight: FontWeight.w600,
                                                          ),
                                                        ),
                                                      ],
                                                    ),
                                                  ),
                                                  const SizedBox(height: 2),
                                                ],
                                                if (s.inn != null && s.inn!.isNotEmpty)
                                                  Text(
                                                    'ИНН: ${s.inn}',
                                                    style: const TextStyle(color: Colors.white38, fontSize: 11),
                                                  ),
                                              ],
                                            ),
                                          ),
                                          // Бейдж долга
                                          Container(
                                            padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
                                            decoration: BoxDecoration(
                                              color: hasDebt
                                                  ? const Color(0xFFEF4444).withOpacity(0.18)
                                                  : const Color(0xFF10B981).withOpacity(0.18),
                                              borderRadius: BorderRadius.circular(8),
                                              border: Border.all(
                                                color: hasDebt ? const Color(0xFFEF4444) : const Color(0xFF10B981),
                                                width: 0.8,
                                              ),
                                            ),
                                            child: Column(
                                              crossAxisAlignment: CrossAxisAlignment.end,
                                              children: [
                                                Text(
                                                  hasDebt ? 'ДОЛГ' : 'В РАСЧЁТЕ',
                                                  style: TextStyle(
                                                    color: hasDebt ? const Color(0xFFFCA5A5) : const Color(0xFF6EE7B7),
                                                    fontSize: 10,
                                                    fontWeight: FontWeight.bold,
                                                  ),
                                                ),
                                                Text(
                                                  hasDebt ? '${s.balance.toStringAsFixed(2)} TJS' : '0.00 TJS',
                                                  style: TextStyle(
                                                    color: hasDebt ? Colors.white : const Color(0xFF6EE7B7),
                                                    fontSize: 13,
                                                    fontWeight: FontWeight.bold,
                                                  ),
                                                ),
                                              ],
                                            ),
                                          ),
                                        ],
                                      ),

                                      const SizedBox(height: 10),
                                      const Divider(color: Color(0xFF334155), height: 1),
                                      const SizedBox(height: 8),

                                      Row(
                                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                                        children: [
                                          Row(
                                            children: [
                                              const Icon(Icons.receipt_long_rounded, color: Color(0xFF38BDF8), size: 16),
                                              const SizedBox(width: 4),
                                              const Text(
                                                'Накладные (хронология)',
                                                style: TextStyle(color: Color(0xFF38BDF8), fontSize: 12, fontWeight: FontWeight.w600),
                                              ),
                                              const SizedBox(width: 4),
                                              const Icon(Icons.arrow_forward_ios_rounded, color: Color(0xFF38BDF8), size: 10),
                                            ],
                                          ),
                                          if (hasDebt)
                                            InkWell(
                                              borderRadius: BorderRadius.circular(6),
                                              onTap: () {
                                                SupplierPaymentSheet.show(
                                                  context,
                                                  initialSupplier: s,
                                                  onPaymentSuccess: _loadSuppliers,
                                                );
                                              },
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
                                                    Icon(Icons.payment_rounded, color: Color(0xFF10B981), size: 13),
                                                    SizedBox(width: 4),
                                                    Text(
                                                      'Оплатить',
                                                      style: TextStyle(color: Color(0xFF10B981), fontSize: 11, fontWeight: FontWeight.bold),
                                                    ),
                                                  ],
                                                ),
                                              ),
                                            ),
                                        ],
                                      ),
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

  Widget _filterChip(String type, String label, {bool isDebtBadge = false}) {
    final isSelected = _filterType == type;
    return InkWell(
      borderRadius: BorderRadius.circular(8),
      onTap: () => setState(() => _filterType = type),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        decoration: BoxDecoration(
          color: isSelected
              ? (isDebtBadge ? const Color(0xFFEF4444) : const Color(0xFF10B981))
              : const Color(0xFF1E293B),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(
            color: isSelected
                ? (isDebtBadge ? const Color(0xFFEF4444) : const Color(0xFF10B981))
                : const Color(0xFF334155),
          ),
        ),
        child: Text(
          label,
          style: TextStyle(
            color: isSelected ? Colors.white : Colors.white70,
            fontSize: 12,
            fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
          ),
        ),
      ),
    );
  }
}
