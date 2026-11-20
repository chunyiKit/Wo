// 准备回归；此轮未运行 Dart/Flutter/SDK，不代表手机协议执行通过。
import 'package:flutter_test/flutter_test.dart';
import 'package:wo/local/local_store.dart';
import 'package:wo/local/plugins/stock_accounting.dart';
import 'package:wo/local/sync/sync_policy.dart';

const fid='policy-family',actor='actor-a',stamp='2026-11-20T00:00:00.000Z';
Json event(String source,int order)=>{'event_id':'same-receipt','type':'receipt','buy_id':'buy','cycle':'initial',
  'item_id':'item','delta':2,'order':order,'actor':source,'created_at':stamp};
Json entry()=>{'family_id':fid,'created_by':actor,'created_at':stamp,'calendar_date':'2026-11-20',
  'calendar_offset_minutes':0,'amount_minor':123,'category':'dining','note':null,'exclude_from_budget':false};
void validate(String suffix,String id,Json fields,{Json? previous,String? source,int? clock,bool deletion=false})=>
  LocalIncrementalStrategy.validatePortableFields(familyId:fid,suffix:suffix,id:id,fields:fields,
    previous:previous,actor:source,clock:clock,deletion:deletion);

void main(){
  test('事件内部actor/order必须绑定外层操作；同receipt并发来源和时间差不拒绝',(){
    final a={'event':LocalStore.canonical(event(actor,7))};
    final b={'event':LocalStore.canonical(event('actor-b',99))};
    expect(()=>validate('plugins/stock/events','same-receipt',a,source:actor,clock:7),returnsNormally);
    expect(()=>validate('plugins/stock/events','same-receipt',b,previous:a,source:'actor-b',clock:99),returnsNormally);
    expect(()=>validate('plugins/stock/events','same-receipt',b,source:actor,clock:99),throwsFormatException);
    expect(()=>validate('plugins/stock/events','same-receipt',b,source:'actor-b',clock:7),throwsFormatException);
    expect(()=>validate('plugins/stock/events','same-receipt',{},source:actor,clock:7,deletion:true),throwsFormatException);
  });
  test('事件字符串重复键、隐藏原件字段和非完整事件均拒绝',(){
    final raw=LocalStore.canonical(event(actor,7));
    expect(()=>validate('plugins/stock/events','same-receipt',{'event':raw.replaceFirst('"delta":2','"delta":2,"delta":2')},source:actor,clock:7),throwsFormatException);
    expect(()=>validate('plugins/stock/events','same-receipt',{'event':LocalStore.canonical({...event(actor,7),'original_uri':'content://synthetic/1'})},source:actor,clock:7),throwsFormatException);
    expect(()=>validate('plugins/stock/events','same-receipt',{'event':'{"type":"receipt"}'},source:actor,clock:7),throwsFormatException);
  });
  test('账目严格嵌套schema、金额、账期和不可变创建来源；家庭成员可编辑金额',(){
    final initial={'family_id':fid,'entry':LocalStore.canonical(entry())};
    expect(()=>validate('plugins/accounting/transactions','transaction',initial,source:actor),returnsNormally);
    final edited={'family_id':fid,'entry':LocalStore.canonical({...entry(),'amount_minor':999})};
    expect(()=>validate('plugins/accounting/transactions','transaction',edited,previous:initial,source:'actor-b'),returnsNormally);
    expect(()=>validate('plugins/accounting/transactions','transaction',edited,source:'actor-b'),throwsFormatException);
    for(final mutation in [{'amount_minor':StockAccountingRoutes.maxMinor+1},{'calendar_date':'2026-02-30'},
      {'calendar_offset_minutes':1500},{'unexpected':'value'}]){
      expect(()=>validate('plugins/accounting/transactions','transaction',{'family_id':fid,'entry':LocalStore.canonical({...entry(),...mutation})},source:actor),throwsFormatException);
    }
    final timezone={'family_id':fid,'entry':LocalStore.canonical({...entry(),'created_at':'2026-11-30T16:30:00Z','calendar_offset_minutes':480,'calendar_date':'2026-12-01'})};
    expect(()=>validate('plugins/accounting/transactions','transaction',timezone),returnsNormally);
    final backdated={'family_id':fid,'entry':LocalStore.canonical({...entry(),'calendar_date':'2026-01-01'})};
    expect(()=>validate('plugins/accounting/transactions','transaction',backdated),returnsNormally);
  });
  test('预算updated_by绑定写入者；最终快照无actor仍严格检查JSON',(){
    Json budget(String who)=>{'family_id':fid,'entry':LocalStore.canonical({'monthly_amount_minor':10000,'updated_at':stamp,'updated_by':who})};
    expect(()=>validate('plugins/accounting/budget','monthly',budget(actor),source:actor),returnsNormally);
    expect(()=>validate('plugins/accounting/budget','monthly',budget('actor-b'),source:actor),throwsFormatException);
    expect(()=>validate('plugins/accounting/budget','monthly',budget('actor-b')),returnsNormally);
    expect(()=>validate('plugins/accounting/budget','wrong-id',budget(actor)),throwsFormatException);
  });
  test('请求缓存验证fingerprint、确定性claim ID和逐路由response，不让JSON字符串绕过',(){
    final body={'client_id':'budget-v1','monthly_amount':'100.00'};
    final fingerprint=LocalStore.canonical({'method':'PUT','tail':['accounting','budget'],'body':body,'query':{}});
    final id=StockAccountingRoutes.uuid.v5(StockAccountingRoutes.namespace,'accounting-client:$fid:budget-v1');
    final fields={'fingerprint':fingerprint,'response':{'monthly_amount':'100.00'}};
    expect(()=>validate('plugins/accounting/requests',id,fields),returnsNormally);
    expect(()=>validate('plugins/accounting/requests','forged-id',fields),throwsFormatException);
    expect(()=>validate('plugins/accounting/requests',id,{'fingerprint':fingerprint,'response':{'monthly_amount':'99.00'}}),throwsFormatException);
    expect(()=>validate('plugins/accounting/requests',id,{'fingerprint':fingerprint.replaceFirst('"method":"PUT"','"method":"PUT","method":"PUT"'),'response':{'monthly_amount':'100.00'}}),throwsFormatException);
  });
  test('库存to-buy缓存返回新buy ID合法；不能强制等于源item ID',(){
    final fingerprint=LocalStore.canonical({'method':'POST','tail':['stock','items','item','to-buy'],'body':{'client_id':'buy-v1'},'query':{}});
    final id=StockAccountingRoutes.uuid.v5(StockAccountingRoutes.namespace,'stock-client:$fid:buy-v1');
    final response={'id':'new-buy','family_id':fid,'created_by':actor,'created_at':stamp,'name':'米','emoji':'🌾',
      'want_qty':'袋','note':null,'stock_item_id':'item','bought':false,'bought_at':null,'purchase_cycle':'initial','receipt_conflict':false,
      'creator_name':null,'creator_emoji':null,'creator_avatar_url':null};
    expect(()=>validate('plugins/stock/requests',id,{'fingerprint':fingerprint,'response':response}),returnsNormally);
    expect(()=>validate('plugins/stock/requests',id,{'fingerprint':fingerprint,'response':{...response,'stock_item_id':'other'}}),throwsFormatException);
  });
  test('聊天仅完整不可变text消息；只作者可撤回，status不接受永久墓碑',(){
    const client='chat-client';final id=StockAccountingRoutes.uuid.v5(StockAccountingRoutes.namespace,'wo-chat-v1:$fid:$actor:$client');
    final fields={'family_id':fid,'created_by':actor,'client_id':client,'kind':'text','body':'hello','created_at':stamp};
    expect(()=>validate('plugins/chat/messages',id,fields,source:actor),returnsNormally);
    expect(()=>validate('plugins/chat/messages',id,{...fields,'body':'changed'},previous:fields,source:actor),throwsFormatException);
    expect(()=>validate('plugins/chat/messages',id,fields,previous:fields,source:'actor-b',deletion:true),throwsFormatException);
    expect(()=>validate('plugins/chat/messages',id,fields,previous:fields,source:actor,deletion:true),returnsNormally);
    expect(()=>validate('plugins/chat/status',actor,{},source:actor,deletion:true),throwsFormatException);
  });
  test('portable helper允许受限private回忆，不把手机传输范围套给加密备份',(){
    expect(()=>validate('plugins/memory/memories','memory',{'family_id':fid,'visibility':'private','created_by':actor,'title':'only local'}),returnsNormally);
    expect(LocalIncrementalStrategy.baseSchemas['plugins/recipe/settings'],{'seeded'});
    expect(()=>validate('plugins/recipe/settings','palette',{'seeded':true}),returnsNormally);
  });
}
