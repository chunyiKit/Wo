import 'dart:convert';

const backupChunkBytes = 8 * 1024 * 1024;
const backupMaxAttachmentBytes = 20 * 1024 * 1024;
const backupMaxFileBytes = 64 * 1024 * 1024 * 1024;
final _identifier = RegExp(r'^[A-Za-z0-9_-]{1,100}$');
final _digest = RegExp(r'^[a-f0-9]{64}$');

bool validBackupId(String value) {
  if (!_identifier.hasMatch(value)) return false;
  final upper = value.toUpperCase();
  return !{'CON', 'PRN', 'AUX', 'NUL'}.contains(upper) &&
      !RegExp(r'^(COM|LPT)[1-9]$').hasMatch(upper);
}

class BackupException implements Exception {
  const BackupException(this.code, {this.retryable = false, this.httpStatus});
  final String code;
  final bool retryable;
  final int? httpStatus;
  @override
  String toString() => 'BackupException($code)';
}

enum BackupPrivacy { public, restricted }

class BackupEntry {
  BackupEntry({required this.id, required this.kind, required this.size,
    required this.sha256, required this.sourceExact, this.missing = '', this.label = ''}) {
    if (!validBackupId(id) || !{'records','photo','video','thumbnail','sealed','file'}.contains(kind) ||
        size < 0 || size > backupMaxFileBytes || utf8.encode(label).length > 240 ||
        label.runes.any((r) => r < 32 || r == 127)) throw const BackupException('invalid_entry');
    if (kind == 'file' && (size > backupMaxAttachmentBytes || (missing.isEmpty && size == 0)) ||
        sourceExact && kind != 'photo' && kind != 'video') throw const BackupException('invalid_file_or_source_exact');
    if (missing.isNotEmpty) {
      if (!{'permission_denied','cloud_only','source_unavailable','not_exact_original'}.contains(missing) ||
          size != 0 || sha256.isNotEmpty || sourceExact) throw const BackupException('invalid_missing');
    } else if (!_digest.hasMatch(sha256) || ((kind == 'photo' || kind == 'video') && size == 0)) {
      throw const BackupException('invalid_digest_or_size');
    }
    if (kind == 'sealed' && (label.isNotEmpty || missing.isNotEmpty || sourceExact || size < 121)) {
      throw const BackupException('restricted_must_be_opaque');
    }
  }
  final String id, kind, sha256, missing, label;
  final int size;
  final bool sourceExact;
  Map<String,dynamic> toJson() => {'id':id,'kind':kind,'size':size,
    if (sha256.isNotEmpty) 'sha256':sha256, if (label.isNotEmpty) 'label':label,
    if (missing.isNotEmpty) 'missing':missing, if (sourceExact) 'source_exact':true};
  factory BackupEntry.fromJson(Map<String,dynamic> j) {
    _fields(j, {'id','kind','size'}, {'sha256','label','missing','source_exact'});
    return BackupEntry(id:_string(j,'id'),kind:_string(j,'kind'),size:_integer(j,'size'),
      sha256:_optionalString(j,'sha256'),label:_optionalString(j,'label'),
      missing:_optionalString(j,'missing'),sourceExact:_optionalBool(j,'source_exact'));
  }
}

