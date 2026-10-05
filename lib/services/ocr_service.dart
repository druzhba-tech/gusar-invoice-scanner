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

  // Офлайн-парсинг строк на случай отсутствия интернета
  Future<InvoiceDocument> _fallbackLocalParse(List<String> imagePaths) async {
    final List<InvoiceItem> items = [];
    double totalAmount = 0.0;

    for (var path in imagePaths) {
      final text = await extractTextOffline(path);
      final lines = text.split('\n');

      for (var line in lines) {
        final trimmed = line.trim();
        if (trimmed.length < 3) continue;

        // Поиск строк вида: "Название 10 шт 45.00 450.00"
        final regex = RegExp(r'(.+?)\s+([0-9]+(?:[\.,][0-9]+)?)\s*(?:шт|кг|кор|л)?\s+([0-9]+(?:[\.,][0-9]+)?)\s+([0-9]+(?:[\.,][0-9]+)?)');
        final match = regex.firstMatch(trimmed);

        if (match != null) {
          final name = match.group(1)!.trim();
          final qty = double.tryParse(match.group(2)!.replaceAll(',', '.')) ?? 1.0;
          final price = double.tryParse(match.group(3)!.replaceAll(',', '.')) ?? 0.0;
          final total = double.tryParse(match.group(4)!.replaceAll(',', '.')) ?? (qty * price);

          items.add(InvoiceItem(
            id: 'local_${DateTime.now().millisecondsSinceEpoch}_${items.length}',
            rawName: name,
            quantity: qty,
            buyPrice: price,
            totalPrice: total,
          ));
          totalAmount += total;
        }
      }
    }

    return InvoiceDocument(
      id: 'doc_local_${DateTime.now().millisecondsSinceEpoch}',
      storeId: 1,
      supplierName: 'Поставщик (Локальный OCR)',
      invoiceNumber: 'б/н',
      invoiceDate: DateTime.now(),
      totalAmount: totalAmount,
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
