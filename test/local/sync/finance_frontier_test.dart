// 准备schema测试；实际frontier同事务比较在finance库测试，当前未执行Dart/SDK。
import 'package:flutter_test/flutter_test.dart';
import 'package:wo/local/local_store.dart';
import 'package:wo/local/plugins/stock_accounting.dart';
import 'package:wo/local/sync/sync_policy.dart';

void main(){
  const fid='frontier-family',sub='subscription-one',token='11111111-1111-5111-8111-111111111111';
  final id=StockAccountingRoutes.uuid.v5(StockAccountingRoutes.namespace,'subscription-client:$fid:confirm-v1');
  Json response()=>{'id':sub,'name':'订阅','emoji':'📆','amount_minor':200,'cycle':'monthly','next_due':'2026-12-01','note':null,
    'notify_enabled':true,'notify_days_before':3,'auto_record':true,'accounting_category':'subscription','exclude_from_budget':false,'active':true,
    'family_id':fid,'created_by':'processor-a','created_at':'2026-11-20T00:00:00Z','created_on':'2026-11-20','acknowledged_charge_conflicts':<String>[],
    'amount':'2.00','days_until':11,'billing_conflict':false,'creator_name':null,'creator_emoji':null,'creator_avatar_url':null,'conflict_frontier':token};
  void validate(Json body,{Json? result})=>LocalIncrementalStrategy.validatePortableFields(familyId:fid,suffix:'plugins/subscription/requests',id:id,
    fields:{'fingerprint':LocalStore.canonical({'method':'PUT','tail':['subscription','subscriptions',sub],'body':{'client_id':'confirm-v1',...body},'query':{}}),'response':result??response()});
  test('确认账期必须带规范v5 frontier；schema不冒充库内同事务比较',(){
    expect(()=>validate({'confirm_billing':true,'next_due':'2026-12-01','expected_conflict_frontier':token}),returnsNormally);
    expect(()=>validate({'confirm_billing':true,'next_due':'2026-12-01'}),throwsFormatException);
    for(final bad in ['11111111-1111-4111-8111-111111111111',token.toUpperCase(),token+'\n','not-a-frontier']){
      // 本token全数字转大写不变，另用含a-f的版本覆盖大小写分支。
      if(bad==token)continue;
      expect(()=>validate({'confirm_billing':true,'next_due':'2026-12-01','expected_conflict_frontier':bad}),throwsFormatException);
    }
    expect(()=>validate({'confirm_billing':true,'next_due':'2026-12-01','expected_conflict_frontier':'AAAAAAAA-AAAA-5AAA-8AAA-AAAAAAAAAAAA'}),throwsFormatException);
  });
  test('普通资料不需expected，但响应仍必须给frontier；不把frontier塞进entry',(){
    expect(()=>validate({'name':'订阅新名'}),returnsNormally);
    final missing=response()..remove('conflict_frontier');expect(()=>validate({'name':'订阅新名'},result:missing),throwsFormatException);
    expect(StockAccountingRoutes.entryFields.contains('conflict_frontier'),false);
    expect(StockAccountingRoutes.entryFields.contains('expected_conflict_frontier'),false);
  });
}