class BackupManifest {
  BackupManifest({required this.familyId, required this.backupId, required Iterable<BackupEntry> entries, int? version})
      : entries = List.unmodifiable(entries) {
    this.version = version ?? (this.entries.any((e)=>e.kind=='file') ? 2 : 1);
    if (![1,2].contains(this.version) || this.version==1 && this.entries.any((e)=>e.kind=='file')) throw const BackupException('unsupported_manifest_version');
    if (!validBackupId(familyId) || !validBackupId(backupId) || this.entries.isEmpty || this.entries.length > 4096) {
      throw const BackupException('invalid_manifest');
    }
    final seen = <String>{}; var total = 0; var sealed = 0;
    for (final e in this.entries) {
      if (!seen.add(e.id.toLowerCase())) throw const BackupException('duplicate_entry');
      total += e.size; if (e.kind == 'sealed') sealed++;
    }
    if (total > (1 << 40) || sealed > 1 || utf8.encode(canonicalJson).length > (2 << 20)) {
      throw const BackupException('manifest_limit');
    }
  }
  late final int version;
  final String familyId, backupId;
  final List<BackupEntry> entries;
  Map<String,dynamic> toJson() => {'version':version,'family_id':familyId,'backup_id':backupId,
    'entries':entries.map((e)=>e.toJson()).toList()};
  String get canonicalJson => jsonEncode(toJson());
  factory BackupManifest.fromJson(Map<String,dynamic> j) {
    _fields(j, {'version','family_id','backup_id','entries'}, {});
    if (j['version'] is! int || ![1,2].contains(j['version']) || j['entries'] is! List) throw const BackupException('invalid_manifest');
    return BackupManifest(version:j['version'] as int,familyId:_string(j,'family_id'),backupId:_string(j,'backup_id'),
      entries:(j['entries'] as List).map((e)=>BackupEntry.fromJson(backupObject(e))));
  }
}

/// openRange 必须读取冻结的同一来源快照，恰好返回 length 字节；不接受旧设备 URI。
/// restricted 原始数据不能交给 upload，必须先封装为单一 sealed 容器。
abstract class BackupSource {
  BackupEntry get entry;
  BackupPrivacy get privacy;
  Future<Stream<List<int>>> openRange(int offset, int length);
}

class BackupEntryProgress {
  BackupEntryProgress(this.id,this.kind,this.size,this.offset,this.missing);
  final String id,kind,missing; final int size,offset;
  factory BackupEntryProgress.fromJson(Map<String,dynamic> j) {
    _fields(j, {'id','kind','size','offset'}, {'label','missing'});
    return BackupEntryProgress(_string(j,'id'),_string(j,'kind'),_integer(j,'size'),
      _integer(j,'offset'),_optionalString(j,'missing'));
  }
}

class BackupStatus {
  BackupStatus.fromJson(Map<String,dynamic> j)
    : familyId=_string(j,'family_id'),backupId=_string(j,'backup_id'),state=_string(j,'state'),
      scope=_string(j,'scope'),complete=j['complete']==true,
      verifiedAt=_optionalString(j,'verified_at'),
      issues=List.unmodifiable(_stringList(j,'issues')),
      entries=List.unmodifiable(_progressList(j)) {
    _fields(j, {'family_id','backup_id','state','scope','complete','full_device_complete','issues','entries'}, {'verified_at'});
    if (j['complete'] is! bool || j['full_device_complete'] != false ||
      !validBackupId(familyId) || !validBackupId(backupId) ||
      !{'uploading','verified','incomplete','unreadable'}.contains(state) ||
      !{'declared_public_files','opaque_restricted_unverified',''}.contains(scope)) {
      throw const BackupException('invalid_status');
    }
  }
  final String familyId,backupId,state,scope,verifiedAt;
  final bool complete;
  final List<String> issues;
  final List<BackupEntryProgress> entries;
  bool get fullDeviceComplete => false;
  void check(BackupManifest manifest) {
    if (familyId != manifest.familyId || backupId != manifest.backupId || entries.length != manifest.entries.length) {
      throw const BackupException('status_scope_mismatch');
    }
    final byId = <String,BackupEntryProgress>{};
    for (final e in entries) {if (byId.containsKey(e.id)) throw const BackupException('invalid_status');byId[e.id]=e;}
    for (final e in manifest.entries) {
      final p=byId[e.id];
      if (p==null || p.kind!=e.kind || p.size!=e.size || p.missing!=e.missing || p.offset<0 || p.offset>e.size) {
        throw const BackupException('invalid_remote_offset');
      }
      if (e.kind=='sealed' && complete) throw const BackupException('opaque_is_not_complete');
      if (complete && (e.missing.isNotEmpty || ((e.kind=='photo'||e.kind=='video')&&!e.sourceExact))) throw const BackupException('incomplete_source_claim');
    }
  }
}

