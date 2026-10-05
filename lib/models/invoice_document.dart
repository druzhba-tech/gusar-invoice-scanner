import 'invoice_item.dart';

enum DocumentStatus {
  draft,        // Распознан / черновик
  matching,     // Этап привязки номенклатуры
  verifying,    // Физическая сверка коробок
  hasDiscrepancy, // Имеются расхождения / брак
  approved,     // Готов к отправке
  synced,       // Успешно оприходован в gusar.tj
}

class InvoiceDocument {
  String id;
  int storeId;
  int? supplierId;
  String supplierName;
  String invoiceNumber;
  DateTime invoiceDate;
  double totalAmount;
  double paidAmount;
  List<InvoiceItem> items;
  List<String> pagePhotos;
  String? driverSignaturePath;
  List<String> discrepancyPhotos;
  DocumentStatus status;
  bool isSynchronized;
  DateTime createdAt;

  InvoiceDocument({
    required this.id,
    required this.storeId,
    this.supplierId,
    required this.supplierName,
    required this.invoiceNumber,
    required this.invoiceDate,
    required this.totalAmount,
    this.paidAmount = 0.0,
    required this.items,
    this.pagePhotos = const [],
    this.driverSignaturePath,
    this.discrepancyPhotos = const [],
    this.status = DocumentStatus.draft,
    this.isSynchronized = false,
    DateTime? createdAt,
  }) : createdAt = createdAt ?? DateTime.now();

  double get calculatedTotal {
    return items.fold(0.0, (sum, item) => sum + item.totalPrice);
  }

  bool get isTotalConsistent {
    if (totalAmount <= 0) return true;
    return (calculatedTotal - totalAmount).abs() < 0.2;
  }

  int get unmatchedCount => items.where((i) => i.matchedProductId == null).length;
  int get matchedCount => items.where((i) => i.matchedProductId != null).length;
  int get priceSpikeCount => items.where((i) => i.hasPriceSpike).length;
  int get mathErrorCount => items.where((i) => !i.isMathValid).length;
  int get discrepancyCount => items.where((i) => i.defectiveQuantity > 0 || (i.verifiedQuantity > 0 && i.verifiedQuantity != i.quantity)).length;

  bool get isReadyToReceive => unmatchedCount == 0 && mathErrorCount == 0;

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'store_id': storeId,
      'supplier_id': supplierId,
      'supplier_name': supplierName,
      'invoice_number': invoiceNumber,
      'invoice_date': invoiceDate.toIso8601String(),
      'total_amount': totalAmount,
      'paid_amount': paidAmount,
      'items': items.map((i) => i.toJson()).toList(),
      'page_photos': pagePhotos,
      'driver_signature_path': driverSignaturePath,
      'discrepancy_photos': discrepancyPhotos,
      'status': status.name,
      'is_synchronized': isSynchronized ? 1 : 0,
      'created_at': createdAt.toIso8601String(),
    };
  }

  factory InvoiceDocument.fromJson(Map<String, dynamic> json) {
    return InvoiceDocument(
      id: json['id'] ?? '',
      storeId: json['store_id'] ?? 1,
      supplierId: json['supplier_id'],
      supplierName: json['supplier_name'] ?? 'Неизвестный поставщик',
      invoiceNumber: json['invoice_number'] ?? 'б/н',
      invoiceDate: json['invoice_date'] != null 
          ? DateTime.tryParse(json['invoice_date']) ?? DateTime.now() 
          : DateTime.now(),
      totalAmount: (json['total_amount'] as num?)?.toDouble() ?? 0.0,
      paidAmount: (json['paid_amount'] as num?)?.toDouble() ?? 0.0,
      items: (json['items'] as List<dynamic>?)
              ?.map((item) => InvoiceItem.fromJson(item))
              .toList() ?? [],
      pagePhotos: List<String>.from(json['page_photos'] ?? []),
      driverSignaturePath: json['driver_signature_path'],
      discrepancyPhotos: List<String>.from(json['discrepancy_photos'] ?? []),
      status: DocumentStatus.values.firstWhere(
        (e) => e.name == json['status'],
        orElse: () => DocumentStatus.draft,
      ),
      isSynchronized: json['is_synchronized'] == 1 || json['is_synchronized'] == true,
      createdAt: json['created_at'] != null 
          ? DateTime.tryParse(json['created_at']) ?? DateTime.now() 
          : DateTime.now(),
    );
  }
}
