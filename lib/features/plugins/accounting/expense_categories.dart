import '../../../data/models.dart';

export '../../../data/models.dart' show ExpenseCategory;

/// 内置分类用于默认值；实际家庭分类由服务端返回。
const expenseCategories = <ExpenseCategory>[
  ExpenseCategory('dining', '餐饮', '🍜'),
  ExpenseCategory('snack', '零食', '🍭'),
  ExpenseCategory('shopping', '购物', '🛍️'),
  ExpenseCategory('utilities', '水电', '💡'),
  ExpenseCategory('car', '养车', '🚗'),
  ExpenseCategory('pet', '宠物', '🐾'),
  ExpenseCategory('subscription', '软件/订阅', '💳'),
];

ExpenseCategory categoryFor(
  String code, [
  List<ExpenseCategory> categories = expenseCategories,
]) =>
    categories.firstWhere(
      (c) => c.code == code,
      orElse: () => const ExpenseCategory('', '其他', '💰'),
    );
