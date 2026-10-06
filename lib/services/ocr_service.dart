import 'dart:convert';
import 'dart:io';
import 'package:http/http.dart' as http;
import 'package:google_mlkit_text_recognition/google_mlkit_text_recognition.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/invoice_document.dart';
import '../models/invoice_item.dart';

class OcrService {
  static final OcrService _instance = OcrService._internal();
  factory OcrService() => _instance;
  OcrService._internal();

  final TextRecognizer _mlKitRecognizer = TextRecognizer(script: TextRecognitionScript.latin);

  Future<String> _getGeminiApiKey() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString('gemini_api_key') ?? '';
  }

  // 1. Быстрое локальное извлечение текста через Google ML Kit (Офлайн)
  Future<String> extractTextOffline(String imagePath) async {
    try {
      final inputImage = InputImage.fromFilePath(imagePath);
      final RecognizedText recognizedText = await _mlKitRecognizer.processImage(inputImage);
      return recognizedText.text;
    } catch (e) {
      print('ML Kit offline OCR error: $e');
      return '';
    }
  }

  // 2. Интеллектуальный разбор накладных и чеков через Vision AI (Gemini 1.5 Flash)
  Future<InvoiceDocument?> parseInvoiceWithVisionAi(List<String> imagePaths) async {
    final apiKey = await _getGeminiApiKey();

    if (apiKey.isEmpty) {
      // Если ключ не задан, используем эвристический локальный парсер
      return _fallbackLocalParse(imagePaths);
    }

    try {
      final List<Map<String, dynamic>> parts = [];

      // Системный промпт с учетом специфики торговли в РТ (русский + таджикский языки)
      final systemInstruction = '''
Ты профессиональный финансовый парсер накладных (ТОРГ-12, счетов-фактур, кассовых и товарных чеков) розничной торговли в Таджикистане.
Твоя задача — внимательно изучить изображение накладной/чека и извлечь структурированную таблицу товаров.
Поддерживай названия товаров и поставщиков на русском и таджикском языках (ҳ, ҷ, ӣ, ӯ, ғ, қ).
Если накладная на нескольких фото — объедини все позиции в один общий список без дублей.

Обязательно верни СТРОГО валидный JSON следующей структуры, без лишних слов:
{
  "supplier_name": "Название поставщика или 'Неизвестный поставщик'",
  "invoice_number": "Номер накладной или 'б/н'",
  "invoice_date": "YYYY-MM-DD",
  "total_amount": 1250.50,
  "items": [
    {
      "name": "Точное наименование товара из накладной",
      "quantity": 10.0,
      "unit": "шт",
      "buy_price": 45.0,
      "total_price": 450.0,
      "barcode": "4820000000000" // если указан в строке, иначе null
    }
  ]
}
''';

      parts.add({'text': systemInstruction});

      // Добавляем все страницы документа в формате Base64
      for (var path in imagePaths) {
        final bytes = await File(path).readAsBytes();
        final base64Image = base64Encode(bytes);
        parts.add({
          'inline_data': {
            'mime_type': 'image/jpeg',
            'data': base64Image,
          }
        });
      }

      final url = Uri.parse(
        'https://generativelanguage.googleapis.com/v1beta/models/gemini-1.5-flash:generateContent?key=$apiKey',
      );

      final response = await http.post(
        url,
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({
          'contents': [
            {'parts': parts}
          ],
          'generationConfig': {
            'response_mime_type': 'application/json',
            'temperature': 0.1,
          }
        }),
      );

      if (response.statusCode == 200) {
        final resJson = jsonDecode(response.body);
        final rawText = resJson['candidates']?[0]?['content']?['parts']?[0]?['text'] ?? '';
        final cleanJson = _cleanJsonString(rawText);
        final data = jsonDecode(cleanJson);

        return _buildDocumentFromJson(data, imagePaths);
      } else {
        print('Gemini API Error: ${response.statusCode} - ${response.body}');
        return _fallbackLocalParse(imagePaths);
      }
    } catch (e) {
      print('Vision AI error: $e');
      return _fallbackLocalParse(imagePaths);
    }
  }

  InvoiceDocument _buildDocumentFromJson(Map<String, dynamic> data, List<String> imagePaths) {
    final List<InvoiceItem> items = [];
    final rawItems = data['items'] as List<dynamic>? ?? [];

    for (var i = 0; i < rawItems.length; i++) {
      final it = rawItems[i];
      final qty = (it['quantity'] as num?)?.toDouble() ?? 1.0;
      final price = (it['buy_price'] as num?)?.toDouble() ?? 0.0;
      final total = (it['total_price'] as num?)?.toDouble() ?? (qty * price);

      items.add(InvoiceItem(
        id: 'item_${DateTime.now().millisecondsSinceEpoch}_$i',
        rawName: it['name']?.toString() ?? 'Позиция #${i + 1}',
        quantity: qty,
        unit: it['unit']?.toString() ?? 'шт',
        buyPrice: price,
        totalPrice: total,
        barcode: it['barcode']?.toString(),
      ));
    }

    final double totalAmount = (data['total_amount'] as num?)?.toDouble() ?? 
        items.fold<double>(0.0, (double sum, i) => sum + i.totalPrice);

    return InvoiceDocument(
      id: 'doc_${DateTime.now().millisecondsSinceEpoch}',
      storeId: 1,
      supplierName: data['supplier_name']?.toString() ?? 'Поставщик',
      invoiceNumber: data['invoice_number']?.toString() ?? 'б/н',
      invoiceDate: data['invoice_date'] != null 
          ? DateTime.tryParse(data['invoice_date']) ?? DateTime.now() 
          : DateTime.now(),
      totalAmount: totalAmount,
      items: items,
      pagePhotos: imagePaths,
    );
  }

  // Офлайн-парсинг с группировкой строк по Y-координатам (реконструкция таблицы) и умной фильтрацией мусора
  Future<InvoiceDocument> _fallbackLocalParse(List<String> imagePaths) async {
    final List<InvoiceItem> items = [];
    double detectedTotal = 0.0;
    String detectedSupplier = 'Поставщик';
    String detectedInvoiceNum = 'б/н';
    DateTime detectedDate = DateTime.now();

    final stopWords = [
      'инн', 'кпп', 'р/с', 'расчетный', 'бик', 'банк', 'огрн', 'мфо', 'корр', 
      'адрес', 'тел.', 'телефон', 'факс', 'email', 'www.', 'сайт',
      'поставщик', 'покупатель', 'грузополучатель', 'грузоотправитель', 
      'накладная', 'счет-фактура', 'счёт-фактура', 'упд', 'товарный чек',
      'итого', 'всего к оплате', 'всего наименований', 'сумма к оплате', 
      'в том числе ндс', 'без ндс', 'ставка ндс',
      'отпустил', 'получил', 'принял', 'сдал', 'бухгалтер', 'водитель', 
      'доверенность', 'подпись', 'печать', 'м.п.', 'страница', 'стр.',
      'наименование товара', 'ед.изм', 'ед. изм', 'кол-во', 'количество', 'цена с ндс'
    ];

    for (var path in imagePaths) {
      try {
        final inputImage = InputImage.fromFilePath(path);
        final recognizedText = await _mlKitRecognizer.processImage(inputImage);

        // 1. Собираем все строки с их координатами boundingBox
        final List<_OcrLineBox> rawLines = [];
        for (var block in recognizedText.blocks) {
          for (var line in block.lines) {
            final t = line.text.trim();
            if (t.isNotEmpty) {
              final box = line.boundingBox;
              rawLines.add(_OcrLineBox(
                text: t,
                top: box.top.toDouble(),
                bottom: box.bottom.toDouble(),
                left: box.left.toDouble(),
                right: box.right.toDouble(),
              ));
            }
          }
        }

        // 2. Сортируем строки по вертикали (сверху вниз)
        rawLines.sort((a, b) => a.top.compareTo(b.top));

        // 3. Группируем элементы, находящиеся на одной горизонтальной линии (строке таблицы)
        final List<List<_OcrLineBox>> rows = [];
        for (var line in rawLines) {
          bool addedToExisting = false;
          for (var row in rows) {
            final rowCenterY = row.map((l) => l.centerY).reduce((a, b) => a + b) / row.length;
            final tolerance = (line.height * 0.75).clamp(12.0, 30.0);
            if ((line.centerY - rowCenterY).abs() <= tolerance) {
              row.add(line);
              addedToExisting = true;
              break;
            }
          }
          if (!addedToExisting) {
            rows.add([line]);
          }
        }

        // 4. В каждой строке сортируем слева направо и объединяем текст
        final List<String> unifiedRows = [];
        for (var row in rows) {
          row.sort((a, b) => a.left.compareTo(b.left));
          final rowText = row.map((l) => l.text).join(' ').trim();
          if (rowText.length >= 3) {
            unifiedRows.add(rowText);
          }
        }

        // 5. Разбираем реконструированные строки таблицы
        for (var row in unifiedRows) {
          final lower = row.toLowerCase();

          // Извлечение поставщика из шапки
          if (lower.contains('поставщик') || lower.contains('чдмм') || lower.contains('ооо') || lower.contains('фурӯшанда')) {
            final cleaned = row.replaceAll(RegExp(r'^(поставщик|чдмм|ооо|фурӯшанда)[:\s]+', caseSensitive: false), '').trim();
            if (cleaned.length > 2 && detectedSupplier == 'Поставщик') {
              detectedSupplier = cleaned;
            }
            continue;
          }

          // Извлечение номера накладной
          if (lower.contains('накладная') || lower.contains('чек') || row.contains('№')) {
            final numMatch = RegExp(r'№\s*([0-9a-zA-Z\-_/]+)').firstMatch(row);
            if (numMatch != null && detectedInvoiceNum == 'б/н') {
              detectedInvoiceNum = numMatch.group(1)!;
            }
            if (lower.contains('накладная') || lower.contains('счет-фактура')) continue;
          }

          // Извлечение итоговой суммы накладной
          if (lower.contains('итого') || lower.contains('всего к оплате') || lower.contains('всего:')) {
            final totalMatch = RegExp(r'([0-9]+(?:[\.,][0-9]{1,2})?)\s*(?:tjs|сомони|руб)?$', caseSensitive: false).firstMatch(row);
            if (totalMatch != null) {
              detectedTotal = double.tryParse(totalMatch.group(1)!.replaceAll(',', '.')) ?? detectedTotal;
            }
            continue;
          }

          // Пропускаем служебный шум и шапки таблиц
          bool isNoise = false;
          for (var stop in stopWords) {
            if (lower.contains(stop)) {
              isNoise = true;
              break;
            }
          }
          if (isNoise) continue;

          // Ищем числа в конце строки (Количество, Цена, Сумма)
          // Поддерживаем форматы: "Кола 0.5 10 шт 5.00 50.00" или "Печенье 20 4.50 90.00"
          final numberMatches = RegExp(r'\b([0-9]+(?:[\.,][0-9]+)?)\b').allMatches(row).toList();

          if (numberMatches.length >= 2) {
            // Берем последние 2 или 3 числа
            final lastNumbers = numberMatches.sublist(numberMatches.length >= 3 ? numberMatches.length - 3 : numberMatches.length - 2);
            final firstNumIndex = lastNumbers.first.start;
            var rawName = row.substring(0, firstNumIndex).trim();

            // Удаляем порядковый номер в начале (например "1.", "2 ", "1)")
            rawName = rawName.replaceAll(RegExp(r'^[0-9]+[\.\)\s\-]+\s*'), '').trim();

            // Удаляем мусорные знаки
            rawName = rawName.replaceAll(RegExp(r'^[\|\:\;\,\.\-\_]+'), '').trim();

            if (rawName.length >= 2) {
              double qty = 1.0;
              double price = 0.0;
              double total = 0.0;

              if (lastNumbers.length == 3) {
                qty = double.tryParse(lastNumbers[0].group(1)!.replaceAll(',', '.')) ?? 1.0;
                price = double.tryParse(lastNumbers[1].group(1)!.replaceAll(',', '.')) ?? 0.0;
                total = double.tryParse(lastNumbers[2].group(1)!.replaceAll(',', '.')) ?? (qty * price);
              } else if (lastNumbers.length == 2) {
                final n1 = double.tryParse(lastNumbers[0].group(1)!.replaceAll(',', '.')) ?? 1.0;
                final n2 = double.tryParse(lastNumbers[1].group(1)!.replaceAll(',', '.')) ?? 0.0;

                // Если первое число похоже на количество (не слишком дробное и <= 1000)
                if (n1 > 0 && n1 <= 1000 && (n1 == n1.roundToDouble() || n1 * 10 == (n1 * 10).roundToDouble())) {
                  qty = n1;
                  price = n2;
                  total = qty * price;
                } else {
                  price = n1;
                  total = n2;
                  qty = price > 0 ? (total / price) : 1.0;
                }
              }

              // Защита от мусора: отсекаем телефонные номера и ИНН (больше 100000)
              if (price > 0 && price < 100000 && total < 1000000) {
                items.add(InvoiceItem(
                  id: 'local_${DateTime.now().millisecondsSinceEpoch}_${items.length}',
                  rawName: rawName,
                  quantity: qty > 0 ? qty : 1.0,
                  buyPrice: price,
                  totalPrice: total > 0 ? total : (qty * price),
                ));
              }
            }
          }
        }
      } catch (e) {
        print('Smart offline parse error: $e');
      }
    }

    final double computedTotal = items.fold<double>(0.0, (s, i) => s + i.totalPrice);

    return InvoiceDocument(
      id: 'doc_local_${DateTime.now().millisecondsSinceEpoch}',
      storeId: 1,
      supplierName: detectedSupplier,
      invoiceNumber: detectedInvoiceNum,
      invoiceDate: detectedDate,
      totalAmount: detectedTotal > 0 ? detectedTotal : computedTotal,
      items: items,
      pagePhotos: imagePaths,
    );
  }

  String _cleanJsonString(String text) {
    var cleaned = text.trim();
    if (cleaned.startsWith('```json')) {
      cleaned = cleaned.substring(7);
    }
    if (cleaned.startsWith('```')) {
      cleaned = cleaned.substring(3);
    }
    if (cleaned.endsWith('```')) {
      cleaned = cleaned.substring(0, cleaned.length - 3);
    }
    return cleaned.trim();
  }

  void dispose() {
    _mlKitRecognizer.close();
  }
}

class _OcrLineBox {
  final String text;
  final double top;
  final double bottom;
  final double left;
  final double right;

  _OcrLineBox({
    required this.text,
    required this.top,
    required this.bottom,
    required this.left,
    required this.right,
  });

  double get centerY => (top + bottom) / 2.0;
  double get height => (bottom - top).abs();
}

