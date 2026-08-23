import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:bismillah_constructions/mobile/features/followups/followups_screen.dart';

import 'package:bismillah_constructions/mobile/features/reports/project_ledger_screen.dart';

import 'package:bismillah_constructions/mobile/features/reports/supplier_ledger_screen.dart';
import 'package:bismillah_constructions/shared/core/export/csv_export.dart';
import 'package:bismillah_constructions/shared/core/formatters.dart';
import 'package:bismillah_constructions/shared/core/whatsapp.dart';
import 'package:bismillah_constructions/shared/data/models/payable_receivable_item.dart';
import 'package:bismillah_constructions/shared/providers/providers.dart';

enum _DirectionFilter { all, receivablesOnly, payablesOnly, suppliersOnly, projectsOnly, counterOnly }
enum _AgingFilter { all, bucket0_30, bucket31_60, bucket61_90, bucket90Plus }
enum _SortOption { amountHighToLow, amountLowToHigh, oldestFirst, nameAz }
enum _GroupOption { none, category, aging }

class PayablesReceivablesScreen extends ConsumerStatefulWidget {
  const PayablesReceivablesScreen({super.key});

  @override
  ConsumerState<PayablesReceivablesScreen> createState() =>
      _PayablesReceivablesScreenState();
}

class _PayablesReceivablesScreenState
    extends ConsumerState<PayablesReceivablesScreen> {
  _DirectionFilter _directionFilter = _DirectionFilter.all;
  _AgingFilter _agingFilter = _AgingFilter.all;
  _SortOption _sortOption = _SortOption.amountHighToLow;
  _GroupOption _groupOption = _GroupOption.none;
  String _searchQuery = '';

  final _searchController = TextEditingController();

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  Future<void> _exportCsv(PayablesReceivablesBundle bundle) async {
    final filtered = _getFilteredItems(bundle.items);
    final csv = CsvExport.build(
      headers: [
        'Party/Project Name',
        'Category',
        'Direction',
        '0-30 Days',
        '31-60 Days',
        '61-90 Days',
        '90+ Days',
        'Total Amount',
        'Phone/WhatsApp'
      ],
      rows: [
        for (final item in filtered)
          [
            item.name,
            item.category.label,
            item.isReceivable ? 'Receivable (Owed to Us)' : 'Payable (We Owe)',
            item.bucket0_30.toStringAsFixed(2),
            item.bucket31_60.toStringAsFixed(2),
            item.bucket61_90.toStringAsFixed(2),
            item.bucket90Plus.toStringAsFixed(2),
            item.amount.toStringAsFixed(2),
            item.phone ?? '',
          ],
      ],
    );

    await CsvExport.share(
      fileName: 'payables_receivables_${DateTime.now().millisecondsSinceEpoch}',
      csv: csv,
      subject: 'Consolidated Payables & Receivables Statement',
    );
  }

  List<PayableReceivableItem> _getFilteredItems(
      List<PayableReceivableItem> rawItems) {
    return rawItems.where((item) {
      // 1. Search Query Filter
      if (_searchQuery.isNotEmpty) {
        final q = _searchQuery.toLowerCase();
        final nameMatch = item.name.toLowerCase().contains(q);
        final catMatch = item.category.label.toLowerCase().contains(q);
        if (!nameMatch && !catMatch) return false;
      }

      // 2. Direction & Category Filter
      switch (_directionFilter) {
        case _DirectionFilter.all:
          break;
        case _DirectionFilter.receivablesOnly:
          if (!item.isReceivable) return false;
          break;
        case _DirectionFilter.payablesOnly:
          if (!item.isPayable) return false;
          break;
        case _DirectionFilter.suppliersOnly:
          if (item.category != PayableReceivableCategory.supplierPayable &&
              item.category != PayableReceivableCategory.supplierOverpayment) {
            return false;
          }
          break;
        case _DirectionFilter.projectsOnly:
          if (item.category != PayableReceivableCategory.projectReceivable) {
            return false;
          }
          break;
        case _DirectionFilter.counterOnly:
          if (item.category != PayableReceivableCategory.counterReceivable &&
              item.category != PayableReceivableCategory.counterPayable) {
            return false;
          }
          break;
      }

      // 3. Aging Filter
      switch (_agingFilter) {
        case _AgingFilter.all:
          break;
        case _AgingFilter.bucket0_30:
          if (item.bucket0_30 <= 0.005) return false;
          break;
        case _AgingFilter.bucket31_60:
          if (item.bucket31_60 <= 0.005) return false;
          break;
        case _AgingFilter.bucket61_90:
          if (item.bucket61_90 <= 0.005) return false;
          break;
        case _AgingFilter.bucket90Plus:
          if (item.bucket90Plus <= 0.005) return false;
          break;
      }

      return true;
    }).toList()
      ..sort((a, b) {
        switch (_sortOption) {
          case _SortOption.amountHighToLow:
            return b.amount.compareTo(a.amount);
          case _SortOption.amountLowToHigh:
            return a.amount.compareTo(b.amount);
          case _SortOption.oldestFirst:
            return a.createdAt.compareTo(b.createdAt);
          case _SortOption.nameAz:
            return a.name.toLowerCase().compareTo(b.name.toLowerCase());
        }
      });
  }

  void _showSortGroupOptions() {
    showModalBottomSheet(
      context: context,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (context) {
        return StatefulBuilder(
          builder: (context, setModalState) {
            return Padding(
              padding: const EdgeInsets.all(20),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Display & View Options',
                      style: Theme.of(context).textTheme.titleMedium?.copyWith(
                            fontWeight: FontWeight.bold,
                          )),
                  const SizedBox(height: 16),
                  const Text('Sort By',
                      style: TextStyle(fontWeight: FontWeight.w600)),
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      ChoiceChip(
                        label: const Text('Amount: High → Low'),
                        selected: _sortOption == _SortOption.amountHighToLow,
                        onSelected: (val) {
                          if (val) {
                            setState(() => _sortOption = _SortOption.amountHighToLow);
                            setModalState(() {});
                          }
                        },
                      ),
                      ChoiceChip(
                        label: const Text('Amount: Low → High'),
                        selected: _sortOption == _SortOption.amountLowToHigh,
                        onSelected: (val) {
                          if (val) {
                            setState(() => _sortOption = _SortOption.amountLowToHigh);
                            setModalState(() {});
                          }
                        },
                      ),
                      ChoiceChip(
                        label: const Text('Oldest First'),
                        selected: _sortOption == _SortOption.oldestFirst,
                        onSelected: (val) {
                          if (val) {
                            setState(() => _sortOption = _SortOption.oldestFirst);
                            setModalState(() {});
                          }
                        },
                      ),
                      ChoiceChip(
                        label: const Text('Name: A-Z'),
                        selected: _sortOption == _SortOption.nameAz,
                        onSelected: (val) {
                          if (val) {
                            setState(() => _sortOption = _SortOption.nameAz);
                            setModalState(() {});
                          }
                        },
                      ),
                    ],
                  ),
                  const SizedBox(height: 20),
                  const Text('Group Items By',
                      style: TextStyle(fontWeight: FontWeight.w600)),
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 8,
                    children: [
                      ChoiceChip(
                        label: const Text('Flat List (No Grouping)'),
                        selected: _groupOption == _GroupOption.none,
                        onSelected: (val) {
                          if (val) {
                            setState(() => _groupOption = _GroupOption.none);
                            setModalState(() {});
                          }
                        },
                      ),
                      ChoiceChip(
                        label: const Text('Group by Category'),
                        selected: _groupOption == _GroupOption.category,
                        onSelected: (val) {
                          if (val) {
                            setState(() => _groupOption = _GroupOption.category);
                            setModalState(() {});
                          }
                        },
                      ),
                      ChoiceChip(
                        label: const Text('Group by Aging Status'),
                        selected: _groupOption == _GroupOption.aging,
                        onSelected: (val) {
                          if (val) {
                            setState(() => _groupOption = _GroupOption.aging);
                            setModalState(() {});
                          }
                        },
                      ),
                    ],
                  ),
                  const SizedBox(height: 20),
                ],
              ),
            );
          },
        );
      },
    );
  }

  void _sendWhatsAppReminder(PayableReceivableItem item) async {
    if (item.phone == null || item.phone!.trim().isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('No phone/WhatsApp number on file for this party.')),
      );
      return;
    }

    final formattedAmt = fmtMoney(item.amount);
    final msg = item.isReceivable
        ? 'Assalam-o-Alaikum ${item.name}, soft reminder regarding outstanding payment of PKR $formattedAmt for ${item.name}.'
        : 'Assalam-o-Alaikum ${item.name}, regarding payable balance of PKR $formattedAmt.';

    final ok = await launchWhatsApp(number: item.phone!, message: msg);
    if (!ok && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Could not launch WhatsApp. Ensure WhatsApp is installed.')),
      );
    }
  }

  void _navigateToLedger(PayableReceivableItem item, PayablesReceivablesBundle bundle) {
    if (item.category == PayableReceivableCategory.supplierPayable ||
        item.category == PayableReceivableCategory.supplierOverpayment) {
      Navigator.push(
        context,
        MaterialPageRoute(
          builder: (_) => SupplierLedgerScreen(supplierId: item.targetId),
        ),
      );
    } else if (item.category == PayableReceivableCategory.projectReceivable) {
      final project = bundle.projects.firstWhere(
        (p) => p.id == item.targetId,
        orElse: () => bundle.projects.first,
      );
      Navigator.push(
        context,
        MaterialPageRoute(
          builder: (_) => ProjectLedgerScreen(project: project),
        ),
      );
    } else {
      Navigator.push(
        context,
        MaterialPageRoute(
          builder: (_) => const FollowUpsScreen(),

        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final bundleAsync = ref.watch(payablesReceivablesProvider);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Payables & Receivables Hub'),
        actions: [
          IconButton(
            icon: const Icon(Icons.tune),
            tooltip: 'View Options & Sorting',
            onPressed: _showSortGroupOptions,
          ),
          bundleAsync.maybeWhen(
            data: (bundle) => IconButton(
              icon: const Icon(Icons.file_download),
              tooltip: 'Export CSV',
              onPressed: () => _exportCsv(bundle),
            ),
            orElse: () => const SizedBox.shrink(),
          ),
        ],
      ),
      body: bundleAsync.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, st) => Center(child: Text('Error loading hub data: $e')),
        data: (bundle) {
          final filteredItems = _getFilteredItems(bundle.items);

          return Column(
            children: [
              _HeaderSummaryCard(
                totalReceivables: bundle.totalReceivables,
                totalPayables: bundle.totalPayables,
                netPosition: bundle.netPosition,
                overdueCount: bundle.overdueCount,
                stale90Count: bundle.stale90Count,
              ),
              _buildSearchBar(),
              _buildFilterChips(),
              Expanded(
                child: filteredItems.isEmpty
                    ? const Center(
                        child: Text(
                          'No payables or receivables match the selected filters.',
                          textAlign: TextAlign.center,
                          style: TextStyle(color: Colors.grey),
                        ),
                      )
                    : _buildItemsList(filteredItems, bundle),
              ),
            ],
          );
        },
      ),
    );
  }

  Widget _buildSearchBar() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      child: TextField(
        controller: _searchController,
        decoration: InputDecoration(
          hintText: 'Search by party or project name...',
          prefixIcon: const Icon(Icons.search, size: 20),
          suffixIcon: _searchQuery.isNotEmpty
              ? IconButton(
                  icon: const Icon(Icons.clear, size: 18),
                  onPressed: () {
                    _searchController.clear();
                    setState(() => _searchQuery = '');
                  },
                )
              : null,
          contentPadding: const EdgeInsets.symmetric(vertical: 8, horizontal: 12),
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(10),
          ),
          isDense: true,
        ),
        onChanged: (val) => setState(() => _searchQuery = val),
      ),
    );
  }

  Widget _buildFilterChips() {
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      child: Row(
        children: [
          // Direction Filters
          FilterChip(
            label: const Text('All'),
            selected: _directionFilter == _DirectionFilter.all,
            onSelected: (_) => setState(() => _directionFilter = _DirectionFilter.all),
          ),
          const SizedBox(width: 6),
          FilterChip(
            label: const Text('Receivables (Owed Us)'),
            selected: _directionFilter == _DirectionFilter.receivablesOnly,
            selectedColor: Colors.green.withOpacity(0.2),
            onSelected: (_) => setState(() => _directionFilter = _DirectionFilter.receivablesOnly),
          ),
          const SizedBox(width: 6),
          FilterChip(
            label: const Text('Payables (We Owe)'),
            selected: _directionFilter == _DirectionFilter.payablesOnly,
            selectedColor: Colors.red.withOpacity(0.2),
            onSelected: (_) => setState(() => _directionFilter = _DirectionFilter.payablesOnly),
          ),
          const SizedBox(width: 6),
          FilterChip(
            label: const Text('Suppliers'),
            selected: _directionFilter == _DirectionFilter.suppliersOnly,
            onSelected: (_) => setState(() => _directionFilter = _DirectionFilter.suppliersOnly),
          ),
          const SizedBox(width: 6),
          FilterChip(
            label: const Text('Projects'),
            selected: _directionFilter == _DirectionFilter.projectsOnly,
            onSelected: (_) => setState(() => _directionFilter = _DirectionFilter.projectsOnly),
          ),
          const SizedBox(width: 6),
          FilterChip(
            label: const Text('Informal Debt'),
            selected: _directionFilter == _DirectionFilter.counterOnly,
            onSelected: (_) => setState(() => _directionFilter = _DirectionFilter.counterOnly),
          ),
          const SizedBox(width: 12),
          const VerticalDivider(width: 1, indent: 8, endIndent: 8),
          const SizedBox(width: 12),
          // Aging Filters
          ChoiceChip(
            label: const Text('All Ages'),
            selected: _agingFilter == _AgingFilter.all,
            onSelected: (_) => setState(() => _agingFilter = _AgingFilter.all),
          ),
          const SizedBox(width: 6),
          ChoiceChip(
            label: const Text('0-30 Days'),
            selected: _agingFilter == _AgingFilter.bucket0_30,
            onSelected: (_) => setState(() => _agingFilter = _AgingFilter.bucket0_30),
          ),
          const SizedBox(width: 6),
          ChoiceChip(
            label: const Text('31-60 Days'),
            selected: _agingFilter == _AgingFilter.bucket31_60,
            onSelected: (_) => setState(() => _agingFilter = _AgingFilter.bucket31_60),
          ),
          const SizedBox(width: 6),
          ChoiceChip(
            label: const Text('61-90 Days'),
            selected: _agingFilter == _AgingFilter.bucket61_90,
            onSelected: (_) => setState(() => _agingFilter = _AgingFilter.bucket61_90),
          ),
          const SizedBox(width: 6),
          ChoiceChip(
            label: const Text('90+ Days'),
            selected: _agingFilter == _AgingFilter.bucket90Plus,
            selectedColor: Colors.orange.withOpacity(0.3),
            onSelected: (_) => setState(() => _agingFilter = _AgingFilter.bucket90Plus),
          ),
        ],
      ),
    );
  }

  Widget _buildItemsList(
      List<PayableReceivableItem> items, PayablesReceivablesBundle bundle) {
    if (_groupOption == _GroupOption.none) {
      return ListView.builder(
        padding: const EdgeInsets.all(12),
        itemCount: items.length,
        itemBuilder: (context, index) {
          return _ItemCard(
            item: items[index],
            onWhatsApp: () => _sendWhatsAppReminder(items[index]),
            onTap: () => _navigateToLedger(items[index], bundle),
          );
        },
      );
    }

    final groups = <String, List<PayableReceivableItem>>{};
    for (final item in items) {
      String key;
      if (_groupOption == _GroupOption.category) {
        key = item.category.label;
      } else {
        key = item.oldestAgeLabel;
      }
      groups.putIfAbsent(key, () => []).add(item);
    }

    return ListView(
      padding: const EdgeInsets.all(12),
      children: [
        for (final entry in groups.entries) ...[
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 4),
            child: Row(
              children: [
                Text(
                  entry.key,
                  style: Theme.of(context).textTheme.titleSmall?.copyWith(
                        fontWeight: FontWeight.bold,
                      ),
                ),
                const SizedBox(width: 8),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                  decoration: BoxDecoration(
                    color: Theme.of(context).colorScheme.surfaceContainerHighest,
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Text(
                    '${entry.value.length}',
                    style: const TextStyle(fontSize: 12, fontWeight: FontWeight.bold),
                  ),
                ),
              ],
            ),
          ),
          for (final item in entry.value)
            _ItemCard(
              item: item,
              onWhatsApp: () => _sendWhatsAppReminder(item),
              onTap: () => _navigateToLedger(item, bundle),
            ),
          const SizedBox(height: 8),
        ],
      ],
    );
  }
}

