import 'dart:convert';
import 'dart:typed_data';
import 'package:crypto/crypto.dart' as hashing;
import 'backup_models.dart' show decodeBackupJson;

/// 只读取证格式，不是LocalStore.merge或peer协议输入；没有授权receipt可携带。
class RecordEvidenceException implements Exception {
  const RecordEvidenceException(this.code);final String code;
  @override String toString()=>'恢复证据无效 ($code)';
}
enum EvidenceContentKind { document, patch, deletion }
typedef EvidenceContentValidator=void Function(String space,String suffix,String id,
  Map<String,dynamic> fields,EvidenceContentKind kind);
class RecordEvidenceSchema {
  RecordEvidenceSchema({required Map<String,Set<String>> fields,required this.validateContent})
    :fields=Map.unmodifiable({for(final e in fields.entries)e.key:Set<String>.unmodifiable(e.value)});
  /// 精确collection suffix白名单；动态评论路径由同一read tx选择器展开为精确键。
  final Map<String,Set<String>> fields;
  /// 只做字段/内嵌值结构检查，不能拿最终LWW行当historical previous或冒充source proof。
  final EvidenceContentValidator validateContent;
}
class RecordEvidenceDocument {
  RecordEvidenceDocument({required this.space,required this.collection,required this.id,
    required this.deleted,required this.revision,required this.rawData,required this.rawVersions});
  final String space,collection,id,rawData,rawVersions;final bool deleted;final int revision;
  Map<String,dynamic> get data=>_object(rawData);
  Map<String,dynamic> get versions=>_object(rawVersions);
  Map<String,dynamic> _json()=>{'space':space,'collection':collection,'id':id,'deleted':deleted,'revision':revision,
    'data_b64':_b64(rawData),'data_sha256':_sha(rawData),'versions_b64':_b64(rawVersions),'versions_sha256':_sha(rawVersions)};
}
class RecordEvidenceOperation {
  RecordEvidenceOperation({required this.space,required this.actor,required this.sequence,required this.clock,required this.rawPayload});
  final String space,actor,rawPayload;final int sequence,clock;
  Map<String,dynamic> get payload=>_object(rawPayload);
  Map<String,dynamic> _json()=>{'space':space,'actor':actor,'sequence':sequence,'clock':clock,
    'payload_b64':_b64(rawPayload),'payload_sha256':_sha(rawPayload)};
}
class RecordEvidenceIssue {
  const RecordEvidenceIssue(this.code,{this.space='',this.collection='',this.id='',this.actor='',this.fromSequence=0,this.toSequence=0});
  final String code,space,collection,id,actor;final int fromSequence,toSequence;
  Map<String,dynamic> toJson()=>{'code':code,'space':space,'collection':collection,'id':id,'actor':actor,
    'from_sequence':fromSequence,'to_sequence':toSequence};
}
class RecordEvidence {
  RecordEvidence._(this.sourceFamilyId,this.viewerId,this.scopes,this.documents,this.operations,this.omissions,this.closureIssues,this._bytes);
  static const maxBytes=64*1024*1024,maxDocuments=20000,maxOperations=100000,maxInteger=9007199254740991;
  final String sourceFamilyId,viewerId;
  final List<String> scopes,omissions;
  final List<RecordEvidenceDocument> documents;
  final List<RecordEvidenceOperation> operations;
  final List<RecordEvidenceIssue> closureIssues;
  final Uint8List _bytes;
  Uint8List get bytes=>Uint8List.fromList(_bytes).asUnmodifiableView();
  String get sha256=>hashing.sha256.convert(_bytes).toString();
  String get provenance=>'provenance_unverified';
  bool get normalImportAllowed=>false;
  bool get peerExportable=>false;
  bool get identityRestored=>false;
  bool get recordsApplied=>false;
  bool get fullDeviceComplete=>false;

