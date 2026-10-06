import 'package:flutter/material.dart';
import 'package:system_casher/repositories/raw_material_repository.dart';
import '../../../../core/theme/app_colors.dart';
import '../../../../core/theme/app_dimensions.dart';
import '../../../../core/theme/app_typography.dart';
import '../../../../core/widgets/app_top_bar.dart';
import '../../../../core/database/database_helper.dart';
import '../../../../core/services/session_service.dart';
import '../../../../models/product.dart';
import '../../../../repositories/product_repository.dart';


// ─── helper مؤقت للصف داخل نموذج التعديل ────────────────────────────────
class _EditRow {
  _EditRow({
    required this.itemType,
    required this.itemId,
    required this.itemName,
    required double quantity,
    required double unitCost,
  }) {
    qtyCtrl.text  = quantity.toString();
    costCtrl.text = unitCost.toString();
  }

  String itemType;
  String itemId;
  String itemName;
  final qtyCtrl  = TextEditingController();
  final costCtrl = TextEditingController();

  double get quantity => double.tryParse(qtyCtrl.text) ?? 0;
  double get unitCost => double.tryParse(costCtrl.text) ?? 0;
  double get total    => quantity * unitCost;
}

// ─── الشاشة الرئيسية ─────────────────────────────────────────────────────
class SupplierDetailScreen extends StatefulWidget {
  const SupplierDetailScreen({super.key, required this.supplier});
  final Map<String, dynamic> supplier;

  @override
  State<SupplierDetailScreen> createState() => _SupplierDetailScreenState();
}

class _SupplierDetailScreenState extends State<SupplierDetailScreen> {
  late Map<String, dynamic> _supplier = widget.supplier;
  List<Map<String, dynamic>> _invoices = [];
  List<Map<String, dynamic>> _payments = [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    final id = _supplier['id'] as String;
    final supplierRows = await DatabaseHelper.instance
        .query('suppliers', where: 'id = ?', whereArgs: [id]);
    final invoices  = await DatabaseHelper.instance.getSupplierInvoices(id);
    final payments  = await DatabaseHelper.instance.query(
      'supplier_payments',
      where: 'supplier_id = ?',
      whereArgs: [id],
      orderBy: 'created_at DESC',
    );
    if (mounted) {
      setState(() {
        _supplier = supplierRows.isNotEmpty ? supplierRows.first : _supplier;
        _invoices = invoices;
        _payments = payments;
        _loading  = false;
      });
    }
  }

