// Tests for the two v18/v19 features:
//   * Labour-Rate service fee as a fixed amount vs a percentage of spend.
//   * WhatsApp number normalization for the wa.me deep link.
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:bismillah_constructions/shared/core/constants.dart';
import 'package:bismillah_constructions/shared/core/whatsapp.dart';
import 'package:bismillah_constructions/shared/data/db/local_db.dart';
import 'package:bismillah_constructions/shared/data/repositories/entity_repository.dart';
import 'package:bismillah_constructions/shared/data/repositories/ledger_repository.dart';

late Database _db;
late EntityRepository _entityRepo;
late LedgerRepository _ledgerRepo;

Future<void> _resetDb() async {
  _db = await databaseFactoryFfi.openDatabase(
    inMemoryDatabasePath,
    options: OpenDatabaseOptions(
      version: 5,
      onConfigure: (db) => db.execute('PRAGMA foreign_keys = ON'),
    ),
  );
  await LocalDb.instance.applySchemaForTests(_db);
  await _db.insert('app_settings',
      {'key': 'device_id', 'value': 'test-device'},
      conflictAlgorithm: ConflictAlgorithm.replace);
  _entityRepo = EntityRepository(_db);
  _ledgerRepo = LedgerRepository(_db);
}

void main() {
  setUpAll(() => sqfliteFfiInit());
  setUp(_resetDb);
  tearDown(() async => _db.close());

  group('Service fee: fixed vs percentage', () {
    test('fixed fee is flat regardless of spend; customer owes the shortfall',
        () async {
      final sId = (await _entityRepo.createSupplier(name: 'Workforce')).id;
      final pId = (await _entityRepo.createProject(
        name: 'LR Fixed',
        model: ProjectModel.labourRate,
        serviceFeeType: ServiceFeeType.fixed,
        serviceFeeAmount: 500000,
      ))
          .id;
      // Customer pays 1,000,000; 600,000 spent on labour.
      await _ledgerRepo.postReceiveFromProject(
          amount: 1000000, projectId: pId, receivedInto: Accounts.cash);
      await _ledgerRepo.postLabourPayment(
          amount: 600000,
          projectId: pId,
          supplierId: sId,
          paidFrom: Accounts.cash);

      final close = await _ledgerRepo.labourRateCloseSummary(
        pId,
        feeType: ServiceFeeType.fixed,
        feeAmount: 500000,
      );
      expect(close.serviceFee, 500000, reason: 'flat fee, ignores spend');
      // (1,000,000 − 500,000) − 600,000 = −100,000 → customer still owes.
      expect(close.netToSettle, -100000);
      expect(close.customerOwesUs, 100000);
    });

    test('percentage fee scales with spend', () async {
      final sId = (await _entityRepo.createSupplier(name: 'Workforce')).id;
      final pId = (await _entityRepo.createProject(
        name: 'LR Pct',
        model: ProjectModel.labourRate,
        serviceFeePercent: 10,
      ))
          .id;
      await _ledgerRepo.postReceiveFromProject(
          amount: 1100, projectId: pId, receivedInto: Accounts.cash);
      await _ledgerRepo.postLabourPayment(
          amount: 1000,
          projectId: pId,
          supplierId: sId,
          paidFrom: Accounts.cash);

      final close = await _ledgerRepo.labourRateCloseSummary(
        pId,
        feeType: ServiceFeeType.percent,
        feePercent: 10,
      );
      expect(close.serviceFee, 100, reason: '10% of 1000 spent');
      expect(close.netToSettle, 0, reason: '(1100−100)−1000 == 0');
    });

    test('Project.serviceFeeOn honours the configured type', () async {
      final fixed = await _entityRepo.createProject(
        name: 'f',
        model: ProjectModel.labourRate,
        serviceFeeType: ServiceFeeType.fixed,
        serviceFeeAmount: 500000,
      );
      expect(fixed.serviceFeeOn(999999), 500000);

      final pct = await _entityRepo.createProject(
        name: 'p',
        model: ProjectModel.labourRate,
        serviceFeePercent: 5,
      );
      expect(pct.serviceFeeOn(200000), 10000);
    });

    test('service fee type round-trips through the projects table', () async {
      final id = (await _entityRepo.createProject(
        name: 'rt',
        model: ProjectModel.labourRate,
        serviceFeeType: ServiceFeeType.fixed,
        serviceFeeAmount: 750000,
      ))
          .id;
      final loaded = await _entityRepo.project(id);
      expect(loaded!.serviceFeeType, ServiceFeeType.fixed);
      expect(loaded.serviceFeeAmount, 750000);
    });
  });

  group('WhatsApp number normalization', () {
    test('Pakistani local + international forms map to 92XXXXXXXXXX', () {
      expect(normalizeWhatsAppNumber('0300 1234567'), '923001234567');
      expect(normalizeWhatsAppNumber('+92 300 1234567'), '923001234567');
      expect(normalizeWhatsAppNumber('0092-300-1234567'), '923001234567');
      expect(normalizeWhatsAppNumber('3001234567'), '923001234567');
      expect(normalizeWhatsAppNumber('923001234567'), '923001234567');
    });

    test('blank / null yields null (prompt is skipped)', () {
      expect(normalizeWhatsAppNumber(''), isNull);
      expect(normalizeWhatsAppNumber('   '), isNull);
      expect(normalizeWhatsAppNumber(null), isNull);
    });
  });

  group('WhatsApp deep-link generation', () {
    test('builds a wa.me link with normalized number + encoded message', () {
      const message =
          'Bismillah Constructions\n\nMaterial Buy (Credit): Rs 50,000\n'
          'Project: Kamran House';
      final uri = whatsAppUri(number: '0300 1234567', message: message);

      expect(uri, isNotNull);
      expect(uri!.scheme, 'https');
      expect(uri.host, 'wa.me');
      expect(uri.path, '/923001234567');
      // The message round-trips through URL decoding (newlines, spaces,
      // commas all survive) — WhatsApp opens pre-filled with exactly it.
      expect(uri.queryParameters['text'], message);
      // And it is actually percent-encoded on the wire.
      expect(uri.toString(), startsWith('https://wa.me/923001234567?text='));
      expect(uri.toString(), contains('%0A')); // newline encoded
    });

    test('returns null when the number is unusable (prompt is skipped)', () {
      expect(whatsAppUri(number: '   ', message: 'x'), isNull);
    });
  });
}