  /// 原始字符串按UTF8字节保留，不重排、不伪造actor/clock/sequence；没有SQLite或网络I/O。
  factory RecordEvidence.build({required String sourceFamilyId,required String viewerId,required Iterable<String> scopes,
      required Iterable<RecordEvidenceDocument> documents,required Iterable<RecordEvidenceOperation> operations,
      required RecordEvidenceSchema schema,Iterable<String> omissions=const ['history_access_unproven','private_registry_not_exported']}) {
    if(!_id(sourceFamilyId)||sourceFamilyId.startsWith('p_')||sourceFamilyId.startsWith('c_')||!_id(viewerId))_bad('invalid_identity_labels');
    final scopeList=scopes.take(65).toList()..sort();if(scopeList.isEmpty||scopeList.length>64||scopeList.toSet().length!=scopeList.length||
      scopeList.any((s)=>!_id(s))||!scopeList.contains(sourceFamilyId))_bad('invalid_scopes');
    final docs=documents.take(maxDocuments+1).toList(),ops=operations.take(maxOperations+1).toList();
    if(docs.length>maxDocuments||ops.length>maxOperations)_bad('count_limit');
    var rawBytes=0;final documentKeys=<String>{},operationKeys=<String>{};
    for(final d in docs){
      final suffix=_location(d.space,d.collection,d.id,scopeList);if(d.revision<1||d.revision>maxInteger)_bad('invalid_revision');
      if(!documentKeys.add(_docKey(d.space,d.collection,d.id)))_bad('duplicate_document');
      final raw=_raw(d.rawData,2*1024*1024),versionsRaw=_raw(d.rawVersions,512*1024);rawBytes+=raw.length+versionsRaw.length;
      if(rawBytes>maxBytes*3~/4)_bad('size_limit');
      final data=d.data,versions=d.versions;_fields(schema,d.space,suffix,d.id,data,EvidenceContentKind.document);
      if(versions.length!=data.length||!versions.keys.toSet().containsAll(data.keys))_bad('version_field_mismatch');
      for(final v in versions.values){final version=_map(v);_keys(version,{'actor','clock'});
        if(version['actor'] is! String||!_id(version['actor'] as String)||!_positive(version['clock']))_bad('invalid_field_version');}
    }
    for(final o in ops){
      if(!scopeList.contains(o.space)||!_id(o.actor)||!_positive(o.sequence)||!_positive(o.clock))_bad('invalid_operation_index');
      if(!operationKeys.add('${o.space}|${o.actor}|${o.sequence}'))_bad('duplicate_operation');
      rawBytes+=_raw(o.rawPayload,1024*1024).length;if(rawBytes>maxBytes*3~/4)_bad('size_limit');
      final p=o.payload;_keys(p,{'space','actor','sequence','clock','collection','id','kind','fields'});
      if(p['space']!=o.space||p['actor']!=o.actor||p['sequence'] is! int||p['sequence']!=o.sequence||p['clock'] is! int||p['clock']!=o.clock||
        p['collection'] is! String||p['id'] is! String||!{'patch','delete'}.contains(p['kind']))_bad('operation_index_mismatch');
      final suffix=_location(o.space,p['collection'] as String,p['id'] as String,scopeList),fields=_map(p['fields']);
      if(p['kind']=='delete'&&fields.isNotEmpty)_bad('delete_has_fields');
      _fields(schema,o.space,suffix,p['id'] as String,fields,p['kind']=='delete'?EvidenceContentKind.deletion:EvidenceContentKind.patch);
    }
    docs.sort((a,b)=>_docKey(a.space,a.collection,a.id).compareTo(_docKey(b.space,b.collection,b.id)));
    ops.sort((a,b){var n=a.space.compareTo(b.space);if(n==0)n=a.actor.compareTo(b.actor);if(n==0)n=a.sequence.compareTo(b.sequence);return n;});
    final omitted=omissions.take(17).toList()..sort();
    if(omitted.length>16||omitted.toSet().length!=omitted.length||omitted.any((s)=>!const {'history_access_unproven','private_registry_not_exported','schema_not_supported','source_operation_limit','source_document_limit','historical_selection_incomplete'}.contains(s)))_bad('invalid_omission');
    final issues=_closure(sourceFamilyId,docs,ops);final counts={'documents':docs.length,'tombstones':docs.where((d)=>d.deleted).length,
      'operations':ops.length,'member_documents':docs.where((d)=>d.space==sourceFamilyId&&d.collection=='/families/$sourceFamilyId/members').length};
    final value={'version':2,'kind':'wo_record_evidence','source_family_id':sourceFamilyId,'viewer_id':viewerId,'scopes':scopeList,
      'provenance':'provenance_unverified','normal_import_allowed':false,'peer_exportable':false,'identity_restored':false,'records_applied':false,
      'authorization_receipts':<Object>[],'private_device_revocations':'not_exported',
      'documents':docs.map((d)=>d._json()).toList(),'operations':ops.map((o)=>o._json()).toList(),'omissions':omitted,
      'counts':counts,'closure_issues':issues.map((i)=>i.toJson()).toList()};
    final encoded=Uint8List.fromList(utf8.encode(_canonical(value)));if(encoded.length>maxBytes)_bad('size_limit');
    return RecordEvidence._(sourceFamilyId,viewerId,List.unmodifiable(scopeList),List.unmodifiable(docs),List.unmodifiable(ops),
      List.unmodifiable(omitted),List.unmodifiable(issues),encoded);
  }

