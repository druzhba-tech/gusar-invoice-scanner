import 'dart:convert';
import 'dart:io';
import 'package:sqflite/sqflite.dart';
import 'package:path/path.dart';
import '../models/invoice_document.dart';
import '../models/invoice_item.dart';
import '../models/product.dart';
import '../utils/image_utils.dart';

class LocalStorageService {
  static final LocalStorageService _instance = LocalStorageService._internal();
  factory LocalStorageService() => _instance;
  LocalStorageService._internal();

  Database? _db;

  Future<Database> get database async {
    if (_db != null) return _db!;
    _db = await _initDb();
    return _db!;
  }

  Future<Database> _initDb() async {
    final dbPath = await getDatabasesPath();
    final path = join(dbPath, 'gusar_scanner.db');

    final db = await openDatabase(
      path,
      version: 4,
      onCreate: (db, version) async {
        // Таблица локальных документов накладных
        await db.execute('''
          CREATE TABLE invoices (
            id TEXT PRIMARY KEY,
            store_id INTEGER,
            supplier_id INTEGER,
            supplier_name TEXT,
            invoice_number TEXT,
            incoming_number TEXT,
            invoice_date TEXT,
            total_amount REAL,
            paid_amount REAL,
            payment_source TEXT,
            items_json TEXT,
            page_photos_json TEXT,
            status TEXT,
            is_synchronized INTEGER,
            created_at TEXT
          )
        ''');

        // Таблица кэша каталога товаров для мгновенного офлайн-сканирования
        await db.execute('''
          CREATE TABLE products_cache (
            id INTEGER PRIMARY KEY,
            store_id INTEGER,
            name TEXT,
            barcode TEXT,
            price REAL,
            cost_price REAL,
            stock_quantity REAL,
            category TEXT,
            payload_json TEXT
          )
        ''');
        await db.execute('CREATE INDEX IF NOT EXISTS idx_products_cache_store ON products_cache(store_id)');
        await db.execute('CREATE INDEX IF NOT EXISTS idx_products_cache_barcode ON products_cache(store_id, barcode)');
      },
      onUpgrade: (db, oldVersion, newVersion) async {
        try {
          await db.execute('ALTER TABLE invoices ADD COLUMN incoming_number TEXT;');
        } catch (_) {}
        try {
          await db.execute('ALTER TABLE invoices ADD COLUMN payment_source TEXT;');
        } catch (_) {}
        try {
          await db.execute('ALTER TABLE products_cache ADD COLUMN payload_json TEXT;');
        } catch (_) {}
        try {
          await db.execute('CREATE INDEX IF NOT EXISTS idx_products_cache_store ON products_cache(store_id)');
          await db.execute('CREATE INDEX IF NOT EXISTS idx_products_cache_barcode ON products_cache(store_id, barcode)');
        } catch (_) {}
      },
    );

    // Гарантированная миграция существующей локальной БД без потери данных
    try {
      await db.execute('ALTER TABLE invoices ADD COLUMN incoming_number TEXT;');
    } catch (_) {}
    try {
      await db.execute('ALTER TABLE invoices ADD COLUMN payment_source TEXT;');
    } catch (_) {}
    try {
      await db.execute('ALTER TABLE products_cache ADD COLUMN payload_json TEXT;');
    } catch (_) {}
    try {
      await db.execute('CREATE INDEX IF NOT EXISTS idx_products_cache_store ON products_cache(store_id)');
      await db.execute('CREATE INDEX IF NOT EXISTS idx_products_cache_barcode ON products_cache(store_id, barcode)');
    } catch (_) {}

    return db;
  }

