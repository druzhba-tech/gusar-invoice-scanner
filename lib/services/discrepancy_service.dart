import 'dart:io';
import 'dart:typed_data';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:printing/printing.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';
import 'package:intl/intl.dart';
import '../models/invoice_document.dart';
import '../models/invoice_item.dart';

class DiscrepancyService {
  static final DiscrepancyService _instance = DiscrepancyService._internal();
  factory DiscrepancyService() => _instance;
  DiscrepancyService._internal();

  /// Генерация официального PDF-акта расхождений с поддержкой кириллицы (шрифт Roboto) и подписью
  Future<File> generateDiscrepancyActPdf({
    required InvoiceDocument document,
    required Uint8List? driverSignatureBytes,
    required String receiverName,
    required String driverName,
  }) async {
    // 1. Загружаем шрифты Roboto с полной поддержкой кириллицы (русский + таджикский языки)
    pw.Font? ttfRegular;
    pw.Font? ttfBold;
    try {
      ttfRegular = await PdfGoogleFonts.robotoRegular();
      ttfBold = await PdfGoogleFonts.robotoBold();
    } catch (e) {
      print('PdfGoogleFonts error: $e');
    }

    final theme = (ttfRegular != null && ttfBold != null)
        ? pw.ThemeData.withFont(base: ttfRegular, bold: ttfBold)
        : (ttfRegular != null ? pw.ThemeData.withFont(base: ttfRegular) : pw.ThemeData());

    final pdf = pw.Document(theme: theme);

    final discrepancyItems = document.items.where((i) {
      return i.defectiveQuantity > 0 || (i.verifiedQuantity > 0 && i.verifiedQuantity != i.quantity);
    }).toList();

    final dateFormat = DateFormat('dd.MM.yyyy HH:mm');
    double totalClaimAmount = 0.0;

    for (var item in discrepancyItems) {
      final shortage = item.quantity - item.verifiedQuantity;
      final totalDiff = item.defectiveQuantity > 0 ? item.defectiveQuantity : (shortage > 0 ? shortage : 0.0);
      totalClaimAmount += (totalDiff * item.buyPrice);
    }

    pdf.addPage(
      pw.Page(
        pageFormat: PdfPageFormat.a4,
        margin: const pw.EdgeInsets.symmetric(horizontal: 32, vertical: 28),
        build: (pw.Context context) {
          return pw.Column(
            crossAxisAlignment: pw.CrossAxisAlignment.start,
            children: [
              // Шапка документа
              pw.Row(
                mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
                crossAxisAlignment: pw.CrossAxisAlignment.center,
                children: [
                  pw.Column(
                    crossAxisAlignment: pw.CrossAxisAlignment.start,
                    children: [
                      pw.Text('СЕТЬ МАГАЗИНОВ GUSAR',
                          style: pw.TextStyle(fontSize: 16, fontWeight: pw.FontWeight.bold, color: PdfColors.teal800)),
                      pw.Text('gusar.tj • Служба контроля качества и приёмки',
                          style: const pw.TextStyle(fontSize: 9, color: PdfColors.grey700)),
                    ],
                  ),
                  pw.Container(
                    padding: const pw.EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                    decoration: pw.BoxDecoration(
                      color: PdfColors.red50,
                      borderRadius: pw.BorderRadius.circular(6),
                      border: pw.Border.all(color: PdfColors.red400),
                    ),
                    child: pw.Text('АКТ РАСХОЖДЕНИЙ №${document.invoiceNumber}',
                        style: pw.TextStyle(fontSize: 12, fontWeight: pw.FontWeight.bold, color: PdfColors.red800)),
                  ),
                ],
              ),
              pw.SizedBox(height: 8),
              pw.Divider(thickness: 1.2, color: PdfColors.grey400),
              pw.SizedBox(height: 8),

              // Блок реквизитов накладной
              pw.Container(
                padding: const pw.EdgeInsets.all(10),
                decoration: pw.BoxDecoration(
                  color: PdfColors.grey100,
                  borderRadius: pw.BorderRadius.circular(6),
                ),
                child: pw.Column(
                  crossAxisAlignment: pw.CrossAxisAlignment.start,
                  children: [
                    pw.Row(
                      children: [
                        pw.Expanded(
                          child: pw.Text('Поставщик: ${document.supplierName}',
                              style: pw.TextStyle(fontSize: 10, fontWeight: pw.FontWeight.bold)),
                        ),
                        pw.Text('Дата акта: ${dateFormat.format(DateTime.now())}',
                            style: const pw.TextStyle(fontSize: 10)),
                      ],
                    ),
                    pw.SizedBox(height: 4),
                    pw.Row(
                      children: [
                        pw.Expanded(
                          child: pw.Text(
                              'Накладная: №${document.invoiceNumber} от ${DateFormat('dd.MM.yyyy').format(document.invoiceDate)}',
                              style: const pw.TextStyle(fontSize: 10)),
                        ),
                        pw.Text(
                          receiverName.isNotEmpty ? 'Товаровед: $receiverName' : 'Товаровед: Gusar',
                          style: const pw.TextStyle(fontSize: 10),
                        ),
                      ],
                    ),
                    if (driverName.isNotEmpty) ...[
                      pw.SizedBox(height: 4),
                      pw.Text('Водитель-экспедитор: $driverName', style: const pw.TextStyle(fontSize: 10)),
                    ],
                  ],
                ),
              ),

              pw.SizedBox(height: 14),

              // Заголовок таблицы
              pw.Row(
                mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
                children: [
                  pw.Text('ВЫЯВЛЕННЫЕ РАСХОЖДЕНИЯ И БРАК (${discrepancyItems.length} поз.):',
                      style: pw.TextStyle(fontSize: 11, fontWeight: pw.FontWeight.bold, color: PdfColors.grey900)),
                  if (totalClaimAmount > 0)
                    pw.Text('Сумма претензии: ${totalClaimAmount.toStringAsFixed(2)} TJS',
                        style: pw.TextStyle(fontSize: 11, fontWeight: pw.FontWeight.bold, color: PdfColors.red800)),
                ],
              ),
              pw.SizedBox(height: 6),

              // Таблица выявленных расхождений
              pw.Table(
                border: pw.TableBorder.all(color: PdfColors.grey400, width: 0.8),
                columnWidths: {
                  0: const pw.FlexColumnWidth(0.5), // №
                  1: const pw.FlexColumnWidth(3.0), // Наименование
                  2: const pw.FlexColumnWidth(1.1), // По накл.
                  3: const pw.FlexColumnWidth(1.1), // Факт
                  4: const pw.FlexColumnWidth(1.5), // Разница
                  5: const pw.FlexColumnWidth(1.1), // Цена
                  6: const pw.FlexColumnWidth(1.3), // Претензия
                },
                children: [
                  // Заголовок таблицы
                  pw.TableRow(
                    decoration: const pw.BoxDecoration(color: PdfColors.grey200),
                    children: [
                      _cell('№', isHeader: true),
                      _cell('Наименование товара', isHeader: true),
                      _cell('По накл.', isHeader: true),
                      _cell('Факт', isHeader: true),
                      _cell('Брак / Недовоз', isHeader: true),
                      _cell('Цена', isHeader: true),
                      _cell('Сумма', isHeader: true),
                    ],
                  ),
                  // Строки таблицы
                  ...discrepancyItems.asMap().entries.map((entry) {
                    final idx = entry.key + 1;
                    final item = entry.value;
                    final shortage = item.quantity - item.verifiedQuantity;
                    final totalDiff = item.defectiveQuantity > 0 ? item.defectiveQuantity : (shortage > 0 ? shortage : 0.0);
                    final claimAmount = totalDiff * item.buyPrice;

                    String reason = item.defectNotes ?? (item.defectiveQuantity > 0 ? 'Брак' : 'Недостача');

                    return pw.TableRow(
                      children: [
                        _cell('$idx'),
                        _cell(item.matchedProductName ?? item.rawName),
                        _cell('${item.quantity} ${item.unit}'),
                        _cell('${item.verifiedQuantity} ${item.unit}'),
                        _cell('$totalDiff ${item.unit}\n($reason)'),
                        _cell('${item.buyPrice.toStringAsFixed(2)}'),
                        _cell('${claimAmount.toStringAsFixed(2)} TJS'),
                      ],
                    );
                  }),
                ],
              ),

              pw.SizedBox(height: 10),

              // Итого претензия
              pw.Align(
                alignment: pw.Alignment.centerRight,
                child: pw.Container(
                  padding: const pw.EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                  decoration: pw.BoxDecoration(
                    color: PdfColors.grey100,
                    borderRadius: pw.BorderRadius.circular(4),
                    border: pw.Border.all(color: PdfColors.grey300),
                  ),
                  child: pw.Text(
                    'ВСЕГО К УДЕРЖАНИЮ: ${totalClaimAmount.toStringAsFixed(2)} TJS',
                    style: pw.TextStyle(fontSize: 11, fontWeight: pw.FontWeight.bold, color: PdfColors.red800),
                  ),
                ),
              ),

              pw.Spacer(),

              // Блок официальных подписей сторон
              pw.Container(
                padding: const pw.EdgeInsets.all(12),
                decoration: pw.BoxDecoration(
                  border: pw.Border.all(color: PdfColors.grey300),
                  borderRadius: pw.BorderRadius.circular(6),
                ),
                child: pw.Row(
                  mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
                  crossAxisAlignment: pw.CrossAxisAlignment.end,
                  children: [
                    // Подпись товароведа
                    pw.Column(
                      crossAxisAlignment: pw.CrossAxisAlignment.start,
                      children: [
                        pw.Text('Товар принял (Магазин):',
                            style: pw.TextStyle(fontSize: 10, fontWeight: pw.FontWeight.bold)),
                        pw.SizedBox(height: 18),
                        pw.Text('Подпись: ________________________', style: const pw.TextStyle(fontSize: 9)),
                        pw.SizedBox(height: 4),
                        pw.Text(receiverName.isNotEmpty ? '/ $receiverName /' : '/ Товаровед Gusar /',
                            style: const pw.TextStyle(fontSize: 9, color: PdfColors.grey700)),
                      ],
                    ),

                    // Подпись экспедитора
                    pw.Column(
                      crossAxisAlignment: pw.CrossAxisAlignment.start,
                      children: [
                        pw.Text('Претензию подтверждаю (Экспедитор):',
                            style: pw.TextStyle(fontSize: 10, fontWeight: pw.FontWeight.bold)),
                        pw.SizedBox(height: 6),
                        if (driverSignatureBytes != null)
                          pw.Image(
                            pw.MemoryImage(driverSignatureBytes),
                            width: 140,
                            height: 45,
                          )
                        else
                          pw.SizedBox(
                            height: 25,
                            child: pw.Text('Подпись: ________________________', style: const pw.TextStyle(fontSize: 9)),
                          ),
                        pw.SizedBox(height: 4),
                        pw.Text(driverName.isNotEmpty ? '/ $driverName /' : '/ ________________________ /',
                            style: const pw.TextStyle(fontSize: 9, color: PdfColors.grey700)),
                      ],
                    ),
                  ],
                ),
              ),

              pw.SizedBox(height: 10),
              pw.Center(
                child: pw.Text(
                  'Акт составлен в 2-х экземплярах (по 1 экз. для Магазина и Поставщика). Сформировано в Gusar Scanner.',
                  style: const pw.TextStyle(fontSize: 8, color: PdfColors.grey600),
                ),
              ),
            ],
          );
        },
      ),
    );

    final outputDir = await getApplicationDocumentsDirectory();
    final safeInvoiceNumber = document.invoiceNumber.replaceAll(RegExp(r'[\\/:*?"<>|\s]'), '_');
    final file = File('${outputDir.path}/act_discrepancy_${safeInvoiceNumber}_${DateTime.now().millisecondsSinceEpoch}.pdf');
    await file.writeAsBytes(await pdf.save());
    return file;
  }

  static pw.Widget _cell(String text, {bool isHeader = false}) {
    return pw.Padding(
      padding: const pw.EdgeInsets.symmetric(horizontal: 5, vertical: 4),
      child: pw.Text(
        text,
        style: pw.TextStyle(
          fontSize: isHeader ? 8.5 : 8,
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
