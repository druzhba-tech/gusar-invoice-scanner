import 'dart:convert';
import 'package:dio/dio.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/product.dart';
import '../models/supplier.dart';
import '../models/invoice_document.dart';
import '../models/invoice_item.dart';

class ApiService {
  static final ApiService _instance = ApiService._internal();
  factory ApiService() => _instance;
  ApiService._internal();

  late Dio _dio;
  String baseUrl = 'https://gusar.tj';
  String? authToken;
  int currentStoreId = 1;
  String currentStoreName = 'Магазин Gusar #1 (Центральный)';

  Future<void> init() async {
    final prefs = await SharedPreferences.getInstance();
    baseUrl = prefs.getString('api_base_url') ?? 'https://gusar.tj';
    authToken = prefs.getString('auth_token');
    currentStoreId = prefs.getInt('store_id') ?? 1;
    currentStoreName = prefs.getString('store_name') ?? 'Магазин Gusar #1 (Центральный)';

    _dio = Dio(
      BaseOptions(
        baseUrl: baseUrl,
        connectTimeout: const Duration(seconds: 15),
        receiveTimeout: const Duration(seconds: 20),
        headers: {
          'Content-Type': 'application/json',
          'Accept': 'application/json',
          if (authToken != null) 'Authorization': 'Bearer $authToken',
        },
      ),
    );
  }

  void updateToken(String token) async {
    authToken = token;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('auth_token', token);
    _dio.options.headers['Authorization'] = 'Bearer $token';
  }

  void updateBaseUrl(String url) async {
    baseUrl = url;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('api_base_url', url);
    _dio.options.baseUrl = url;
  }

  Future<void> updateStore(int id, String name) async {
    currentStoreId = id;
    currentStoreName = name;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt('store_id', id);
    await prefs.setString('store_name', name);
  }

  void updateStoreId(int id) async {
    currentStoreId = id;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt('store_id', id);
  }

  // 1. Авторизация сотрудника склада / товароведа для выбранного магазина
  Future<Map<String, dynamic>> login(String username, String password) async {
    try {
      final response = await _dio.post('/api/admin/login', data: {
        'username': username,
        'password': password,
        'store_id': currentStoreId,
      }).timeout(const Duration(seconds: 12));

      if (response.statusCode == 200 && response.data != null) {
        final token = response.data['token']?.toString() ?? 'session_${DateTime.now().millisecondsSinceEpoch}';
        updateToken(token);
        final prefs = await SharedPreferences.getInstance();
        await prefs.setString('logged_username', username);
        await prefs.setBool('is_authenticated', true);
        return {'success': true, 'message': 'Успешная авторизация в системе gusar.tj!'};
      }
      return {'success': false, 'message': 'Неверный логин или пароль.'};
    } on DioException catch (dioErr) {
      if (dioErr.response?.statusCode == 401 || dioErr.response?.statusCode == 403) {
        return {'success': false, 'message': 'Ошибка 401: Неверный логин или пароль сотрудника.'};
      }
      // Офлайн-авторизация при недоступности внешнего API
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('logged_username', username);
      await prefs.setBool('is_authenticated', true);
      return {
        'success': true,
        'message': 'Локальная сессия активирована для $currentStoreName (офлайн-режим).'
      };
    } catch (e) {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('logged_username', username);
      await prefs.setBool('is_authenticated', true);
      return {
        'success': true,
        'message': 'Вход выполнен локально (офлайн-режим).'
      };
    }
  }

  Future<void> logout() async {
    authToken = null;
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove('auth_token');
    await prefs.remove('logged_username');
    await prefs.setBool('is_authenticated', false);
    _dio.options.headers.remove('Authorization');
  }

  List<Product> _cachedProducts = [];
  List<Product> get cachedProducts => _cachedProducts;

