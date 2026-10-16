enum ProductType {
  barcode, // Штучный товар со стандартным штрихкодом (EAN-13, EAN-8)
  internal, // Внутренний артикул / код без заводского штрихкода
  weight, // Весовой товар (продаётся в кг, код для весов PLU)
}

extension ProductTypeExtension on ProductType {
  String get label {
    switch (this) {
      case ProductType.barcode:
        return 'Штрихкод';
      case ProductType.internal:
        return 'Внутренний код';
      case ProductType.weight:
        return 'Весы';
    }
  }

  String get idName {
    switch (this) {
      case ProductType.barcode:
        return 'barcode';
      case ProductType.internal:
        return 'internal';
      case ProductType.weight:
        return 'weight';
    }
  }

  static ProductType fromString(String? val) {
    if (val == null) return ProductType.barcode;
    final lower = val.toLowerCase().trim();
    if (lower == 'weight' || lower == 'весы' || lower == 'весовой') {
      return ProductType.weight;
    }
    if (lower == 'internal' || lower == 'внутренний' || lower == 'артикул' || lower == 'plu') {
      return ProductType.internal;
    }
    return ProductType.barcode;
  }
}

class Product {
  final int id;
  final int storeId;
  final String name;
  final String? barcode;
  final double price; // Розничная цена продажи
  final double? wholesalePrice; // Оптовая цена продажи
  final double costPrice; // Последняя себестоимость
  final double stockQuantity; // Текущий остаток
  final String? category;
  final String? imageUrl;
  final ProductType productType;
  final String unit; // 'шт', 'кг', 'л', 'уп'
  final String? pluCode; // Код для электронных весов
  final String? localImagePath; // Путь к локальному фото на телефоне

  Product({
    required this.id,
    required this.storeId,
    required this.name,
    this.barcode,
    required this.price,
    this.wholesalePrice,
    this.costPrice = 0.0,
    this.stockQuantity = 0.0,
    this.category,
    this.imageUrl,
    this.productType = ProductType.barcode,
    this.unit = 'шт',
    this.pluCode,
    this.localImagePath,
  });

