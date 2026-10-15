const test=require('node:test');
const assert=require('node:assert/strict');
const fs=require('node:fs');
const path=require('node:path');
const vm=require('node:vm');
const {stripTypeScriptTypes}=require('node:module');
const source=stripTypeScriptTypes(fs.readFileSync(path.resolve(__dirname,'../pages/home/index.ts'),'utf8')).replace(/^import .*;\n/gm,'');
const noFamily={user:{id:'u1'},current_family:null,families:[],installed_plugins:[]};
const family=(role='owner')=>({id:'f1',name:'我们的小窝',slogan:null,member_count:1,my_role:role});
function deferred(){let resolve,reject;const promise=new Promise((a,b)=>{resolve=a;reject=b});return {promise,resolve,reject};}
function home(api){
 let page,generation=1,session={user:{id:'u1'},familyId:null};const listeners=[];const notices=[];const familyChanges=[];
 const context={Date,Error,Promise,Set,Array,String,Number,console,
  Page:options=>page=options,api,getSession:()=>session,epoch:()=>generation,
  onSessionChange:fn=>{listeners.push(fn);return()=>{}},
  setFamily:id=>{if(session.familyId===id)return;session={...session,familyId:id};familyChanges.push(id);generation++;listeners.forEach(fn=>fn());},
  hydrateAvatars:async rows=>rows,privateMedia:async()=>'',theme:()=> 'cinema',applyTheme(){},toggleTheme(){},showError:error=>notices.push(error),
  wx:{showToast:value=>notices.push(value),navigateTo(){},reLaunch(){},stopPullDownRefresh(){}},
 };
 vm.runInNewContext(source,context);
 page.setData=function(patch){Object.assign(this.data,patch)};page.onLoad();page.stamp=generation;
 return {p:page,notices,familyChanges,changeSession(){generation++;session={user:{id:'u2'},familyId:null};listeners.forEach(fn=>fn());}};
}
const event=value=>({detail:{value},currentTarget:{dataset:{}}});
test('新微信用户可创建家庭，仅提交名称并切换后加载',async()=>{
 const calls=[];let joined=false;const {p,familyChanges}=home(async(url,method,data)=>{
  calls.push({url,method,data});if(url==='/families'){joined=true;return family();}if(url==='/me/bootstrap')return joined?{...noFamily,current_family:family(),families:[family()]}:noFamily;return [];
 });await p.load();p.updateFamilyName(event('  我们的小窝  '));await p.createFamily();
 const write=calls.find(call=>call.method==='POST');assert.equal(write.url,'/families');assert.deepEqual(JSON.parse(JSON.stringify(write.data)),{name:'我们的小窝'});
 assert.deepEqual(familyChanges,['f1']);assert.equal(p.data.bootstrap.current_family.id,'f1');assert.equal(p.data.busy,false);assert.equal(p.data.familyName,'');
 assert.equal(calls.filter(call=>call.method==='POST').length,1);
});
test('空白或超过16字家庭名称不得写入',async()=>{
 let writes=0;const {p}=home(async(url,method)=>{if(method==='POST')writes++;return noFamily});await p.load();
 for(const value of [' ','一'.repeat(17)]){p.data.familyName=value;await p.createFamily();}assert.equal(writes,0);
});
test('邀请码规范化为8位slug，预览不保留邀请人，确认后才accept',async()=>{
 const calls=[];let accepted=false;const {p,familyChanges}=home(async(url,method)=>{
  calls.push({url,method});if(url.endsWith('/preview'))return {family:{name:'晴天小窝',member_count:3},role:'member',inviter:{display_name:'不应显示',avatar_emoji:'👤'}};
  if(url.endsWith('/accept')){accepted=true;return family('member');}if(url==='/me/bootstrap')return accepted?{...noFamily,current_family:family('member'),families:[family('member')]}:noFamily;return [];
 });await p.load();p.updateInvite(event(' wo-w4m9-p2kx '));await p.previewInvitation();
 assert.equal(calls.at(-1).url,'/invitations/W4M9P2KX/preview');assert.equal(calls.some(call=>call.method==='POST'),false);
 assert.equal(p.data.invitePreview.name,'晴天小窝');assert.equal(p.data.invitePreview.memberCount,3);assert.equal(p.data.invitePreview.role,'家庭成员');assert.equal(JSON.stringify(p.data.invitePreview).includes('不应显示'),false);
 await p.acceptInvitation();assert.equal(calls.find(call=>call.method==='POST').url,'/invitations/W4M9P2KX/accept');assert.deepEqual(familyChanges,['f1']);assert.equal(p.data.invitePreview,null);
});
test('修改邀请码后旧预览失效；无预览或路径注入不可accept',async()=>{
 const calls=[];const {p}=home(async(url,method)=>{calls.push({url,method});if(url.endsWith('/preview'))return {family:{name:'小窝',member_count:2},role:'member'};return noFamily;});await p.load();
 p.updateInvite(event('W4M9P2KX'));await p.acceptInvitation();assert.equal(calls.length,1);
 await p.previewInvitation();p.updateInvite(event('W4M9P2KY'));await p.acceptInvitation();assert.equal(calls.some(call=>call.method==='POST'),false);
 p.updateInvite(event('../../x'));await p.previewInvitation();assert.equal(calls.some(call=>call.url.includes('..')),false);
});
test('创建家庭请求有忙碌锁；切账号后的响应不能设置家庭',async()=>{
 const pending=deferred();let writes=0;const {p,changeSession,familyChanges}=home(async(url,method)=>{if(method==='POST'){writes++;return pending.promise;}return noFamily;});
 await p.load();p.data.familyName='我的家';const create=p.createFamily();await p.createFamily();assert.equal(writes,1);changeSession();pending.resolve(family());await create;
 assert.deepEqual(familyChanges,[]);assert.equal(p.data.bootstrap,null);assert.equal(p.data.familyName,'');assert.equal(p.data.busy,false);
});
test('owner按明确按钮启用单个缺失插件，已有安装与其他插件保持不动',async()=>{
 const writes=[];let installed=[{plugin_id:'memory',preview:{count:4},config:{private:true}}];const {p}=home(async(url,method,data)=>{
  if(method==='POST'){writes.push({url,data});const plugin={plugin_id:data.plugin_id,preview:{}};installed=[...installed,plugin];return plugin;}
  if(url==='/me/bootstrap')return {...noFamily,current_family:family(),families:[family()],installed_plugins:installed};return [];
 });await p.load();assert.equal(p.data.cards.length,1);assert.equal(p.data.canManagePlugins,true);
 await p.installPlugin({currentTarget:{dataset:{id:'accounting'}}});assert.equal(writes.length,1);assert.equal(writes[0].url,'/families/f1/plugins');assert.deepEqual(JSON.parse(JSON.stringify(writes[0].data)),{plugin_id:'accounting'});
 assert.equal(p.data.cards.length,2);assert.equal(p.data.missingCards.length,1);assert.equal(installed[0].config.private,true);
 await p.installPlugin({currentTarget:{dataset:{id:'memory'}}});await p.installPlugin({currentTarget:{dataset:{id:'unknown'}}});assert.equal(writes.length,1);
});
test('普通成员不可启用插件；账号切换清掉家庭、成员及邀请摘要',async()=>{
 let writes=0;const {p,changeSession}=home(async(url,method)=>{if(method==='POST')writes++;if(url==='/me/bootstrap')return {...noFamily,current_family:family('member'),families:[family('member')]};return [{user_id:'m',display_name:'家人',avatar_emoji:'👤'}];});
 await p.load();assert.equal(p.data.canManagePlugins,false);await p.installPlugin({currentTarget:{dataset:{id:'chore'}}});assert.equal(writes,0);
 p.data.invitePreview={name:'旧家庭',memberCount:2,role:'成员'};changeSession();assert.equal(p.data.bootstrap,null);assert.equal(p.data.members.length,0);assert.equal(p.data.invitePreview,null);assert.equal(p.data.cards.length,0);
});
test('插件安装刷新失败保留已确认安装，无自动重试',async()=>{
 let installed=false,writes=0;const {p}=home(async(url,method,data)=>{
  if(method==='POST'){writes++;installed=true;return {plugin_id:data.plugin_id};}
  if(url==='/me/bootstrap'){if(installed)throw Error('offline');return {...noFamily,current_family:family('admin'),families:[family('admin')]};}return [];
 });await p.load();await p.installPlugin({currentTarget:{dataset:{id:'chore'}}});assert.equal(writes,1);assert.equal(p.data.cards[0].id,'chore');assert.equal(p.data.error,'offline');assert.equal(p.data.busy,false);
});
test('首页静默刷新失败保持原家庭卡片、头像与背景',async()=>{
 let delay=false;const pending=deferred();const {p}=home(async url=>{
  if(url==='/me/bootstrap'){if(delay)return pending.promise;return {...noFamily,current_family:family(),families:[family()],installed_plugins:[{plugin_id:'memory'}]};}
  return [{user_id:'m',display_name:'家人',avatar_emoji:'👤',avatar_url:'private-avatar'}];
 });await p.load();p.data.background='private-background';delay=true;const load=p.load();assert.equal(p.data.loading,false);assert.equal(p.data.cards.length,1);assert.equal(p.data.members[0].avatar_url,'private-avatar');
 pending.reject(Error('offline'));await load;assert.equal(p.data.background,'private-background');assert.equal(p.data.cards.length,1);assert.equal(p.data.error,'offline');
});
test('旧邀请码预览和确认加入响应均不能跨账号回填',async()=>{
 const preview=deferred();const {p,changeSession,familyChanges}=home(async url=>url.endsWith('/preview')?preview.promise:noFamily);
 await p.load();p.data.inviteInput='W4M9P2KX';const lookup=p.previewInvitation();changeSession();preview.resolve({family:{name:'私密家庭',member_count:2},role:'member'});await lookup;assert.equal(p.data.invitePreview,null);
 const accept=deferred();const fixture=home(async(url,method)=>method==='POST'?accept.promise:noFamily);await fixture.p.load();fixture.p.data.inviteInput='W4M9P2KX';fixture.p.data.previewCode='W4M9P2KX';fixture.p.data.invitePreview={name:'小窝',memberCount:2,role:'家庭成员'};
 const joining=fixture.p.acceptInvitation();fixture.changeSession();accept.resolve(family());await joining;assert.equal(fixture.p.data.bootstrap,null);assert.deepEqual(fixture.familyChanges,[]);assert.deepEqual(familyChanges,[]);
});
test('插件启用有忙碌锁且旧账号成功响应不能恢复卡片',async()=>{
 const pending=deferred();let writes=0;const {p,changeSession}=home(async(url,method)=>{
  if(method==='POST'){writes++;return pending.promise;}if(url==='/me/bootstrap')return {...noFamily,current_family:family(),families:[family()]};return [];
 });await p.load();const installing=p.installPlugin({currentTarget:{dataset:{id:'memory'}}});await p.installPlugin({currentTarget:{dataset:{id:'accounting'}}});assert.equal(writes,1);
 changeSession();pending.resolve({plugin_id:'memory'});await installing;assert.equal(p.data.bootstrap,null);assert.equal(p.data.cards.length,0);assert.equal(p.data.installing,'');
});
