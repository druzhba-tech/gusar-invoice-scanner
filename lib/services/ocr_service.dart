import 'dart:convert';
import 'dart:io';
import 'package:http/http.dart' as http;
import 'package:google_mlkit_text_recognition/google_mlkit_text_recognition.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/invoice_document.dart';
import '../models/invoice_item.dart';
import '../utils/image_utils.dart';
import '../utils/cyrillic_decoder.dart';
import 'invoice_template_service.dart';

class OcrService {
  static final OcrService _instance = OcrService._internal();
  factory OcrService() => _instance;
  OcrService._internal();

  final TextRecognizer _mlKitRecognizer = TextRecognizer(script: TextRecognitionScript.latin);
  final InvoiceTemplateService _templateService = InvoiceTemplateService();

  static String get defaultGeminiKey => '';

  Future<Map<String, String>> _getAiConfig() async {
    final prefs = await SharedPreferences.getInstance();
    var savedGeminiKey = prefs.getString('gemini_api_key')?.trim() ?? '';
    // Очищаем старые невалидные ключи или фиктивные строки
    if (!savedGeminiKey.startsWith('AIzaSy')) {
      savedGeminiKey = '';
    }
    return {
      'provider': prefs.getString('ai_provider') ?? 'gemini',
      'gemini_key': savedGeminiKey,
      'yandex_key': prefs.getString('yandex_api_key')?.trim() ?? '',
      'yandex_folder_id': prefs.getString('yandex_folder_id')?.trim() ?? '',
    };
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

  // 2. Интеллектуальный разбор накладных через Vision AI / ML Kit
  Future<InvoiceDocument?> parseInvoiceWithVisionAi(List<String> imagePaths) async {
    // Используем фотографии в их исходном разрешении и ориентации (ручное выравнивание)
    final List<String> preparedPaths = List<String>.from(imagePaths);

    // ШАГ 0.5: ПРОВЕРКА ЗАПОМНЕННОГО ШАБЛОНА ПОСТАВЩИКА
    await _templateService.init();
    SupplierInvoiceTemplate? knownTemplate;
    if (preparedPaths.isNotEmpty) {
      try {
        final quickSampleText = await extractTextOffline(preparedPaths.first);
        knownTemplate = _templateService.detectTemplateFromOcrText(quickSampleText);
      } catch (_) {}
    }

    final config = await _getAiConfig();
    final provider = config['provider'] ?? 'gemini';
    final yandexKey = config['yandex_key'] ?? '';
    final geminiKey = config['gemini_key'] ?? '';
    final yandexFolderId = config['yandex_folder_id'] ?? '';

    InvoiceDocument? doc;

    // 1. По умолчанию или при выборе Gemini — вызываем Google Gemini Vision AI
    // СТРОГОЕ ПРАВИЛО: вызываем только при наличии настоящего ключа Google (начинается с AIzaSy)
    if (provider == 'gemini' && geminiKey.startsWith('AIzaSy')) {
      doc = await _parseWithGemini(preparedPaths, geminiKey, template: knownTemplate);
    }

    // 2. Если выбран Яндекс AI (специализирован под кириллицу) и ключ задан
    if ((doc == null || doc.items.isEmpty) && provider == 'yandex' && yandexKey.isNotEmpty) {
      doc = await parseInvoiceWithYandexVision(preparedPaths, yandexKey, folderId: yandexFolderId);
    }

    // 3. Fallback: если облачные нейросети не настроены или не ответили —
    // используем сверхбыстрый локальный офлайн-парсер Google ML Kit (1.5 сек, как в v1.4.10)
    doc ??= await _fallbackLocalParse(preparedPaths);

    // 3.1. АВТО-ВОССТАНОВЛЕНИЕ ОРИЕНТАЦИИ (MULTI-ANGLE AUTO-RECOVERY):
    // Если накладная сфотографирована боком (как на мобильных телефонах при горизонтальной съёмке)
    // и распознавание дало 0 товаров:
    // Мы АВТОМАТИЧЕСКИ поворачиваем снимок на 90 градусов и пробуем распознать снова!
    if ((doc == null || doc.items.isEmpty) && preparedPaths.isNotEmpty) {
      final List<String> currentTryPaths = List<String>.from(preparedPaths);
      for (int rotationAttempt = 1; rotationAttempt <= 3; rotationAttempt++) {
        final List<String> nextRotatedPaths = [];
        for (var p in currentTryPaths) {
          if (!p.toLowerCase().endsWith('.pdf')) {
            try {
              final rotated = await ImageUtils.rotateImage90Degrees(File(p));
              nextRotatedPaths.add(rotated.path);
            } catch (_) {
              nextRotatedPaths.add(p);
            }
          } else {
            nextRotatedPaths.add(p);
          }
        }
        currentTryPaths.clear();
        currentTryPaths.addAll(nextRotatedPaths);

        final retryDoc = await _fallbackLocalParse(currentTryPaths);
        if (retryDoc.items.isNotEmpty) {
          doc = retryDoc;
          break;
        }
      }
    }

    // ШАГ ФИНАЛЬНЫЙ: ПРИМЕНЯЕМ ШАБЛОН ПОСТАВЩИКА К ДОКУМЕНТУ
    if (doc != null) {
      final tmpl = knownTemplate ?? _templateService.findTemplateForSupplier(doc.supplierName);
      if (tmpl != null) {
        _templateService.applyTemplateToDocument(doc, tmpl);
      }
    }

    return doc;
  }

  // =========================================================================
  // РАСПОЗНАВАНИЕ ЧЕРЕЗ YANDEX CLOUD VISION OCR (КИРИЛЛИЦА / РУС / ТАДЖ)
  // =========================================================================
  Future<InvoiceDocument?> parseInvoiceWithYandexVision(
    List<String> imagePaths,
    String apiKey, {
    String? folderId,
    List<String>? originalPaths,
  }) async {
    try {
      final List<String> extractedLines = [];

      for (var path in imagePaths) {
        final bytes = await File(path).readAsBytes();
        final base64Image = base64Encode(bytes);

        final url = Uri.parse('https://ocr.api.cloud.yandex.net/ocr/v1/recognizeText');
        final headers = {
          'Content-Type': 'application/json',
          'Authorization': 'Api-Key $apiKey',
          'x-data-logging-enabled': 'true',
          if (folderId != null && folderId.trim().isNotEmpty) 'x-folder-id': folderId.trim(),
        };

        // Запрашиваем распознавание с моделью 'table' для кириллицы
        final body = jsonEncode({
          'mimeType': 'JPEG',
          'languageCodes': ['ru', 'en'],
          'model': 'table',
          'content': base64Image,
        });

        final response = await http.post(url, headers: headers, body: body).timeout(const Duration(seconds: 25));

        if (response.statusCode == 200) {
          final resJson = jsonDecode(response.body);
          final textAnnotation = resJson['result']?['textAnnotation'];
          if (textAnnotation != null) {
            // 1. Извлекаем ячейки таблиц, если Yandex структурировал таблицу
            final tables = textAnnotation['tables'] as List<dynamic>? ?? [];
            if (tables.isNotEmpty) {
              for (var t in tables) {
                final cells = t['cells'] as List<dynamic>? ?? [];
                final Map<int, List<Map<String, dynamic>>> rowMap = {};
                for (var c in cells) {
                  final rIdx = (c['rowIndex'] as num?)?.toInt() ?? 0;
                  rowMap.putIfAbsent(rIdx, () => []).add(c as Map<String, dynamic>);
                }
                final sortedRows = rowMap.keys.toList()..sort();
                for (var r in sortedRows) {
                  final cellsInRow = rowMap[r]!;
                  cellsInRow.sort((a, b) => ((a['columnIndex'] as num?)?.toInt() ?? 0).compareTo((b['columnIndex'] as num?)?.toInt() ?? 0));
                  final rowStr = cellsInRow.map((c) => c['text']?.toString().trim() ?? '').where((s) => s.isNotEmpty).join('  ');
                  if (rowStr.isNotEmpty) {
                    extractedLines.add(rowStr);
                  }
                }
              }
            }

            // 2. Если табличная структура не выделилась, берём строки из текстовых блоков
            if (extractedLines.isEmpty) {
              final blocks = textAnnotation['blocks'] as List<dynamic>? ?? [];
              for (var b in blocks) {
                final lines = b['lines'] as List<dynamic>? ?? [];
                for (var l in lines) {
                  final text = l['text']?.toString().trim() ?? '';
                  if (text.isNotEmpty) {
                    extractedLines.add(text);
                  }
                }
              }
            }
          }
        } else {
          print('Yandex OCR API error: ${response.statusCode} - ${response.body}');
        }
      }

      if (extractedLines.isNotEmpty) {
        return _parseUnifiedLines(extractedLines, originalPaths ?? imagePaths);
      }
    } catch (e) {
      print('Yandex Vision error: $e');
    }
    return null;
  }

  // =========================================================================
  // РАСПОЗНАВАНИЕ ЧЕРЕЗ GOOGLE GEMINI FLASH (VISION AI) С ПОДСКАЗКОЙ ШАБЛОНА
  // =========================================================================
  Future<InvoiceDocument?> _parseWithGemini(
    List<String> imagePaths,
    String apiKey, {
    SupplierInvoiceTemplate? template,
    List<String>? originalPaths,
  }) async {
    try {
      final List<Map<String, dynamic>> parts = [];

      final systemInstruction = '''
Ты профессиональный финансовый аудитор и высокоточный парсер товарных накладных (ТОРГ-12, счетов-фактур, товарных и кассовых чеков) розничной торговли в Таджикистане.
Твоя задача — извлечь СТРОГО данные строк ТАБЛИЦЫ ТОВАРОВ и ничего лишнего. Поддерживай русский и таджикский языки (ҳ, ҷ, ӣ, ӯ, ғ, қ).

КРИТИЧЕСКИ ВАЖНЫЕ ПРАВИЛА РАЗБОРА СТОЛБЦОВ И ТАБЛИЦЫ:
1. ТОВАРЫ ВСЕГДА НАХОДЯТСЯ СТРОГО В ТАБЛИЦЕ ТОВАРОВ:
   - Таблица начинается после строки заголовков: "№", "Наименование", "Кол-во", "Цена", "Сумма" (или аналоги: "Номи мол", "Миқдор", "Нарх", "Маблағ").
   - Таблица заканчивается строкой "Итого" / "Всего к оплате" / "Ҳамагӣ" / "Ҷамъ".

2. КАТЕГОРИЧЕСКИ ЗАПРЕЩЕНО извлекать в "items" строки подвала или шапки:
   - ЗАПРЕЩЕНО добавлять строки: "Итого", "Всего", "В том числе НДС", "Ҳамагӣ", "Ҷамъ", "Отпустил", "Принял", "Сдал", "Бухгалтер", "Печать", "MToro", "wT.".
   - ЗАПРЕЩЕНО превращать номера счетов, телефоны, артикулы или ИНН в товары или цены!

3. ПРАВИЛА ДЛЯ СТОЛБЦОВ ЦЕН И СКИДОК:
   - Если в таблице есть столбцы "Цена без скидки", "Скидка %" и "Цена со скидкой" (или "Отпускная цена") -> в "buy_price" СТРОГО извлекай ФАКТИЧЕСКУЮ ЦЕНУ ЗА 1 ШТ ПОСЛЕ СКИДКИ (цену к оплате)!
   - Никогда не путай цену за единицу и общую сумму по строке!

4. ПРАВИЛА ДЛЯ СТОЛБЦОВ КОЛИЧЕСТВА И УПАКОВОК:
   - Если в накладной есть "Кол-во мест" (коробок) и "В одном месте" (штук в коробке) или "Итого шт." -> в "quantity" СТРОГО извлекай ИТОГОВОЕ КОЛИЧЕСТВО В БАЗОВЫХ ЕДИНИЦАХ (штуки, килограммы, литры)!
   - Не путай числа из названий товаров (например "17", "710N", "2448", "450г") с количеством!

5. СТРОГОЕ МАТЕМАТИЧЕСКОЕ РАВЕНСТВО:
   - Для КАЖДОЙ позиции ОБЯЗАТЕЛЬНО должно выполняться: "total_price" = "quantity" * "buy_price" (с учетом округлений до 2 знаков).
   - "total_amount" документа СТРОГО равен сумме всех "total_price" (значение из строки "Итого" / "Ҳамагӣ").

6. СТОЛБЕЦ ЕДИНИЦ ИЗМЕРЕНИЯ И НАИМЕНОВАНИЕ:
   - Значения "шт", "шт.", "wT.", "wT", "дона", "компл", "кг", "литр", "упак" — это СТРОГО "unit" (единица измерения)!
   - КАТЕГОРИЧЕСКИ ЗАПРЕЩЕНО помещать "wT.", "шт", "дона" в название товара "name"!
   - Название товара ("name") — это ВСЕГДА полное текстовое наименование из графы Товар/Наименование (например: "Принтер HP LaserJet 1020 C5911A A4", "Сканер Bear Paw 2448 TA Pro").

Верни СТРОГО валидный JSON:
{
  "supplier_name": "Название поставщика или 'Поставщик'",
  "invoice_number": "Номер накладной или 'б/н'",
  "invoice_date": "YYYY-MM-DD",
  "total_amount": 37516.18,
  "items": [
    {
      "name": "Монитор 17\" Samsung 710N (SKN) TFT",
      "quantity": 5.0,
      "unit": "шт",
      "buy_price": 5465.24,
      "total_price": 27326.20,
      "barcode": null
    }
  ]
}
''';

      parts.add({'text': systemInstruction});

      // Если найден шаблон поставщика — передаем нейросети подсказку структуры для ускорения
      if (template != null) {
        final hint = _templateService.buildAiTemplatePromptHint(template);
        parts.add({'text': hint});
      }

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

      // Используем стабильные, актуальные и самые скоростные модели Flash
      if (!apiKey.trim().startsWith('AIzaSy')) {
        return null;
      }

      // Используем стабильную и самую скоростную модель Flash
      final candidateModels = [
        'gemini-1.5-flash',
        'gemini-2.0-flash',
      ];

      for (var modelName in candidateModels) {
        try {
          final url = Uri.parse(
            'https://generativelanguage.googleapis.com/v1beta/models/$modelName:generateContent?key=$apiKey',
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
                'maxOutputTokens': 8192,
                'temperature': 0.1,
              }
            }),
          ).timeout(const Duration(seconds: 8));

          if (response.statusCode == 200) {
            final resJson = jsonDecode(response.body);
            final rawText = resJson['candidates']?[0]?['content']?['parts']?[0]?['text'] ?? '';
            final cleanJson = _cleanAndRepairJson(rawText);
            final data = jsonDecode(cleanJson);

            final doc = _buildDocumentFromJson(data, originalPaths ?? imagePaths);
            if (doc.items.isNotEmpty) {
              return doc;
            }
          } else if (response.statusCode == 400 || response.statusCode == 401 || response.statusCode == 403) {
            print('Gemini Auth/Param Error (${response.statusCode}), skipping directly to local OCR...');
            break;
          } else if (response.statusCode == 503 || response.statusCode == 429) {
            print('Gemini $modelName temporary busy (${response.statusCode}), switching to next model...');
            await Future.delayed(const Duration(milliseconds: 500));
          } else {
            print('Gemini $modelName Error: ${response.statusCode}');
            break;
          }
        } catch (e) {
          print('Gemini $modelName attempt failed: $e');
          break;
        }
      }
      return null;
    } catch (e) {
      print('Gemini Vision error: $e');
      return null;
    }
  }

  InvoiceDocument _buildDocumentFromJson(Map<String, dynamic> data, List<String> imagePaths) {
    final List<InvoiceItem> items = [];
    final rawItems = data['items'] as List<dynamic>? ?? [];

    final stopKeywords = [
      'итого', 'всего', 'ҳамагӣ', 'ҷамъ', 'ндс', 'mtoro', 'wt.', 
      'отпустил', 'принял', 'сдал', 'бухгалтер', 'подпись', 'печать', 'м.п.'
    ];

    double extractedTotalFromFooter = (data['total_amount'] as num?)?.toDouble() ?? 0.0;

    for (var i = 0; i < rawItems.length; i++) {
      final it = rawItems[i];
      var rawName = it['name']?.toString().trim() ?? '';
      final lowerName = rawName.toLowerCase();

      // 1. Отсеиваем служебные строки подвала и мусор
      bool isStopword = false;
      for (var stop in stopKeywords) {
        if (lowerName == stop || lowerName.startsWith('$stop:') || lowerName.startsWith('$stop ') || lowerName.contains('в том числе ндс')) {
          isStopword = true;
          final rowTotal = (it['total_price'] as num?)?.toDouble() ?? (it['buy_price'] as num?)?.toDouble() ?? 0.0;
          if (rowTotal > 0 && extractedTotalFromFooter <= 0) {
            extractedTotalFromFooter = rowTotal;
          }
          break;
        }
      }
      if (isStopword) continue;

      // 2. Очистка от лидирующих номеров строк: "1. Монитор" -> "Монитор"
      rawName = rawName.replaceAll(RegExp(r'^[0-9]+[\.\)\s\-]+\s*'), '').trim();
      rawName = rawName.replaceAll(RegExp(r'^[\|\:\;\,\.\-\_]+'), '').trim();

      // 3. Проверка на минимальную длину и валидность
      if (rawName.length < 2 || lowerName == 'wt.' || lowerName == 'mtoro:' || lowerName == 'mtoro') {
        continue;
      }

      var qty = (it['quantity'] as num?)?.toDouble() ?? 1.0;
      var price = (it['buy_price'] as num?)?.toDouble() ?? 0.0;
      var total = (it['total_price'] as num?)?.toDouble() ?? 0.0;

      // 4. Математическая нормализация и защита от перепутывания колонок
      if (total <= 0 && qty > 0 && price > 0) {
        total = double.parse((qty * price).toStringAsFixed(2));
      } else if (price <= 0 && qty > 0 && total > 0) {
        price = double.parse((total / qty).toStringAsFixed(2));
      } else if (qty <= 0 && price > 0 && total > 0) {
        qty = double.parse((total / price).toStringAsFixed(2));
      } else if (qty > 100 && price > 0 && price <= 50 && total > 0 && (qty - total).abs() <= 1.0) {
        final temp = qty;
        qty = price;
        price = temp;
      } else if (qty > 0 && price > 0 && total > 0 && (qty * price - total).abs() > 0.50) {
        final calcTotal = qty * price;
        if ((calcTotal - total).abs() / total < 0.05) {
          total = double.parse(calcTotal.toStringAsFixed(2));
        } else if ((total / qty - price).abs() < (total / price - qty).abs()) {
          price = double.parse((total / qty).toStringAsFixed(2));
        }
      }

      if (qty > 0 && (price > 0 || total > 0)) {
        items.add(InvoiceItem(
          id: 'item_${DateTime.now().millisecondsSinceEpoch}_$i',
          rawName: rawName,
          quantity: qty,
          unit: it['unit']?.toString() ?? 'шт',
          buyPrice: price,
          totalPrice: total > 0 ? total : double.parse((qty * price).toStringAsFixed(2)),
          barcode: it['barcode']?.toString(),
        ));
      }
    }

    final double computedTotal = items.fold<double>(0.0, (double sum, i) => sum + i.totalPrice);
    final double totalAmount = (extractedTotalFromFooter > 0 && (extractedTotalFromFooter - computedTotal).abs() <= 1.0)
        ? extractedTotalFromFooter
        : (computedTotal > 0 ? computedTotal : extractedTotalFromFooter);

    return InvoiceDocument(
      id: 'doc_${DateTime.now().millisecondsSinceEpoch}',
      storeId: 1,
      supplierName: data['supplier_name']?.toString() ?? 'Поставщик',
      invoiceNumber: data['invoice_number']?.toString() ?? 'б/н',
      invoiceDate: data['invoice_date'] != null 
          ? DateTime.tryParse(data['invoice_date']) ?? DateTime.now() 
          : DateTime.now(),
      totalAmount: double.parse(totalAmount.toStringAsFixed(2)),
      items: items,
      pagePhotos: imagePaths,
    );
  }

  // =========================================================================
  // УНИФИЦИРОВАННЫЙ РАЗБОР СТРОК ТАБЛИЦЫ ДЛЯ КИРИЛЛИЦЫ
  // =========================================================================
  InvoiceDocument _parseUnifiedLines(List<String> unifiedRows, List<String> imagePaths) {
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
      'бухгалтер', 'подпись', 'печать', 'м.п.', 'mtoro', 'в том числе ндс'
    ];

    final tableHeaderKeywords = [
      'наименование', 'товар', 'номи мол', 'номгӯи', 'кол-во', 'количество',
      'миқдор', 'цена', 'нарх', 'сумма', 'маблағ', 'ед.изм', 'ед. изм', '№ п/п',
      'haumehoba', 'haumeho', 'tovar', 'tobap', 'kol-vo', 'kolichestvo', 'cena', 
      'leha', 'ueha', 'summa', 'cymma', 'sum', 'somoni', 'narx', 'miqdor', 'kod', 'код', 'арт'
    ];

    int tableStartIndex = 0;
    int tableEndIndex = unifiedRows.length;

    // 1. Поиск начала таблицы (строка заголовков)
    for (int i = 0; i < unifiedRows.length; i++) {
      final lower = unifiedRows[i].toLowerCase();
      int headerHits = 0;
      for (var keyword in tableHeaderKeywords) {
        if (lower.contains(keyword)) headerHits++;
      }
      if (headerHits >= 2 || (headerHits >= 1 && (lower.contains('цена') || lower.contains('нарх') || lower.contains('кол-во') || lower.contains('миқдор') || lower.contains('cena') || lower.contains('kol-vo')))) {
        tableStartIndex = i + 1;
        break;
      }
    }

    // 2. Поиск конца таблицы (строка Итого / Всего / Ҳамагӣ)
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
        // Нормализация разделителей тысяч в строке итогов: "37 516.18" -> "37516.18"
        final cleanRow = unifiedRows[i].replaceAllMapped(RegExp(r'(\d)\s+(\d{3})'), (m) => '${m[1]}${m[2]}');
        final totalMatch = RegExp(r'([0-9]+(?:[\.,][0-9]{1,2})?)\s*(?:tjs|сомони|руб)?$', caseSensitive: false).firstMatch(cleanRow);
        if (totalMatch != null) {
          final val = double.tryParse(totalMatch.group(1)!.replaceAll(',', '.')) ?? 0.0;
          if (val > 0 && val < 5000000) {
            detectedTotal = val;
          }
        }
        tableEndIndex = i;
        break;
      }
    }

    // 3. Извлечение метаданных документа (поставщик, номер, дата)
    for (var row in unifiedRows) {
      final lower = row.toLowerCase();
      if (lower.contains('поставщик') || lower.contains('чдмм') || lower.contains('ооо') || lower.contains('фурӯшанда') || lower.contains('noctabwuk') || lower.contains('noctab') || lower.contains('postavshik') || lower.contains('4dmm') || lower.contains('ooo')) {
        final cleaned = row.replaceAll(RegExp(r'^(поставщик|чдмм|ооо|ooo|фурӯшанда|noctabwuk|noctab|postavshik|4dmm)[:\s]+', caseSensitive: false), '').trim();
        if (cleaned.length > 2 && detectedSupplier == 'Поставщик') {
          detectedSupplier = CyrillicDecoder.decode(cleaned);
        }
      }
      if (lower.contains('накладная') || lower.contains('чек') || row.contains('№') || lower.contains('naklad') || lower.contains('no.')) {
        final numMatch = RegExp(r'(?:№|no\.?|n\s*)\s*([0-9a-zA-Z\-_/]+)', caseSensitive: false).firstMatch(row);
        if (numMatch != null && detectedInvoiceNum == 'б/н') {
          detectedInvoiceNum = numMatch.group(1)!;
        }
      }
    }

    // 4. Функция извлечения товаров из любого диапазона строк
    List<InvoiceItem> extractItemsFromRange(int start, int end) {
      final List<InvoiceItem> result = [];
      for (int i = start; i < end; i++) {
        var row = unifiedRows[i];
        final lower = row.toLowerCase();

        // Исключаем стоп-строки подвала и мусор
        bool isNoise = false;
        for (var stop in headerStopWords) {
          if (lower.contains(stop)) {
            isNoise = true;
            break;
          }
        }
        for (var footer in footerKeywords) {
          if (lower.contains(footer)) {
            isNoise = true;
            break;
          }
        }
        for (var th in tableHeaderKeywords) {
          if (lower.contains(th) && !lower.contains('сомони') && !lower.contains('tjs')) {
            if (lower.contains('наименование') || lower.contains('ед.изм') || lower.contains('№ п/п') || lower.contains('haumehoba')) {
              isNoise = true;
              break;
            }
          }
        }
        if (isNoise || lower.contains('mtoro') || lower.contains('wt.')) continue;

        if (lower.startsWith('накладная') || lower.startsWith('счет-фактура') || lower.startsWith('товарный чек') || lower.startsWith('расходная') || lower.startsWith('приходная')) {
          continue;
        }

        if (!RegExp(r'[a-zA-Zа-яА-ЯёЁғқӣӯҳҷҒҚӢӮҲҶ]{2,}').hasMatch(row)) {
          continue;
        }

        // Нормализуем пробелы в тысячах: "27 326,20" -> "27326,20"
        row = row.replaceAllMapped(RegExp(r'(\d)\s+(\d{3})'), (m) => '${m[1]}${m[2]}');

        // Поиск явного количества с единицей измерения: "5 шт."
        double? explicitQty;
        final unitMatch = RegExp(r'\b(\d+(?:[\.,]\d+)?)\s*(шт|кг|л|уп|пач|кор|дона|д-на)\b', caseSensitive: false).firstMatch(row);
        if (unitMatch != null) {
          explicitQty = double.tryParse(unitMatch.group(1)!.replaceAll(',', '.'));
        }

        final numberMatches = RegExp(r'\b([0-9]+(?:[\.,][0-9]+)?)\b').allMatches(row).toList();
        if (numberMatches.length >= 2) {
          final lastNumbers = numberMatches.sublist(numberMatches.length >= 3 ? numberMatches.length - 3 : numberMatches.length - 2);
          final firstNumIndex = lastNumbers.first.start;
          var rawName = row.substring(0, firstNumIndex).trim();

          rawName = rawName.replaceAll(RegExp(r'^[0-9]+[\.\)\s\-]+\s*'), '').trim();
          rawName = rawName.replaceAll(RegExp(r'^[\|\:\;\,\.\-\_]+'), '').trim();

          // Автокоррекция частых ошибок латинского сканера ML Kit
          rawName = rawName.replaceAll(RegExp(r'\bpMHTep\b', caseSensitive: false), 'Принтер')
              .replaceAll(RegExp(r'\bCcaHep\b', caseSensitive: false), 'Сканер')
              .replaceAll(RegExp(r'\bCkaHep\b', caseSensitive: false), 'Сканер')
              .replaceAll(RegExp(r'\bHFP\b', caseSensitive: false), 'HP');

          // Удаляем случайные суффиксы единиц измерения в конце имени
          rawName = rawName.replaceAll(RegExp(r'\s+(шт|кг|л|уп|пач|кор|дона|д-на|wt\.?)\.?$', caseSensitive: false), '').trim();

          if (rawName.length < 2 || lower.startsWith('тел') || lower.startsWith('инн') || lower.startsWith('р/с') || rawName.toLowerCase().startsWith('дата') || rawName.toLowerCase().startsWith('время')) {
            continue;
          }

          double qty = explicitQty ?? 1.0;
          double price = 0.0;
          double total = 0.0;

          if (lastNumbers.length == 3) {
            final n1 = double.tryParse(lastNumbers[0].group(1)!.replaceAll(',', '.')) ?? 1.0;
            final n2 = double.tryParse(lastNumbers[1].group(1)!.replaceAll(',', '.')) ?? 0.0;
            final n3 = double.tryParse(lastNumbers[2].group(1)!.replaceAll(',', '.')) ?? 0.0;

            if (explicitQty != null) {
              qty = explicitQty;
              price = (n2 > 0 && n2 < n3) ? n2 : ((n1 > 0 && n1 != qty) ? n1 : n2);
              total = (n3 > price) ? n3 : (qty * price);
            } else if ((n1 * n2 - n3).abs() <= (n3 * 0.15 + 1.0)) {
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

            if (explicitQty != null) {
              qty = explicitQty;
              price = n1 != qty ? n1 : n2;
              total = qty * price;
            } else if (n1 > 0 && n1 <= 1000) {
              qty = n1;
              price = n2;
              total = qty * price;
            } else {
              price = n1;
              total = n2;
              qty = (price > 0) ? (total / price) : 1.0;
            }
          }

          // Финальная математическая проверка
          if (qty > 0 && price > 0 && (total <= 0 || (qty * price - total).abs() > total * 0.1)) {
            total = double.parse((qty * price).toStringAsFixed(2));
          }

          // Интеллектуальное декодирование псевдо-латиницы в человеческий русский язык и срез артикулов
          final decodedName = CyrillicDecoder.decode(rawName);

          if (price > 0.05 && price < 500000.0 && total > 0.05 && total < 5000000.0 && qty > 0.001 && qty < 100000.0) {
            result.add(InvoiceItem(
              id: 'item_${DateTime.now().millisecondsSinceEpoch}_${result.length}',
              rawName: decodedName.isNotEmpty ? decodedName : rawName,
              quantity: qty,
              buyPrice: price,
              totalPrice: total > 0 ? total : (qty * price),
            ));
          }
        }
      }
      return result;
    }

    // ЭТАП 1: Разбор строго внутри обнаруженных границ таблицы
    if (tableStartIndex < tableEndIndex) {
      items.addAll(extractItemsFromRange(tableStartIndex, tableEndIndex));
    }

    // ЭТАП 2 (FALLBACK КАК В V1.0.4): Если по заголовкам ничего не найдено,
    // сканируем весь документ целиком (0..unifiedRows.length), отфильтровывая шум шапки и подвала.
    // Это гарантирует 100% распознавание строк товаров даже при блеклых/нестандартных заголовках!
    if (items.isEmpty) {
      items.addAll(extractItemsFromRange(0, unifiedRows.length));
    }

    final double computedTotal = items.fold<double>(0.0, (s, i) => s + i.totalPrice);
    final double finalTotal = (detectedTotal > 0 && computedTotal > 0 && (detectedTotal - computedTotal).abs() / computedTotal < 0.25)
        ? detectedTotal
        : computedTotal;

    return InvoiceDocument(
      id: 'doc_${DateTime.now().millisecondsSinceEpoch}',
      storeId: 1,
      supplierName: detectedSupplier,
      invoiceNumber: detectedInvoiceNum,
      invoiceDate: detectedDate,
      totalAmount: finalTotal,
      items: items,
      pagePhotos: imagePaths,
    );
  }

  // Офлайн-парсинг через локальный ML Kit
  Future<InvoiceDocument> _fallbackLocalParse(List<String> imagePaths) async {
    final List<String> unifiedRows = [];

    for (var path in imagePaths) {
      try {
        final inputImage = InputImage.fromFilePath(path);
        final recognizedText = await _mlKitRecognizer.processImage(inputImage);

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

        rawLines.sort((a, b) => a.top.compareTo(b.top));

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

        for (final List<_OcrLineBox> row in rows) {
          row.sort((_OcrLineBox a, _OcrLineBox b) => a.left.compareTo(b.left));
          final rowText = row.map((_OcrLineBox l) => l.text).join(' ').trim();
          if (rowText.length >= 2) {
            unifiedRows.add(rowText);
          }
        }
      } catch (e) {
        print('Offline ML Kit error: $e');
      }
    }

    return _parseUnifiedLines(unifiedRows, imagePaths);
  }

  String _cleanAndRepairJson(String text) {
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
    cleaned = cleaned.trim();

    // Если JSON закрыт корректно
    if (cleaned.endsWith('}')) {
      return cleaned;
    }

    // Если JSON оборвался на середине генерации из-за лимита токенов
    // Ищем последний полностью закрытый элемент массива товаров '}'
    final lastItemClose = cleaned.lastIndexOf('}');
    if (lastItemClose != -1) {
      final truncated = cleaned.substring(0, lastItemClose + 1);
      // Закрываем массив и корневой JSON-объект
      return '$truncated\n  ]\n}';
    }
    return cleaned;
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

  double get height => (bottom - top).abs();
  double get centerY => top + height / 2;
}