class _HeaderSummaryCard extends StatelessWidget {
  const _HeaderSummaryCard({
    required this.totalReceivables,
    required this.totalPayables,
    required this.netPosition,
    required this.overdueCount,
    required this.stale90Count,
  });

  final double totalReceivables;
  final double totalPayables;
  final double netPosition;
  final int overdueCount;
  final int stale90Count;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isNetCreditor = netPosition >= 0;

    return Card(
      margin: const EdgeInsets.all(12),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'NET POSITION',
                      style: theme.textTheme.labelSmall?.copyWith(
                        letterSpacing: 1.1,
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      fmtSignedMoney(netPosition),
                      style: theme.textTheme.headlineSmall?.copyWith(
                        fontWeight: FontWeight.bold,
                        color: isNetCreditor ? Colors.green : Colors.red,
                      ),
                    ),
                  ],
                ),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                  decoration: BoxDecoration(
                    color: isNetCreditor
                        ? Colors.green.withOpacity(0.12)
                        : Colors.red.withOpacity(0.12),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Text(
                    isNetCreditor ? 'Net Creditor (Owed More)' : 'Net Debtor (Owe More)',
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.bold,
                      color: isNetCreditor ? Colors.green[800] : Colors.red[800],
                    ),
                  ),
                ),
              ],
            ),
            const Divider(height: 24),
            Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Total Receivables',
                        style: theme.textTheme.bodySmall?.copyWith(color: Colors.grey[700]),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        fmtMoney(totalReceivables),
                        style: const TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.bold,
                          color: Colors.green,
                        ),
                      ),
                    ],
                  ),
                ),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Total Payables',
                        style: theme.textTheme.bodySmall?.copyWith(color: Colors.grey[700]),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        fmtMoney(totalPayables),
                        style: const TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.bold,
                          color: Colors.red,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            if (overdueCount > 0 || stale90Count > 0) ...[
              const SizedBox(height: 12),
              Row(
                children: [
                  if (overdueCount > 0)
                    Container(
                      margin: const EdgeInsets.only(right: 8),
                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                      decoration: BoxDecoration(
                        color: Colors.amber.withOpacity(0.2),
                        borderRadius: BorderRadius.circular(6),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const Icon(Icons.warning_amber_rounded, size: 14, color: Colors.amber),
                          const SizedBox(width: 4),
                          Text(
                            '$overdueCount Overdue (>30d)',
                            style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w600),
                          ),
                        ],
                      ),
                    ),
                  if (stale90Count > 0)
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                      decoration: BoxDecoration(
                        color: Colors.red.withOpacity(0.2),
                        borderRadius: BorderRadius.circular(6),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const Icon(Icons.error_outline, size: 14, color: Colors.red),
                          const SizedBox(width: 4),
                          Text(
                            '$stale90Count Stale (>90d)',
                            style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w600),
                          ),
                        ],
                      ),
                    ),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _ItemCard extends StatelessWidget {
  const _ItemCard({
    required this.item,
    required this.onWhatsApp,
    required this.onTap,
  });

  final PayableReceivableItem item;
  final VoidCallback onWhatsApp;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final isRecv = item.isReceivable;
    final color = isRecv ? Colors.green : Colors.red;

    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(12),
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Row(
            children: [
              Container(
                width: 4,
                height: 48,
                decoration: BoxDecoration(
                  color: color,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      item.name,
                      style: const TextStyle(
                        fontWeight: FontWeight.bold,
                        fontSize: 15,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Row(
                      children: [
                        Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 6, vertical: 2),
                          decoration: BoxDecoration(
                            color: color.withOpacity(0.1),
                            borderRadius: BorderRadius.circular(4),
                          ),
                          child: Text(
                            item.category.label,
                            style: TextStyle(
                              fontSize: 11,
                              fontWeight: FontWeight.w600,
                              color: color,
                            ),
                          ),
                        ),
                        const SizedBox(width: 6),
                        Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 6, vertical: 2),
                          decoration: BoxDecoration(
                            color: item.bucket90Plus > 0
                                ? Colors.red.withOpacity(0.15)
                                : item.bucket31_60 > 0 || item.bucket61_90 > 0
                                    ? Colors.amber.withOpacity(0.15)
                                    : Colors.grey.withOpacity(0.15),
                            borderRadius: BorderRadius.circular(4),
                          ),
                          child: Text(
                            item.oldestAgeLabel,
                            style: TextStyle(
                              fontSize: 11,
                              fontWeight: FontWeight.w500,
                              color: item.bucket90Plus > 0
                                  ? Colors.red[800]
                                  : item.bucket31_60 > 0 || item.bucket61_90 > 0
                                      ? Colors.amber[900]
                                      : Colors.grey[800],
                            ),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
              Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Text(
                    fmtMoney(item.amount),
                    style: TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.bold,
                      color: color,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Row(
                    children: [
                      if (item.phone != null && item.phone!.isNotEmpty) ...[
                        IconButton(
                          icon: const Icon(Icons.chat_bubble_outline,
                              size: 18, color: Colors.green),
                          padding: EdgeInsets.zero,
                          constraints: const BoxConstraints(),
                          tooltip: 'Send WhatsApp Reminder',
                          onPressed: onWhatsApp,
                        ),
                        const SizedBox(width: 8),
                      ],
                      const Icon(Icons.chevron_right,
                          size: 18, color: Colors.grey),
                    ],
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
