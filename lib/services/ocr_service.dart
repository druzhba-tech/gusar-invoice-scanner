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

  static String get defaultGeminiKey {
    try {
      return utf8.decode(base64Decode('QVEuQWI4Uk42SlZ2dDVWZDM2WmItYjFkQ3hUcVRJUEdnOFc5QVAxdDVZRVFvNlhUUkhJZmc='));
    } catch (_) {
      return '';
    }
  }

  static String get defaultYandexKey {
    try {
      return utf8.decode(base64Decode('QVFWTnhFNWdxTTI5ZWcwcVFEajRPMFhNcW1QLVB0Z3lpOGdnTzBVeQ=='));
    } catch (_) {
      return '';
    }
  }

  static String get defaultYandexFolderId => 'b1g19395325ob2oao64t';

  Future<Map<String, String>> _getAiConfig() async {
    final prefs = await SharedPreferences.getInstance();
    var savedGeminiKey = prefs.getString('gemini_api_key')?.trim() ?? '';
    if (savedGeminiKey.isEmpty || savedGeminiKey.length < 15) {
      savedGeminiKey = defaultGeminiKey;
    }
    var savedYandexKey = prefs.getString('yandex_api_key')?.trim() ?? '';
    if (savedYandexKey.isEmpty || savedYandexKey.length < 15) {
      savedYandexKey = defaultYandexKey;
    }
    var savedYandexFolderId = prefs.getString('yandex_folder_id')?.trim() ?? '';
    if (savedYandexFolderId.isEmpty) {
      savedYandexFolderId = defaultYandexFolderId;
    }

    final savedProvider = prefs.getString('ai_provider');
    final activeProvider = savedProvider ?? (savedYandexKey.isNotEmpty ? 'yandex' : 'gemini');

    return {
      'provider': activeProvider,
      'gemini_key': savedGeminiKey,
      'yandex_key': savedYandexKey,
      'yandex_folder_id': savedYandexFolderId,
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
    final provider = config['provider'] ?? 'yandex';
    final yandexKey = config['yandex_key'] ?? defaultYandexKey;
    final geminiKey = config['gemini_key'] ?? defaultGeminiKey;
    final yandexFolderId = config['yandex_folder_id'] ?? defaultYandexFolderId;

    InvoiceDocument? doc;

    // 1. Если провайдер Yandex или есть ключ Yandex — вызываем Yandex Cloud Vision (100% кириллица)
    if ((provider == 'yandex' || geminiKey.isEmpty) && yandexKey.isNotEmpty) {
      doc = await parseInvoiceWithYandexVision(preparedPaths, yandexKey, folderId: yandexFolderId);
    }

    // 2. Если Yandex не ответил или выбран Gemini — вызываем Google Gemini Vision AI
    if ((doc == null || doc.items.isEmpty) && geminiKey.isNotEmpty) {
      doc = await _parseWithGemini(preparedPaths, geminiKey, template: knownTemplate);
    }

    // 3. Если Gemini не ответил, но Yandex еще не пробовали — резервная попытка через Yandex
    if ((doc == null || doc.items.isEmpty) && yandexKey.isNotEmpty) {
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

      if (apiKey.trim().isEmpty) {
        return null;
      }

      // Используем проверенные стабильные модели Google Gemini
      final candidateModels = [
        'gemini-3.5-flash',
        'gemini-3.5-flash-lite',
        'gemini-3.6-flash',
        'gemini-flash-latest',
        'gemini-3.1-flash-lite',
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
          ).timeout(const Duration(seconds: 40));

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
            print('Gemini Auth/Param Error (${response.statusCode})');
            break;
          } else if (response.statusCode == 503 || response.statusCode == 429) {
            print('Gemini $modelName temporary busy (${response.statusCode}), switching to next model...');
            await Future.delayed(const Duration(milliseconds: 1000));
            continue;
          } else {
            print('Gemini $modelName Error: ${response.statusCode}, switching to next model...');
            await Future.delayed(const Duration(milliseconds: 500));
            continue;
          }
        } catch (e) {
          print('Gemini $modelName attempt failed: $e, switching to next model...');
          await Future.delayed(const Duration(milliseconds: 500));
          continue;
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
      'итого', 'всего', 'всего наименований', 'всего наиме', 'ҳамагӣ', 'ҷамъ', 'ндс', 'mtoro', 'wt.', 
      'отпустил', 'принял', 'сдал', 'бухгалтер', 'подпись', 'печать', 'м.п.',
      'наименовани', 'haumehoba', 'haumeho', 'сумма к оплате', 'вcero', 'bcero'
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
      invoiceNumber: '',
      incomingNumber: data['invoice_number']?.toString() ?? 'б/н',
      invoiceDate: data['invoice_date'] != null 
          ? DateTime.tryParse(data['invoice_date']) ?? DateTime.now() 
          : DateTime.now(),
      totalAmount: double.parse(totalAmount.toStringAsFixed(2)),
      items: items,
      pagePhotos: imagePaths,
    );
  }

  List<String> _splitGluedRow(String rawRow) {
    var trimmed = rawRow.trim();
    if (trimmed.isEmpty) return [];

    final List<String> subRows = [];
    if (trimmed.contains('|')) {
      final parts = trimmed.split('|');
      for (var p in parts) {
        final pt = p.trim();
        if (pt.length >= 2) {
          subRows.add(pt);
        }
      }
    } else {
      subRows.add(trimmed);
    }

    final List<String> result = [];
    for (var sr in subRows) {
      // Ищем склейку нескольких товаров: "(Код) Кол-во НовоеИмя"
      // например: "(Br120) 1 MaHro..."
      final splitPattern = RegExp(r'(\([A-Za-zА-Яа-я0-9\-_]+\)\s+\d+(?:[\.,]\d+)?)\s+(?=[A-ZА-ЯЁ][a-zа-яA-ZА-Я])');
      final matches = splitPattern.allMatches(sr).toList();
      if (matches.isNotEmpty) {
        int lastPos = 0;
        for (var m in matches) {
          final endOfItem = m.end;
          final part = sr.substring(lastPos, endOfItem).trim();
          if (part.isNotEmpty) {
            result.add(part);
          }
          lastPos = endOfItem;
        }
        if (lastPos < sr.length) {
          final remainder = sr.substring(lastPos).trim();
          if (remainder.isNotEmpty) {
            result.add(remainder);
          }
        }
      } else {
        result.add(sr);
      }
    }
    return result;
  }

  // =========================================================================
  // УНИФИЦИРОВАННЫЙ РАЗБОР СТРОК ТАБЛИЦЫ ДЛЯ КИРИЛЛИЦЫ
  // =========================================================================
  InvoiceDocument _parseUnifiedLines(List<String> rawUnifiedRows, List<String> imagePaths) {
    // 0. Предварительная нормализация: разъединяем склеенные в одну строку товары
    final List<String> unifiedRows = [];
    for (var r in rawUnifiedRows) {
      unifiedRows.addAll(_splitGluedRow(r));
    }

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
      'итого', 'всего', 'всего к оплате', 'всего:', 'всего наименований', 'всего наиме', 'сумма к оплате',
      'ҳамагӣ', 'ҷамъ', 'отпустил', 'получил', 'принял', 'сдал', 'супорид', 'қабул',
      'бухгалтер', 'подпись', 'печать', 'м.п.', 'mtoro', 'в том числе ндс',
      'наименовани', 'haumehoba', 'haumeho', 'вcero', 'bcero'
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

        // Пропускаем строки, состоящие исключительно из одиночного артикула в скобках: "(AB166)"
        if (RegExp(r'^\s*\([A-Za-zА-Яа-я0-9\-_]+\)\s*$').hasMatch(row)) {
          if (result.isNotEmpty && !result.last.rawName.contains(row.trim())) {
            result.last.rawName = '${result.last.rawName} ${row.trim()}';
          }
          continue;
        }

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

    // ЭТАП 2: Fallback если по заголовкам ничего не найдено
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
      invoiceNumber: '',
      incomingNumber: detectedInvoiceNum,
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

        // Сортируем блоки по вертикали (top), затем по горизонтали (left)
        rawLines.sort((a, b) {
          final topDiff = a.top.compareTo(b.top);
          return topDiff != 0 ? topDiff : a.left.compareTo(b.left);
        });

        // СТРОГАЯ ГРУППИРОВКА СТРОК ТАБЛИЦЫ:
        // 1. Горизонтальная исключительность: элементы одной строки находятся в разных колонках (не перекрываются по X).
        // 2. Вертикальное соответствие: элементы должны реально лежать в одной горизонтальной полосе таблицы (перекрытие по Y).
        // Это предотвращает объединение разных товаров в одну мега-строку!
        final List<List<_OcrLineBox>> rows = [];
        for (var line in rawLines) {
          List<_OcrLineBox>? bestRow;
          double bestOverlapY = 0.0;

          for (var row in rows) {
            // Проверка 1: нет ли горизонтального перекрытия с элементами строки (два товара в одной колонке)
            bool hasHorizontalOverlap = false;
            for (var existing in row) {
              final overlapX = (line.right < existing.right ? line.right : existing.right) -
                  (line.left > existing.left ? line.left : existing.left);
              final minW = line.width < existing.width ? line.width : existing.width;
              if (minW > 0 && (overlapX / minW) > 0.25) {
                hasHorizontalOverlap = true;
                break;
              }
            }
            if (hasHorizontalOverlap) continue;

            // Проверка 2: реальное вертикальное перекрытие строк таблицы
            final rowTop = row.map((b) => b.top).reduce((a, b) => a < b ? a : b);
            final rowBottom = row.map((b) => b.bottom).reduce((a, b) => a > b ? a : b);
            final overlapY = (line.bottom < rowBottom ? line.bottom : rowBottom) -
                (line.top > rowTop ? line.top : rowTop);
            final minH = line.height < (rowBottom - rowTop) ? line.height : (rowBottom - rowTop);

            if (minH > 0 && (overlapY / minH) >= 0.38) {
              if (overlapY > bestOverlapY) {
                bestOverlapY = overlapY;
                bestRow = row;
              }
            }
          }

          if (bestRow != null) {
            bestRow.add(line);
          } else {
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
  double get width => (right - left).abs();
  double get centerY => top + height / 2;
}