  bool get isWeighted => productType == ProductType.weight;
  bool get isBarcode => productType == ProductType.barcode;
  bool get isInternal => productType == ProductType.internal;

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'store_id': storeId,
      'name': name,
      'barcode': barcode,
      'price': price,
      'wholesale_price': wholesalePrice,
      'cost_price': costPrice,
      'stock_quantity': stockQuantity,
      'category': category,
      'image_url': imageUrl,
      'product_type': productType.idName,
      'unit': unit,
      'plu_code': pluCode,
      'local_image_path': localImagePath,
    };
  }

  // Для локального SQLite кеша в products_cache
  Map<String, dynamic> toDatabaseMap() {
    return {
      'id': id,
      'store_id': storeId,
      'name': name,
      'barcode': barcode,
      'price': price,
      'wholesale_price': wholesalePrice,
      'cost_price': costPrice,
      'stock_quantity': stockQuantity,
      'category': category,
    };
  }

  factory Product.fromJson(Map<String, dynamic> json) {
    final name = json['name']?.toString() ??
        json['title']?.toString() ??
        json['product_name']?.toString() ??
        'Товар';
    final barcode = json['barcode']?.toString() ??
        json['bar_code']?.toString() ??
        json['code']?.toString() ??
        json['ean']?.toString();
    final price = (json['price'] ?? json['retail_price'] ?? json['sell_price'] ?? 0) is num
        ? (json['price'] ?? json['retail_price'] ?? json['sell_price'] ?? 0).toDouble()
        : double.tryParse((json['price'] ?? 0).toString()) ?? 0.0;
    final wholesalePrice = (json['wholesale_price'] ?? json['wholesale'] ?? json['opt_price'] ?? json['trade_price'] ?? json['optom_price']) is num
        ? (json['wholesale_price'] ?? json['wholesale'] ?? json['opt_price'] ?? json['trade_price'] ?? json['optom_price']).toDouble()
        : double.tryParse((json['wholesale_price'] ?? json['wholesale'] ?? json['opt_price'] ?? json['trade_price'] ?? json['optom_price'] ?? '').toString());
    final costPrice = (json['cost_price'] ?? json['cost'] ?? json['purchase_price'] ?? 0) is num
        ? (json['cost_price'] ?? json['cost'] ?? json['purchase_price'] ?? 0).toDouble()
        : double.tryParse((json['cost_price'] ?? 0).toString()) ?? 0.0;
    final stock = (json['stock_quantity'] ?? json['quantity'] ?? json['stock'] ?? json['qty'] ?? json['remainder'] ?? 0) is num
        ? (json['stock_quantity'] ?? json['quantity'] ?? json['stock'] ?? json['qty'] ?? json['remainder'] ?? 0).toDouble()
        : double.tryParse((json['stock_quantity'] ?? json['quantity'] ?? 0).toString()) ?? 0.0;

    // Определение типа товара
    ProductType parsedType = ProductType.barcode;
    if (json['product_type'] != null) {
      parsedType = ProductTypeExtension.fromString(json['product_type'].toString());
    } else if (json['is_weighted'] == true || json['unit'] == 'кг' || (barcode != null && barcode.length == 13 && barcode.startsWith(RegExp(r'2[0-9]')))) {
      parsedType = ProductType.weight;
    } else if (barcode != null && (barcode.length < 7 || barcode.startsWith('INT_'))) {
      parsedType = ProductType.internal;
    }

    final parsedUnit = json['unit']?.toString() ?? (parsedType == ProductType.weight ? 'кг' : 'шт');

    String? resolvedImageUrl;
    dynamic rawImage = json['image_url'] ??
        json['image'] ??
        json['imageUrl'] ??
        json['imageBase64'] ??
        json['photo'] ??
        json['photo_url'] ??
        json['img'] ??
        json['thumbnail'];

    if (rawImage == null && json['images'] is List && (json['images'] as List).isNotEmpty) {
      rawImage = (json['images'] as List).first;
    }

    if (rawImage != null) {
      final imgStr = rawImage.toString().trim();
      if (imgStr.isNotEmpty && imgStr != 'null') {
        if (imgStr.startsWith('/')) {
          resolvedImageUrl = 'https://gusar.tj$imgStr';
        } else if (imgStr.startsWith('uploads/') || imgStr.startsWith('images/')) {
          resolvedImageUrl = 'https://gusar.tj/$imgStr';
        } else {
          resolvedImageUrl = imgStr;
        }
      }
    }

    return Product(
      id: json['id'] is int ? json['id'] : int.tryParse(json['id']?.toString() ?? '0') ?? 0,
      storeId: json['store_id'] is int ? json['store_id'] : int.tryParse(json['store_id']?.toString() ?? '1') ?? 1,
      name: name,
      barcode: barcode,
      price: price,
      wholesalePrice: wholesalePrice,
      costPrice: costPrice,
      stockQuantity: stock,
      category: json['category']?.toString(),
      imageUrl: resolvedImageUrl,
      productType: parsedType,
      unit: parsedUnit,
      pluCode: json['plu_code']?.toString() ?? json['plu']?.toString(),
      localImagePath: json['local_image_path']?.toString(),
    );
  }

  Product copyWith({
    int? id,
    int? storeId,
    String? name,
    String? barcode,
    double? price,
    double? wholesalePrice,
    double? costPrice,
    double? stockQuantity,
    String? category,
    String? imageUrl,
    ProductType? productType,
    String? unit,
    String? pluCode,
    String? localImagePath,
  }) {
    return Product(
      id: id ?? this.id,
      storeId: storeId ?? this.storeId,
      name: name ?? this.name,
      barcode: barcode ?? this.barcode,
      price: price ?? this.price,
      wholesalePrice: wholesalePrice ?? this.wholesalePrice,
      costPrice: costPrice ?? this.costPrice,
      stockQuantity: stockQuantity ?? this.stockQuantity,
      category: category ?? this.category,
      imageUrl: imageUrl ?? this.imageUrl,
      productType: productType ?? this.productType,
      unit: unit ?? this.unit,
      pluCode: pluCode ?? this.pluCode,
      localImagePath: localImagePath ?? this.localImagePath,
    );
  }
}
