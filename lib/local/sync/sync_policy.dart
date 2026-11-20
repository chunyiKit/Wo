import 'dart:convert';
import 'dart:typed_data';
import '../local_media_repository.dart';
import '../local_store.dart';
import '../plugins/stock_accounting.dart';
import '../plugins/retirement_subscription.dart';
import 'strict_json.dart';
import 'peer_registry.dart';
import 'sync_wire.dart';

/// 集合适配与连接分离。未知业务集合明确失败，不降级发送原始SQLite或设备引用。
abstract interface class IncrementalSyncStrategy {
  Future<Map<String,dynamic>> state(PeerLink peer);
  Future<Map<String,dynamic>> delta(PeerLink peer,Map<String,dynamic> remoteState);
  Future<void> apply(PeerLink peer,Map<String,dynamic> delta);
}
class LocalIncrementalStrategy implements IncrementalSyncStrategy {
  LocalIncrementalStrategy(this.store,this.registry,this.media,{this.additionalSchemas=const{}});
  final LocalStore store;final PeerRegistry registry;final LocalMediaRepository media;
  final Map<String,Set<String>> additionalSchemas;
  static const baseSchemas=<String,Set<String>>{
    'family':{'name','slogan','emoji','background_url','created_at'},
    'members':{'family_id','user_id','role','status','display_name','avatar_emoji','avatar_url','joined_at'},
    'installed':{'plugin_id','enabled','config','layout'},
    'plugins/recipe/recipes':{'family_id','name','emoji','category','minutes','difficulty','servings','note','ingredients','steps','created_by','created_at','updated_at','cover_version','cover_url'},
    'plugins/recipe/tags':{'family_id','name','created_at','order'},
    'plugins/recipe/settings':{'seeded'},
    'plugins/expiry/items':{'family_id','name','emoji','kind','expire_on','note','notify_enabled','notify_days_before','active','created_by','created_at','updated_at'},
    'plugins/memory/memories':{'family_id','title','body','mood','location','visibility','event_date','created_by','created_at','updated_at'},
    'plugins/memory/media':{'memory_id','kind','thumbnail_sha256','thumbnail_bytes','width','height','duration_ms','created_by','sort_key'},
  };
  static const commentFields={'family_id','memory_id','body','created_by','created_at'};
  static final _sha=RegExp(r'^[a-f0-9]{64}$');
  static void _object(Map<String,dynamic> value,Set<String> fields){if(value.keys.toSet().length!=fields.length||!value.keys.toSet().containsAll(fields))throw const FormatException('同步字段无效');}
  Future<Set<String>> _allowed(PeerLink peer)async{final result=await registry.scopes(peer);if(result.any((s)=>s.startsWith('p_'))||!result.contains(peer.familyId))throw const FormatException('私密空间不得进入设备同步');return result;}
  String _suffix(String scope,String collection){final prefix='/families/$scope/';if(!collection.startsWith(prefix))throw const FormatException('集合跨空间');final suffix=collection.substring(prefix.length);if(suffix.split('/').any((s)=>!syncId(s)))throw const FormatException('集合标识无效');return suffix;}
  Set<String> _schema(String suffix){if(RegExp(r'^plugins/memory/memories/[A-Za-z0-9_-]{1,100}/comments$').hasMatch(suffix))return commentFields;
    final fields=additionalSchemas[suffix]??baseSchemas[suffix];if(fields==null)throw const FormatException('此集合尚无安全同步适配');return fields;}
  static void _noOriginal(Object? value,[int depth=0]){
    if(depth>10)throw const FormatException('同步字段过深');
    if(value is Map){for(final entry in value.entries){final k=entry.key;if(k is! String||{'locator','bookmark','asset_id','original_uri','original_bytes','original_handle','source_uri','file_path','api_key','access_token','token','secret','password'}.contains(k))throw const FormatException('本机句柄、原件或凭据禁止同步');_noOriginal(entry.value,depth+1);}}
    else if(value is List){if(value.length>4096)throw const FormatException('同步数组过大');for(final item in value){_noOriginal(item,depth+1);}}
    else if(value is double&&!value.isFinite){throw const FormatException('非有限数值');}
  }
  static Never _badEmbedded()=>throw const FormatException('嵌套业务JSON结构或来源无效');
  static Json _jsonObject(Object? value){
    if(value is! String||utf8.encode(value).length>LocalStore.maxOperationBytes)_badEmbedded();
    final parsed=decodeStrictJson(value);if(parsed is! Map)_badEmbedded();
    final result=Json.from(parsed);_noOriginal(result);return result;
  }
  static void _fields(Json value,Set<String> required,Set<String> optional){
    if(!required.every(value.containsKey)||value.keys.any((k)=>!required.contains(k)&&!optional.contains(k)))_badEmbedded();
  }
  static bool _text(Object? value,int max,{bool nullable=false,bool empty=false})=>
    value==null?nullable:value is String&&value.runes.length<=max&&(empty||value.trim().isNotEmpty);
  static bool _integer(Object? value,int min,int max)=>value is int&&value>=min&&value<=max;
  static bool _timestamp(Object? value){
    if(value is! String||value.length>64)return false;
    final date=DateTime.tryParse(value);return date!=null&&date.isUtc;
  }
  static bool _calendar(Object? value){
    if(value is! String||value.length!=10||!RegExp(r'^\d{4}-\d{2}-\d{2}$').hasMatch(value))return false;
    final date=DateTime.tryParse(value);return date!=null&&date.year>=1&&date.year<=9999&&StockAccountingRoutes.calendarDate(date)==value;
  }
  static int _money(Object? value,{bool nonnegative=false}){
    try{return StockAccountingRoutes.moneyMinor(value,nonnegative:nonnegative);}catch(_){_badEmbedded();}
  }
  static void _stockBody(Json body,{required bool item,bool creation=false}){
    _fields(body,creation?{'name'}:<String>{},item
      ?{'name','emoji','qty','unit','low_at','note','base_qty','confirm_stocktake','client_id'}
      :{'name','emoji','want_qty','note','bought','client_id'});
    for(final k in ['name','emoji']){if(body.containsKey(k)&&!_text(body[k],k=='name'?64:16))_badEmbedded();}
    for(final k in [if(item)'unit' else 'want_qty','note']){
      if(body.containsKey(k)&&!_text(body[k],k=='note'?500:item?16:32,nullable:true,empty:true))_badEmbedded();
    }
    for(final k in ['qty','base_qty','low_at']){
      if(body.containsKey(k)&&!(k=='low_at'&&body[k]==null)&&!_integer(body[k],0,StockAccountingRoutes.maxQuantity))_badEmbedded();
    }
    for(final k in ['confirm_stocktake','bought']){if(body.containsKey(k)&&body[k] is! bool)_badEmbedded();}
    if(body.containsKey('client_id')&&!_text(body['client_id'],100))_badEmbedded();
  }
  static void _entry(Json value,{required String familyId,required String id,Json? previous,String? actor,bool verifiedAutomaticSource=false,bool verifiedPriorOrigin=false}){
    StockAccountingRoutes.decodeEntry(LocalStore.canonical(value),familyId:familyId,expectedId:id);
    final automatic=StockAccountingRoutes.entrySourceFields.every(value.containsKey);
    if(previous!=null){
      final old=StockAccountingRoutes.decodeEntry(previous['entry'],familyId:familyId,expectedId:id);
      if(StockAccountingRoutes.entrySourceFields.any((key)=>value[key]!=old[key]))_badEmbedded();
      final collision=automatic&&verifiedAutomaticSource&&actor!=null&&value['created_by']==actor;
      final prior=automatic&&verifiedPriorOrigin;
      for(final key in ['family_id','created_by','created_at','calendar_date','calendar_offset_minutes']){
        if(value[key]!=old[key]&&!((collision||prior)&&{'created_by','created_at','calendar_offset_minutes'}.contains(key)))_badEmbedded();
      }
    }else if(actor!=null&&(value['created_by']!=actor||automatic&&!verifiedAutomaticSource)){_badEmbedded();}
    // calendar_date为独立业务账期；离线补记/订阅到期日可早于实际created_at，绝不反推改写。
  }
  static void _request(String suffix,String familyId,String id,Json fields){
    _fields(fields,{'fingerprint','response'},{});
    final fingerprint=_jsonObject(fields['fingerprint']);_fields(fingerprint,{'method','tail','body','query'},{});
    final plugin=suffix.startsWith('plugins/stock/')?'stock':'accounting';
    final rawTail=fingerprint['tail'];
    if(rawTail is! List||rawTail.length<2||rawTail.length>4||rawTail.any((v)=>v is! String||!syncId(v)))_badEmbedded();
    final tail=rawTail.cast<String>(),method=fingerprint['method'];
    if(tail[0]!=plugin||fingerprint['body'] is! Map||fingerprint['query'] is! Map||(fingerprint['query'] as Map).isNotEmpty)_badEmbedded();
    final body=Json.from(fingerprint['body'] as Map);_noOriginal(body);
    if(!_text(body['client_id'],100))_badEmbedded();
    final client=(body['client_id'] as String).trim();
    if(id!=StockAccountingRoutes.uuid.v5(StockAccountingRoutes.namespace,'$plugin-client:$familyId:$client'))_badEmbedded();
    if(plugin=='stock'){
      if(!['items','buys'].contains(tail[1]))_badEmbedded();
      if(tail.length==2&&method=='POST'||tail.length==3&&method=='PUT'){
        _stockBody(body,item:tail[1]=='items',creation:tail.length==2);
      }else if(tail.length==3&&method=='DELETE'){
        _fields(body,{'client_id'},{});
      }else if(tail.length==4&&method=='POST'){
        final item=tail[1]=='items',action=tail[3];
        if(item&&action=='to-buy'||!item&&action=='reopen'){_fields(body,{'client_id'},{});}
        else if(item&&action=='adjust'){
          _fields(body,{'client_id','delta_qty'},{});if(!_integer(body['delta_qty'],-StockAccountingRoutes.maxQuantity,StockAccountingRoutes.maxQuantity))_badEmbedded();
        }else if(!item&&action=='bought'){
          _fields(body,{'client_id'},{'into_stock_qty'});if(body['into_stock_qty']!=null&&!_integer(body['into_stock_qty'],0,StockAccountingRoutes.maxQuantity))_badEmbedded();
        }else{_badEmbedded();}
      }else{_badEmbedded();}
    }else{
      if(tail.length==2&&tail[1]=='categories'&&method=='POST'){
        _fields(body,{'client_id','label'},{'emoji'});if(!_text(body['label'],20)||body.containsKey('emoji')&&!_text(body['emoji'],16))_badEmbedded();
      }else if(tail.length==2&&tail[1]=='budget'&&method=='PUT'){
        _fields(body,{'client_id','monthly_amount'},{});_money(body['monthly_amount'],nonnegative:true);
      }else if(tail[1]=='transactions'&&(tail.length==2&&method=='POST'||tail.length==3&&method=='PUT')){
        _fields(body,tail.length==2?{'client_id','amount','category'}:{'client_id'},{'amount','category','note','exclude_from_budget'});
        if(body.containsKey('amount'))_money(body['amount']);
        if(body.containsKey('category')&&(body['category'] is! String||(body['category'] as String).length>16||!syncId(body['category'] as String)))_badEmbedded();
        if(body.containsKey('note')&&!_text(body['note'],200,nullable:true,empty:true)||body.containsKey('exclude_from_budget')&&body['exclude_from_budget'] is! bool)_badEmbedded();
      }else if(tail[1]=='transactions'&&tail.length==3&&method=='DELETE'){_fields(body,{'client_id'},{});}
      else{_badEmbedded();}
    }
    final rawResponse=fields['response'];if(rawResponse is! Map)_badEmbedded();final response=Json.from(rawResponse);
    _fields(response,{},StockAccountingRoutes.requestResponseFields);_noOriginal(response);
    if(response.isEmpty)_badEmbedded();
    if(method!='DELETE'&&(plugin=='stock'||tail[1]=='transactions')&&(response['id'] is! String||!syncId(response['id'] as String)))_badEmbedded();
    if(response.containsKey('family_id')&&response['family_id']!=familyId)_badEmbedded();
    for(final key in ['id','created_by','stock_item_id','deleted','purchase_cycle']){
      if(response[key]!=null&&(response[key] is! String||!syncId(response[key] as String)))_badEmbedded();
    }
    for(final key in ['created_at','bought_at']){if(response[key]!=null&&!_timestamp(response[key]))_badEmbedded();}
    if(response['creator_avatar_url']!=null)_badEmbedded();
    for(final key in ['qty','raw_qty']){if(response.containsKey(key)&&!_integer(response[key],-StockAccountingRoutes.safeMinor,StockAccountingRoutes.safeMinor))_badEmbedded();}
    if(response['low_at']!=null&&!_integer(response['low_at'],0,StockAccountingRoutes.maxQuantity))_badEmbedded();
    for(final key in ['quantity_conflict','is_low','bought','receipt_conflict','exclude_from_budget']){if(response.containsKey(key)&&response[key] is! bool)_badEmbedded();}
    if(response.containsKey('quantity_conflicts')&&(response['quantity_conflicts'] is! List||(response['quantity_conflicts'] as List).length>4096||(response['quantity_conflicts'] as List).any((v)=>v is! String)))_badEmbedded();
    if(response.containsKey('amount_minor')&&!_integer(response['amount_minor'],-StockAccountingRoutes.maxMinor,StockAccountingRoutes.maxMinor))_badEmbedded();
    if(response.containsKey('amount')){if(response['amount'] is! String)_badEmbedded();final minor=_money(response['amount']);if(response.containsKey('amount_minor')&&response['amount_minor']!=minor)_badEmbedded();}
    if(response.containsKey('monthly_amount')){if(response['monthly_amount'] is! String)_badEmbedded();_money(response['monthly_amount'],nonnegative:true);}
    if(response.containsKey('calendar_date')&&!_calendar(response['calendar_date'])||response.containsKey('calendar_offset_minutes')&&!_integer(response['calendar_offset_minutes'],-1440,1440))_badEmbedded();
    for(final key in ['name','emoji','unit','note','want_qty','label','category','creator_name','creator_emoji','code']){
      if(response.containsKey(key)&&!_text(response[key],key=='note'?500:key=='name'||key=='creator_name'?64:key=='want_qty'?32:20,nullable:true,empty:true))_badEmbedded();
    }
    if(response.containsKey('creation_request'))_stockBody(_jsonObject(response['creation_request']),item:response.containsKey('unit'),creation:true);
    if(method=='DELETE'){
      if(response.length!=1||response['deleted']!=tail[2])_badEmbedded();return;
    }
    if(plugin=='accounting'&&tail[1]=='categories'){
      _fields(response,{'code','label','emoji'},{});
      final label=(body['label'] as String).trim();
      final expected='c_${StockAccountingRoutes.uuid.v5(StockAccountingRoutes.namespace,'accounting-category:$familyId:$label').replaceAll('-','').substring(0,14)}';
      if(response['code']!=expected||response['label']!=label||response['emoji']!=(body.containsKey('emoji')?(body['emoji'] as String).trim():'💰'))_badEmbedded();
    }else if(plugin=='accounting'&&tail[1]=='budget'){
      _fields(response,{'monthly_amount'},{});if(_money(response['monthly_amount'],nonnegative:true)!=_money(body['monthly_amount'],nonnegative:true))_badEmbedded();
    }else if(plugin=='accounting'){
      _fields(response,{...StockAccountingRoutes.entryBaseFields,'id','amount','creator_name','creator_emoji','creator_avatar_url'},StockAccountingRoutes.entrySourceFields);
      _entry({for(final k in StockAccountingRoutes.entryFields)if(response.containsKey(k))k:response[k]},familyId:familyId,id:response['id'] as String);
    }else{
      final toBuy=tail.length==4&&tail[1]=='items'&&tail[3]=='to-buy';
      final item=tail[1]=='items'&&!toBuy;
      final metadata=<String>{'family_id','created_by','created_at','name','emoji',if(item)...['unit','low_at','note']else...['want_qty','note','stock_item_id']};
      _fields(response,{...metadata,'id','creator_name','creator_emoji','creator_avatar_url',
        if(item)...['qty','raw_qty','quantity_conflict','quantity_conflicts','is_low']
        else...['bought','bought_at','purchase_cycle','receipt_conflict']},{'creation_request'});
      final record=<String,dynamic>{for(final k in metadata)k:response[k],if(response.containsKey('creation_request'))'creation_request':response['creation_request']};
      validatePortableFields(familyId:familyId,suffix:item?'plugins/stock/items':'plugins/stock/buys',id:response['id'] as String,fields:record);
      if(item){
        final qty=response['qty'] as int,conflicts=response['quantity_conflicts'] as List;
        if(qty!=response['raw_qty']||response['quantity_conflict']!=(qty<0||qty>StockAccountingRoutes.maxQuantity||conflicts.isNotEmpty)||
            response['is_low']!=(response['low_at'] is int&&qty<=(response['low_at'] as int)))_badEmbedded();
      }else{
        if(response['purchase_cycle'] is! String||!syncId(response['purchase_cycle'] as String)||
            (response['bought']==true?!_timestamp(response['bought_at']):response['bought_at']!=null))_badEmbedded();
        if(toBuy&&response['stock_item_id']!=tail[2])_badEmbedded();
      }
    }
    final toBuy=plugin=='stock'&&tail.length==4&&tail[1]=='items'&&tail[3]=='to-buy';
    if(tail.length>=3&&!toBuy&&response['id']!=tail[2])_badEmbedded();
    if(tail.length==2&&method=='POST'&&(plugin=='stock'||tail[1]=='transactions')){
      final kind=plugin=='stock'?'create-${tail[1]}':'accounting-create';
      if(response['id']!=StockAccountingRoutes.uuid.v5(StockAccountingRoutes.namespace,'$familyId:$kind:new:$client'))_badEmbedded();
    }
  }

