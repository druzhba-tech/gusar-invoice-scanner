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
  int currentStoreId = 3; // По умолчанию магазин Мағозаи намунавӣ (Тестӣ #3)
  String currentStoreName = 'Мағозаи намунавӣ (Тестӣ #3)';
  List<Map<String, dynamic>> accessibleStores = [];

  String? lastSubmitError;
  bool _isRefreshingToken = false;

  Future<void> init() async {
    final prefs = await SharedPreferences.getInstance();
    baseUrl = prefs.getString('api_base_url') ?? 'https://gusar.tj';
    authToken = prefs.getString('auth_token');
    final savedId = prefs.getInt('store_id');
    final savedName = prefs.getString('store_name');
    if (savedId != null && savedId > 0 && savedName != null && savedName.trim().isNotEmpty) {
      currentStoreId = savedId;
      currentStoreName = savedName.trim();
    } else {
      currentStoreId = 3;
      currentStoreName = 'Мағозаи намунавӣ (Тестӣ #3)';
    }

    final savedAcc = prefs.getString('accessible_stores_list');
    if (savedAcc != null) {
      try {
        final decoded = jsonDecode(savedAcc) as List;
        accessibleStores = decoded
            .map((e) => Map<String, dynamic>.from(e as Map))
            .where((s) => (s['id'] ?? 0) > 0 && (s['name'] ?? '').toString().trim().isNotEmpty)
            .toList();
      } catch (_) {}
    }
    if (accessibleStores.isEmpty) {
      accessibleStores = [
        {'id': currentStoreId, 'name': currentStoreName, 'address': 'Магазин gusar.tj'}
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

    // Перехватчик для автоматического обновления токена при 401 (Session Expired Shield)
    _dio.interceptors.add(
      InterceptorsWrapper(
        onRequest: (options, handler) {
          if (authToken != null && authToken!.isNotEmpty) {
            options.headers['Authorization'] = 'Bearer $authToken';
          }
          options.headers['X-Store-ID'] = currentStoreId.toString();
          return handler.next(options);
        },
        onError: (DioException error, handler) async {
          // Если токен протух (401), пробуем тихий вход с сохранёнными логином и паролем
          if (error.response?.statusCode == 401 && !error.requestOptions.path.contains('/login')) {
            final refreshed = await _trySilentReLogin();
            if (refreshed) {
              final opts = error.requestOptions;
              opts.headers['Authorization'] = 'Bearer $authToken';
              opts.headers['X-Store-ID'] = currentStoreId.toString();
              try {
                final retryResponse = await _dio.fetch(opts);
                return handler.resolve(retryResponse);
              } catch (retryErr) {
                return handler.next(error);
              }
            }
          }
          return handler.next(error);
        },
      ),
    );
  }

  // Тихий перезапуск сессии при истечении срока JWT-токена
  Future<bool> _trySilentReLogin() async {
    if (_isRefreshingToken) return false;
    _isRefreshingToken = true;
    try {
      final prefs = await SharedPreferences.getInstance();
      final savedUser = prefs.getString('saved_username') ?? prefs.getString('logged_username');
      final savedPass = prefs.getString('saved_password');

      if (savedUser == null || savedPass == null || savedUser.isEmpty || savedPass.isEmpty) {
        _isRefreshingToken = false;
        return false;
      }

      final isolatedDio = Dio(BaseOptions(
        baseUrl: baseUrl,
        connectTimeout: const Duration(seconds: 10),
        receiveTimeout: const Duration(seconds: 10),
      ));

      Response? response;
      try {
        response = await isolatedDio.post('/api/admin/login', data: {
          'username': savedUser,
          'password': savedPass,
        });
      } catch (_) {
        response = await isolatedDio.post('/api/auth/login', data: {
          'username': savedUser,
          'password': savedPass,
        });
      }

      if (response != null && (response.statusCode == 200 || response.statusCode == 201) && response.data != null) {
        final token = response.data['token']?.toString() ??
            response.data['accessToken']?.toString() ??
            response.data['data']?['token']?.toString();
        if (token != null && token.isNotEmpty) {
          updateToken(token);
          _isRefreshingToken = false;
          return true;
        }
      }
    } catch (e) {
      print('Silent re-login failed: $e');
    }
    _isRefreshingToken = false;
    return false;
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
    final validId = id > 0 ? id : 2;
    final validName = name.trim().isNotEmpty ? name.trim() : 'Мағозаи Арзон';
    currentStoreId = validId;
    currentStoreName = validName;
    _cachedProducts = []; // ВАЖНО: очищаем память от товаров старого магазина!
    _cachedSuppliers = []; // ВАЖНО: очищаем память от контрагентов старого магазина!
    _dio.options.headers['X-Store-ID'] = validId.toString();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt('store_id', validId);
    await prefs.setString('store_name', validName);
    await prefs.remove('cached_products_list'); // Очищаем кэш старого магазина
    await prefs.remove('cached_suppliers_list'); // Очищаем кэш контрагентов старого магазина
  }

  void updateStoreId(int id) async {
    final validId = id > 0 ? id : 2;
    currentStoreId = validId;
    _cachedProducts = [];
    _cachedSuppliers = [];
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt('store_id', validId);
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
            final isActive = e['is_active'] == true || e['active'] == true || e['is_active'] == 1;
            return {
              'id': id,
              'name': name,
              'address': address,
              'subdomain': subdomain,
              'is_active': isActive,
            };
          }).toList();
          return list;
        }
      }
    } catch (e) {
      print('fetchStores warning: $e');
    }
    return [];
  }

  // 1. Авторизация сотрудника склада / товароведа с привязкой к выбранному или назначенному магазину
  Future<Map<String, dynamic>> login(String username, String password, {int? preferredStoreId, bool remember = true}) async {
    final prefs = await SharedPreferences.getInstance();

    // Всегда надежно сохраняем логин и пароль сотрудника в памяти приложения
    await prefs.setString('saved_username', username);
    await prefs.setString('saved_password', password);
    await prefs.setBool('remember_credentials', true);

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

        // 2. Определяем точный store_id пользователя:
        // А) Если пользователь выбрал магазин на экране логина - это высший приоритет!
        int? userStoreId = (preferredStoreId != null && preferredStoreId > 0) ? preferredStoreId : null;
        String? userStoreName;
        String? userRole = response.data['role']?.toString().toUpperCase();

        if (userStoreId == null && response.data['store_id'] != null) {
          userStoreId = int.tryParse(response.data['store_id'].toString());
        }

        final dynamic rawUser = response.data['user'] ?? response.data['data']?['user'];
        if (rawUser is Map && userStoreId == null) {
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

        // 3. Запрашиваем точный профиль сотрудника из gusar.tj (/api/auth/me) если еще не определен
        if (userStoreId == null) {
          try {
            final meResp = await _dio.get(
              '/api/auth/me',
              options: Options(headers: {'Authorization': 'Bearer $token'}),
            ).timeout(const Duration(seconds: 6));

            if (meResp.statusCode == 200 && meResp.data != null) {
              final meData = meResp.data;
              if (meData['store_id'] != null) {
                userStoreId = int.tryParse(meData['store_id'].toString());
              } else if (meData['storeId'] != null) {
                userStoreId = int.tryParse(meData['storeId'].toString());
              }

              final dynamic meUser = meData['user'] ?? meData['data'];
              if (meUser is Map) {
                if (meUser['store_id'] != null) {
                  userStoreId = int.tryParse(meUser['store_id'].toString()) ?? userStoreId;
                } else if (meUser['storeId'] != null) {
                  userStoreId = int.tryParse(meUser['storeId'].toString()) ?? userStoreId;
                }

                if (meUser['store_name'] != null && meUser['store_name'].toString().trim().isNotEmpty) {
                  userStoreName = meUser['store_name'].toString().trim();
                } else if (meUser['store'] is Map) {
                  if (meUser['store']['id'] != null) {
                    userStoreId = int.tryParse(meUser['store']['id'].toString()) ?? userStoreId;
                  }
                  if (meUser['store']['name'] != null) {
                    userStoreName = meUser['store']['name'].toString().trim();
                  }
                }
              }
            }
          } catch (_) {}
        }

        // 4. Умное сопоставление логина сотрудника со списком магазинов gusar.tj
        if (userStoreId == null && allStores.isNotEmpty) {
          final cleanUser = username.toLowerCase().trim();
          final userDigits = cleanUser.replaceAll(RegExp(r'\D'), '');

          // Если в логине есть номер магазина (например "3" или "№3")
          if (userDigits.isNotEmpty) {
            final parsedDigit = int.tryParse(userDigits);
            if (parsedDigit != null && allStores.any((s) => s['id'] == parsedDigit)) {
              final matched = allStores.firstWhere((s) => s['id'] == parsedDigit);
              userStoreId = matched['id'] as int;
              userStoreName = matched['name'] as String;
            }
          }

          // Если в логине слово "тест", "намунав", "test" - это Мағозаи намунавӣ (Тестӣ #3)
          if (userStoreId == null && (cleanUser.contains('тест') || cleanUser.contains('намунав') || cleanUser.contains('test'))) {
            final matched = allStores.firstWhere((s) => s['id'] == 3, orElse: () => {});
            if (matched.isNotEmpty && matched['id'] != null) {
              userStoreId = 3;
              userStoreName = matched['name'] as String;
            }
          }

          if (userStoreId == null) {
            final matched = allStores.firstWhere(
              (s) {
                final sub = (s['subdomain'] ?? '').toString().toLowerCase().trim();
                final sName = (s['name'] ?? '').toString().toLowerCase().trim();
                final bot = (s['bot_username'] ?? '').toString().toLowerCase().trim();
                final card = (s['bank_card'] ?? '').toString().toLowerCase().trim();
                final cardDigits = card.replaceAll(RegExp(r'\D'), '');

                if (sub.isNotEmpty && (sub == cleanUser || cleanUser.contains(sub) || sub.contains(cleanUser))) {
                  return true;
                }
                if (bot.isNotEmpty && (bot.contains(cleanUser) || cleanUser.contains(bot.replaceAll('_bot', '')))) {
                  return true;
                }
                if (userDigits.length >= 6 && cardDigits.contains(userDigits)) {
                  return true;
                }
                if (sName.isNotEmpty && (sName.contains(cleanUser) || cleanUser.contains(sName))) {
                  return true;
                }
                return false;
              },
              orElse: () => {},
            );

            if (matched.isNotEmpty && matched['id'] != null) {
              userStoreId = matched['id'] as int;
              userStoreName = matched['name'] as String;
            }
          }
        }

        // 5. Если всё еще не определен - проверяем ранее сохраненный в приложении магазин!
        if (userStoreId == null) {
          final previouslySavedId = prefs.getInt('store_id');
          if (previouslySavedId != null && previouslySavedId > 0 && allStores.any((s) => s['id'] == previouslySavedId)) {
            final matched = allStores.firstWhere((s) => s['id'] == previouslySavedId);
            userStoreId = matched['id'] as int;
            userStoreName = matched['name'] as String;
          }
        }

        // 6. Ищем точное название магазина в общем справочнике магазинов gusar.tj
        if (userStoreId != null && allStores.isNotEmpty) {
          final matched = allStores.firstWhere(
            (s) => (s['id'] as int) == userStoreId,
            orElse: () => {},
          );
          if (matched.isNotEmpty && matched['name'] != null) {
            userStoreName = matched['name'] as String;
          }
        }

        int assignedStoreId;
        String assignedStoreName;

        if (userStoreId != null && userStoreId > 0) {
          assignedStoreId = userStoreId;
          assignedStoreName = (userStoreName != null && userStoreName.trim().isNotEmpty)
              ? userStoreName.trim()
              : (allStores.firstWhere((s) => s['id'] == userStoreId, orElse: () => {})['name']?.toString() ?? 'Магазин gusar.tj #$userStoreId');
        } else {
          // Если магазин не определен ни сервером, ни пользователем - отдаем предпочтение Магазину #3
          final defaultStore = allStores.firstWhere(
            (s) => s['id'] == 3,
            orElse: () => allStores.firstWhere(
              (s) => s['is_active'] == true && s['id'] != null && (s['id'] as int) >= 1,
              orElse: () => allStores.isNotEmpty
                  ? allStores.first
                  : {'id': 3, 'name': 'Мағозаи намунавӣ (Тестӣ #3)', 'address': 'Магазин gusar.tj'},
            ),
          );
          assignedStoreId = defaultStore['id'] as int;
          assignedStoreName = defaultStore['name'] as String;
        }

        // ВСЕГДА предоставляем сотруднику полный список доступных магазинов для свободного переключения
        accessibleStores = allStores.isNotEmpty ? allStores : [
          {'id': assignedStoreId, 'name': assignedStoreName, 'address': 'Магазин сотрудника $username'}
        ];

        // ВАЖНО: Обновляем текущий магазин и сбрасываем кэш старого магазина!
        await updateStore(assignedStoreId, assignedStoreName);
        await prefs.setString('accessible_stores_list', jsonEncode(accessibleStores));

        // Предварительно загружаем актуальных поставщиков и каталог товаров для этого магазина
        getSuppliers(forceRefresh: true).catchError((_) => <Supplier>[]);
        getProducts().catchError((_) => <Product>[]);

        return {
          'success': true,
          'message': 'Добро пожаловать! Открыт магазин: $assignedStoreName',
          'store_name': assignedStoreName,
          'store_id': assignedStoreId,
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
      final savedId = preferredStoreId ?? prefs.getInt('store_id') ?? currentStoreId;
      final fallbackId = savedId > 0 ? savedId : 3;
      final fallbackName = prefs.getString('store_name') ?? currentStoreName;
      await updateStore(fallbackId, fallbackName);
      if (accessibleStores.isEmpty) {
        accessibleStores = [
          {'id': fallbackId, 'name': fallbackName, 'address': 'Магазин сотрудника $username'}
        ];
      }
      await prefs.setString('accessible_stores_list', jsonEncode(accessibleStores));
      return {
        'success': true,
        'message': 'Вход выполнен (офлайн-режим для $fallbackName).'
      };
    } catch (e) {
      await prefs.setString('logged_username', username);
      await prefs.setBool('is_authenticated', true);
      final savedId = preferredStoreId ?? prefs.getInt('store_id') ?? currentStoreId;
      final fallbackId = savedId > 0 ? savedId : 3;
      final fallbackName = prefs.getString('store_name') ?? currentStoreName;
      await updateStore(fallbackId, fallbackName);
      if (accessibleStores.isEmpty) {
        accessibleStores = [
          {'id': fallbackId, 'name': fallbackName, 'address': 'Магазин сотрудника $username'}
        ];
      }
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
    currentStoreId = 2; // Всегда валидный активный магазин (Мағозаи Арзон)
    currentStoreName = 'Мағозаи Арзон';
    accessibleStores = [
      {'id': 2, 'name': 'Мағозаи Арзон', 'address': 'Магазин gusar.tj'}
    ];
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove('auth_token');
    await prefs.setBool('is_authenticated', false);
    await prefs.remove('logged_username');
    // ВАЖНО: сохраняем saved_username и saved_password, чтобы пароли НЕ слетали при выходе!
    await prefs.remove('cached_products_list');
    await prefs.remove('cached_suppliers_list');
    _dio.options.headers.remove('Authorization');
    _dio.options.headers.remove('X-Store-ID');
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

  // 4. Получение актуального списка контрагентов из базы gusar.tj
  Future<List<Supplier>> getSuppliers({bool forceRefresh = false}) async {
    final prefs = await SharedPreferences.getInstance();

    if (!forceRefresh && _cachedSuppliers.isNotEmpty) {
      return _cachedSuppliers;
    }

    final localJson = prefs.getString('cached_suppliers_list');
    if (localJson != null && _cachedSuppliers.isEmpty && !forceRefresh) {
      try {
        final list = jsonDecode(localJson) as List;
        final sups = list
            .map((s) => Supplier.fromJson(s as Map<String, dynamic>))
            .where((s) => s.id > 0 && s.id < 1000000)
            .toList();
        if (sups.isNotEmpty) {
          _cachedSuppliers = sups;
          return _cachedSuppliers;
        }
      } catch (_) {}
    }

    // Пробуем эндпоинты gusar.tj по очереди
    final endpointsToTry = [
      {'path': '/api/suppliers', 'params': {'store_id': currentStoreId}},
      {'path': '/api/suppliers', 'params': <String, dynamic>{}},
      {'path': '/api/purchases/suppliers', 'params': <String, dynamic>{}},
      {'path': '/api/contractors', 'params': <String, dynamic>{}},
      {'path': '/api/admin/suppliers', 'params': <String, dynamic>{}},
    ];

    for (var ep in endpointsToTry) {
      try {
        final path = ep['path'] as String;
        final params = ep['params'] as Map<String, dynamic>;

        Response? response;
        try {
          response = await _dio.get(
            path,
            queryParameters: params.isNotEmpty ? params : null,
          ).timeout(const Duration(seconds: 7));
        } on DioException catch (dioErr) {
          if (dioErr.response?.statusCode == 401) {
            final ok = await _trySilentReLogin();
            if (ok) {
              response = await _dio.get(
                path,
                queryParameters: params.isNotEmpty ? params : null,
              ).timeout(const Duration(seconds: 7));
            }
          }
        }

        if (response != null && response.statusCode == 200 && response.data != null) {
          dynamic raw = response.data;
          List<dynamic> items = [];

          if (raw is List) {
            items = raw;
          } else if (raw is Map) {
            if (raw['suppliers'] is List) {
              items = raw['suppliers'];
            } else if (raw['contractors'] is List) {
              items = raw['contractors'];
            } else if (raw['data'] is List) {
              items = raw['data'];
            } else if (raw['data'] is Map && raw['data']['suppliers'] is List) {
              items = raw['data']['suppliers'];
            } else if (raw['data'] is Map && raw['data']['data'] is List) {
              items = raw['data']['data'];
            } else if (raw['items'] is List) {
              items = raw['items'];
            } else if (raw['result'] is List) {
              items = raw['result'];
            }
          }

          if (items.isNotEmpty) {
            final parsed = items
                .whereType<Map<String, dynamic>>()
                .map((s) => Supplier.fromJson(s))
                .where((s) => s.id > 0 && s.id < 1000000 && s.name.trim().isNotEmpty)
                .toList();

            if (parsed.isNotEmpty) {
              _cachedSuppliers = parsed;
              await prefs.setString(
                'cached_suppliers_list',
                jsonEncode(_cachedSuppliers.map((s) => s.toJson()).toList()),
              );
              return _cachedSuppliers;
            }
          }
        }
      } catch (e) {
        // Пробуем следующий эндпоинт
      }
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

  // 5. Создание нового контрагента в базе магазина на сервере gusar.tj (с защитой от дубликатов)
  Future<Supplier?> createSupplier(String name, {String? contact, String? address, String? inn}) async {
    final cleanName = name.trim();
    if (cleanName.isEmpty) return null;

    // ПРАВИЛО ДУБЛИКАТОВ: если контрагент с таким именем или ИНН уже есть в базе магазина — возвращаем существующего
    if (_cachedSuppliers.isEmpty) {
      await getSuppliers();
    }
    final cleanSimple = cleanName.toLowerCase().replaceAll(RegExp(r'["«»„“\s]+'), '');
    final cleanInn = inn?.replaceAll(RegExp(r'\D'), '').trim();
    for (final s in _cachedSuppliers) {
      final sSimple = s.name.toLowerCase().replaceAll(RegExp(r'["«»„“\s]+'), '');
      final sInn = s.inn?.replaceAll(RegExp(r'\D'), '').trim();
      if (sSimple.isNotEmpty && sSimple == cleanSimple) {
        return s; // Уже существует по названию — возвращаем имеющегося!
      }
      if (cleanInn != null && cleanInn.isNotEmpty && sInn != null && sInn.isNotEmpty && cleanInn == sInn) {
        return s; // Уже существует по ИНН — возвращаем имеющегося!
      }
    }

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
          final parsed = Supplier.fromJson(data);
          if (parsed.id > 0 && parsed.id < 1000000) {
            created = parsed;
          }
        }
      }
    } on DioException catch (e) {
      if (e.response?.statusCode == 401) {
        final relogOk = await _trySilentReLogin();
        if (relogOk) {
          return createSupplier(name, contact: contact, address: address, inn: inn);
        }
      }
    } catch (e) {
      print('Create supplier server error: $e');
    }

    // Кэшируем только реальные валидные серверные ID (защита от Foreign Key Violations)
    if (created != null && created.id > 0 && created.id < 1000000) {
      _cachedSuppliers.removeWhere((s) => s.id == created!.id || s.name.trim().toLowerCase() == cleanName.toLowerCase());
      _cachedSuppliers.insert(0, created);
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('cached_suppliers_list', jsonEncode(_cachedSuppliers.where((s) => s.id > 0 && s.id < 1000000).map((s) => s.toJson()).toList()));
    }

    return created;
  }

  // 6. Проверка на дубликат накладной
  Future<bool> checkInvoiceExists(String invoiceNumber, int? supplierId) async {
    final clean = invoiceNumber.trim().toLowerCase();
    if (clean.isEmpty) return false;
    try {
      final response = await _dio.get('/api/purchases', queryParameters: {'store_id': currentStoreId});
      if (response.statusCode == 200 && response.data is List) {
        for (var p in response.data) {
          final invNum = p['invoice_number']?.toString().trim().toLowerCase() ?? '';
          final notes = p['notes']?.toString().trim().toLowerCase() ?? '';
          if (invNum == clean || (notes.isNotEmpty && notes.contains(clean))) {
            return true;
          }
        }
      }
      return false;
    } catch (e) {
      return false;
    }
  }

  // 7. Отправка приходной накладной и прямое зачисление в остатки базы gusar.tj
  Future<bool> submitPurchase(InvoiceDocument document) async {
    lastSubmitError = null;
    try {
      final isDebt = document.paidAmount <= 0;
      final rawInvNum = document.invoiceNumber.trim();
      final cleanInvNum = rawInvNum.isNotEmpty
          ? rawInvNum
          : 'НАК-${DateTime.now().millisecondsSinceEpoch ~/ 1000}';
      final double total = document.totalAmount > 0 ? document.totalAmount : document.calculatedTotal;
      final double paid = isDebt ? 0.0 : document.paidAmount;

      // 1. Проверяем и валидируем контрагента:
      int? verifiedSupplierId;
      final rawSupName = document.supplierName.trim();

      // Санитизация: если в документе локальный псевдо-ID (>= 1,000,000 или <= 0), обнуляем
      if (document.supplierId != null && (document.supplierId! <= 0 || document.supplierId! >= 1000000)) {
        document.supplierId = null;
      }

      // Всегда опрашиваем сервер для получения актуального и достоверного списка контрагентов
      List<Supplier> serverSuppliers = [];
      try {
        serverSuppliers = await getSuppliers(forceRefresh: true);
      } catch (_) {
        serverSuppliers = _cachedSuppliers.where((s) => s.id > 0 && s.id < 1000000).toList();
      }

      // Функция нормализации для надёжного сопоставления (без кавычек, скобок, пробелов)
      String norm(String s) => s.toLowerCase().replaceAll(RegExp(r'["«»„“\s\-\.\,\(\)]+'), '');

      // А) Если в документе уже был ID, проверяем его реальное наличие в базе магазина
      if (document.supplierId != null && document.supplierId! > 0 && document.supplierId! < 1000000) {
        final exists = serverSuppliers.any((s) => s.id == document.supplierId);
        if (exists) {
          verifiedSupplierId = document.supplierId;
        }
      }

      // Б) Если ID не подтвержден, ищем по нормализованному названию среди контрагентов базы
      if (verifiedSupplierId == null && rawSupName.isNotEmpty) {
        final targetNorm = norm(rawSupName);
        for (final s in serverSuppliers) {
          if (s.id > 0 && s.id < 1000000) {
            final sNorm = norm(s.name);
            if (sNorm == targetNorm || (targetNorm.length > 3 && (sNorm.contains(targetNorm) || targetNorm.contains(sNorm)))) {
              verifiedSupplierId = s.id;
              document.supplierId = s.id;
              break;
            }
          }
        }

        // В) Если контрагента еще нет в базе gusar.tj, создаем его на сервере прямо сейчас
        if (verifiedSupplierId == null) {
          try {
            final newSup = await createSupplier(rawSupName);
            if (newSup != null && newSup.id > 0 && newSup.id < 1000000) {
              verifiedSupplierId = newSup.id;
              document.supplierId = newSup.id;
            }
          } catch (_) {}
        }
      }

      // 2. Формируем позиции с точными дробными весами (для весовых товаров в кг)
      final List<Map<String, dynamic>> itemsPayload = [];
      for (var item in document.items) {
        int? productId = item.matchedProductId;

        // Если товар не привязан к базе gusar.tj, создаем его карточку прямо в базе!
        if (productId == null || productId <= 0) {
          try {
            final newProd = await createProduct(
              name: item.rawName.trim(),
              barcode: item.barcode ?? item.matchedBarcode ?? '',
              price: item.currentRetailPrice ?? (item.buyPrice > 0 ? (item.buyPrice * 1.25) : 10.0),
              costPrice: item.buyPrice > 0 ? item.buyPrice : 1.0,
              unit: item.unit.isNotEmpty ? item.unit : 'шт',
            );
            if (newProd != null && newProd.id > 0) {
              productId = newProd.id;
              item.matchedProductId = newProd.id;
            }
          } catch (createErr) {
            print('Auto-create product error: $createErr');
          }
        }

        if (productId != null && productId > 0) {
          final rawQty = item.verifiedQuantity > 0 ? item.verifiedQuantity : item.quantity;
          final double cleanQty = double.tryParse(rawQty.toStringAsFixed(3)) ?? rawQty;
          final double cleanBuy = item.buyPrice > 0 ? double.tryParse(item.buyPrice.toStringAsFixed(2)) ?? item.buyPrice : 0.01;
          final double? cleanRetail = item.currentRetailPrice != null && item.currentRetailPrice! > 0
              ? double.tryParse(item.currentRetailPrice!.toStringAsFixed(2))
              : null;

          itemsPayload.add({
            'product_id': productId,
            'quantity': cleanQty > 0 ? cleanQty : 1.0,
            'buy_price': cleanBuy,
            if (cleanRetail != null) 'retail_price': cleanRetail,
            if (cleanRetail != null) 'sell_price': cleanRetail,
          });
        }
      }

      if (itemsPayload.isEmpty) {
        lastSubmitError = 'Нет привязанных товаров для оприходования.';
        return false;
      }

      final double debtAmount = (total - paid) > 0.001 ? (total - paid) : 0.0;

      final purchasePayload = {
        'store_id': currentStoreId,
        'supplier_id': verifiedSupplierId,
        'invoice_number': cleanInvNum,
        'invoice_no': cleanInvNum,
        'incoming_invoice_number': cleanInvNum,
        'incoming_number': cleanInvNum,
        'date': document.invoiceDate.toIso8601String(),
        'total_amount': double.parse(total.toStringAsFixed(2)),
        // Сумма оплаты и остаток долга по накладной
        'paid_amount': isDebt ? 0.0 : double.parse(paid.toStringAsFixed(2)),
        'amount_paid': isDebt ? 0.0 : double.parse(paid.toStringAsFixed(2)),
        'debt_amount': double.parse(debtAmount.toStringAsFixed(2)),
        'remaining_amount': double.parse(debtAmount.toStringAsFixed(2)),
        'unpaid_amount': double.parse(debtAmount.toStringAsFixed(2)),
        'payment_status': isDebt ? 'debt' : (debtAmount > 0.001 ? 'partial' : 'paid'),
        'is_debt': (isDebt || debtAmount > 0.001) ? 1 : 0,
        'payment_source': paid > 0 ? 'cash' : 'unpaid',
        'notes': 'Накладная №$cleanInvNum от ${document.invoiceDate.toIso8601String().substring(0, 10)} (Поставщик: ${document.supplierName}) [${isDebt ? "В ДОЛГ: ${debtAmount.toStringAsFixed(2)} TJS" : (debtAmount > 0.001 ? "ОПЛАЧЕНО: ${paid.toStringAsFixed(2)} TJS, ДОЛГ: ${debtAmount.toStringAsFixed(2)} TJS" : "ОПЛАЧЕНО ПОЛНОСТЬЮ: ${paid.toStringAsFixed(2)} TJS")}]',
        'items': itemsPayload,
      };

      final response = await _dio.post('/api/purchases', data: purchasePayload);

      if (response.statusCode == 200 || response.statusCode == 201) {
        return true;
      } else {
        lastSubmitError = response.data?['error']?.toString() ?? response.data?['message']?.toString() ?? 'Ошибка сервера ${response.statusCode}';
        return false;
      }
    } on DioException catch (dioErr) {
      if (dioErr.response?.statusCode == 401) {
        final relogOk = await _trySilentReLogin();
        if (relogOk) {
          return submitPurchase(document);
        }
      }
      final serverMsg = dioErr.response?.data?['error'] ?? dioErr.response?.data?['message'];
      lastSubmitError = serverMsg?.toString() ?? dioErr.message ?? 'Ошибка сети при отправке накладной';
      print('Submit purchase dio error: $lastSubmitError');
      return false;
    } catch (e) {
      lastSubmitError = e.toString();
      print('Submit purchase error: $e');
      return false;
    }
  }
}
