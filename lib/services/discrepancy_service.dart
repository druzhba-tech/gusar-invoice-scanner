import 'dart:io';
import 'dart:typed_data';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';
import 'package:intl/intl.dart';
import '../models/invoice_document.dart';
import '../models/invoice_item.dart';

class DiscrepancyService {
  static final DiscrepancyService _instance = DiscrepancyService._internal();
  factory DiscrepancyService() => _instance;
  DiscrepancyService._internal();

  // Генерация официального PDF-акта расхождений с цифровой подписью
  Future<File> generateDiscrepancyActPdf({
    required InvoiceDocument document,
    required Uint8List? driverSignatureBytes,
    required String receiverName,
    required String driverName,
  }) async {
    final pdf = pw.Document();

    final discrepancyItems = document.items.where((i) {
      return i.defectiveQuantity > 0 || (i.verifiedQuantity > 0 && i.verifiedQuantity != i.quantity);
    }).toList();

    final dateFormat = DateFormat('dd.MM.yyyy HH:mm');

    pdf.addPage(
      pw.Page(
        pageFormat: PdfPageFormat.a4,
        margin: const pw.EdgeInsets.all(32),
        build: (pw.Context context) {
          return pw.Column(
            crossContent: pw.CrossAxisAlignment.start,
            children: [
              // Шапка документа
              pw.Row(
                mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
                children: [
                  pw.Text('СЕТЬ МАГАЗИНОВ GUSAR (gusar.tj)',
                      style: pw.TextStyle(fontSize: 16, fontWeight: pw.FontWeight.bold, color: PdfColors.teal800)),
                  pw.Text('АКТ РАСХОЖДЕНИЙ №${document.invoiceNumber}',
                      style: pw.TextStyle(fontSize: 14, fontWeight: pw.FontWeight.bold, color: PdfColors.red800)),
                ],
              ),
              pw.Divider(thickness: 1.5, color: PdfColors.grey400),
              pw.SizedBox(height: 10),

              // Реквизиты
              pw.Text('Дата составления: ${dateFormat.format(DateTime.now())}'),
              pw.Text('Поставщик: ${document.supplierName}'),
              pw.Text('Накладная: №${document.invoiceNumber} от ${DateFormat('dd.MM.yyyy').format(document.invoiceDate)}'),
              pw.Text('Товаровед: $receiverName'),
              pw.Text('Водитель-экспедитор: $driverName'),
              pw.SizedBox(height: 15),

              // Таблица расхождений
              pw.Text('ВЫЯВЛЕННЫЕ РАСХОЖДЕНИЯ И БРАК:',
                  style: pw.TextStyle(fontSize: 12, fontWeight: pw.FontWeight.bold)),
              pw.SizedBox(height: 8),

              pw.Table(
                border: pw.TableBorder.all(color: PdfColors.grey400),
                children: [
                  // Заголовок таблицы
                  pw.TableRow(
                    decoration: const pw.BoxDecoration(color: PdfColors.grey200),
                    children: [
                      _cell('Наименование товара', isHeader: true),
                      _cell('По накладной', isHeader: true),
                      _cell('Принято факт', isHeader: true),
                      _cell('Брак / Недостача', isHeader: true),
                      _cell('Сумма претензии', isHeader: true),
                    ],
                  ),
                  // Строки с расхождениями
                  ...discrepancyItems.map((item) {
                    final shortage = item.quantity - item.verifiedQuantity;
                    final totalDiff = item.defectiveQuantity > 0 ? item.defectiveQuantity : (shortage > 0 ? shortage : 0.0);
                    final claimAmount = totalDiff * item.buyPrice;

                    return pw.TableRow(
                      children: [
                        _cell(item.matchedProductName ?? item.rawName),
                        _cell('${item.quantity} ${item.unit}'),
                        _cell('${item.verifiedQuantity} ${item.unit}'),
                        _cell('$totalDiff ${item.unit} (${item.defectNotes ?? 'Недостача'})'),
                        _cell('${claimAmount.toStringAsFixed(2)} TJS'),
                      ],
                    );
                  }),
                ],
              ),

              pw.Spacer(),

              // Блок подписей
              pw.Row(
                mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
                crossAxisAlignment: pw.CrossAxisAlignment.end,
                children: [
                  pw.Column(
                    crossAxisAlignment: pw.CrossAxisAlignment.start,
                    children: [
                      pw.Text('Товар принял (Магазин):'),
                      pw.SizedBox(height: 20),
                      pw.Text('Подпись: __________________ / $receiverName /'),
                    ],
                  ),
                  pw.Column(
                    crossAxisAlignment: pw.CrossAxisAlignment.start,
                    children: [
                      pw.Text('Претензию подтверждаю (Экспедитор):'),
                      pw.SizedBox(height: 5),
                      if (driverSignatureBytes != null)
                        pw.Image(
                          pw.MemoryImage(driverSignatureBytes),
                          width: 140,
                          height: 50,
                        )
                      else
                        pw.Text('Подпись: __________________'),
                      pw.Text('/ $driverName /'),
                    ],
                  ),
                ],
              ),
              pw.SizedBox(height: 15),
              pw.Center(
                child: pw.Text('Сформировано автоматически в мобильном приложении Gusar Scanner',
                    style: const pw.TextStyle(fontSize: 9, color: PdfColors.grey600)),
              ),
            ],
          );
        },
      ),
    );

    final outputDir = await getApplicationDocumentsDirectory();
    final file = File('${outputDir.path}/act_discrepancy_${document.invoiceNumber}.pdf');
    await file.writeAsBytes(await pdf.save());
    return file;
  }

  static pw.Widget _cell(String text, {bool isHeader = false}) {
    return pw.Padding(
      padding: const pw.EdgeInsets.all(6),
      child: pw.Text(
        text,
        style: pw.TextStyle(
          fontSize: isHeader ? 10 : 9,
          fontWeight: isHeader ? pw.FontWeight.bold : pw.FontWeight.normal,
        ),
      ),
    );
  }

  // Отправка Акта расхождений экспедитору в Telegram / WhatsApp
  Future<void> shareDiscrepancyAct(File pdfFile, String invoiceNumber) async {
    await Share.shareXFiles(
      [XFile(pdfFile.path)],
      text: 'Акт расхождений по накладной №$invoiceNumber (Сеть Gusar)',
    );
  }
}