  /// 只验证结构/摘要/闭包标记；成功不授予旧成员rights或证明原操作历史授权。
  factory RecordEvidence.decode(Uint8List bytes,{required String expectedFamily,required RecordEvidenceSchema schema}) {
    if(bytes.length>maxBytes)_bad('size_limit');final root=_object(utf8.decode(bytes,allowMalformed:false));
    _keys(root,{'version','kind','source_family_id','viewer_id','scopes','provenance','normal_import_allowed','peer_exportable','identity_restored',
      'records_applied','authorization_receipts','private_device_revocations','documents','operations','omissions','counts','closure_issues'});
    if(root['version'] is! int||root['version']!=2||root['kind']!='wo_record_evidence'||root['source_family_id']!=expectedFamily||root['viewer_id'] is! String||
      root['provenance']!='provenance_unverified'||root['normal_import_allowed']!=false||root['peer_exportable']!=false||root['identity_restored']!=false||
      root['records_applied']!=false||root['private_device_revocations']!='not_exported'||root['authorization_receipts'] is! List||(root['authorization_receipts'] as List).isNotEmpty)_bad('unsafe_or_foreign_evidence');
    final docs=<RecordEvidenceDocument>[],ops=<RecordEvidenceOperation>[];
    final documents=_list(root['documents'],maxDocuments),operations=_list(root['operations'],maxOperations);
    for(final value in documents){final d=_map(value);_keys(d,{'space','collection','id','deleted','revision','data_b64','data_sha256','versions_b64','versions_sha256'});
      if(d['deleted'] is! bool||d['revision'] is! int)_bad('invalid_document');
      docs.add(RecordEvidenceDocument(space:_text(d['space']),collection:_text(d['collection']),id:_text(d['id']),deleted:d['deleted'] as bool,
        revision:d['revision'] as int,rawData:_decodeRaw(d['data_b64'],d['data_sha256'],2*1024*1024),rawVersions:_decodeRaw(d['versions_b64'],d['versions_sha256'],512*1024)));
    }
    for(final value in operations){final o=_map(value);_keys(o,{'space','actor','sequence','clock','payload_b64','payload_sha256'});
      if(o['sequence'] is! int||o['clock'] is! int)_bad('invalid_operation');
      ops.add(RecordEvidenceOperation(space:_text(o['space']),actor:_text(o['actor']),sequence:o['sequence'] as int,clock:o['clock'] as int,
        rawPayload:_decodeRaw(o['payload_b64'],o['payload_sha256'],1024*1024)));
    }
    final evidence=RecordEvidence.build(sourceFamilyId:expectedFamily,viewerId:_text(root['viewer_id']),scopes:_list(root['scopes'],64).map(_text),
      documents:docs,operations:ops,schema:schema,omissions:_list(root['omissions'],16).map(_text));
    final normalized=_object(utf8.decode(evidence._bytes));
    if(_canonical(root['counts'])!=_canonical(normalized['counts'])||_canonical(root['closure_issues'])!=_canonical(normalized['closure_issues']))_bad('closure_or_count_mismatch');
    // 保留接收到的外层字节，重备份不改source_family或原始证据字节。
    return RecordEvidence._(evidence.sourceFamilyId,evidence.viewerId,evidence.scopes,evidence.documents,evidence.operations,evidence.omissions,evidence.closureIssues,Uint8List.fromList(bytes));
  }
}

