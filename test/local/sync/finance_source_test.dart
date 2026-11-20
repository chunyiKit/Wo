// 已准备，未执行Dart/Flutter/SDK。合成已授权peer测试不代替真实握手或设备实测。
import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:wo/local/local_media_repository.dart';
import 'package:wo/local/local_store.dart';
import 'package:wo/local/media/native_media.dart';
import 'package:wo/local/plugins/stock_accounting.dart';
import 'package:wo/local/plugins/retirement_subscription.dart';
import 'package:wo/local/sync/peer_registry.dart';
import 'package:wo/local/sync/sync_policy.dart';
import 'package:wo/local/transport/native_local.dart';

const fid='finance-family',sub='subscription-one',due='2026-01-01',a='processor-a',b='processor-b';
const stampA='2026-11-20T00:00:00.000Z',stampB='2026-11-20T01:00:00.000Z';
String stable(String name)=>StockAccountingRoutes.uuid.v5(StockAccountingRoutes.namespace,name);
final chargeId=stable('subscription-charge:$fid:$sub:$due'),expenseId=stable('subscription-expense:$fid:$sub:$due');
PeerLink peer(String actor)=>PeerLink(id:'11111111-1111-4111-8111-111111111111',familyId:fid,remoteDeviceId:actor,
  secretRef:'wo.sync.link.11111111-1111-4111-8111-111111111111',remoteRole:'member');
class _AuthorizedRegistry implements PeerRegistry {
  _AuthorizedRegistry(this.store,this.crypto);
  @override final LocalStore store;@override final LocalCrypto crypto;
  @override Future<Set<String>> scopes(PeerLink peer) async=>{fid};
  @override dynamic noSuchMethod(Invocation invocation)=>super.noSuchMethod(invocation);
}
Json charge(String actor,int clock,{int amount=200})=>{'event_id':chargeId,'kind':'subscription_charge','subscription_id':sub,
  'amount_minor':amount,'period':'2026-01','due':due,'next_due_after':'2026-02-01','auto_recorded':true,
  'accounting_category':'subscription','exclude_from_budget':false,'note':'合成订阅','actor':actor,'order':clock,'created_at':actor==a?stampA:stampB};
Json expense(String actor,{int amount=200,String? timestamp})=>{'family_id':fid,'created_by':actor,'created_at':timestamp??(actor==a?stampA:stampB),
  'calendar_date':due,'calendar_offset_minutes':actor==a?0:60,'amount_minor':amount,'category':'subscription','note':'合成扣费','exclude_from_budget':false,
  'source_plugin':'subscription','source_id':sub,'source_occurrence':due,'source_event_id':chargeId};
Json op(String actor,int sequence,int clock,String suffix,String id,Json fields)=>{'space':fid,'actor':actor,'sequence':sequence,'clock':clock,
  'collection':'/families/$fid/$suffix','id':id,'kind':'patch','fields':fields};
