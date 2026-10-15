import { api, familyPath, requireFamily, showError } from '../../core/api';
import { getSession, epoch, assertEpoch, onSessionChange } from '../../core/session';
import { privateMedia, hydrateAvatars, upload } from '../../core/media';
import { theme, applyTheme } from '../../core/theme';
import { addMemoryImage, clearMemoryDrafts, MAX_IMAGES, newMemoryDraft, readMemoryDraft, removeMemoryImage, saveMemoryDraft, writeMemoryDraft } from '../../core/memory-draft';
import type { MemoryDraft, MemoryScope } from '../../core/memory-draft';

interface MemoryRow {
  id: string; title: string; body: string; event_date: string; visibility: string;
  author_name?: string; author_emoji?: string; author_avatar_url?: string;
  avatarSource?: string;
  media: { id: string; kind: string; url: string; local?: string }[];
}
Page({
  data: {
    theme: theme(), items: [] as MemoryRow[], loaded: false, loading: false, error: '', refreshError: '',
    editor: false, draft: null as MemoryDraft | null, restored: false, saving: false, picking: false,
    previewingId: '', imageError: '', imageErrorMemory: '',
    saveError: '', visibilityLabels: ['仅自己可见', '分享给家庭'], visibilityIndex: 0,
  },
  _epoch: -1,
  _scope: null as MemoryScope | null,
  _alive: true,
  _request: 0,
  _unsubscribe: null as (() => void) | null,
  onLoad() {
    this._alive = true;
    this._unsubscribe = onSessionChange(() => this.clearPrivateState());
  },
  clearPrivateState() {
    this._epoch = -1;
    this._scope = null;
    this._request++;
    this.setData({ items: [], loaded: false, loading: false, editor: false, draft: null, restored: false,
      error: '', refreshError: '', saveError: '', saving: false, picking: false, visibilityIndex: 0,
      previewingId: '', imageError: '', imageErrorMemory: '' });
  },
  onShow() {
    applyTheme(this);
    if (!requireFamily()) return;
    const session = getSession();
    if (!session || !session.familyId) return;
    const changed = this._epoch !== epoch();
    this._epoch = epoch();
    this._scope = { userId: session.user.id, familyId: session.familyId };
    if (changed) {
      this._request++;
      this.setData({ items: [], loaded: false, loading: false, editor: false, draft: null, error: '', refreshError: '', saveError: '', saving: false, picking: false,
        previewingId: '', imageError: '', imageErrorMemory: '' });
      try {
        const restored = readMemoryDraft(this._scope);
        if (restored) this.setData({ draft: restored, restored: true });
      } catch (error) { showError(error); }
    }
    void this.load();
  },
  onUnload() { this._alive = false; this._request++; this._unsubscribe?.(); },
  onPullDownRefresh() { void this.load().finally(() => wx.stopPullDownRefresh()); },
  checkScope(stamp: number) {
    assertEpoch(stamp);
    if (!this._alive) throw new Error('页面已离开，草稿已保留');
    const session = getSession();
    if (!session || session.user.id !== this._scope?.userId || session.familyId !== this._scope?.familyId) throw new Error('登录身份或家庭已改变');
  },
  async load() {
    if (!this._scope || this.data.loading) return;
    const stamp = this._epoch;
    const request = ++this._request;
    this.setData({ loading: true, error: '', refreshError: '' });
    try {
      const rows = await api<MemoryRow[]>(familyPath('memory', '/memories?limit=50'));
      this.checkScope(stamp);
      if (request !== this._request) return;
      // Paint text first; each authenticated thumbnail replaces its own placeholder.
      const previous = new Map<string, MemoryRow>(this.data.items.map((row: MemoryRow) => [row.id, row]));
      this.setData({ items: rows.map(row => {
        const old = previous.get(row.id);
        return { ...row, avatarSource: row.author_avatar_url,
          author_avatar_url: old?.avatarSource === row.author_avatar_url ? old?.author_avatar_url : '',
          media: row.media.filter(m => m.kind === 'photo').slice(0, 9).map(media => ({
            ...media, local: old?.media.find(m => m.id === media.id)?.local,
          })),
        };
      }), loaded: true });
      void this.hydrate(rows, stamp, request);
    } catch (error) {
      if (stamp !== epoch() || !this._alive || request !== this._request) return;
      const message = error instanceof Error ? error.message : '回忆加载失败，请重试';
      this.setData(this.data.loaded ? { refreshError: message } : { error: message });
    } finally {
      if (stamp === epoch() && this._alive && request === this._request) this.setData({ loading: false });
    }
  },
  async hydrate(rows: MemoryRow[], stamp: number, request: number) {
    const valid = () => this._alive && epoch() === stamp && this._request === request;
    try {
      const hydrated = await hydrateAvatars(rows, ['author_avatar_url']);
      if (!valid()) return;
      const previous = new Map<string, MemoryRow>(this.data.items.map((row: MemoryRow) => [row.id, row]));
      const decorated: MemoryRow[] = hydrated.map((row: MemoryRow) => ({ ...row,
        avatarSource: rows.find(original => original.id === row.id)?.author_avatar_url,
        media: row.media.filter(m => m.kind === 'photo').slice(0, 9).map(media => ({
          ...media, local: previous.get(row.id)?.media.find(m => m.id === media.id)?.local,
        })),
      }));
      this.setData({ items: decorated });
      // Only eight covers are automatic. Full-size galleries are fetched on tap.
      await Promise.all(decorated.slice(0, 8).map(async (row, index) => {
        await Promise.all(row.media.slice(0, 1).map(async (media, imageIndex) => {
          if (media.local) return;
          try {
            const local = await privateMedia(media.url);
            if (valid()) this.setData({ [`items[${index}].media[${imageIndex}].local`]: local });
          } catch (_) { /* Keep an explicit image placeholder; text remains useful. */ }
        }));
      }));
    } catch (_) { /* Avatar component falls back to the author's emoji. */ }
  },
  async startEditor() {
    if (!this._scope || this.data.saving) return;
    const stamp = this._epoch;
    try {
      const draft = this.data.draft || await newMemoryDraft(this._scope);
      this.checkScope(stamp);
      writeMemoryDraft(draft);
      this.setData({ draft, editor: true, saveError: '', visibilityIndex: draft.visibility === 'family' ? 1 : 0 });
    } catch (error) { if (epoch() === stamp && this._alive) showError(error); }
  },
  closeEditor() { if (!this.data.saving && !this.data.picking) this.setData({ editor: false }); },
  updateField(event: any) {
    if (!this.data.draft || this.data.saving || this.data.picking) return;
    const field = event.currentTarget.dataset.field;
    if (!['title', 'body', 'eventDate'].includes(field)) return;
    const draft = { ...this.data.draft, [field]: event.detail.value } as MemoryDraft;
    try { this.checkScope(this._epoch); writeMemoryDraft(draft); this.setData({ draft }); }
    catch (error) { showError(error); }
  },
  updateVisibility(event: any) {
    if (!this.data.draft || this.data.saving || this.data.picking) return;
    const index = Number(event.detail.value) === 1 ? 1 : 0;
    const draft = { ...this.data.draft, visibility: index === 1 ? 'family' : 'private' } as MemoryDraft;
    try { this.checkScope(this._epoch); writeMemoryDraft(draft); this.setData({ draft, visibilityIndex: index }); }
    catch (error) { showError(error); }
  },
  async chooseImages() {
    const draft = this.data.draft;
    if (!draft || this.data.picking || this.data.saving) return;
    if (draft.attachments.length >= MAX_IMAGES) { showError(new Error('最多选择 9 张图片')); return; }
    const stamp = this._epoch;
    this.setData({ picking: true, saveError: '' });
    try {
      const result: any = await new Promise((resolve, reject) => wx.chooseMedia({
        count: MAX_IMAGES - draft.attachments.length, mediaType: ['image'], sourceType: ['album', 'camera'],
        sizeType: ['compressed'], success: resolve, fail: reject,
      }));
      this.checkScope(stamp);
      for (const file of result.tempFiles) {
        await addMemoryImage(draft, file.tempFilePath, () => this.checkScope(stamp));
        this.checkScope(stamp);
        this.setData({ draft });
      }
    } catch (error) {
      if (stamp === epoch() && this._alive && !String((error as any)?.errMsg).includes('cancel')) {
        this.setData({ saveError: error instanceof Error ? error.message : '图片暂存失败，已添加的图片仍保留。请检查本机存储空间后重试。' });
      }
    } finally { if (stamp === epoch() && this._alive) this.setData({ picking: false }); }
  },
  async removeImage(event: any) {
    if (!this.data.draft || this.data.saving || this.data.picking) return;
    const stamp = this._epoch;
    try {
      this.checkScope(stamp);
      await removeMemoryImage(this.data.draft, event.currentTarget.dataset.id);
      this.checkScope(stamp);
      this.setData({ draft: this.data.draft });
    } catch (error) { if (stamp === epoch() && this._alive) showError(error); }
  },
  async save() {
    const draft = this.data.draft;
    if (!draft || this.data.saving || this.data.picking) return;
    const stamp = this._epoch;
    const base = familyPath('memory', '/memories');
    this.setData({ saving: true, saveError: '' });
    try {
      const saved = await saveMemoryDraft(draft, {
        create: fields => api<{ id: string }>(base, 'POST', fields),
        update: (id, fields) => api(`${base}/${encodeURIComponent(id)}`, 'PUT', fields),
        upload: (id, attachment) => upload(`${base}/${encodeURIComponent(id)}/media`, attachment.path, { client_id: attachment.id }),
      }, () => this.checkScope(stamp));
      this.checkScope(stamp);
      if (saved) {
        this.setData({ draft: null, editor: false, restored: false });
        wx.showToast({ title: '回忆已保存', icon: 'success' });
        void this.load();
      }
    } catch (error) {
      if (stamp === epoch() && this._alive) this.setData({ draft, saveError: (error instanceof Error ? error.message : '保存中断') + '。草稿已保留，点击继续保存即可；不会自动上传。' });
    } finally { if (stamp === epoch() && this._alive) this.setData({ saving: false }); }
  },
  async discard() {
    if (this.data.saving || this.data.picking || !this._scope) return;
    const stamp = this._epoch;
    const confirmed: any = await new Promise(resolve => wx.showModal({
      title: '清理本机草稿？', content: '将移除本机暂存图片。若曾开始保存，服务端已保存的私密回忆会保留。',
      confirmText: '清理草稿', confirmColor: '#b85547', success: resolve,
    }));
    if (!confirmed.confirm) return;
    try {
      this.checkScope(stamp);
      await clearMemoryDrafts(this._scope.userId, this._scope.familyId);
      this.checkScope(stamp);
      this.setData({ draft: null, editor: false, restored: false, saveError: '' });
    } catch (error) { if (stamp === epoch() && this._alive) showError(error); }
  },
  async previewImage(event: any) {
    if (this.data.previewingId) return;
    const row: MemoryRow | undefined = this.data.items.find((item: MemoryRow) => item.id === event.currentTarget.dataset.memory);
    if (!row || !row.media.length) return;
    const stamp = this._epoch;
    this.setData({ previewingId: row.id, imageError: '', imageErrorMemory: '' });
    try {
      const urls = await Promise.all(row.media.map(async media => {
        const local = media.local || await privateMedia(media.url);
        this.checkScope(stamp);
        const index = this.data.items.findIndex((item: MemoryRow) => item.id === row.id);
        const imageIndex = index < 0 ? -1 : this.data.items[index].media.findIndex((image: any) => image.id === media.id);
        if (index >= 0 && imageIndex >= 0) this.setData({ [`items[${index}].media[${imageIndex}].local`]: local });
        return local;
      }));
      this.checkScope(stamp);
      const selected = row.media.findIndex(media => media.id === event.currentTarget.dataset.media);
      wx.previewImage({ urls, current: urls[selected >= 0 ? selected : 0] });
    } catch (error) {
      if (stamp === epoch() && this._alive) this.setData({ imageError: '图片加载失败，请点击图片重试。', imageErrorMemory: row.id });
    } finally {
      if (stamp === epoch() && this._alive) this.setData({ previewingId: '' });
    }
  },
});
