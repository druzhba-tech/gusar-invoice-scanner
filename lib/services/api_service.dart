import 'dart:convert';
import 'dart:io';
import 'package:dio/dio.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/product.dart';
import '../models/supplier.dart';
import '../models/invoice_document.dart';
import '../models/invoice_item.dart';
import '../utils/image_utils.dart';

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
          'X-Store-ID': currentStoreId.toString(),
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
    _dio.options.headers['X-Store-ID'] = currentStoreId.toString();
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
    _cachedProducts = []; // ВАЖНО: очищаем память от товаров старого магазина!
    _cachedSuppliers = []; // ВАЖНО: очищаем память от контрагентов старого магазина!
    _dio.options.headers['X-Store-ID'] = id.toString();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt('store_id', id);
    await prefs.setString('store_name', name);
    await prefs.remove('cached_products_list'); // Очищаем кэш старого магазина
    await prefs.remove('cached_suppliers_list'); // Очищаем кэш контрагентов старого магазина
  }

  void updateStoreId(int id) async {
    currentStoreId = id;
    _cachedProducts = [];
    _cachedSuppliers = [];
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt('store_id', id);
    await prefs.remove('cached_products_list');
    await prefs.remove('cached_suppliers_list');
  }

  // Загрузка подразделений/складов напрямую из базы gusar.tj (публичный + супер-админский эндпоинты)
  Future<List<Map<String, dynamic>>> fetchStores() async {
    try {
      Response? response;
      // 1. Сначала запрашиваем публичный каталог всех магазинов (всегда открыт, не требует прав суперадмина)
      try {
        response = await _dio.get('/api/public-stores').timeout(const Duration(seconds: 6));
      } catch (_) {
        // 2. Если публичный эндпоинт недоступен, пробуем админский эндпоинт
        response = await _dio.get('/api/stores').timeout(const Duration(seconds: 6));
      }

      if (response != null && response.statusCode == 200 && response.data != null) {
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
          final list = items.map((e) {
            final id = e['id'] is int ? e['id'] as int : int.tryParse(e['id']?.toString() ?? '1') ?? 1;
            final name = e['name']?.toString() ?? 'Магазин gusar.tj #$id';
            final address = e['address']?.toString() ?? e['description']?.toString() ?? 'База gusar.tj';
            final subdomain = e['subdomain']?.toString() ?? '';
            return {'id': id, 'name': name, 'address': address, 'subdomain': subdomain};
          }).toList();
          return list;
        }
      }
    } catch (e) {
      print('fetchStores warning: $e');
    }
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

        // 1. Сначала подгружаем актуальный список всех магазинов базы gusar.tj
        final allStores = await fetchStores();

        // 2. Извлекаем точный store_id пользователя из ответа логина
        int? userStoreId;
        String? userStoreName;
        String? userRole = response.data['role']?.toString().toUpperCase();

        if (response.data['store_id'] != null) {
          userStoreId = int.tryParse(response.data['store_id'].toString());
        }

        final dynamic rawUser = response.data['user'] ?? response.data['data']?['user'];
        if (rawUser is Map) {
          if (rawUser['store_id'] != null) {
            userStoreId = int.tryParse(rawUser['store_id'].toString());
          }
          if (rawUser['store_name'] != null && rawUser['store_name'].toString().trim().isNotEmpty) {
            userStoreName = rawUser['store_name'].toString().trim();
          } else if (rawUser['store'] is Map) {
            if (rawUser['store']['name'] != null) {
              userStoreName = rawUser['store']['name'].toString().trim();
            }
            if (rawUser['store']['id'] != null) {
              userStoreId = int.tryParse(rawUser['store']['id'].toString());
            }
          }
          if (rawUser['role'] != null) {
            userRole = rawUser['role'].toString().toUpperCase();
          }
        }

        // 3. Запрашиваем точный профиль сотрудника из gusar.tj (/api/admin/me или /api/auth/me)
        try {
          Response? meResp;
          try {
            meResp = await _dio.get('/api/admin/me').timeout(const Duration(seconds: 4));
          } catch (_) {
            meResp = await _dio.get('/api/auth/me').timeout(const Duration(seconds: 4));
          }
          if (meResp != null && meResp.statusCode == 200 && meResp.data != null) {
            final meData = meResp.data;
            if (meData['store_id'] != null) {
              userStoreId = int.tryParse(meData['store_id'].toString()) ?? userStoreId;
            }
            if (meData['role'] != null) {
              userRole = meData['role'].toString().toUpperCase();
            }
            final meUser = meData['user'] ?? meData['data'];
            if (meUser is Map) {
              if (meUser['store_id'] != null) {
                userStoreId = int.tryParse(meUser['store_id'].toString()) ?? userStoreId;
              }
              if (meUser['store_name'] != null && meUser['store_name'].toString().trim().isNotEmpty) {
                userStoreName = meUser['store_name'].toString().trim();
              }
              if (meUser['store'] is Map) {
                if (meUser['store']['id'] != null) {
                  userStoreId = int.tryParse(meUser['store']['id'].toString()) ?? userStoreId;
                }
                if (meUser['store']['name'] != null) {
                  userStoreName = meUser['store']['name'].toString().trim();
                }
              }
              if (meUser['role'] != null) {
                userRole = meUser['role'].toString().toUpperCase();
              }
            }
          }
        } catch (_) {}

        // 4. Если store_id все еще не указан сервером, сопоставляем логин с подразделением/магазином (subdomain / имя)
        if (userStoreId == null && allStores.isNotEmpty) {
          final cleanUser = username.toLowerCase().trim();
          final matched = allStores.firstWhere(
            (s) {
              final sub = (s['subdomain'] ?? '').toString().toLowerCase().trim();
              final sName = (s['name'] ?? '').toString().toLowerCase().trim();
              return (sub.isNotEmpty && (sub == cleanUser || cleanUser.contains(sub))) ||
                     (sName.isNotEmpty && (sName.contains(cleanUser) || cleanUser.contains(sName)));
            },
            orElse: () => {},
          );
          if (matched.isNotEmpty && matched['id'] != null) {
            userStoreId = matched['id'] as int;
            userStoreName = matched['name'] as String;
          }
        }

        // 5. Ищем точное название магазина в общем справочнике магазинов gusar.tj
        if (userStoreId != null && allStores.isNotEmpty) {
          final matched = allStores.firstWhere(
            (s) => (s['id'] as int) == userStoreId,
            orElse: () => {},
          );
          if (matched.isNotEmpty && matched['name'] != null) {
            userStoreName = matched['name'] as String;
          }
        }

        final isSuperAdmin = (userRole == 'SUPERADMIN' || userRole == 'OWNER') && userStoreId == null;

        int assignedStoreId;
        String assignedStoreName;

        if (userStoreId != null) {
          // Для сотрудника закрепляем строго ЕГО магазин
          assignedStoreId = userStoreId;
          assignedStoreName = userStoreName ?? 'Магазин gusar.tj #$userStoreId';
          accessibleStores = [
            {'id': assignedStoreId, 'name': assignedStoreName, 'address': 'Магазин сотрудника $username'}
          ];
        } else if (isSuperAdmin) {
          // Для подтвержденного суперадмина без склада открываем каталог
          accessibleStores = allStores.isNotEmpty ? allStores : [
            {'id': 1, 'name': 'Ашам Маркет', 'address': 'Основной склад'}
          ];
          assignedStoreId = accessibleStores.first['id'] as int;
          assignedStoreName = accessibleStores.first['name'] as String;
        } else {
          assignedStoreId = allStores.isNotEmpty ? (allStores.first['id'] as int) : 1;
          assignedStoreName = allStores.isNotEmpty ? (allStores.first['name'] as String) : 'Склад gusar.tj';
          accessibleStores = [
            {'id': assignedStoreId, 'name': assignedStoreName, 'address': 'Магазин сотрудника $username'}
          ];
        }

        // ВАЖНО: Обновляем текущий магазин и сбрасываем кэш товаров и поставщиков старого магазина!
        await updateStore(assignedStoreId, assignedStoreName);
        await prefs.setString('accessible_stores_list', jsonEncode(accessibleStores));

        return {
          'success': true,
          'message': 'Добро пожаловать! Открыт магазин: $assignedStoreName',
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
    _cachedProducts = [];
    _cachedSuppliers = [];
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove('auth_token');
    await prefs.setBool('is_authenticated', false);
    await prefs.remove('logged_username');
    await prefs.remove('store_id');
    await prefs.remove('store_name');
    await prefs.remove('cached_products_list');
    await prefs.remove('cached_suppliers_list');
    await prefs.remove('accessible_stores_list');
    final keepPassword = prefs.getBool('remember_credentials') ?? false;
    if (!keepPassword) {
      await prefs.remove('saved_password');
    }
    _dio.options.headers.remove('Authorization');
    _dio.options.headers.remove('X-Store-ID');
  }
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

  // 3. Создание нового товара прямо из приёмки или экрана добавления товара
  Future<Product?> createProduct({
    required String name,
    required String barcode,
    required double price,
    double? wholesalePrice,
    required double costPrice,
    int? categoryId,
    String? category,
    ProductType productType = ProductType.barcode,
    String unit = 'шт',
    String? pluCode,
    String? localImagePath,
    String? imageUrl,
  }) async {
    final cleanBarcode = barcode.trim();
    Product? created;

    String? base64Image;
    if (localImagePath != null && localImagePath.isNotEmpty) {
      try {
        final f = File(localImagePath);
        if (f.existsSync()) {
          // Гарантируем сжатие до <= 40 КБ перед конвертацией в base64 и отправкой на сервер
          final compressedFile = await ImageUtils.compressFileToMaxKb(f, maxKb: 40);
          final bytes = await compressedFile.readAsBytes();
          base64Image = 'data:image/jpeg;base64,${base64Encode(bytes)}';
        }
      } catch (_) {}
    }

    try {
      final response = await _dio.post('/api/products', data: {
        'name': name.trim(),
        'barcode': cleanBarcode,
        'price': price,
        'wholesale_price': wholesalePrice,
        'cost_price': costPrice,
        'category_id': categoryId,
        'category': category,
        'store_id': currentStoreId,
        'stock_quantity': 0,
        'product_type': productType.idName,
        'unit': unit,
        'plu_code': pluCode,
        'image_url': imageUrl,
        if (base64Image != null) 'imageBase64': base64Image,
      }).timeout(const Duration(seconds: 12));

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
      barcode: cleanBarcode.isNotEmpty ? cleanBarcode : null,
      price: price,
      wholesalePrice: wholesalePrice,
      costPrice: costPrice,
      stockQuantity: 0,
      category: category,
      productType: productType,
      unit: unit,
      pluCode: pluCode,
      localImagePath: localImagePath,
      imageUrl: imageUrl,
    );

    _addOrUpdateCachedProduct(created);
    return created;
  }

  // 4. Загрузка фото товара на сервер gusar.tj в формате Base64 (как в админке сайта)
  Future<Product?> uploadProductImage(int productId, String imagePath) async {
    final idx = _cachedProducts.indexWhere((p) => p.id == productId);
    Product? updatedProd;

    try {
      final f = File(imagePath);
      if (!f.existsSync()) return null;

      // Гарантируем сжатие до <= 40 КБ перед отправкой на сервер
      final compressedFile = await ImageUtils.compressFileToMaxKb(f, maxKb: 40);
      final bytes = await compressedFile.readAsBytes();
      final base64Image = 'data:image/jpeg;base64,${base64Encode(bytes)}';

      Response? response;
      // 1. Быстрое обновление фото через метод админки gusar.tj
      try {
        response = await _dio.patch(
          '/api/admin/products/$productId/quick-update',
          data: {'imageBase64': base64Image},
        ).timeout(const Duration(seconds: 15));
      } catch (_) {
        // 2. Метод через прямое обновление карточки товара
        try {
          response = await _dio.put(
            '/api/products/$productId',
            data: {'imageBase64': base64Image},
          ).timeout(const Duration(seconds: 15));
        } catch (_) {}
      }

      if (response != null && (response.statusCode == 200 || response.statusCode == 201) && response.data != null) {
        final serverUrl = response.data['image_url'] ??
            response.data['url'] ??
            response.data['image'] ??
            response.data['product']?['image_url'];
        if (idx >= 0) {
          updatedProd = _cachedProducts[idx].copyWith(
            imageUrl: serverUrl?.toString() ?? _cachedProducts[idx].imageUrl,
            localImagePath: imagePath,
          );
        }
      }
    } catch (e) {
      print('Upload product photo to server error: $e');
    }

    if (updatedProd == null && idx >= 0) {
      updatedProd = _cachedProducts[idx].copyWith(localImagePath: imagePath);
    }

    if (updatedProd != null) {
      _addOrUpdateCachedProduct(updatedProd);
    }

    return updatedProd;
  }

  List<Supplier> _cachedSuppliers = [];
  List<Supplier> get cachedSuppliers => _cachedSuppliers;

  // 4. Получение актуального списка контрагентов из базы магазина на gusar.tj (СТРОГО из базы магазина)
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
        // Защита от старых тестовых сидов: если обнаружены старые заглушки, очищаем кэш!
        final hasLegacySeeds = sups.any((s) => s.name.contains('Оби Зулол') || s.name.contains('Кока-Кола Таджикистан') || s.name.contains('Шири Душанбе'));
        if (!hasLegacySeeds && sups.isNotEmpty) {
          _cachedSuppliers = sups.where((s) => s.storeId == currentStoreId).toList();
          if (_cachedSuppliers.isNotEmpty) return _cachedSuppliers;
        } else if (hasLegacySeeds) {
          await prefs.remove('cached_suppliers_list');
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

    // Никаких заглушек: строго реальные поставщики базы gusar.tj
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

  // 5. Создание нового контрагента в базе магазина на сервере gusar.tj
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

      if (response.statusCode == 200 || response.statusCode == 201) {
        final data = response.data is Map ? (response.data['supplier'] ?? response.data['data'] ?? response.data) : response.data;
        if (data is Map<String, dynamic>) {
          created = Supplier.fromJson(data);
        }
      }
    } catch (e) {
      print('Create supplier server error: $e');
    }

    created ??= Supplier(
      id: DateTime.now().millisecondsSinceEpoch ~/ 1000,
      storeId: currentStoreId,
      name: cleanName,
      contact: contact?.trim(),
      inn: inn?.trim(),
      address: address?.trim(),
    );

    _cachedSuppliers.removeWhere((s) => s.id == created!.id);
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
      final isDebt = document.paidAmount <= 0;
      final invNum = document.invoiceNumber.trim();
      final double total = document.totalAmount > 0 ? document.totalAmount : document.calculatedTotal;
      final double paid = isDebt ? 0.0 : document.paidAmount;

      final purchasePayload = {
        'store_id': currentStoreId,
        'supplier_id': document.supplierId,
        // Передаем распознанный номер бумажной накладной во все возможные поля бэкенда:
        'invoice_number': invNum,
        'invoice_no': invNum,
        'incoming_invoice_number': invNum,
        'incoming_number': invNum,
        'total_amount': total,
        // Если выбрано в долг — ячейка оплаты пустая (null/0)
        'paid_amount': isDebt ? null : paid,
        'payment_status': isDebt ? 'debt' : (paid >= total ? 'paid' : 'partial'),
        'is_debt': isDebt ? 1 : 0,
        'notes': 'Накладная №${invNum.isNotEmpty ? invNum : "Б/Н"} от ${document.invoiceDate.toIso8601String().substring(0, 10)} (Поставщик: ${document.supplierName}) [${isDebt ? "В ДОЛГ / НЕ ОПЛАЧЕНО" : "ОПЛАЧЕНО: " + paid.toStringAsFixed(2) + " TJS"}]',
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
