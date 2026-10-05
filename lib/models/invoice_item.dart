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
  });

  bool get isMathValid {
    final expectedTotal = quantity * buyPrice;
    return (expectedTotal - totalPrice).abs() < 0.1;
  }

  double? get priceChangePercent {
    if (lastBuyPrice == null || lastBuyPrice! <= 0) return null;
    return ((buyPrice - lastBuyPrice!) / lastBuyPrice!) * 100.0;
  }

  bool get hasPriceSpike {
    final change = priceChangePercent;
    return change != null && change > 5.0; // Подорожание больше 5%
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
    };
  }

  factory InvoiceItem.fromJson(Map<String, dynamic> json) {
    return InvoiceItem(
      id: json['id'] ?? DateTime.now().millisecondsSinceEpoch.toString(),
      rawName: json['raw_name'] ?? '',
      quantity: (json['quantity'] as num?)?.toDouble() ?? 1.0,
      unit: json['unit'] ?? 'шт',
      buyPrice: (json['buy_price'] as num?)?.toDouble() ?? 0.0,
      totalPrice: (json['total_price'] as num?)?.toDouble() ?? 0.0,
      barcode: json['barcode'],
      matchedProductId: json['matched_product_id'],
      matchedProductName: json['matched_product_name'],
      matchedBarcode: json['matched_barcode'],
      currentRetailPrice: (json['current_retail_price'] as num?)?.toDouble(),
      lastBuyPrice: (json['last_buy_price'] as num?)?.toDouble(),
      matchConfidence: (json['match_confidence'] as num?)?.toDouble() ?? 0.0,
      verifiedQuantity: (json['verified_quantity'] as num?)?.toDouble() ?? 0.0,
      defectiveQuantity: (json['defective_quantity'] as num?)?.toDouble() ?? 0.0,
      defectNotes: json['defect_notes'],
      status: ItemStatus.values.firstWhere(
        (e) => e.name == json['status'],
        orElse: () => ItemStatus.pending,
      ),
    );
  }
}
