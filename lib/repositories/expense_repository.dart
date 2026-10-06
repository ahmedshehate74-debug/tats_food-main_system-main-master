import '../core/database/database_helper.dart';
import '../core/services/session_service.dart';
import '../models/expense.dart';

class ExpenseRepository {
  final DatabaseHelper _db = DatabaseHelper.instance;

  Future<List<Expense>> getAll({
    DateTime? from,
    DateTime? to,
    int? limit,
    int? offset,
  }) async {
    final conditions = <String>[];
    final args = <dynamic>[];

    if (from != null) {
      conditions.add("date(date) >= date(?)");
      args.add(from.toIso8601String());
    }
    if (to != null) {
      conditions.add("date(date) <= date(?)");
      args.add(to.toIso8601String());
    }

    final results = await _db.query(
      'expenses',
      where: conditions.isEmpty ? null : conditions.join(' AND '),
      whereArgs: args.isEmpty ? null : args,
      orderBy: 'date DESC',
      limit: limit,
      offset: offset,
    );
    return results.map(Expense.fromMap).toList();
  }

  Future<void> insert(Expense expense) async {
    await _ensureShiftAccess();
    final shift = await _db.getCurrentShift();
    // إدراج ذري: المصروف + قيوده المحاسبية في Transaction واحدة
    await _db.insertExpenseAtomic(
      id: expense.id,
      category: expense.category,
      amount: expense.amount,
      description: expense.description,
      userId: expense.userId,
      shiftId: shift?['id'] as String?,
      date: expense.date,
    );
  }

  Future<void> update(Expense expense) async {
    await _ensureShiftAccess();
    // تعديل ذري: عكس القيود القديمة + تطبيق الجديدة في Transaction واحدة
    await _db.updateExpenseWithReversal(
      id: expense.id,
      newCategory: expense.category,
      newAmount: expense.amount,
      newDescription: expense.description,
      userId: expense.userId,
    );
  }

  Future<void> _ensureShiftAccess() async {
    final user = SessionService.instance.currentUser;
    if (user?.role.name == 'manager') return; // الأدمن يسجل مصروف في أي وقت

    final shift = await _db.getCurrentShift();
    if (shift != null && user?.id != shift['user_id'] as String?) {
      throw StateError('لا يمكن تسجيل مصروف أثناء شيفت مستخدم آخر');
    }
  }

  Future<void> delete(String id) async {
    // حذف ذري: عكس القيود المحاسبية + حذف السجل في Transaction واحدة
    await _db.deleteExpenseWithReversal(id);
  }

  Future<double> getTotalByDateRange(DateTime from, DateTime to) async {
    final result = await _db.rawQuery(
      "SELECT COALESCE(SUM(amount), 0) as total FROM expenses WHERE date(date) >= date(?) AND date(date) <= date(?)",
      [from.toIso8601String(), to.toIso8601String()],
    );
    return (result.first['total'] as num).toDouble();
  }
}

/*
import '../core/database/database_helper.dart';

class ExpenseRepository {
  final _db = DatabaseHelper.instance;

  Future<List<Map<String, dynamic>>> getAll({
    DateTime? from,
    DateTime? to,
    String? shiftId,
  }) async {
    final conditions = <String>[];
    final args = <dynamic>[];

    if (shiftId != null) {
      conditions.add('shift_id = ?');
      args.add(shiftId);
    }
    if (from != null) {
      conditions.add('date(date) >= date(?)');
      args.add(from.toIso8601String());
    }
    if (to != null) {
      conditions.add('date(date) <= date(?)');
      args.add(to.toIso8601String());
    }

    return _db.query(
      'expenses',
      where: conditions.isEmpty ? null : conditions.join(' AND '),
      whereArgs: args.isEmpty ? null : args,
      orderBy: 'created_at DESC',
    );
  }

  Future<String> addExpense({
    required String category,
    required double amount,
    String? description,
    required String userId,
    String? shiftId,
  }) async {
    final id = DatabaseHelper.generateId();
    final now = DateTime.now().toIso8601String();
    await _db.insert('expenses', {
      'id': id,
      'category': category,
      'amount': amount,
      'description': description,
      'user_id': userId,
      'shift_id': shiftId,
      'date': now,
      'created_at': now,
    });
    return id;
  }

  Future<void> delete(String id) => _db.delete('expenses', 'id = ?', [id]);

  Future<double> getTotal({String? shiftId, DateTime? from, DateTime? to}) async {
    final rows = await getAll(shiftId: shiftId, from: from, to: to);
    double total = 0;
    for (final r in rows) {
      total += (r['amount'] as num).toDouble();
    }
    return total;
  }
}*/
