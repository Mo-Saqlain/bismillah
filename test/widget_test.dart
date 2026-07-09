import 'package:flutter_test/flutter_test.dart';

import 'package:bismillah_constructions/core/constants.dart';

void main() {
  test('Chart of accounts is well-formed', () {
    final ids = Accounts.all.map((a) => a.id).toList();
    expect(ids.toSet().length, ids.length, reason: 'Account IDs are unique');
    expect(Accounts.byId(Accounts.cash.id), Accounts.cash);
    expect(Accounts.systemCashLike, contains(Accounts.cash));
  });

  test('Canonical transaction kinds all have label + blurb', () {
    expect(TxnKind.values, isNotEmpty);
    for (final k in TxnKind.values) {
      expect(k.label, isNotEmpty);
      expect(k.blurb, isNotEmpty);
    }
  });
}
