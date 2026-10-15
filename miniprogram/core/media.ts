import {apiUrl} from './config';
import {assertEpoch,epoch,getSession,onSessionChange} from './session';
const cache = new Map<string,Promise<string>>();
const files = new Set<string>();
let active = 0;
const waiting: (()=>void)[] = [];
function limited<T>(run:()=>Promise<T>):Promise<T> {
  return new Promise((resolve,reject)=>{
    const start=()=>{
      active++;
      const release=()=>{active--;waiting.shift()?.();};
      try {run().then(resolve,reject).finally(release);}catch(error){release();reject(error);}
    };
    if(active<4)start();else waiting.push(start);
  });
}
onSessionChange(() => {cache.clear(); files.forEach(filePath => wx.getFileSystemManager().unlink({filePath,fail(){}})); files.clear();});
// 相同来源的鉴权 bytes 端点，服务端 download=true 禁止 COS redirect。
export function privateMedia(path:string):Promise<string> {
  const session = getSession(); if (!session) return Promise.reject(new Error('请先登录'));
  const stamp = epoch();
  const key = `${stamp}:${path}`;
  const found = cache.get(key); if (found) return found;
  const task = limited(()=>new Promise<string>((resolve,reject)=> {
    try {assertEpoch(stamp);}catch(error){reject(error);return;}
    let url:string;
    try {url = apiUrl(path) + (path.includes('?') ? '&':'?') + 'download=true';} catch (e) {reject(e); return;}
    wx.downloadFile({url,header:{Authorization:`Bearer ${session.token}`},timeout:30000,
      success(res:{statusCode:number;tempFilePath:string}) {
        try {assertEpoch(stamp); if(res.statusCode!==200) throw new Error('图片暂时无法加载'); files.add(res.tempFilePath); resolve(res.tempFilePath);}
        catch(e) {wx.getFileSystemManager().unlink({filePath:res.tempFilePath,fail(){}}); reject(e);}
      },fail(){reject(new Error('图片下载失败'));},
    });
  }));
  if(cache.size>=80)cache.delete(cache.keys().next().value);
  cache.set(key,task); task.catch(()=>cache.delete(key)); return task;
}
export async function hydrateAvatars<T extends Record<string,any>>(rows:T[], fields?:string[]):Promise<T[]> {
  return Promise.all(rows.map(async row => {
    const result = {...row};
    const keys = fields || Object.keys(row).filter(k=>k === 'avatar_url' || k.endsWith('_avatar_url'));
    await Promise.all(keys.map(async key=> {if (row[key]) (result as Record<string,any>)[key] = await privateMedia(row[key]).catch(()=> '');}));
    return result;
  }));
}
export function upload<T = any>(path:string,filePath:string,formData:Record<string,string>):Promise<T> {
  const session = getSession(); if (!session) return Promise.reject(new Error('请先登录'));
  const stamp = epoch();
  return new Promise((resolve,reject)=> {
    let url:string; try {url=apiUrl(path);} catch(e){reject(e);return;}
    wx.uploadFile({url,filePath,name:'file',formData,header:{Authorization:`Bearer ${session.token}`},timeout:60000,
      success(res:{statusCode:number;data:string}) {
        try {assertEpoch(stamp);const body = JSON.parse(res.data);if(res.statusCode<200 || res.statusCode>=300 || !body.success) throw new Error(body.error?.message || '图片上传失败，可继续重试');resolve(body.data);} catch(e){reject(e);}
      },fail(){reject(new Error('图片上传中断，可继续重试'));},
    });
  });
}
