import 'dart:io';
import 'package:flutter/material.dart';
import 'package:signature/signature.dart';
import 'package:image_picker/image_picker.dart';
import '../models/invoice_document.dart';
import '../services/discrepancy_service.dart';

class DiscrepancyScreen extends StatefulWidget {
  final InvoiceDocument document;

  const DiscrepancyScreen({super.key, required this.document});

  @override
  State<DiscrepancyScreen> createState() => _DiscrepancyScreenState();
}

class _DiscrepancyScreenState extends State<DiscrepancyScreen> {
  final DiscrepancyService _discrepancyService = DiscrepancyService();

  late SignatureController _sigController;
  final TextEditingController _driverNameCtrl = TextEditingController(text: 'Экспедитор Поставщика');
  final TextEditingController _receiverNameCtrl = TextEditingController(text: 'Товаровед Gusar');

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
  }

  @override
  void dispose() {
    _sigController.dispose();
    super.dispose();
  }

  void _addDefectPhoto() async {
    final picker = ImagePicker();
    final photo = await picker.pickImage(source: ImageSource.camera);
    if (photo != null) {
      setState(() => _defectPhotos.add(photo.path));
    }
  }

  void _generateAndSharePdf() async {
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
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Ошибка создания акта: $e')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final discrepancyItems = widget.document.items.where((i) {
      return i.defectiveQuantity > 0 || (i.verifiedQuantity > 0 && i.verifiedQuantity != i.quantity);
    }).toList();

    return Scaffold(
      backgroundColor: const Color(0xFF0F172A),
      appBar: AppBar(
        backgroundColor: const Color(0xFF1E293B),
        title: const Text('Акт расхождений и брака', style: TextStyle(color: Colors.white, fontSize: 16)),
      ),
      body: _isGeneratingPdf
          ? const Center(child: CircularProgressIndicator(color: Color(0xFF10B981)))
          : SingleChildScrollView(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // Сводка претензии
                  Container(
                    padding: const EdgeInsets.all(14),
                    decoration: BoxDecoration(
                      color: Colors.red.shade900.withOpacity(0.3),
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(color: Colors.redAccent.withOpacity(0.5)),
                    ),
                    child: Row(
                      children: [
                        const Icon(Icons.report_problem_rounded, color: Colors.redAccent, size: 24),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text('Обнаружено расхождений: ${discrepancyItems.length} позиций',
                                  style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 13)),
                              const SizedBox(height: 2),
                              Text('Поставщик: ${widget.document.supplierName}',
                                  style: const TextStyle(color: Colors.white70, fontSize: 11)),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),

                  const SizedBox(height: 16),

                  // Список проблемных товаров
                  const Text('СПИСОК РАСХОЖДЕНИЙ:',
                      style: TextStyle(color: Colors.white54, fontSize: 11, fontWeight: FontWeight.bold, letterSpacing: 1.1)),
                  const SizedBox(height: 8),

                  ...discrepancyItems.map((item) {
                    final shortage = item.quantity - item.verifiedQuantity;
                    return Card(
                      color: const Color(0xFF1E293B),
                      margin: const EdgeInsets.only(bottom: 8),
                      child: ListTile(
                        title: Text(item.matchedProductName ?? item.rawName, style: const TextStyle(color: Colors.white, fontSize: 13)),
                        subtitle: Text(
                          'План: ${item.quantity} • Факт: ${item.verifiedQuantity} • Брак: ${item.defectiveQuantity} (${item.defectNotes ?? "Недостача $shortage"})',
                          style: const TextStyle(color: Colors.redAccent, fontSize: 11),
                        ),
                      ),
                    );
                  }),

                  const SizedBox(height: 16),

                  // Фотофиксация дефектов
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      const Text('ФОТОФИКСАЦИЯ БРАКА:',
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
                    decoration: const InputDecoration(labelText: 'ФИО Товароведа', labelStyle: TextStyle(color: Colors.white54)),
                  ),
                  const SizedBox(height: 8),
                  TextField(
                    controller: _driverNameCtrl,
                    style: const TextStyle(color: Colors.white),
                    decoration: const InputDecoration(labelText: 'ФИО Водителя-экспедитора', labelStyle: TextStyle(color: Colors.white54)),
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
                    label: const Text('Сформировать Акт и отправить в Telegram/WhatsApp',
                        style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 13)),
                    onPressed: _generateAndSharePdf,
                  ),
                ],
              ),
            ),
    );
  }
}
