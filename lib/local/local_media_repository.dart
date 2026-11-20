import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:crypto/crypto.dart' as hashing;
import 'package:path_provider/path_provider.dart';
import 'package:flutter/services.dart';
import 'package:uuid/uuid.dart';
import 'local_store.dart';
import 'media/native_media.dart';
import 'backup/backup_models.dart';

/// 只表示已核归属后的派生小图损坏或不可用，不表示权限/绑定校验失败。
class ThumbnailUnavailable implements Exception { const ThumbnailUnavailable(); }

/// 公开操作只含缩略图描述；原件的原生句柄与保真状态仅存本机device_refs。
class LocalMediaItem {
  const LocalMediaItem({required this.id,required this.kind,required this.thumbnailSha256,
    required this.sizeBytes,this.width,this.height,this.durationMs});
  final String id,kind,thumbnailSha256;
  final int sizeBytes;
  final int? width,height,durationMs;
  String get contentType=>'image/jpeg';
  String get url=>'wo-local-media://$id/thumbnail';
  Map<String,dynamic> toMemoryJson(String memoryId,int sortOrder)=>{'id':id,'memory_id':memoryId,'kind':kind,
    'url':url,'content_type':contentType,'size_bytes':sizeBytes,'width':width,'height':height,'duration_ms':durationMs,'sort_order':sortOrder};
  factory LocalMediaItem.fromJson(Map<String,dynamic> m)=>LocalMediaItem(id:m['id'] as String,kind:m['kind'] as String,
    thumbnailSha256:m['thumbnail_sha256'] as String,sizeBytes:(m['thumbnail_bytes'] as num?)?.toInt()??0,
    width:(m['width'] as num?)?.toInt(),height:(m['height'] as num?)?.toInt(),durationMs:(m['duration_ms'] as num?)?.toInt());
}

