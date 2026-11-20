import 'dart:convert';
import 'dart:typed_data';
import 'package:crypto/crypto.dart' as hashes;
import '../transport/native_local.dart';
import 'backup_models.dart';
import 'backup_transport.dart';

/// 接收器只能指向新建的应用私有隔离缓存；不能是业务数据库或用户选的已有目录。
/// append 的成功必须代表完整块落盘并记录 SHA，offset 必须从复验后的日志恢复。
abstract class BackupReceiveStore {
  Future<void> bind(BackupManifest manifest);
  Future<int> verifiedOffset(BackupEntry entry);
  Future<void> append(BackupEntry entry,int offset,Uint8List bytes,String chunkSha256);
  Future<void> finish(BackupManifest manifest);
}

class MobileBackupClient {
  MobileBackupClient({required this.transport,required this.crypto,required this.computer}) {
    if(transport.origin!=computer.origin||transport.pin!=computer.pin)throw const BackupException('pair_transport_mismatch');
  }
  final BackupTransport transport;final LocalCrypto crypto;final PairedComputer computer;
  static Future<PairedComputer> pair({required BackupTransport transport,required LocalCrypto crypto,
      required String oneTimeCode,required String familyId,required String deviceId}) async {
    validateComputerOrigin(transport.origin,transport.pin);
    if(!RegExp(r'^[a-f0-9]{64}$').hasMatch(oneTimeCode)||!validBackupId(familyId)||!validBackupId(deviceId)) {
      throw const BackupException('invalid_pair_request');
    }
    // 任何配对网络异常都可能已消费一次码，禁止自动重试或猜测 token。
    BackupReply reply;
    try {reply=await transport.request('POST','/v1/pair',headers:{'Content-Type':'application/json'},
      body:_jsonBytes({'code':oneTimeCode,'family':familyId,'device':deviceId}));}
    catch(_){throw const BackupException('pair_outcome_unknown');}
    _success(reply);
    final j=backupObject(_decode(reply.body));
    if(j.length!=3||j['family']!=familyId||j['device']!=deviceId||j['token'] is! String||
        !RegExp(r'^[a-f0-9]{64}$').hasMatch(j['token'] as String))throw const BackupException('pair_response_mismatch');
    final random=await crypto.random(16);
    if(random.length!=16)throw const BackupException('invalid_random');
    final ref='wo.backup.token.${backupHex(random)}';
    final token=Uint8List.fromList(utf8.encode(j['token'] as String));
    try {await crypto.putSecret(ref,token);} finally {token.fillRange(0,token.length,0);}
    return PairedComputer(origin:transport.origin,pin:transport.pin,familyId:familyId,deviceId:deviceId,tokenRef:ref);
  }
  Future<void> forgetLocally() async {transport.close();await crypto.deleteSecret(computer.tokenRef);}
  Future<BackupReply> _request(String method,String path,{Uint8List? body,Map<String,String> headers=const {},int max=2*1024*1024}) async {
    final secret=await crypto.getSecret(computer.tokenRef);
    if(secret==null)throw const BackupException('pair_secret_unavailable');
    try {
      final token=ascii.decode(secret,allowInvalid:false);
      if(!RegExp(r'^[a-f0-9]{64}$').hasMatch(token))throw const BackupException('invalid_pair_secret');
      final response=await transport.request(method,path,body:body,maxResponseBytes:max,
        headers:{'Authorization':'Bearer $token',if(body!=null)'Content-Type':'application/json',...headers});
      _success(response);return response;
    } on BackupException {rethrow;} catch(_){throw const BackupException('backup_request_failed',retryable:true);}
    finally {secret.fillRange(0,secret.length,0);}
  }
  Future<List<BackupStatus>> list() async {
    final reply=await _request('GET','/v1/backups');final j=_decode(reply.body);
    if(j is! List||j.length>256)throw const BackupException('invalid_backup_list');
    final result=j.map((e)=>BackupStatus.fromJson(backupObject(e))).toList(growable:false);
    if(result.any((e)=>e.familyId!=computer.familyId))throw const BackupException('cross_family_response');
    return List.unmodifiable(result);
  }
  Future<BackupStatus> status(String backupId) async {
    _id(backupId);final r=await _request('GET','/v1/backups/$backupId');
    final st=BackupStatus.fromJson(backupObject(_decode(r.body)));
    if(st.familyId!=computer.familyId||st.backupId!=backupId)throw const BackupException('cross_family_response');return st;
  }
  Future<BackupManifest> manifest(String backupId) async {
    _id(backupId);final r=await _request('GET','/v1/backups/$backupId/manifest');
    final m=BackupManifest.fromJson(backupObject(_decode(r.body)));
    if(m.familyId!=computer.familyId||m.backupId!=backupId)throw const BackupException('cross_family_response');return m;
  }
  /// 失败后显式再次调用：重发同一不可变清单并读取已确认 offset；不自动重试 POST 或块。
  Future<BackupStatus> upload(BackupManifest manifest,Iterable<BackupSource> sources) async {
    _scope(manifest);
    final byId=<String,BackupSource>{};
    for(final source in sources) {
      if(byId.containsKey(source.entry.id))throw const BackupException('duplicate_source');
      byId[source.entry.id]=source;
    }
    for(final e in manifest.entries) {
      final s=byId[e.id];
      if(s==null||jsonEncode(e.toJson())!=jsonEncode(s.entry.toJson()))throw const BackupException('source_manifest_mismatch');
      if((s.privacy==BackupPrivacy.restricted)!=(e.kind=='sealed'))throw const BackupException('restricted_requires_sealed');
      if(e.missing.isEmpty)await _verifySource(s);
    }
    if(byId.length!=manifest.entries.length)throw const BackupException('undeclared_source');
    await _request('POST','/v1/backups',body:_jsonBytes(manifest.toJson()));
    final st=await status(manifest.backupId);st.check(manifest);
    final offsets={for(final e in st.entries)e.id:e.offset};
    for(final e in manifest.entries) {
      if(e.missing.isNotEmpty)continue;
      var offset=offsets[e.id]!;
      while(offset<e.size) {
        final length=(e.size-offset).clamp(0,backupChunkBytes).toInt();
        final bytes=await _readExact(await byId[e.id]!.openRange(offset,length),length);
        final sha=await crypto.hash(bytes);
        if(sha.length!=32)throw const BackupException('invalid_hash');
        final answer=await _request('PUT','/v1/backups/${manifest.backupId}/entries/${e.id}?offset=$offset',body:bytes,
          headers:{'Content-Type':'application/octet-stream','X-Chunk-SHA256':backupHex(sha)},max:1024);
        final j=backupObject(_decode(answer.body));
        if(j.length!=1||j['offset']!=offset+length)throw const BackupException('invalid_acknowledgement');
        offset+=length;
      }
    }
    final done=await _request('POST','/v1/backups/${manifest.backupId}/finalize');
    final result=BackupStatus.fromJson(backupObject(_decode(done.body)));result.check(manifest);
    if(result.verifiedAt.isEmpty||result.entries.any((e)=>e.missing.isEmpty&&e.offset!=e.size))throw const BackupException('finalization_not_verified');
    return result;
  }
  /// 只下载到隔离缓存。首次失败的部分 Range 不会传给接收器；已提交块可复验后续传。
  Future<void> fetch(BackupManifest expected,BackupReceiveStore destination) async {
    _scope(expected);final remote=await manifest(expected.backupId);
    if(remote.canonicalJson!=expected.canonicalJson)throw const BackupException('immutable_manifest_mismatch');
    await destination.bind(expected);
    for(final e in expected.entries) {
      if(e.missing.isNotEmpty)continue;
      var offset=await destination.verifiedOffset(e);
      if(offset<0||offset>e.size)throw const BackupException('invalid_local_offset');
      while(offset<e.size) {
        final length=(e.size-offset).clamp(0,backupChunkBytes).toInt();final end=offset+length-1;
        final reply=await _request('GET','/v1/backups/${expected.backupId}/files/${e.id}',max:length,
          headers:{'Range':'bytes=$offset-$end','If-Range':'"${e.sha256}"'});
        if(reply.status!=206||reply.headers['content-range']!='bytes $offset-$end/${e.size}'||
           reply.headers['etag']!='"${e.sha256}"'||reply.headers['content-length']!='$length'||reply.body.length!=length) {
          throw const BackupException('range_or_digest_mismatch');
        }
        final sha=await crypto.hash(reply.body);if(sha.length!=32)throw const BackupException('invalid_hash');
        await destination.append(e,offset,reply.body,backupHex(sha));offset+=length;
      }
    }
    await destination.finish(expected);
  }
  void _scope(BackupManifest m){if(m.familyId!=computer.familyId)throw const BackupException('cross_family_manifest');}
  void _id(String id){if(!validBackupId(id))throw const BackupException('invalid_backup_id');}
}

Future<void> _verifySource(BackupSource source) async {
  final e=source.entry;var count=0;
  final digest=await hashes.sha256.bind((await source.openRange(0,e.size)).map((chunk){
    count+=chunk.length;if(count>e.size)throw const BackupException('source_size_changed');return chunk;
  })).first;
  if(count!=e.size||digest.toString()!=e.sha256)throw const BackupException('source_changed');
}
Future<Uint8List> _readExact(Stream<List<int>> stream,int size) async {
  final builder=BytesBuilder(copy:false);var count=0;
  await for(final chunk in stream){count+=chunk.length;if(count>size)throw const BackupException('source_range_changed');builder.add(chunk);}
  if(count!=size)throw const BackupException('source_range_changed');return builder.takeBytes();
}
Uint8List _jsonBytes(Object value)=>Uint8List.fromList(utf8.encode(jsonEncode(value)));
Object? _decode(Uint8List bytes){try{return decodeBackupJson(utf8.decode(bytes,allowMalformed:false));}catch(_){throw const BackupException('invalid_response_json');}}
void _success(BackupReply reply) {
  if(reply.status<200||reply.status>299)throw BackupException('backup_http_error',httpStatus:reply.status,
    retryable:reply.status==409||reply.status==429||reply.status>=500);
}