  // Базовый стартовый каталог магазина для мгновенного отклика и офлайн-работы
  final List<Product> _seedProducts = [
    Product(id: 101, storeId: 1, name: 'Coca-Cola 0.5л', barcode: '5449000000996', price: 6.50, costPrice: 4.80, stockQuantity: 120),
    Product(id: 102, storeId: 1, name: 'Батончик Snickers Super 80г', barcode: '5000159461122', price: 9.00, costPrice: 6.90, stockQuantity: 85),
    Product(id: 103, storeId: 1, name: 'Масло растительное Олейна 1л', barcode: '4607065520015', price: 21.00, costPrice: 17.50, stockQuantity: 60),
    Product(id: 104, storeId: 1, name: 'Мука 1 сорт 50кг (Казахстан)', barcode: '4820000112233', price: 285.00, costPrice: 260.00, stockQuantity: 40),
    Product(id: 105, storeId: 1, name: 'Сахар песок белый 1кг', barcode: '4820000223344', price: 11.50, costPrice: 9.80, stockQuantity: 200),
    Product(id: 106, storeId: 1, name: 'Чай черный листовой 100г', barcode: '4780012345678', price: 14.00, costPrice: 10.50, stockQuantity: 75),
    Product(id: 107, storeId: 1, name: 'Молоко пастеризованное 1л', barcode: '4820000334455', price: 9.50, costPrice: 7.80, stockQuantity: 50),
    Product(id: 108, storeId: 1, name: 'Вода минеральная Сиёма 0.5л', barcode: '4820000445566', price: 3.50, costPrice: 2.20, stockQuantity: 300),
    Product(id: 109, storeId: 1, name: 'Печенье Юбилейное традиционное 112г', barcode: '4600648000012', price: 5.50, costPrice: 4.00, stockQuantity: 90),
    Product(id: 110, storeId: 1, name: 'Шоколад Алёнка молочный 100г', barcode: '4600605001234', price: 12.00, costPrice: 9.20, stockQuantity: 65),
  ];

  // 2. Получение актуального каталога товаров и остатков магазина
  Future<List<Product>> getProducts({bool forceRefresh = false}) async {
    if (!forceRefresh && _cachedProducts.isNotEmpty) {
      return _cachedProducts;
    }

    // Загрузка сохраненного кеша из SharedPreferences
    final prefs = await SharedPreferences.getInstance();
    final localJson = prefs.getString('cached_products_list');
    if (localJson != null && _cachedProducts.isEmpty) {
      try {
        final list = jsonDecode(localJson) as List;
        _cachedProducts = list.map((p) => Product.fromJson(p)).toList();
      } catch (_) {}
    }

    try {
      final response = await _dio.get('/api/products').timeout(const Duration(seconds: 8));
      if (response.statusCode == 200 && response.data is List) {
        final serverProds = (response.data as List).map((p) => Product.fromJson(p)).toList();
        if (serverProds.isNotEmpty) {
          _cachedProducts = serverProds;
          await prefs.setString('cached_products_list', jsonEncode(_cachedProducts.map((p) => p.toJson()).toList()));
          return _cachedProducts;
        }
      }
    } catch (e) {
      print('Fetch products from gusar.tj error (using offline cache): $e');
    }

    if (_cachedProducts.isEmpty) {
      _cachedProducts = List.from(_seedProducts);
      await prefs.setString('cached_products_list', jsonEncode(_cachedProducts.map((p) => p.toJson()).toList()));
    }
    return _cachedProducts;
  }

  // Поиск товара в базе gusar.tj по штрихкоду
  Future<Product?> findProductByBarcode(String barcode) async {
    final clean = barcode.trim();
    if (clean.isEmpty) return null;

    // 1. Поиск в памяти
    if (_cachedProducts.isEmpty) {
      await getProducts();
    }

    for (var p in _cachedProducts) {
      if (p.barcode != null && p.barcode!.trim() == clean) {
        return p;
      }
    }

    // 2. Поиск через прямой запрос на сайт gusar.tj
    try {
      final response = await _dio.get('/api/products', queryParameters: {'barcode': clean}).timeout(const Duration(seconds: 5));
      if (response.statusCode == 200) {
        if (response.data is List && (response.data as List).isNotEmpty) {
          final prod = Product.fromJson((response.data as List).first);
          _addOrUpdateCachedProduct(prod);
          return prod;
        } else if (response.data is Map<String, dynamic> && response.data['id'] != null) {
          final prod = Product.fromJson(response.data);
          _addOrUpdateCachedProduct(prod);
          return prod;
        }
      }
    } catch (_) {}

    return null;
  }

  // Поиск товаров по названию или штрихкоду
  Future<List<Product>> searchProducts(String query) async {
    final clean = query.trim().toLowerCase();
    if (_cachedProducts.isEmpty) {
      await getProducts();
    }
    if (clean.isEmpty) return _cachedProducts;

    return _cachedProducts.where((p) {
      final nameMatches = p.name.toLowerCase().contains(clean);
      final barcodeMatches = p.barcode != null && p.barcode!.contains(clean);
      return nameMatches || barcodeMatches;
    }).toList();
  }