  static bool _period(Object? value)=>value is String&&value.length==7&&
    RegExp(r'^[0-9]{4}-(0[1-9]|1[0-2])$').hasMatch(value)&&int.parse(value.substring(0,4))>=1;
  static bool _idList(Object? value)=>value is List&&value.length<=4096&&value.every((v)=>v is String&&syncId(v));
  static bool _conflictList(Object? value)=>value is List&&value.length<=4096&&value.every((v)=>v is String);
  static bool _frontier(Object? value)=>value is String&&value.length==36&&
    RegExp(r'^[a-f0-9]{8}-[a-f0-9]{4}-5[a-f0-9]{3}-[89ab][a-f0-9]{3}-[a-f0-9]{12}$').hasMatch(value);
  static int _financeMoney(Object? value,{bool nonnegative=false,bool subscription=false}){
    try{return RetirementSubscriptionRoutes.minor(value,nonnegative:nonnegative,subscription:subscription);}catch(_){_badEmbedded();}
  }
  static int _renderedMoney(Object? value){
    if(value is! String||value.length>20||!RegExp(r'^-?[0-9]{1,14}\.[0-9]{2}$').hasMatch(value))_badEmbedded();
    final negative=value.startsWith('-'),parts=(value.startsWith('-')?value.substring(1):value).split('.');
    final minor=int.parse(parts[0])*100+int.parse(parts[1]);if(minor>RetirementSubscriptionRoutes.safeInteger)_badEmbedded();
    return negative?-minor:minor;
  }
  static Json _financeEvent(String familyId,String suffix,String id,Object? encoded,{String? actor,int? clock}){
    final decoded=_jsonObject(encoded);Json event;
    try{event=RetirementSubscriptionRoutes.decodeEvent(LocalStore.canonical(decoded),expectedId:id,actor:actor,order:clock,subscription:suffix=='plugins/subscription/charges');}
    catch(_){_badEmbedded();}
    if(!_integer(event['amount_minor'],-RetirementSubscriptionRoutes.safeInteger,RetirementSubscriptionRoutes.safeInteger)||!_period(event['period'])||event['actor'] is! String||!syncId(event['actor'] as String)||
        !_integer(event['order'],1,1<<40)||!_timestamp(event['created_at']))_badEmbedded();
    for(final key in ['account_id','debt_id','subscription_id']){if(event[key]!=null&&(event[key] is! String||!syncId(event[key] as String)))_badEmbedded();}
    String source;
    if(event['kind']=='subscription_charge'){
      if(!_calendar(event['due'])||!_calendar(event['next_due_after'])||event['accounting_category'] is! String||
          (event['accounting_category'] as String).length>16||!syncId(event['accounting_category'] as String)||event['exclude_from_budget'] is! bool)_badEmbedded();
      source='subscription-charge:$familyId:${event['subscription_id']}:${event['due']}';
    }else{
      if(event['kind']=='expense_settle'&&!_period(event['expense_period']))_badEmbedded();
      final origin=event['kind']=='income'?event['account_id']:event['kind']=='debt_payment'?event['debt_id']:'family';
      source='retirement:$familyId:${event['kind']}:${event['period']}:$origin';
    }
    if(id!=StockAccountingRoutes.uuid.v5(StockAccountingRoutes.namespace,source))_badEmbedded();
    return event;
  }
  static void _financeEntry(String familyId,String suffix,String id,Json fields,{Json? previous,String? actor}){
    _fields(fields,{'family_id','entry'},{});if(fields['family_id']!=familyId)_badEmbedded();
    final entry=_jsonObject(fields['entry']);
    final account=suffix=='plugins/retirement/accounts',debt=suffix=='plugins/retirement/debts',plan=suffix=='plugins/retirement/plan';
    final allowed=account?RetirementSubscriptionRoutes.accountEntryFields:debt?RetirementSubscriptionRoutes.debtEntryFields:
      plan?RetirementSubscriptionRoutes.planEntryFields:RetirementSubscriptionRoutes.subscriptionEntryFields;
    _fields(entry,allowed,{});
    if(plan){
      if(id!='family'||entry['retire_date']!=null&&!_calendar(entry['retire_date'])||
          entry['savings_goal_minor']!=null&&!_integer(entry['savings_goal_minor'],0,RetirementSubscriptionRoutes.maxMinor)||
          !RetirementSubscriptionRoutes.goalBases.contains(entry['goal_basis'])||!RetirementSubscriptionRoutes.surplusBases.contains(entry['surplus_basis'])||
          entry['updated_by'] is! String||!syncId(entry['updated_by'] as String)||actor!=null&&entry['updated_by']!=actor||!_timestamp(entry['updated_at']))_badEmbedded();
      return;
    }
    if(entry['family_id']!=familyId||entry['created_by'] is! String||!syncId(entry['created_by'] as String)||
        !_timestamp(entry['created_at'])||!_calendar(entry['created_on'])||!_text(entry['name'],40)||!_text(entry['emoji'],16))_badEmbedded();
    if(previous!=null){final old=_jsonObject(previous['entry']);for(final key in ['family_id','created_by','created_at','created_on']){if(entry[key]!=old[key])_badEmbedded();}}
    else if(actor!=null&&entry['created_by']!=actor){_badEmbedded();}
    if(account||debt){
      if(!(account?RetirementSubscriptionRoutes.accountKinds:RetirementSubscriptionRoutes.debtKinds).contains(entry['kind'])||
          !_integer(entry['balance_minor'],debt?0:-RetirementSubscriptionRoutes.maxMinor,RetirementSubscriptionRoutes.maxMinor)||
          !_integer(entry[debt?'monthly_payment_minor':'monthly_income_minor'],0,RetirementSubscriptionRoutes.maxMinor)||
          !_integer(entry[debt?'payment_day':'income_day'],1,28)||!_idList(entry['basis_event_ids'])||!_conflictList(entry['acknowledged_conflicts']))_badEmbedded();
      if(debt){if(entry['active'] is! bool||entry['from_account_id']!=null&&(entry['from_account_id'] is! String||!syncId(entry['from_account_id'] as String)))_badEmbedded();}
      else{
        final checks=entry['settlement_checks'];if(checks is! Map||checks.length>4096||checks.entries.any((e)=>e.key is! String||!syncId(e.key as String)||!_integer(e.value,-RetirementSubscriptionRoutes.safeInteger,RetirementSubscriptionRoutes.safeInteger)))_badEmbedded();
      }
    }else{
      if(!_integer(entry['amount_minor'],1,StockAccountingRoutes.maxMinor)||!{'monthly','yearly'}.contains(entry['cycle'])||!_calendar(entry['next_due'])||
          !_text(entry['note'],200,nullable:true,empty:true)||!_integer(entry['notify_days_before'],0,60)||
          entry['accounting_category'] is! String||(entry['accounting_category'] as String).length>16||!syncId(entry['accounting_category'] as String)||
          !['notify_enabled','auto_record','exclude_from_budget','active'].every((k)=>entry[k] is bool)||!_conflictList(entry['acknowledged_charge_conflicts']))_badEmbedded();
    }
  }
  static void _financeRequest(String familyId,String suffix,String id,Json fields){
    _fields(fields,{'fingerprint','response'},{});final fp=_jsonObject(fields['fingerprint']);_fields(fp,{'method','tail','body','query'},{});
    final plugin=suffix.startsWith('plugins/retirement/')?'retirement':'subscription',rawTail=fp['tail'];
    if(rawTail is! List||rawTail.length<2||rawTail.length>3||rawTail.any((v)=>v is! String||!syncId(v))||fp['body'] is! Map||fp['query'] is! Map||(fp['query'] as Map).isNotEmpty)_badEmbedded();
    final tail=rawTail.cast<String>(),body=Json.from(fp['body'] as Map),method=fp['method'];_noOriginal(body);
    if(tail[0]!=plugin||!_text(body['client_id'],100)||id!=StockAccountingRoutes.uuid.v5(StockAccountingRoutes.namespace,'$plugin-client:$familyId:${(body['client_id'] as String).trim()}'))_badEmbedded();
    final resource=tail[1],subscription=plugin=='subscription',plan=!subscription&&resource=='plan',debt=!subscription&&resource=='debts';
    if(subscription&&resource!='subscriptions'||!subscription&&!{'accounts','debts','plan'}.contains(resource))_badEmbedded();
    if(method=='DELETE'){
      if(tail.length!=3||plan)_badEmbedded();_fields(body,{'client_id'},{});
    }else{
      if(plan?(tail.length!=2||method!='PUT'):(tail.length==2?method!='POST':method!='PUT'))_badEmbedded();
      final keys=subscription?{'name','emoji','amount','cycle','next_due','note','notify_enabled','notify_days_before','auto_record','accounting_category','exclude_from_budget','active','confirm_billing','expected_conflict_frontier','client_id'}:
        plan?{'retire_date','savings_goal','goal_basis','surplus_basis','client_id'}:
        {'name','kind','emoji','balance',if(debt)...['monthly_payment','payment_day','from_account_id','active']else...['monthly_income','income_day'],'expected_conflict_frontier','client_id'};
      _fields(body,{'client_id'},keys);
      if(body.containsKey('expected_conflict_frontier')&&!_frontier(body['expected_conflict_frontier']))_badEmbedded();
      if(tail.length==3&&method=='PUT'&&(subscription?body['confirm_billing']==true:!plan&&body.containsKey('balance'))&&!_frontier(body['expected_conflict_frontier']))_badEmbedded();
      if(!plan&&tail.length==2&&(!body.containsKey('name')||!body.containsKey(subscription?'amount':'balance')||subscription&&!body.containsKey('next_due')))_badEmbedded();
      for(final key in ['name','emoji']){if(body.containsKey(key)&&!_text(body[key],key=='name'?40:16))_badEmbedded();}
      for(final key in ['amount','balance','monthly_payment','monthly_income','savings_goal']){
        if(body.containsKey(key)&&!(key=='savings_goal'&&body[key]==null)){
          final minor=_financeMoney(body[key],nonnegative:key!='balance'||debt,subscription:key=='amount');if(key=='amount'&&minor<=0)_badEmbedded();
        }
      }
      if(body.containsKey('kind')&&!(debt?RetirementSubscriptionRoutes.debtKinds:RetirementSubscriptionRoutes.accountKinds).contains(body['kind']))_badEmbedded();
      for(final key in ['income_day','payment_day']){if(body.containsKey(key)&&!_integer(body[key],1,28))_badEmbedded();}
      for(final key in ['active','confirm_billing','notify_enabled','auto_record','exclude_from_budget']){if(body.containsKey(key)&&body[key] is! bool)_badEmbedded();}
      for(final key in ['retire_date','next_due']){if(body.containsKey(key)&&!(key=='retire_date'&&body[key]==null)&&!_calendar(body[key]))_badEmbedded();}
      if(body['from_account_id']!=null&&(body['from_account_id'] is! String||!syncId(body['from_account_id'] as String)))_badEmbedded();
      if(body.containsKey('note')&&!_text(body['note'],200,nullable:true,empty:true)||body.containsKey('notify_days_before')&&!_integer(body['notify_days_before'],0,60)||
          body.containsKey('cycle')&&!{'monthly','yearly'}.contains(body['cycle'])||body.containsKey('accounting_category')&&(body['accounting_category'] is! String||(body['accounting_category'] as String).length>16||!syncId(body['accounting_category'] as String))||
          body.containsKey('goal_basis')&&!RetirementSubscriptionRoutes.goalBases.contains(body['goal_basis'])||body.containsKey('surplus_basis')&&!RetirementSubscriptionRoutes.surplusBases.contains(body['surplus_basis']))_badEmbedded();
      if(body['confirm_billing']==true&&!body.containsKey('next_due'))_badEmbedded();
    }
    if(fields['response'] is! Map)_badEmbedded();final response=Json.from(fields['response'] as Map);_noOriginal(response);
    _fields(response,{},{...RetirementSubscriptionRoutes.requestResponseFields,'conflict_frontier'});
    if(method=='DELETE'){_fields(response,{'deleted'},{});if(response['deleted']!=tail[2])_badEmbedded();return;}
    if(plan){
      _fields(response,{'retire_date','savings_goal','goal_basis','surplus_basis'},{});
      if(response['retire_date']!=null&&!_calendar(response['retire_date'])||response['savings_goal']!=null&&_renderedMoney(response['savings_goal'])<0||
          !RetirementSubscriptionRoutes.goalBases.contains(response['goal_basis'])||!RetirementSubscriptionRoutes.surplusBases.contains(response['surplus_basis']))_badEmbedded();return;
    }
    final entryFields=subscription?RetirementSubscriptionRoutes.subscriptionEntryFields:debt?RetirementSubscriptionRoutes.debtEntryFields:RetirementSubscriptionRoutes.accountEntryFields;
    final derived=subscription?{'amount','days_until','billing_conflict','conflict_frontier'}:debt?{'balance','balance_conflict','monthly_payment','conflict_frontier'}:{'balance','balance_conflict','monthly_income','settlement_conflict','conflict_frontier'};
    _fields(response,{...entryFields,...derived,'id','creator_name','creator_emoji','creator_avatar_url'},{});
    if(response['id'] is! String||!syncId(response['id'] as String)||response['creator_avatar_url']!=null||
        !_text(response['creator_name'],64,nullable:true,empty:true)||!_text(response['creator_emoji'],16,nullable:true,empty:true))_badEmbedded();
    if(!_frontier(response['conflict_frontier']))_badEmbedded();
    final entry=<String,dynamic>{for(final key in entryFields)key:response[key]};
    _financeEntry(familyId,'plugins/$plugin/$resource',response['id'] as String,{'family_id':familyId,'entry':LocalStore.canonical(entry)});
    if(subscription){if(_renderedMoney(response['amount'])!=entry['amount_minor']||!_integer(response['days_until'],-4000000,4000000)||response['billing_conflict'] is! bool)_badEmbedded();}
    else{_renderedMoney(response['balance']);if(response['balance_conflict'] is! bool||!debt&&response['settlement_conflict'] is! bool||
        _renderedMoney(response[debt?'monthly_payment':'monthly_income'])!=entry[debt?'monthly_payment_minor':'monthly_income_minor'])_badEmbedded();}
    final expected=tail.length==3?tail[2]:StockAccountingRoutes.uuid.v5(StockAccountingRoutes.namespace,subscription?'$familyId:subscription:${body['client_id']}':'$familyId:$resource:${body['client_id']}');
    if(response['id']!=expected)_badEmbedded();
  }

