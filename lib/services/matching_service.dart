import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/invoice_item.dart';
import '../models/invoice_document.dart';
import '../models/product.dart';

class MatchCandidate {
  final Product product;
  final double score; // 0.0 to 1.0

  MatchCandidate({required this.product, required this.score});
}

class MatchingService {
  static final MatchingService _instance = MatchingService._internal();
  factory MatchingService() => _instance;
  MatchingService._internal();

  // Словарь синонимов: "supplier::raw_name" -> productId и "global::raw_name" -> productId
  Map<String, int> _aliasDictionary = {};

  // Обучаемая память исправлений пользователя: "rawOcrText" -> "cleanText"
  Map<String, String> _correctionsDictionary = {};

  // Память контрагентов: "rawSupplierOcr" -> { id: 1, name: "ООО Оби Зулол" }
  Map<String, Map<String, dynamic>> _supplierAliases = {};

  Future<void> init() async {
    final prefs = await SharedPreferences.getInstance();
    final rawDict = prefs.getString('supplier_aliases_dict');
    if (rawDict != null) {
      try {
        final decoded = jsonDecode(rawDict) as Map<String, dynamic>;
        _aliasDictionary = decoded.map((k, v) => MapEntry(k, v as int));
      } catch (_) {}
    }

    final rawCorrections = prefs.getString('ocr_corrections_dict');
    if (rawCorrections != null) {
      try {
        final decoded = jsonDecode(rawCorrections) as Map<String, dynamic>;
        _correctionsDictionary = decoded.map((k, v) => MapEntry(k, v.toString()));
      } catch (_) {}
    }

    final rawSuppliers = prefs.getString('counterparty_aliases_dict');
    if (rawSuppliers != null) {
      try {
        final decoded = jsonDecode(rawSuppliers) as Map<String, dynamic>;
        _supplierAliases = decoded.map((k, v) => MapEntry(k, v as Map<String, dynamic>));
      } catch (_) {}
    }
  }

  // Сохранение привязки контрагента из базы
  Future<void> saveSupplierAlias(String rawOcrSupplier, int supplierId, String supplierName) async {
    final norm = _normalizeText(rawOcrSupplier);
    if (norm.isEmpty) return;
    _supplierAliases[norm] = {'id': supplierId, 'name': supplierName};
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('counterparty_aliases_dict', jsonEncode(_supplierAliases));
  }

  Map<String, dynamic>? matchSupplier(String rawSupplier) {
    final norm = _normalizeText(rawSupplier);
    if (norm.isEmpty) return null;
    if (_supplierAliases.containsKey(norm)) {
      return _supplierAliases[norm];
    }
    for (var entry in _supplierAliases.entries) {
      if (entry.key.length > 3 && (norm.contains(entry.key) || entry.key.contains(norm))) {
        return entry.value;
      }
    }
    return null;
  }

  String _buildKey(String supplier, String rawName) {
    return '${supplier.trim().toLowerCase()}::${_normalizeText(rawName)}';
  }

  // 1. Привязать навсегда по сканированию штрихкода (Scan to Bind)
  Future<bool> bindItemByBarcode({
    required InvoiceItem item,
    required String barcode,
    required String supplierName,
    required List<Product> catalog,
  }) async {
    Product? matchedProduct;
    try {
      matchedProduct = catalog.firstWhere((p) => p.barcode == barcode.trim());
    } catch (_) {
      matchedProduct = null;
    }

    if (matchedProduct != null) {
      applyMatch(item, matchedProduct, confidence: 1.0);
      await saveAlias(supplierName, item.rawName, matchedProduct.id);
      return true;
    }
    return false;
  }

  // 2. Сохранение связки в постоянный обучаемый словарь сети (поставщик + глобально)
  Future<void> saveAlias(String supplierName, String rawName, int productId) async {
    final key = _buildKey(supplierName, rawName);
    final globalKey = 'global::${_normalizeText(rawName)}';

    _aliasDictionary[key] = productId;
    _aliasDictionary[globalKey] = productId;

    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('supplier_aliases_dict', jsonEncode(_aliasDictionary));
  }

  // 3. Запоминание ручного исправления названия (самообучение системы)
  Future<void> learnCorrection({required String rawOcrText, required String cleanText}) async {
    final normRaw = _normalizeText(rawOcrText);
    final normClean = cleanText.trim();
    if (normRaw.isNotEmpty && normClean.isNotEmpty && normRaw != _normalizeText(normClean)) {
      _correctionsDictionary[normRaw] = normClean;
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('ocr_corrections_dict', jsonEncode(_correctionsDictionary));
    }
  }

