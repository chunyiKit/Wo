import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:uuid/uuid.dart';

import '../../../data/api_client.dart';
import '../../../data/models.dart';
import '../../../data/wo_session.dart';
import '../../../local/local_runtime.dart';
import '../../../theme/wo_tokens.dart';

/// 本地编辑仍保留九宫格、标题正文、日期地点、心情与可见范围。
/// 原件仅由本机媒体仓库引用；本页不压缩/上传照片，也不读取整段视频。
class LocalMemoryEditPage extends StatefulWidget {
  const LocalMemoryEditPage({super.key,this.existing});
  final Memory? existing;
  @override
  State<LocalMemoryEditPage> createState()=>_LocalMemoryEditPageState();
}
class _LocalMemoryEditPageState extends State<LocalMemoryEditPage> {
  static const _moods=['😍','🥹','🤤','😌','😆','🥰','😭','🤔'];
  static const _visibilities=[('private','🔒 只我自己'),('family','🏡 全家'),('couple','💞 我和 TA')];
  final _title=TextEditingController(),_body=TextEditingController(),_location=TextEditingController();
  final _mediaIds=<String>[],_pending=<String>{},_removed=<String>{};
  LocalRuntime? _runtime;
  String? _fid,_device,_draftKey;
  late String _memoryId;
  String _mood='',_visibility='private';
  DateTime _date=DateTime.now();
  bool _started=false,_initializing=true,_loadFailed=false,_picking=false,_saving=false,_exists=false,_finished=false;
  Future<void> _draftWrites=Future<void>.value();
  bool _checkingAccess=true,_accessBlocked=false;
  int _authorityEpoch=0;


