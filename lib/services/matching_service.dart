import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/invoice_item.dart';
import '../models/invoice_document.dart';
import '../models/product.dart';
import '../utils/cyrillic_decoder.dart';
import 'api_service.dart';
import 'invoice_template_service.dart';

/// Единая фонетическая нормализация (русский + таджикский: ё=е, ый=ий, ғ=г, қ=к, ҳ=х, ӯ=у, ҷ=ч, ӣ=и)
/// Позволяет точно сопоставлять «сок добрий» с «Сок Добрый Яблочный» даже при опечатках
String normalizeProductNameForMatch(String text) {
  final decoded = CyrillicDecoder.decode(text);
  return decoded
      .toLowerCase()
      .replaceAll('ё', 'е')
      .replaceAll('ғ', 'г')
      .replaceAll('қ', 'к')
      .replaceAll('ҳ', 'х')
      .replaceAll('ӯ', 'у')
      .replaceAll('ҷ', 'ч')
      .replaceAll('ӣ', 'и')
      .replaceAll(RegExp(r'ый\b'), 'ий')
      .replaceAll(RegExp(r'[^\w\s\d]', unicode: true), ' ')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();
}

class MatchCandidate {
  final Product product;
  final double score; // 0.0 to 1.0

  MatchCandidate({required this.product, required this.score});
}

class MatchingService {
  static final MatchingService _instance = MatchingService._internal();
  factory MatchingService() => _instance;
  MatchingService._internal();

  // Словарь синонимов: "s3::supplier::raw_name" -> productId (для 1-к-1 автопривязки)
  Map<String, int> _aliasDictionary = {};
  Map<String, int> get aliasDictionary => Map.unmodifiable(_aliasDictionary);

  // Мульти-вариантный словарь: если общее имя ("сок добрий") привязывалось к 2+ разным вкусам,
  // храним список всех productId, чтобы НЕ привязывать вслепую к одному вкусу, а показать их первыми!
  Map<String, List<int>> _multiAliases = {};

  // Обучаемая память исправлений пользователя: "rawOcrText" -> "cleanText"
  Map<String, String> _correctionsDictionary = {};

  // Память контрагентов: "rawSupplierOcr" -> { id: 1, name: "ООО Оби Зулол" }
  Map<String, Map<String, dynamic>> _supplierAliases = {};

  // Очистка всех связок товаров (пользовательский запрос "почисти все связанные товары")
  Future<void> clearAllAliases() async {
    _aliasDictionary.clear();
    _correctionsDictionary.clear();
    _supplierAliases.clear();
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove('supplier_aliases_dict');
    await prefs.remove('ocr_corrections_dict');
    await prefs.remove('counterparty_aliases_dict');
    await prefs.setBool('aliases_cleaned_v1429', true);
  }

  int _resolveStoreId(int? storeId) {
    if (storeId != null && storeId > 0) return storeId;
    return ApiService().currentStoreId > 0 ? ApiService().currentStoreId : 3;
  }

  // Удаление конкретной связки (с изоляцией по store_id)
  Future<void> removeAlias(String supplierName, String rawName, {int? storeId}) async {
    final sid = _resolveStoreId(storeId);
    final key = _buildKey(supplierName, rawName, storeId: sid);
    final globalKey = 's$sid::global::${_normalizeText(rawName)}';
    _aliasDictionary.remove(key);
    _aliasDictionary.remove(globalKey);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('supplier_aliases_dict', jsonEncode(_aliasDictionary));
  }

  Future<void> init() async {
    final prefs = await SharedPreferences.getInstance();
    final alreadyCleaned = prefs.getBool('aliases_cleaned_v1429') ?? false;
    if (!alreadyCleaned) {
      await clearAllAliases();
      return;
    }

    final rawDict = prefs.getString('supplier_aliases_dict');
    if (rawDict != null) {
      try {
        final decoded = jsonDecode(rawDict) as Map<String, dynamic>;
        _aliasDictionary = decoded.map((k, v) => MapEntry(k, v as int));
        // Очищаем любые поврежденные / слишком короткие или общие ключи, а также фейковые ID
        _aliasDictionary.removeWhere((k, v) {
          if (v <= 0 || v >= 100000000 || (v >= 101 && v <= 110)) return true;
          final cleanKey = k.replaceAll('global::', '').replaceAll(RegExp(r'^.*?::'), '').trim();
          if (cleanKey.length < 5) return true;
          const genericWords = {'сливки', 'со вкусом', 'сыр', 'соль', 'шоколад', 'конфеты', 'печенье', 'молоко', 'масло', 'сахар'};
          return genericWords.contains(cleanKey);
        });
      } catch (_) {}
    }

    final rawMulti = prefs.getString('supplier_multi_aliases_dict');
    if (rawMulti != null) {
      try {
        final decoded = jsonDecode(rawMulti) as Map<String, dynamic>;
        _multiAliases = decoded.map((k, v) => MapEntry(
              k,
              (v is List)
                  ? v.map((e) => int.tryParse(e.toString()) ?? 0).where((id) => id > 0 && id < 100000000).toList()
                  : <int>[],
            ));
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
        // Очищаем любые поврежденные псевдо-ID (таймстампы >= 1,000,000)
        _supplierAliases.removeWhere((k, v) {
          final id = v['id'] is int ? v['id'] as int : int.tryParse(v['id']?.toString() ?? '0') ?? 0;
          return id <= 0 || id >= 1000000;
        });
      } catch (_) {}
    }
  }