  // ─── سداد دفعة ──────────────────────────────────────────────────────────
  Future<void> _payDialog() async {
    final balance = (_supplier['balance'] as num).toDouble();
    if (balance <= 0) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('مفيش مستحقات على المورد ده حاليًا')),
      );
      return;
    }

    final amountCtrl = TextEditingController(text: balance.toStringAsFixed(2));
    final notesCtrl  = TextEditingController();
    String? selectedInvoiceId;
    final creditInvoices =
        _invoices.where((inv) => (inv['remaining_amount'] as num) > 0).toList();

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) => AlertDialog(
          title: const Text('سداد دفعة للمورد'),
          content: SizedBox(
            width: 360,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'المستحق حاليًا: ${balance.toStringAsFixed(2)} ج.م',
                  style: AppTypography.titleSmall.copyWith(
                      color: AppColors.warning, fontWeight: FontWeight.w700),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: amountCtrl,
                  autofocus: true,
                  keyboardType:
                      const TextInputType.numberWithOptions(decimal: true),
                  decoration: const InputDecoration(
                      labelText: 'المبلغ المدفوع', suffixText: 'ج.م'),
                ),
                if (creditInvoices.isNotEmpty) ...[
                  const SizedBox(height: 12),
                  DropdownButtonFormField<String?>(
                    initialValue: selectedInvoiceId,
                    items: [
                      const DropdownMenuItem<String?>(
                          value: null,
                          child: Text('سداد عام (بدون ربط بفاتورة)')),
                      ...creditInvoices.map(
                        (inv) => DropdownMenuItem<String?>(
                          value: inv['id'] as String,
                          child: Text(
                            '${inv['invoice_number']} — متبقي '
                            '${(inv['remaining_amount'] as num).toStringAsFixed(2)} ج.م',
                          ),
                        ),
                      ),
                    ],
                    onChanged: (v) =>
                        setDialogState(() => selectedInvoiceId = v),
                    decoration:
                        const InputDecoration(labelText: 'ربط بفاتورة (اختياري)'),
                  ),
                ],
                const SizedBox(height: 12),
                TextField(
                  controller: notesCtrl,
                  decoration:
                      const InputDecoration(labelText: 'ملاحظات (اختياري)'),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: const Text('إلغاء')),
            FilledButton(
                onPressed: () => Navigator.pop(ctx, true),
                child: const Text('تأكيد السداد')),
          ],
        ),
      ),
    );

    if (confirmed != true) return;
    final amount = double.tryParse(amountCtrl.text) ?? 0;
    if (amount <= 0) return;

    try {
      await DatabaseHelper.instance.paySupplier(
        supplierId:    _supplier['id'] as String,
        amount:        amount,
        invoiceId:     selectedInvoiceId,
        paymentMethod: 'cash',
        notes: notesCtrl.text.trim().isEmpty ? null : notesCtrl.text.trim(),
        userId: SessionService.instance.currentUser?.id,
      );
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text('تم تسجيل سداد ${amount.toStringAsFixed(2)} ج.م'),
            backgroundColor: AppColors.success));
      }
    } on StateError catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text(e.message), backgroundColor: AppColors.error));
        return;
      }
    }
    _load();
  }

  // ─── تعديل دفعة ──────────────────────────────────────────────────────────
  Future<void> _editPaymentDialog(Map<String, dynamic> payment) async {
    final oldAmount = (payment['amount'] as num).toDouble();
    final amountCtrl =
        TextEditingController(text: oldAmount.toStringAsFixed(2));
    final notesCtrl =
        TextEditingController(text: payment['notes'] as String? ?? '');
    String? selectedInvoiceId = payment['invoice_id'] as String?;

    final creditInvoices = _invoices
        .where((inv) =>
            (inv['remaining_amount'] as num) > 0 ||
            inv['id'] == selectedInvoiceId)
        .toList();

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) => AlertDialog(
          title: const Text('تعديل دفعة المورد'),
          content: SizedBox(
            width: 360,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                TextField(
                  controller: amountCtrl,
                  autofocus: true,
                  keyboardType:
                      const TextInputType.numberWithOptions(decimal: true),
                  decoration: const InputDecoration(
                      labelText: 'المبلغ المدفوع', suffixText: 'ج.م'),
                ),
                if (creditInvoices.isNotEmpty) ...[
                  const SizedBox(height: 12),
                  DropdownButtonFormField<String?>(
                    initialValue: selectedInvoiceId,
                    items: [
                      const DropdownMenuItem<String?>(
                          value: null,
                          child: Text('سداد عام (بدون ربط بفاتورة)')),
                      ...creditInvoices.map(
                        (inv) => DropdownMenuItem<String?>(
                          value: inv['id'] as String,
                          child: Text(
                            '${inv['invoice_number']} — متبقي '
                            '${(inv['remaining_amount'] as num).toStringAsFixed(2)} ج.م',
                          ),
                        ),
                      ),
                    ],
                    onChanged: (v) =>
                        setDialogState(() => selectedInvoiceId = v),
                    decoration:
                        const InputDecoration(labelText: 'ربط بفاتورة (اختياري)'),
                  ),
                ],
                const SizedBox(height: 12),
                TextField(
                  controller: notesCtrl,
                  decoration:
                      const InputDecoration(labelText: 'ملاحظات الدفعة'),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: const Text('إلغاء')),
            FilledButton(
                onPressed: () => Navigator.pop(ctx, true),
                child: const Text('حفظ التعديل')),
          ],
        ),
      ),
    );

    if (confirmed != true) return;
    final amount = double.tryParse(amountCtrl.text) ?? 0;
    if (amount <= 0) return;

    try {
      await DatabaseHelper.instance.updateSupplierPayment(
        paymentId: payment['id'] as String,
        newAmount: amount,
        newInvoiceId: selectedInvoiceId,
        notes: notesCtrl.text.trim().isEmpty ? null : notesCtrl.text.trim(),
        userId: SessionService.instance.currentUser?.id,
      );
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: const Text('تم تعديل الدفعة وعكس القيود بنجاح'),
            backgroundColor: AppColors.success));
      }
    } on StateError catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text(e.message), backgroundColor: AppColors.error));
        return;
      }
    }
    _load();
  }

  // ─── حذف دفعة ───────────────────────────────────────────────────────────
  Future<void> _deletePayment(Map<String, dynamic> payment) async {
    final amount = (payment['amount'] as num).toDouble();
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('حذف الدفعة'),
        content: Text(
          'هل أنت متأكد من حذف هذه الدفعة؟\n'
          'المبلغ: ${amount.toStringAsFixed(2)} ج.م\n\n'
          'سيتم عكس تأثيرها على المورد والحسابات.',
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('إلغاء')),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: AppColors.error),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('حذف'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;

    try {
      await DatabaseHelper.instance.deleteSupplierPayment(
        payment['id'] as String,
        userId: SessionService.instance.currentUser?.id,
      );
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: const Text('تم حذف الدفعة وعكس تأثيرها'),
            backgroundColor: AppColors.success));
      }
    } on StateError catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text(e.message), backgroundColor: AppColors.error));
        return;
      }
    }
    _load();
  }

  // ─── حذف فاتورة ─────────────────────────────────────────────────────────
  Future<void> _deleteInvoice(Map<String, dynamic> invoice) async {
    final invoiceNumber  = invoice['invoice_number'] as String;
    final linkedPayments =
        _payments.where((p) => p['invoice_id'] == invoice['id']).toList();

    String warningText =
        'هل أنت متأكد من حذف الفاتورة $invoiceNumber؟\n\n'
        'سيتم عكس تأثيرها على:\n• المخزون\n• رصيد المورد\n• الحسابات المحاسبية';
    if (linkedPayments.isNotEmpty) {
      warningText +=
          '\n\n⚠️ هناك ${linkedPayments.length} دفعة مرتبطة — ستُحذف أيضاً.';
    }

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('حذف فاتورة الشراء'),
        content: Text(warningText),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('إلغاء')),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: AppColors.error),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('حذف'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;

    try {
      await DatabaseHelper.instance.deletePurchaseInvoice(
        invoice['id'] as String,
        userId:                    SessionService.instance.currentUser?.id,
        forceDeleteWithPayments:   linkedPayments.isNotEmpty,
      );
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: const Text('تم حذف الفاتورة وعكس تأثيراتها'),
            backgroundColor: AppColors.success));
      }
    } on StateError catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text(e.message), backgroundColor: AppColors.error));
        return;
      }
    }
    _load();
  }

  // ─── تعديل فاتورة ────────────────────────────────────────────────────────
  Future<void> _editInvoice(Map<String, dynamic> invoice) async {
    // نجلب أصناف الفاتورة الحالية أولاً
    final existingItems = await DatabaseHelper.instance.query(
      'purchase_invoice_items',
      where: 'invoice_id = ?',
      whereArgs: [invoice['id']],
    );

    // نفتح نموذج التعديل
    if (!mounted) return;
    final result = await showDialog<List<Map<String, dynamic>>>(
      context: context,
      builder: (ctx) => _EditInvoiceDialog(
        invoice:       invoice,
        existingItems: existingItems,
      ),
    );

    if (result == null) return; // ألغى المستخدم

    try {
      await DatabaseHelper.instance.editPurchaseInvoice(
        invoiceId: invoice['id'] as String,
        newItems:  result,
        userId:    SessionService.instance.currentUser?.id,
      );
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: const Text('تم تعديل الفاتورة بنجاح'),
            backgroundColor: AppColors.success));
      }
    } on StateError catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text(e.message), backgroundColor: AppColors.error));
        return;
      }
    }
    _load();
  }

  // ─── عرض أصناف فاتورة ───────────────────────────────────────────────────
  Future<void> _showInvoiceItems(Map<String, dynamic> invoice) async {
    final items = await DatabaseHelper.instance.query(
      'purchase_invoice_items',
      where: 'invoice_id = ?',
      whereArgs: [invoice['id']],
    );
    if (!mounted) return;
    await showDialog<void>(
      context: context,
      builder: (_) => AlertDialog(
        title: Text('أصناف فاتورة ${invoice['invoice_number']}'),
        content: SizedBox(
          width: 420,
          child: items.isEmpty
              ? const Padding(
                  padding: EdgeInsets.all(AppDimensions.space16),
                  child: Text('لا توجد أصناف'),
                )
              : ListView.separated(
                  shrinkWrap: true,
                  itemCount: items.length,
                  separatorBuilder: (_, __) => const Divider(height: 1),
                  itemBuilder: (_, i) {
                    final item = items[i];
                    return ListTile(
                      dense: true,
                      title: Text(item['item_name'] as String),
                      subtitle: Text(
                        '${item['quantity']} × '
                        '${(item['unit_cost'] as num).toStringAsFixed(2)} ج.م',
                      ),
                      trailing: Text(
                          '${(item['total_cost'] as num).toStringAsFixed(2)} ج.م'),
                    );
                  },
                ),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('إغلاق')),
        ],
      ),
    );
  }

  // ─── Build ───────────────────────────────────────────────────────────────
  @override
  Widget build(BuildContext context) {
    final balance = (_supplier['balance'] as num?)?.toDouble() ?? 0;

    return Scaffold(
      appBar: AppTopBar(
        title: _supplier['name'] as String,
        onBack: () => Navigator.pop(context),
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : RefreshIndicator(
              onRefresh: _load,
              child: ListView(
                padding: const EdgeInsets.all(AppDimensions.space20),
                children: [
                  // ─── بيانات المورد ──────────────────────────
                  Container(
                    padding: const EdgeInsets.all(AppDimensions.space16),
                    decoration: BoxDecoration(
                      color: AppColors.surface,
                      borderRadius:
                          BorderRadius.circular(AppDimensions.radiusMd),
                      border: Border.all(color: AppColors.border),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        if ((_supplier['phone'] as String?)?.isNotEmpty == true)
                          _infoRow(Icons.phone_outlined,
                              _supplier['phone'] as String),
                        if ((_supplier['address'] as String?)?.isNotEmpty ==
                            true)
                          _infoRow(Icons.location_on_outlined,
                              _supplier['address'] as String),
                        const Divider(height: 24),
                        Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            Text('المستحق عليه',
                                style: AppTypography.titleMedium),
                            Text(
                              '${balance.toStringAsFixed(2)} ج.م',
                              style: AppTypography.titleLarge.copyWith(
                                fontWeight: FontWeight.w800,
                                color: balance > 0
                                    ? AppColors.warning
                                    : AppColors.success,
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: AppDimensions.space16),
                        SizedBox(
                          width: double.infinity,
                          height: 48,
                          child: ElevatedButton.icon(
                            onPressed: balance > 0 ? _payDialog : null,
                            icon: const Icon(Icons.payments_outlined),
                            label: const Text('سداد دفعة'),
                            style: ElevatedButton.styleFrom(
                              backgroundColor: AppColors.primary,
                              foregroundColor: Colors.white,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: AppDimensions.space24),

                  // ─── فواتير الشراء ──────────────────────────
                  Text('فواتير الشراء', style: AppTypography.titleMedium),
                  const SizedBox(height: AppDimensions.space10),
                  if (_invoices.isEmpty)
                    Padding(
                      padding: const EdgeInsets.symmetric(
                          vertical: AppDimensions.space12),
                      child: Text('لا توجد فواتير شراء بعد',
                          style: AppTypography.bodySmall
                              .copyWith(color: AppColors.textSecondary)),
                    )
                  else
                    ..._invoices.map((inv) => _invoiceTile(inv)),

                  const SizedBox(height: AppDimensions.space24),

                  // ─── سجل السداد ─────────────────────────────
                  Text('سجل السداد', style: AppTypography.titleMedium),
                  const SizedBox(height: AppDimensions.space10),
                  if (_payments.isEmpty)
                    Padding(
                      padding: const EdgeInsets.symmetric(
                          vertical: AppDimensions.space12),
                      child: Text('لا توجد مدفوعات مسجلة بعد',
                          style: AppTypography.bodySmall
                              .copyWith(color: AppColors.textSecondary)),
                    )
                  else
                    ..._payments.map((p) => _paymentTile(p)),
                ],
              ),
            ),
    );
  }

  Widget _infoRow(IconData icon, String text) => Padding(
        padding: const EdgeInsets.only(bottom: 6),
        child: Row(
          children: [
            Icon(icon, size: 16, color: AppColors.textSecondary),
            const SizedBox(width: 8),
            Text(text, style: AppTypography.bodyMedium),
          ],
        ),
      );

  Widget _invoiceTile(Map<String, dynamic> inv) {
    final total     = (inv['total_amount']     as num).toDouble();
    final remaining = (inv['remaining_amount'] as num).toDouble();
    final isCredit  = inv['payment_type'] == 'credit';

    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.all(AppDimensions.space12),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(AppDimensions.radiusSm),
        border: Border.all(color: AppColors.border),
      ),
      child: Row(
        children: [
          InkWell(
            onTap: () => _showInvoiceItems(inv),
            borderRadius: BorderRadius.circular(AppDimensions.radiusSm),
            child: Icon(Icons.receipt_long_outlined,
                color: AppColors.primary, size: 20),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: InkWell(
              onTap: () => _showInvoiceItems(inv),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(inv['invoice_number'] as String,
                      style: AppTypography.titleSmall),
                  Text(
                    _formatDate(inv['created_at'] as String),
                    style: AppTypography.caption
                        .copyWith(color: AppColors.textDisabled),
                  ),
                ],
              ),
            ),
          ),
          Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Text('${total.toStringAsFixed(2)} ج.م',
                  style: AppTypography.titleSmall
                      .copyWith(fontWeight: FontWeight.w700)),
              Container(
                margin: const EdgeInsets.only(top: 2),
                padding:
                    const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                decoration: BoxDecoration(
                  color: isCredit
                      ? AppColors.warningLight
                      : AppColors.successLight,
                  borderRadius:
                      BorderRadius.circular(AppDimensions.radiusFull),
                ),
                child: Text(
                  isCredit
                      ? (remaining > 0
                          ? 'آجل — متبقي ${remaining.toStringAsFixed(0)}'
                          : 'آجل — مسدد')
                      : 'كاش',
                  style: AppTypography.caption.copyWith(
                    fontSize: 10,
                    color: isCredit ? AppColors.warning : AppColors.success,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(width: 4),
          // زر تعديل الفاتورة
          IconButton(
            icon: const Icon(Icons.edit_outlined, size: 18),
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(),
            color: AppColors.primary,
            tooltip: 'تعديل الفاتورة',
            onPressed: () => _editInvoice(inv),
          ),
          const SizedBox(width: 4),
          // زر حذف الفاتورة
          IconButton(
            icon: const Icon(Icons.delete_outline, size: 18),
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(),
            color: AppColors.error,
            tooltip: 'حذف الفاتورة',
            onPressed: () => _deleteInvoice(inv),
          ),
        ],
      ),
    );
  }

  Widget _paymentTile(Map<String, dynamic> p) {
    final invoiceNumber = p['invoice_id'] == null
        ? 'سداد عام'
        : (_invoices
                .where((i) => i['id'] == p['invoice_id'])
                .firstOrNull?['invoice_number'] as String? ??
            'فاتورة محذوفة');

    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.all(AppDimensions.space12),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(AppDimensions.radiusSm),
        border: Border.all(color: AppColors.border),
      ),
      child: Row(
        children: [
          Icon(Icons.check_circle_outline_rounded,
              color: AppColors.success, size: 20),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(invoiceNumber, style: AppTypography.titleSmall),
                if ((p['notes'] as String?)?.isNotEmpty == true)
                  Text(p['notes'] as String,
                      style: AppTypography.caption
                          .copyWith(color: AppColors.textSecondary)),
                Text(
                  _formatDate(p['created_at'] as String),
                  style: AppTypography.caption
                      .copyWith(color: AppColors.textDisabled),
                ),
              ],
            ),
          ),
          Text(
            '${(p['amount'] as num).toStringAsFixed(2)} ج.م',
            style: AppTypography.titleSmall
                .copyWith(color: AppColors.success, fontWeight: FontWeight.w700),
          ),
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              IconButton(
                icon: const Icon(Icons.edit_outlined, size: 18),
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints(),
                color: AppColors.primary,
                tooltip: 'تعديل الدفعة',
                onPressed: () => _editPaymentDialog(p),
              ),
              const SizedBox(width: 8),
              IconButton(
                icon: const Icon(Icons.delete_outline, size: 18),
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints(),
                color: AppColors.error,
                tooltip: 'حذف الدفعة',
                onPressed: () => _deletePayment(p),
              ),
            ],
          ),
        ],
      ),
    );
  }

  String _formatDate(String iso) {
    final d = DateTime.tryParse(iso);
    if (d == null) return iso;
    return '${d.year}/${d.month.toString().padLeft(2, '0')}/'
        '${d.day.toString().padLeft(2, '0')} '
        '${d.hour.toString().padLeft(2, '0')}:'
        '${d.minute.toString().padLeft(2, '0')}';
  }
}