List<RecordEvidenceIssue> _closure(String family,List<RecordEvidenceDocument> docs,List<RecordEvidenceOperation> ops){
  final unique=<String,RecordEvidenceIssue>{};var truncated=false;
  void issue(RecordEvidenceIssue value){final key=_canonical(value.toJson());if(unique.containsKey(key))return;if(unique.length>=8191){truncated=true;return;}unique[key]=value;}
  issue(const RecordEvidenceIssue('authorization_receipts_unavailable'));issue(const RecordEvidenceIssue('private_device_revocations_unavailable'));
  final byActor=<String,List<int>>{},origins=<String,int>{},deletions=<String>{};
  String originKey(String target,String actor,int clock,String field,Object? value)=>
    _canonical([target,actor,clock,field,hashing.sha256.convert(utf8.encode(_canonical(value))).toString()]);
  final docKeys=docs.map((d)=>_docKey(d.space,d.collection,d.id)).toSet();
  final members=docs.where((d)=>d.space==family&&d.collection=='/families/$family/members').map((d)=>d.id).toSet();
  for(final o in ops){final p=o.payload,key=_docKey(o.space,p['collection'] as String,p['id'] as String);(byActor['${o.space}|${o.actor}']??=[]).add(o.sequence);
    if(p['kind']=='delete'){deletions.add(key);}else{for(final field in (p['fields'] as Map).entries){
      final origin=originKey(key,o.actor,o.clock,field.key as String,field.value);origins[origin]=(origins[origin]??0)+1;
    }}
    if(!docKeys.contains(key))issue(RecordEvidenceIssue('operation_target_missing',space:o.space,collection:p['collection'] as String,id:p['id'] as String,actor:o.actor));
    if(!members.contains(o.actor))issue(RecordEvidenceIssue('operation_actor_not_in_member_evidence',space:o.space,actor:o.actor));
  }
  for(final d in docs){final target=_docKey(d.space,d.collection,d.id);
    if(d.deleted&&!deletions.contains(target))issue(RecordEvidenceIssue('missing_delete_operation',space:d.space,collection:d.collection,id:d.id));
    final data=d.data,versions=d.versions;
    for(final field in versions.keys){final v=_map(versions[field]);final matches=origins[originKey(target,v['actor'] as String,v['clock'] as int,field,data[field])]??0;
      if(matches!=1)issue(RecordEvidenceIssue(matches==0?'missing_version_origin':'ambiguous_version_origin',space:d.space,collection:d.collection,id:d.id,actor:v['actor'] as String));
    }
  }
  for(final entry in byActor.entries){final split=entry.key.split('|'),sequences=entry.value..sort();var expected=1;
    for(final sequence in sequences){if(sequence>expected)issue(RecordEvidenceIssue('operation_sequence_gap',space:split[0],actor:split[1],fromSequence:expected,toSequence:sequence-1));expected=sequence+1;}
  }
  if(truncated){final value=const RecordEvidenceIssue('closure_issue_limit');unique[_canonical(value.toJson())]=value;}
  final keys=unique.keys.toList()..sort();return [for(final key in keys)unique[key]!];
}
void _fields(RecordEvidenceSchema schema,String space,String suffix,String id,Map<String,dynamic> fields,EvidenceContentKind kind){
  final allowed=schema.fields[suffix];if(allowed==null||fields.length>256||fields.keys.any((key)=>!allowed.contains(key)))_bad('unknown_schema_field');
  _noNative(fields);schema.validateContent(space,suffix,id,Map.unmodifiable(fields),kind);
}
void _noNative(Object? value,[int depth=0]){
  if(depth>10)_bad('content_depth');
  if(value is Map){for(final e in value.entries){if(e.key is! String||const {'locator','bookmark','asset_id','original_uri','original_bytes','original_handle','source_uri','file_path',
      'api_key','access_token','password','secret','token','secret_ref','credential_ref'}.contains(e.key))_bad('native_or_secret_field');_noNative(e.value,depth+1);}}
  else if(value is List){if(value.length>4096)_bad('content_array_limit');for(final item in value){_noNative(item,depth+1);}}
  else if(value is String){if(RegExp(r'(?:content|file|ph|assets-library)://',caseSensitive:false).hasMatch(value))_bad('native_uri');}
  else if(value is double&&!value.isFinite)_bad('nonfinite_content');
}
String _location(String space,String collection,String id,List<String> scopes){
  if(!_id(space)||!scopes.contains(space)||!_id(id)||!collection.startsWith('/families/$space/'))_bad('invalid_location');
  final suffix=collection.substring('/families/$space/'.length);if(suffix.isEmpty||suffix.split('/').any((p)=>!_id(p)))_bad('invalid_location');return suffix;
}
String _docKey(String space,String collection,String id)=>'$space|$collection|$id';
bool _id(String value){final m=RegExp(r'^[A-Za-z0-9_-]{1,100}$').firstMatch(value);return m!=null&&m.end==value.length;}
bool _positive(Object? value)=>value is int&&value>0&&value<=RecordEvidence.maxInteger;
Never _bad(String code)=>throw RecordEvidenceException(code);
String _text(Object? value){if(value is! String)_bad('invalid_type');return value as String;}
Map<String,dynamic> _map(Object? value){if(value is! Map<String,dynamic>)_bad('invalid_object');return value as Map<String,dynamic>;}
Map<String,dynamic> _object(String value){try{return _map(decodeBackupJson(value));}on RecordEvidenceException{rethrow;}catch(_){_bad('invalid_json');}}
List _list(Object? value,int max){if(value is! List||value.length>max)_bad('invalid_list');return value as List;}
void _keys(Map value,Set<String> expected){if(value.length!=expected.length||!value.keys.toSet().containsAll(expected))_bad('invalid_keys');}
Uint8List _raw(String value,int max){if(value.length>max)_bad('raw_byte_limit');final bytes=Uint8List.fromList(utf8.encode(value));if(bytes.length>max||utf8.decode(bytes,allowMalformed:false)!=value)_bad('raw_byte_limit');return bytes;}
String _sha(String value)=>hashing.sha256.convert(utf8.encode(value)).toString();
String _b64(String value)=>base64Url.encode(utf8.encode(value)).replaceAll('=','');
String _decodeRaw(Object? encoded,Object? digest,int max){
  final text=_text(encoded),hash=_text(digest);if(!RegExp(r'^[a-f0-9]{64}$').hasMatch(hash)||text.length>(max*4+2)~/3)_bad('invalid_raw_digest');
  try{final bytes=base64Url.decode(base64Url.normalize(text));if(bytes.length>max||base64Url.encode(bytes).replaceAll('=','')!=text||hashing.sha256.convert(bytes).toString()!=hash)_bad('raw_digest_mismatch');return utf8.decode(bytes,allowMalformed:false);}
  on RecordEvidenceException{rethrow;}catch(_){_bad('invalid_raw_bytes');}
}
Object? _ordered(Object? value){if(value is Map){final keys=value.keys.cast<String>().toList()..sort();return {for(final key in keys)key:_ordered(value[key])};}if(value is List)return value.map(_ordered).toList();return value;}
String _canonical(Object? value)=>jsonEncode(_ordered(value));
