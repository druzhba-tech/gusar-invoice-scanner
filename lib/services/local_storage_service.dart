import 'dart:convert';
import 'package:sqflite/sqflite.dart';
import 'package:path/path.dart';
import '../models/invoice_document.dart';
import '../models/invoice_item.dart';
import '../models/product.dart';

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

    return await openDatabase(
      path,
      version: 1,
      onCreate: (db, version) async {
        // Таблица локальных документов накладных
        await db.execute('''
          CREATE TABLE invoices (
            id TEXT PRIMARY KEY,
            store_id INTEGER,
            supplier_id INTEGER,
            supplier_name TEXT,
            invoice_number TEXT,
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
    );
  }

  // 1. Сохранение черновика накладной
  Future<void> saveInvoice(InvoiceDocument doc) async {
    final db = await database;
    await db.insert(
      'invoices',
      {
        'id': doc.id,
        'store_id': doc.storeId,
        'supplier_id': doc.supplierId,
        'supplier_name': doc.supplierName,
        'invoice_number': doc.invoiceNumber,
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
      batch.insert('products_cache', p.toJson(), conflictAlgorithm: ConflictAlgorithm.replace);
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
}
