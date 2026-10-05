class Supplier {
  final int id;
  final int storeId;
  final String name;
  final String? contact;
  final String? address;
  final double balance;

  Supplier({
    required this.id,
    required this.storeId,
    required this.name,
    this.contact,
    this.address,
    this.balance = 0.0,
  });

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'store_id': storeId,
      'name': name,
      'contact': contact,
      'address': address,
      'balance': balance,
    };
  }

  factory Supplier.fromJson(Map<String, dynamic> json) {
    return Supplier(
      id: json['id'] is int ? json['id'] : int.tryParse(json['id'].toString()) ?? 0,
      storeId: json['store_id'] is int ? json['store_id'] : int.tryParse(json['store_id'].toString()) ?? 1,
      name: json['name'] ?? '',
      contact: json['contact']?.toString(),
      address: json['address']?.toString(),
      balance: (json['balance'] as num?)?.toDouble() ?? 0.0,
    );
  }
}
