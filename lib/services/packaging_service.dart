import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';

class PackagingService {
  static final PackagingService _instance = PackagingService._internal();
  factory PackagingService() => _instance;
  PackagingService._internal();

  Map<String, double> _packagingMemory = {};
  bool _isLoaded = false;

  Future<void> init() async {
    if (_isLoaded) return;
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString('packaging_units_memory');
      if (raw != null) {
        final decoded = jsonDecode(raw) as Map<String, dynamic>;
        _packagingMemory = decoded.map((k, v) => MapEntry(k, (v as num).toDouble()));
      }
    } catch (_) {}
    _isLoaded = true;
  }

  // Получение запомненного количества штук в упаковке по штрихкоду или названию
  Future<double?> getUnitsPerPackage({String? barcode, String? name}) async {
    await init();
    if (barcode != null && barcode.trim().isNotEmpty) {
      final cleanBarcode = barcode.trim();
      if (_packagingMemory.containsKey('bc:$cleanBarcode')) {
        return _packagingMemory['bc:$cleanBarcode'];
      }
    }

    if (name != null && name.trim().isNotEmpty) {
      final cleanName = _normalizeName(name);
      if (_packagingMemory.containsKey('name:$cleanName')) {
        return _packagingMemory['name:$cleanName'];
      }
    }

    // Если нет в памяти, пробуем автодетект из названия
    if (name != null) {
      return detectUnitsFromText(name);
    }
    return null;
  }

  // Запоминание фасовки для товара навсегда
  Future<void> saveUnitsPerPackage({String? barcode, String? name, required double units}) async {
    if (units <= 1) return;
    await init();

    if (barcode != null && barcode.trim().isNotEmpty) {
      _packagingMemory['bc:${barcode.trim()}'] = units;
    }
    if (name != null && name.trim().isNotEmpty) {
      _packagingMemory['name:${_normalizeName(name)}'] = units;
    }

    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('packaging_units_memory', jsonEncode(_packagingMemory));
    } catch (_) {}
  }

  // Умный поиск числа штук в названии товара (например: "24 шт", "10 пач", "12 кор", "20 бан", "10x", "12*")
  static double? detectUnitsFromText(String text) {
    final lower = text.toLowerCase().trim();

    // 1. Паттерны вида: "24 шт", "24шт", "10 пач", "12 кор", "20 бан", "12 бут", "10 бл"
    final m1 = RegExp(r'(\d+)\s*(?:шт|пач|кор|бан|бут|бл|уп|пк|штук|пачек|пачки|коробок)\b').firstMatch(lower);
    if (m1 != null) {
      final val = double.tryParse(m1.group(1)!);
      if (val != null && val > 1 && val <= 1000) return val;
    }

    // 2. Паттерны вида: "24x", "12х", "10*" (например "Oreo 24x38g")
    final m2 = RegExp(r'\b(\d+)\s*[xх*×]').firstMatch(lower);
    if (m2 != null) {
      final val = double.tryParse(m2.group(1)!);
      if (val != null && val > 1 && val <= 500) return val;
    }

    // 3. Паттерны вида: "х12", "x24"
    final m3 = RegExp(r'[xх*×]\s*(\d+)\b').firstMatch(lower);
    if (m3 != null) {
      final val = double.tryParse(m3.group(1)!);
      if (val != null && val > 1 && val <= 500) return val;
    }

    // 4. Паттерны вида: "(24)", "/24"
    final m4 = RegExp(r'[\(/]\s*(\d+)\s*(?:шт)?\s*[\)]').firstMatch(lower);
    if (m4 != null) {
      final val = double.tryParse(m4.group(1)!);
      if (val != null && val > 1 && val <= 500) return val;
    }

    return null;
  }

  String _normalizeName(String name) {
    return name
        .toLowerCase()
        .replaceAll(RegExp(r'[^\w\sа-яёқғӣҳҷў]'), '')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
  }
}
