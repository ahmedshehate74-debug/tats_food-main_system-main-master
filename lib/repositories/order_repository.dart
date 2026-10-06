import '../core/database/database_helper.dart';
import '../core/services/session_service.dart';
import '../models/order.dart';

class OrderRepository {
  final DatabaseHelper _db = DatabaseHelper.instance;

  Future<Order> createOrder({
    required Order order,
    required List<OrderItem> items,
  }) async {
    // اربط الأوردر بالشيفت المفتوح حاليًا (لو موجود) علشان يدخل في إحصائيات الشيفت
    final currentShift = await _db.getCurrentShift();
    final currentUser = SessionService.instance.currentUser;
    if (currentShift != null &&
        currentUser?.id != currentShift['user_id'] as String?) {
      throw StateError('لا يمكن تسجيل عملية أثناء شيفت مستخدم آخر');
    }

    await _db.runTransaction((txn) async {
      final orderMap = order.toMap();
      if (currentShift != null) {
        orderMap['shift_id'] = currentShift['id'];
      }
      await txn.insert('orders', orderMap);

      final debitCode =
          order.paymentMethod == PaymentMethod.cash ? '1.1' : '1.2';
      final revenueCode = order.orderType == OrderType.delivery
          ? '4.3'
          : order.paymentMethod == PaymentMethod.cash
              ? '4.1'
              : '4.2';
      final debitAccount = await _db.getAccountIdByCode(txn, debitCode);
      final revenueAccount = await _db.getAccountIdByCode(txn, revenueCode);
      if (debitAccount != null && revenueAccount != null) {
        await _db.postJournalEntryInTransaction(
          txn,
          accountId: debitAccount,
          debit: order.finalAmount,
          description: 'تحصيل طلب #${order.orderNumber}',
          refType: 'sale',
          refId: order.id,
          shiftId: currentShift?['id'] as String?,
          userId: order.userId,
        );
        await _db.postJournalEntryInTransaction(
          txn,
          accountId: revenueAccount,
          credit: order.finalAmount,
          description: 'إيراد طلب #${order.orderNumber}',
          refType: 'sale',
          refId: order.id,
          shiftId: currentShift?['id'] as String?,
          userId: order.userId,
        );
      }

      for (final item in items) {
        final hasRecipe = await _db.consumeRawMaterialsForOrder(
          txn,
          item.productId,
          item.quantity,
          orderId: order.id,
          orderItemId: item.id,
        );

        // سجّل deduction_type في order_items داخل نفس الـ transaction
        final deductionType = hasRecipe ? 'recipe' : 'product';
        await txn.insert('order_items', {
          ...item.toMap(),
          'deduction_type': deductionType,
        });

        if (!hasRecipe) {
          final productRows = await txn.query(
            'products',
            where: 'id = ?',
            whereArgs: [item.productId],
          );
          if (productRows.isNotEmpty) {
            final stockBefore = (productRows.first['stock'] as num).toDouble();
            final productName = productRows.first['name'] as String;

            if (stockBefore < item.quantity) {
              throw StateError('الرصيد غير كافٍ للصنف: $productName');
            }

            final stockAfter = stockBefore - item.quantity;

            await txn.update(
              'products',
              {'stock': stockAfter, 'updated_at': DateTime.now().toIso8601String()},
              where: 'id = ?',
              whereArgs: [item.productId],
            );

            await txn.insert('stock_movements', {
              'id': DatabaseHelper.generateId(),
              'product_id': item.productId,
              'product_name': productName,
              'type': 'sale',
              'item_type': 'product',
              'quantity': item.quantity,
              'stock_before': stockBefore,
              'stock_after': stockAfter,
              'order_id': order.id,
              'order_item_id': item.id,
              'reason': 'بيع',
              'user_id': order.userId,
              'created_at': DateTime.now().toIso8601String(),
            });
          }
        }
      }
    });

    return order.copyWith(items: items);
  }

