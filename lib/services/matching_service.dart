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

  // Словарь синонимов: "supplier_name:raw_name" -> productId
  Map<String, int> _aliasDictionary = {};

  Future<void> init() async {
    final prefs = await SharedPreferences.getInstance();
    final rawDict = prefs.getString('supplier_aliases_dict');
    if (rawDict != null) {
      final decoded = jsonDecode(rawDict) as Map<String, dynamic>;
      _aliasDictionary = decoded.map((k, v) => MapEntry(k, v as int));
    }
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
    // Ищем товар в базе по штрихкоду
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

  // 2. Сохранение связки в постоянный обучаемый словарь сети
  Future<void> saveAlias(String supplierName, String rawName, int productId) async {
    final key = _buildKey(supplierName, rawName);
    _aliasDictionary[key] = productId;

    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('supplier_aliases_dict', jsonEncode(_aliasDictionary));
  }

  // 3. Автоматическое сопоставление документа
  void autoMatchDocument(InvoiceDocument doc, List<Product> catalog) {
    for (var item in doc.items) {
      if (item.matchedProductId != null) continue;

      // Шаг 1: Проверяем память истории (словарь синонимов)
      final key = _buildKey(doc.supplierName, item.rawName);
      if (_aliasDictionary.containsKey(key)) {
        final savedId = _aliasDictionary[key];
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
      if (candidates.isNotEmpty && candidates.first.score >= 0.82) {
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

  // 4. Получение ТОП-3 похожих кандидатов для 1-тап выбора
  List<MatchCandidate> getCandidates(String rawName, List<Product> catalog, {int limit = 3}) {
    final cleanInput = _normalizeText(rawName);
    final inputTokens = cleanInput.split(' ').where((t) => t.length > 1).toSet();

    final List<MatchCandidate> scoredList = [];

    for (var prod in catalog) {
      final cleanTarget = _normalizeText(prod.name);
      final targetTokens = cleanTarget.split(' ').where((t) => t.length > 1).toSet();

      // Jaccard similarity по токенам + учет вхождения
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
