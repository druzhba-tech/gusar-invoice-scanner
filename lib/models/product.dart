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
    final costPrice = (json['cost_price'] ?? json['cost'] ?? json['purchase_price'] ?? 0) is num
        ? (json['cost_price'] ?? json['cost'] ?? json['purchase_price'] ?? 0).toDouble()
        : double.tryParse((json['cost_price'] ?? 0).toString()) ?? 0.0;
    final stock = (json['stock_quantity'] ?? json['quantity'] ?? json['stock'] ?? json['qty'] ?? json['remainder'] ?? 0) is num
        ? (json['stock_quantity'] ?? json['quantity'] ?? json['stock'] ?? json['qty'] ?? json['remainder'] ?? 0).toDouble()
        : double.tryParse((json['stock_quantity'] ?? json['quantity'] ?? 0).toString()) ?? 0.0;

    return Product(
      id: json['id'] is int ? json['id'] : int.tryParse(json['id']?.toString() ?? '0') ?? 0,
      storeId: json['store_id'] is int ? json['store_id'] : int.tryParse(json['store_id']?.toString() ?? '1') ?? 1,
      name: name,
      barcode: barcode,
      price: price,
      costPrice: costPrice,
      stockQuantity: stock,
      category: json['category']?.toString(),
      imageUrl: json['image_url']?.toString() ?? json['image']?.toString(),
    );
  }
}
