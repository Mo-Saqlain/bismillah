import 'package:bismillah_constructions/shared/data/repositories/ledger_repository.dart';

enum PayableReceivableDirection {
  payable,
  receivable,
}

enum PayableReceivableCategory {
  supplierPayable,
  projectReceivable,
  supplierOverpayment,
  counterReceivable,
  counterPayable,
}

extension PayableReceivableCategoryX on PayableReceivableCategory {
  String get label {
    switch (this) {
      case PayableReceivableCategory.supplierPayable:
        return 'Supplier Payable';
      case PayableReceivableCategory.projectReceivable:
        return 'Project Receivable';
      case PayableReceivableCategory.supplierOverpayment:
        return 'Supplier Overpayment';
      case PayableReceivableCategory.counterReceivable:
        return 'Informal Receivable';
      case PayableReceivableCategory.counterPayable:
        return 'Informal Payable';
    }
  }

  PayableReceivableDirection get direction {
    switch (this) {
      case PayableReceivableCategory.supplierPayable:
      case PayableReceivableCategory.counterPayable:
        return PayableReceivableDirection.payable;
      case PayableReceivableCategory.projectReceivable:
      case PayableReceivableCategory.supplierOverpayment:
      case PayableReceivableCategory.counterReceivable:
        return PayableReceivableDirection.receivable;
    }
  }
}

class PayableReceivableItem {
  final String id;
  final String targetId;
  final String name;
  final PayableReceivableCategory category;
  final double amount;
  final double bucket0_30;
  final double bucket31_60;
  final double bucket61_90;
  final double bucket90Plus;
  final DateTime createdAt;
  final String? phone;

  const PayableReceivableItem({
    required this.id,
    required this.targetId,
    required this.name,
    required this.category,
    required this.amount,
    required this.bucket0_30,
    required this.bucket31_60,
    required this.bucket61_90,
    required this.bucket90Plus,
    required this.createdAt,
    this.phone,
  });

  PayableReceivableDirection get direction => category.direction;

  bool get isPayable => direction == PayableReceivableDirection.payable;
  bool get isReceivable => direction == PayableReceivableDirection.receivable;

  bool get isOverdue => bucket31_60 > 0 || bucket61_90 > 0 || bucket90Plus > 0;

  String get oldestAgeLabel {
    if (bucket90Plus > 0) return '90+ Days';
    if (bucket61_90 > 0) return '61-90 Days';
    if (bucket31_60 > 0) return '31-60 Days';
    return '0-30 Days';
  }

  factory PayableReceivableItem.fromAgingLine({
    required AgingLine line,
    required String name,
    required PayableReceivableCategory category,
    String? phone,
  }) {
    return PayableReceivableItem(
      id: '${category.name}_${line.partyId}',
      targetId: line.partyId,
      name: name,
      category: category,
      amount: line.total,
      bucket0_30: line.bucket0_30,
      bucket31_60: line.bucket31_60,
      bucket61_90: line.bucket61_90,
      bucket90Plus: line.bucket90Plus,
      createdAt: DateTime.now(),

      phone: phone,
    );
  }
}
