/** Local drafts never upload automatically. A distinct manifest belongs to each user/family. */
export interface MemoryScope { userId: string; familyId: string }
export interface MemoryAttachment { id: string; path: string; size: number; uploaded: boolean }
export interface MemoryDraft {
  version: 1;
  userId: string;
  familyId: string;
  clientId: string;
  memoryId?: string;
  title: string;
  body: string;
  eventDate: string;
  visibility: 'private' | 'family';
  attachments: MemoryAttachment[];
}
const PREFIX = 'wo.memory.draft.v1.';
const saving = new Set<string>();
export const MAX_IMAGES = 9;
export const MAX_IMAGE_BYTES = 10 * 1024 * 1024;
export function draftKey(scope: MemoryScope): string {
  return PREFIX + encodeURIComponent(scope.userId) + '.' + encodeURIComponent(scope.familyId);
}
/** Fail closed if secure randomness is unavailable; never derive IDs from timestamps. */
export async function memoryUuid(): Promise<string> {
  if (typeof wx.getRandomValues !== 'function') throw new Error('当前微信版本不支持安全随机数，请升级微信');
  const value: ArrayBuffer = await new Promise((resolve, reject) => {
    wx.getRandomValues({ length: 16, success: (r: any) => resolve(r.randomValues), fail: reject });
  });
  const bytes = new Uint8Array(value);
  if (bytes.length !== 16) throw new Error('生成保存标识失败，请重试');
  bytes[6] = (bytes[6] & 15) | 64;
  bytes[8] = (bytes[8] & 63) | 128;
  const hex = Array.from(bytes, b => b.toString(16).padStart(2, '0')).join('');
  return `${hex.slice(0, 8)}-${hex.slice(8, 12)}-${hex.slice(12, 16)}-${hex.slice(16, 20)}-${hex.slice(20)}`;
}
export async function newMemoryDraft(scope: MemoryScope): Promise<MemoryDraft> {
  const now = new Date();
  const day = `${now.getFullYear()}-${String(now.getMonth() + 1).padStart(2, '0')}-${String(now.getDate()).padStart(2, '0')}`;
  return { version: 1, ...scope, clientId: await memoryUuid(), title: '', body: '', eventDate: day, visibility: 'private', attachments: [] };
}
export function writeMemoryDraft(draft: MemoryDraft): void {
  wx.setStorageSync(draftKey(draft), draft);
}
export function readMemoryDraft(scope: MemoryScope): MemoryDraft | null {
  const draft = wx.getStorageSync(draftKey(scope));
  if (!draft) return null;
  if (draft.version !== 1 || draft.userId !== scope.userId || draft.familyId !== scope.familyId || !draft.clientId || !Array.isArray(draft.attachments)) {
    throw new Error('草稿数据无法恢复，请清理这份本地草稿后重试');
  }
  return draft as MemoryDraft;
}
function removeSaved(path: string): Promise<void> {
  return new Promise(resolve => wx.getFileSystemManager().removeSavedFile({ filePath: path, complete: () => resolve() }));
}
export async function addMemoryImage(draft: MemoryDraft, tempFilePath: string, checkScope: () => void): Promise<void> {
  checkScope();
  if (draft.attachments.length >= MAX_IMAGES) throw new Error('最多选择 9 张图片');
  const dimensions: { width: number; height: number } = await new Promise((resolve, reject) => wx.getImageInfo({
    src: tempFilePath, success: (r: any) => resolve({ width: r.width, height: r.height }), fail: reject,
  }));
  checkScope();
  if (!(dimensions.width > 0 && dimensions.height > 0)) throw new Error('无法读取图片尺寸，请重新选择');
  const ratio = Math.min(1, 1920 / Math.max(dimensions.width, dimensions.height));
  const compressed: string = await new Promise((resolve, reject) => wx.compressImage({
    src: tempFilePath, quality: 78,
    compressedWidth: Math.max(1, Math.round(dimensions.width * ratio)),
    compressedHeight: Math.max(1, Math.round(dimensions.height * ratio)),
    success: (r: any) => resolve(r.tempFilePath), fail: reject,
  }));
  checkScope();
  const size: number = await new Promise((resolve, reject) => wx.getFileSystemManager().getFileInfo({
    filePath: compressed, success: (r: any) => resolve(r.size), fail: reject,
  }));
  checkScope();
  if (size <= 0 || size > MAX_IMAGE_BYTES) throw new Error('压缩后的每张图片须小于 10 MB');
  const id = await memoryUuid();
  checkScope();
  const path: string = await new Promise((resolve, reject) => wx.getFileSystemManager().saveFile({
    tempFilePath: compressed, success: (r: any) => resolve(r.savedFilePath), fail: reject,
  }));
  try {
    checkScope();
    draft.attachments.push({ id, path, size, uploaded: false });
    writeMemoryDraft(draft);
  } catch (error) {
    draft.attachments = draft.attachments.filter(a => a.id !== id);
    await removeSaved(path);
    throw error;
  }
}
export async function removeMemoryImage(draft: MemoryDraft, id: string): Promise<void> {
  const attachment = draft.attachments.find(a => a.id === id);
  if (!attachment) return;
  if (attachment.uploaded) throw new Error('这张图片已保存到私密回忆，请先完成本次保存');
  draft.attachments = draft.attachments.filter(a => a.id !== id);
  try { writeMemoryDraft(draft); } catch (error) { draft.attachments.push(attachment); throw error; }
  await removeSaved(attachment.path);
}
/** Logout hook: omit scope to delete all local memory drafts; never affects remote records. */
export async function clearMemoryDrafts(userId?: string, familyId?: string): Promise<void> {
  const keys: string[] = wx.getStorageInfoSync().keys;
  for (const key of keys.filter(k => k.startsWith(PREFIX))) {
    const draft = wx.getStorageSync(key) as MemoryDraft;
    if (!draft || (userId && draft.userId !== userId) || (familyId && draft.familyId !== familyId)) continue;
    // Remove manifest first so a completed/discarded draft cannot be replayed.
    wx.removeStorageSync(key);
    await Promise.all((draft.attachments || []).map(a => removeSaved(a.path)));
  }
}
export interface MemoryDraftTransport {
  create(fields: Record<string, unknown>): Promise<{ id: string }>;
  update(id: string, fields: Record<string, unknown>): Promise<unknown>;
  upload(id: string, attachment: MemoryAttachment): Promise<unknown>;
}
export async function saveMemoryDraft(draft: MemoryDraft, transport: MemoryDraftTransport, checkScope: () => void): Promise<boolean> {
  const key = draftKey(draft);
  if (saving.has(key)) return false;
  if (!draft.title.trim()) throw new Error('请给这段回忆起个名字');
  if (!draft.attachments.length) throw new Error('请至少选择一张图片');
  if (draft.title.trim().length > 80 || draft.body.length > 2000) throw new Error('标题最多 80 字，正文最多 2000 字');
  saving.add(key);
  const fields = { title: draft.title.trim(), body: draft.body, event_date: draft.eventDate };
  try {
    checkScope();
    writeMemoryDraft(draft);
    if (!draft.memoryId) {
      const created = await transport.create({ ...fields, client_id: draft.clientId, visibility: 'private' });
      checkScope();
      draft.memoryId = created.id;
      writeMemoryDraft(draft);
    } else {
      // A previous final share may have committed even when its response was lost.
      // A retry can include newly selected attachments: hide the record first and
      // require this acknowledgement before sending any new image bytes.
      checkScope();
      await transport.update(draft.memoryId, { visibility: 'private' });
      checkScope();
    }
    for (const attachment of draft.attachments) {
      if (attachment.uploaded) continue;
      checkScope();
      await transport.upload(draft.memoryId, attachment);
      checkScope();
      attachment.uploaded = true;
      writeMemoryDraft(draft);
    }
    checkScope();
    // Family visibility only becomes effective after all attachments have succeeded.
    await transport.update(draft.memoryId, { ...fields, visibility: draft.visibility });
    checkScope();
    await clearMemoryDrafts(draft.userId, draft.familyId);
    return true;
  } finally { saving.delete(key); }
}
