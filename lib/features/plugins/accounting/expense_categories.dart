/// 内置支出标签：餐饮、购物、水电、养车。
///
/// 后端只存 [code]（稳定标识），label/emoji 在客户端定义。
class ExpenseCategory {
  const ExpenseCategory(this.code, this.label, this.emoji);

  final String code;
  final String label;
  final String emoji;
}

const expenseCategories = <ExpenseCategory>[
  ExpenseCategory('dining', '餐饮', '🍜'),
  ExpenseCategory('shopping', '购物', '🛍️'),
  ExpenseCategory('utilities', '水电', '💡'),
  ExpenseCategory('car', '养车', '🚗'),
];

ExpenseCategory categoryFor(String code) => expenseCategories.firstWhere(
      (c) => c.code == code,
      orElse: () => const ExpenseCategory('', '其他', '💰'),
    );
