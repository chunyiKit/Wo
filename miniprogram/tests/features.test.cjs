const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');
const {stripTypeScriptTypes} = require('node:module');
const root = require('node:path').resolve(__dirname, '..');
function deferred(){let resolve,reject; const promise=new Promise((a,b)=>{resolve=a;reject=b});return {promise,resolve,reject};}
function page(name,api) {
 let result, generation=1, modal; const listeners=[]; const notices=[];
 const context={Promise,Date,Number,String,Error,console,Page: options=>result=options,
   api, familyPath:(plugin,tail)=>`/families/f1/plugins/${plugin}/${tail}`,requireFamily:()=>true,showError:error=>notices.push(error),
   epoch:()=>generation,onSessionChange:fn=>{listeners.push(fn);return()=>{}},theme:()=> 'cinema',applyTheme:()=>{},hydrateAvatars:async rows=>rows,
   wx:{showToast:x=>notices.push(x),stopPullDownRefresh(){},showModal:x=>modal=x}};
 const source=stripTypeScriptTypes(fs.readFileSync(`${root}/pages/${name}/index.ts`,'utf8')).replace(/^import .*;\n/gm,'');
 vm.runInNewContext(source,context);
 result.setData=function(patch){for(const [key,value]of Object.entries(patch)){ const parts=key.split('.');let target=this.data;while(parts.length>1)target=target[parts.shift()];target[parts[0]]=value; }};
 result.onLoad();return {p:result,notices,changeSession(){generation++;listeners.forEach(fn=>fn());},modal:()=>modal};
}
const expense={id:'x',amount:'12.30',category:'dining',note:'午饭',exclude_from_budget:false,created_at:'2026-10-15T11:00:00Z',creator_name:'妈妈',creator_avatar_url:null,creator_emoji:'👩'};
const categories=[{code:'dining',emoji:'🍜',label:'餐饮'}];
const summary={month_total:'12.30',budget:'100',remaining:'87.70',budgeted_total:'12.30',excluded_total:'0'};
function accountingResponse(path){return path.includes('/summary')?summary:path.includes('/categories')?categories:[expense];}
test('记账首次加载、刷新失败保留数据且无整页 loading', async()=>{
 let fail=false;const {p}=page('accounting',async path=>{if(fail)throw Error('offline');return accountingResponse(path)});
 await p.load(); assert.equal(p.data.items[0].money,'12.30'); assert.equal(p.data.total,'12.30');
 fail=true;const pending=p.load(); assert.equal(p.data.loading,false);assert.equal(p.data.items.length,1);await pending;
 assert.equal(p.data.items.length,1);assert.equal(p.data.error,'offline');
});
test('月份晚到响应不能覆盖新月份',async()=>{
 const old=deferred();let delay=true;const {p}=page('accounting',async path=>delay?old.promise:accountingResponse(path));
 p.data.month='2026-09';const first=p.load();delay=false;p.data.month='2026-10';await p.load();
 old.resolve([]);await first;assert.equal(p.data.displayedMonth,'2026-10');assert.equal(p.data.items.length,1);
});
test('切账号即时清空私有内容，旧响应与旧提交不得回填',async()=>{
 const pending=deferred();const {p,changeSession}=page('accounting',()=>pending.promise);
 p.data.loaded=true;p.data.items=[expense];p.data.total='12.30';p.data.form={amount:'18',note:'',category:'dining',exclude_from_budget:false};p.data.categories=categories;
 const save=p.submit();assert.equal(p.data.submitting,true);changeSession();pending.resolve(expense);await save;
 assert.equal(p.data.items.length,0);assert.equal(p.data.total,'0.00');assert.equal(p.data.form.amount,'');assert.equal(p.data.loaded,false);
});
test('金额验证与保存锁拒绝重复请求，服务失败不会自动重试',async()=>{
 let calls=0;const pending=deferred();const {p}=page('accounting',()=>{calls++;return pending.promise});p.data.categories=categories;
 for(const amount of ['0','-1','1e2','1.001','10000000000']){p.data.form={amount,note:'',category:'dining',exclude_from_budget:false};await p.submit();}
 assert.equal(calls,0);p.data.form.amount='1.23';const save=p.submit();await p.submit();assert.equal(calls,1);pending.reject(Error('uncertain'));await save;assert.equal(calls,1);assert.equal(p.data.editor,false);
});
test('删除确认对话框跨账号后不得执行',async()=>{
 let calls=0;const {p,changeSession,modal}=page('accounting',async()=>{calls++;});p.deleteExpense({currentTarget:{dataset:{id:'x'}}});changeSession();await modal().success({confirm:true});assert.equal(calls,0);
});
const chore={id:'c',title:'浇花',note:null,emoji:'🪴',assigned_to:'m',done:false,recurring:true,assignee_name:'妈妈',assignee_emoji:'👩',assignee_avatar_url:null};
const member={user_id:'m',display_name:'妈妈',avatar_emoji:'👩',avatar_url:null,status:'active'};
test('家务完成后刷新失败仍保留已确认完成状态',async()=>{
 let fetches=0;const {p}=page('chores',async(path,method)=>{
  if(method==='POST')return {...chore,done:true};if(path.endsWith('/members'))return [member];if(fetches++)throw Error('offline');return [chore];
 });await p.load();assert.equal(p.data.visible.length,1);await p.toggleDone({currentTarget:{dataset:{id:'c'}}});
 assert.equal(p.data.items[0].done,true);assert.equal(p.data.visible.length,0);assert.equal(p.data.doneCount,1);assert.equal(p.data.pendingIds.length,0);
});
test('家务保存仅提交当前家庭有效成员与原始备注，未调用提醒',async()=>{
 const calls=[];const {p}=page('chores',async(path,method,data)=>{calls.push({path,method,data});if(method==='POST')return chore;return path.endsWith('/members')?[member]:[chore];});
 await p.load();p.selectMember({currentTarget:{dataset:{id:'outside'}}});assert.equal(p.data.form.assigned_to,null);
 p.selectMember({currentTarget:{dataset:{id:'m'}}});p.data.form.title=' 浇花 ';p.data.form.note=' 阳台 ';await p.submit();
 const write=calls.find(x=>x.method==='POST');assert.equal(write.data.title,'浇花');assert.equal(write.data.assigned_to,'m');assert.equal(write.data.note,'阳台');assert.ok(calls.every(x=>!x.path.includes('remind')));
});
test('家务切账号清空负责人、旧列表和编辑草稿',async()=>{
 const {p,changeSession}=page('chores',async path=>path.endsWith('/members')?[member]:[chore]);await p.load();p.data.form.title='私人草稿';changeSession();
 assert.equal(p.data.items.length,0);assert.equal(p.data.members.length,0);assert.equal(p.data.form.title,'');assert.equal(p.data.openCount,0);
});
test('已确认支出在刷新失败时保留，按分汇总预算内外避免浮点尾差',async()=>{
 let saved=false;const extra={...expense,id:'new',amount:'0.20',exclude_from_budget:true};
 const {p}=page('accounting',async(path,method)=>{if(method==='POST'){saved=true;return extra;}if(saved)throw Error('offline');return accountingResponse(path);});
 await p.load();p.data.items=[{...expense,amount:'0.10'}];p.data.displayedMonth='2026-10';p.data.form={amount:'0.20',note:'',category:'dining',exclude_from_budget:true};
 await p.submit();assert.equal(p.data.items.length,2);assert.equal(p.data.total,'0.30');assert.equal(p.data.excluded,'0.20');assert.equal(p.data.budgeted,'0.10');assert.equal(p.data.remaining,'99.90');assert.equal(p.data.error,'offline');
});
test('卸载后不显示旧保存错误、不更新页面状态',async()=>{
 const pending=deferred();const {p,notices}=page('chores',()=>pending.promise);p.data.form.title='浇花';const save=p.submit();p.onUnload();pending.reject(Error('late'));await save;
 assert.equal(notices.length,0);assert.equal(p.data.submitting,true);
});
test('账目时间按设备本地时区显示，跨日UTC记录不直接切片',async()=>{
 const previous=process.env.TZ;process.env.TZ='Asia/Shanghai';
 try {
  const row={...expense,created_at:'2026-10-14T18:03:00Z'};
  const {p}=page('accounting',async path=>path.includes('/transactions')?[row]:accountingResponse(path));
  await p.load();assert.equal(p.data.items[0].date,'10-15 02:03');
 } finally {if(previous===undefined)delete process.env.TZ;else process.env.TZ=previous;}
});