// ═══════════════════════════════════════════════════════════════════════════
// Dialog تعديل الفاتورة — يُعيد List<Map> من الأصناف الجديدة، أو null إذا ألغى
// ═══════════════════════════════════════════════════════════════════════════
class _EditInvoiceDialog extends StatefulWidget {
  const _EditInvoiceDialog({
    required this.invoice,
    required this.existingItems,
  });
  final Map<String, dynamic> invoice;
  final List<Map<String, dynamic>> existingItems;

  @override
  State<_EditInvoiceDialog> createState() => _EditInvoiceDialogState();
}

class _EditInvoiceDialogState extends State<_EditInvoiceDialog> {
  final _rawMaterialRepo = RawMaterialRepository();
  final _productRepo     = ProductRepository();

  List<Map<String, dynamic>> _rawMaterials = [];
  List<Product> _products = [];
  List<_EditRow> _rows    = [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _loadData();
  }

  Future<void> _loadData() async {
    final rawMaterials = await _rawMaterialRepo.getAll();
    final products     = await _productRepo.getAll(activeOnly: true, limit: 500);
    if (mounted) {
      setState(() {
        _rawMaterials = rawMaterials;
        _products     = products;
        // تحميل الأصناف الحالية للفاتورة
        _rows = widget.existingItems.map((it) => _EditRow(
          itemType: it['item_type'] as String,
          itemId:   it['item_id']   as String,
          itemName: it['item_name'] as String,
          quantity: (it['quantity']  as num).toDouble(),
          unitCost: (it['unit_cost'] as num).toDouble(),
        )).toList();
        if (_rows.isEmpty) _rows.add(_newEmptyRow());
        _loading = false;
      });
    }
  }

