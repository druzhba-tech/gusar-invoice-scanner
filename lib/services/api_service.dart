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

  // 2. Получение актуального каталога товаров и остатков магазина
  Future<List<Product>> getProducts() async {
    try {
      final response = await _dio.get('/api/products');
      if (response.statusCode == 200 && response.data is List) {
        return (response.data as List).map((p) => Product.fromJson(p)).toList();
      }
      return [];
    } catch (e) {
      print('Fetch products error: $e');
      return [];
    }
  }

  // 3. Создание нового товара прямо из приёмки за 1 клик
  Future<Product?> createProduct({
    required String name,
    required String barcode,
    required double price,
    required double costPrice,
    int? categoryId,
  }) async {
    try {
      final response = await _dio.post('/api/products', data: {
        'name': name,
        'barcode': barcode,
        'price': price,
        'cost_price': costPrice,
        'category_id': categoryId,
        'store_id': currentStoreId,
        'stock_quantity': 0,
      });

      if (response.statusCode == 200 || response.statusCode == 201) {
        return Product.fromJson(response.data);
      }
      return null;
    } catch (e) {
      print('Create product error: $e');
      return null;
    }
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