Json delta(List<Json> ops)=>{'t':'delta','ops':ops,'thumbs':<Json>[],'more':false};
void main(){
  sqfliteFfiInit();late Directory dir;late LocalStore store;late LocalIncrementalStrategy strategy;
  setUp(()async{dir=await Directory.systemTemp.createTemp('wo-finance-source-');store=await LocalStore.open(factory:databaseFactoryFfi,path:'${dir.path}/local.sqlite');
    final crypto=NativeCrypto(),registry=_AuthorizedRegistry(store,crypto);
    strategy=LocalIncrementalStrategy(store,registry,LocalMediaRepository(store,native:NativeMedia(),directory:Directory('${dir.path}/media')),
      additionalSchemas:{...StockAccountingRoutes.syncFields,...RetirementSubscriptionRoutes.syncFields});});
  tearDown(()async{await store.close();await dir.delete(recursive:true);});
  List<Json> cycle(String actor,int first,int clock,{int amount=200})=>[
    op(actor,first,clock,'plugins/subscription/charges',chargeId,{'event':LocalStore.canonical(charge(actor,clock,amount:amount))}),
    op(actor,first+1,clock+1,'plugins/accounting/transactions',expenseId,{'family_id':fid,'entry':LocalStore.canonical(expense(actor,amount:amount))})];

  test('基础9字段手动账合法；来源4字段整组可选，稳定ID和due关联不能伪造',(){
    final manual=expense(a)..removeWhere((k,v)=>StockAccountingRoutes.entrySourceFields.contains(k));
    expect(()=>StockAccountingRoutes.decodeEntry(LocalStore.canonical(manual),familyId:fid,expectedId:'manual'),returnsNormally);
    for(final key in StockAccountingRoutes.entrySourceFields){final broken=expense(a)..remove(key);expect(()=>StockAccountingRoutes.decodeEntry(LocalStore.canonical(broken),familyId:fid,expectedId:expenseId),throwsFormatException);}
    expect(()=>StockAccountingRoutes.decodeEntry(LocalStore.canonical(expense(a)),familyId:fid,expectedId:'forged'),throwsFormatException);
    expect(()=>StockAccountingRoutes.decodeEntry(LocalStore.canonical({...expense(a),'source_occurrence':'2026-01-02'}),familyId:fid,expectedId:expenseId),throwsFormatException);
  });
  test('来源charge必须先获认证，缺失/不同actor/金额不符整批不落库',()async{
    final alone=cycle(a,1,10).last;alone['sequence']=1;
    await expectLater(strategy.apply(peer(a),delta([alone])),throwsFormatException);expect(await store.vector(fid),isEmpty);
    final forged=cycle(a,1,10);forged[0]['fields']={'event':LocalStore.canonical(charge(b,10))};
    await expectLater(strategy.apply(peer(a),delta(forged)),throwsFormatException);expect(await store.vector(fid),isEmpty);
    final mismatch=cycle(a,1,10);mismatch[1]['fields']={'family_id':fid,'entry':LocalStore.canonical(expense(a,amount:999))};
    await expectLater(strategy.apply(peer(a),delta(mismatch)),throwsFormatException);expect(await store.vector(fid),isEmpty);
  });
  test('同due两机processor/createdAt/offset真实差异合并成一笔，不双加金额',()async{
    await strategy.apply(peer(a),delta(cycle(a,1,10)));await strategy.apply(peer(b),delta(cycle(b,1,20)));
    final rows=await store.list(fid,'/families/$fid/plugins/accounting/transactions');expect(rows,hasLength(1));
    final value=StockAccountingRoutes.decodeEntry(rows.single['entry'],familyId:fid,expectedId:expenseId);
    expect(value['amount_minor'],200);expect(value['created_by'],b);expect(value['calendar_date'],due);expect(value['created_at'],stampB);
    final events=await store.db.query('operations',where:'space=? AND instr(payload,?)>0',whereArgs:[fid,chargeId]);expect(events.length,greaterThanOrEqualTo(2));
  });
  test('已认证初始op证明保留A原来源，B并发创建后A合法手动修正不被误拒',()async{
    await strategy.apply(peer(a),delta(cycle(a,1,10)));await strategy.apply(peer(b),delta(cycle(b,1,20)));
    final edited=op(a,3,30,'plugins/accounting/transactions',expenseId,{'family_id':fid,'entry':LocalStore.canonical(expense(a,amount:333))});
    await strategy.apply(peer(a),delta([edited]));
    final row=(await store.list(fid,'/families/$fid/plugins/accounting/transactions')).single;
    expect((jsonDecode(row['entry'] as String) as Map)['amount_minor'],333);
    expect((jsonDecode(row['entry'] as String) as Map)['created_at'],stampA);
    final fake=op(a,4,40,'plugins/accounting/transactions',expenseId,{'family_id':fid,'entry':LocalStore.canonical(expense(a,amount:444,timestamp:'2026-11-20T09:00:00Z'))});
    await expectLater(strategy.apply(peer(a),delta([fake])),throwsFormatException);
    expect((await store.vector(fid))[a],3);
  });
  test('金额语义冲突保留两份源charge给billing reducer，账目仍一笔wholeentry',()async{
    await strategy.apply(peer(a),delta(cycle(a,1,10,amount:200)));await strategy.apply(peer(b),delta(cycle(b,1,20,amount:300)));
    final rows=await store.list(fid,'/families/$fid/plugins/accounting/transactions');expect(rows,hasLength(1));
    expect((jsonDecode(rows.single['entry'] as String) as Map)['amount_minor'],300);
    final events=await store.db.query('operations',columns:['payload'],where:'space=?',whereArgs:[fid]);
    final charges=[for(final e in events)Json.from(jsonDecode(e['payload'] as String) as Map)].where((e)=>e['collection']=='/families/$fid/plugins/subscription/charges').toList();
    expect(charges,hasLength(2));
  });
  test('退休/订阅entry和event嵌套未知字段、重复键、来源actor、删除不可变事件均拒绝',(){
    final event=charge(a,10);
    void verify(Json fields,{String who=a,int clock=10,bool deleted=false})=>LocalIncrementalStrategy.validatePortableFields(
      familyId:fid,suffix:'plugins/subscription/charges',id:chargeId,fields:fields,actor:who,clock:clock,deletion:deleted);
    expect(()=>verify({'event':LocalStore.canonical(event)}),returnsNormally);
    expect(()=>verify({'event':LocalStore.canonical({...event,'unexpected':'value'})}),throwsFormatException);
    expect(()=>verify({'event':LocalStore.canonical(event).replaceFirst('"auto_recorded":true','"auto_recorded":true,"auto_recorded":true')}),throwsFormatException);
    expect(()=>verify({'event':LocalStore.canonical(event)},who:b),throwsFormatException);
    expect(()=>verify({},deleted:true),throwsFormatException);
  });
}
