class Product {
  final int id;
  final int storeId;
  final String name;
  final String? barcode;
  final double price; // Розничная цена продажи
  final double costPrice; // Последняя себестоимость
  final double stockQuantity; // Текущий остаток
  final String? category;
  final String? imageUrl;

  Product({
    required this.id,
    required this.storeId,
    required this.name,
    this.barcode,
    required this.price,
    this.costPrice = 0.0,
    this.stockQuantity = 0.0,
    this.category,
    this.imageUrl,
  });

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'store_id': storeId,
      'name': name,
      'barcode': barcode,
      'price': price,
      'cost_price': costPrice,
      'stock_quantity': stockQuantity,
      'category': category,
      'image_url': imageUrl,
    };
  }

  factory Product.fromJson(Map<String, dynamic> json) {
    return Product(
      id: json['id'] is int ? json['id'] : int.tryParse(json['id'].toString()) ?? 0,
      storeId: json['store_id'] is int ? json['store_id'] : int.tryParse(json['store_id'].toString()) ?? 1,
      name: json['name'] ?? '',
      barcode: json['barcode']?.toString(),
      price: (json['price'] as num?)?.toDouble() ?? 0.0,
      costPrice: (json['cost_price'] as num?)?.toDouble() ?? 0.0,
      stockQuantity: (json['stock_quantity'] as num?)?.toDouble() ?? 0.0,
      category: json['category'],
      imageUrl: json['image_url'],
    );
  }
}
