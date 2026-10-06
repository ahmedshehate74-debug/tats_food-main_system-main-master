/// Runtime Smoke Test – Inventory & Sales Stock Deduction
///
/// Opens smoke_test_inv.db (isolated) via DatabaseHelper.testDbPath.
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:system_casher/core/database/database_helper.dart';
import 'package:uuid/uuid.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';

class MockPathProviderPlatform extends Fake
    with MockPlatformInterfaceMixin
    implements PathProviderPlatform {
  @override
  Future<String?> getApplicationSupportPath() async {
    final dir = Directory('./.dart_tool/test_db_2');
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

  test('Inventory & Sales Stock Deduction Smoke Test', () async {
    // ─── تهيئة قاعدة البيانات المعزولة ───────────────────────────
    final dbFile = File('./.dart_tool/test_db_2/foodpro.db');
    if (dbFile.existsSync()) dbFile.deleteSync();

    final dbHelper = DatabaseHelper.instance;
    final db = await dbHelper.database;
    final uuid = Uuid();

    // ─── إعداد البيانات الأساسية ──────────────────────────────────
    final categoryId = uuid.v4();
    await db.insert('categories', {
      'id': categoryId,
      'name': 'Test Category',
      'is_active': 1,
      'created_at': DateTime.now().toIso8601String(),
    });

    // منتج مباشر (Cola) – stock = 50
    final colaId = uuid.v4();
    await db.insert('products', {
      'id': colaId,
      'category_id': categoryId,
      'name': 'Cola',
      'price': 10,
      'stock': 50.0,
      'is_active': 1,
      'created_at': DateTime.now().toIso8601String(),
      'updated_at': DateTime.now().toIso8601String(),
    });

    // خامة (Tomato) – stock = 100
    final tomatoId = uuid.v4();
    await db.insert('raw_materials', {
      'id': tomatoId,
      'name': 'Tomato',
      'unit': 'KG',
      'stock': 100.0,
      'cost_per_unit': 5,
      'created_at': DateTime.now().toIso8601String(),
      'updated_at': DateTime.now().toIso8601String(),
    });

    // منتج Recipe-based (Soup) – 2 KG طماطم لكل وحدة
    final soupId = uuid.v4();
    await db.insert('products', {
      'id': soupId,
      'category_id': categoryId,
      'name': 'Tomato Soup',
      'price': 20,
      'stock': 0.0,
      'is_active': 1,
      'created_at': DateTime.now().toIso8601String(),
      'updated_at': DateTime.now().toIso8601String(),
    });
    await db.insert('product_recipes', {
      'id': uuid.v4(),
      'product_id': soupId,
      'raw_material_id': tomatoId,
      'quantity_used': 2.0,
    });

    // Helpers
    Future<double> colaStock() async {
      return ((await db.query('products', where: 'id = ?', whereArgs: [colaId])).first['stock'] as num).toDouble();
    }
    Future<double> tomatoStock() async {
      return ((await db.query('raw_materials', where: 'id = ?', whereArgs: [tomatoId])).first['stock'] as num).toDouble();
    }
    Future<double> soupStock() async {
      return ((await db.query('products', where: 'id = ?', whereArgs: [soupId])).first['stock'] as num).toDouble();
    }

    // Helper: بناء order + items وإدراجهم في DB محاكاةً لـ OrderRepository.createOrder
    Future<String> simulateSaleOrder({
      required String orderNumber,
      required List<Map<String, dynamic>> items, // [{productId, productName, qty, price, hasRecipe}]
    }) async {
      final orderId = uuid.v4();
      final now = DateTime.now().toIso8601String();

      await db.transaction((txn) async {
        // 1. إدراج الطلب
        await txn.insert('orders', {
          'id': orderId,
          'order_number': orderNumber,
          'subtotal': items.fold<double>(0, (s, i) => s + (i['qty'] as double) * (i['price'] as double)),
          'discount_amount': 0,
          'final_amount': items.fold<double>(0, (s, i) => s + (i['qty'] as double) * (i['price'] as double)),
          'paid_amount': items.fold<double>(0, (s, i) => s + (i['qty'] as double) * (i['price'] as double)),
          'change_amount': 0,
          'payment_method': 'cash',
          'order_type': 'takeaway',
          'status': 'completed',
          'created_at': now,
        });

        for (final item in items) {
          final itemId = uuid.v4();
          final productId = item['productId'] as String;
          final productName = item['productName'] as String;
          final qty = (item['qty'] as double);
          final price = (item['price'] as double);

          // استهلاك خامات لو Recipe
          final hasRecipe = await dbHelper.consumeRawMaterialsForOrder(
            txn,
            productId,
            qty,
            orderId: orderId,
            orderItemId: itemId,
          );

          final deductionType = hasRecipe ? 'recipe' : 'product';

          // إدراج order_item
          await txn.insert('order_items', {
            'id': itemId,
            'order_id': orderId,
            'product_id': productId,
            'product_name': productName,
            'unit_price': price,
            'quantity': qty,
            'total_price': qty * price,
            'deduction_type': deductionType,
          });

          if (!hasRecipe) {
            // خصم من stock المنتج
            final pRows = await txn.query('products', where: 'id = ?', whereArgs: [productId]);
            if (pRows.isNotEmpty) {
              final stockBefore = (pRows.first['stock'] as num).toDouble();
              if (stockBefore < qty) throw StateError('الرصيد غير كافٍ للصنف: $productName');
              final stockAfter = stockBefore - qty;
              await txn.update('products', {'stock': stockAfter, 'updated_at': now},
                  where: 'id = ?', whereArgs: [productId]);
              await txn.insert('stock_movements', {
                'id': DatabaseHelper.generateId(),
                'product_id': productId,
                'product_name': productName,
                'type': 'sale',
                'item_type': 'product',
                'quantity': qty,
                'stock_before': stockBefore,
                'stock_after': stockAfter,
                'order_id': orderId,
                'order_item_id': itemId,
                'reason': 'بيع',
                'created_at': now,
              });
            }
          }
        }
      });
      return orderId;
    }

    // ══════════════════════════════════════════════════════════════
    // TEST 1: Product without recipe
    // ══════════════════════════════════════════════════════════════
    print('\n--- Test 1: Product without recipe ---');
    final order1Id = await simulateSaleOrder(
      orderNumber: 'T-001',
      items: [{'productId': colaId, 'productName': 'Cola', 'qty': 3.0, 'price': 10.0}],
    );
    expect(await colaStock(), 47, reason: 'Cola stock should be 47 (50-3)');
    print('✅ Test 1 Passed: Cola stock = ${await colaStock()}');

    // ══════════════════════════════════════════════════════════════
    // TEST 2: Product with recipe
    // ══════════════════════════════════════════════════════════════
    print('\n--- Test 2: Product with recipe ---');
    final order2Id = await simulateSaleOrder(
      orderNumber: 'T-002',
      items: [{'productId': soupId, 'productName': 'Tomato Soup', 'qty': 2.0, 'price': 20.0}],
    );
    // 2 soups × 2 KG = 4 KG → 100 - 4 = 96
    expect(await tomatoStock(), 96, reason: 'Tomato should be 96 (100-4)');
    expect(await soupStock(), 0, reason: 'Soup product.stock stays 0');
    print('✅ Test 2 Passed: Tomato = ${await tomatoStock()}, Soup.stock = ${await soupStock()}');

    // ══════════════════════════════════════════════════════════════
    // TEST 3: Insufficient stock
    // ══════════════════════════════════════════════════════════════
    print('\n--- Test 3: Insufficient stock ---');
    bool thrown = false;
    try {
      await simulateSaleOrder(
        orderNumber: 'T-003',
        items: [{'productId': colaId, 'productName': 'Cola', 'qty': 999.0, 'price': 10.0}],
      );
    } on StateError {
      thrown = true;
    }
    expect(thrown, true, reason: 'Should throw StateError on insufficient stock');
    expect(await colaStock(), 47, reason: 'Cola stock should still be 47 after failed order');
    print('✅ Test 3 Passed: Exception thrown, stock unchanged = ${await colaStock()}');

    // ══════════════════════════════════════════════════════════════
    // TEST 4: Mixed order (product + recipe)
    // ══════════════════════════════════════════════════════════════
    print('\n--- Test 4: Mixed order (Cola×5 + Soup×1) ---');
    final order4Id = await simulateSaleOrder(
      orderNumber: 'T-004',
      items: [
        {'productId': colaId, 'productName': 'Cola', 'qty': 5.0, 'price': 10.0},
        {'productId': soupId, 'productName': 'Tomato Soup', 'qty': 1.0, 'price': 20.0},
      ],
    );
    // Cola: 47 - 5 = 42
    expect(await colaStock(), 42, reason: 'Cola should be 42 (47-5)');
    // Tomato: 96 - (1×2) = 94
    expect(await tomatoStock(), 94, reason: 'Tomato should be 94 (96-2)');
    print('✅ Test 4 Passed: Cola = ${await colaStock()}, Tomato = ${await tomatoStock()}');

    // ══════════════════════════════════════════════════════════════
    // TEST 5: Cancel product-based order → stock returns
    // ══════════════════════════════════════════════════════════════
    print('\n--- Test 5: Cancel product-based order (T-001, Cola×3) ---');
    // order1 had Cola×3, cancelling should return 3 → 42+3=45
    final orderRepo = _FakeOrderRepo(dbHelper);
    await orderRepo.cancelOrder(order1Id, db: db, uuid: uuid);

    expect(await colaStock(), 45, reason: 'Cola should be 45 after cancelling Cola×3');
    print('✅ Test 5 Passed: Cola stock after cancel = ${await colaStock()}');

    // ══════════════════════════════════════════════════════════════
    // TEST 6: Cancel recipe-based order → raw materials return
    // ══════════════════════════════════════════════════════════════
    print('\n--- Test 6: Cancel recipe-based order (T-002, Soup×2) ---');
    // order2 had Soup×2 → consumed 4 KG tomato → tomato should go back to 94+4=98
    await orderRepo.cancelOrder(order2Id, db: db, uuid: uuid);
    expect(await tomatoStock(), 98, reason: 'Tomato should be 98 after cancelling Soup×2');
    print('✅ Test 6 Passed: Tomato stock after cancel = ${await tomatoStock()}');

    // ══════════════════════════════════════════════════════════════
    // TEST 7: updateOrderItemQuantity – product (Cola×5→3 in order4)
    // ══════════════════════════════════════════════════════════════
    print('\n--- Test 7: updateOrderItemQuantity (product Cola 5→3) ---');
    final order4Items = await db.query('order_items', where: 'order_id = ?', whereArgs: [order4Id]);
    final colaOrderItem = order4Items.firstWhere((i) => i['product_id'] == colaId);
    final colaItemId = colaOrderItem['id'] as String;

    await dbHelper.updateOrderItemQuantity(
      orderId: order4Id,
      orderItemId: colaItemId,
      newQuantity: 3,
      userId: 'test-user',
      userName: 'Test User',
    );
    // After cancel in Test5, cola=45. Reducing order4 from 5→3 returns 2 → 45+2=47
    expect(await colaStock(), 47, reason: 'Cola should be 47 after reducing order qty 5→3');
    print('✅ Test 7 Passed: Cola after update = ${await colaStock()}');

    // ══════════════════════════════════════════════════════════════
    // TEST 8: updateOrderItemQuantity – recipe (Soup×1→3 in order4)
    // ══════════════════════════════════════════════════════════════
    print('\n--- Test 8: updateOrderItemQuantity (recipe Soup 1→3) ---');
    final soupOrderItem = order4Items.firstWhere((i) => i['product_id'] == soupId);
    final soupItemId = soupOrderItem['id'] as String;

    await dbHelper.updateOrderItemQuantity(
      orderId: order4Id,
      orderItemId: soupItemId,
      newQuantity: 3,
      userId: 'test-user',
      userName: 'Test User',
    );
    // After cancel in Test6, tomato=98. Increasing soup 1→3 = consume (3-1)×2=4 KG → 98-4=94
    expect(await tomatoStock(), 94, reason: 'Tomato should be 94 after increasing soup 1→3');
    print('✅ Test 8 Passed: Tomato after recipe update = ${await tomatoStock()}');

    print('\n══════════════════════════════════════════════════');
    print('✅ INVENTORY & SALES SMOKE TEST: ALL 8 TESTS PASSED');
    print('══════════════════════════════════════════════════');
  });
}

/// Helper class to simulate cancel without importing OrderRepository
class _FakeOrderRepo {
  final DatabaseHelper _dbHelper;
  _FakeOrderRepo(this._dbHelper);

  Future<void> cancelOrder(String orderId, {required dynamic db, required Uuid uuid}) async {
    final now = DateTime.now().toIso8601String();
    await db.transaction((txn) async {
      // تحديث status
      await txn.update('orders', {'status': 'cancelled'}, where: 'id = ?', whereArgs: [orderId]);

      // قراءة order_items
      final items = await txn.query('order_items', where: 'order_id = ?', whereArgs: [orderId]);
      for (final item in items) {
        final itemId = item['id'] as String;
        final productId = item['product_id'] as String;
        final productName = item['product_name'] as String;
        final qty = (item['quantity'] as num).toDouble();
        final deductionType = item['deduction_type'] as String? ?? 'product';

        if (deductionType == 'recipe') {
          // استرجع الخامات المستهلكة لهذا الصنف
          final consumed = await txn.rawQuery(
            '''SELECT product_id, SUM(quantity) AS total_qty, MAX(product_name) AS name
               FROM stock_movements
               WHERE order_id = ? AND order_item_id = ?
                 AND item_type = 'raw_material' AND type = 'consumption'
               GROUP BY product_id''',
            [orderId, itemId],
          );
          for (final move in consumed) {
            final rmId = move['product_id'] as String;
            final qtyBack = (move['total_qty'] as num).toDouble();
            final rmName = move['name'] as String;
            final rmRows = await txn.query('raw_materials', where: 'id = ?', whereArgs: [rmId]);
            if (rmRows.isEmpty) continue;
            final before = (rmRows.first['stock'] as num).toDouble();
            final after = before + qtyBack;
            await txn.update('raw_materials', {'stock': after, 'updated_at': now}, where: 'id = ?', whereArgs: [rmId]);
            await txn.insert('stock_movements', {
              'id': DatabaseHelper.generateId(),
              'product_id': rmId,
              'product_name': rmName,
              'type': 'return',
              'item_type': 'raw_material',
              'quantity': qtyBack,
              'stock_before': before,
              'stock_after': after,
              'order_id': orderId,
              'order_item_id': itemId,
              'reason': 'إلغاء الطلب',
              'created_at': now,
            });
          }
        } else {
          // استرجع stock المنتج
          final pRows = await txn.query('products', where: 'id = ?', whereArgs: [productId]);
          if (pRows.isEmpty) continue;
          final before = (pRows.first['stock'] as num).toDouble();
          final after = before + qty;
          await txn.update('products', {'stock': after, 'updated_at': now}, where: 'id = ?', whereArgs: [productId]);
          await txn.insert('stock_movements', {
            'id': DatabaseHelper.generateId(),
            'product_id': productId,
            'product_name': productName,
            'type': 'return',
            'item_type': 'product',
            'quantity': qty,
            'stock_before': before,
            'stock_after': after,
            'order_id': orderId,
            'order_item_id': itemId,
            'reason': 'إلغاء الطلب',
            'created_at': now,
          });
        }
      }
    });
  }
}