  // Сохранение привязки контрагента из базы (изолировано по store_id)
  Future<void> saveSupplierAlias(String rawOcrSupplier, int supplierId, String supplierName, {int? storeId}) async {
    // Никогда не сохраняем клиентские псевдо-ID (таймстампы)
    if (supplierId <= 0 || supplierId >= 1000000) return;
    final sid = _resolveStoreId(storeId);
    final norm = _normalizeText(rawOcrSupplier);
    if (norm.isEmpty) return;
    _supplierAliases['s$sid::$norm'] = {'id': supplierId, 'name': supplierName, 'store_id': sid};
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('counterparty_aliases_dict', jsonEncode(_supplierAliases));
  }

  Map<String, dynamic>? matchSupplier(String rawSupplier, {int? storeId}) {
    final sid = _resolveStoreId(storeId);
    final prefix = 's$sid::';
    final norm = _normalizeText(rawSupplier);
    if (norm.isEmpty) return null;
    Map<String, dynamic>? res;
    if (_supplierAliases.containsKey('$prefix$norm')) {
      res = _supplierAliases['$prefix$norm'];
    } else {
      for (var entry in _supplierAliases.entries) {
        if (!entry.key.startsWith(prefix)) continue;
        final cleanEntryKey = entry.key.substring(prefix.length);
        if (cleanEntryKey.length > 3 && (norm.contains(cleanEntryKey) || cleanEntryKey.contains(norm))) {
          res = entry.value;
          break;
        }
      }
    }
    if (res != null) {
      final id = res['id'] is int ? res['id'] as int : int.tryParse(res['id']?.toString() ?? '0') ?? 0;
      if (id <= 0 || id >= 1000000) return null;
    }
    return res;
  }

  String _buildKey(String supplier, String rawName, {int? storeId}) {
    final sid = _resolveStoreId(storeId);
    return 's$sid::${supplier.trim().toLowerCase()}::${_normalizeText(rawName)}';
  }

  // 1. Привязать навсегда по сканированию штрихкода (Scan to Bind)
  Future<bool> bindItemByBarcode({
    required InvoiceItem item,
    required String barcode,
    required String supplierName,
    required List<Product> catalog,
    int? storeId,
  }) async {
    Product? matchedProduct;
    try {
      matchedProduct = catalog.firstWhere((p) => p.barcode == barcode.trim());
    } catch (_) {
      matchedProduct = null;
    }

    if (matchedProduct != null) {
      applyMatch(item, matchedProduct, confidence: 1.0);
      await saveAlias(supplierName, item.rawName, matchedProduct.id, storeId: storeId ?? matchedProduct.storeId);
      return true;
    }
    return false;
  }

