import 'dart:convert';
import 'dart:typed_data';
import '../attachments/ordinary_attachment_store.dart';
import 'package:sqflite/sqflite.dart';
import '../backup/backup_models.dart';
import '../local_store.dart';
import '../plugins/chat_routes.dart';
import '../plugins/pet_routes.dart';
import 'peer_registry.dart';
import 'strict_json.dart';

typedef AttachmentDocumentLookup=Future<Json?> Function(String space,String collection,String id);

/// 普通附件专用传输；绝不调用memory/travel/original/owned接口。
abstract interface class OrdinaryAttachmentTransferStrategy {
  bool get attachmentTransferEnabled;
  Future<Json> attachmentRequest(PeerLink peer);
  Future<Json> attachmentReply(PeerLink peer,Json request);
  Future<bool> receiveAttachmentReply(PeerLink peer,Json reply);
}

class OrdinaryAttachmentSyncAdapter {
  OrdinaryAttachmentSyncAdapter(this.store,this.registry,this.repository);
  final LocalStore store;final PeerRegistry registry;
  final Future<OrdinaryAttachmentStore> Function() repository;
  final _cursor=<String,int>{};
  final _requested=<String,Map<String,({AttachmentDescriptor descriptor,int offset})>>{};
  static const collections={'chat':'plugins/chat/attachments','pet':'plugins/pet/attachments'};
  static bool isCollection(String suffix)=>collections.values.contains(suffix);
  static Never _bad()=>throw const FormatException('普通附件范围、父记录或分块无效');
  static void _keys(Json value,Set<String> keys){if(value.length!=keys.length||!keys.every(value.containsKey))_bad();}
  static Json _data(Json value)=>{for(final e in value.entries)if(e.key!='id'&&e.key!='_deleted')e.key:e.value};
  Future<Json?> lookup(String space,String collection,String id)async{
    final rows=await store.db.query('documents',columns:['data','deleted'],where:'space=? AND collection=? AND id=?',whereArgs:[space,collection,id]);
    if(rows.isEmpty)return null;return {'id':id,...Json.from(decodeStrictJson(rows.single['data'] as String) as Map),'_deleted':rows.single['deleted']==1};
  }
  Future<Json> _member(String fid,String actor,{AttachmentDocumentLookup? read})async{
    final member=await (read??lookup)(fid,'/families/$fid/members',actor);
    if(member==null||member['_deleted']==true||member['family_id']!=fid||member['user_id']!=actor||member['status']!='active'||!{'owner','member'}.contains(member['role']))_bad();
    return member;
  }
  Future<void> _peer(PeerLink peer)async{
    if(!(await registry.scopes(peer)).contains(peer.familyId))_bad();
    await _member(peer.familyId,store.deviceId);await _member(peer.familyId,peer.remoteDeviceId);
  }
  Future<void> _collision(AttachmentDescriptor d)async{
    final rows=await store.db.query('documents',columns:['space','collection','data'],where:'id=? AND (collection LIKE ? OR collection LIKE ? OR collection LIKE ?)',
      whereArgs:[d.id,'/families/%/plugins/%/attachments','/families/%/plugins/memory/media','/families/%/plugins/travel/media']);
    for(final row in rows){if(row['space']!=d.familyId||row['collection']!='/families/${d.familyId}/${collections[d.plugin]}')_bad();
      final other=AttachmentDescriptor.fromJson({'id':d.id,...Json.from(decodeStrictJson(row['data'] as String) as Map)});if(!d.same(other))_bad();}
  }
  Future<Json> _parent(AttachmentDescriptor d,AttachmentDocumentLookup read)async{
    final path=d.plugin=='chat'?'plugins/chat/messages':'plugins/pet/records';
    final parent=await read(d.familyId,'/families/${d.familyId}/$path',d.parentId);if(parent==null)_bad();
    if(parent['family_id']!=d.familyId||parent['created_by'] is! String)_bad();
    if(d.plugin=='chat'){
      if(parent['attachment_id']!=d.id||parent['created_by']!=d.authorDeviceId||parent['kind']!=d.kind||parent['body']!='')_bad();
    }else{
      final pet=await read(d.familyId,'/families/${d.familyId}/pets',parent['pet_id'] as String);
      if(pet==null||pet['_deleted']==true||pet['family_id']!=d.familyId)_bad();
    }
    return parent;
  }
  /// 元数据每个原操作仍过actor/序号与不可变字段验证，不替代peer来源证明。
  Future<void> validateOp(Json op,{required AttachmentDocumentLookup read,Json? previous})async{
    final scope=op['space'] as String,collection=op['collection'] as String,id=op['id'] as String,actor=op['actor'] as String;
    if(scope.startsWith('p_')||scope.startsWith('c_'))_bad();
    final prefix='/families/$scope/';if(!collection.startsWith(prefix))_bad();final suffix=collection.substring(prefix.length);
    if(suffix=='plugins/pet/records'){
      final member=await _member(scope,actor,read:read),fields={...?previous,...Json.from(op['fields'] as Map)};
      PetRoutes.validateRecordSync(_data(fields),familyId:scope,id:id,actor:actor,previous:previous==null?null:_data(previous),owner:member['role']=='owner',deletion:op['kind']=='delete');return;
    }
    if(!isCollection(suffix))return;
    final fields=Json.from(op['fields'] as Map),candidate={...?previous,...fields};
    final d=AttachmentDescriptor.fromJson({'id':id,..._data(candidate)});
    if(d.familyId!=scope||collections[d.plugin]!=suffix)_bad();await _collision(d);
    if(previous!=null&&!d.same(AttachmentDescriptor.fromJson({'id':id,..._data(previous)})))_bad();
    final parent=await _parent(d,read),member=await _member(scope,actor,read:read);
    if(op['kind']=='patch'){
      if(fields.length!=AttachmentDescriptor.syncFields.length||!AttachmentDescriptor.syncFields.every(fields.containsKey)||actor!=d.authorDeviceId)_bad();
      if(d.plugin=='pet'&&parent['created_by']!=actor&&member['role']!='owner')_bad();
    }else if(op['kind']=='delete'){
      if(previous==null||fields.isNotEmpty||d.plugin=='chat'&&parent['created_by']!=actor||d.plugin=='pet'&&parent['created_by']!=actor&&member['role']!='owner')_bad();
    }else{_bad();}
  }
  Future<AttachmentDescriptor?> _active(String fid,String plugin,String id)async{
    final row=await lookup(fid,'/families/$fid/${collections[plugin]}',id);if(row==null||row['_deleted']==true)return null;
    final d=AttachmentDescriptor.fromJson({'id':id,..._data(row)});if(d.familyId!=fid||d.plugin!=plugin)_bad();
    await _collision(d);final parent=await _parent(d,lookup);if(parent['_deleted']==true)return null;return d;
  }
  Future<List<AttachmentDescriptor>> active(String fid)async{
    await _member(fid,store.deviceId);final result=<AttachmentDescriptor>[];
    for(final plugin in collections.keys){
      final rows=await store.list(fid,'/families/$fid/${collections[plugin]}');
      for(final row in rows){final d=await _active(fid,plugin,row['id'] as String);if(d!=null)result.add(d);}
    }
    result.sort((a,b)=>a.id.compareTo(b.id));return result;
  }
  Future<Json> request(PeerLink peer)async{
    await _peer(peer);final candidates=await active(peer.familyId),requests=<Json>[];
    final sent=<String,({AttachmentDescriptor descriptor,int offset})>{};
    if(candidates.isNotEmpty){final repo=await repository();var cursor=(_cursor[peer.id]??0)%candidates.length,examined=0,probes=0;
      while(examined<64&&examined<candidates.length&&requests.length<2){
        final d=candidates[cursor];cursor=(cursor+1)%candidates.length;examined++;
        var asset=await repo.get(d.binding,d.id);
        if(asset?.available==true){if(probes++>=2)continue;try{await repo.verifiedFile(d.binding,d.id);continue;}on AttachmentException{/*明确重试损坏副本。*/}}
        asset=await repo.beginReceive(d);final offset=asset.offset;
        if(offset>=d.size)continue;
        requests.add({'plugin':d.plugin,'id':d.id,'sha256':d.sha256,'offset':offset,'length':(d.size-offset).clamp(1,ordinaryAttachmentChunkBytes).toInt()});
        sent[d.id]=(descriptor:d,offset:offset);
      }
      _cursor[peer.id]=cursor;
    }
    await _peer(peer);_requested[peer.id]=sent;
    return {'t':'ordinary_request','version':1,'family_id':peer.familyId,'requests':requests};
  }
  Future<Json> reply(PeerLink peer,Json request)async{
    _keys(request,{'t','version','family_id','requests'});
    if(request['t']!='ordinary_request'||request['version'] is! int||request['version']!=1||request['family_id']!=peer.familyId||request['requests'] is! List||(request['requests'] as List).length>2)_bad();
    await _peer(peer);final chunks=<Json>[],seen=<String>{};var more=false;
    for(final raw in request['requests'] as List){
      final item=Json.from(raw as Map);_keys(item,{'plugin','id','sha256','offset','length'});
      if(!collections.containsKey(item['plugin'])||item['id'] is! String||!AttachmentDescriptor.validId(item['id'] as String)||!seen.add(item['id'] as String)||item['offset'] is! int||item['length'] is! int)_bad();
      final d=await _active(peer.familyId,item['plugin'] as String,item['id'] as String);
      if(d==null)continue;
      final offset=item['offset'] as int,length=item['length'] as int;
      if(item['sha256']!=d.sha256||offset<0||length<1||length>ordinaryAttachmentChunkBytes||offset+length>d.size)_bad();
      final repo=await repository(),asset=await repo.get(d.binding,d.id);if(asset?.available!=true)continue;
      final bytes=await repo.read(d.binding,d.id,offset:offset,maxBytes:length);
      if(bytes.length!=length)_bad();await _peer(peer);if(await _active(peer.familyId,d.plugin,d.id)==null)continue;
      chunks.add({'plugin':d.plugin,'id':d.id,'sha256':d.sha256,'offset':offset,'bytes':base64Url.encode(bytes).replaceAll('=','')});
      more=more||offset+length<d.size;
    }
    await _peer(peer);return {'t':'ordinary_chunks','version':1,'family_id':peer.familyId,'chunks':chunks,'more':more};
  }
  Future<bool> receive(PeerLink peer,Json reply)async{
    _keys(reply,{'t','version','family_id','chunks','more'});
    if(reply['t']!='ordinary_chunks'||reply['version'] is! int||reply['version']!=1||reply['family_id']!=peer.familyId||reply['chunks'] is! List||(reply['chunks'] as List).length>2||reply['more'] is! bool)_bad();
    await _peer(peer);final expected=_requested.remove(peer.id)??{},seen=<String>{};var changed=false;
    for(final raw in reply['chunks'] as List){
      final item=Json.from(raw as Map);_keys(item,{'plugin','id','sha256','offset','bytes'});final id=item['id'];
      if(id is! String||!seen.add(id)||!expected.containsKey(id)||item['bytes'] is! String||(item['bytes'] as String).length>350000)_bad();
      final wanted=expected[id]!,d=await _active(peer.familyId,wanted.descriptor.plugin,id);
      if(d==null)continue;
      if(!d.same(wanted.descriptor)||item['plugin']!=d.plugin||item['sha256']!=d.sha256||item['offset']!=wanted.offset)_bad();
      final bytes=Uint8List.fromList(base64Url.decode(base64Url.normalize(item['bytes'] as String)));
      if(base64Url.encode(bytes).replaceAll('=','')!=item['bytes']||bytes.length!=(d.size-wanted.offset).clamp(1,ordinaryAttachmentChunkBytes).toInt())_bad();
      await _peer(peer);if(await _active(peer.familyId,d.plugin,id)==null)continue;
      final repo=await repository();await repo.beginReceive(d);await repo.receiveChunk(d,offset:wanted.offset,bytes:bytes);changed=true;
      // 撤回在写入期间到达时，保留本地不可见副本但不继续发布UI读取能力。
      await _peer(peer);await _active(peer.familyId,d.plugin,id);
    }
    return changed;
  }
  /// 只增加合并后的同事务约束；不跳过任何原操作/作者/序号验证。
  Future<void> validateMerged(DatabaseExecutor tx,String fid,List<Json> operations)async{
    final affected=<String>{};
    for(final op in operations){
      final collection=op['collection'] as String;
      if(!collection.endsWith('/plugins/chat/attachments')&&!collection.endsWith('/plugins/pet/attachments'))continue;
      final id=op['id'] as String;
      final collisions=await tx.query('documents',columns:['space','collection'],where:'id=? AND (collection LIKE ? OR collection LIKE ? OR collection LIKE ?)',
        whereArgs:[id,'/families/%/plugins/%/attachments','/families/%/plugins/memory/media','/families/%/plugins/travel/media']);
      if(collisions.any((r)=>r['space']!=fid||r['collection']!=collection))_bad();
      if(collection.endsWith('/plugins/pet/attachments')){
        final rows=await tx.query('documents',columns:['data'],where:'space=? AND collection=? AND id=?',whereArgs:[fid,collection,id]);
        if(rows.isNotEmpty){final d=Json.from(decodeStrictJson(rows.single['data'] as String) as Map);if(d['parent_id'] is String)affected.add(d['parent_id'] as String);}
      }
    }
    if(affected.isEmpty)return;
    final all=await tx.query('documents',columns:['data'],where:'space=? AND collection=? AND deleted=0',whereArgs:[fid,'/families/$fid/plugins/pet/attachments']);
    final counts=<String,int>{};for(final row in all){final d=Json.from(decodeStrictJson(row['data'] as String) as Map);final parent=d['parent_id'];if(parent is String&&affected.contains(parent))counts[parent]=(counts[parent]??0)+1;}
    for(final e in counts.entries){
      final parent=await tx.query('documents',columns:['deleted'],where:'space=? AND collection=? AND id=?',whereArgs:[fid,'/families/$fid/plugins/pet/records',e.key]);
      if(e.value>10&&parent.isNotEmpty&&parent.single['deleted']==0)throw const FormatException('同一宠物记录附件并发超过10件，需明确删除冲突附件后重试');
    }
  }
  Future<List<BackupSource>> backupSources(String fid)async{
    final descriptors=await active(fid);if(descriptors.isEmpty)return [];
    final repo=await repository(),sources=<BackupSource>[];
    for(final d in descriptors){await _member(fid,store.deviceId);if(await _active(fid,d.plugin,d.id)==null)continue;
      final asset=await repo.get(d.binding,d.id);
      final source=asset==null?_MissingOrdinarySource(d.id):await repo.frozenBackupSource(d.binding,d.id,entryId:d.id);
      sources.add(_AuthorizedOrdinarySource(this,d,source));}
    return sources;
  }
}

