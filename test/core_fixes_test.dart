import 'package:flutter_test/flutter_test.dart';
import 'package:gusar_invoice_scanner/models/invoice_document.dart';
import 'package:gusar_invoice_scanner/models/invoice_item.dart';
import 'package:gusar_invoice_scanner/models/product.dart';
import 'package:gusar_invoice_scanner/screens/barcode_verifier_screen.dart';
import 'package:gusar_invoice_scanner/services/matching_service.dart';

void main() {
  group('Scale Barcode Verifier (Store #3 & #2 EAN-13 20/00 formats)', () {
    test('parses 13-digit prefix-20 variable weight barcode', () {
      final info = parseScaleBarcode('2000001005004');
      expect(info.isScale, isTrue);
      expect(info.prefix7, '2000001');
      expect(info.plu5, '00001');
      expect(info.pluNum, 1);
      expect(info.weightKg, closeTo(0.5, 0.0001));
    });

    test('parses 13-digit prefix-00 variable weight barcode', () {
      final info = parseScaleBarcode('0000012012500');
      expect(info.isScale, isTrue);
      expect(info.prefix7, '0000012');
      expect(info.pluNum, 12);
      expect(info.weightKg, closeTo(1.25, 0.0001));
    });

    test('ignores standard retail EAN-13 barcode', () {
      final info = parseScaleBarcode('5449000000996');
      expect(info.isScale, isFalse);
      expect(info.weightKg, isNull);
    });

    test('matches live weighed label against 7-digit internal barcode 2000001', () {
      final item = InvoiceItem(
        id: '1',
        rawName: 'Бодом колифор',
        quantity: 20,
        unit: 'кг',
        buyPrice: 100,
        totalPrice: 2000,
        matchedBarcode: '2000001',
      );
      final info = parseScaleBarcode('2000001005004');
      expect(matchesInvoiceItemBarcode(item, '2000001005004', info), isTrue);

      final wrongInfo = parseScaleBarcode('2000002005003');
      expect(matchesInvoiceItemBarcode(item, '2000002005003', wrongInfo), isFalse);
    });
  });

  group('Model store_id default consistency', () {
    test('InvoiceDocument and Product default storeId to 3 when missing', () {
      final doc = InvoiceDocument.fromJson({'id': 'inv1', 'items': []});
      expect(doc.storeId, 3);
      expect(doc.paymentSource, 'cash_drawer');

      final bankDoc = InvoiceDocument.fromJson({
        'id': 'inv2',
        'store_id': 3,
        'payment_source': 'bank',
        'items': [],
      });
      expect(bankDoc.paymentSource, 'bank');
      expect(bankDoc.toJson()['payment_source'], 'bank');

      final prod = Product.fromJson({'id': 40572, 'name': 'Бодом колифор', 'price': 120});
      expect(prod.storeId, 3);
    });
  });

  group('TJ/RU Phonetic Normalization & Smart Matching', () {
    test('normalizes Russian/Tajik spelling variants cleanly', () {
      expect(normalizeProductNameForMatch('сок добрий'), normalizeProductNameForMatch('Сок Добрый'));
      expect(normalizeProductNameForMatch('Сок яблочний добрий'), normalizeProductNameForMatch('Сок Яблочный Добрый'));
      expect(normalizeProductNameForMatch('Шӯрбои Ғӯсарӣ'), 'шурбои гусари');
    });

    test('ranks "Сок Добрый Яблочный" at top for "сок добрий" without blind auto-locking across flavors', () {
      final matcher = MatchingService();
      final catalog = [
        Product(id: 5001, storeId: 3, name: 'Сок Добрый Яблочный 1л', price: 14),
        Product(id: 5002, storeId: 3, name: 'Сок Добрый Персик 1л', price: 14),
        Product(id: 5003, storeId: 3, name: 'Молоко 1л', price: 12),
      ];
      final cands = matcher.getCandidates('сок добрий', catalog, storeId: 3);
      expect(cands.length, 2);
      expect(cands.first.product.name, contains('Сок Добрый'));
      expect(cands.first.score, lessThan(0.85)); // Never blindly auto-lock ambiguous flavor!
    });
  });
}
