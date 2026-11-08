enum ItemStatus {
  pending,      // Не привязан к базе
  matched,      // Привязан к номенклатуре
  verified,     // Штрихкод проверен физически
  priceAlert,   // Скачок цены обнаружен
  discrepancy,  // Брак / Недостача
}

class InvoiceItem {
  String id;
  String rawName;
  double quantity;
  String unit;
  double buyPrice;
  double totalPrice;
  String? barcode;

  // Поля привязки к базе gusar.tj
  int? matchedProductId;
  String? matchedProductName;
  String? matchedBarcode;
  double? currentRetailPrice;
  double? lastBuyPrice;
  double matchConfidence; // 0.0 - 1.0

  // Поля физической сверки
  double verifiedQuantity;
  double defectiveQuantity;
  String? defectNotes;

  // Статус
  ItemStatus status;

  // Поля распаковки (коробки / штуки)
  bool isPieceBreakdown;
  double? unitsPerPackage;
  double? packageQuantity;
  double? packageBuyPrice;
  String? pieceBarcode;

  InvoiceItem({
    required this.id,
    required this.rawName,
    required this.quantity,
    this.unit = 'шт',
    required this.buyPrice,
    required this.totalPrice,
    this.barcode,
    this.matchedProductId,
    this.matchedProductName,
    this.matchedBarcode,
    this.currentRetailPrice,
    this.lastBuyPrice,
    this.matchConfidence = 0.0,
    this.verifiedQuantity = 0.0,
    this.defectiveQuantity = 0.0,
    this.defectNotes,
    this.status = ItemStatus.pending,
    this.isPieceBreakdown = false,
    this.unitsPerPackage,
    this.packageQuantity,
    this.packageBuyPrice,
    this.pieceBarcode,
  });

  bool get isMathValid {
    if (quantity <= 0 || buyPrice <= 0 || totalPrice <= 0) return false;
    final expectedTotal = quantity * buyPrice;
    // Допуск расхождения до 0.50 TJS для компенсации бухгалтерских округлений в 1С
    return (expectedTotal - totalPrice).abs() <= 0.50 || (expectedTotal > 0 && (expectedTotal - totalPrice).abs() / expectedTotal < 0.015);
  }

  double? get priceChangePercent {
    if (lastBuyPrice == null || lastBuyPrice! <= 0) return null;
    return ((buyPrice - lastBuyPrice!) / lastBuyPrice!) * 100.0;
  }

  bool get hasPriceSpike {
    final change = priceChangePercent;
    return change != null && change.abs() > 15.0; // Значимый скачок цены более 15%
  }

  bool get isMarginNegative {
    if (currentRetailPrice == null) return false;
    return buyPrice >= currentRetailPrice!;
  }

  bool get isFullyVerified {
    return (verifiedQuantity + defectiveQuantity) >= quantity;
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'raw_name': rawName,
      'quantity': quantity,
      'unit': unit,
      'buy_price': buyPrice,
      'total_price': totalPrice,
      'barcode': barcode,
      'matched_product_id': matchedProductId,
      'matched_product_name': matchedProductName,
      'matched_barcode': matchedBarcode,
      'current_retail_price': currentRetailPrice,
      'last_buy_price': lastBuyPrice,
      'match_confidence': matchConfidence,
      'verified_quantity': verifiedQuantity,
      'defective_quantity': defectiveQuantity,
      'defect_notes': defectNotes,
      'status': status.name,
      'is_piece_breakdown': isPieceBreakdown,
      'units_per_package': unitsPerPackage,
      'package_quantity': packageQuantity,
      'package_buy_price': packageBuyPrice,
      'piece_barcode': pieceBarcode,
    };
  }

  static double? _toDoubleOrNull(dynamic v) {
    if (v == null) return null;
    if (v is num) return v.toDouble();
    return double.tryParse(v.toString().replaceAll(',', '.'));
  }

  static int? _toIntOrNull(dynamic v) {
    if (v == null) return null;
    if (v is int) return v;
    if (v is num) return v.toInt();
    return int.tryParse(v.toString());
  }

  factory InvoiceItem.fromJson(Map<String, dynamic> json) {
    return InvoiceItem(
      id: json['id']?.toString() ?? DateTime.now().millisecondsSinceEpoch.toString(),
      rawName: json['raw_name']?.toString() ?? json['name']?.toString() ?? '',
      quantity: _toDoubleOrNull(json['quantity']) ?? 1.0,
      unit: json['unit']?.toString() ?? 'шт',
      buyPrice: _toDoubleOrNull(json['buy_price']) ?? 0.0,
      totalPrice: _toDoubleOrNull(json['total_price']) ?? 0.0,
      barcode: json['barcode']?.toString(),
      matchedProductId: _toIntOrNull(json['matched_product_id']),
      matchedProductName: json['matched_product_name']?.toString(),
      matchedBarcode: json['matched_barcode']?.toString(),
      currentRetailPrice: _toDoubleOrNull(json['current_retail_price']),
      lastBuyPrice: _toDoubleOrNull(json['last_buy_price']),
      matchConfidence: _toDoubleOrNull(json['match_confidence']) ?? 0.0,
      verifiedQuantity: _toDoubleOrNull(json['verified_quantity']) ?? 0.0,
      defectiveQuantity: _toDoubleOrNull(json['defective_quantity']) ?? 0.0,
      defectNotes: json['defect_notes']?.toString(),
      status: ItemStatus.values.firstWhere(
        (e) => e.name == json['status']?.toString(),
        orElse: () => ItemStatus.pending,
      ),
      isPieceBreakdown: json['is_piece_breakdown'] == true || json['is_piece_breakdown'] == 1,
      unitsPerPackage: _toDoubleOrNull(json['units_per_package']),
      packageQuantity: _toDoubleOrNull(json['package_quantity']),
      packageBuyPrice: _toDoubleOrNull(json['package_buy_price']),
      pieceBarcode: json['piece_barcode']?.toString(),
    );
  }
}
