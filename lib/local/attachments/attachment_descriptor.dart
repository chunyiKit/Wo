import 'dart:convert';
import 'dart:typed_data';

class AttachmentException implements Exception {
  const AttachmentException(this.code);
  final String code;
  @override String toString() => 'AttachmentException($code)';
}

const ordinaryAttachmentMaxBytes = 20 * 1024 * 1024;
const ordinaryAttachmentChunkBytes = 256 * 1024;
const ordinaryAttachmentPurposes = {'chat_image_copy', 'chat_file_copy', 'pet_image_copy', 'pet_file_copy'};
bool attachmentFullMatch(RegExp pattern, String value) {
  final match = pattern.firstMatch(value); return match != null && match.start == 0 && match.end == value.length;
}
final _logical = RegExp(r'^[A-Za-z0-9_-]{1,100}$');
final _id = RegExp(r'^a_[a-f0-9]{32}$');
final _sha = RegExp(r'^[a-f0-9]{64}$');
final _token = RegExp(r'^[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}$');
Never attachmentFail(String code) => throw AttachmentException(code);

/// 仅展示名，永不拼接路径；wire名字必须已经规范化。
String safeAttachmentDisplayName(String raw) {
  if (raw.length > 4096) attachmentFail('invalid_attachment_name');
  var value = String.fromCharCodes(raw.runes.map((r) => r < 32 || r == 127 ||
    r >= 0x200b && r <= 0x200f || r >= 0x202a && r <= 0x202e || r >= 0x2066 && r <= 0x2069 ||
    '<>:"/\\|?*'.runes.contains(r) ? 95 : r)).trim();
  while (value.startsWith('.')) { value = value.substring(1); }
  while (value.endsWith('.') || value.endsWith(' ')) { value = value.substring(0, value.length - 1); }
  if (value.isEmpty) value = 'attachment';
  if (RegExp(r'^(CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])(\.|$)', caseSensitive: false).hasMatch(value)) value = 'attachment_$value';
  final runes = value.runes.toList();
  while (utf8.encode(String.fromCharCodes(runes)).length > 180) { runes.removeLast(); }
  value = String.fromCharCodes(runes);
  while (value.endsWith('.') || value.endsWith(' ')) { value = value.substring(0, value.length - 1); }
  return value.isEmpty ? 'attachment' : value;
}

class AttachmentBinding {
  AttachmentBinding({required this.familyId, required this.plugin, required this.parentId, required this.authorDeviceId}) {
    if (![familyId, parentId, authorDeviceId].every((v) => attachmentFullMatch(_logical, v)) ||
      !{'chat', 'pet'}.contains(plugin)) attachmentFail('invalid_attachment_binding');
  }
  final String familyId, plugin, parentId, authorDeviceId;
  bool matches(AttachmentBinding other) => familyId == other.familyId && plugin == other.plugin &&
    parentId == other.parentId && authorDeviceId == other.authorDeviceId;
}

class AttachmentDescriptor {
  AttachmentDescriptor({required this.id, required this.binding, required this.purpose, required this.kind,
    required this.displayName, required this.contentType, required this.size, required this.sha256, required this.createdAt}) {
    if (!attachmentFullMatch(_id, id) || !ordinaryAttachmentPurposes.contains(purpose) ||
      !purpose.startsWith('${binding.plugin}_') || kind != (purpose.endsWith('_image_copy') ? 'image' : 'file') ||
      size < 1 || size > ordinaryAttachmentMaxBytes || !attachmentFullMatch(_sha, sha256) ||
      safeAttachmentDisplayName(displayName) != displayName || !attachmentFullMatch(RegExp(r'^[a-z0-9!#$&^_.+-]+/[a-z0-9!#$&^_.+-]+$'),contentType) ||
      contentType.length > 120 || DateTime.tryParse(createdAt) == null || !createdAt.endsWith('Z')) attachmentFail('invalid_attachment_descriptor');
    if (kind == 'image' && contentType != 'image/jpeg' || kind == 'file' &&
      (contentType.startsWith('image/') || contentType.startsWith('video/') || _mediaExtension(displayName))) attachmentFail('media_requires_image_copy');
  }
  final String id, purpose, kind, displayName, contentType, sha256, createdAt;
  final AttachmentBinding binding;
  final int size;
  String get familyId => binding.familyId;
  String get plugin => binding.plugin;
  String get parentId => binding.parentId;
  String get authorDeviceId => binding.authorDeviceId;
  static const syncFields = {'family_id','plugin','parent_id','author_device_id','purpose','kind','display_name','content_type','size','sha256','created_at'};
  Map<String,dynamic> toJson() => {'id':id,'family_id':familyId,'plugin':plugin,'parent_id':parentId,
    'author_device_id':authorDeviceId,'purpose':purpose,'kind':kind,'display_name':displayName,
    'content_type':contentType,'size':size,'sha256':sha256,'created_at':createdAt};
  factory AttachmentDescriptor.fromJson(Map<String,dynamic> value) {
    final expected = {...syncFields, 'id'};
    if (value.keys.toSet().difference(expected).isNotEmpty || !expected.every(value.containsKey) ||
      value['size'] is! int || expected.difference({'size'}).any((key) => value[key] is! String)) attachmentFail('invalid_attachment_descriptor');
    return AttachmentDescriptor(id:value['id'] as String, binding:AttachmentBinding(familyId:value['family_id'] as String,
      plugin:value['plugin'] as String,parentId:value['parent_id'] as String,authorDeviceId:value['author_device_id'] as String),
      purpose:value['purpose'] as String,kind:value['kind'] as String,displayName:value['display_name'] as String,
      contentType:value['content_type'] as String,size:value['size'] as int,sha256:value['sha256'] as String,createdAt:value['created_at'] as String);
  }
  bool same(AttachmentDescriptor other) => id == other.id && binding.matches(other.binding) && purpose == other.purpose &&
    kind == other.kind && displayName == other.displayName && contentType == other.contentType && size == other.size &&
    sha256 == other.sha256 && createdAt == other.createdAt;
  static bool validId(String value) => attachmentFullMatch(_id, value);
}