/// 可写入本地设置的配对引用；不含 token、恢复密钥、私密正文。
class PairedComputer {
  PairedComputer({required this.origin,required this.pin,required this.familyId,
    required this.deviceId,required this.tokenRef}) {
    validateComputerOrigin(origin,pin);
    if (!validBackupId(familyId)||!validBackupId(deviceId)||!RegExp(r'^wo\.backup\.token\.[a-f0-9]{32}$').hasMatch(tokenRef)) {
      throw const BackupException('invalid_pair_reference');
    }
  }
  final Uri origin; final String pin,familyId,deviceId,tokenRef;
}

void validateComputerOrigin(Uri origin,String pin) {
  if (origin.scheme!='https'||origin.host.isEmpty||origin.userInfo.isNotEmpty||
      origin.path.isNotEmpty||origin.hasQuery||origin.hasFragment||!_digest.hasMatch(pin)) {
    throw const BackupException('explicit_https_and_pin_required');
  }
}

Map<String,dynamic> backupObject(Object? value) {
  if (value is! Map<String,dynamic>) throw const BackupException('invalid_json_object');
  return value;
}
void _fields(Map<String,dynamic> j,Set<String> required,Set<String> optional) {
  if (!j.keys.toSet().containsAll(required)||j.keys.any((k)=>!required.contains(k)&&!optional.contains(k))||j.values.any((v)=>v==null)) {
    throw const BackupException('invalid_json_fields');
  }
}
String _string(Map<String,dynamic> j,String k) {final v=j[k];if(v is! String)throw const BackupException('invalid_json_type');return v;}
String _optionalString(Map<String,dynamic> j,String k)=>j.containsKey(k)?_string(j,k):'';
int _integer(Map<String,dynamic> j,String k) {final v=j[k];if(v is! int)throw const BackupException('invalid_json_type');return v;}
bool _optionalBool(Map<String,dynamic> j,String k) {final v=j[k];if(v==null)return false;if(v is! bool)throw const BackupException('invalid_json_type');return v;}

/// 标准 jsonDecode 保留重复键的最后值；协议先拒绝重复键/过深结构再解码。
Object? decodeBackupJson(String text) {
  try {final guard=_JsonShape(text);guard.value(0);guard.space();if(guard.index!=text.length)throw const BackupException('json_trailing');return jsonDecode(text);}
  on BackupException {rethrow;} catch(_){throw const BackupException('invalid_json');}
}
class _JsonShape {
  _JsonShape(this.text);final String text;int index=0;
  void space(){while(index<text.length&&' \r\n\t'.contains(text[index])){index++;}}
  bool take(String c){space();if(index<text.length&&text[index]==c){index++;return true;}return false;}
  void require(String c){if(!take(c))throw const BackupException('invalid_json');}
  String string(){space();final start=index;require('"');var escaped=false;
    while(index<text.length){final c=text[index++];if(escaped){escaped=false;continue;}if(c=='\\'){escaped=true;continue;}if(c=='"')return jsonDecode(text.substring(start,index)) as String;}
    throw const BackupException('invalid_json');
  }
  void value(int depth){
    if(depth>12)throw const BackupException('json_depth');space();if(index>=text.length)throw const BackupException('invalid_json');
    if(text[index]=='{') {index++;final seen=<String>{};if(take('}'))return;while(true){final key=string();if(!seen.add(key))throw const BackupException('duplicate_json_key');require(':');value(depth+1);if(take('}'))return;require(',');}}
    else if(text[index]=='['){index++;if(take(']'))return;while(true){value(depth+1);if(take(']'))return;require(',');}}
    else if(text[index]=='"'){string();}
    else{final start=index;while(index<text.length&&!' \r\n\t,]}'.contains(text[index])){index++;}if(start==index)throw const BackupException('invalid_json');jsonDecode(text.substring(start,index));}
  }
}

List<String> _stringList(Map<String,dynamic> j,String key) {
 final values=j[key];if(values is! List||values.length>8192||values.any((v)=>v is! String))throw const BackupException('invalid_status');
 return values.cast<String>();
}
List<BackupEntryProgress> _progressList(Map<String,dynamic> j) {
 final values=j['entries'];if(values is! List||values.length>4096)throw const BackupException('invalid_status');
 return values.map((v)=>BackupEntryProgress.fromJson(backupObject(v))).toList(growable:false);
}
