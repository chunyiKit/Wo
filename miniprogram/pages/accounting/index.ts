import { api, familyPath, requireFamily, showError } from '../../core/api';
import { theme, applyTheme } from '../../core/theme';
import { hydrateAvatars } from '../../core/media';
import { epoch, onSessionChange } from '../../core/session';

interface Category { code: string; label: string; emoji: string }
interface Expense {
  id: string; amount: string | number; category: string; note: string | null;
  exclude_from_budget: boolean; created_at: string; creator_name: string | null;
  creator_emoji: string | null; creator_avatar_url: string | null;
}
interface ExpenseView extends Expense { money: string; categoryLabel: string; categoryEmoji: string; date: string }
interface Summary { month_total: string | number; budget: string | number | null; remaining: string | number | null; budgeted_total: string | number; excluded_total: string | number }
interface InputEvent { detail: { value: string }; currentTarget: { dataset: { id?: string; field?: string; code?: string } } }
const money = (amount: string | number | null) => amount === null ? '未设置' : Number(amount).toFixed(2);
const currentMonth = () => { const d = new Date(); return `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, '0')}`; };
const emptyForm = () => ({ amount: '', note: '', category: '', exclude_from_budget: false });
function localDateLabel(value: string): string {
  const date = new Date(value);
  if (Number.isNaN(date.getTime())) return '时间待确认';
  const pad = (part: number) => String(part).padStart(2, '0');
  return `${pad(date.getMonth() + 1)}-${pad(date.getDate())} ${pad(date.getHours())}:${pad(date.getMinutes())}`;
}
function expenseView(row: Expense, categories: Category[]): ExpenseView {
  const category = categories.find(c => c.code === row.category);
  return { ...row, money: money(row.amount), categoryLabel: category?.label || '其他', categoryEmoji: category?.emoji || '💰',
    date: localDateLabel(row.created_at) };
}

