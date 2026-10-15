export interface User {id: string; display_name: string; avatar_emoji: string; avatar_url?: string | null}
export interface Session {token: string; user: User; familyId: string | null}
let current: Session | null = null;
let generation = 0;
const listeners = new Set<() => void>();
const KEY = 'wo:session:v1';
export function epoch(): number {return generation;}
export function assertEpoch(value: number): void {
  if (value !== generation) throw new Error('登录状态已变化，请重新操作');
}
export function getSession(): Session | null {return current;}
export function onSessionChange(callback: () => void): () => void {listeners.add(callback); return () => listeners.delete(callback);}
function changed(): void {generation++; listeners.forEach(fn => fn());}
export function restoreSession(): void {
  const saved = wx.getStorageSync(KEY);
  if (saved && typeof saved.token === 'string' && typeof saved.user?.id === 'string') current = saved;
  changed();
}
export function setSession(value: Session): void {
  current = value; wx.setStorageSync(KEY, value); changed();
}
export function setFamily(familyId: string | null): void {
  if (!current || current.familyId === familyId) return;
  current = {...current, familyId}; wx.setStorageSync(KEY, current); changed();
}
export function clearSession(): void {current = null; wx.removeStorageSync(KEY); changed();}
