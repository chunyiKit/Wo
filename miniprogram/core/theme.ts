import {config} from './config';
export function theme(): string {return wx.getStorageSync('wo:theme') === 'paper' ? 'paper' : 'cinema';}
export function applyTheme(page:{setData: (data:object)=>void}):void {
  const value = theme(); page.setData({theme:value});
  wx.setNavigationBarColor({frontColor:value === 'paper' ? '#000000' : '#ffffff',backgroundColor:value === 'paper' ? '#F8F1E7' : '#160F0D'});
  wx.setBackgroundColor({backgroundColor:value === 'paper' ? '#F8F1E7' : '#160F0D'});
}
export function toggleTheme():void {wx.setStorageSync('wo:theme',theme()==='paper' ? 'cinema':'paper');}
export function loadFont():void {
  if (!config.fontUrl || !/^https:\/\//.test(config.fontUrl)) return;
  wx.loadFontFace({global:true,family:'WoSerif',source:`url("${config.fontUrl}")`,fail(){/* 系统衬线回退，不阻塞首屏。 */}});
}
