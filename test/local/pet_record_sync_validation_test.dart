import 'package:flutter_test/flutter_test.dart';
import 'package:wo/local/plugins/pet_routes.dart';

// 准备好的纯结构/授权测试；本轮未执行Dart或Flutter。
void main(){
  const family='synthetic-family',id='synthetic-record',author='synthetic-author';
  Map<String,dynamic> fields()=>{'family_id':family,'pet_id':'synthetic-pet','record_type_id':'synthetic-type',
    'type_name_snapshot':'喂食','type_emoji_snapshot':'🐾','data_kind_snapshot':'general','name':'合成记录','note':null,
    'occurred_on':'2020-02-29','next_due_date':null,'weight_grams':null,'plan_id':null,'scheduled_due_date':null,
    'created_by':author,'created_at':'2026-01-31T12:00:00.000Z','updated_at':'2026-01-31T12:00:00.000Z'};
  void validate(Map<String,dynamic> value,{String actor=author,Map<String,dynamic>? previous,bool owner=false,bool deletion=false})=>
    PetRoutes.validateRecordSync(value,familyId:family,id:id,actor:actor,previous:previous,owner:owner,deletion:deletion);
  test('创建不得凭owner伪造他人作者，补录日期保留',(){
    expect(()=>validate(fields()),returnsNormally);
    expect(()=>validate(fields(),actor:'synthetic-other',owner:true),throwsFormatException);
  });
  test('只有实际前序作者或当前owner可修改，绑定字段不可改',(){
    final old=fields(),next={...old,'note':'新备注'};
    expect(()=>validate(next,previous:old),returnsNormally);
    expect(()=>validate(next,previous:old,actor:'synthetic-other'),throwsFormatException);
    expect(()=>validate(next,previous:old,actor:'synthetic-other',owner:true),returnsNormally);
    for(final key in ['family_id','pet_id','created_by','created_at','plan_id','scheduled_due_date']){
      expect(()=>validate({...next,key:'synthetic-forged'},previous:old,owner:true),throwsFormatException);
    }
  });
  test('未知父记录删除即使owner也拒绝，完整字段不得夹本机句柄',(){
    expect(()=>validate({},owner:true,deletion:true),throwsFormatException);
    expect(()=>validate({},previous:fields(),deletion:true),returnsNormally);
    expect(()=>validate({},actor:'synthetic-other',previous:fields(),deletion:true),throwsFormatException);
    expect(()=>validate({...fields(),'locator':'synthetic-local-only'}),throwsFormatException);
    expect(()=>validate({...fields(),'occurred_on':'2026-02-30'}),throwsFormatException);
    expect(()=>validate({...fields(),'data_kind_snapshot':'weight','weight_grams':null}),throwsFormatException);
  });
}
