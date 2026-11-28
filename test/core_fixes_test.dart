import 'package:flutter_test/flutter_test.dart';
import 'package:gusar_invoice_scanner/models/invoice_document.dart';
import 'package:gusar_invoice_scanner/models/invoice_item.dart';
import 'package:gusar_invoice_scanner/models/product.dart';
import 'package:gusar_invoice_scanner/screens/barcode_verifier_screen.dart';
import 'package:gusar_invoice_scanner/services/api_service.dart';
import 'package:gusar_invoice_scanner/services/matching_service.dart';
import 'package:gusar_invoice_scanner/services/ocr_service.dart';

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

  group('Gemini Vision OCR Pipeline Guards (v1.4.46)', () {
    test('detects accurate MIME types for PDF, PNG, WebP and JPEG invoices', () {
      expect(detectInvoiceMimeType('/storage/emulated/0/inv.PDF'), 'application/pdf');
      expect(detectInvoiceMimeType('/tmp/scan.png'), 'image/png');
      expect(detectInvoiceMimeType('/tmp/scan.webp'), 'image/webp');
      expect(detectInvoiceMimeType('/tmp/photo.jpg'), 'image/jpeg');
    });

    test('skips Gemini thought blocks and extracts JSON response part cleanly', () {
      final response = {
        'candidates': [
          {
            'content': {
              'parts': [
                {'thought': true, 'text': 'Let me analyze the table carefully...'},
                {'text': '{"supplier_name":"ООО Тест","items":[{"name":"Сок Добрый","quantity":6,"buy_price":10,"total_price":60}]}'},
              ]
            }
          }
        ]
      };
      final extracted = extractGeminiResponseText(response);
      expect(extracted, contains('"supplier_name":"ООО Тест"'));
      expect(extracted, isNot(contains('Let me analyze')));
    });

    test('candidate Gemini model list excludes retired 2.5-flash and includes active 3.x models', () {
      expect(kGeminiInvoiceModels, isNot(contains('gemini-2.5-flash')));
      expect(kGeminiInvoiceModels, contains('gemini-3.5-flash-lite'));
      expect(kGeminiInvoiceModels, contains('gemini-3.1-flash-lite'));
    });
  });

  group('Per-Store Sequential Invoice Numbering & Date Guard (v1.4.49)', () {
    test('extractStrictSequentialInvoiceNumber accepts only pure integer numbers and ignores fallback IDs', () {
      expect(extractStrictSequentialInvoiceNumber('13'), 13);
      expect(extractStrictSequentialInvoiceNumber(' 15 '), 15);
      expect(extractStrictSequentialInvoiceNumber('№ 1502'), isNull);
      expect(extractStrictSequentialInvoiceNumber('Вх-25'), isNull);
      expect(extractStrictSequentialInvoiceNumber('20261128'), isNull);
      expect(extractStrictSequentialInvoiceNumber('0'), isNull);
    });

    test('sanitizeOcrInvoiceDate rejects stale years like 2024-01-01 and preserves recent dates', () {
      final now = DateTime(2026, 11, 28, 12, 0);
      expect(sanitizeOcrInvoiceDate(DateTime(2024, 1, 1), now: now), now);
      expect(sanitizeOcrInvoiceDate(DateTime(2030, 1, 1), now: now), now);
      final yesterday = DateTime(2026, 11, 27, 15, 0);
      expect(sanitizeOcrInvoiceDate(yesterday, now: now), yesterday);
    });

    test('InvoiceDocument preserves optional accountUsername for multi-account isolation', () {
      final doc = InvoiceDocument.fromJson({
        'id': 'doc_1',
        'store_id': 3,
        'account_username': 'testadmin',
        'items': [],
      });
      expect(doc.accountUsername, 'testadmin');
      expect(doc.toJson()['account_username'], 'testadmin');
    });
  });
}