  Future<List<Order>> getAll({
    DateTime? from,
    DateTime? to,
    OrderStatus? status,
    int? limit,
    int? offset,
  }) async {
    final conditions = <String>[];
    final args = <dynamic>[];

    if (from != null) {
      conditions.add("date(created_at) >= date(?)");
      args.add(from.toIso8601String());
    }
    if (to != null) {
      conditions.add("date(created_at) <= date(?)");
      args.add(to.toIso8601String());
    }
    if (status != null) {
      conditions.add("status = ?");
      args.add(status.name);
    }

    final results = await _db.query(
      'orders',
      where: conditions.isEmpty ? null : conditions.join(' AND '),
      whereArgs: args.isEmpty ? null : args,
      orderBy: 'created_at DESC',
      limit: limit,
      offset: offset,
    );

    return results.map((map) => Order.fromMap(map)).toList();
  }

  Future<Order?> getById(String id) async {
    final orderResults = await _db.query(
      'orders',
      where: 'id = ?',
      whereArgs: [id],
    );
    if (orderResults.isEmpty) return null;

    final itemResults = await _db.query(
      'order_items',
      where: 'order_id = ?',
      whereArgs: [id],
    );
    final items = itemResults.map(OrderItem.fromMap).toList();

    return Order.fromMap(orderResults.first, items: items);
  }

  Future<List<OrderItem>> getItemsByOrderId(String orderId) async {
    final results = await _db.query(
      'order_items',
      where: 'order_id = ?',
      whereArgs: [orderId],
    );
    return results.map(OrderItem.fromMap).toList();
  }

  /// إحصائيات المبيعات
  Future<Map<String, dynamic>> getSalesStats({
    DateTime? from,
    DateTime? to,
  }) async {
    final fromStr =
        (from ?? DateTime.now().copyWith(hour: 0, minute: 0, second: 0))
            .toIso8601String();
    final toStr = (to ?? DateTime.now()).toIso8601String();

    final result = await _db.rawQuery(
      '''
      SELECT 
        COUNT(*) as order_count,
        COALESCE(SUM(final_amount), 0) as total_sales,
        COALESCE(AVG(final_amount), 0) as avg_order
      FROM orders
      WHERE status = 'completed'
        AND created_at >= ?
        AND created_at <= ?
    ''',
      [fromStr, toStr],
    );

    final itemsResult = await _db.rawQuery(
      '''
      SELECT COALESCE(SUM(oi.quantity), 0) as items_sold
      FROM order_items oi
      JOIN orders o ON oi.order_id = o.id
      WHERE o.status = 'completed'
        AND o.created_at >= ?
        AND o.created_at <= ?
    ''',
      [fromStr, toStr],
    );

    return {
      'order_count': result.first['order_count'],
      'total_sales': result.first['total_sales'],
      'avg_order': result.first['avg_order'],
      'items_sold': itemsResult.first['items_sold'],
    };
  }

  /// أكثر الأصناف مبيعاً
  Future<List<Map<String, dynamic>>> getTopProducts({
    int limit = 10,
    DateTime? from,
    DateTime? to,
  }) async {
    final fromStr = (from ?? DateTime.now().subtract(const Duration(days: 30)))
        .toIso8601String();
    final toStr = (to ?? DateTime.now()).toIso8601String();

    return await _db.rawQuery(
      '''
      SELECT 
        oi.product_id,
        oi.product_name,
        SUM(oi.quantity) as total_qty,
        SUM(oi.total_price) as total_revenue
      FROM order_items oi
      JOIN orders o ON oi.order_id = o.id
      WHERE o.status = 'completed'
        AND o.created_at >= ?
        AND o.created_at <= ?
      GROUP BY oi.product_id, oi.product_name
      ORDER BY total_qty DESC
      LIMIT ?
    ''',
      [fromStr, toStr, limit],
    );
  }

  /// المبيعات حسب طريقة الدفع
  Future<List<Map<String, dynamic>>> getSalesByPaymentMethod({
    DateTime? from,
    DateTime? to,
  }) async {
    final fromStr =
        (from ?? DateTime.now().copyWith(hour: 0, minute: 0, second: 0))
            .toIso8601String();
    final toStr = (to ?? DateTime.now()).toIso8601String();

    return await _db.rawQuery(
      '''
      SELECT 
        payment_method,
        COUNT(*) as count,
        SUM(final_amount) as total
      FROM orders
      WHERE status = 'completed'
        AND created_at >= ?
        AND created_at <= ?
      GROUP BY payment_method
    ''',
      [fromStr, toStr],
    );
  }