  // Сохранение кэша каталога магазина в SQLite (быстро и без переполнения SharedPreferences)
  Future<void> saveProductsCache(int storeId, List<Product> products) async {
    if (storeId <= 0) return;
    try {
      final db = await database;
      await db.transaction((txn) async {
        await txn.delete('products_cache', where: 'store_id = ?', whereArgs: [storeId]);
        final batch = txn.batch();
        for (final p in products) {
          batch.insert(
            'products_cache',
            {
              'id': p.id,
              'store_id': storeId,
              'name': p.name,
              'barcode': p.barcode ?? '',
              'price': p.price,
              'cost_price': p.costPrice,
              'stock_quantity': p.stockQuantity,
              'category': p.category ?? '',
              'payload_json': jsonEncode(p.toJson()),
            },
            conflictAlgorithm: ConflictAlgorithm.replace,
          );
        }
        await batch.commit(noResult: true);
      });
    } catch (e) {
      print('saveProductsCache warning: $e');
    }
  }

  Future<List<Product>> getProductsCache(int storeId) async {
    if (storeId <= 0) return [];
    try {
      final db = await database;
      final rows = await db.query(
        'products_cache',
        columns: ['payload_json', 'id', 'store_id', 'name', 'barcode', 'price', 'cost_price', 'stock_quantity', 'category'],
        where: 'store_id = ?',
        whereArgs: [storeId],
      );
      final List<Product> result = [];
      for (final r in rows) {
        final rawPayload = r['payload_json']?.toString();
        if (rawPayload != null && rawPayload.isNotEmpty) {
          try {
            result.add(Product.fromJson(jsonDecode(rawPayload) as Map<String, dynamic>));
            continue;
          } catch (_) {}
        }
        result.add(Product(
          id: (r['id'] as int?) ?? 0,
          storeId: (r['store_id'] as int?) ?? storeId,
          name: r['name']?.toString() ?? '',
          barcode: r['barcode']?.toString(),
          price: (r['price'] as num?)?.toDouble() ?? 0.0,
          costPrice: (r['cost_price'] as num?)?.toDouble() ?? 0.0,
          stockQuantity: (r['stock_quantity'] as num?)?.toDouble() ?? 0.0,
          category: r['category']?.toString(),
        ));
      }
      return result;
    } catch (e) {
      print('getProductsCache warning: $e');
      return [];
    }
  }

  Future<void> clearProductsCache(int storeId) async {
    if (storeId <= 0) return;
    try {
      final db = await database;
      await db.delete('products_cache', where: 'store_id = ?', whereArgs: [storeId]);
    } catch (_) {}
  }