  // Синхронизация централизованного словаря синонимов с сервером gusar.tj для текущего магазина
  Future<void> syncFromServer({int? storeId}) async {
    final sid = _resolveStoreId(storeId);
    final serverRows = await ApiService().fetchSupplierAliases(storeId: sid);
    if (serverRows.isEmpty) return;

    final Map<String, Set<int>> grouped = {};
    for (final row in serverRows) {
      final pid = row['product_id'] is int
          ? row['product_id'] as int
          : int.tryParse(row['product_id']?.toString() ?? '') ?? 0;
      if (pid <= 0 || pid >= 100000000 || (pid >= 101 && pid <= 110)) continue;
      final supNorm = normalizeProductNameForMatch((row['supplier_name_norm'] ?? '').toString());
      final rawNorm = normalizeProductNameForMatch((row['raw_name_norm'] ?? row['raw_name'] ?? '').toString());
      if (rawNorm.length < 3) continue;

      final supKey = 's$sid::$supNorm::$rawNorm';
      final globalKey = 's$sid::global::$rawNorm';
      grouped.putIfAbsent(supKey, () => <int>{}).add(pid);
      grouped.putIfAbsent(globalKey, () => <int>{}).add(pid);
    }

    for (final entry in grouped.entries) {
      final ids = entry.value.toList();
      _multiAliases[entry.key] = ids;
      if (ids.length == 1) {
        _aliasDictionary[entry.key] = ids.first;
      } else {
        // Несколько разных товаров на одно общее название ("сок добрий"): не привязываем вслепую!
        _aliasDictionary.remove(entry.key);
      }
    }

    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('supplier_aliases_dict', jsonEncode(_aliasDictionary));
    await prefs.setString('supplier_multi_aliases_dict', jsonEncode(_multiAliases));
  }

