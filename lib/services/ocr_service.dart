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

      // Системный промпт с максимальной строгостью: ТОЛЬКО строки таблицы товаров, БЕЗ шапки, реквизитов и подвала
      final systemInstruction = '''
Ты профессиональный финансовый аудитор и парсер товарных накладных (ТОРГ-12, счетов-фактур, товарных и кассовых чеков) розничной торговли в Таджикистане.
Твоя задача — извлечь СТРОГО данные строк ТАБЛИЦЫ ТОВАРОВ и ничего лишнего. Поддерживай русский и таджикский языки (ҳ, ҷ, ӣ, ӯ, ғ, қ).

КРИТИЧЕСКИ ВАЖНЫЕ ПРАВИЛА ИЗОЛЯЦИИ ТАБЛИЦЫ:
1. ТОВАРЫ ВСЕГДА НАХОДЯТСЯ СТРОГО В ТАБЛИЦЕ ТОВАРОВ:
   - Таблица начинается после строки заголовков: "№", "Наименование", "Кол-во", "Цена", "Сумма" (или таджикские аналоги: "Номи мол", "Миқдор", "Нарх", "Маблағ").
   - Таблица заканчивается строкой "Итого" / "Всего к оплате" / "Ҳамагӣ" / "Ҷамъ".

2. КАТЕГОРИЧЕСКИ ЗАПРЕЩЕНО извлекать в "items" данные ВНЕ таблицы товаров:
   - ЗАПРЕЩЕНО извлекать реквизиты, названия магазинов, ИНН, расчетные счета, телефоны, адреса, ФИО экспедитора, водителя, коды документов (например: 'IPJWO87-001', 'VapnHa', 'TJS' и т.д.).
   - ЗАПРЕЩЕНО превращать номера счетов, телефоны или артикулы в цены! (Никаких цен вроде 3104400.04 TJS!).
   - ЗАПРЕЩЕНО извлекать текст подвала, подписи, штампы: "Отпустил", "Принял", "Сдал", "Бухгалтер", "Печать".

3. ДЛЯ КАЖДОЙ ПОЗИЦИИ В "items":
   - "name": Чистое название реального товара из строки таблицы.
   - "quantity": Количество (число, например 5.0).
   - "unit": Единица измерения (шт, кг, уп, л, кор и т.д., по умолчанию "шт").
   - "buy_price": Реальная закупочная цена за 1 шт в сомони (TJS).
   - "total_price": Сумма по строке (quantity * buy_price).
   - "barcode": Штрихкод (если напечатан в таблице, иначе null).

4. ИТОГ НАКЛАДНОЙ ("total_amount"):
   - СТРОГО равен сумме строк товаров (значение из строки 'Итого' / 'Ҳамагӣ' в конце таблицы).

Обязательно верни СТРОГО валидный JSON следующей структуры, без разметки и без лишних слов:
{
  "supplier_name": "Название поставщика или 'Поставщик'",
  "invoice_number": "Номер накладной или 'б/н'",
  "invoice_date": "YYYY-MM-DD",
  "total_amount": 1250.50,
  "items": [
    {
      "name": "Наименование товара",
      "quantity": 10.0,
      "unit": "шт",
      "buy_price": 45.0,
      "total_price": 450.0,
      "barcode": null
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

  // Офлайн-парсинг со СТРОГОЙ изоляцией границ таблицы товаров (только между шапкой и итого)
  Future<InvoiceDocument> _fallbackLocalParse(List<String> imagePaths) async {
    final List<InvoiceItem> items = [];
    double detectedTotal = 0.0;
    String detectedSupplier = 'Поставщик';
    String detectedInvoiceNum = 'б/н';
    DateTime detectedDate = DateTime.now();

    final headerStopWords = [
      'инн', 'кпп', 'р/с', 'расчетный', 'бик', 'банк', 'огрн', 'мфо', 'корр', 
      'адрес', 'тел.', 'телефон', 'факс', 'email', 'www.', 'сайт',
      'поставщик', 'покупатель', 'грузополучатель', 'грузоотправитель', 
      'водитель', 'экспедитор', 'доверенность', 'страница', 'стр.'
    ];

    final footerKeywords = [
      'итого', 'всего к оплате', 'всего:', 'всего наименований', 'сумма к оплате',
      'ҳамагӣ', 'ҷамъ', 'отпустил', 'получил', 'принял', 'сдал', 'супорид', 'қабул',
      'бухгалтер', 'подпись', 'печать', 'м.п.'
    ];

    final tableHeaderKeywords = [
      'наименование', 'товар', 'номи мол', 'номгӯи', 'кол-во', 'количество',
      'миқдор', 'цена', 'нарх', 'сумма', 'маблағ', 'ед.изм', 'ед. изм', '№ п/п'
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
          if (rowText.length >= 2) {
            unifiedRows.add(rowText);
          }
        }

        // 5. ОПРЕДЕЛЯЕМ ГРАНИЦЫ ТАБЛИЦЫ ТОВАРОВ:
        // ТОВАРЫ НАХОДЯТСЯ СТРОГО МЕЖДУ tableStartIndex и tableEndIndex!
        int tableStartIndex = 0;
        int tableEndIndex = unifiedRows.length;

        // Поиск начала таблицы (строка заголовков: Наименование, Кол-во, Цена, Сумма...)
        for (int i = 0; i < unifiedRows.length; i++) {
          final lower = unifiedRows[i].toLowerCase();
          int headerHits = 0;
          for (var keyword in tableHeaderKeywords) {
            if (lower.contains(keyword)) headerHits++;
          }
          if (headerHits >= 2 || (headerHits >= 1 && (lower.contains('цена') || lower.contains('нарх') || lower.contains('кол-во') || lower.contains('миқдор')))) {
            tableStartIndex = i + 1; // Товары начинаются со следующей строки
            break;
          }
        }

        // Поиск конца таблицы (строка Итого / Всего / Ҳамагӣ / Отпустил...)
        for (int i = tableStartIndex; i < unifiedRows.length; i++) {
          final lower = unifiedRows[i].toLowerCase();
          bool isFooter = false;
          for (var footerKey in footerKeywords) {
            if (lower.contains(footerKey)) {
              isFooter = true;
              break;
            }
          }

          if (isFooter) {
            // Извлекаем итоговую сумму из строки итого
            final totalMatch = RegExp(r'([0-9]+(?:[\.,][0-9]{1,2})?)\s*(?:tjs|сомони|руб)?$', caseSensitive: false).firstMatch(unifiedRows[i]);
            if (totalMatch != null) {
              final val = double.tryParse(totalMatch.group(1)!.replaceAll(',', '.')) ?? 0.0;
              if (val > 0 && val < 500000) {
                detectedTotal = val;
              }
            }
            tableEndIndex = i; // Граница конца таблицы! Всё, что ниже — реквизиты, подписи, штампы
            break;
          }
        }

        // 6. Извлечение метаданных документа (поставщик, номер, дата) из всего текста
        for (var row in unifiedRows) {
          final lower = row.toLowerCase();
          if (lower.contains('поставщик') || lower.contains('чдмм') || lower.contains('ооо') || lower.contains('фурӯшанда')) {
            final cleaned = row.replaceAll(RegExp(r'^(поставщик|чдмм|ооо|фурӯшанда)[:\s]+', caseSensitive: false), '').trim();
            if (cleaned.length > 2 && detectedSupplier == 'Поставщик') {
              detectedSupplier = cleaned;
            }
          }
          if (lower.contains('накладная') || lower.contains('чек') || row.contains('№')) {
            final numMatch = RegExp(r'№\s*([0-9a-zA-Z\-_/]+)').firstMatch(row);
            if (numMatch != null && detectedInvoiceNum == 'б/н') {
              detectedInvoiceNum = numMatch.group(1)!;
            }
          }
        }

        // 7. СТРОГИЙ РАЗБОР СТРОК ТОВАРОВ — ТОЛЬКО ВНУТРИ ТАБЛИЦЫ [tableStartIndex .. tableEndIndex]
        for (int i = tableStartIndex; i < tableEndIndex; i++) {
          final row = unifiedRows[i];
          final lower = row.toLowerCase();

          // Исключаем шум и случайные служебные строки
          bool isNoise = false;
          for (var stop in headerStopWords) {
            if (lower.contains(stop)) {
              isNoise = true;
              break;
            }
          }
          if (isNoise) continue;

          // Строка товара обязательно должна содержать текст (название), а не быть просто цифрами
          if (!RegExp(r'[a-zA-Zа-яА-ЯёЁғқӣӯҳҷҒҚӢӮҲҶ]{2,}').hasMatch(row)) {
            continue;
          }

          // Ищем числа в строке (Количество, Цена, Сумма)
          final numberMatches = RegExp(r'\b([0-9]+(?:[\.,][0-9]+)?)\b').allMatches(row).toList();
          if (numberMatches.length >= 2) {
            // Выделяем название товара (текст до чисел)
            final lastNumbers = numberMatches.sublist(numberMatches.length >= 3 ? numberMatches.length - 3 : numberMatches.length - 2);
            final firstNumIndex = lastNumbers.first.start;
            var rawName = row.substring(0, firstNumIndex).trim();

            // Очищаем от номера строки "1.", "2 ", "1)"
            rawName = rawName.replaceAll(RegExp(r'^[0-9]+[\.\)\s\-]+\s*'), '').trim();
            rawName = rawName.replaceAll(RegExp(r'^[\|\:\;\,\.\-\_]+'), '').trim();

            // Исключаем мусорные однобуквенные или системные названия
            if (rawName.length < 2 || lower.startsWith('тел') || lower.startsWith('инн') || lower.startsWith('р/с')) {
              continue;
            }

            double qty = 1.0;
            double price = 0.0;
            double total = 0.0;

            if (lastNumbers.length == 3) {
              final n1 = double.tryParse(lastNumbers[0].group(1)!.replaceAll(',', '.')) ?? 1.0;
              final n2 = double.tryParse(lastNumbers[1].group(1)!.replaceAll(',', '.')) ?? 0.0;
              final n3 = double.tryParse(lastNumbers[2].group(1)!.replaceAll(',', '.')) ?? 0.0;

              // Математическая проверка (qty * price ≈ total)
              if ((n1 * n2 - n3).abs() <= (n3 * 0.15 + 1.0)) {
                qty = n1;
                price = n2;
                total = n3;
              } else if ((n1 * n3 - n2).abs() <= (n2 * 0.15 + 1.0)) {
                qty = n1;
                price = n3;
                total = n2;
              } else {
                qty = n1;
                price = n2;
                total = (n3 > 0) ? n3 : (n1 * n2);
              }
            } else if (lastNumbers.length == 2) {
              final n1 = double.tryParse(lastNumbers[0].group(1)!.replaceAll(',', '.')) ?? 1.0;
              final n2 = double.tryParse(lastNumbers[1].group(1)!.replaceAll(',', '.')) ?? 0.0;

              if (n1 > 0 && n1 <= 1000) {
                qty = n1;
                price = n2;
                total = qty * price;
              } else {
                price = n1;
                total = n2;
                qty = (price > 0) ? (total / price) : 1.0;
              }
            }

            // ЖЕСТКИЙ ФИЛЬТР ЗДРАВОГО СМЫСЛА:
            // Отсекаем телефонные номера, банковские счета и мусор (вроде 3104400.04 TJS)
            if (price > 0.05 && price < 50000.0 && total > 0.05 && total < 500000.0 && qty > 0.001 && qty < 10000.0) {
              items.add(InvoiceItem(
                id: 'local_${DateTime.now().millisecondsSinceEpoch}_${items.length}',
                rawName: rawName,
                quantity: qty,
                buyPrice: price,
                totalPrice: total > 0 ? total : (qty * price),
              ));
            }
          }
        }
      } catch (e) {
        print('Smart offline parse error: $e');
      }
    }

    final double computedTotal = items.fold<double>(0.0, (s, i) => s + i.totalPrice);
    final double finalTotal = (detectedTotal > 0 && computedTotal > 0 && (detectedTotal - computedTotal).abs() / computedTotal < 0.25)
        ? detectedTotal
        : computedTotal;

    return InvoiceDocument(
      id: 'doc_local_${DateTime.now().millisecondsSinceEpoch}',
      storeId: 1,
      supplierName: detectedSupplier,
      invoiceNumber: detectedInvoiceNum,
      invoiceDate: detectedDate,
      totalAmount: finalTotal,
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