class LocalMediaRepository {
  LocalMediaRepository(this.store,{required this.native,required this.directory});
  final LocalStore store;
  final NativeMedia native;
  final Directory directory;
  static const maxThumbnailBytes=96*1024;
  static final _id=RegExp(r'^[a-zA-Z0-9_-]{1,100}$');
  static final _sha=RegExp(r'^[a-f0-9]{64}$');
  static Future<LocalMediaRepository> open(LocalStore store)async{
    final root=await getApplicationSupportDirectory();final directory=Directory('${root.path}/local_media_v1');
    await directory.create(recursive:true);return LocalMediaRepository(store,native:NativeMedia(),directory:directory);
  }
  String _collection(String space)=>'/families/$space/plugins/memory/media';
  static bool _full(RegExp pattern,String value){final match=pattern.firstMatch(value);return match!=null&&match.start==0&&match.end==value.length;}
  File _thumb(String id){if(!_full(_id,id))throw const FormatException('媒体标识无效');return File('${directory.path}/$id.jpg');}
  static String hash(List<int> bytes)=>hashing.sha256.convert(bytes).toString();
  /// 完整解析段与扫描字节：拒绝扫描后的元数据、截断、无EOI及尾随内容。
  static void validateThumbnail(Uint8List bytes){
    if(bytes.length<4||bytes.length>maxThumbnailBytes||bytes[0]!=255||bytes[1]!=216)throw const FormatException('缩略图格式或大小无效');
    var pos=2,scans=0;var scanning=false,dimensions=false,quantization=false,huffman=false;
    var progressive=false;final components=<int>{};
    Never invalid()=>throw const FormatException('非规范或含元数据的缩略图JPEG');
    int u16(int at)=>(bytes[at]<<8)|bytes[at+1];
    while(pos<bytes.length){
      var marker=-1;
      if(scanning){
        var data=false;
        while(pos<bytes.length){
          if(bytes[pos++]!=255){data=true;continue;}
          while(pos<bytes.length&&bytes[pos]==255){pos++;}
          if(pos>=bytes.length)invalid();
          final next=bytes[pos++];
          if(next==0){data=true;continue;}
          if(next>=208&&next<=215)continue;
          if(!data)invalid();
          marker=next;scanning=false;break;
        }
        if(marker<0)invalid();
      }else{
        if(bytes[pos++]!=255)invalid();
        while(pos<bytes.length&&bytes[pos]==255){pos++;}
        if(pos>=bytes.length)invalid();
        marker=bytes[pos++];
      }
      if(marker==217){if(!dimensions||scans==0||pos!=bytes.length)invalid();return;}
      if(marker==0||marker==1||marker==216||marker>=208&&marker<=215||
          marker>=225&&marker<=239||marker==254)invalid();
      if(pos+2>bytes.length)invalid();
      final length=u16(pos),end=pos+length;
      if(length<2||end>bytes.length)invalid();
      final start=pos+2;
      if(marker==224){
        // 只允许无嵌套图/任意扩展负载的标准 JFIF APP0。
        if(length!=16||bytes[start]!=74||bytes[start+1]!=70||bytes[start+2]!=73||
            bytes[start+3]!=70||bytes[start+4]!=0||bytes[end-2]!=0||bytes[end-1]!=0)invalid();
      }else if(marker==192||marker==194){
        if(dimensions||scans!=0||length<8||bytes[start]!=8)invalid();
        final h=u16(start+1),w=u16(start+3),count=bytes[start+5];
        if(w<1||h<1||w>512||h>512||!(count==1||count==3)||length!=8+3*count)invalid();
        for(var i=0;i<count;i++){
          final at=start+6+3*i,sampling=bytes[at+1];
          if(!components.add(bytes[at])||(sampling>>4)<1||(sampling>>4)>4||
              (sampling&15)<1||(sampling&15)>4||bytes[at+2]>3)invalid();
        }
        dimensions=true;progressive=marker==194;
      }else if(marker==219){
        var at=start;
        while(at<end){final table=bytes[at++],precision=table>>4;if(precision>1||(table&15)>3)invalid();at+=64*(precision+1);if(at>end)invalid();}
        if(at!=end||length==2)invalid();quantization=true;
      }else if(marker==196){
        var at=start;
        while(at<end){
          final table=bytes[at++];if((table>>4)>1||(table&15)>3||at+16>end)invalid();
          var count=0;for(var i=0;i<16;i++){count+=bytes[at++];}
          if(count<1||count>256||at+count>end)invalid();at+=count;
        }
        if(at!=end||length==2)invalid();huffman=true;
      }else if(marker==221){if(length!=4)invalid();
      }else if(marker==218){
        if(!dimensions||!quantization||!huffman||length<6)invalid();
        final count=bytes[start];if(count<1||count>components.length||length!=6+2*count)invalid();
        final selected=<int>{};
        for(var i=0;i<count;i++){
          final at=start+1+2*i,table=bytes[at+1];
          if(!components.contains(bytes[at])||!selected.add(bytes[at])||(table>>4)>3||(table&15)>3)invalid();
        }
        final ss=bytes[end-3],se=bytes[end-2],successive=bytes[end-1];
        if(ss>se||se>63||(successive>>4)>13||(successive&15)>13||
            (!progressive&&(ss!=0||se!=63||successive!=0))||
            (progressive&&((ss==0&&se!=0)||(ss>0&&count!=1))))invalid();
        scanning=true;scans++;
      }else{invalid();}
      pos=end;
    }
    invalid();
  }
  static final _thumbnailQueues=<String,Future<void>>{};
  Future<void> _serializeThumbnail(String id,Future<void> Function() action){
    final key=_thumb(id).absolute.path,result=Completer<void>();
    final tail=(_thumbnailQueues[key]??Future<void>.value()).then((_)async{
      try{await action();result.complete();}catch(e,s){result.completeError(e,s);}
    });
    _thumbnailQueues[key]=tail;
    unawaited(tail.then((_) {if(identical(_thumbnailQueues[key],tail))_thumbnailQueues.remove(key);}));
    return result.future;
  }
  Future<void> _saveThumbnailUnlocked(String id,Uint8List bytes,{bool repair=false})async{
    validateThumbnail(bytes);await directory.create(recursive:true);final target=_thumb(id);
    if(await target.exists()){
      final small=await target.length()<=maxThumbnailBytes;
      final oldMatches=small&&hash(await target.readAsBytes())==hash(bytes);
      if(oldMatches)return;
      if(!repair)throw const FormatException('同一媒体ID缩略图冲突');
      // 仅 descriptor 已绑定的接收路径可隔离坏缩略图；不触碰原件或设备句柄。
      await target.rename('${target.path}.corrupt-${const Uuid().v4()}');
    }
    final temp=File('${target.path}.${const Uuid().v4()}.tmp');
    try{await temp.writeAsBytes(bytes,flush:true);if(await target.exists())throw const FormatException('缩略图目标已出现');await temp.rename(target.path);}
    finally{if(await temp.exists())await temp.delete();}
  }
  Future<void> _saveThumbnail(String id,Uint8List bytes)=>_serializeThumbnail(id,()=>_saveThumbnailUnlocked(id,bytes));
  Future<LocalMediaItem?> pick(String kind,{String source='photos'})async{
    if(!['photo','video'].contains(kind)||!['photos','files'].contains(source))throw const FormatException('媒体来源无效');
    final ref=await native.pick(kind:kind=='photo'?MediaKind.photo:MediaKind.video,source:source=='photos'?MediaSource.photos:MediaSource.files);if(ref==null)return null;
    final id=const Uuid().v4();final bytes=await native.thumbnail(ref.handle);await _saveThumbnail(id,bytes);
    final metadata=<String,dynamic>{'kind':kind,'thumbnail_sha256':hash(bytes),'thumbnail_bytes':bytes.length,
      'width':ref.width,'height':ref.height,'duration_ms':ref.durationMs,'selected_at':DateTime.now().toUtc().toIso8601String(),'source_exact':false,'missing_reason':ref.missingReason,'scope':null,'memory_id':null};
    await store.saveDeviceReference(id,kind,ref.handle,metadata);
    return LocalMediaItem.fromJson({'id':id,...metadata});
  }
  Map<String,dynamic> _metadata(Map<String,dynamic> ref)=>Map<String,dynamic>.from(jsonDecode(ref['metadata'] as String) as Map);
  /// 全局媒体ID终身只属于同一space/插件/父记录；已删除描述也保留归属。
  /// 远端接收的小图可能没有device_ref，不能仅凭没有原生句柄就视为可重新绑定。
  Future<void> verifyMediaOwnership(String scope,String mediaId,String memoryId,{
    bool allowUnboundLocal=false,bool rejectDeleted=false,String? expectedDigest,
  })async{
    if(!_full(_id,scope)||!_full(_id,mediaId)||!_full(_id,memoryId))throw const FormatException('媒体归属标识无效');
    final expectedCollection=_collection(scope);
    final rows=await store.db.query('documents',columns:['space','collection','data','deleted'],
      where:'id=? AND (collection LIKE ? OR collection LIKE ?)',
      whereArgs:[mediaId,'/families/%/plugins/memory/media','/families/%/plugins/travel/media']);
    for(final row in rows){
      if(row['space']!=scope||row['collection']!=expectedCollection)throw const FormatException('媒体ID已属于其它权限空间或插件');
      final fields=Map<String,dynamic>.from(jsonDecode(row['data'] as String) as Map);
      if(fields['memory_id']!=memoryId)throw const FormatException('媒体ID已属于其它父记录或历史墓碑');
      if(rejectDeleted&&row['deleted']==1)throw const FormatException('已删除的媒体ID不可重新绑定，请重新选择');
    }
    final ref=await store.deviceReference(mediaId);
    if(ref!=null){
      final meta=_metadata(ref);
      final fresh=allowUnboundLocal&&meta['scope']==null&&meta['memory_id']==null&&meta['plugin']==null&&meta['trip_id']==null;
      if(!fresh&&(meta['scope']!=scope||meta['memory_id']!=memoryId||meta['trip_id']!=null||
          meta['plugin']!=null&&meta['plugin']!='memory'))throw const FormatException('本机媒体绑定范围不可改变');
      if(expectedDigest!=null&&meta['thumbnail_sha256']!=expectedDigest)throw const FormatException('本机媒体缩略图摘要绑定不符');
    }
    // 生成结果与已接收旅行小图没有原生引用时，也不能挂接进回忆。
    if(await store.privateValue('travel-artifact:$mediaId')!=null||await store.privateValue('travel-received:$mediaId')!=null)
      throw const FormatException('旅行媒体ID不能重新挂接到回忆');
  }
  Future<void> attach(String space,String memoryId,String mediaId)=>_serializeThumbnail(mediaId,()async{
    await verifyMediaOwnership(space,mediaId,memoryId,allowUnboundLocal:true,rejectDeleted:true);
    if(!_full(_id,space)||!_full(_id,memoryId))throw const FormatException('媒体范围无效');final ref=await store.deviceReference(mediaId);if(ref==null)throw const FormatException('没有本机已选媒体');
    final meta=_metadata(ref);if(meta['scope']!=null&&(meta['scope']!=space||meta['memory_id']!=memoryId))throw const FormatException('媒体绑定范围不可改变，请重新明确选择');
    final existing=await store.get(space,_collection(space),mediaId);if(existing!=null){if(existing['memory_id']!=memoryId)throw const FormatException('媒体已绑定其它回忆');return;}
    final selected=meta['selected_at'] is String?meta['selected_at'] as String:'1970-01-01T00:00:00.000Z';
    final sortKey='${selected}_$mediaId';
    if(meta['sort_key']!=null&&meta['sort_key']!=sortKey)throw const FormatException('媒体排序绑定不可改变');
    meta['scope']=space;meta['memory_id']=memoryId;meta['sort_key']=sortKey;await store.saveDeviceReference(mediaId,ref['kind'] as String,ref['locator'] as String,meta);
    await store.patch(space,_collection(space),mediaId,{'memory_id':memoryId,'kind':meta['kind'],'thumbnail_sha256':meta['thumbnail_sha256'],
      'thumbnail_bytes':meta['thumbnail_bytes'],'sort_key':sortKey,'width':meta['width'],'height':meta['height'],'duration_ms':meta['duration_ms'],'created_by':store.deviceId});
  });
  Future<void> detach(String space,String memoryId,String mediaId)async{final row=await store.get(space,_collection(space),mediaId);if(row==null||row['memory_id']!=memoryId)throw const FormatException('媒体不属于回忆');await store.patch(space,_collection(space),mediaId,{},delete:true);}
  Future<List<LocalMediaItem>> forMemory(String space,String memoryId)async{
    final rows=(await store.list(space,_collection(space))).where((row)=>row['memory_id']==memoryId).toList();
    String key(Map<String,dynamic> row)=>row['sort_key'] is String&&(row['sort_key'] as String).isNotEmpty?row['sort_key'] as String:row['id'] as String;
    rows.sort((a,b){final order=key(a).compareTo(key(b));return order!=0?order:(a['id'] as String).compareTo(b['id'] as String);});
    return rows.map(LocalMediaItem.fromJson).toList();
  }
  Future<File?> thumbnailFile(String id)async{final f=_thumb(id);return await f.exists()?f:null;}
  Future<Map<String,dynamic>> originalAvailability(String id)async{
    final ref=await store.deviceReference(id);if(ref==null)return {'available':false,'reason':'本机只有缩略图，原件在拍摄设备或电脑备份'};
    try{final resolved=await native.resolve(ref['locator'] as String);return {'available':resolved.sourceExact,'referenced':true,'prepared':resolved.sourceExact,'reason':resolved.sourceExact?'本机原件快照已核验':'本机引用已保留，原件将在备份时核验'};}catch(_){return {'available':false,'reason':'当前无权限或原件离线不可读'};}
  }
  Future<bool> openOriginal(String id)async{final ref=await store.deviceReference(id);if(ref==null||(ref['locator'] as String).isEmpty)return false;return native.openOriginal(ref['locator'] as String);}
  Future<Map<String,dynamic>?> thumbnailForWire(String scope,String mediaId)async{
    if(!_full(_id,scope)||scope.startsWith('p_'))throw const FormatException('不能同步私密或无效空间');
    final row=await store.get(scope,_collection(scope),mediaId);if(row==null)return null;
    final parent=row['memory_id'],digest=row['thumbnail_sha256'];
    if(parent is! String||digest is! String||!_full(_sha,digest))throw const FormatException('媒体父记录或摘要无效');
    await verifyMediaOwnership(scope,mediaId,parent,expectedDigest:digest);
    final f=await thumbnailFile(mediaId);if(f==null||await f.length()>maxThumbnailBytes)return null;
    final bytes=await f.readAsBytes();try{validateThumbnail(bytes);}on FormatException{throw const ThumbnailUnavailable();}
    if(hash(bytes)!=row['thumbnail_sha256']||bytes.length!=row['thumbnail_bytes'])throw const ThumbnailUnavailable();
    return {'space':scope,'id':mediaId,'sha256':row['thumbnail_sha256'],'bytes':base64Url.encode(bytes)};
  }
  Future<void> receiveThumbnail(String scope,String id,String digest,Uint8List bytes)=>_serializeThumbnail(id,()async{
    if(!_full(_id,scope)||scope.startsWith('p_')||!_full(_sha,digest)||hash(bytes)!=digest)throw const FormatException('缩略图范围或摘要无效');
    validateThumbnail(bytes);
    final row=await store.get(scope,_collection(scope),id);
    if(row==null||row['thumbnail_sha256']!=digest||row['thumbnail_bytes']!=bytes.length||
        !['photo','video'].contains(row['kind']))throw const FormatException('缩略图未绑定本轮已授权媒体记录');
    final parent=row['memory_id'];if(parent is! String)throw const FormatException('媒体父记录无效');
    await verifyMediaOwnership(scope,id,parent,expectedDigest:digest);
    final local=await store.deviceReference(id);
    if(local!=null){final meta=_metadata(local);if(meta['scope']!=scope||meta['memory_id']!=parent||meta['thumbnail_sha256']!=digest)throw const FormatException('远端不能覆盖其它本机媒体引用');}
    await _saveThumbnailUnlocked(id,bytes,repair:true);
  });
  Future<BackupSource> prepareBackupSource(String id,{required BackupPrivacy privacy,String kindIfMissing='photo'})async{
    final ref=await store.deviceReference(id);if(ref==null)return _NativeBackupSource(BackupEntry(id:id,kind:kindIfMissing,size:0,sha256:'',sourceExact:false,missing:'source_unavailable'),privacy,null,null);
    final kind=ref['kind'] as String,handle=ref['locator'] as String;
    Future<BackupSource> missing(String reason)async{
      final allowed={'permission_denied','cloud_only','source_unavailable','not_exact_original'};
      final code=allowed.contains(reason)?reason:'source_unavailable';
      final meta=_metadata(ref)..['source_exact']=false..['missing_reason']=code;
      await store.saveDeviceReference(id,kind,handle,meta);
      return _NativeBackupSource(BackupEntry(id:id,kind:kind,size:0,sha256:'',sourceExact:false,missing:code),privacy,null,null);
    }
    try{
      final ready=await native.prepareOriginal(handle);
      if(!ready.sourceExact||ready.size<=0)return missing(ready.missingReason??'not_exact_original');
      final digest=await hashing.sha256.bind(_nativeRange(native,handle,0,ready.size)).first;
      final meta=_metadata(ref)..['source_exact']=true..['missing_reason']=null;
      await store.saveDeviceReference(id,kind,handle,meta);
      return _NativeBackupSource(BackupEntry(id:id,kind:kind,size:ready.size,sha256:digest.toString(),sourceExact:true),privacy,native,handle);
    }on PlatformException catch(e){return missing(e.details is String?e.details as String:'source_unavailable');}
    on FileSystemException{return missing('source_unavailable');}
  }
}
class _NativeBackupSource extends BackupSource {
  _NativeBackupSource(this.entry,this.privacy,this.native,this.handle);
  @override final BackupEntry entry;
  @override final BackupPrivacy privacy;
  final NativeMedia? native;final String? handle;
  @override Future<Stream<List<int>>> openRange(int offset,int length)async{
    if(native==null||handle==null||offset<0||length<0||offset+length>entry.size)throw const FormatException('原件不可读或范围无效');return _nativeRange(native!,handle!,offset,length);
  }
 }
Stream<List<int>> _nativeRange(NativeMedia native,String handle,int offset,int length)async*{
  var left=length;while(left>0){final count=left>8*1024*1024?8*1024*1024:left;final chunk=await native.read(handle,offset:offset,maxBytes:count);if(chunk.length!=count)throw const FileSystemException('原件变化或截断');yield chunk;offset+=chunk.length;left-=chunk.length;}
}
