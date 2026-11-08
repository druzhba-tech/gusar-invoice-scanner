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
import 'api_service.dart';

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
    // 0. Авто-выравнивание ориентации (если лист сфотографирован боком) для 100% точности Yandex Vision
    final List<String> preparedPaths = [];
    for (var p in imagePaths) {
      if (!p.toLowerCase().endsWith('.pdf')) {
        try {
          final straightened = await ImageUtils.autoStraightenInvoiceImage(
            File(p),
            recognizer: _mlKitRecognizer,
          );
          preparedPaths.add(straightened.path);
        } catch (_) {
          preparedPaths.add(p);
        }
      } else {
        preparedPaths.add(p);
      }
    }

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
    final yandexKey = config['yandex_key'] ?? defaultYandexKey;
    final geminiKey = config['gemini_key'] ?? defaultGeminiKey;
    final yandexFolderId = config['yandex_folder_id'] ?? defaultYandexFolderId;

    InvoiceDocument? doc;

    // 1. Всегда приоритетно вызываем Yandex Cloud Vision (100% кириллица и табличная разметка)
    if (yandexKey.isNotEmpty) {
      doc = await parseInvoiceWithYandexVision(
        preparedPaths,
        yandexKey,
        folderId: yandexFolderId,
        originalPaths: preparedPaths,
      );
    }

    // 2. Если Yandex не ответил и есть валидный ключ Gemini — вызываем Google Gemini Vision AI
    if ((doc == null || doc.items.isEmpty) && geminiKey.isNotEmpty && geminiKey.startsWith('AIza')) {
      doc = await _parseWithGemini(preparedPaths, geminiKey, template: knownTemplate, originalPaths: preparedPaths);
    }

    // 3. Fallback: если облачные нейросети не настроены или не ответили —
    // используем сверхбыстрый локальный офлайн-парсер Google ML Kit
    if (doc == null || doc.items.isEmpty) {
      doc = await _fallbackLocalParse(preparedPaths);
    }

    // 3.1. АВТО-ВОССТАНОВЛЕНИЕ ОРИЕНТАЦИИ (MULTI-ANGLE AUTO-RECOVERY):
    // Если накладная сфотографирована боком и первый проход дал 0 товаров —
    // поворачиваем снимок на 90 градусов и пробуем распознать снова ЧЕРЕЗ YANDEX VISION (с сохранением кириллицы)!
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

        InvoiceDocument? retryDoc;
        if (yandexKey.isNotEmpty) {
          retryDoc = await parseInvoiceWithYandexVision(
            currentTryPaths,
            yandexKey,
            folderId: yandexFolderId,
            originalPaths: currentTryPaths,
          );
        }
        if (retryDoc == null || retryDoc.items.isEmpty) {
          retryDoc = await _fallbackLocalParse(currentTryPaths);
        }
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

  int _toInt(dynamic v) {
    if (v is num) return v.toInt();
    if (v == null) return 0;
    return int.tryParse(v.toString().trim()) ?? 0;
  }

  double _toDouble(dynamic v) {
    if (v is num) return v.toDouble();
    if (v == null) return 0.0;
    return double.tryParse(v.toString().trim().replaceAll(',', '.')) ?? 0.0;
  }

  List<String> _groupYandexBlocksByRows(List<dynamic> blocks) {
    final List<_OcrLineBox> rawLines = [];
    for (var b in blocks) {
      final lines = b['lines'] as List<dynamic>? ?? [];
      for (var l in lines) {
        final text = l['text']?.toString().replaceAll(RegExp(r'[\r\n]+'), ' ').trim() ?? '';
        if (text.isEmpty) continue;
        final vertices = l['boundingBox']?['vertices'] as List<dynamic>? ?? [];
        if (vertices.isNotEmpty) {
          final xs = vertices.map((v) => _toDouble(v['x'])).toList();
          final ys = vertices.map((v) => _toDouble(v['y'])).toList();
          final left = xs.reduce((a, b) => a < b ? a : b);
          final right = xs.reduce((a, b) => a > b ? a : b);
          final top = ys.reduce((a, b) => a < b ? a : b);
          final bottom = ys.reduce((a, b) => a > b ? a : b);
          rawLines.add(_OcrLineBox(text: text, top: top, bottom: bottom, left: left, right: right));
        } else {
          rawLines.add(_OcrLineBox(text: text, top: rawLines.length * 30.0, bottom: rawLines.length * 30.0 + 20.0, left: 0, right: 100));
        }
      }
    }

    rawLines.sort((a, b) {
      final topDiff = a.top.compareTo(b.top);
      return topDiff != 0 ? topDiff : a.left.compareTo(b.left);
    });

    final List<List<_OcrLineBox>> rows = [];
    for (var line in rawLines) {
      List<_OcrLineBox>? bestRow;
      double bestOverlapY = 0.0;
      for (var row in rows) {
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

    final List<String> grouped = [];
    for (final row in rows) {
      row.sort((a, b) => a.left.compareTo(b.left));
      final rowText = row.map((l) => l.text).join('\t').trim();
      if (rowText.length >= 2) {
        grouped.add(rowText);
      }
    }
    return grouped;
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
      final List<String> fallbackBlockLines = [];

      for (var path in imagePaths) {
        final File sourceFile = File(path);
        final File uploadFile = path.toLowerCase().endsWith('.pdf')
            ? sourceFile
            : await ImageUtils.prepareImageForAiUpload(sourceFile);
        final bytes = await uploadFile.readAsBytes();
        final base64Image = base64Encode(bytes);
        final lowerPath = uploadFile.path.toLowerCase();
        final mimeType = lowerPath.endsWith('.png')
            ? 'PNG'
            : (lowerPath.endsWith('.pdf') ? 'PDF' : 'JPEG');

        final url = Uri.parse('https://ocr.api.cloud.yandex.net/ocr/v1/recognizeText');
        final headers = {
          'Content-Type': 'application/json',
          'Authorization': 'Api-Key $apiKey',
          'x-data-logging-enabled': 'true',
          if (folderId != null && folderId.trim().isNotEmpty) 'x-folder-id': folderId.trim(),
        };

        // Запрашиваем распознавание с моделью 'table' для кириллицы
        final body = jsonEncode({
          'mimeType': mimeType,
          'languageCodes': ['ru', 'en'],
          'model': 'table',
          'content': base64Image,
        });

        final response = await http.post(url, headers: headers, body: body).timeout(const Duration(seconds: 30));

        if (response.statusCode == 200) {
          final resJson = jsonDecode(response.body);
          final textAnnotation = resJson['result']?['textAnnotation'];
          if (textAnnotation != null) {
            final blocks = textAnnotation['blocks'] as List<dynamic>? ?? [];
            final pageBlockRows = _groupYandexBlocksByRows(blocks);
            fallbackBlockLines.addAll(pageBlockRows);

            // Добавляем шапку документа (первые строки из текстовых блоков для распознавания поставщика и № накладной)
            for (var br in pageBlockRows.take(8)) {
              final lower = br.toLowerCase();
              if (lower.contains('накладн') || lower.contains('поставщик') || lower.contains('чдмм') || lower.contains('ооо') || lower.contains('дата') || br.contains('№')) {
                extractedLines.add(br);
              }
            }

            // 1. Извлекаем ячейки таблиц с разделителем табуляции '\t' для сохранения точных границ колонок
            // ВАЖНО: Yandex возвращает rowIndex и columnIndex как String ("0", "1"), поэтому используем _toInt()!
            final tables = textAnnotation['tables'] as List<dynamic>? ?? [];
            if (tables.isNotEmpty) {
              for (var t in tables) {
                final cells = t['cells'] as List<dynamic>? ?? [];
                final Map<int, List<Map<String, dynamic>>> rowMap = {};
                for (var c in cells) {
                  final rIdx = _toInt(c['rowIndex']);
                  rowMap.putIfAbsent(rIdx, () => []).add(c as Map<String, dynamic>);
                }
                final sortedRows = rowMap.keys.toList()..sort();
                for (var r in sortedRows) {
                  final cellsInRow = rowMap[r]!;
                  cellsInRow.sort((a, b) => _toInt(a['columnIndex']).compareTo(_toInt(b['columnIndex'])));
                  final rowStr = cellsInRow
                      .map((c) => c['text']?.toString().replaceAll(RegExp(r'[\r\n\t]+'), ' ').trim() ?? '')
                      .where((s) => s.isNotEmpty)
                      .join('\t');
                  if (rowStr.isNotEmpty) {
                    extractedLines.add(rowStr);
                  }
                }
              }
            }

            // 2. Если табличная структура не выделилась, используем сгруппированные по Y строки из блоков
            if (tables.isEmpty && pageBlockRows.isNotEmpty) {
              extractedLines.addAll(pageBlockRows);
            }
          }
        } else {
          print('Yandex OCR API error: ${response.statusCode} - ${response.body}');
        }
      }

      InvoiceDocument? tableDoc;
      if (extractedLines.isNotEmpty) {
        tableDoc = _parseUnifiedLines(extractedLines, originalPaths ?? imagePaths);
      }
      InvoiceDocument? blockDoc;
      if (fallbackBlockLines.isNotEmpty) {
        blockDoc = _parseUnifiedLines(fallbackBlockLines, originalPaths ?? imagePaths);
      }

      if (tableDoc != null && blockDoc != null) {
        // Если таблица захватила только шапку или меньше позиций, чем полный разбор строк — выбираем более полный результат
        if (blockDoc.items.length > tableDoc.items.length) {
          return blockDoc;
        }
        return tableDoc;
      }
      if (tableDoc != null && tableDoc.items.isNotEmpty) return tableDoc;
      if (blockDoc != null) return blockDoc;
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
      final discountPct = (it['discount_percent'] as num?)?.toDouble() ?? 0.0;

      // 4. Математическая нормализация с учётом скидок и защита от перепутывания колонок
      if (total <= 0 && qty > 0 && price > 0) {
        if (discountPct > 0 && discountPct < 100) {
          price = double.parse((price * (1.0 - discountPct / 100.0)).toStringAsFixed(2));
        }
        total = double.parse((qty * price).toStringAsFixed(2));
      } else if (price <= 0 && qty > 0 && total > 0) {
        price = double.parse((total / qty).toStringAsFixed(2));
      } else if (qty <= 0 && price > 0 && total > 0) {
        qty = double.parse((total / price).toStringAsFixed(2));
      } else if (qty > 100 && price > 0 && price <= 50 && total > 0 && (qty - total).abs() <= 1.0) {
        final temp = qty;
        qty = price;
        price = temp;
      } else if (qty > 0 && price > 0 && total > 0) {
        final undiscountedTotal = qty * price;
        if (discountPct > 0 && discountPct < 100 && (undiscountedTotal - total).abs() <= 1.0) {
          // Если в total_price попала сумма без скидки, применяем скидку
          total = double.parse((undiscountedTotal * (1.0 - discountPct / 100.0)).toStringAsFixed(2));
          price = double.parse((total / qty).toStringAsFixed(2));
        } else if ((undiscountedTotal - total).abs() > 0.05) {
          // Если итоговая сумма меньше qty * price (скидка уже учтена в сумме) — пересчитываем цену со скидкой!
          if (total < undiscountedTotal && total >= undiscountedTotal * 0.45) {
            price = double.parse((total / qty).toStringAsFixed(2));
          } else if ((total / qty - price).abs() < (total / price - qty).abs()) {
            price = double.parse((total / qty).toStringAsFixed(2));
          } else {
            total = double.parse(undiscountedTotal.toStringAsFixed(2));
          }
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
      storeId: ApiService().currentStoreId > 0 ? ApiService().currentStoreId : 1,
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

        // Безопасная нормализация разделителей тысяч: "27 326,20" -> "27326,20"
        // ВАЖНО: объединяем только одиночный пробел (не \t и не 2+ пробела колонок) перед дробной частью 000.00 при 2-3 цифрах слева,
        // чтобы НИКОГДА не склеивать однозначное количество "8" с ценой "150.00"!
        row = row.replaceAllMapped(RegExp(r'\b(\d{2,3}) (\d{3}[\.,]\d{2})\b'), (m) => '${m[1]}${m[2]}');

        final allMatches = RegExp(r'\b([0-9]+(?:[\.,][0-9]+)?)\s*(%)?').allMatches(row).toList();
        if (allMatches.length >= 2) {
          final colMatches = _extractTrailingColumnMatches(row, allMatches);
          if (colMatches.length < 2) continue;

          final List<double> colNums = colMatches
              .map((m) => double.tryParse(m.group(1)!.replaceAll(',', '.')) ?? 0.0)
              .toList();
          final List<bool> colIsPct = colMatches
              .map((m) => (m.group(2) ?? '').isNotEmpty)
              .toList();

          // Поиск явного количества с единицей измерения ТОЛЬКО в числовых колонках справа
          double? explicitQty;
          final tailPart = row.substring(colMatches.first.start);
          final unitMatch = RegExp(r'\b(\d+(?:[\.,]\d+)?)\s*(шт|кг|л|уп|пач|кор|дона|д-на)\b', caseSensitive: false).firstMatch(tailPart);
          if (unitMatch != null) {
            explicitQty = double.tryParse(unitMatch.group(1)!.replaceAll(',', '.'));
          }

          final solved = _solveColumnsWithDiscount(colNums, colIsPct, explicitQty: explicitQty);
          final int firstNumIndex = colMatches[solved.usedStartIndex].start;
          var rawName = row.substring(0, firstNumIndex).trim();

          rawName = rawName.replaceAll(RegExp(r'^[0-9]+[\.\)\s\-]+\s*'), '').trim();
          rawName = rawName.replaceAll(RegExp(r'^[\|\:\;\,\.\-\_]+'), '').trim();

          // Автокоррекция частых ошибок латинского сканера ML Kit
          rawName = rawName.replaceAll(RegExp(r'\bpMHTep\b', caseSensitive: false), 'Принтер')
              .replaceAll(RegExp(r'\bCcaHep\b', caseSensitive: false), 'Сканер')
              .replaceAll(RegExp(r'\bCkaHep\b', caseSensitive: false), 'Сканер')
              .replaceAll(RegExp(r'\bHFP\b', caseSensitive: false), 'HP');

          if (rawName.length < 2 || lower.startsWith('тел') || lower.startsWith('инн') || lower.startsWith('р/с') || rawName.toLowerCase().startsWith('дата') || rawName.toLowerCase().startsWith('время')) {
            continue;
          }

          final double qty = solved.qty;
          final double price = solved.buyPrice;
          final double total = solved.totalPrice;

          // Интеллектуальное декодирование псевдо-латиницы в человеческий русский язык и срез артикулов
          final decodedName = CyrillicDecoder.decode(rawName);

          if (price > 0.05 && price < 500000.0 && total > 0.05 && total < 5000000.0 && qty > 0.001 && qty < 100000.0) {
            result.add(InvoiceItem(
              id: 'item_${DateTime.now().millisecondsSinceEpoch}_${result.length}',
              rawName: decodedName.isNotEmpty ? decodedName : rawName,
              quantity: qty,
              buyPrice: price,
              totalPrice: total > 0 ? total : double.parse((qty * price).toStringAsFixed(2)),
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
      storeId: ApiService().currentStoreId > 0 ? ApiService().currentStoreId : 1,
      supplierName: detectedSupplier,
      invoiceNumber: '',
      incomingNumber: detectedInvoiceNum,
      invoiceDate: detectedDate,
      totalAmount: finalTotal,
      items: items,
      pagePhotos: imagePaths,
    );
  }

  /// Выделяет все числовые колонки справа от наименования товара (от 2 до 6 колонок: Кол-во, Цена, Скидка %, Сумма без скидки, Сумма со скидкой),
  /// не захватывая числа фасовки внутри названия (например: "200 гр/18 шт", "140г х 19", "250 гр х 20 шт").
  List<RegExpMatch> _extractTrailingColumnMatches(String row, List<RegExpMatch> allMatches) {
    if (allMatches.length < 2) return allMatches;

    final List<RegExpMatch> selected = [allMatches.last];

    for (int k = allMatches.length - 2; k >= 0; k--) {
      if (selected.length >= 6) break;

      final curr = allMatches[k];
      final next = allMatches[k + 1];
      final String before = row.substring(0, curr.start);
      final String between = row.substring(curr.end, next.start);

      // 1. Если слева от числа вообще нет букв (например "1", "2" — порядковый номер строки в начале) -> стоп!
      if (!RegExp(r'[a-zA-Zа-яА-ЯёЁғқӣӯҳҷҒҚӢӮҲҶ]{2,}').hasMatch(before)) {
        break;
      }

      // 2. Если сразу после числа идёт вес/объём/размер фасовки ("200 гр", "140г", "250 мл") -> это часть названия товара!
      if (RegExp(r'^\s*(?:гр|г|мл|мг|см|мм)(?:\b|[^а-яА-Яa-zA-Z])', caseSensitive: false).hasMatch(between)) {
        break;
      }

      // 3. Если между этим числом и следующим есть знак дроби или умножения фасовки ("/", "х", "x", "*") -> это фасовка ("200 гр/18", "140г х 19")!
      if (RegExp(r'[\/\*×xхX]').hasMatch(between)) {
        break;
      }

      // 4. Если между числами есть обычный текст (кроме допустимых единиц измерения и валют колонок: шт, кг, уп, кор, тjs, сом, %) -> стоп!
      final cleanedBetween = between
          .replaceAll(
            RegExp(
              r'\b(?:шт|уп|упак|кор|пач|бл|блок|кг|л|литр|дона|д-на|компл|tjs|сом|сомони|руб|р|usd|wt|wт)\b',
              caseSensitive: false,
            ),
            '',
          )
          .replaceAll(RegExp(r'[\s\t\|,.;:\-\(\)%]+'), '');
      if (cleanedBetween.isNotEmpty) {
        break;
      }

      // 5. Если непосредственно перед числом стоит знак фасовки ("/18 шт", "х 20 шт", "x 19", "-10") -> это фасовка внутри названия!
      if (RegExp(r'(?:[\/\*×xхX\-№#]|\bпо)\s*$', caseSensitive: false).hasMatch(before)) {
        break;
      }

      selected.insert(0, curr);
    }

    // Если по какой-то причине выбралось только 1 число, берём последние 2 числа строки
    if (selected.length < 2 && allMatches.length >= 2) {
      return allMatches.sublist(allMatches.length - 2);
    }
    return selected;
  }

  /// Математический решатель колонок строки накладной с поддержкой скидок (% и суммовых)
  /// Возвращает:
  /// - usedStartIndex: с какого индекса в colNums начинаются реальные колонки таблицы
  /// - qty: количество
  /// - buyPrice: цена за 1 ед. С УЧЁТОМ СКИДКИ (если скидка есть)
  /// - totalPrice: итоговая сумма по строке С УЧЁТОМ СКИДКИ
  _SolvedRowMath _solveColumnsWithDiscount(
    List<double> nums,
    List<bool> isPct, {
    double? explicitQty,
  }) {
    bool eq(double a, double b, [double rel = 0.025, double abs = 0.65]) {
      return (a - b).abs() <= (b.abs() * rel + abs);
    }

    double r2(double v) => double.parse(v.toStringAsFixed(2));

    _SolvedRowMath? tryExactSlice(int s) {
      final c = nums.sublist(s);
      final p = isPct.sublist(s);
      final int len = c.length;

      // --- 5 ИЛИ 6 КОЛОНОК ---
      if (len >= 5) {
        // Вариант 5A: [Кол-во, Цена, Сумма_без_скидки, Скидка(% или сумма), ..., Сумма_со_скидкой]
        if (!p[0] && !p[1] && c[0] > 0 && c[1] > 0 && c[2] > 0 && eq(c[0] * c[1], c[2])) {
          final qty = c[0];
          final lastVal = c[len - 1];
          if (!p[len - 1] && lastVal > 0 && lastVal <= c[2] * 1.01 && lastVal >= c[2] * 0.4) {
            return _SolvedRowMath(s, qty, r2(lastVal / qty), r2(lastVal));
          } else if (c[3] > 0 && c[3] < 100) {
            final discTotal = r2(c[2] * (1.0 - c[3] / 100.0));
            return _SolvedRowMath(s, qty, r2(discTotal / qty), discTotal);
          }
          return _SolvedRowMath(s, qty, r2(c[1]), r2(c[2]));
        }

        // Вариант 5B: [Кол-во, Цена_без_скидки, Скидка%, Цена_со_скидкой, Сумма_со_скидкой]
        if (!p[0] && c[0] > 0 && c[3] > 0 && c[4] > 0 && eq(c[0] * c[3], c[4])) {
          return _SolvedRowMath(s, c[0], r2(c[3]), r2(c[4]));
        }

        // Вариант 5C: [Мест/Упак, В_упак, Кол-во, Цена, Сумма]
        if (!p[2] && c[2] > 0 && c[3] > 0 && c[4] > 0 && eq(c[2] * c[3], c[4])) {
          final lastVal = c[len - 1];
          final total = (len > 5 && lastVal > 0 && lastVal <= c[4]) ? lastVal : c[4];
          return _SolvedRowMath(s, c[2], r2(total / c[2]), r2(total));
        }
      }

      // --- 4 КОЛОНКИ: [c0, c1, c2, c3] ---
      if (len == 4) {
        // Вариант 4A: [Кол-во, Цена, Скидка %, Сумма со скидкой]
        // Пример: 8 | 60.00 | 7.5% | 444.00  (или Скидка = 0%: 8 | 7.50 | 0 | 60.00)
        if (!p[0] && !p[1] && !p[3] && c[0] > 0 && c[1] > 0 && c[2] >= 0 && c[2] < 100 && c[3] > 0) {
          final expectedDiscTotal = c[0] * c[1] * (1.0 - c[2] / 100.0);
          if (eq(expectedDiscTotal, c[3])) {
            return _SolvedRowMath(s, c[0], r2(c[3] / c[0]), r2(c[3]));
          }
        }

        // Вариант 4B: [Кол-во, Скидка %, Цена, Сумма со скидкой]
        // Пример: 8 | 7.5% | 60.00 | 444.00
        if (!p[0] && !p[2] && !p[3] && c[0] > 0 && c[2] > 0 && c[1] >= 0 && c[1] < 100 && c[3] > 0) {
          final expectedDiscTotal = c[0] * c[2] * (1.0 - c[1] / 100.0);
          if (eq(expectedDiscTotal, c[3])) {
            return _SolvedRowMath(s, c[0], r2(c[3] / c[0]), r2(c[3]));
          }
        }

        // Вариант 4C: [Кол-во, Цена без скидки, Цена со скидкой, Сумма со скидкой]
        if (!p[0] && !p[2] && !p[3] && c[0] > 0 && c[2] > 0 && c[2] <= c[1] && c[3] > 0 && eq(c[0] * c[2], c[3])) {
          return _SolvedRowMath(s, c[0], r2(c[2]), r2(c[3]));
        }

        // Вариант 4D: [Кол-во, Цена, Сумма скидки, Сумма со скидкой]
        if (!p[0] && !p[1] && !p[3] && c[0] > 0 && c[1] > 0 && c[2] >= 0 && c[3] > 0 && c[2] < c[0] * c[1]) {
          if (eq(c[0] * c[1] - c[2], c[3])) {
            return _SolvedRowMath(s, c[0], r2(c[3] / c[0]), r2(c[3]));
          }
        }

        // Вариант 4E: [Кол-во, Цена, Сумма без скидки, Скидка (0, % или Сумма со скидкой)]
        // Пример: 8 | 7.50 | 60.00 | 0  или  8 | 7.50 | 60.00 | 5%  или  8 | 7.50 | 60.00 | 57.00
        if (!p[0] && !p[1] && !p[2] && c[0] > 0 && c[1] > 0 && c[2] > 0 && eq(c[0] * c[1], c[2])) {
          final qty = c[0];
          if (c[3] == 0) {
            return _SolvedRowMath(s, qty, r2(c[1]), r2(c[2]));
          } else if (p[3] || (c[3] > 0 && c[3] <= 50 && c[3] < c[2] * 0.5)) {
            final discTotal = r2(c[2] * (1.0 - c[3] / 100.0));
            return _SolvedRowMath(s, qty, r2(discTotal / qty), discTotal);
          } else if (c[3] > 0 && c[3] <= c[2] && c[3] >= c[2] * 0.45) {
            return _SolvedRowMath(s, qty, r2(c[3] / qty), r2(c[3]));
          }
          return _SolvedRowMath(s, qty, r2(c[1]), r2(c[2]));
        }
      }

      // --- 3 КОЛОНКИ: [c0, c1, c2] ---
      if (len == 3) {
        // Вариант 3A: Стандартный [Кол-во, Цена, Сумма]
        if (!p[0] && !p[1] && !p[2] && c[0] > 0 && c[1] > 0 && c[2] > 0) {
          if (eq(c[0] * c[1], c[2])) {
            return _SolvedRowMath(s, c[0], r2(c[1]), r2(c[2]));
          }
          // Вариант 3B: [Кол-во, Сумма, Цена]
          if (eq(c[0] * c[2], c[1])) {
            return _SolvedRowMath(s, c[0], r2(c[2]), r2(c[1]));
          }
          // Вариант 3C: [Кол-во, Цена без скидки, Сумма со скидкой] (когда скидка уже вычтена в итоговой сумме)
          final undiscounted = c[0] * c[1];
          if (c[2] < undiscounted && c[2] >= undiscounted * 0.50 && c[0] <= 2000) {
            return _SolvedRowMath(s, c[0], r2(c[2] / c[0]), r2(c[2]));
          }
        }
      }

      return null;
    }

    // 1. Сначала пробуем решить с самого первого найденного числа (s = 0), затем со сдвигом (если s = 0 было частью названия товара)
    for (int s = 0; s <= nums.length - 3; s++) {
      final solved = tryExactSlice(s);
      if (solved != null) {
        return solved;
      }
    }

    // 2. Если точного уравнения не нашлось (например, всего 2 числа или сильное искажение OCR):
    final int s = nums.length > 3 ? nums.length - 3 : 0;
    final c = nums.sublist(s);
    if (c.length >= 3) {
      final n1 = c[0] > 0 ? c[0] : (explicitQty ?? 1.0);
      final n2 = c[1];
      final n3 = c[2];
      if (n1 > 0 && n2 > 0 && n3 > 0) {
        if (n3 <= n1 * n2 && n3 >= n1 * n2 * 0.45) {
          return _SolvedRowMath(s, n1, r2(n3 / n1), r2(n3));
        }
        return _SolvedRowMath(s, n1, r2(n2), r2(n1 * n2));
      }
    }

    // Для 2 чисел: [Кол-во, Цена] или [Цена, Сумма]
    final int s2 = nums.length >= 2 ? nums.length - 2 : 0;
    final n1 = nums[s2];
    final n2 = nums[s2 + 1];
    if (explicitQty != null && explicitQty > 0) {
      final pr = (n1 != explicitQty && n1 > 0) ? n1 : n2;
      return _SolvedRowMath(s2, explicitQty, r2(pr), r2(explicitQty * pr));
    }
    if (n1 > 0 && n1 <= 1000 && n2 > 0) {
      return _SolvedRowMath(s2, n1, r2(n2), r2(n1 * n2));
    }
    final pr = n1 > 0 ? n1 : 1.0;
    final tot = n2 > 0 ? n2 : pr;
    final q = pr > 0 ? r2(tot / pr) : 1.0;
    return _SolvedRowMath(s2, q > 0 ? q : 1.0, r2(pr), r2(tot));
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
          final rowText = row.map((_OcrLineBox l) => l.text).join('\t').trim();
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

class _SolvedRowMath {
  final int usedStartIndex;
  final double qty;
  final double buyPrice;
  final double totalPrice;

  _SolvedRowMath(this.usedStartIndex, this.qty, this.buyPrice, this.totalPrice);
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
