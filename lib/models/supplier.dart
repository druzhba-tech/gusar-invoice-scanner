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
    return Supplier(
      id: json['id'] is int ? json['id'] as int : int.tryParse(json['id']?.toString() ?? '0') ?? 0,
      storeId: json['store_id'] is int ? json['store_id'] as int : int.tryParse(json['store_id']?.toString() ?? '1') ?? 1,
      name: json['name']?.toString() ??
          json['title']?.toString() ??
          json['company_name']?.toString() ??
          json['contractor']?.toString() ??
          'Контрагент #${json['id'] ?? ''}',
      contact: json['contact']?.toString() ?? json['phone']?.toString() ?? json['mobile']?.toString(),
      inn: json['inn']?.toString() ?? json['tin']?.toString(),
      address: json['address']?.toString() ?? json['city']?.toString(),
      balance: (json['balance'] as num?)?.toDouble() ?? 0.0,
    );
  }
}
