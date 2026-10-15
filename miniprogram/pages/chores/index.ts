import { api, familyPath, requireFamily, showError } from '../../core/api';
import { theme, applyTheme } from '../../core/theme';
import { hydrateAvatars } from '../../core/media';
import { epoch, onSessionChange } from '../../core/session';

interface Chore {
  id: string; title: string; note: string | null; emoji: string; assigned_to: string | null;
  done: boolean; recurring: boolean; assignee_name: string | null; assignee_emoji: string | null;
  assignee_avatar_url: string | null;
}
interface Member { user_id: string; display_name: string; avatar_emoji: string; avatar_url: string | null; status: string }
interface Event { currentTarget: { dataset: { id?: string; filter?: string } }; detail: { value: string } }
const emptyForm = () => ({ title: '', note: '', emoji: '🧹', assigned_to: null as string | null, recurring: false });

Page({
  data: {
    theme: theme(), loaded: false, loading: false, refreshing: false, error: '',
    items: [] as Chore[], visible: [] as Chore[], members: [] as Member[],
    filter: 'open', openCount: 0, doneCount: 0, editor: false, editingId: '',
    form: emptyForm(), submitting: false, pendingIds: [] as string[],
  },
  sessionEpoch: -1,
  requestSequence: 0,
  disposed: false,
  unsubscribe: null as (() => void) | null,
  onLoad() { this.unsubscribe = onSessionChange(() => this.clearPrivateState()); },
  clearPrivateState() {
    this.sessionEpoch = epoch(); this.requestSequence += 1;
    this.setData({ loaded: false, loading: false, refreshing: false, items: [], visible: [], members: [], editor: false,
      form: emptyForm(), editingId: '', openCount: 0, doneCount: 0, pendingIds: [], submitting: false, error: '' });
  },
  onShow() {
    applyTheme(this);
    if (this.sessionEpoch !== epoch()) {
      this.clearPrivateState();
    }
    if (requireFamily()) void this.load();
  },
  onUnload() { this.disposed = true; this.requestSequence += 1; this.unsubscribe?.(); },
  async onPullDownRefresh() { await this.load(); wx.stopPullDownRefresh(); },
  async load() {
    if (!requireFamily()) return;
    const sequence = ++this.requestSequence;
    const session = epoch();
    this.setData({ loading: !this.data.loaded, refreshing: this.data.loaded, error: '' });
    try {
      const choresPath = familyPath('chore', 'chores');
      const membersPath = choresPath.slice(0, choresPath.indexOf('/plugins/')) + '/members';
      const [rows, members] = await Promise.all([api<Chore[]>(choresPath), api<Member[]>(membersPath)]);
      const [items, avatars] = await Promise.all([
        hydrateAvatars(rows, ['assignee_avatar_url']) as Promise<Chore[]>,
        hydrateAvatars(members.filter(member => member.status === 'active'), ['avatar_url']) as Promise<Member[]>,
      ]);
      if (sequence !== this.requestSequence || session !== epoch() || this.disposed) return;
      this.setData({ items, members: avatars, loaded: true }); this.filterItems();
    } catch (error) {
      if (sequence === this.requestSequence && session === epoch() && !this.disposed) this.setData({ error: error instanceof Error ? error.message : '家务加载失败，请重试' });
    } finally {
      if (sequence === this.requestSequence && session === epoch() && !this.disposed) this.setData({ loading: false, refreshing: false });
    }
  },
  retry() { void this.load(); },
  filterItems() {
    const { items, filter } = this.data;
    this.setData({ visible: items.filter(item => filter === 'all' || item.done === (filter === 'done')),
      openCount: items.filter(item => !item.done).length, doneCount: items.filter(item => item.done).length });
  },
  changeFilter(event: Event) {
    const filter = event.currentTarget.dataset.filter;
    if (filter === 'open' || filter === 'done' || filter === 'all') { this.setData({ filter }); this.filterItems(); }
  },
  openNew() { if (this.data.submitting || this.data.pendingIds.length) return; this.setData({ editor: true, editingId: '', form: emptyForm() }); },
  openEdit(event: Event) {
    if (this.data.submitting || this.data.pendingIds.length) return;
    const row = this.data.items.find(item => item.id === event.currentTarget.dataset.id);
    if (!row) return;
    this.setData({ editor: true, editingId: row.id, form: { title: row.title, note: row.note || '', emoji: row.emoji, assigned_to: row.assigned_to, recurring: row.recurring } });
  },
  closeEditor() { if (!this.data.submitting) this.setData({ editor: false }); },
  updateTitle(event: Event) { this.setData({ 'form.title': event.detail.value }); },
  updateNote(event: Event) { this.setData({ 'form.note': event.detail.value }); },
  updateEmoji(event: Event) { this.setData({ 'form.emoji': event.detail.value }); },
  selectMember(event: Event) {
    const id = event.currentTarget.dataset.id || null;
    if (id === null || this.data.members.some(member => member.user_id === id)) this.setData({ 'form.assigned_to': id });
  },
  toggleRecurring(event: { detail: { value: boolean } }) { this.setData({ 'form.recurring': event.detail.value }); },
  async submit() {
    if (this.data.submitting || !requireFamily()) return;
    const form = this.data.form;
    if (!form.title.trim()) { wx.showToast({ title: '给家务起个名字吧', icon: 'none' }); return; }
    const session = epoch();
    this.setData({ submitting: true });
    try {
      const id = this.data.editingId;
      const saved = await api<Chore>(familyPath('chore', `chores${id ? `/${id}` : ''}`), id ? 'PUT' : 'POST', {
        ...form, title: form.title.trim(), emoji: form.emoji.trim() || '🧹', note: form.note.trim() || null,
      });
      if (session !== epoch() || this.disposed) return;
      const [hydrated] = await hydrateAvatars([saved], ['assignee_avatar_url']) as Chore[];
      if (session !== epoch() || this.disposed) return;
      this.setData({ items: [hydrated, ...this.data.items.filter(item => item.id !== saved.id)], editor: false }); this.filterItems(); wx.showToast({ title: id ? '已保存' : '家务已添加', icon: 'success' });
      await this.load();
    } catch (error) { if (session === epoch() && !this.disposed) showError(error); }
    finally { if (session === epoch() && !this.disposed) this.setData({ submitting: false }); }
  },
  async toggleDone(event: Event) {
    const id = event.currentTarget.dataset.id;
    const row = this.data.items.find(item => item.id === id);
    if (!id || !row || this.data.pendingIds.includes(id) || !requireFamily()) return;
    const session = epoch();
    this.setData({ pendingIds: [...this.data.pendingIds, id] });
    try {
      await api<Chore>(familyPath('chore', `chores/${id}/${row.done ? 'reopen' : 'complete'}`), 'POST');
      if (session !== epoch() || this.disposed) return;
      // 已确认的操作先就地更新；刷新失败仍保留操作结果。
      this.setData({ items: this.data.items.map(item => item.id === id ? { ...item, done: !row.done } : item) });
      this.filterItems(); await this.load();
    } catch (error) { if (session === epoch() && !this.disposed) showError(error); }
    finally { if (session === epoch() && !this.disposed) this.setData({ pendingIds: this.data.pendingIds.filter(value => value !== id) }); }
  },
  deleteChore(event: Event) {
    const id = event.currentTarget.dataset.id;
    const row = this.data.items.find(item => item.id === id);
    if (!id || !row || this.data.pendingIds.includes(id)) return;
    const session = epoch();
    wx.showModal({ title: '删除家务？', content: `确定删除「${row.title}」吗？删除后无法恢复。`, confirmText: '删除', confirmColor: '#c75e50', success: async (result: { confirm: boolean }) => {
      if (!result.confirm || session !== epoch() || this.disposed || this.data.pendingIds.includes(id) || !requireFamily()) return;
      this.setData({ pendingIds: [...this.data.pendingIds, id] });
      try {
        await api(familyPath('chore', `chores/${id}`), 'DELETE');
        if (session !== epoch() || this.disposed) return;
        this.setData({ items: this.data.items.filter(item => item.id !== id) }); this.filterItems(); await this.load();
      } catch (error) { if (session === epoch() && !this.disposed) showError(error); }
      finally { if (session === epoch() && !this.disposed) this.setData({ pendingIds: this.data.pendingIds.filter(value => value !== id) }); }
    } });
  },
});