  Future<({bool initial,bool priorOrigin})> _automaticSource(String familyId,String scope,String id,Json fields,Json? previous,
      String actor,int clock,Map<String,Json> pendingProofs)async{
    final entry=StockAccountingRoutes.decodeEntry(fields['entry'],familyId:familyId,expectedId:id);
    if(!StockAccountingRoutes.entrySourceFields.any(entry.containsKey))return (initial:false,priorOrigin:false);
    final sourceId=entry['source_event_id'] as String,creator=entry['created_by'] as String;
    final collection='/families/$scope/plugins/subscription/charges',key='$scope|$sourceId|$creator';
    Json? proof=pendingProofs[key];
    if(proof==null){
      // 只取已保存的原actor操作，不把另一设备的LWW文档快照当成来源签发证明。
      final rows=await store.db.query('operations',columns:['payload'],
        where:'space=? AND actor=? AND instr(payload,?)>0',whereArgs:[scope,creator,sourceId],orderBy:'sequence',limit:256);
      for(final row in rows){final op=Json.from(decodeStrictJson(row['payload'] as String) as Map);
        if(op['collection']==collection&&op['id']==sourceId&&op['actor']==creator&&op['kind']=='patch'){proof=op;break;}
      }
    }
    if(proof==null||proof['space']!=scope||proof['collection']!=collection||proof['id']!=sourceId||
        proof['actor']!=creator||proof['clock'] is! int||proof['fields'] is! Map)_badEmbedded();
    final proofFields=Json.from(proof['fields'] as Map);_fields(proofFields,{'event'},{});
    final charge=_financeEvent(familyId,'plugins/subscription/charges',sourceId,proofFields['event'],actor:creator,clock:proof['clock'] as int);
    if(charge['auto_recorded']!=true||charge['subscription_id']!=entry['source_id']||charge['due']!=entry['source_occurrence'])_badEmbedded();
    final initial=entry['created_by']==actor&&entry['amount_minor']==charge['amount_minor']&&
      entry['category']==charge['accounting_category']&&entry['exclude_from_budget']==charge['exclude_from_budget'];
    bool origin(Json op){
      if(op['space']!=scope||op['collection']!='/families/$scope/plugins/accounting/transactions'||op['id']!=id||op['kind']!='patch'||
          op['actor']!=creator||!_integer(op['sequence'],1,1<<40)||op['clock'] is! int||(op['clock'] as int)<=charge['order']||
          (op['clock'] as int)>=clock||op['fields'] is! Map)return false;
      final payload=Json.from(op['fields'] as Map);if(payload['entry'] is! String)return false;
      final value=StockAccountingRoutes.decodeEntry(payload['entry'],familyId:familyId,expectedId:id);
      return value['created_by']==creator&&value['created_at']==entry['created_at']&&value['calendar_offset_minutes']==entry['calendar_offset_minutes']&&
        StockAccountingRoutes.entrySourceFields.every((k)=>value[k]==entry[k])&&value['amount_minor']==charge['amount_minor']&&
        value['category']==charge['accounting_category']&&value['exclude_from_budget']==charge['exclude_from_budget'];
    }
    var priorOrigin=false;
    if(!initial){
      priorOrigin=pendingProofs.values.any(origin);
      if(!priorOrigin){
        final rows=await store.db.query('operations',columns:['payload'],where:'space=? AND actor=? AND instr(payload,?)>0',whereArgs:[scope,creator,id],orderBy:'sequence',limit:256);
        for(final row in rows){if(origin(Json.from(decodeStrictJson(row['payload'] as String) as Map))){priorOrigin=true;break;}}
      }
    }
    if(previous==null&&!initial)_badEmbedded();
    if(previous!=null){
      final old=StockAccountingRoutes.decodeEntry(previous['entry'],familyId:familyId,expectedId:id);
      if(StockAccountingRoutes.entrySourceFields.any((k)=>old[k]!=entry[k]))_badEmbedded();
      final originChanged=['created_by','created_at','calendar_offset_minutes'].any((k)=>old[k]!=entry[k]);
      if(originChanged&&!initial&&!priorOrigin)_badEmbedded();
    }
    return (initial:initial,priorOrigin:priorOrigin);
  }
  static void _financeNotification(Json fields,{String? actor,Json? previous}){
    _fields(fields,{'type','title','body','icon_emoji','created_by','created_at','read_by','status','recipient_ids','source_plugin','source_id'},{});
    if(!{'retirement','subscription'}.contains(fields['source_plugin'])||
        !(fields['source_plugin']=='retirement'?{'retirement_debt_charged','retirement_expense_settled'}:{'subscription_due','subscription_charged'}).contains(fields['type'])||
        !_text(fields['title'],200)||!_text(fields['body'],2000)||!_text(fields['icon_emoji'],16)||
        fields['created_by'] is! String||!syncId(fields['created_by'] as String)||!_timestamp(fields['created_at'])||
        fields['status']!='pending_local_delivery'||fields['read_by'] is! List||(fields['read_by'] as List).isNotEmpty||
        !_idList(fields['recipient_ids'])||(fields['recipient_ids'] as List).length>128||fields['source_id'] is! String||!syncId(fields['source_id'] as String))_badEmbedded();
    if(actor!=null&&previous==null&&fields['created_by']!=actor)_badEmbedded();
    if(previous!=null&&['source_plugin','source_id','type'].any((k)=>previous[k]!=fields[k]))_badEmbedded();
  }

