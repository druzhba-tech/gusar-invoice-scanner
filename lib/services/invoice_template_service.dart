import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/invoice_document.dart';
import '../models/invoice_item.dart';

/// Позиция товара в шаблоне накладной поставщика
class SupplierTemplateItem {
  final String rawName;
  final int productId;
  final String productName;
  final String? barcode;
  final String unit;
  final double lastBuyPrice;

  SupplierTemplateItem({
    required this.rawName,
    required this.productId,
    required this.productName,
    this.barcode,
    required this.unit,
    required this.lastBuyPrice,
  });

  Map<String, dynamic> toJson() => {
        'raw_name': rawName,
        'product_id': productId,
        'product_name': productName,
        'barcode': barcode,
        'unit': unit,
        'last_buy_price': lastBuyPrice,
      };

  factory SupplierTemplateItem.fromJson(Map<String, dynamic> json) => SupplierTemplateItem(
        rawName: json['raw_name']?.toString() ?? '',
        productId: json['product_id'] is int ? json['product_id'] as int : int.tryParse(json['product_id']?.toString() ?? '0') ?? 0,
        productName: json['product_name']?.toString() ?? '',
        barcode: json['barcode']?.toString(),
        unit: json['unit']?.toString() ?? 'шт',
        lastBuyPrice: (json['last_buy_price'] as num?)?.toDouble() ?? 0.0,
      );
}

/// Шаблон формата накладной конкретного поставщика
class SupplierInvoiceTemplate {
  final String supplierName;
  int? supplierId;
  final List<String> signatures; // ключевые маркеры шапки (ИНН, название, характерные слова)
  String columnOrder; // структура колонок: "№ | Наименование | Ед. изм | Кол-во | Цена | Сумма"
  final Map<String, SupplierTemplateItem> items; // ключ: нормализованное имя товара
  int usageCount;
  DateTime lastUsed;

  SupplierInvoiceTemplate({
    required this.supplierName,
    this.supplierId,
    required this.signatures,
    this.columnOrder = '№ | Наименование | Ед | Кол-во | Цена | Сумма',
    required this.items,
    this.usageCount = 1,
    DateTime? lastUsed,
  }) : lastUsed = lastUsed ?? DateTime.now();

  Map<String, dynamic> toJson() => {
        'supplier_name': supplierName,
        'supplier_id': supplierId,
        'signatures': signatures,
        'column_order': columnOrder,
        'items': items.map((k, v) => MapEntry(k, v.toJson())),
        'usage_count': usageCount,
        'last_used': lastUsed.toIso8601String(),
      };

  factory SupplierInvoiceTemplate.fromJson(Map<String, dynamic> json) {
    final rawItems = json['items'] as Map<String, dynamic>? ?? {};
    final parsedItems = <String, SupplierTemplateItem>{};
    for (var entry in rawItems.entries) {
      if (entry.value is Map<String, dynamic>) {
        parsedItems[entry.key] = SupplierTemplateItem.fromJson(entry.value as Map<String, dynamic>);
      }
    }

    final rawSignatures = json['signatures'] as List<dynamic>? ?? [];
    final signatures = rawSignatures.map((s) => s.toString()).toList();

    return SupplierInvoiceTemplate(
      supplierName: json['supplier_name']?.toString() ?? 'Поставщик',
      supplierId: json['supplier_id'] is int ? json['supplier_id'] as int : int.tryParse(json['supplier_id']?.toString() ?? ''),
      signatures: signatures,
      columnOrder: json['column_order']?.toString() ?? '№ | Наименование | Ед | Кол-во | Цена | Сумма',
      items: parsedItems,
      usageCount: json['usage_count'] is int ? json['usage_count'] as int : 1,
      lastUsed: DateTime.tryParse(json['last_used']?.toString() ?? '') ?? DateTime.now(),
    );
  }
}

/// Сервис самообучения и запоминания форматов накладных поставщиков (Invoice Template Service).
/// Обеспечивает:
/// 1. Автоматическое запоминание шаблонов поставщиков при каждом подтверждении накладной
/// 2. Мгновенное опознавание знакомого поставщика по шапке и структуре документа
/// 3. Обогащение Vision AI подсказками формата колонок для ускорения ответа нейросети
/// 4. Мгновенную привязку (100% сопоставление) повторяющихся товаров при повторной закупке
class InvoiceTemplateService {
  static final InvoiceTemplateService _instance = InvoiceTemplateService._internal();
  factory InvoiceTemplateService() => _instance;
  InvoiceTemplateService._internal();

  static const String _prefKey = 'saved_supplier_invoice_templates_v1';
  final Map<String, SupplierInvoiceTemplate> _templates = {};
  bool _isInitialized = false;

  int get templatesCount => _templates.length;
  List<SupplierInvoiceTemplate> get allTemplates => _templates.values.toList();