  @override
  void initState(){
    super.initState();
    final existing=widget.existing;
    _memoryId=existing?.id??const Uuid().v4();
    _exists=existing!=null;
    if(existing!=null){
      _title.text=existing.title;_body.text=existing.body??'';_location.text=existing.location??'';
      _mood=existing.mood??'';_visibility=existing.visibility;_date=existing.eventDate;
      _mediaIds.addAll(existing.media.map((m)=>m.id));
    }
  }
  @override
  void didChangeDependencies(){
    super.didChangeDependencies();
    if(!_started){_started=true;_loadDraft();}
    else if(!_sameIdentity){_authorityEpoch++;_accessBlocked=true;_checkingAccess=false;}
  }
  bool get _sameIdentity=>mounted&&_runtime!=null&&_runtime!.store.deviceId==_device&&WoScope.of(context).currentFamilyId==_fid;
  bool get _current=>_sameIdentity&&!_checkingAccess&&!_accessBlocked&&!_initializing&&!_loadFailed;
  bool _at(int epoch)=>_current&&epoch==_authorityEpoch;
  void _require(int epoch){if(!_at(epoch))throw StateError('本机身份或回忆权限已变化，请核权后重试');}
  void _permissionChanged(){
    if(!mounted)return;
    // 先保留本机私有草稿，再隐藏正文；不删除来源文件或已保存的媒体引用。
    unawaited(_persistDraft().catchError((Object _){}));
    _authorityEpoch++;
    setState((){_checkingAccess=true;_accessBlocked=true;});
    if(!_initializing)unawaited(_validateAccess());
  }
  Future<bool> _validateAccess()async{
    final epoch=_authorityEpoch;
    var allowed=false;
    try{
      if(_sameIdentity){
        final runtime=_runtime!,fid=_fid!;
        final member=await runtime.store.get(fid,'/families/$fid/members',_device!);
        if(member!=null&&member['status']=='active'&&member['family_id']==fid&&member['user_id']==_device){
          if(_exists){
            final result=await runtime.memories.request('GET',fid,['memory','memories',_memoryId]);
            final value=result?.data;
            allowed=value is Map&&value['visibility']==_visibility;
          }else{
            final scope=await runtime.memories.access.spaceFor(fid,_visibility);
            allowed=(await runtime.memories.access.visibleSpaces(fid)).contains(scope);
          }
        }
      }
    }catch(_){allowed=false;}
    if(!mounted||epoch!=_authorityEpoch)return false;
    allowed=allowed&&_sameIdentity;
    setState((){_accessBlocked=!allowed;_checkingAccess=false;});
    return allowed;
  }
  String get _dateText=>[_date.year.toString().padLeft(4,'0'),_date.month.toString().padLeft(2,'0'),_date.day.toString().padLeft(2,'0')].join('-');
  Future<void> _loadDraft() async {
    final runtime=LocalRuntime.instance,fid=WoScope.of(context).currentFamilyId;
    if(runtime==null||fid==null){setState((){_loadFailed=true;_initializing=false;});return;}
    _runtime=runtime;_fid=fid;_device=runtime.store.deviceId;
    runtime.changes.addListener(_permissionChanged);
    _draftKey='local-memory-draft:$fid:$_device:${widget.existing?.id??'new'}';
    try{
      if(widget.existing!=null){await runtime.memories.request('GET',fid,['memory','memories',_memoryId]);}
      final raw=await runtime.store.privateValue(_draftKey!);
      if(!_sameIdentity){if(mounted)setState((){_loadFailed=true;_initializing=false;});return;}
      if(raw!=null){
        if(raw is! Map)throw const FormatException('草稿结构无效');
        final value=Map<String,dynamic>.from(raw);
        final visibility=value['visibility'];
        if(!['private','family','couple'].contains(visibility)||
          (widget.existing!=null&&visibility!=widget.existing!.visibility))throw const FormatException('草稿可见范围无效');
        final id=value['memory_id'];
        if(id is! String||!RegExp(r'^[A-Za-z0-9_-]{1,100}$').hasMatch(id))throw const FormatException('草稿标识无效');
        final date=DateTime.tryParse(value['event_date'] as String? ?? '');
        if(date==null)throw const FormatException('草稿日期无效');
        _memoryId=id;_visibility=visibility as String;_date=date;_exists=value['record_exists']==true;
        _title.text=value['title'] as String;_body.text=value['body'] as String? ?? '';
        _location.text=value['location'] as String? ?? '';_mood=value['mood'] as String? ?? '';
        List<String> ids(String key){
          final list=(value[key] as List?)?.cast<String>()??<String>[];
          if(list.any((id)=>!RegExp(r'^[A-Za-z0-9_-]{1,100}$').hasMatch(id)))throw const FormatException('草稿媒体标识无效');
          return list.toSet().toList();
        }
        _mediaIds..clear()..addAll(ids('media_ids'));
        _pending..clear()..addAll(ids('pending'));
        _removed..clear()..addAll(ids('removed'));
        if(_mediaIds.length>1024||_pending.length>9||!_pending.every(_mediaIds.contains))throw const FormatException('草稿媒体列表无效');
        if(_exists)await runtime.memories.request('GET',fid,['memory','memories',_memoryId]);
      }
      if(!mounted)return;
      setState(()=>_initializing=false);
      await _validateAccess();
      if(raw!=null&&_current)_message('已恢复本机未完成草稿，可继续保存');
    }catch(e){if(mounted){setState((){_loadFailed=true;_initializing=false;});_toast(e);}}
  }
  Future<void> _persistDraft(){
    final runtime=_runtime,key=_draftKey;
    if(runtime==null||key==null||_initializing||_loadFailed||_finished)return Future<void>.value();
    final snapshot=<String,dynamic>{
      'memory_id':_memoryId,'record_exists':_exists,'title':_title.text,'body':_body.text,
      'mood':_mood,'location':_location.text,'visibility':_visibility,'event_date':_dateText,
      'media_ids':List<String>.of(_mediaIds),'pending':_pending.toList(),'removed':_removed.toList(),
    };
    // 私有 SQLite meta 不进入 operations；队列防止较旧草稿覆盖后续编辑。
    _draftWrites=_draftWrites.catchError((Object _){}).then((_)=>runtime.store.setPrivate(key,snapshot));
    return _draftWrites;
  }
  void _changed(){setState((){});unawaited(_persistDraft().catchError((Object e){if(mounted)_toast(e);}));}
  @override
  void dispose(){
    _runtime?.changes.removeListener(_permissionChanged);
    _authorityEpoch++;
    if(!_finished&&!_initializing&&!_loadFailed)unawaited(_persistDraft().catchError((Object _){}));
    _title.dispose();_body.dispose();_location.dispose();super.dispose();
  }
  void _message(String text){ScaffoldMessenger.of(context).showSnackBar(WoSnackBar(content:Text(text)));}
  void _toast(Object error){_message(error is ApiException?error.message:error is PlatformException&&error.code=='MEDIA_UNAVAILABLE'&&error.details=='unsupported'?'此设备相册接口当前不可用，请选择文件中的照片或视频；草稿已保留':'无法完成本机操作，请保留草稿后重试');}
  Future<void> _addMedia() async {
    if(_picking||_mediaIds.length>=9||!_current)return;
    final epoch=_authorityEpoch;
    final selection=await showWoModalBottomSheet<(String,String)>(context:context,builder:(ctx)=>SafeArea(child:Column(mainAxisSize:MainAxisSize.min,children:[
      for(final option in [('photo','photos','相册照片',Icons.photo_library_outlined),('photo','files','文件中的照片',Icons.folder_outlined),('video','photos','相册视频',Icons.videocam_outlined),('video','files','文件中的视频',Icons.video_file_outlined)])
        WoListTile(leading:Icon(option.$4),title:Text(option.$3),onTap:()=>Navigator.of(ctx).pop((option.$1,option.$2))),
    ])));
    if(selection==null||!_at(epoch))return;
    setState(()=>_picking=true);
    try{
      final item=await _runtime!.media.pick(selection.$1,source:selection.$2);
      if(item==null||!_at(epoch))return;
      if(_mediaIds.contains(item.id))return;
      setState((){_mediaIds.add(item.id);_pending.add(item.id);});
      await _persistDraft();
    }catch(e){if(mounted)_toast(e);}finally{if(mounted)setState(()=>_picking=false);}
  }
  Future<void> _pickDate() async {
    if(!_current)return;
    final epoch=_authorityEpoch;
    final tomorrow=DateTime.now().add(const Duration(days:1));
    final chosen=await showDatePicker(context:context,useRootNavigator:false,initialDate:_date,
      firstDate:DateTime(_date.year<2000?_date.year:2000),lastDate:_date.isAfter(tomorrow)?_date:tomorrow);
    if(chosen!=null&&_at(epoch)){_date=chosen;_changed();}
  }
  Future<void> _remove(String id) async {
    if(!_current)return;
    setState((){_mediaIds.remove(id);if(!_pending.remove(id))_removed.add(id);});
    try{await _persistDraft();}catch(e){if(mounted)_toast(e);}
  }
  Future<void> _save() async {
    if(_saving||_picking||!_current||_title.text.trim().isEmpty)return;
    final epoch=_authorityEpoch;
    setState(()=>_saving=true);
    final runtime=_runtime!,fid=_fid!;
    final fields=<String,dynamic>{'title':_title.text.trim(),'body':_body.text.isEmpty?null:_body.text,
      'mood':_mood.isEmpty?null:_mood,'location':_location.text.isEmpty?null:_location.text,
      'visibility':_visibility,'event_date':_dateText};
    try{
      await _persistDraft();_require(epoch);
      if(!_exists){
        final result=await runtime.memories.request('POST',fid,['memory','memories'],body:{...fields,'client_id':_memoryId});
        if(result==null)throw StateError('本地回忆路由未接入');
        final saved=Memory.fromJson(Map<String,dynamic>.from(result.data as Map));
        _memoryId=saved.id;_visibility=saved.visibility;_exists=true;await _persistDraft();
      }
      _require(epoch);
      // 幂等创建可能返回上一次保存；再 PUT 本次明确编辑，防止重试丢失修改。
      await runtime.memories.request('PUT',fid,['memory','memories',_memoryId],body:fields);
      _require(epoch);
      for(final id in _removed.toList()){
        _require(epoch);
        try{await runtime.memories.removeMedia(fid,_memoryId,id);}
        on ApiException catch(e){
          if(e.statusCode!=404)rethrow;
          final result=await runtime.memories.request('GET',fid,['memory','memories',_memoryId]);
          _require(epoch);
          final visible=Memory.fromJson(Map<String,dynamic>.from(result!.data as Map));
          if(visible.media.any((m)=>m.id==id))rethrow;
        }
        _require(epoch);
        _removed.remove(id);await _persistDraft();
      }
      for(final id in _pending.toList()){
        _require(epoch);
        await runtime.memories.attachMedia(fid,_memoryId,id);
        _require(epoch);
        _pending.remove(id);await _persistDraft();
      }
      _require(epoch);
      await runtime.memories.request('GET',fid,['memory','memories',_memoryId]);
      _require(epoch);
      await _draftWrites;_require(epoch);
      await runtime.store.setPrivate(_draftKey!,null);_finished=true;
      if(mounted)Navigator.of(context).pop(true);
    }catch(e){if(mounted)_toast(e);}finally{if(mounted)setState(()=>_saving=false);}
  }
  Widget _thumbnail(String id)=>FutureBuilder<File?>(future:_runtime!.media.thumbnailFile(id),builder:(context,snapshot){
    final file=snapshot.data;
    return file==null?const ColoredBox(color:Color(0xFFEDE8E1),child:Center(child:Icon(Icons.photo_outlined))):Image.file(file,fit:BoxFit.cover,errorBuilder:(_,__,___)=>const Center(child:Icon(Icons.broken_image_outlined)));
  });
  Widget _tile(String id)=>Stack(fit:StackFit.expand,children:[
    ClipRRect(borderRadius:BorderRadius.circular(14),child:_thumbnail(id)),
    Positioned(left:4,right:4,bottom:4,child:FutureBuilder<Map<String,dynamic>>(future:_runtime!.media.originalAvailability(id),builder:(context,snapshot)=>Text(
      snapshot.data==null?'检查原件':snapshot.data!['available']==true?'原件可读':snapshot.data!['referenced']==true?'原件引用已保留，待备份核验':'原件缺件，备份将不完整',
      maxLines:2,style:const TextStyle(fontSize:10,color:Colors.white,backgroundColor:Colors.black54),
    ))),
    Positioned(top:2,right:2,child:IconButton(tooltip:'移除媒体',onPressed:()=>_remove(id),icon:const Icon(Icons.cancel,color:Colors.white),style:IconButton.styleFrom(backgroundColor:Colors.black38))),
  ]);
  @override
  Widget build(BuildContext context){
    final wo=context.wo,t=Theme.of(context).textTheme;
    final inaccessible=_loadFailed||_accessBlocked||(!_initializing&&!_sameIdentity);
    final canSave=!_initializing&&!_checkingAccess&&!inaccessible&&!_saving&&!_picking&&_title.text.trim().isNotEmpty;
    return PopScope(canPop:!_saving,child:WoScaffold(backgroundColor:wo.bg,
      appBar:WoAppBar(title:Text(widget.existing==null?'新的回忆':'编辑回忆'),actions:[
        Padding(padding:const EdgeInsets.symmetric(horizontal:WoTokens.space2),child:WoTextButton(onPressed:canSave?_save:null,
          child:_saving?const SizedBox(width:18,height:18,child:WoProgressIndicator(strokeWidth:2)):const Text('保存'))),
      ]),
      body:_initializing||_checkingAccess?const Center(child:WoProgressIndicator()):inaccessible?Center(child:Column(mainAxisSize:MainAxisSize.min,children:[
        const Text('当前身份无法打开这份本机回忆，私有草稿仍保留'),
        WoTextButton(onPressed:_sameIdentity?(){setState(()=>_checkingAccess=true);_validateAccess();}:null,child:const Text('重新核对权限')),
      ])):
      SafeArea(child:AbsorbPointer(absorbing:_saving||_picking,child:ListView(padding:const EdgeInsets.all(WoTokens.space4),children:[
        GridView.count(crossAxisCount:3,mainAxisSpacing:WoTokens.space2,crossAxisSpacing:WoTokens.space2,shrinkWrap:true,physics:const NeverScrollableScrollPhysics(),children:[
          for(final id in _mediaIds)_tile(id),
          if(_mediaIds.length<9)InkWell(onTap:_addMedia,borderRadius:BorderRadius.circular(14),child:Container(decoration:BoxDecoration(color:wo.bgTint,borderRadius:BorderRadius.circular(14)),child:Center(child:_picking?const WoProgressIndicator():const Icon(Icons.add,size:32)))),
        ]),
        const SizedBox(height:WoTokens.space2),Text('${_mediaIds.length} / 9 · 照片或视频',style:t.labelSmall?.copyWith(color:wo.fgDim)),
        const SizedBox(height:WoTokens.space4),
        WoTextField(controller:_title,maxLength:80,onChanged:(_)=>_changed(),style:t.titleLarge?.copyWith(fontWeight:FontWeight.w600),decoration:const InputDecoration(hintText:'给这一刻起个标题',counterText:'',border:InputBorder.none)),
        Divider(color:wo.hairline,height:1),const SizedBox(height:WoTokens.space3),
        WoTextField(controller:_body,maxLength:2000,minLines:3,maxLines:8,onChanged:(_)=>_changed(),decoration:const InputDecoration(hintText:'今天发生了什么？',counterText:'',border:InputBorder.none)),
        const SizedBox(height:WoTokens.space4),
        WoListTile(leading:const Icon(Icons.calendar_today_outlined),title:const Text('日期'),trailing:Text(_dateText),onTap:_pickDate),
        WoTextField(controller:_location,maxLength:80,onChanged:(_)=>_changed(),decoration:const InputDecoration(prefixIcon:Icon(Icons.place_outlined),hintText:'地点',counterText:'')),
        const SizedBox(height:WoTokens.space4),Text('心情',style:t.titleSmall),const SizedBox(height:WoTokens.space2),
        Wrap(spacing:WoTokens.space2,children:[for(final mood in _moods)GestureDetector(onTap:(){_mood=_mood==mood?'':mood;_changed();},child:Container(width:44,height:44,alignment:Alignment.center,decoration:BoxDecoration(color:_mood==mood?wo.accentSoft:wo.bgTint,borderRadius:BorderRadius.circular(14),border:Border.all(color:_mood==mood?wo.accent:Colors.transparent,width:1.5)),child:Text(mood,style:const TextStyle(fontSize:22))))]),
        const SizedBox(height:WoTokens.space4),Text('谁能看到',style:t.titleSmall),const SizedBox(height:WoTokens.space2),
        Wrap(spacing:WoTokens.space2,children:[for(final (value,label) in _visibilities)WoChoiceChip(label:Text(label),selected:_visibility==value,onSelected:_exists?null:(_){if(!_current)return;_visibility=value;_changed();_permissionChanged();})]),
        if(_exists)Padding(padding:const EdgeInsets.only(top:WoTokens.space2),child:Text('已保存回忆的可见范围固定',style:t.labelSmall?.copyWith(color:wo.fgDim))),
      ]))),
    ));
  }
}