  _EditRow _newEmptyRow() => _EditRow(
    itemType: 'raw_material',
    itemId:   '',
    itemName: '',
    quantity: 1,
    unitCost: 0,
  );

  double get _total => _rows.fold(0, (s, r) => s + r.total);

  void _addRow()        => setState(() => _rows.add(_newEmptyRow()));
  void _removeRow(int i) => setState(() => _rows.removeAt(i));

  void _save() {
    final valid = _rows.where((r) => r.itemId.isNotEmpty && r.quantity > 0).toList();
    if (valid.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
            content: const Text('ضيف صنف واحد على الأقل بكمية صحيحة'),
            backgroundColor: AppColors.error),
      );
      return;
    }
    final result = valid.map((r) => <String, dynamic>{
      'item_type': r.itemType,
      'item_id':   r.itemId,
      'item_name': r.itemName,
      'quantity':  r.quantity,
      'unit_cost': r.unitCost,
    }).toList();
    Navigator.pop(context, result);
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text('تعديل فاتورة ${widget.invoice['invoice_number']}'),
      content: _loading
          ? const SizedBox(
              width: 300,
              height: 100,
              child: Center(child: CircularProgressIndicator()))
          : SizedBox(
              width: 500,
              child: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // ─── قائمة الأصناف
                    ..._rows.asMap().entries.map((e) => _buildRow(e.key, e.value)),
                    TextButton.icon(
                      onPressed: _addRow,
                      icon: const Icon(Icons.add_rounded),
                      label: const Text('إضافة صنف'),
                    ),
                    const Divider(height: 20),
                    // ─── الإجمالي
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Text('الإجمالي الجديد',
                            style: AppTypography.titleSmall),
                        Text(
                          '${_total.toStringAsFixed(2)} ج.م',
                          style: AppTypography.titleMedium.copyWith(
                              color: AppColors.primary,
                              fontWeight: FontWeight.w800),
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    Text(
                      '⚠️ سيتم تعديل المخزون والحسابات تلقائياً بناءً على الفروق.',
                      style: AppTypography.caption
                          .copyWith(color: AppColors.textSecondary),
                    ),
                  ],
                ),
              ),
            ),
      actions: [
        TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('إلغاء')),
        if (!_loading)
          FilledButton(
              onPressed: _save,
              child: const Text('حفظ التعديلات')),
      ],
    );
  }

  Widget _buildRow(int index, _EditRow row) {
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.all(AppDimensions.space12),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(AppDimensions.radiusSm),
        border: Border.all(color: AppColors.border),
      ),
      child: Column(
        children: [
          Row(
            children: [
              // نوع الصنف
              SizedBox(
                width: 130,
                child: DropdownButtonFormField<String>(
                  initialValue: row.itemType,
                  isDense: true,
                  items: const [
                    DropdownMenuItem(value: 'raw_material', child: Text('خامة')),
                    DropdownMenuItem(value: 'product',      child: Text('صنف جاهز')),
                  ],
                  onChanged: (v) => setState(() {
                    row.itemType = v!;
                    row.itemId   = '';
                    row.itemName = '';
                  }),
                ),
              ),
              const SizedBox(width: 8),
              // اسم الصنف
              Expanded(
                child: row.itemType == 'raw_material'
                    ? DropdownButtonFormField<String>(
                        initialValue: row.itemId.isEmpty ? null : row.itemId,
                        isDense: true,
                        hint: const Text('اختار الخامة'),
                        items: _rawMaterials
                            .map((m) => DropdownMenuItem(
                                  value: m['id'] as String,
                                  child: Text('${m['name']} (${m['unit']})'),
                                ))
                            .toList(),
                        onChanged: (v) {
                          final m = _rawMaterials.firstWhere((e) => e['id'] == v);
                          setState(() {
                            row.itemId   = v!;
                            row.itemName = m['name'] as String;
                          });
                        },
                      )
                    : DropdownButtonFormField<String>(
                        initialValue: row.itemId.isEmpty ? null : row.itemId,
                        isDense: true,
                        hint: const Text('اختار الصنف'),
                        items: _products
                            .map((p) => DropdownMenuItem(
                                value: p.id, child: Text(p.name)))
                            .toList(),
                        onChanged: (v) {
                          final p = _products.firstWhere((e) => e.id == v);
                          setState(() {
                            row.itemId   = v!;
                            row.itemName = p.name;
                          });
                        },
                      ),
              ),
              IconButton(
                onPressed: _rows.length > 1 ? () => _removeRow(index) : null,
                icon: const Icon(Icons.delete_outline_rounded, size: 20),
                color: AppColors.error,
              ),
            ],
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: row.qtyCtrl,
                  keyboardType:
                      const TextInputType.numberWithOptions(decimal: true),
                  decoration: const InputDecoration(
                      labelText: 'الكمية', isDense: true),
                  onChanged: (_) => setState(() {}),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: TextField(
                  controller: row.costCtrl,
                  keyboardType:
                      const TextInputType.numberWithOptions(decimal: true),
                  decoration: const InputDecoration(
                      labelText: 'سعر الوحدة',
                      isDense: true,
                      suffixText: 'ج.م'),
                  onChanged: (_) => setState(() {}),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  '= ${row.total.toStringAsFixed(2)} ج.م',
                  textAlign: TextAlign.center,
                  style: AppTypography.bodyMedium
                      .copyWith(fontWeight: FontWeight.w700),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