  Future<void> init() async {
    if (_isInitialized) return;
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_prefKey);
      if (raw != null && raw.isNotEmpty) {
        final decoded = jsonDecode(raw) as Map<String, dynamic>;
        for (var entry in decoded.entries) {
          if (entry.value is Map<String, dynamic>) {
            _templates[entry.key] = SupplierInvoiceTemplate.fromJson(entry.value as Map<String, dynamic>);
          }
        }
      }
      _isInitialized = true;
    } catch (e) {
      print('InvoiceTemplateService init error: $e');
      _isInitialized = true;
    }
  }

  String _normalize(String text) {
    return text
        .toLowerCase()
        .replaceAll(RegExp(r'["«»„“\.,:;\-_/\\]+'), ' ')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
  }

  /// Поиск шаблона по названию контрагента
  SupplierInvoiceTemplate? findTemplateForSupplier(String supplierName) {
    final norm = _normalize(supplierName);
    if (norm.isEmpty) return null;

    if (_templates.containsKey(norm)) {
      return _templates[norm];
    }

    for (var entry in _templates.entries) {
      if (entry.key.length >= 3 && (norm.contains(entry.key) || entry.key.contains(norm))) {
        return entry.value;
      }
    }
    return null;
  }

  /// Поиск шаблона по ключевым фразам/сигнатурам из первых строк распознанного текста
  SupplierInvoiceTemplate? detectTemplateFromOcrText(String ocrText) {
    if (ocrText.trim().isEmpty) return null;
    final normText = _normalize(ocrText);

    SupplierInvoiceTemplate? bestMatch;
    int bestScore = 0;

    for (var template in _templates.values) {
      int score = 0;
      final normSupplier = _normalize(template.supplierName);
      if (normSupplier.length >= 3 && normText.contains(normSupplier)) {
        score += 5;
      }

      for (var sig in template.signatures) {
        final normSig = _normalize(sig);
        if (normSig.length >= 3 && normText.contains(normSig)) {
          score += 2;
        }
      }

      if (score > bestScore && score >= 2) {
        bestScore = score;
        bestMatch = template;
      }
    }

    return bestMatch;
  }

  /// Обучение: запоминание формата и каталога товаров накладной поставщика
  Future<void> learnFromInvoice(InvoiceDocument doc) async {
    await init();
    final normSupplier = _normalize(doc.supplierName);
    if (normSupplier.isEmpty) return;

    SupplierInvoiceTemplate template = _templates[normSupplier] ??
        SupplierInvoiceTemplate(
          supplierName: doc.supplierName,
          supplierId: doc.supplierId,
          signatures: [doc.supplierName],
          items: {},
        );

    template.supplierId = doc.supplierId ?? template.supplierId;
    template.lastUsed = DateTime.now();
    template.usageCount++;

    // Добавляем сигнатуры
    if (!template.signatures.contains(doc.supplierName)) {
      template.signatures.add(doc.supplierName);
    }

    // Сохраняем все привязанные товары в память шаблона поставщика
    for (var item in doc.items) {
      final normItem = _normalize(item.rawName);
      if (normItem.isEmpty) continue;

      if (item.matchedProductId != null && item.matchedProductId! > 0) {
        template.items[normItem] = SupplierTemplateItem(
          rawName: item.rawName,
          productId: item.matchedProductId!,
          productName: item.matchedProductName ?? item.rawName,
          barcode: item.matchedBarcode ?? item.barcode,
          unit: item.unit.isNotEmpty ? item.unit : 'шт',
          lastBuyPrice: item.buyPrice > 0 ? item.buyPrice : 0.0,
        );
      }
    }

    _templates[normSupplier] = template;
    await _persist();
  }

  /// Мгновенная привязка товаров из памяти шаблона при повторной покупке
  int applyTemplateToDocument(InvoiceDocument doc, SupplierInvoiceTemplate template) {
    int matchedCount = 0;

    if (doc.supplierId == null && template.supplierId != null) {
      doc.supplierId = template.supplierId;
      doc.supplierName = template.supplierName;
    }

    for (var item in doc.items) {
      if (item.matchedProductId != null && item.matchedProductId! > 0) continue;

      final norm = _normalize(item.rawName);
      SupplierTemplateItem? found = template.items[norm];

      // Если точного совпадения нет, ищем по высокой токенной схожести (>= 85%)
      if (found == null) {
        final itemTokens = norm.split(' ').where((t) => t.length > 2).toSet();
        if (itemTokens.length >= 2) {
          double bestScore = 0.0;
          for (var entry in template.items.entries) {
            final entryTokens = entry.key.split(' ').where((t) => t.length > 2).toSet();
            if (entryTokens.length >= 2) {
              final inter = itemTokens.intersection(entryTokens).length;
              final union = itemTokens.union(entryTokens).length;
              final sim = union > 0 ? (inter / union) : 0.0;
              if (sim >= 0.85 && sim > bestScore) {
                bestScore = sim;
                found = entry.value;
              }
            }
          }
        }
      }

      if (found != null) {
        item.matchedProductId = found.productId;
        item.matchedProductName = found.productName;
        item.matchedBarcode = found.barcode;
        item.matchConfidence = 1.0;
        item.status = ItemStatus.verified;
        item.lastBuyPrice = found.lastBuyPrice;
        if (item.unit.isEmpty || item.unit == 'шт') {
          item.unit = found.unit;
        }
        matchedCount++;
      }
    }

    return matchedCount;
  }

  /// Формирование подсказки для Vision AI, чтобы нейросеть мгновенно поняла структуру документа
  String buildAiTemplatePromptHint(SupplierInvoiceTemplate? template) {
    if (template == null) return '';

    final knownNames = template.items.values.take(15).map((i) => '"${i.productName}"').join(', ');
    return '''
ВНИМАНИЕ — ИСПОЛЬЗУЙ ЗАПОМНЕННЫЙ ШАБЛОН ЭТОГО ПОСТАВЩИКА ДЛЯ УСКОРЕНИЯ:
• Поставщик: "${template.supplierName}" (ранее накладные этого поставщика уже оприходовались ${template.usageCount} раз).
• Порядок колонок в таблице: ${template.columnOrder}.
• Частые товары этого поставщика: [$knownNames].
Используй эти известные названия для безошибочного выделения колонок "Наименование", "Кол-во", "Цена" и "Сумма".
''';
  }

  Future<void> _persist() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final encoded = jsonEncode(_templates.map((k, v) => MapEntry(k, v.toJson())));
      await prefs.setString(_prefKey, encoded);
    } catch (e) {
      print('InvoiceTemplateService persist error: $e');
    }
  }

  Future<void> clearAll() async {
    _templates.clear();
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_prefKey);
  }
}
