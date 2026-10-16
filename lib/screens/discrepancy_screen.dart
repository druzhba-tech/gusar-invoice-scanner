import 'dart:io';
import 'package:flutter/material.dart';
import 'package:signature/signature.dart';
import 'package:image_picker/image_picker.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/invoice_document.dart';
import '../models/invoice_item.dart';
import '../services/discrepancy_service.dart';
import '../utils/top_notification.dart';

class DiscrepancyScreen extends StatefulWidget {
  final InvoiceDocument document;

  const DiscrepancyScreen({super.key, required this.document});

  @override
  State<DiscrepancyScreen> createState() => _DiscrepancyScreenState();
}

class _DiscrepancyScreenState extends State<DiscrepancyScreen> {
  final DiscrepancyService _discrepancyService = DiscrepancyService();

  late SignatureController _sigController;
  final TextEditingController _driverNameCtrl = TextEditingController(text: '');
  final TextEditingController _receiverNameCtrl = TextEditingController(text: '');

  final List<String> _defectPhotos = [];
  bool _isGeneratingPdf = false;

  @override
  void initState() {
    super.initState();
    _sigController = SignatureController(
      penStrokeWidth: 3,
      penColor: Colors.black,
      exportBackgroundColor: Colors.white,
    );
    _loadEmployeeLogin();
  }

  void _loadEmployeeLogin() async {
    final prefs = await SharedPreferences.getInstance();
    final username = prefs.getString('logged_username') ?? prefs.getString('saved_username') ?? '';
    if (mounted && username.isNotEmpty) {
      setState(() {
        _receiverNameCtrl.text = username;
      });
    }
  }

  @override
  void dispose() {
    _sigController.dispose();
    _driverNameCtrl.dispose();
    _receiverNameCtrl.dispose();
    super.dispose();
  }

  void _addDefectPhoto() async {
    final picker = ImagePicker();
    final photo = await picker.pickImage(source: ImageSource.camera, imageQuality: 85);
    if (photo != null) {
      setState(() => _defectPhotos.add(photo.path));
    }
  }