  /// مبيعات الشيفت الحالي (أو أي شيفت بالـ id)
  Future<Map<String, dynamic>> getShiftSales(String shiftId) =>
      _db.getShiftSummary(shiftId);

  Future<void> cancelOrder(
    String id, {
    String? reason,
    String? userId,
    bool restoreStock = true,
  }) async {
    final order = await getById(id);
    if (order == null) return;
    if (order.status == OrderStatus.cancelled) return; // منع التكرار

    await _db.runTransaction((txn) async {
      // 1) تحديث حالة الطلب
      await txn.update(
        'orders',
        {'status': OrderStatus.cancelled.name},
        where: 'id = ?',
        whereArgs: [id],
      );

      if (!restoreStock) return;

      bool oldOrderRawRestored = false;

      // 2) استرجاع المخزون بناءً على deduction_type المحفوظ وقت البيع
      for (final item in order.items) {
        // قراءة deduction_type الفعلي من DB (المصدر الحقيقي)
        final itemRows = await txn.query(
          'order_items',
          where: 'id = ?',
          whereArgs: [item.id],
        );
        final dbDeductionType = itemRows.isNotEmpty
            ? itemRows.first['deduction_type'] as String?
            : null;

        // ─── تحديد نوع الاسترجاع ─────────────────────────────────
        // الطلبات الجديدة: deduction_type = 'recipe' أو 'product' (مؤكد)
        // الطلبات القديمة: deduction_type = 'product' (default) لكن غير موثوق
        //                  → نفحص stock_movements لتحديد النوع الفعلي
        final bool isKnownNew = (dbDeductionType == 'recipe' || dbDeductionType == 'product');

        String resolvedType;
        if (isKnownNew) {
          resolvedType = dbDeductionType!;
        } else {
          // طلب قديم: نستنتج النوع من stock_movements للطلب ككل
          final rawMoves = await txn.rawQuery(
            '''SELECT COUNT(*) AS cnt FROM stock_movements
               WHERE order_id = ? AND item_type = 'raw_material' AND type = 'consumption' ''',
            [id],
          );
          final productMoves = await txn.rawQuery(
            '''SELECT COUNT(*) AS cnt FROM stock_movements
               WHERE order_id = ? AND item_type = 'product' AND type = 'sale' ''',
            [id],
          );
          final rawCount = (rawMoves.first['cnt'] as int?) ?? 0;
          final prodCount = (productMoves.first['cnt'] as int?) ?? 0;

          if (rawCount > 0 && prodCount == 0) {
            resolvedType = 'recipe';
          } else if (prodCount > 0 && rawCount == 0) {
            resolvedType = 'product';
          } else {
            // بيانات غير كافية أو متضاربة — لا تخمّن
            throw StateError(
              'لا يمكن إلغاء هذا الطلب القديم بأمان لأن طريقة خصم المخزون لـ "${item.productName}" غير معروفة أو متضاربة.',
            );
          }
        }

        // ─── استرجاع بناءً على النوع المحدد ──────────────────────
        if (resolvedType == 'recipe') {
          if (isKnownNew) {
            // طلب جديد: استرجع خامات هذا السطر تحديداً باستخدام order_item_id
            final consumedMoves = await txn.rawQuery(
              '''SELECT product_id, SUM(quantity) AS total_qty, MAX(product_name) AS name
                 FROM stock_movements
                 WHERE order_id = ? AND order_item_id = ?
                   AND item_type = 'raw_material'
                   AND type = 'consumption'
                 GROUP BY product_id''',
              [id, item.id],
            );

            final now = DateTime.now().toIso8601String();
            for (final move in consumedMoves) {
              final rmId = move['product_id'] as String;
              final qtyToRestore = (move['total_qty'] as num).toDouble();
              final rmName = move['name'] as String;

              final rmRows = await txn.query('raw_materials', where: 'id = ?', whereArgs: [rmId]);
              if (rmRows.isEmpty) continue;

              final before = (rmRows.first['stock'] as num).toDouble();
              final after = before + qtyToRestore;

              await txn.update('raw_materials', {'stock': after, 'updated_at': now},
                  where: 'id = ?', whereArgs: [rmId]);
              await txn.insert('stock_movements', {
                'id': DatabaseHelper.generateId(),
                'product_id': rmId,
                'product_name': rmName,
                'type': 'return',
                'item_type': 'raw_material',
                'quantity': qtyToRestore,
                'stock_before': before,
                'stock_after': after,
                'order_id': id,
                'order_item_id': item.id,
                'reason': reason ?? 'إرجاع خامات - إلغاء الطلب',
                'created_at': now,
              });
            }
          } else {
            // طلب قديم (لا يوجد order_item_id): نسترجع كل خامات الطلب مرة واحدة فقط
            if (!oldOrderRawRestored) {
              final consumedMoves = await txn.rawQuery(
                '''SELECT product_id, SUM(quantity) AS total_qty, MAX(product_name) AS name
                   FROM stock_movements
                   WHERE order_id = ?
                     AND item_type = 'raw_material'
                     AND type = 'consumption'
                   GROUP BY product_id''',
                [id],
              );

              final now = DateTime.now().toIso8601String();
              for (final move in consumedMoves) {
                final rmId = move['product_id'] as String;
                final qtyToRestore = (move['total_qty'] as num).toDouble();
                final rmName = move['name'] as String;

                final rmRows = await txn.query('raw_materials', where: 'id = ?', whereArgs: [rmId]);
                if (rmRows.isEmpty) continue;

                final before = (rmRows.first['stock'] as num).toDouble();
                final after = before + qtyToRestore;

                await txn.update('raw_materials', {'stock': after, 'updated_at': now},
                    where: 'id = ?', whereArgs: [rmId]);
                await txn.insert('stock_movements', {
                  'id': DatabaseHelper.generateId(),
                  'product_id': rmId,
                  'product_name': rmName,
                  'type': 'return',
                  'item_type': 'raw_material',
                  'quantity': qtyToRestore,
                  'stock_before': before,
                  'stock_after': after,
                  'order_id': id,
                  'reason': reason ?? 'إرجاع خامات - إلغاء الطلب (طلب قديم)',
                  'created_at': now,
                });
              }
              oldOrderRawRestored = true;
            }
          }
        } else {
          // resolvedType == 'product' → استرجع product.stock
          final productRows = await txn.query(
            'products',
            where: 'id = ?',
            whereArgs: [item.productId],
          );
          if (productRows.isEmpty) continue;

          final stockBefore = (productRows.first['stock'] as num).toDouble();
          final stockAfter = stockBefore + item.quantity;

          await txn.update(
            'products',
            {'stock': stockAfter, 'updated_at': DateTime.now().toIso8601String()},
            where: 'id = ?',
            whereArgs: [item.productId],
          );
          await txn.insert('stock_movements', {
            'id': DatabaseHelper.generateId(),
            'product_id': item.productId,
            'product_name': item.productName,
            'type': 'return',
            'item_type': 'product',
            'quantity': item.quantity,
            'stock_before': stockBefore,
            'stock_after': stockAfter,
            'order_id': id,
            'order_item_id': isKnownNew ? item.id : null,
            'reason': reason ?? 'إلغاء الطلب',
            'user_id': userId,
            'created_at': DateTime.now().toIso8601String(),
          });
        }
      }
    });
  }
}

extension OrderCopyWith on Order {
  Order copyWith({List<OrderItem>? items}) {
    return Order(
      id: id,
      orderNumber: orderNumber,
      userId: userId,
      userName: userName,
      subtotal: subtotal,
      discountAmount: discountAmount,
      finalAmount: finalAmount,
      paidAmount: paidAmount,
      changeAmount: changeAmount,
      paymentMethod: paymentMethod,
      paymentRef: paymentRef,
      status: status,
      notes: notes,
      items: items ?? this.items,
      createdAt: createdAt,
    );
  }
}
