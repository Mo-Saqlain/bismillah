import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:bismillah_constructions/shared/core/constants.dart';
import 'package:bismillah_constructions/shared/data/models/counter_entity.dart';
import 'package:bismillah_constructions/shared/data/models/party.dart';
import 'package:bismillah_constructions/shared/data/models/payable_receivable_item.dart';
import 'package:bismillah_constructions/shared/data/models/project.dart';
import 'package:bismillah_constructions/shared/providers/db_providers.dart';


class PayablesReceivablesBundle {
  final List<PayableReceivableItem> items;
  final double totalReceivables;
  final double totalPayables;
  final double netPosition;
  final int overdueCount;
  final int stale90Count;
  final List<Party> suppliers;
  final List<Project> projects;
  final List<CounterEntity> counterEntities;

  const PayablesReceivablesBundle({
    required this.items,
    required this.totalReceivables,
    required this.totalPayables,
    required this.netPosition,
    required this.overdueCount,
    required this.stale90Count,
    required this.suppliers,
    required this.projects,
    required this.counterEntities,
  });
}

final payablesReceivablesProvider =
    FutureProvider<PayablesReceivablesBundle>((ref) async {
  ref.watch(ledgerVersionProvider);
  final ledger = await ref.watch(ledgerRepoProvider.future);
  final entityRepo = await ref.watch(entityRepoProvider.future);

  final payablesAging = await ledger.aging(
    partyAccountId: Accounts.supplierPayables.id,
  );
  final projectRecvAging = await ledger.agingProjectReceivables();
  final supplierOverpayAging = await ledger.agingSupplierOverpayment();

  final suppliers = await entityRepo.suppliers(includeArchived: true);
  final projects = await entityRepo.projects(includeArchived: true);
  final counterEntities = await entityRepo.counterEntities();

  final supplierMap = {for (final s in suppliers) s.id: s};
  final projectMap = {for (final p in projects) p.id: p};

  final items = <PayableReceivableItem>[];
  final now = DateTime.now();

  // 1. Supplier Trade Payables
  for (final line in payablesAging.lines) {
    final supplier = supplierMap[line.partyId];
    final name = supplier?.name ?? 'Supplier ${line.partyId.substring(0, 6)}';
    items.add(PayableReceivableItem.fromAgingLine(
      line: line,
      name: name,
      category: PayableReceivableCategory.supplierPayable,
      phone: supplier?.phone,
    ));
  }

  // 2. Project Receivables
  for (final line in projectRecvAging.lines) {
    final project = projectMap[line.partyId];
    final name = project?.name ?? 'Project ${line.partyId.substring(0, 6)}';
    items.add(PayableReceivableItem.fromAgingLine(
      line: line,
      name: name,
      category: PayableReceivableCategory.projectReceivable,
      phone: project?.whatsapp,
    ));
  }

  // 3. Supplier Overpayments
  for (final line in supplierOverpayAging.lines) {
    final supplier = supplierMap[line.partyId];
    final name = supplier?.name ?? 'Supplier ${line.partyId.substring(0, 6)}';
    items.add(PayableReceivableItem.fromAgingLine(
      line: line,
      name: name,
      category: PayableReceivableCategory.supplierOverpayment,
      phone: supplier?.phone,
    ));
  }

  // 4. Counter Entities (Informal Receivables & Payables)
  for (final c in counterEntities) {
    if (c.amount <= 0.005) continue;
    final days = now.difference(c.createdAt).inDays;
    double b0 = 0, b30 = 0, b60 = 0, b90 = 0;
    if (days <= 30) {
      b0 = c.amount;
    } else if (days <= 60) {
      b30 = c.amount;
    } else if (days <= 90) {
      b60 = c.amount;
    } else {
      b90 = c.amount;
    }

    final cat = c.type == CounterEntityType.receivable
        ? PayableReceivableCategory.counterReceivable
        : PayableReceivableCategory.counterPayable;

    items.add(PayableReceivableItem(
      id: 'counter_${c.id}',
      targetId: c.id,
      name: c.name,
      category: cat,
      amount: c.amount,
      bucket0_30: b0,
      bucket31_60: b30,
      bucket61_90: b60,
      bucket90Plus: b90,
      createdAt: c.createdAt,
    ));
  }

  // Calculate Aggregates
  double totalRecv = 0;
  double totalPay = 0;
  int overdueCount = 0;
  int stale90Count = 0;

  for (final item in items) {
    if (item.isReceivable) {
      totalRecv += item.amount;
    } else {
      totalPay += item.amount;
    }
    if (item.isOverdue) {
      overdueCount++;
    }
    if (item.bucket90Plus > 0) {
      stale90Count++;
    }
  }

  items.sort((a, b) => b.amount.compareTo(a.amount));

  return PayablesReceivablesBundle(
    items: items,
    totalReceivables: totalRecv,
    totalPayables: totalPay,
    netPosition: totalRecv - totalPay,
    overdueCount: overdueCount,
    stale90Count: stale90Count,
    suppliers: suppliers,
    projects: projects,
    counterEntities: counterEntities,
  );
});