class _MissingOrdinarySource extends BackupSource {
  _MissingOrdinarySource(String id):entry=BackupEntry(id:id,kind:'file',size:0,sha256:'',sourceExact:false,missing:'source_unavailable');
  @override final BackupEntry entry;
  @override BackupPrivacy get privacy=>BackupPrivacy.restricted;
  @override Future<Stream<List<int>>> openRange(int offset,int length)=>throw const BackupException('source_unavailable');
}
class _AuthorizedOrdinarySource extends BackupSource {
  _AuthorizedOrdinarySource(this.adapter,this.descriptor,this.delegate);
  final OrdinaryAttachmentSyncAdapter adapter;final AttachmentDescriptor descriptor;final BackupSource delegate;
  @override BackupEntry get entry=>delegate.entry;
  @override BackupPrivacy get privacy=>BackupPrivacy.restricted;
  Future<void> _check()async{await adapter._member(descriptor.familyId,adapter.store.deviceId);final current=await adapter._active(descriptor.familyId,descriptor.plugin,descriptor.id);if(current==null||!current.same(descriptor))throw const BackupException('attachment_authorization_changed');}
  @override Future<Stream<List<int>>> openRange(int offset,int length)async{
    await _check();final input=await delegate.openRange(offset,length);
    Stream<List<int>> checked()async*{await for(final chunk in input){await _check();yield chunk;}await _check();}
    return checked();
  }
}
