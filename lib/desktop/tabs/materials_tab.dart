import 'package:flutter/material.dart';

import 'package:bismillah_constructions/shared/core/constants.dart';
import 'package:bismillah_constructions/mobile/features/manage/material_types_screen.dart';
import 'package:bismillah_constructions/mobile/features/reports/material_price_trend_screen.dart';
import 'package:bismillah_constructions/mobile/features/transactions/transaction_form_screen.dart';
import 'package:bismillah_constructions/desktop/widgets/tab_screen_host.dart';

class MaterialsTab extends StatelessWidget {
  const MaterialsTab({super.key});

  @override
  Widget build(BuildContext context) {
    return TabScreenHost(
      screens: [
        SubScreen(Icons.shopping_cart_outlined, 'Material Buy (Credit)',
            (reset) =>
                TransactionFormScreen(kind: TxnKind.materialBuy, onSaved: reset)),
        SubScreen(Icons.point_of_sale_outlined, 'Material Buy (Counter)',
            (reset) => TransactionFormScreen(
                kind: TxnKind.materialCounter, onSaved: reset)),
        SubScreen(Icons.category_outlined, 'Material Types',
            (_) => const MaterialTypesScreen()),
        SubScreen(Icons.show_chart_outlined, 'Price Trend',
            (_) => const MaterialPriceTrendScreen()),
      ],
    );
  }
}