  String applyCorrection(String rawText) {
    final norm = _normalizeText(rawText);
    if (norm.isEmpty) return rawText;

    // 1. Точное совпадение
    if (_correctionsDictionary.containsKey(norm)) {
      return _correctionsDictionary[norm]!;
    }

    // 2. Нечеткое совпадение по схожести токенов (защита от мелких дефектов сканирования)
    final inputTokens = norm.split(' ').where((t) => t.length > 2).toSet();
    if (inputTokens.isNotEmpty) {
      for (var entry in _correctionsDictionary.entries) {
        final keyTokens = entry.key.split(' ').where((t) => t.length > 2).toSet();
        if (keyTokens.isNotEmpty) {
          final intersect = inputTokens.intersection(keyTokens).length;
          final union = inputTokens.union(keyTokens).length;
          if (union > 0 && (intersect / union) >= 0.75) {
            return entry.value;
          }
        }
      }
    }

    return rawText;
  }

  int get rememberedAliasesCount => _aliasDictionary.length;
  int get rememberedCorrectionsCount => _correctionsDictionary.length;
  int get rememberedSuppliersCount => _supplierAliases.length;

  // 4. Автоматическое сопоставление накладной с каталогом товаров gusar.tj с приоритетом памяти
  void autoMatchDocument(InvoiceDocument doc, List<Product> catalog) {
    // Шаг -1: Проверяем память контрагентов
    if (doc.supplierId == null) {
      final matchedSup = matchSupplier(doc.supplierName);
      if (matchedSup != null) {
        doc.supplierId = matchedSup['id'] as int;
        doc.supplierName = matchedSup['name'] as String;
      }
    }

    for (var item in doc.items) {
      // Шаг 0: Применяем ранее выученные исправления названия
      final correctedName = applyCorrection(item.rawName);
      if (correctedName != item.rawName) {
        item.rawName = correctedName;
      }

      if (item.matchedProductId != null) continue;

      // Шаг 1: Проверяем память истории (словарь привязок конкретного поставщика или глобальный)
      final key = _buildKey(doc.supplierName, item.rawName);
      final globalKey = 'global::${_normalizeText(item.rawName)}';

      int? savedId = _aliasDictionary[key] ?? _aliasDictionary[globalKey];

      // Если прямого совпадения нет, ищем среди сохраненных связок по высокому сходству
      if (savedId == null) {
        final normItem = _normalizeText(item.rawName);
        for (var entry in _aliasDictionary.entries) {
          if (entry.key.startsWith('global::')) {
            final savedNorm = entry.key.substring(8);
            if (savedNorm.length > 3 && (normItem.contains(savedNorm) || savedNorm.contains(normItem))) {
              savedId = entry.value;
              break;
            }
          }
        }
      }

      if (savedId != null) {
        try {
          final prod = catalog.firstWhere((p) => p.id == savedId);
          applyMatch(item, prod, confidence: 1.0);
          continue;
        } catch (_) {}
      }

      // Шаг 2: Если у строки есть распознанный штрихкод
      if (item.barcode != null && item.barcode!.isNotEmpty) {
        try {
          final prod = catalog.firstWhere((p) => p.barcode == item.barcode);
          applyMatch(item, prod, confidence: 0.99);
          continue;
        } catch (_) {}
      }

      // Шаг 3: Нечеткое семантическое сопоставление (Fuzzy Match)
      final candidates = getCandidates(item.rawName, catalog, limit: 1);
      if (candidates.isNotEmpty && candidates.first.score >= 0.75) {
        applyMatch(item, candidates.first.product, confidence: candidates.first.score);
      }
    }
  }

  void applyMatch(InvoiceItem item, Product product, {required double confidence}) {
    item.matchedProductId = product.id;
    item.matchedProductName = product.name;
    item.matchedBarcode = product.barcode;
    item.currentRetailPrice = product.price;
    item.lastBuyPrice = product.costPrice > 0 ? product.costPrice : null;
    item.matchConfidence = confidence;
    item.status = ItemStatus.matched;
  }

  // 5. Получение ТОП-3 похожих кандидатов для 1-тап выбора
  List<MatchCandidate> getCandidates(String rawName, List<Product> catalog, {int limit = 3}) {
    final cleanInput = _normalizeText(rawName);
    final inputTokens = cleanInput.split(' ').where((t) => t.length > 1).toSet();

    final List<MatchCandidate> scoredList = [];

    for (var prod in catalog) {
      final cleanTarget = _normalizeText(prod.name);
      final targetTokens = cleanTarget.split(' ').where((t) => t.length > 1).toSet();

      if (inputTokens.isEmpty || targetTokens.isEmpty) continue;

      final intersection = inputTokens.intersection(targetTokens).length;
      final union = inputTokens.union(targetTokens).length;
      double score = union > 0 ? (intersection / union) : 0.0;

      // Бонус за точное вхождение подстроки
      if (cleanTarget.contains(cleanInput) || cleanInput.contains(cleanTarget)) {
        score = (score + 0.4).clamp(0.0, 1.0);
      }

      if (score > 0.25) {
        scoredList.add(MatchCandidate(product: prod, score: score));
      }
    }

    scoredList.sort((a, b) => b.score.compareTo(a.score));
    return scoredList.take(limit).toList();
  }

  String _normalizeText(String text) {
    return text
        .toLowerCase()
        .replaceAll(RegExp(r'[^\w\s\d]', unicode: true), ' ')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
  }
}
