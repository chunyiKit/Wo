import {apiUrl} from './config';
import {assertEpoch,clearSession,epoch,getSession} from './session';
interface Envelope<T> {success: boolean; data: T; error?: {message?: string}}
export function api<T = any>(path: string, method: 'GET'|'POST'|'PUT'|'DELETE' = 'GET', data?: unknown): Promise<T> {
  const stamp = epoch();
  const token = getSession()?.token;
  return new Promise((resolve, reject) => {
    let url: string;
    try {url = apiUrl(path);} catch (e) {reject(e); return;}
    wx.request({url, method, data, timeout: 20000,
      header: {'Content-Type':'application/json', ...(token ? {Authorization:`Bearer ${token}`} : {})},
      success(res: {statusCode:number; data:Envelope<T>}) {
        try {
          assertEpoch(stamp);
          if (res.statusCode === 401 && token) {clearSession(); wx.reLaunch({url:'/pages/login/index'}); throw new Error('登录已失效，请重新登录');}
          if (res.statusCode < 200 || res.statusCode >= 300 || !res.data.success) throw new Error(res.data.error?.message || '请求失败，请稍后再试');
          resolve(res.data.data);
        } catch (e) {reject(e);}
      }, fail() {reject(new Error('网络连接失败，请检查网络后重试'));},
    });
  });
}
export function familyPath(plugin:string, tail:string):string {
  const id = getSession()?.familyId;
  if (!id) throw new Error('请先在 App 中创建或加入家庭，再刷新');
  return `/families/${encodeURIComponent(id)}/plugins/${plugin}/${tail.replace(/^\/+/, '')}`;
}
export function requireFamily():boolean {
  const session = getSession();
  if (!session) {wx.reLaunch({url:'/pages/login/index'}); return false;}
  if (!session.familyId) {wx.showToast({title:'请先在 App 中创建或加入家庭',icon:'none'}); return false;}
  return true;
}
export function showError(error:unknown):void {wx.showToast({title:error instanceof Error ? error.message : '操作失败，请重试',icon:'none',duration:3500});}