Page({
  data: {
    theme: theme(), month: currentMonth(), displayedMonth: '', loaded: false, loading: false,
    refreshing: false, error: '', items: [] as ExpenseView[], categories: [] as Category[],
    total: '0.00', budget: '未设置', remaining: '—', budgeted: '0.00', excluded: '0.00',
    editor: false, editingId: '', form: emptyForm(), submitting: false,
    budgetEditor: false, budgetInput: '', budgetSubmitting: false,
  },
  requestSequence: 0,
  disposed: false,
  scope: '',
  sessionEpoch: -1,
  unsubscribe: null as (() => void) | null,
  onLoad() { this.unsubscribe = onSessionChange(() => this.clearPrivateState()); },
  clearPrivateState() {
    this.requestSequence += 1; this.sessionEpoch = epoch();
    this.setData({ loaded: false, loading: false, refreshing: false, items: [], categories: [], editor: false, budgetEditor: false,
      form: emptyForm(), editingId: '', budgetInput: '', submitting: false, budgetSubmitting: false, error: '',
      total: '0.00', budget: '未设置', remaining: '—', budgeted: '0.00', excluded: '0.00', displayedMonth: '' });
  },
  onShow() {
    applyTheme(this);
    if (this.sessionEpoch !== epoch()) this.clearPrivateState();
    if (!requireFamily()) return;
    const scope = familyPath('accounting', '');
    if (this.scope !== scope) {
      this.scope = scope; this.clearPrivateState();
    }
    void this.load();
  },
  onUnload() { this.disposed = true; this.requestSequence += 1; this.unsubscribe?.(); },
  async onPullDownRefresh() { await this.load(); wx.stopPullDownRefresh(); },
  async load() {
    if (!requireFamily()) return;
    const sequence = ++this.requestSequence;
    const session = epoch();
    const month = this.data.month;
    const [year, monthNumber] = month.split('-');
    const query = `?year=${year}&month=${Number(monthNumber)}`;
    this.setData({ loading: !this.data.loaded, refreshing: this.data.loaded, error: '' });
    try {
      const [summary, rows, categories] = await Promise.all([
        api<Summary>(familyPath('accounting', `summary${query}`)),
        api<Expense[]>(familyPath('accounting', `transactions${query}`)),
        api<Category[]>(familyPath('accounting', 'categories')),
      ]);
      const hydrated = await hydrateAvatars(rows, ['creator_avatar_url']) as Expense[];
      if (sequence !== this.requestSequence || session !== epoch() || this.disposed) return;
      const items = hydrated.map(row => expenseView(row, categories));
      this.setData({ items, categories, loaded: true, displayedMonth: month,
        total: money(summary.month_total), budget: money(summary.budget), remaining: summary.remaining === null ? '—' : money(summary.remaining),
        budgeted: money(summary.budgeted_total), excluded: money(summary.excluded_total) });
    } catch (error) {
      if (sequence === this.requestSequence && session === epoch() && !this.disposed) this.setData({ error: error instanceof Error ? error.message : '账目加载失败，请重试' });
    } finally {
      if (sequence === this.requestSequence && session === epoch() && !this.disposed) this.setData({ loading: false, refreshing: false });
    }
  },
  // 后端已经确认的写入立即在屏幕上落地，后续读取失败也不撤回已成功的操作。
  storeConfirmedItems(items: ExpenseView[]) {
    const cents = (value: string | number) => Math.round(Number(value) * 100);
    const total = items.reduce((sum, row) => sum + cents(row.amount), 0);
    const excluded = items.filter(row => row.exclude_from_budget).reduce((sum, row) => sum + cents(row.amount), 0);
    const budgeted = total - excluded;
    this.setData({ items, total: (total / 100).toFixed(2), excluded: (excluded / 100).toFixed(2), budgeted: (budgeted / 100).toFixed(2),
      remaining: this.data.budget === '未设置' ? '—' : ((cents(this.data.budget) - budgeted) / 100).toFixed(2) });
  },
  retry() { void this.load(); },
  changeMonth(event: InputEvent) { this.setData({ month: event.detail.value }); void this.load(); },
  openNew() {
    if (!this.data.categories.length) { wx.showToast({ title: '请先加载记账分类', icon: 'none' }); return; }
    this.setData({ editor: true, editingId: '', form: { ...emptyForm(), category: this.data.categories[0].code } });
  },
  openEdit(event: InputEvent) {
    if (this.data.submitting) return;
    const row = this.data.items.find(item => item.id === event.currentTarget.dataset.id);
    if (!row) return;
    this.setData({ editor: true, editingId: row.id, form: { amount: String(row.amount), note: row.note || '', category: row.category, exclude_from_budget: row.exclude_from_budget } });
  },
  closeEditor() { if (!this.data.submitting) this.setData({ editor: false }); },
  updateField(event: InputEvent) {
    const field = event.currentTarget.dataset.field;
    if (field === 'amount' || field === 'note') this.setData({ [`form.${field}`]: event.detail.value });
  },
  selectCategory(event: InputEvent) { this.setData({ 'form.category': event.currentTarget.dataset.code || '' }); },
  toggleExclude(event: { detail: { value: boolean } }) { this.setData({ 'form.exclude_from_budget': event.detail.value }); },
  async submit() {
    if (this.data.submitting || !requireFamily()) return;
    const form = this.data.form;
    // Decimal 字符串保持分精度，拒绝指数记法和超过数据库范围的金额。
    if (!/^\d{1,10}(\.\d{1,2})?$/.test(form.amount) || Number(form.amount) <= 0) {
      wx.showToast({ title: '请输入大于 0、最多两位小数的金额', icon: 'none' }); return;
    }
    if (!this.data.categories.some(c => c.code === form.category)) return;
    const session = epoch();
    this.setData({ submitting: true });
    try {
      const id = this.data.editingId;
      const saved = await api<Expense>(familyPath('accounting', `transactions${id ? `/${id}` : ''}`), id ? 'PUT' : 'POST', {
        ...form, note: form.note.trim() || null,
      });
      if (session !== epoch() || this.disposed) return;
      const [hydrated] = await hydrateAvatars([saved], ['creator_avatar_url']) as Expense[];
      if (session !== epoch() || this.disposed) return;
      if (saved.created_at.slice(0, 7) === this.data.displayedMonth) {
        const row = expenseView(hydrated, this.data.categories);
        this.storeConfirmedItems([row, ...this.data.items.filter(item => item.id !== saved.id)].sort((a, b) => b.created_at.localeCompare(a.created_at)));
      }
      this.setData({ editor: false });
      wx.showToast({ title: id ? '已保存' : '已记下', icon: 'success' });
      await this.load();
    } catch (error) { if (session === epoch() && !this.disposed) showError(error); }
    finally { if (session === epoch() && !this.disposed) this.setData({ submitting: false }); }
  },
  deleteExpense(event: InputEvent) {
    const id = event.currentTarget.dataset.id;
    if (!id || this.data.submitting) return;
    const session = epoch();
    wx.showModal({ title: '删除这笔支出？', content: '删除后无法恢复。', confirmText: '删除', confirmColor: '#c75e50', success: async (result: { confirm: boolean }) => {
      if (!result.confirm || session !== epoch() || this.disposed || this.data.submitting || !requireFamily()) return;
      this.setData({ submitting: true });
      try {
        await api(familyPath('accounting', `transactions/${id}`), 'DELETE');
        if (session !== epoch() || this.disposed) return;
        this.storeConfirmedItems(this.data.items.filter(item => item.id !== id)); await this.load();
      }
      catch (error) { if (session === epoch() && !this.disposed) showError(error); }
      finally { if (session === epoch() && !this.disposed) this.setData({ submitting: false }); }
    } });
  },
  openBudget() { this.setData({ budgetEditor: true, budgetInput: this.data.budget === '未设置' ? '' : this.data.budget }); },
  closeBudget() { if (!this.data.budgetSubmitting) this.setData({ budgetEditor: false }); },
  updateBudget(event: InputEvent) { this.setData({ budgetInput: event.detail.value }); },
  async saveBudget() {
    if (this.data.budgetSubmitting || !requireFamily()) return;
    if (!/^\d{1,10}(\.\d{1,2})?$/.test(this.data.budgetInput) || Number(this.data.budgetInput) <= 0) {
      wx.showToast({ title: '请输入有效的每月预算', icon: 'none' }); return;
    }
    const session = epoch();
    this.setData({ budgetSubmitting: true });
    try {
      await api(familyPath('accounting', 'budget'), 'PUT', { monthly_amount: this.data.budgetInput });
      if (session !== epoch() || this.disposed) return;
      this.setData({ budgetEditor: false, budget: money(this.data.budgetInput) }); this.storeConfirmedItems(this.data.items); await this.load();
    } catch (error) { if (session === epoch() && !this.disposed) showError(error); }
    finally { if (session === epoch() && !this.disposed) this.setData({ budgetSubmitting: false }); }
  },
});
