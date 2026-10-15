class Supplier {
  final int id;
  final int storeId;
  final String name;
  final String? contact;
  final String? inn;
  final String? address;
  final double balance;

  Supplier({
    required this.id,
    required this.storeId,
    required this.name,
    this.contact,
    this.inn,
    this.address,
    this.balance = 0.0,
  });

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'store_id': storeId,
      'name': name,
      'contact': contact,
      'inn': inn,
      'address': address,
      'balance': balance,
    };
  }

  factory Supplier.fromJson(Map<String, dynamic> json) {
    final rawId = json['id'] ?? json['supplier_id'] ?? json['contractor_id'];
    final id = rawId is int ? rawId : int.tryParse(rawId?.toString() ?? '0') ?? 0;

    final rawStoreId = json['store_id'] ?? json['storeId'];
    final storeId = rawStoreId is int ? rawStoreId : int.tryParse(rawStoreId?.toString() ?? '0') ?? 0;

    final name = json['name']?.toString() ??
        json['supplier_name']?.toString() ??
        json['title']?.toString() ??
        json['company_name']?.toString() ??
        json['contractor']?.toString() ??
        json['company']?.toString() ??
        json['fullname']?.toString() ??
        json['full_name']?.toString() ??
        json['legal_name']?.toString() ??
        'Контрагент #$id';

    final contact = json['contact']?.toString() ??
        json['phone']?.toString() ??
        json['mobile']?.toString() ??
        json['tel']?.toString() ??
        json['phone_number']?.toString();

    final inn = json['inn']?.toString() ?? json['tin']?.toString() ?? json['tax_id']?.toString();

    final address = json['address']?.toString() ?? json['city']?.toString() ?? json['legal_address']?.toString();

    final rawBalance = json['balance'] ?? json['debt'] ?? 0.0;
    final balance = (rawBalance is num) ? rawBalance.toDouble() : double.tryParse(rawBalance.toString()) ?? 0.0;

    return Supplier(
      id: id,
      storeId: storeId,
      name: name.trim(),
      contact: contact?.trim(),
      inn: inn?.trim(),
      address: address?.trim(),
      balance: balance,
    );
  }
}