  // 1. Сохранение черновика накладной (с защитой от переполнения CursorWindow 2 МБ в SQLite)
  Future<void> saveInvoice(InvoiceDocument doc) async {
    final db = await database;

    final List<String> optimizedPhotos = [];
    for (final photoPath in doc.pagePhotos) {
      final trimmed = photoPath.trim();
      if (trimmed.isEmpty) continue;
      // Никогда не сохраняем гигантские base64-строки напрямую в SQLite (они вызывают Row too big to fit into CursorWindow!)
      if (trimmed.startsWith('data:image') || trimmed.length > 4000) {
        try {
          final commaIdx = trimmed.indexOf(',');
          final b64Part = commaIdx != -1 ? trimmed.substring(commaIdx + 1) : trimmed;
          final bytes = base64Decode(b64Part);
          final dbDir = await getDatabasesPath();
          final filePath = join(dbDir, 'inv_photo_${doc.id}_${optimizedPhotos.length}.jpg');
          await File(filePath).writeAsBytes(bytes);
          optimizedPhotos.add(filePath);
        } catch (_) {}
      } else {
        optimizedPhotos.add(trimmed);
      }
    }
    doc.pagePhotos = optimizedPhotos;

    await db.insert(
      'invoices',
      {
        'id': doc.id,
        'store_id': doc.storeId,
        'supplier_id': doc.supplierId,
        'supplier_name': doc.supplierName,
        'invoice_number': doc.invoiceNumber,
        'incoming_number': doc.incomingNumber,
        'invoice_date': doc.invoiceDate.toIso8601String(),
        'total_amount': doc.totalAmount,
        'paid_amount': doc.paidAmount,
        'payment_source': doc.paymentSource,
        'items_json': jsonEncode(doc.items.map((i) => i.toJson()).toList()),
        'page_photos_json': jsonEncode(doc.pagePhotos),
        'status': doc.status.name,
        'is_synchronized': doc.isSynchronized ? 1 : 0,
        'created_at': doc.createdAt.toIso8601String(),
      },
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  // 2. Получение локальных накладных (построчное чтение без переполнения Android SQLite CursorWindow 2MB)
  Future<List<InvoiceDocument>> getLocalInvoices({int? storeId}) async {
    try {
      final db = await database;

      // 1. Авто-очистка гигантских base64-строк в page_photos_json внутри движка SQLite (до создания CursorWindow!)
      try {
        await db.execute("UPDATE invoices SET page_photos_json = '[]' WHERE LENGTH(page_photos_json) > 100000");
      } catch (_) {}

      // 2. Сначала запрашиваем ТОЛЬКО лёгкие ID строк со строгой изоляцией по store_id
      List<Map<String, dynamic>> idRows = [];
      if (storeId != null && storeId > 0) {
        idRows = await db.rawQuery(
          'SELECT id FROM invoices WHERE store_id = ? ORDER BY created_at DESC',
          [storeId],
        );
      } else {
        idRows = await db.rawQuery('SELECT id FROM invoices ORDER BY created_at DESC');
      }

      final List<InvoiceDocument> result = [];

      // 3. Загружаем каждую накладную по одной (1 строка = отдельный CursorWindow), чтобы сумма всех строк никогда не превышала 2 МБ
      for (final idMap in idRows) {
        final String? docId = idMap['id']?.toString();
        if (docId == null || docId.isEmpty) continue;

        try {
          final singleRows = await db.rawQuery(
            "SELECT id, store_id, supplier_id, supplier_name, invoice_number, incoming_number, "
            "invoice_date, total_amount, paid_amount, payment_source, "
            "CASE WHEN LENGTH(items_json) > 1500000 THEN '' ELSE items_json END AS items_json, "
            "CASE WHEN LENGTH(page_photos_json) > 100000 THEN '[]' ELSE page_photos_json END AS page_photos_json, "
            "status, is_synchronized, created_at "
            "FROM invoices WHERE id = ? LIMIT 1",
            [docId],
          );
          if (singleRows.isEmpty) continue;
          final r = singleRows.first;

          String rawItemsStr = r['items_json']?.toString() ?? '[]';
          // Если items_json был больше 1.5 МБ, читаем его безопасными частями по 400 КБ через SUBSTR
          if (rawItemsStr.isEmpty) {
            final sb = StringBuffer();
            int offset = 1;
            const int chunkSize = 400000;
            while (true) {
              final chunkRows = await db.rawQuery(
                'SELECT SUBSTR(items_json, ?, ?) AS chunk FROM invoices WHERE id = ? LIMIT 1',
                [offset, chunkSize, docId],
              );
              final part = chunkRows.isNotEmpty ? (chunkRows.first['chunk']?.toString() ?? '') : '';
              if (part.isEmpty) break;
              sb.write(part);
              if (part.length < chunkSize) break;
              offset += chunkSize;
            }
            rawItemsStr = sb.toString();
          }

          List<InvoiceItem> itemsList = [];
          if (rawItemsStr.isNotEmpty) {
            final decodedItems = jsonDecode(rawItemsStr);
            if (decodedItems is List) {
              for (final item in decodedItems) {
                if (item is Map) {
                  itemsList.add(InvoiceItem.fromJson(Map<String, dynamic>.from(item)));
                }
              }
            }
          }

          List<String> photosList = [];
          final rawPhotosStr = r['page_photos_json']?.toString() ?? '[]';
          if (rawPhotosStr.isNotEmpty) {
            final decodedPhotos = jsonDecode(rawPhotosStr);
            if (decodedPhotos is List) {
              photosList = decodedPhotos
                  .map((e) => e.toString())
                  .where((s) => s.isNotEmpty && s.length < 4000)
                  .toList();
            }
          }

          final rawStoreId = r['store_id'];
          final int parsedStoreId = rawStoreId is int
              ? rawStoreId
              : (int.tryParse(rawStoreId?.toString() ?? '') ?? (storeId ?? 1));

          final rawSupId = r['supplier_id'];
          final int? parsedSupId = rawSupId is int
              ? rawSupId
              : int.tryParse(rawSupId?.toString() ?? '');

          final rawTotal = r['total_amount'];
          final double parsedTotal = rawTotal is num
              ? rawTotal.toDouble()
              : (double.tryParse(rawTotal?.toString() ?? '0') ?? 0.0);

          final rawPaid = r['paid_amount'];
          final double parsedPaid = rawPaid is num
              ? rawPaid.toDouble()
              : (double.tryParse(rawPaid?.toString() ?? '0') ?? 0.0);

          final docDate = DateTime.tryParse(r['invoice_date']?.toString() ?? '') ?? DateTime.now();
          final createdDate = DateTime.tryParse(r['created_at']?.toString() ?? '') ?? docDate;

          result.add(InvoiceDocument(
            id: docId,
            storeId: parsedStoreId,
            supplierId: parsedSupId,
            supplierName: r['supplier_name']?.toString() ?? 'Поставщик',
            invoiceNumber: r['invoice_number']?.toString() ?? 'б/н',
            incomingNumber: r['incoming_number']?.toString() ?? '',
            invoiceDate: docDate,
            totalAmount: parsedTotal,
            paidAmount: parsedPaid,
            paymentSource: (r['payment_source']?.toString().trim().isNotEmpty == true)
                ? r['payment_source'].toString().trim()
                : 'cash_drawer',
            items: itemsList,
            pagePhotos: photosList,
            status: DocumentStatus.values.firstWhere(
              (e) => e.name == r['status']?.toString(),
              orElse: () => DocumentStatus.draft,
            ),
            isSynchronized: r['is_synchronized'] == 1 || r['is_synchronized'] == true,
            createdAt: createdDate,
          ));
        } catch (rowErr) {
          print('getLocalInvoices row parse warning ($docId): $rowErr');
        }
      }

      // Сортируем: черновики и самые свежие накладные сверху
      result.sort((a, b) => b.invoiceDate.compareTo(a.invoiceDate));
      return result;
    } catch (e) {
      print('getLocalInvoices db warning: $e');
      return [];
    }
  }

  // 3. Кэширование каталога товаров для офлайн-приёмки
  Future<void> cacheProducts(List<Product> products) async {
    final db = await database;
    final batch = db.batch();
    batch.delete('products_cache');

    for (var p in products) {
      batch.insert('products_cache', p.toDatabaseMap(), conflictAlgorithm: ConflictAlgorithm.replace);
    }
    await batch.commit(noResult: true);
  }

  // 4. Поиск товара в офлайн-кэше по штрихкоду
  Future<Product?> getProductByBarcodeOffline(String barcode) async {
    final db = await database;
    final rows = await db.query(
      'products_cache',
      where: 'barcode = ?',
      whereArgs: [barcode.trim()],
      limit: 1,
    );

    if (rows.isNotEmpty) {
      return Product.fromJson(rows.first);
    }
    return null;
  }

  // 5. Удаление накладной из локальной базы
  Future<void> deleteInvoice(String id) async {
    final db = await database;
    await db.delete('invoices', where: 'id = ?', whereArgs: [id]);
  }

  // 6. Очистка локальных накладных (с возможностью очистки только текущего магазина)
  Future<void> clearAllInvoices({int? storeId}) async {
    final db = await database;
    if (storeId != null && storeId > 0) {
      await db.delete('invoices', where: 'store_id = ?', whereArgs: [storeId]);
    } else {
      await db.delete('invoices');
    }
  }

  // 7. Проверка на дубликат накладной
  Future<InvoiceDocument?> findDuplicateInvoice(String supplierName, String invoiceNumber) async {
    final trimmedNum = invoiceNumber.trim();
    if (trimmedNum.isEmpty || trimmedNum.toLowerCase() == 'б/н' || trimmedNum == '0') {
      return null;
    }
    try {
      final allDocs = await getLocalInvoices();
      final querySupplier = supplierName.trim().toLowerCase();
      for (final doc in allDocs) {
        if (doc.invoiceNumber.trim().toLowerCase() == trimmedNum.toLowerCase() ||
            (doc.incomingNumber.trim().isNotEmpty && doc.incomingNumber.trim().toLowerCase() == trimmedNum.toLowerCase())) {
          final existingSupplier = doc.supplierName.trim().toLowerCase();
          if (querySupplier.isEmpty || existingSupplier.contains(querySupplier) || querySupplier.contains(existingSupplier)) {
            return doc;
          }
        }
      }
    } catch (_) {}
    return null;
  }

  // 8. Получение неотправленных накладных для офлайн-очереди
  Future<List<InvoiceDocument>> getUnsynchronizedInvoices() async {
    final allDocs = await getLocalInvoices();
    return allDocs.where((d) => !d.isSynchronized).toList();
  }

  // 9. Очистить все связки товаров внутри локальных накладных
  Future<void> clearAllItemMatchesInInvoices() async {
    final docs = await getLocalInvoices();
    for (var doc in docs) {
      bool changed = false;
      for (var item in doc.items) {
        if (item.matchedProductId != null) {
          item.matchedProductId = null;
          item.matchedProductName = null;
          item.matchedBarcode = null;
          item.matchConfidence = 0.0;
          item.status = ItemStatus.pending;
          changed = true;
        }
      }
      if (changed) {
        await saveInvoice(doc);
      }
    }
  }

  // 10. Отвязать конкретный товар по накладной
  Future<void> unmatchItemInInvoice(String invoiceId, String rawName) async {
    final docs = await getLocalInvoices();
    final docIdx = docs.indexWhere((d) => d.id == invoiceId);
    if (docIdx >= 0) {
      final doc = docs[docIdx];
      bool changed = false;
      final cleanRaw = rawName.trim().toLowerCase();
      for (var item in doc.items) {
        if (item.rawName.trim().toLowerCase() == cleanRaw) {
          item.matchedProductId = null;
          item.matchedProductName = null;
          item.matchedBarcode = null;
          item.matchConfidence = 0.0;
          item.status = ItemStatus.pending;
          changed = true;
        }
      }
      if (changed) {
        await saveInvoice(doc);
      }
    }
  }

  // 11. Перепривязать товар строки накладной к другому товару из базы
  Future<void> rematchItemInInvoice(String invoiceId, String rawName, Product newProduct) async {
    final docs = await getLocalInvoices();
    final docIdx = docs.indexWhere((d) => d.id == invoiceId);
    if (docIdx >= 0) {
      final doc = docs[docIdx];
      bool changed = false;
      final cleanRaw = rawName.trim().toLowerCase();
      for (var item in doc.items) {
        if (item.rawName.trim().toLowerCase() == cleanRaw) {
          item.matchedProductId = newProduct.id;
          item.matchedProductName = newProduct.name;
          item.matchedBarcode = newProduct.barcode;
          item.currentRetailPrice = newProduct.price;
          item.lastBuyPrice = newProduct.costPrice > 0 ? newProduct.costPrice : null;
          item.matchConfidence = 1.0;
          item.status = ItemStatus.verified;
          changed = true;
        }
      }
      if (changed) {
        await saveInvoice(doc);
      }
    }
  }
}