  // 2. Сохранение связки в постоянный обучаемый словарь магазина (локально + сервер gusar.tj)
  Future<void> saveAlias(String supplierName, String rawName, int productId, {int? storeId, int? supplierId}) async {
    if (productId <= 0 || productId >= 100000000 || (productId >= 101 && productId <= 110)) return;
    final sid = _resolveStoreId(storeId);

    final key = _buildKey(supplierName, rawName, storeId: sid);
    final globalKey = 's$sid::global::${_normalizeText(rawName)}';

    for (final k in [key, globalKey]) {
      final existingList = List<int>.from(_multiAliases[k] ?? <int>[]);
      if (!existingList.contains(productId)) {
        existingList.insert(0, productId);
      }
      _multiAliases[k] = existingList;
      if (existingList.length == 1) {
        _aliasDictionary[k] = productId;
      } else {
        // Обнаружен второй вариант на то же общее название — переводим в режим быстрого выбора!
        _aliasDictionary.remove(k);
      }
    }

    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('supplier_aliases_dict', jsonEncode(_aliasDictionary));
    await prefs.setString('supplier_multi_aliases_dict', jsonEncode(_multiAliases));

    // Фоновая синхронизация на сервер gusar.tj (доступно всем устройствам магазина)
    ApiService().saveSupplierAliasOnServer(
      supplierName: supplierName,
      rawName: rawName,
      productId: productId,
      supplierId: supplierId,
      storeId: sid,
    );
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

  // 4. Автоматическое сопоставление накладной с каталогом товаров gusar.tj с приоритетом памяти (строго по store_id)
  void autoMatchDocument(InvoiceDocument doc, List<Product> catalog) {
    final sid = _resolveStoreId(doc.storeId);
    final storePrefix = 's$sid::';
    // Фильтруем каталог строго по магазину документа
    final storeCatalog = catalog.where((p) => p.storeId <= 0 || p.storeId == sid).toList();

    // Шаг -1: Проверяем память контрагентов текущего магазина
    if (doc.supplierId == null) {
      final matchedSup = matchSupplier(doc.supplierName, storeId: sid);
      if (matchedSup != null) {
        doc.supplierId = matchedSup['id'] as int;
        doc.supplierName = matchedSup['name'] as String;
      }
    }

    // Шаг -0.5: Применяем запомненный шаблон поставщика (повторные закупки матчатся мгновенно)
    final template = InvoiceTemplateService().findTemplateForSupplier(doc.supplierName);
    if (template != null) {
      InvoiceTemplateService().applyTemplateToDocument(doc, template);
    }

    for (var item in doc.items) {
      // Шаг 0: Применяем ранее выученные исправления названия
      final correctedName = applyCorrection(item.rawName);
      if (correctedName != item.rawName) {
        item.rawName = correctedName;
      }

      if (item.matchedProductId != null) continue;

      // Шаг 1: Проверяем память истории строго в рамках текущего store_id
      final key = _buildKey(doc.supplierName, item.rawName, storeId: sid);
      final globalKey = 's$sid::global::${_normalizeText(item.rawName)}';

      // Защита от автопривязки общих названий ("сок добрий"), имеющих 2+ вкусов/товаров:
      final multiIds = _multiAliases[key] ?? _multiAliases[globalKey];
      final bool isAmbiguousMultiVariant = multiIds != null && multiIds.length > 1;

      int? savedId = isAmbiguousMultiVariant ? null : (_aliasDictionary[key] ?? _aliasDictionary[globalKey]);

      // Если прямого совпадения нет (и название не помечено как многовариантное), ищем по схожести (>= 85%)
      if (savedId == null && !isAmbiguousMultiVariant) {
        final normItem = _normalizeText(item.rawName);
        final itemTokens = normItem.split(' ').where((t) => t.length > 2).toSet();
        if (itemTokens.length >= 2) {
          double bestScore = 0.0;
          for (var entry in _aliasDictionary.entries) {
            if (!entry.key.startsWith(storePrefix)) continue;
            final keyStr = entry.key.split('::').last;
            final keyTokens = keyStr.split(' ').where((t) => t.length > 2).toSet();
            if (keyTokens.length >= 2) {
              final inter = itemTokens.intersection(keyTokens).length;
              final union = itemTokens.union(keyTokens).length;
              final sim = union > 0 ? (inter / union) : 0.0;
              if (sim >= 0.85 && sim > bestScore) {
                bestScore = sim;
                savedId = entry.value;
              }
            }
          }
        }
      }

      if (savedId != null) {
        try {
          final prod = storeCatalog.firstWhere((p) => p.id == savedId);
          applyMatch(item, prod, confidence: 1.0);
          continue;
        } catch (_) {}
      }

      // Шаг 2: Если у строки есть распознанный штрихкод
      if (item.barcode != null && item.barcode!.isNotEmpty) {
        try {
          final prod = storeCatalog.firstWhere((p) => p.barcode == item.barcode);
          applyMatch(item, prod, confidence: 0.99);
          continue;
        } catch (_) {}
      }

      // Шаг 3: Нечеткое семантическое сопоставление (Fuzzy Match)
      // В приёмке товаров строго требуется точность >= 85%, чтобы конфеты не матчились на шоколад
      final candidates = getCandidates(item.rawName, storeCatalog, limit: 1);
      if (candidates.isNotEmpty && candidates.first.score >= 0.85) {
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

  // 5. Получение ТОП-3 похожих кандидатов для 1-тап выбора (с приоритетом известных вариантов из словаря)
  List<MatchCandidate> getCandidates(String rawName, List<Product> catalog, {int limit = 3, int? storeId, String? supplierName}) {
    final cleanInput = _normalizeText(rawName);
    final inputTokens = cleanInput.split(' ').where((t) => t.length > 1).toSet();

    final sid = _resolveStoreId(storeId);
    final Set<int> preferredIds = <int>{};
    if (supplierName != null && supplierName.trim().isNotEmpty) {
      preferredIds.addAll(_multiAliases[_buildKey(supplierName, rawName, storeId: sid)] ?? const <int>[]);
    }
    preferredIds.addAll(_multiAliases['s$sid::global::$cleanInput'] ?? const <int>[]);

    final List<MatchCandidate> scoredList = [];

    for (var prod in catalog) {
      if (preferredIds.contains(prod.id)) {
        scoredList.add(MatchCandidate(product: prod, score: 0.98));
        continue;
      }

      final cleanTarget = _normalizeText(prod.name);
      final targetTokens = cleanTarget.split(' ').where((t) => t.length > 1).toSet();

      if (inputTokens.isEmpty || targetTokens.isEmpty) continue;

      final intersection = inputTokens.intersection(targetTokens).length;
      final union = inputTokens.union(targetTokens).length;
      double score = union > 0 ? (intersection / union) : 0.0;

      // Бонус если все слова из короткого названия накладной (например "сок добрий") входят в название товара базы ("сок добрый яблочный")
      if (inputTokens.length >= 2 && intersection == inputTokens.length) {
        score = (score + 0.2).clamp(0.0, 0.84);
      }

      // Бонус за точное вхождение подстроки дается только если короткая строка составляет не менее 65% длины длинной
      if (cleanTarget.length >= 8 && cleanInput.length >= 8) {
        if (cleanTarget.contains(cleanInput) || cleanInput.contains(cleanTarget)) {
          final shorter = cleanTarget.length < cleanInput.length ? cleanTarget.length : cleanInput.length;
          final longer = cleanTarget.length > cleanInput.length ? cleanTarget.length : cleanInput.length;
          if (shorter / longer >= 0.65) {
            score = (score + 0.3).clamp(0.0, 1.0);
          }
        }
      }

      if (score > 0.25) {
        scoredList.add(MatchCandidate(product: prod, score: score));
      }
    }

    scoredList.sort((a, b) => b.score.compareTo(a.score));
    return scoredList.take(limit).toList();
  }

  String _normalizeText(String text) => normalizeProductNameForMatch(text);
}