  /// 字段不含文档id；备份可复用本机句柄隔离和嵌套schema，不需要导出设备引用。
  /// actor/clock同时提供时还验证不可变事件的操作来源；最终快照无日志时只做结构验证。
  static void validatePortableFields({required String familyId,required String suffix,required String id,
    required Json fields,Json? previous,String? actor,int? clock,bool deletion=false,bool verifiedAutomaticSource=false,bool verifiedPriorOrigin=false}){
    _noOriginal(fields);
    if(RetirementSubscriptionRoutes.immutableCollections.contains(suffix)){
      if(deletion)_badEmbedded();_fields(fields,{'event'},{});_financeEvent(familyId,suffix,id,fields['event'],actor:actor,clock:clock);return;
    }
    if(suffix=='plugins/retirement/requests'||suffix=='plugins/subscription/requests'){
      if(deletion)_badEmbedded();_financeRequest(familyId,suffix,id,fields);return;
    }
    if(!deletion&&(suffix=='plugins/retirement/accounts'||suffix=='plugins/retirement/debts'||suffix=='plugins/retirement/plan'||suffix=='plugins/subscription/subscriptions')){
      _financeEntry(familyId,suffix,id,fields,previous:previous,actor:actor);return;
    }
    if(suffix=='notifications'&&{'retirement','subscription'}.contains(fields['source_plugin'])){
      if(deletion)_badEmbedded();_financeNotification(fields,actor:actor,previous:previous);return;
    }
    if(suffix=='plugins/stock/events'){
      if(deletion)_badEmbedded();_fields(fields,{'event'},{});
      final decoded=_jsonObject(fields['event']);
      StockAccountingRoutes.decodeEvent(LocalStore.canonical(decoded),expectedId:id,actor:actor,order:clock);
      if(decoded.containsKey('delta')&&!_integer(decoded['delta'],-StockAccountingRoutes.safeMinor,StockAccountingRoutes.safeMinor))_badEmbedded();
      if(decoded['actor'] is! String||!syncId(decoded['actor'] as String)||!syncId(id)||
          !_integer(decoded['order'],1,1<<40)||!_timestamp(decoded['created_at']))_badEmbedded();
      for(final key in ['item_id','buy_id','cycle','next_cycle']){if(decoded[key]!=null&&(decoded[key] is! String||!syncId(decoded[key] as String)))_badEmbedded();}
      // 同event_id可有不同actor/order的独立源操作；保留日志供库存冲突reducer处理。
      return;
    }
    if(suffix.endsWith('/requests')&&(suffix.startsWith('plugins/stock/')||suffix.startsWith('plugins/accounting/'))){
      if(deletion)_badEmbedded();_request(suffix,familyId,id,fields);return;
    }
    if(deletion){
      if(suffix=='plugins/chat/messages'&&(previous==null||actor==null||previous['created_by']!=actor))_badEmbedded();
      if(suffix=='plugins/chat/status')_badEmbedded();
      return;
    }
    if(suffix=='plugins/recipe/settings'){
      _fields(fields,{'seeded'},{});if(id!='palette'||fields['seeded']!=true)_badEmbedded();
    }else if(suffix=='plugins/stock/items'||suffix=='plugins/stock/buys'){
      final item=suffix.endsWith('/items');
      _fields(fields,{'family_id','created_by','created_at','name','emoji'},item
        ?{'unit','low_at','note','creation_request'}:{'want_qty','note','stock_item_id','creation_request'});
      if(fields['family_id']!=familyId||fields['created_by'] is! String||!syncId(fields['created_by'] as String)||!_timestamp(fields['created_at'])||
          !_text(fields['name'],64)||!_text(fields['emoji'],16)||!_text(fields['note'],500,nullable:true,empty:true))_badEmbedded();
      if(item){if(!_text(fields['unit'],16,nullable:true,empty:true)||fields['low_at']!=null&&!_integer(fields['low_at'],0,StockAccountingRoutes.maxQuantity))_badEmbedded();}
      else if(!_text(fields['want_qty'],32,nullable:true,empty:true)||fields['stock_item_id']!=null&&(fields['stock_item_id'] is! String||!syncId(fields['stock_item_id'] as String)))_badEmbedded();
      if(fields.containsKey('creation_request'))_stockBody(_jsonObject(fields['creation_request']),item:item,creation:true);
    }else if(suffix=='plugins/accounting/transactions'){
      _fields(fields,{'family_id','entry'},{});if(fields['family_id']!=familyId)_badEmbedded();
      _entry(_jsonObject(fields['entry']),familyId:familyId,id:id,previous:previous,actor:actor,verifiedAutomaticSource:verifiedAutomaticSource,verifiedPriorOrigin:verifiedPriorOrigin);
    }else if(suffix=='plugins/accounting/budget'){
      _fields(fields,{'family_id','entry'},{});final budget=_jsonObject(fields['entry']);_fields(budget,StockAccountingRoutes.budgetEntryFields,{});
      if(id!='monthly'||fields['family_id']!=familyId||!_integer(budget['monthly_amount_minor'],0,StockAccountingRoutes.maxMinor)||
          !_timestamp(budget['updated_at'])||budget['updated_by'] is! String||!syncId(budget['updated_by'] as String)||
          actor!=null&&budget['updated_by']!=actor)_badEmbedded();
    }else if(suffix=='plugins/accounting/categories'){
      _fields(fields,{'family_id','label','emoji','created_at'},{});
      if(fields['family_id']!=familyId||!_text(fields['label'],20)||!_text(fields['emoji'],16)||!_timestamp(fields['created_at']))_badEmbedded();
    }else if(suffix=='plugins/chat/messages'){
      _fields(fields,{'family_id','created_by','client_id','kind','body','created_at'},{});
      if(fields['family_id']!=familyId||fields['created_by'] is! String||!syncId(fields['created_by'] as String)||
          fields['client_id'] is! String||!syncId(fields['client_id'] as String)||fields['kind']!='text'||
          !_text(fields['body'],2000)||!_timestamp(fields['created_at'])||
          id!=StockAccountingRoutes.uuid.v5(StockAccountingRoutes.namespace,'wo-chat-v1:$familyId:${fields['created_by']}:${fields['client_id']}'))_badEmbedded();
      if(previous==null){if(actor!=null&&fields['created_by']!=actor)_badEmbedded();}
      else if(fields.keys.any((k)=>fields[k]!=previous[k])){_badEmbedded();}
    }else if(suffix=='plugins/chat/status'){
      _fields(fields,{'family_id','created_by','emoji','text','updated_at'},{});
      if(fields['family_id']!=familyId||fields['created_by']!=id||actor!=null&&actor!=id||
          !_text(fields['emoji'],16,empty:true)||!_text(fields['text'],80,empty:true)||!_timestamp(fields['updated_at']))_badEmbedded();
    }
  }
  Future<Map<String,dynamic>> _validateState(PeerLink peer,Map<String,dynamic> value)async{
    _object(value,{'t','vectors','missing'});if(value['t']!='state'||value['vectors'] is! Map||value['missing'] is! List)throw const FormatException('增量状态无效');
    final allowed=await _allowed(peer);final vectors=Map<String,dynamic>.from(value['vectors'] as Map);
    if(vectors.length!=allowed.length||!vectors.keys.toSet().containsAll(allowed))throw const FormatException('状态越权');
    for(final v in vectors.values){if(v is! Map||v.length>128)throw const FormatException('游标无效');for(final entry in v.entries){if(entry.key is! String||!syncId(entry.key as String)||entry.value is! int||(entry.value as int)<0||(entry.value as int)>1<<40)throw const FormatException('游标无效');}}
    if((value['missing'] as List).length>16)throw const FormatException('缩略图请求过多');for(final raw in value['missing'] as List){final item=Map<String,dynamic>.from(raw as Map);_object(item,{'space','id','sha256'});if(!allowed.contains(item['space'])||item['id'] is! String||!syncId(item['id'] as String)||item['sha256'] is! String||!_sha.hasMatch(item['sha256'] as String))throw const FormatException('缩略图请求范围无效');}
    return value;
  }
  @override Future<Map<String,dynamic>> state(PeerLink peer)async{
    final allowed=(await _allowed(peer)).toList()..sort();final vectors=<String,dynamic>{},missing=<Map<String,dynamic>>[];
    for(final scope in allowed){vectors[scope]=await store.vector(scope);for(final row in await store.list(scope,'/families/$scope/plugins/memory/media')){
      if(missing.length>=16)break;final parent=await store.get(scope,'/families/$scope/plugins/memory/memories',row['memory_id'] as String);if(parent==null)continue;
      final file=await media.thumbnailFile(row['id'] as String);if(file==null||await file.length()>LocalMediaRepository.maxThumbnailBytes||LocalMediaRepository.hash(await file.readAsBytes())!=row['thumbnail_sha256'])missing.add({'space':scope,'id':row['id'],'sha256':row['thumbnail_sha256']});
    }}return {'t':'state','vectors':vectors,'missing':missing};
  }
  @override Future<Map<String,dynamic>> delta(PeerLink peer,Map<String,dynamic> remoteState)async{
    await _validateState(peer,remoteState);final scopes=(await _allowed(peer)).toList()..sort();final ops=<Json>[],thumbs=<Json>[],sent=<String>{};var more=false;
    Future<void> addThumb(String scope,String id,String expected)async{if(thumbs.length>=16||!sent.add('$scope:$id'))return;final thumb=await media.thumbnailForWire(scope,id);if(thumb==null||thumb['sha256']!=expected)return;final trial={'t':'delta','ops':ops,'thumbs':[...thumbs,thumb],'more':false};if(wireBytes(trial).length<=syncMaxPlainBytes)thumbs.add(thumb);}
    for(final scope in scopes){final vector=Map<String,dynamic>.from((remoteState['vectors'] as Map)[scope] as Map);final rows=await store.exportOwnSince(scope,vector[store.deviceId] as int? ??0);
      for(final op in rows){if(ops.length>=64||wireBytes({'t':'delta','ops':[...ops,op],'thumbs':thumbs,'more':true}).length>syncMaxPlainBytes){more=true;break;}
        final suffix=_suffix(scope,op['collection'] as String),schema=_schema(suffix),fields=Map<String,dynamic>.from(op['fields'] as Map);
        if(fields.keys.any((k)=>!schema.contains(k)))throw const FormatException('出口包含未经适配的字段');
        if(suffix=='plugins/chat/messages'&&op['kind']=='patch')_fields(fields,{'family_id','created_by','client_id','kind','body','created_at'},{});
        for(final key in ['avatar_url','background_url','cover_url']){if(fields[key]!=null)throw const FormatException('本机媒体不得在拒收前泄漏');}
        if(suffix=='plugins/memory/memories'&&fields.containsKey('visibility')&&fields['visibility']!=(scope==peer.familyId?'family':'couple'))throw const FormatException('出口回忆范围无效');
        final existingRows=await store.db.query('documents',columns:['data'],where:'space=? AND collection=? AND id=?',whereArgs:[scope,op['collection'],op['id']]);
        final previous=existingRows.isEmpty?null:Json.from(jsonDecode(existingRows.single['data'] as String) as Map);
        final complete=<String,dynamic>{...?previous,...fields};
        final verified=suffix=='plugins/accounting/transactions'&&op['kind']=='patch'?await _automaticSource(peer.familyId,scope,op['id'] as String,complete,previous,store.deviceId,op['clock'] as int,{}):(initial:false,priorOrigin:false);
        validatePortableFields(familyId:peer.familyId,suffix:suffix,id:op['id'] as String,fields:complete,previous:previous,actor:store.deviceId,clock:op['clock'] as int,deletion:op['kind']=='delete',verifiedAutomaticSource:verified.initial,verifiedPriorOrigin:verified.priorOrigin);ops.add(op);
        if((op['collection'] as String).endsWith('/plugins/memory/media')&&op['kind']=='patch'){final fields=op['fields'] as Map;if(fields['thumbnail_sha256'] is String)await addThumb(scope,op['id'] as String,fields['thumbnail_sha256'] as String);}
      }
      if(rows.length==64)more=true;
    }
    for(final raw in remoteState['missing'] as List){final item=Map<String,dynamic>.from(raw as Map);await addThumb(item['space'] as String,item['id'] as String,item['sha256'] as String);}
    return {'t':'delta','ops':ops,'thumbs':thumbs,'more':more};
  }
  @override Future<void> apply(PeerLink peer,Map<String,dynamic> value)async{
    _object(value,{'t','ops','thumbs','more'});if(value['t']!='delta'||value['ops'] is! List||value['thumbs'] is! List||value['more'] is! bool||(value['ops'] as List).length>64||(value['thumbs'] as List).length>16||wireBytes(value).length>syncMaxPlainBytes)throw const FormatException('增量批次无效');
    final allowed=await _allowed(peer);final pendingProofs=<String,Json>{};final grouped=<String,List<Json>>{},shadow=<String,Json?>{},deleted=<String,bool>{},prefix=<String,int>{};
    Future<Json?> row(String s,String c,String id)async{final k='$s|$c|$id';if(shadow.containsKey(k))return shadow[k];
      final rows=await store.db.query('documents',columns:['data','deleted'],where:'space=? AND collection=? AND id=?',whereArgs:[s,c,id]);if(rows.isEmpty)return null;deleted[k]=rows.single['deleted']==1;return {...Map<String,dynamic>.from(jsonDecode(rows.single['data'] as String) as Map),'id':id};}
    for(final raw in value['ops'] as List){final op=Map<String,dynamic>.from(raw as Map);_object(op,{'space','actor','sequence','clock','collection','id','kind','fields'});
      final scope=op['space'],collection=op['collection'],id=op['id'];
      if(scope is! String||!allowed.contains(scope)||scope.startsWith('p_')||op['actor']!=peer.remoteDeviceId||collection is! String||id is! String||!syncId(id)||op['sequence'] is! int||op['clock'] is! int||(op['sequence'] as int)<1||(op['sequence'] as int)>1<<40||(op['clock'] as int)<1||(op['clock'] as int)>1<<40||!['patch','delete'].contains(op['kind'])||op['fields'] is! Map)throw const FormatException('增量身份或范围无效');
      final known=prefix[scope]??((await store.vector(scope))[peer.remoteDeviceId]??0);final sequence=op['sequence'] as int;if(sequence>known+1)throw const FormatException('增量不能跳过未确认序号');if(sequence==known+1)prefix[scope]=sequence;
      final suffix=_suffix(scope,collection);if(scope!=peer.familyId&&!suffix.startsWith('plugins/memory/'))throw const FormatException('伴侣空间只接受明确回忆适配');
      final fields=Map<String,dynamic>.from(op['fields'] as Map),schema=_schema(suffix);if(fields.keys.any((k)=>!schema.contains(k))||op['kind']=='delete'&&fields.isNotEmpty)throw const FormatException('同步业务字段无效');_noOriginal(fields);
      if(wireBytes(op).length>LocalStore.maxOperationBytes)throw const FormatException('单个操作过大');
      if(suffix=='plugins/chat/messages'&&op['kind']=='patch')_fields(fields,{'family_id','created_by','client_id','kind','body','created_at'},{});
      final old=await row(scope,collection,id);final merged=<String,dynamic>{...?old,...fields,'id':id};
      if(suffix=='family'&&(peer.remoteRole!='owner'||id!=peer.familyId))throw const FormatException('家庭资料需要主理人授权');
      if(suffix=='members'){
        if(peer.remoteRole!='owner'&&(id!=peer.remoteDeviceId||fields.keys.any((k)=>!{'display_name','avatar_emoji','avatar_url'}.contains(k))))throw const FormatException('成员权限不可由远端升级');
        if(fields['family_id']!=null&&fields['family_id']!=peer.familyId||fields['user_id']!=null&&fields['user_id']!=id)throw const FormatException('成员范围无效');
      }
      for(final key in ['avatar_url','background_url','cover_url']){if(fields.containsKey(key)&&fields[key]!=null)throw const FormatException('本机媒体引用不能伪装网络资源同步');}
      if(fields.containsKey('family_id')&&fields['family_id']!=peer.familyId)throw const FormatException('业务记录跨家庭');
      final stockCreation=(suffix=='plugins/stock/items'||suffix=='plugins/stock/buys')&&op['kind']=='patch'&&
        {'family_id','created_by','created_at','name','emoji'}.every(fields.containsKey)&&fields['created_by']==peer.remoteDeviceId;
      // 同收货/采购的确定性ID可在两台离线手机同时创建；其元数据作者按LWW，数量仍只认源事件。
      final financeNotice=suffix=='notifications'&&{'retirement','subscription'}.contains(fields['source_plugin'])&&
        {'type','title','body','icon_emoji','created_by','created_at','read_by','status','recipient_ids','source_plugin','source_id'}.every(fields.containsKey)&&fields['created_by']==peer.remoteDeviceId;
      if(fields.containsKey('created_by')&&((old==null&&fields['created_by']!=peer.remoteDeviceId)||
          (old!=null&&old['created_by']!=fields['created_by']&&!stockCreation&&!financeNotice)))throw const FormatException('作者身份不可伪造');
      if(suffix=='plugins/memory/memories'&&op['kind']=='patch'){
        if(merged['family_id']!=peer.familyId||merged['visibility']!=(scope==peer.familyId?'family':'couple'))throw const FormatException('私密或伴侣内容不能降级公开');
        if(old!=null&&fields.containsKey('visibility')&&old['visibility']!=fields['visibility'])throw const FormatException('可见范围不可修改');
      }
      if(suffix=='plugins/memory/media'&&op['kind']=='patch'){
        if(merged['memory_id'] is! String||!syncId(merged['memory_id'] as String)||!['photo','video'].contains(merged['kind'])||merged['thumbnail_sha256'] is! String||!_sha.hasMatch(merged['thumbnail_sha256'] as String)||merged['thumbnail_bytes'] is! int||(merged['thumbnail_bytes'] as int)<1||(merged['thumbnail_bytes'] as int)>LocalMediaRepository.maxThumbnailBytes)throw const FormatException('媒体同步仅允许缩略图描述');
      }
      if(suffix=='plugins/memory/media'&&fields.containsKey('sort_key')&&(fields['sort_key'] is! String||(fields['sort_key'] as String).isEmpty||(fields['sort_key'] as String).length>160||old!=null&&old['sort_key']!=null&&fields['sort_key']!=old['sort_key']))throw const FormatException('媒体排序键不可改变');
      if(old!=null&&suffix=='plugins/memory/media'&&fields.containsKey('memory_id')&&fields['memory_id']!=old['memory_id'])throw const FormatException('媒体绑定不可改变');
      if(suffix=='plugins/memory/media'){
        final localRef=await store.deviceReference(id);
        if(localRef!=null){final meta=Json.from(jsonDecode(localRef['metadata'] as String) as Map);
          if(meta['scope']!=scope||meta['memory_id']!=merged['memory_id'])throw const FormatException('同步媒体ID与本机受限引用冲突');}
      }
      final embedded=<String,dynamic>{...merged}..remove('id');
      final previous=old==null?null:(<String,dynamic>{...old}..remove('id'));
      final verified=suffix=='plugins/accounting/transactions'&&op['kind']=='patch'?await _automaticSource(peer.familyId,scope,id,embedded,previous,peer.remoteDeviceId,op['clock'] as int,pendingProofs):(initial:false,priorOrigin:false);
      validatePortableFields(familyId:peer.familyId,suffix:suffix,id:id,fields:embedded,previous:previous,actor:peer.remoteDeviceId,clock:op['clock'] as int,deletion:op['kind']=='delete',verifiedAutomaticSource:verified.initial,verifiedPriorOrigin:verified.priorOrigin);
      if(suffix=='plugins/subscription/charges'&&op['kind']=='patch')pendingProofs['$scope|$id|${op['actor']}']=op;
      if(suffix=='plugins/accounting/transactions'&&op['kind']=='patch')pendingProofs['entry|$scope|$id|${op['actor']}|${op['sequence']}']=op;
      shadow['$scope|$collection|$id']=merged;if(op['kind']=='delete')deleted['$scope|$collection|$id']=true;(grouped[scope]??=[]).add(op);
    }
    final incoming=<({String scope,String id,String hash,Uint8List bytes})>[];
    for(final raw in value['thumbs'] as List){final t=Map<String,dynamic>.from(raw as Map);_object(t,{'space','id','sha256','bytes'});final scope=t['space'],id=t['id'],hash=t['sha256'];if(scope is! String||!allowed.contains(scope)||id is! String||!syncId(id)||hash is! String||!_sha.hasMatch(hash)||t['bytes'] is! String||(t['bytes'] as String).length>132000)throw const FormatException('缩略图范围无效');
      final descriptor=await row(scope,'/families/$scope/plugins/memory/media',id);if(descriptor==null||descriptor['thumbnail_sha256']!=hash)throw const FormatException('缩略图必须绑定授权描述');
      final bytes=Uint8List.fromList(base64Url.decode(base64Url.normalize(t['bytes'] as String)));LocalMediaRepository.validateThumbnail(bytes);if(LocalMediaRepository.hash(bytes)!=hash||descriptor['thumbnail_bytes']!=bytes.length)throw const FormatException('缩略图摘要或长度无效');if(deleted['$scope|/families/$scope/plugins/memory/media|$id']!=true)incoming.add((scope:scope,id:id,hash:hash,bytes:bytes));
    }
    await _allowed(peer);for(final entry in grouped.entries){await store.merge(entry.key,entry.value);}
    // 文件失败不伪报完成；下轮state独立请求缺图，不依赖已经推进的操作游标。
    for(final t in incoming){await media.receiveThumbnail(t.scope,t.id,t.hash,t.bytes);}
  }
}