  void _addOrUpdateCachedProduct(Product prod) async {
    final idx = _cachedProducts.indexWhere((p) => p.id == prod.id || (p.barcode != null && p.barcode == prod.barcode));
    if (idx >= 0) {
      _cachedProducts[idx] = prod;
    } else {
      _cachedProducts.add(prod);
    }
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('cached_products_list', jsonEncode(_cachedProducts.map((p) => p.toJson()).toList()));
  }

  // 3. Создание нового товара прямо из приёмки за 1 клик
  Future<Product?> createProduct({
    required String name,
    required String barcode,
    required double price,
    required double costPrice,
    int? categoryId,
  }) async {
    final cleanBarcode = barcode.trim();
    Product? created;

    try {
      final response = await _dio.post('/api/products', data: {
        'name': name.trim(),
        'barcode': cleanBarcode,
        'price': price,
        'cost_price': costPrice,
        'category_id': categoryId,
        'store_id': currentStoreId,
        'stock_quantity': 0,
      }).timeout(const Duration(seconds: 8));

      if (response.statusCode == 200 || response.statusCode == 201) {
        created = Product.fromJson(response.data);
      }
    } catch (e) {
      print('Create product on gusar.tj server error (creating local fallback): $e');
    }

    // Если сервер недоступен или вернул ошибку, создаем локально в базе приложения
    created ??= Product(
      id: DateTime.now().millisecondsSinceEpoch ~/ 1000,
      storeId: currentStoreId,
      name: name.trim(),
      barcode: cleanBarcode,
      price: price > 0 ? price : (costPrice * 1.25),
      costPrice: costPrice,
      stockQuantity: 0,
    );

    _addOrUpdateCachedProduct(created);
    return created;
  }

  // 4. Получение списка поставщиков
  Future<List<Supplier>> getSuppliers() async {
    try {
      final response = await _dio.get('/api/suppliers');
      if (response.statusCode == 200 && response.data is List) {
        return (response.data as List).map((s) => Supplier.fromJson(s)).toList();
      }
      return [];
    } catch (e) {
      print('Fetch suppliers error: $e');
      return [];
    }
  }

  // 5. Создание нового поставщика
  Future<Supplier?> createSupplier(String name, {String? contact, String? address}) async {
    try {
      final response = await _dio.post('/api/suppliers', data: {
        'name': name,
        'contact': contact,
        'address': address,
        'store_id': currentStoreId,
      });

      if (response.statusCode == 200 || response.statusCode == 201) {
        return Supplier.fromJson(response.data);
      }
      return null;
    } catch (e) {
      print('Create supplier error: $e');
      return null;
    }
  }

  // 6. Проверка на дубликат накладной
  Future<bool> checkInvoiceExists(String invoiceNumber, int? supplierId) async {
    try {
      final response = await _dio.get('/api/purchases');
      if (response.statusCode == 200 && response.data is List) {
        for (var p in response.data) {
          if (p['notes'] != null && p['notes'].toString().contains(invoiceNumber)) {
            return true;
          }
        }
      }
      return false;
    } catch (e) {
      return false;
    }
  }

  // 7. Отправка приходной накладной и прямое зачисление в остатки
  Future<bool> submitPurchase(InvoiceDocument document) async {
    try {
      final purchasePayload = {
        'store_id': currentStoreId,
        'supplier_id': document.supplierId,
        'total_amount': document.totalAmount > 0 ? document.totalAmount : document.calculatedTotal,
        'paid_amount': document.paidAmount,
        'notes': 'Накладная №${document.invoiceNumber} от ${document.invoiceDate.toIso8601String().substring(0, 10)} (Поставщик: ${document.supplierName})',
        'items': document.items.map((item) {
          return {
            'product_id': item.matchedProductId,
            'quantity': (item.verifiedQuantity > 0 ? item.verifiedQuantity : item.quantity).toInt(),
            'buy_price': item.buyPrice,
          };
        }).toList(),
      };

      final response = await _dio.post('/api/purchases', data: purchasePayload);

      return response.statusCode == 200 || response.statusCode == 201;
    } catch (e) {
      print('Submit purchase error: $e');
      return false;
    }
  }
}