bool _mediaExtension(String name) => RegExp(r'\.(jpg|jpeg|png|gif|webp|heif|heic|avif|bmp|tif|tiff|svg|mp4|mov|m4v|mkv|mpeg|mpg|avi|webm|3gp)$', caseSensitive:false).hasMatch(name);

class AttachmentSelectionMetadata {
  AttachmentSelectionMetadata({required this.token,required this.purpose,required this.displayName,
    required this.contentType,required this.size,required this.kind}) {
    if (!attachmentFullMatch(_token,token) || !ordinaryAttachmentPurposes.contains(purpose) || size < 1 ||
      size > ordinaryAttachmentMaxBytes || kind != (purpose.endsWith('_image_copy') ? 'image' : 'file') ||
      displayName.length > 4096 || contentType.length > 120) attachmentFail('invalid_attachment_selection');
  }
  final String token,purpose,displayName,contentType,kind;
  final int size;
  factory AttachmentSelectionMetadata.fromMap(Map<dynamic,dynamic> value) {
    const fields = {'token','purpose','displayName','contentType','size','kind'};
    if (value.keys.toSet().difference(fields).isNotEmpty || !fields.every(value.containsKey) ||
      value['size'] is! int || fields.difference({'size'}).any((key) => value[key] is! String)) attachmentFail('invalid_attachment_selection');
    return AttachmentSelectionMetadata(token:value['token'] as String,purpose:value['purpose'] as String,
      displayName:value['displayName'] as String,contentType:value['contentType'] as String,size:value['size'] as int,kind:value['kind'] as String);
  }
  static void checkToken(String token) { if (!attachmentFullMatch(_token,token)) attachmentFail('invalid_attachment_token'); }
}

/// 实现只能消费独立原生picker一次性选择；不是路径、相册handle或恢复归档导入入口。
abstract interface class AttachmentSelectionSource {
  Future<AttachmentSelectionMetadata?> pick({required String purpose});
  Future<AttachmentSelectionMetadata> claim({required String token,required String purpose});
  Future<Uint8List> read({required String token,required int offset,required int maxBytes});
  Future<void> release(String token);
}

/// file通道只接受普通文件。MIME/名字检查之外，再拒媒体魔数伪装。
void validateOrdinaryFileHeader(Uint8List bytes) {
  bool at(int offset,List<int> value) => offset+value.length<=bytes.length &&
    List.generate(value.length,(i)=>bytes[offset+i]==value[i]).every((v)=>v);
  if (at(0,[255,216]) || at(0,[137,80,78,71]) || at(0,[71,73,70,56]) ||
    at(0,[73,73,42,0]) || at(0,[77,77,0,42]) || at(0,[66,77]) ||
    at(4,[102,116,121,112]) || at(0,[26,69,223,163]) || at(0,[79,103,103,83]) ||
    at(0,[82,73,70,70]) && (at(8,[87,69,66,80]) || at(8,[65,86,73,32]))) attachmentFail('media_requires_image_copy');
}

void validateAttachmentImage(Uint8List bytes){
    if(bytes.length<4||bytes.length>ordinaryAttachmentMaxBytes||bytes[0]!=255||bytes[1]!=216)throw const FormatException('缩略图格式或大小无效');
    var pos=2,scans=0;var scanning=false,dimensions=false,quantization=false,huffman=false;
    var progressive=false;final components=<int>{};
    Never invalid()=>throw const FormatException('非规范或含元数据的附件JPEG');
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
        if(w<1||h<1||w>1600||h>1600||!(count==1||count==3)||length!=8+3*count)invalid();
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
