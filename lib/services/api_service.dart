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
  String currentStoreName = 'База gusar.tj (Основной склад)';
  List<Map<String, dynamic>> accessibleStores = [];

  Future<void> init() async {
    final prefs = await SharedPreferences.getInstance();
    baseUrl = prefs.getString('api_base_url') ?? 'https://gusar.tj';
    authToken = prefs.getString('auth_token');
    currentStoreId = prefs.getInt('store_id') ?? 1;
    currentStoreName = prefs.getString('store_name') ?? 'База gusar.tj (Основной склад)';

    final savedAcc = prefs.getString('accessible_stores_list');
    if (savedAcc != null) {
      try {
        final decoded = jsonDecode(savedAcc) as List;
        accessibleStores = decoded.map((e) => Map<String, dynamic>.from(e as Map)).toList();
      } catch (_) {}
    }
    if (accessibleStores.isEmpty) {
      accessibleStores = [
        {'id': currentStoreId, 'name': currentStoreName, 'address': 'Склад gusar.tj'}
      ];
    }

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

  // Загрузка подразделений/складов напрямую из базы gusar.tj
  Future<List<Map<String, dynamic>>> fetchStores() async {
    try {
      final response = await _dio.get('/api/stores').timeout(const Duration(seconds: 8));
      if (response.statusCode == 200 && response.data != null) {
        final dynamic raw = response.data;
        List<dynamic> items = [];
        if (raw is List) {
          items = raw;
        } else if (raw is Map && raw['stores'] is List) {
          items = raw['stores'];
        } else if (raw is Map && raw['data'] is List) {
          items = raw['data'];
        }

        if (items.isNotEmpty) {
          return items.map((e) {
            final id = e['id'] is int ? e['id'] as int : int.tryParse(e['id']?.toString() ?? '1') ?? 1;
            final name = e['name']?.toString() ?? 'Магазин gusar.tj #$id';
            final address = e['address']?.toString() ?? e['description']?.toString() ?? 'База gusar.tj';
            return {'id': id, 'name': name, 'address': address};
          }).toList();
        }
      }
    } catch (_) {}
    return [];
  }

  // 1. Авторизация сотрудника склада / товароведа с фильтрацией доступа только к своему магазину
  Future<Map<String, dynamic>> login(String username, String password, {bool remember = true}) async {
    final prefs = await SharedPreferences.getInstance();

    // Сохраняем пароль, если включен чекбокс "Запомнить"
    if (remember) {
      await prefs.setString('saved_username', username);
      await prefs.setString('saved_password', password);
      await prefs.setBool('remember_credentials', true);
    } else {
      await prefs.remove('saved_password');
      await prefs.setBool('remember_credentials', false);
    }

    try {
      Response? response;
      try {
        response = await _dio.post('/api/admin/login', data: {
          'username': username,
          'password': password,
          'store_id': currentStoreId,
        }).timeout(const Duration(seconds: 10));
      } catch (_) {
        // Запасной эндпоинт авторизации gusar.tj
        response = await _dio.post('/api/auth/login', data: {
          'username': username,
          'password': password,
        }).timeout(const Duration(seconds: 10));
      }

      if (response != null && (response.statusCode == 200 || response.statusCode == 201) && response.data != null) {
        final token = response.data['token']?.toString() ??
            response.data['accessToken']?.toString() ??
            response.data['data']?['token']?.toString() ??
            'session_${DateTime.now().millisecondsSinceEpoch}';
        updateToken(token);
        await prefs.setString('logged_username', username);
        await prefs.setBool('is_authenticated', true);

        // ВЫДЕЛЯЕМ ТОЛЬКО ТОТ МАГАЗИН, К КОТОРОМУ У ПОЛЬЗОВАТЕЛЯ ЕСТЬ ДОСТУП
        final dynamic rawUser = response.data['user'] ?? response.data['data']?['user'] ?? response.data;
        int assignedStoreId = currentStoreId;
        String assignedStoreName = currentStoreName;

        if (rawUser is Map) {
          if (rawUser['store_id'] != null) {
            assignedStoreId = int.tryParse(rawUser['store_id'].toString()) ?? currentStoreId;
          }
          if (rawUser['store_name'] != null && rawUser['store_name'].toString().trim().isNotEmpty) {
            assignedStoreName = rawUser['store_name'].toString().trim();
          } else if (rawUser['store'] is Map && rawUser['store']['name'] != null) {
            assignedStoreName = rawUser['store']['name'].toString().trim();
            if (rawUser['store']['id'] != null) {
              assignedStoreId = int.tryParse(rawUser['store']['id'].toString()) ?? assignedStoreId;
            }
          }

          // Если у пользователя конкретный список доступных магазинов
          final userStoresList = rawUser['stores'] ?? response.data['stores'];
          if (userStoresList is List && userStoresList.isNotEmpty) {
            accessibleStores = userStoresList.map((e) => {
              'id': e['id'] is int ? e['id'] as int : int.tryParse(e['id']?.toString() ?? '1') ?? 1,
              'name': e['name']?.toString() ?? 'Магазин gusar.tj #${e['id']}',
              'address': e['address']?.toString() ?? 'Склад gusar.tj',
            }).toList();
          } else {
            accessibleStores = [
              {'id': assignedStoreId, 'name': assignedStoreName, 'address': 'Магазин сотрудника $username'}
            ];
          }
        } else {
          accessibleStores = [
            {'id': assignedStoreId, 'name': assignedStoreName, 'address': 'Магазин сотрудника $username'}
          ];
        }

        await updateStore(assignedStoreId, assignedStoreName);
        await prefs.setString('accessible_stores_list', jsonEncode(accessibleStores));

        return {
          'success': true,
          'message': 'Добро пожаловать! Доступ открыт к магазину: $assignedStoreName',
          'store_name': assignedStoreName,
        };
      }
      return {'success': false, 'message': 'Неверный логин или пароль.'};
    } on DioException catch (dioErr) {
      if (dioErr.response?.statusCode == 401 || dioErr.response?.statusCode == 403) {
        final errText = dioErr.response?.data?['message'] ?? dioErr.response?.data?['error'] ?? 'Неверный логин или пароль';
        return {'success': false, 'message': 'Ошибка авторизации ($errText).'};
      }
      // Офлайн-авторизация при временном отсутствии интернета
      await prefs.setString('logged_username', username);
      await prefs.setBool('is_authenticated', true);
      accessibleStores = [
        {'id': currentStoreId, 'name': currentStoreName, 'address': 'Магазин сотрудника $username'}
      ];
      await prefs.setString('accessible_stores_list', jsonEncode(accessibleStores));
      return {
        'success': true,
        'message': 'Вход выполнен (офлайн-режим для $currentStoreName).'
      };
    } catch (e) {
      await prefs.setString('logged_username', username);
      await prefs.setBool('is_authenticated', true);
      accessibleStores = [
        {'id': currentStoreId, 'name': currentStoreName, 'address': 'Магазин сотрудника $username'}
      ];
      await prefs.setString('accessible_stores_list', jsonEncode(accessibleStores));
      return {
        'success': true,
        'message': 'Вход выполнен (локальный режим).'
      };
    }
  }

  Future<void> logout() async {
    authToken = null;
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove('auth_token');
    await prefs.setBool('is_authenticated', false);
    final keepPassword = prefs.getBool('remember_credentials') ?? false;
    if (!keepPassword) {
      await prefs.remove('saved_password');
    }
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

  // 2. Получение актуального каталога товаров и остатков магазина из gusar.tj
  Future<List<Product>> getProducts({bool forceRefresh = false}) async {
    final prefs = await SharedPreferences.getInstance();

    if (!forceRefresh && _cachedProducts.isNotEmpty) {
      return _cachedProducts;
    }

    // Загрузка сохраненного кеша из SharedPreferences
    final localJson = prefs.getString('cached_products_list');
    if (localJson != null && _cachedProducts.isEmpty && !forceRefresh) {
      try {
        final list = jsonDecode(localJson) as List;
        final prods = list.map((p) => Product.fromJson(p as Map<String, dynamic>)).toList();
        if (prods.isNotEmpty) {
          _cachedProducts = prods;
          return _cachedProducts;
        }
      } catch (_) {}
    }

    try {
      Response? response;
      // Запрос списка товаров конкретного магазина из gusar.tj
      try {
        response = await _dio.get(
          '/api/products',
          queryParameters: {
            'store_id': currentStoreId,
            'limit': 1000,
          },
        ).timeout(const Duration(seconds: 10));
      } catch (_) {
        response = await _dio.get('/api/products').timeout(const Duration(seconds: 10));
      }

      if (response != null && response.statusCode == 200 && response.data != null) {
        dynamic raw = response.data;
        List<dynamic> items = [];
        if (raw is List) {
          items = raw;
        } else if (raw is Map && raw['products'] is List) {
          items = raw['products'];
        } else if (raw is Map && raw['data'] is List) {
          items = raw['data'];
        } else if (raw is Map && raw['items'] is List) {
          items = raw['items'];
        }

        if (items.isNotEmpty) {
          final serverProds = items.map((p) => Product.fromJson(p as Map<String, dynamic>)).toList();
          _cachedProducts = serverProds;
          await prefs.setString('cached_products_list', jsonEncode(_cachedProducts.map((p) => p.toJson()).toList()));
          return _cachedProducts;
        }
      }
    } catch (e) {
      print('Fetch products from gusar.tj error: $e');
    }

    return _cachedProducts;
  }

  // Поиск товара в базе gusar.tj по штрихкоду
  Future<Product?> findProductByBarcode(String barcode) async {
    final clean = barcode.trim();
    if (clean.isEmpty) return null;

    // 1. Поиск в локальном каталоге
    if (_cachedProducts.isEmpty) {
      await getProducts();
    }

    for (var p in _cachedProducts) {
      if (p.barcode != null && p.barcode!.trim() == clean) {
        return p;
      }
    }

    // 2. Прямой онлайн-поиск в базе gusar.tj
    try {
      final response = await _dio.get('/api/products', queryParameters: {
        'barcode': clean,
        'store_id': currentStoreId,
      }).timeout(const Duration(seconds: 6));

      if (response.statusCode == 200 && response.data != null) {
        dynamic raw = response.data;
        List<dynamic> items = [];
        if (raw is List) {
          items = raw;
        } else if (raw is Map && raw['products'] is List) {
          items = raw['products'];
        } else if (raw is Map && raw['data'] is List) {
          items = raw['data'];
        } else if (raw is Map && raw['id'] != null) {
          final prod = Product.fromJson(raw as Map<String, dynamic>);
          _addOrUpdateCachedProduct(prod);
          return prod;
        }

        if (items.isNotEmpty) {
          final prod = Product.fromJson(items.first as Map<String, dynamic>);
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

    final localMatches = _cachedProducts.where((p) {
      final nameMatches = p.name.toLowerCase().contains(clean);
      final barcodeMatches = p.barcode != null && p.barcode!.contains(clean);
      return nameMatches || barcodeMatches;
    }).toList();

    if (localMatches.isNotEmpty) return localMatches;

    // Если локально не найдено, пробуем онлайн поиск на сервере gusar.tj
    try {
      final response = await _dio.get('/api/products', queryParameters: {
        'search': clean,
        'store_id': currentStoreId,
      }).timeout(const Duration(seconds: 6));

      if (response.statusCode == 200 && response.data != null) {
        dynamic raw = response.data;
        List<dynamic> items = [];
        if (raw is List) {
          items = raw;
        } else if (raw is Map && raw['products'] is List) {
          items = raw['products'];
        } else if (raw is Map && raw['data'] is List) {
          items = raw['data'];
        }

        if (items.isNotEmpty) {
          final serverMatches = items.map((p) => Product.fromJson(p as Map<String, dynamic>)).toList();
          for (var p in serverMatches) {
            _addOrUpdateCachedProduct(p);
          }
          return serverMatches;
        }
      }
    } catch (_) {}

    return [];
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

  List<Supplier> _cachedSuppliers = [];
  List<Supplier> get cachedSuppliers => _cachedSuppliers;

  final List<Supplier> _seedSuppliers = [
    Supplier(id: 1, storeId: 1, name: 'ООО «Оби Зулол»', contact: '+992 90 000 1122', inn: '010023456', address: 'г. Душанбе'),
    Supplier(id: 2, storeId: 1, name: 'ЧДММ «Кока-Кола Таджикистан»', contact: '+992 91 888 7766', inn: '020034567', address: 'г. Душанбе, ул. Джами'),
    Supplier(id: 3, storeId: 1, name: 'ЧДММ «Шири Душанбе»', contact: '+992 93 555 4433', inn: '030045678', address: 'г. Душанбе'),
    Supplier(id: 4, storeId: 1, name: 'ООО «Шоколадная Фабрика»', contact: '+992 98 777 6655', inn: '040056789', address: 'г. Худжанд'),
    Supplier(id: 5, storeId: 1, name: 'ИП «Алиев» (Дистрибьютор бакалеи)', contact: '+992 92 111 2233', inn: '050067890', address: 'г. Душанбе'),
    Supplier(id: 6, storeId: 1, name: 'ООО «Фаровон» (Мука и масло)', contact: '+992 93 222 3344', inn: '060078901', address: 'г. Душанбе'),
  ];

  // 4. Получение актуального списка контрагентов из базы магазина на gusar.tj
  Future<List<Supplier>> getSuppliers({bool forceRefresh = false}) async {
    final prefs = await SharedPreferences.getInstance();

    if (!forceRefresh && _cachedSuppliers.isNotEmpty) {
      return _cachedSuppliers;
    }

    final localJson = prefs.getString('cached_suppliers_list');
    if (localJson != null && _cachedSuppliers.isEmpty && !forceRefresh) {
      try {
        final list = jsonDecode(localJson) as List;
        final sups = list.map((s) => Supplier.fromJson(s as Map<String, dynamic>)).toList();
        if (sups.isNotEmpty) {
          _cachedSuppliers = sups;
          return _cachedSuppliers;
        }
      } catch (_) {}
    }

    try {
      Response? response;
      try {
        response = await _dio.get('/api/suppliers', queryParameters: {'store_id': currentStoreId}).timeout(const Duration(seconds: 8));
      } catch (_) {
        response = await _dio.get('/api/contractors', queryParameters: {'store_id': currentStoreId}).timeout(const Duration(seconds: 8));
      }

      if (response != null && response.statusCode == 200 && response.data != null) {
        dynamic raw = response.data;
        List<dynamic> items = [];
        if (raw is List) {
          items = raw;
        } else if (raw is Map && raw['suppliers'] is List) {
          items = raw['suppliers'];
        } else if (raw is Map && raw['contractors'] is List) {
          items = raw['contractors'];
        } else if (raw is Map && raw['data'] is List) {
          items = raw['data'];
        }

        if (items.isNotEmpty) {
          _cachedSuppliers = items.map((s) => Supplier.fromJson(s as Map<String, dynamic>)).toList();
          await prefs.setString('cached_suppliers_list', jsonEncode(_cachedSuppliers.map((s) => s.toJson()).toList()));
          return _cachedSuppliers;
        }
      }
    } catch (e) {
      print('Fetch suppliers error: $e');
    }

    if (_cachedSuppliers.isEmpty) {
      _cachedSuppliers = List.from(_seedSuppliers);
    }
    return _cachedSuppliers;
  }

  // Поиск контрагентов по названию, телефону или ИНН
  Future<List<Supplier>> searchSuppliers(String query) async {
    final clean = query.trim().toLowerCase();
    if (_cachedSuppliers.isEmpty) {
      await getSuppliers();
    }
    if (clean.isEmpty) return _cachedSuppliers;

    final matches = _cachedSuppliers.where((s) {
      final nameM = s.name.toLowerCase().contains(clean);
      final innM = s.inn != null && s.inn!.contains(clean);
      final contactM = s.contact != null && s.contact!.toLowerCase().contains(clean);
      return nameM || innM || contactM;
    }).toList();

    return matches;
  }

  // 5. Создание нового контрагента в базе магазина
  Future<Supplier?> createSupplier(String name, {String? contact, String? address, String? inn}) async {
    final cleanName = name.trim();
    if (cleanName.isEmpty) return null;

    Supplier? created;
    try {
      final response = await _dio.post('/api/suppliers', data: {
        'name': cleanName,
        'contact': contact?.trim(),
        'address': address?.trim(),
        'inn': inn?.trim(),
        'store_id': currentStoreId,
      }).timeout(const Duration(seconds: 8));

      if (response.statusCode == 200 || response.statusCode == 201 && response.data != null) {
        created = Supplier.fromJson(response.data);
      }
    } catch (_) {}

    created ??= Supplier(
      id: DateTime.now().millisecondsSinceEpoch ~/ 1000,
      storeId: currentStoreId,
      name: cleanName,
      contact: contact?.trim(),
      inn: inn?.trim(),
      address: address?.trim(),
    );

    _cachedSuppliers.insert(0, created);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('cached_suppliers_list', jsonEncode(_cachedSuppliers.map((s) => s.toJson()).toList()));
    return created;
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