  // Диалог выбора товара из накладной и фиксации брака/недостачи
  void _showAddDiscrepancyDialog() {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: const Color(0xFF1E293B),
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (modalCtx) {
        return Container(
          height: MediaQuery.of(context).size.height * 0.75,
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  const Text('Выберите товар из накладной',
                      style: TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.bold)),
                  IconButton(
                    icon: const Icon(Icons.close, color: Colors.white54),
                    onPressed: () => Navigator.pop(modalCtx),
                  ),
                ],
              ),
              const Text('Укажите позицию, по которой обнаружен брак, бой или недовоз:',
                  style: TextStyle(color: Colors.white60, fontSize: 12)),
              const SizedBox(height: 12),
              Expanded(
                child: ListView.separated(
                  itemCount: widget.document.items.length,
                  separatorBuilder: (_, __) => const Divider(color: Colors.white10),
                  itemBuilder: (ctx, i) {
                    final item = widget.document.items[i];
                    final hasIssue = item.defectiveQuantity > 0 || (item.verifiedQuantity > 0 && item.verifiedQuantity != item.quantity);

                    return ListTile(
                      contentPadding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                      leading: CircleAvatar(
                        backgroundColor: hasIssue ? Colors.redAccent.withOpacity(0.2) : const Color(0xFF0F172A),
                        child: Text('#${i + 1}',
                            style: TextStyle(
                              color: hasIssue ? Colors.redAccent : const Color(0xFF38BDF8),
                              fontWeight: FontWeight.bold,
                              fontSize: 12,
                            )),
                      ),
                      title: Text(item.matchedProductName ?? item.rawName,
                          style: const TextStyle(color: Colors.white, fontSize: 13, fontWeight: FontWeight.w600)),
                      subtitle: Text(
                        'По накладной: ${item.quantity} ${item.unit} • Цена: ${item.buyPrice.toStringAsFixed(2)} TJS'
                        '${hasIssue ? ' • [Уже в акте: ${item.defectiveQuantity > 0 ? item.defectiveQuantity : (item.quantity - item.verifiedQuantity)} ${item.unit}]' : ''}',
                        style: TextStyle(color: hasIssue ? Colors.orangeAccent : Colors.white54, fontSize: 11),
                      ),
                      trailing: ElevatedButton(
                        style: ElevatedButton.styleFrom(
                          backgroundColor: hasIssue ? Colors.orangeAccent : const Color(0xFF10B981),
                          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                        ),
                        onPressed: () {
                          Navigator.pop(modalCtx);
                          _showEditItemDiscrepancyDialog(item, i + 1);
                        },
                        child: Text(hasIssue ? 'Изменить' : '+ Добавить',
                            style: const TextStyle(color: Colors.white, fontSize: 11, fontWeight: FontWeight.bold)),
                      ),
                    );
                  },
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  // Диалог ввода параметров брака или недостачи по выбранному товару
  void _showEditItemDiscrepancyDialog(InvoiceItem item, int itemIndex) {
    String problemType = item.defectiveQuantity > 0 ? 'Брак' : 'Недостача';
    double count = item.defectiveQuantity > 0
        ? item.defectiveQuantity
        : ((item.quantity - item.verifiedQuantity) > 0 ? (item.quantity - item.verifiedQuantity) : 1.0);
    final countCtrl = TextEditingController(text: count.toStringAsFixed(count.truncateToDouble() == count ? 0 : 2));
    final noteCtrl = TextEditingController(text: item.defectNotes ?? '');

    showDialog(
      context: context,
      builder: (dlgCtx) => StatefulBuilder(
        builder: (ctx, setDlgState) {
          final claimSum = (double.tryParse(countCtrl.text.replaceAll(',', '.')) ?? 0.0) * item.buyPrice;

          return AlertDialog(
            backgroundColor: const Color(0xFF1E293B),
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
            title: Row(
              children: [
                const Icon(Icons.report_problem_rounded, color: Colors.redAccent, size: 24),
                const SizedBox(width: 8),
                Expanded(
                  child: Text('Позиция #$itemIndex: Расхождение',
                      style: const TextStyle(color: Colors.white, fontSize: 15, fontWeight: FontWeight.bold)),
                ),
              ],
            ),
            content: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(item.matchedProductName ?? item.rawName,
                      style: const TextStyle(color: Color(0xFF38BDF8), fontSize: 13, fontWeight: FontWeight.bold)),
                  const SizedBox(height: 4),
                  Text('По накладной всего: ${item.quantity} ${item.unit} • Цена: ${item.buyPrice.toStringAsFixed(2)} TJS',
                      style: const TextStyle(color: Colors.white54, fontSize: 11)),
                  const SizedBox(height: 16),

                  const Text('Тип расхождения:', style: TextStyle(color: Colors.white70, fontSize: 12)),
                  const SizedBox(height: 6),
                  Wrap(
                    spacing: 8,
                    children: ['Недостача', 'Брак', 'Бой', 'Срок годности'].map((type) {
                      final isSelected = problemType == type;
                      return ChoiceChip(
                        label: Text(type),
                        selected: isSelected,
                        selectedColor: Colors.redAccent.withOpacity(0.3),
                        labelStyle: TextStyle(
                          color: isSelected ? Colors.redAccent : Colors.white70,
                          fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
                          fontSize: 11,
                        ),
                        backgroundColor: const Color(0xFF0F172A),
                        onSelected: (val) {
                          if (val) setDlgState(() => problemType = type);
                        },
                      );
                    }).toList(),
                  ),
                  const SizedBox(height: 14),

                  Text('Количество расхождения (${item.unit}):',
                      style: const TextStyle(color: Colors.white70, fontSize: 12)),
                  const SizedBox(height: 6),
                  Row(
                    children: [
                      IconButton(
                        icon: const Icon(Icons.remove_circle_outline, color: Colors.white70),
                        onPressed: () {
                          double cur = double.tryParse(countCtrl.text.replaceAll(',', '.')) ?? 1.0;
                          if (cur > 1) {
                            cur -= 1;
                            setDlgState(() => countCtrl.text = cur.toStringAsFixed(cur.truncateToDouble() == cur ? 0 : 2));
                          }
                        },
                      ),
                      Expanded(
                        child: TextField(
                          controller: countCtrl,
                          keyboardType: const TextInputType.numberWithOptions(decimal: true),
                          textAlign: TextAlign.center,
                          style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 16),
                          decoration: InputDecoration(
                            filled: true,
                            fillColor: const Color(0xFF0F172A),
                            border: OutlineInputBorder(borderRadius: BorderRadius.circular(8), borderSide: BorderSide.none),
                            contentPadding: const EdgeInsets.symmetric(vertical: 8),
                          ),
                          onChanged: (_) => setDlgState(() {}),
                        ),
                      ),
                      IconButton(
                        icon: const Icon(Icons.add_circle_outline, color: Colors.white70),
                        onPressed: () {
                          double cur = double.tryParse(countCtrl.text.replaceAll(',', '.')) ?? 0.0;
                          cur += 1;
                          setDlgState(() => countCtrl.text = cur.toStringAsFixed(cur.truncateToDouble() == cur ? 0 : 2));
                        },
                      ),
                    ],
                  ),
                  const SizedBox(height: 14),

                  const Text('Причина / Примечание для экспедитора:', style: TextStyle(color: Colors.white70, fontSize: 12)),
                  const SizedBox(height: 6),
                  TextField(
                    controller: noteCtrl,
                    style: const TextStyle(color: Colors.white, fontSize: 13),
                    decoration: InputDecoration(
                      hintText: 'Например: разбита банка, порвана упаковка...',
                      hintStyle: const TextStyle(color: Colors.white38, fontSize: 12),
                      filled: true,
                      fillColor: const Color(0xFF0F172A),
                      border: OutlineInputBorder(borderRadius: BorderRadius.circular(8), borderSide: BorderSide.none),
                      contentPadding: const EdgeInsets.all(10),
                    ),
                  ),
                  const SizedBox(height: 14),

                  Container(
                    padding: const EdgeInsets.all(10),
                    decoration: BoxDecoration(
                      color: Colors.red.shade900.withOpacity(0.2),
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(color: Colors.redAccent.withOpacity(0.3)),
                    ),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        const Text('Сумма претензии:', style: TextStyle(color: Colors.white70, fontSize: 12)),
                        Text('${claimSum.toStringAsFixed(2)} TJS',
                            style: const TextStyle(color: Colors.redAccent, fontWeight: FontWeight.bold, fontSize: 14)),
                      ],
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
                style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFF10B981)),
                onPressed: () {
                  final val = double.tryParse(countCtrl.text.replaceAll(',', '.')) ?? 0.0;
                  if (val <= 0) {
                    TopNotification.showWarning(context, 'Укажите количество больше нуля!');
                    return;
                  }

                  setState(() {
                    if (problemType == 'Брак' || problemType == 'Бой' || problemType == 'Срок годности') {
                      item.defectiveQuantity = val;
                      item.verifiedQuantity = (item.quantity - val).clamp(0.0, item.quantity);
                    } else {
                      item.defectiveQuantity = 0.0;
                      item.verifiedQuantity = (item.quantity - val).clamp(0.0, item.quantity);
                    }
                    item.defectNotes = noteCtrl.text.trim().isNotEmpty
                        ? '$problemType: ${noteCtrl.text.trim()}'
                        : problemType;
                  });

                  Navigator.pop(dlgCtx);
                  TopNotification.showSuccess(context, 'Расхождение по позиции #${itemIndex} зафиксировано!');
                },
                child: const Text('Сохранить', style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
              ),
            ],
          );
        },
      ),
    );
  }

  void _removeDiscrepancy(InvoiceItem item) {
    setState(() {
      item.defectiveQuantity = 0.0;
      item.verifiedQuantity = item.quantity;
      item.defectNotes = null;
    });
    TopNotification.showSuccess(context, 'Расхождение по позиции удалено');
  }

  void _generateAndSharePdf() async {
    final discrepancyItems = widget.document.items.where((i) {
      return i.defectiveQuantity > 0 || (i.verifiedQuantity > 0 && i.verifiedQuantity != i.quantity);
    }).toList();

    if (discrepancyItems.isEmpty) {
      TopNotification.showWarning(context, 'Добавьте хотя бы один товар с браком или недостачей!');
      return;
    }

    setState(() => _isGeneratingPdf = true);

    try {
      final sigBytes = await _sigController.toPngBytes();

      final pdfFile = await _discrepancyService.generateDiscrepancyActPdf(
        document: widget.document,
        driverSignatureBytes: sigBytes,
        receiverName: _receiverNameCtrl.text.trim(),
        driverName: _driverNameCtrl.text.trim(),
      );

      setState(() => _isGeneratingPdf = false);

      await _discrepancyService.shareDiscrepancyAct(pdfFile, widget.document.invoiceNumber);
    } catch (e) {
      setState(() => _isGeneratingPdf = false);
      TopNotification.showError(context, 'Ошибка создания акта: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    final discrepancyItems = widget.document.items.where((i) {
      return i.defectiveQuantity > 0 || (i.verifiedQuantity > 0 && i.verifiedQuantity != i.quantity);
    }).toList();

    double totalClaim = 0.0;
    for (var it in discrepancyItems) {
      final diff = it.defectiveQuantity > 0 ? it.defectiveQuantity : (it.quantity - it.verifiedQuantity);
      totalClaim += (diff > 0 ? diff : 0.0) * it.buyPrice;
    }

    return Scaffold(
      backgroundColor: const Color(0xFF0F172A),
      appBar: AppBar(
        backgroundColor: const Color(0xFF1E293B),
        elevation: 0,
        title: const Text('Акт расхождений и брака', style: TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.bold)),
        actions: [
          IconButton(
            icon: const Icon(Icons.add_circle_outline, color: Color(0xFF10B981)),
            tooltip: 'Добавить товар из накладной',
            onPressed: _showAddDiscrepancyDialog,
          ),
        ],
      ),
      body: _isGeneratingPdf
          ? const Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  CircularProgressIndicator(color: Color(0xFF10B981)),
                  SizedBox(height: 16),
                  Text('Формирование официального PDF с поддержкой кириллицы...', style: TextStyle(color: Colors.white70, fontSize: 13)),
                ],
              ),
            )
          : SingleChildScrollView(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // Сводный блок претензии
                  Container(
                    padding: const EdgeInsets.all(14),
                    decoration: BoxDecoration(
                      color: discrepancyItems.isNotEmpty ? Colors.red.shade900.withOpacity(0.3) : const Color(0xFF1E293B),
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(
                        color: discrepancyItems.isNotEmpty ? Colors.redAccent.withOpacity(0.5) : Colors.white12,
                      ),
                    ),
                    child: Column(
                      children: [
                        Row(
                          children: [
                            Icon(
                              discrepancyItems.isNotEmpty ? Icons.report_problem_rounded : Icons.info_outline,
                              color: discrepancyItems.isNotEmpty ? Colors.redAccent : const Color(0xFF38BDF8),
                              size: 26,
                            ),
                            const SizedBox(width: 12),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    discrepancyItems.isNotEmpty
                                        ? 'Обнаружено расхождений: ${discrepancyItems.length} позиций'
                                        : 'В накладной пока не отмечено расхождений',
                                    style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 14),
                                  ),
                                  const SizedBox(height: 2),
                                  Text(
                                    'Накладная №${widget.document.invoiceNumber} от ${widget.document.supplierName}',
                                    style: const TextStyle(color: Colors.white70, fontSize: 11),
                                  ),
                                ],
                              ),
                            ),
                          ],
                        ),
                        if (discrepancyItems.isNotEmpty) ...[
                          const SizedBox(height: 10),
                          const Divider(color: Colors.white12, height: 1),
                          const SizedBox(height: 8),
                          Row(
                            mainAxisAlignment: MainAxisAlignment.spaceBetween,
                            children: [
                              const Text('ОБЩАЯ СУММА ПРЕТЕНЗИИ:', style: TextStyle(color: Colors.white70, fontSize: 11, fontWeight: FontWeight.bold)),
                              Text('${totalClaim.toStringAsFixed(2)} TJS',
                                  style: const TextStyle(color: Colors.redAccent, fontSize: 15, fontWeight: FontWeight.bold)),
                            ],
                          ),
                        ],
                      ],
                    ),
                  ),

                  const SizedBox(height: 16),

                  // Кнопка добавления товара из накладной
                  ElevatedButton.icon(
                    style: ElevatedButton.styleFrom(
                      backgroundColor: const Color(0xFF0284C7),
                      foregroundColor: Colors.white,
                      minimumSize: const Size(double.infinity, 46),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                    ),
                    icon: const Icon(Icons.add, size: 20),
                    label: const Text('+ Добавить позицию из накладной в Акт',
                        style: TextStyle(fontSize: 13, fontWeight: FontWeight.bold)),
                    onPressed: _showAddDiscrepancyDialog,
                  ),

                  const SizedBox(height: 18),

                  // Список проблемных товаров
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      const Text('СПИСОК РАСХОЖДЕНИЙ В АКТЕ:',
                          style: TextStyle(color: Colors.white54, fontSize: 11, fontWeight: FontWeight.bold, letterSpacing: 1.1)),
                      Text('${discrepancyItems.length} поз.', style: const TextStyle(color: Color(0xFF38BDF8), fontSize: 11, fontWeight: FontWeight.bold)),
                    ],
                  ),
                  const SizedBox(height: 8),

                  if (discrepancyItems.isEmpty)
                    Container(
                      padding: const EdgeInsets.all(24),
                      alignment: Alignment.center,
                      decoration: BoxDecoration(
                        color: const Color(0xFF1E293B),
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(color: Colors.white12),
                      ),
                      child: const Column(
                        children: [
                          Icon(Icons.check_circle_outline, color: Color(0xFF10B981), size: 40),
                          SizedBox(height: 8),
                          Text('Расхождений нет', style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 14)),
                          SizedBox(height: 4),
                          Text('Нажмите кнопку выше, чтобы добавить позицию с браком, боем или недостачей',
                              textAlign: TextAlign.center, style: TextStyle(color: Colors.white54, fontSize: 12)),
                        ],
                      ),
                    )
                  else
                    ...discrepancyItems.map((item) {
                      final itemIndex = widget.document.items.indexOf(item) + 1;
                      final shortage = item.quantity - item.verifiedQuantity;
                      final diff = item.defectiveQuantity > 0 ? item.defectiveQuantity : (shortage > 0 ? shortage : 0.0);
                      final claimAmount = diff * item.buyPrice;

                      return Container(
                        margin: const EdgeInsets.only(bottom: 10),
                        decoration: BoxDecoration(
                          color: const Color(0xFF1E293B),
                          borderRadius: BorderRadius.circular(12),
                          border: Border.all(color: Colors.redAccent.withOpacity(0.4)),
                        ),
                        child: Padding(
                          padding: const EdgeInsets.all(12),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Row(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  CircleAvatar(
                                    radius: 12,
                                    backgroundColor: Colors.redAccent.withOpacity(0.2),
                                    child: Text('#$itemIndex',
                                        style: const TextStyle(color: Colors.redAccent, fontSize: 10, fontWeight: FontWeight.bold)),
                                  ),
                                  const SizedBox(width: 8),
                                  Expanded(
                                    child: Text(
                                      item.matchedProductName ?? item.rawName,
                                      style: const TextStyle(color: Colors.white, fontSize: 13, fontWeight: FontWeight.bold),
                                    ),
                                  ),
                                  IconButton(
                                    padding: EdgeInsets.zero,
                                    constraints: const BoxConstraints(),
                                    icon: const Icon(Icons.edit_outlined, color: Color(0xFF38BDF8), size: 18),
                                    onPressed: () => _showEditItemDiscrepancyDialog(item, itemIndex),
                                  ),
                                  const SizedBox(width: 10),
                                  IconButton(
                                    padding: EdgeInsets.zero,
                                    constraints: const BoxConstraints(),
                                    icon: const Icon(Icons.delete_outline, color: Colors.redAccent, size: 18),
                                    onPressed: () => _removeDiscrepancy(item),
                                  ),
                                ],
                              ),
                              const SizedBox(height: 8),
                              Row(
                                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                                children: [
                                  Text(
                                    'По накладной: ${item.quantity} ${item.unit} ➔ Факт: ${item.verifiedQuantity} ${item.unit}',
                                    style: const TextStyle(color: Colors.white70, fontSize: 11),
                                  ),
                                  Text(
                                    'Брак/Недовоз: $diff ${item.unit}',
                                    style: const TextStyle(color: Colors.redAccent, fontSize: 11, fontWeight: FontWeight.bold),
                                  ),
                                ],
                              ),
                              const SizedBox(height: 4),
                              Row(
                                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                                children: [
                                  Text(
                                    item.defectNotes != null && item.defectNotes!.isNotEmpty
                                        ? 'Причина: ${item.defectNotes}'
                                        : 'Причина: Не указана',
                                    style: const TextStyle(color: Colors.orangeAccent, fontSize: 11),
                                  ),
                                  Text(
                                    'Претензия: ${claimAmount.toStringAsFixed(2)} TJS',
                                    style: const TextStyle(color: Color(0xFF10B981), fontWeight: FontWeight.bold, fontSize: 12),
                                  ),
                                ],
                              ),
                            ],
                          ),
                        ),
                      );
                    }),

                  const SizedBox(height: 16),

                  // Фотофиксация дефектов
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      const Text('ФОТОФИКСАЦИЯ БРАКА / БОЯ:',
                          style: TextStyle(color: Colors.white54, fontSize: 11, fontWeight: FontWeight.bold)),
                      TextButton.icon(
                        icon: const Icon(Icons.camera_alt, color: Color(0xFF10B981), size: 18),
                        label: const Text('Сделать фото', style: TextStyle(color: Color(0xFF10B981), fontSize: 12)),
                        onPressed: _addDefectPhoto,
                      ),
                    ],
                  ),

                  if (_defectPhotos.isNotEmpty)
                    SizedBox(
                      height: 80,
                      child: ListView.builder(
                        scrollDirection: Axis.horizontal,
                        itemCount: _defectPhotos.length,
                        itemBuilder: (ctx, i) {
                          return Container(
                            margin: const EdgeInsets.only(right: 8),
                            width: 80,
                            decoration: BoxDecoration(
                              borderRadius: BorderRadius.circular(8),
                              image: DecorationImage(image: FileImage(File(_defectPhotos[i])), fit: BoxFit.cover),
                            ),
                          );
                        },
                      ),
                    ),

                  const SizedBox(height: 16),

                  // Поля подписей
                  TextField(
                    controller: _receiverNameCtrl,
                    style: const TextStyle(color: Colors.white),
                    decoration: InputDecoration(
                      labelText: 'ФИО Товароведа / Приёмщика (логин сотрудника)',
                      labelStyle: const TextStyle(color: Colors.white54, fontSize: 12),
                      prefixIcon: const Icon(Icons.person_outline, color: Color(0xFF10B981)),
                      filled: true,
                      fillColor: const Color(0xFF1E293B),
                      border: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: BorderSide.none),
                    ),
                  ),
                  const SizedBox(height: 10),
                  TextField(
                    controller: _driverNameCtrl,
                    style: const TextStyle(color: Colors.white),
                    decoration: InputDecoration(
                      labelText: 'ФИО Водителя-экспедитора (пустое или введите имя)',
                      labelStyle: const TextStyle(color: Colors.white54, fontSize: 12),
                      hintText: 'ФИО водителя...',
                      hintStyle: const TextStyle(color: Colors.white24, fontSize: 12),
                      prefixIcon: const Icon(Icons.local_shipping_outlined, color: Color(0xFF38BDF8)),
                      filled: true,
                      fillColor: const Color(0xFF1E293B),
                      border: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: BorderSide.none),
                    ),
                  ),

                  const SizedBox(height: 16),

                  // Сенсорная цифровая роспись водителя на экране
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      const Text('РОСПИСЬ ЭКСПЕДИТОРА НА ЭКРАНЕ:',
                          style: TextStyle(color: Colors.white54, fontSize: 11, fontWeight: FontWeight.bold)),
                      TextButton(
                        onPressed: () => _sigController.clear(),
                        child: const Text('Очистить', style: TextStyle(color: Colors.redAccent, fontSize: 12)),
                      ),
                    ],
                  ),
                  Container(
                    height: 140,
                    decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(12),
                      child: Signature(
                        controller: _sigController,
                        backgroundColor: Colors.white,
                      ),
                    ),
                  ),

                  const SizedBox(height: 24),

                  // Кнопка создания и отправки PDF
                  ElevatedButton.icon(
                    style: ElevatedButton.styleFrom(
                      backgroundColor: const Color(0xFF10B981),
                      minimumSize: const Size(double.infinity, 50),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                    ),
                    icon: const Icon(Icons.picture_as_pdf, color: Colors.white),
                    label: const Text('Сформировать официальный Акт (PDF) и отправить',
                        style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 13)),
                    onPressed: _generateAndSharePdf,
                  ),
                ],
              ),
            ),
    );
  }
}
