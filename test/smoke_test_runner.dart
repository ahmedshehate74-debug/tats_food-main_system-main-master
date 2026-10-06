import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:system_casher/core/database/database_helper.dart';
import 'package:uuid/uuid.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';

class MockPathProviderPlatform extends Fake with MockPlatformInterfaceMixin implements PathProviderPlatform {
  @override
  Future<String?> getApplicationSupportPath() async {
    final dir = Directory('./.dart_tool/test_db_1');
    if (!dir.existsSync()) dir.createSync(recursive: true);
    return dir.path;
  }
}

void main() {
  setUpAll(() {
    TestWidgetsFlutterBinding.ensureInitialized();
    PathProviderPlatform.instance = MockPathProviderPlatform();
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  test('Runtime Smoke Test', () async {
    final dbFile = File('./.dart_tool/test_db_1/foodpro.db');
    if (dbFile.existsSync()) {
      dbFile.deleteSync();
    }

    final dbHelper = DatabaseHelper.instance;
    final db = await dbHelper.database;
    final uuid = Uuid();

    print('--- 1. Add Expense ---');
    final expenseId = uuid.v4();
    await dbHelper.insertExpenseAtomic(
      id: expenseId,
      amount: 100,
      category: 'Test Category',
      date: DateTime.now(),
      description: 'Test Expense',
      userId: null,
      shiftId: null,
    );
    
    var journal = await dbHelper.getJournalEntries();
    bool foundExpenseInJournal = journal.any((e) => e['description'].toString().contains('Test Expense'));
    expect(foundExpenseInJournal, true, reason: 'Expense not found in journal');
    print('✅ Add Expense: Passed');

    print('--- 2. Edit Expense ---');
    await dbHelper.updateExpenseWithReversal(
      id: expenseId,
      newAmount: 150,
      newCategory: 'Test Category 2',
      newDescription: 'Test Expense Edited',
      userId: null,
    );
    journal = await dbHelper.getJournalEntries();
    bool foundEditedExpenseInJournal = journal.any((e) => e['debit'] == 150 && e['description'].toString().contains('Edited'));
    expect(foundEditedExpenseInJournal, true, reason: 'Edited Expense not found in journal');
    print('✅ Edit Expense: Passed');

    print('--- 3. Delete Expense ---');
    await dbHelper.deleteExpenseWithReversal(expenseId);
    final accounts = await db.query('accounts');
    final expensesAccount = accounts.firstWhere((a) => a['code'] == '5.4');
    expect(expensesAccount['balance'], 0, reason: 'Expense account balance not 0 after delete');
    print('✅ Delete Expense: Passed');

    print('--- Setup Supplier and Material ---');
    final supplierId = uuid.v4();
    await db.insert('suppliers', {
      'id': supplierId,
      'name': 'Test Supplier',
      'balance': 0,
      'created_at': DateTime.now().toIso8601String(),
    });
    
    final materialId = uuid.v4();
    await db.insert('raw_materials', {
      'id': materialId,
      'name': 'Test Material',
      'unit': 'KG',
      'stock': 0,
      'cost_per_unit': 10,
      'created_at': DateTime.now().toIso8601String(),
      'updated_at': DateTime.now().toIso8601String(),
    });

    print('--- 4. Add Supplier Invoice ---');
    final invoiceId = await dbHelper.receivePurchase(
      supplierId: supplierId,
      items: [
        {'item_type': 'raw_material', 'item_id': materialId, 'item_name': 'Test Material', 'quantity': 10.0, 'unit_cost': 10.0}
      ],
      paymentType: 'credit', 
      paidAmount: 0,
      notes: 'Purchase 1',
      userId: null,
    );
    var supplier = (await db.query('suppliers', where: 'id = ?', whereArgs: [supplierId])).first;
    expect(supplier['balance'], 100, reason: 'Supplier balance should be 100');
    var material = (await db.query('raw_materials', where: 'id = ?', whereArgs: [materialId])).first;
    expect(material['stock'], 10, reason: 'Material stock should be 10');
    print('✅ Add Supplier Invoice: Passed');

    print('--- 5. Edit Supplier Invoice ---');
    await dbHelper.editPurchaseInvoice(
      invoiceId: invoiceId,
      newItems: [
        {'item_type': 'raw_material', 'item_id': materialId, 'item_name': 'Test Material', 'quantity': 15.0, 'unit_cost': 10.0}
      ],
      notes: 'Purchase 1 Edited',
      userId: null,
    );
    supplier = (await db.query('suppliers', where: 'id = ?', whereArgs: [supplierId])).first;
    expect(supplier['balance'], 150, reason: 'Supplier balance should be 150');
    material = (await db.query('raw_materials', where: 'id = ?', whereArgs: [materialId])).first;
    expect(material['stock'], 15, reason: 'Material stock should be 15');
    print('✅ Edit Supplier Invoice: Passed');

    print('--- 6. Add Supplier Payment ---');
    final paymentId = await dbHelper.paySupplier(
      supplierId: supplierId,
      amount: 50,
      paymentMethod: 'cash',
      notes: 'Payment 1',
      invoiceId: invoiceId,
      userId: null,
    );
    supplier = (await db.query('suppliers', where: 'id = ?', whereArgs: [supplierId])).first;
    expect(supplier['balance'], 100, reason: 'Supplier balance should be 100 after 50 payment');
    var invoice = (await db.query('purchase_invoices', where: 'id = ?', whereArgs: [invoiceId])).first;
    expect(invoice['paid_amount'], 50, reason: 'Invoice paid_amount should be 50');
    expect(invoice['remaining_amount'], 100, reason: 'Invoice remaining_amount should be 100');
    print('✅ Add Supplier Payment: Passed');

    print('--- 7. Edit Supplier Payment ---');
    await dbHelper.updateSupplierPayment(
      paymentId: paymentId,
      newAmount: 70,
      newInvoiceId: invoiceId,
      notes: 'Payment 1 Edited',
      userId: null,
    );
    supplier = (await db.query('suppliers', where: 'id = ?', whereArgs: [supplierId])).first;
    expect(supplier['balance'], 80, reason: 'Supplier balance should be 80 after editing payment to 70');
    invoice = (await db.query('purchase_invoices', where: 'id = ?', whereArgs: [invoiceId])).first;
    expect(invoice['paid_amount'], 70, reason: 'Invoice paid_amount should be 70');
    expect(invoice['remaining_amount'], 80, reason: 'Invoice remaining_amount should be 80');
    print('✅ Edit Supplier Payment: Passed');

    print('--- 8. Delete Supplier Payment ---');
    await dbHelper.deleteSupplierPayment(paymentId);
    supplier = (await db.query('suppliers', where: 'id = ?', whereArgs: [supplierId])).first;
    expect(supplier['balance'], 150, reason: 'Supplier balance should be 150 after deleting payment');
    invoice = (await db.query('purchase_invoices', where: 'id = ?', whereArgs: [invoiceId])).first;
    expect(invoice['paid_amount'], 0, reason: 'Invoice paid_amount should be 0');
    print('✅ Delete Supplier Payment: Passed');

    print('--- 9. Delete Supplier Invoice ---');
    await dbHelper.deletePurchaseInvoice(invoiceId);
    supplier = (await db.query('suppliers', where: 'id = ?', whereArgs: [supplierId])).first;
    expect(supplier['balance'], 0, reason: 'Supplier balance should be 0 after deleting invoice');
    material = (await db.query('raw_materials', where: 'id = ?', whereArgs: [materialId])).first;
    expect(material['stock'], 0, reason: 'Material stock should be 0 after deleting invoice');
    print('✅ Delete Supplier Invoice: Passed');

    print('--- 10. Accounting Date Filter ---');
    final before = DateTime.now().subtract(Duration(days: 5));
    final after = DateTime.now().subtract(Duration(days: 3));
    
    final firstAccount = (await db.query('accounts')).first['id'] as String;
    
    await db.insert('account_transactions', {
      'id': uuid.v4(),
      'account_id': firstAccount,
      'debit': 100,
      'credit': 0,
      'description': 'Old transaction',
      'ref_type': 'test',
      'ref_id': 'test',
      'created_at': before.toIso8601String(),
    });

    final journalFiltered = await dbHelper.getJournalEntries(from: after, to: DateTime.now());
    expect(journalFiltered.any((e) => e['description'] == 'Old transaction'), false, reason: 'Old transaction found when it should have been filtered out');
    
    final journalUnfiltered = await dbHelper.getJournalEntries(from: before.subtract(Duration(days: 1)), to: DateTime.now());
    expect(journalUnfiltered.any((e) => e['description'] == 'Old transaction'), true, reason: 'Old transaction not found when it should have been included');
    print('✅ Accounting Date Filter: Passed');

    print('\nRUNTIME SMOKE TEST PASSED');
  });
}
