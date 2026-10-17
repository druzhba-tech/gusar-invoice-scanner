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
      version: 2,
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
            category TEXT
          )
        ''');
      },
      onUpgrade: (db, oldVersion, newVersion) async {
        try {
          await db.execute('ALTER TABLE invoices ADD COLUMN incoming_number TEXT;');
        } catch (_) {}
      },
    );

    // Гарантированная миграция существующей локальной БД без потери данных
    try {
      await db.execute('ALTER TABLE invoices ADD COLUMN incoming_number TEXT;');
    } catch (_) {}

    return db;
  }

  // 1. Сохранение черновика накладной (со сжатием оригиналов фото до 40 КБ)
  Future<void> saveInvoice(InvoiceDocument doc) async {
    final db = await database;

    // Сохраняем фотографии страниц накладной в высоком оригинальном качестве (без сжатия в 40 КБ)
    final List<String> optimizedPhotos = [];
    for (final photoPath in doc.pagePhotos) {
      if (photoPath.isNotEmpty && File(photoPath).existsSync()) {
        optimizedPhotos.add(photoPath);
      } else if (photoPath.isNotEmpty) {
        optimizedPhotos.add(photoPath);
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
        'items_json': jsonEncode(doc.items.map((i) => i.toJson()).toList()),
        'page_photos_json': jsonEncode(doc.pagePhotos),
        'status': doc.status.name,
        'is_synchronized': doc.isSynchronized ? 1 : 0,
        'created_at': doc.createdAt.toIso8601String(),
      },
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  // 2. Получение всех локальных накладных
  Future<List<InvoiceDocument>> getLocalInvoices() async {
    final db = await database;
    final rows = await db.query('invoices', orderBy: 'created_at DESC');

    return rows.map((r) {
      final List<InvoiceItem> itemsList = (jsonDecode(r['items_json'] as String) as List<dynamic>)
          .map((item) => InvoiceItem.fromJson(item as Map<String, dynamic>))
          .toList();

      final photosList = List<String>.from(jsonDecode(r['page_photos_json'] as String));

      return InvoiceDocument(
        id: r['id'] as String,
        storeId: r['store_id'] as int,
        supplierId: r['supplier_id'] as int?,
        supplierName: r['supplier_name'] as String,
        invoiceNumber: r['invoice_number'] as String,
        incomingNumber: r['incoming_number'] as String? ?? '',
        invoiceDate: DateTime.parse(r['invoice_date'] as String),
        totalAmount: (r['total_amount'] as num).toDouble(),
        paidAmount: (r['paid_amount'] as num).toDouble(),
        items: itemsList,
        pagePhotos: photosList,
        status: DocumentStatus.values.firstWhere(
          (e) => e.name == r['status'],
          orElse: () => DocumentStatus.draft,
        ),
        isSynchronized: (r['is_synchronized'] as int) == 1,
        createdAt: DateTime.parse(r['created_at'] as String),
      );
    }).toList();
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

  // 6. Очистка всех локальных накладных
  Future<void> clearAllInvoices() async {
    final db = await database;
    await db.delete('invoices');
  }

  // 7. Проверка на дубликат накладной
  Future<InvoiceDocument?> findDuplicateInvoice(String supplierName, String invoiceNumber) async {
    final trimmedNum = invoiceNumber.trim();
    if (trimmedNum.isEmpty || trimmedNum.toLowerCase() == 'б/н' || trimmedNum == '0') {
      return null;
    }
    try {
      final db = await database;
      final rows = await db.query(
        'invoices',
        where: 'LOWER(invoice_number) = ?',
        whereArgs: [trimmedNum.toLowerCase()],
        limit: 5,
      );

      for (var r in rows) {
        final existingSupplier = (r['supplier_name'] as String? ?? '').toLowerCase();
        final querySupplier = supplierName.trim().toLowerCase();
        if (querySupplier.isEmpty || existingSupplier.contains(querySupplier) || querySupplier.contains(existingSupplier)) {
          final List<InvoiceItem> itemsList = (jsonDecode(r['items_json'] as String) as List<dynamic>)
              .map((item) => InvoiceItem.fromJson(item as Map<String, dynamic>))
              .toList();
          final photosList = List<String>.from(jsonDecode(r['page_photos_json'] as String));
          return InvoiceDocument(
            id: r['id'] as String,
            storeId: r['store_id'] as int? ?? 1,
            supplierId: r['supplier_id'] as int?,
            supplierName: r['supplier_name'] as String? ?? 'Поставщик',
            invoiceNumber: r['invoice_number'] as String? ?? 'б/н',
            invoiceDate: DateTime.tryParse(r['invoice_date'] as String? ?? '') ?? DateTime.now(),
            totalAmount: (r['total_amount'] as num?)?.toDouble() ?? 0.0,
            paidAmount: (r['paid_amount'] as num?)?.toDouble() ?? 0.0,
            items: itemsList,
            pagePhotos: photosList,
            status: DocumentStatus.values.firstWhere(
              (s) => s.name == (r['status'] as String? ?? 'draft'),
              orElse: () => DocumentStatus.draft,
            ),
            isSynchronized: (r['is_synchronized'] as int? ?? 0) == 1,
            createdAt: DateTime.tryParse(r['created_at'] as String? ?? '') ?? DateTime.now(),
          );
        }
      }
    } catch (_) {}
    return null;
  }

  // 8. Получение неотправленных накладных для офлайн-очереди
  Future<List<InvoiceDocument>> getUnsynchronizedInvoices() async {
    final db = await database;
    final rows = await db.query('invoices', where: 'is_synchronized = 0', orderBy: 'created_at ASC');
    return rows.map((r) {
      final List<InvoiceItem> itemsList = (jsonDecode(r['items_json'] as String) as List<dynamic>)
          .map((item) => InvoiceItem.fromJson(item as Map<String, dynamic>))
          .toList();
      final photosList = List<String>.from(jsonDecode(r['page_photos_json'] as String));
      return InvoiceDocument(
        id: r['id'] as String,
        storeId: r['store_id'] as int? ?? 1,
        supplierId: r['supplier_id'] as int?,
        supplierName: r['supplier_name'] as String? ?? 'Поставщик',
        invoiceNumber: r['invoice_number'] as String? ?? 'б/н',
        invoiceDate: DateTime.tryParse(r['invoice_date'] as String? ?? '') ?? DateTime.now(),
        totalAmount: (r['total_amount'] as num?)?.toDouble() ?? 0.0,
        paidAmount: (r['paid_amount'] as num?)?.toDouble() ?? 0.0,
        items: itemsList,
        pagePhotos: photosList,
        status: DocumentStatus.values.firstWhere(
          (s) => s.name == (r['status'] as String? ?? 'draft'),
          orElse: () => DocumentStatus.draft,
        ),
        isSynchronized: false,
        createdAt: DateTime.tryParse(r['created_at'] as String? ?? '') ?? DateTime.now(),
      );
    }).toList();
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
          item.status = ItemStatus.unmatched;
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
          item.status = ItemStatus.unmatched;
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
