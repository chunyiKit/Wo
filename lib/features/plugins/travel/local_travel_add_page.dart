import 'dart:io';

import 'package:flutter/material.dart';
import 'package:uuid/uuid.dart';

import '../../../data/api_client.dart';
import '../../../data/models.dart';
import '../../../data/wo_session.dart';
import '../../../local/local_runtime.dart';
import '../../../services/external_services.dart';
import '../../../theme/wo_tokens.dart';
import 'memory_link_sheet.dart';
import 'travel_city_picker.dart';

/// 新建只在本机记录原照引用；生成按钮在保存后逐次确认供应商和发送副本。
class LocalTravelAddPage extends StatefulWidget {
  const LocalTravelAddPage({super.key});
  @override State<LocalTravelAddPage> createState()=>_LocalTravelAddPageState();
}
class _LocalTravelAddPageState extends State<LocalTravelAddPage> {
  final _place=TextEditingController(),_caption=TextEditingController();
  final _clientId=const Uuid().v4();
  TravelCity? _city;
  Memory? _memory;
  String? _mediaId,_familyId;
  File? _thumbnail;
  TravelTrip? _saved;
  bool _busy=false,_savedAnything=false;
  int _epoch=0;
  @override void didChangeDependencies(){
    super.didChangeDependencies();final current=WoScope.of(context).currentFamilyId;
    _familyId??=current;
    if(current!=_familyId)_epoch++;
  }
  bool _valid(int epoch)=>mounted&&_epoch==epoch&&_familyId==WoScope.of(context).currentFamilyId;
  void _toast(String text)=>ScaffoldMessenger.of(context).showSnackBar(WoSnackBar(content:Text(text)));
  void _error(Object e)=>_toast(e is ApiException?e.message:'无法完成本机旅行操作，请保留当前记录后重试');
  @override void dispose(){_epoch++;_place.dispose();_caption.dispose();super.dispose();}
  Future<void> _pick()async{
    if(_busy||_saved!=null)return;final epoch=_epoch,runtime=LocalRuntime.instance;
    if(runtime==null||!_valid(epoch))return;
    final source=await showWoModalBottomSheet<String>(context:context,builder:(ctx)=>SafeArea(child:Column(mainAxisSize:MainAxisSize.min,children:[
      WoListTile(leading:const Icon(Icons.photo_library_outlined),title:const Text('相册中的原照引用'),onTap:()=>Navigator.pop(ctx,'photos')),
      WoListTile(leading:const Icon(Icons.folder_outlined),title:const Text('文件中的原照引用'),onTap:()=>Navigator.pop(ctx,'files')),
    ])));
    if(source==null||!_valid(epoch))return;setState(()=>_busy=true);
    try{final item=await runtime.media.pick('photo',source:source);if(item==null||!_valid(epoch))return;
      final thumb=await runtime.media.thumbnailFile(item.id);if(!_valid(epoch))return;
      setState((){_mediaId=item.id;_thumbnail=thumb;});
    }catch(e){if(mounted)_error(e);}finally{if(mounted)setState(()=>_busy=false);}
  }
  Future<void> _pickCity()async{
    if(_busy||_saved!=null)return;final epoch=_epoch;
    final city=await showWoModalBottomSheet<TravelCity>(context:context,isScrollControlled:true,builder:(_)=>const TravelCityPickerSheet());
    if(city!=null&&_valid(epoch))setState(()=>_city=city);
  }
  Future<void> _pickMemory()async{
    if(_busy||_saved!=null)return;final epoch=_epoch;
    final memory=await showMemoryLinkSheet(context,seedQuery:_place.text.trim().isNotEmpty?_place.text.trim():_city?.name);
    if(memory==null||!_valid(epoch))return;
    if(memory.visibility!='family'){_toast('全家旅行只能关联全家可见回忆，受限标题和关联不会保存到全家');return;}
    setState(()=>_memory=memory);
  }
  Future<void> _save()async{
    final runtime=LocalRuntime.instance,epoch=_epoch;
    if(_busy||_saved!=null||runtime==null||!_valid(epoch))return;
    if(_city==null||_mediaId==null){_toast('请选择城市和本机原照引用');return;}
    setState(()=>_busy=true);
    try{
      final result=await runtime.travels.request('POST',_familyId!,['travel','trips'],body:{
        'client_id':_clientId,'media_id':_mediaId,'city_name':_city!.name,'city_lng':_city!.lng,'city_lat':_city!.lat,
        'place':_place.text,'caption':_caption.text,'memory_id':_memory?.id});
      if(result==null)throw StateError('本地旅行路由未接入');
      _savedAnything=true;runtime.changed();
      if(!_valid(epoch))return;
      setState(()=>_saved=TravelTrip.fromJson(Map<String,dynamic>.from(result.data as Map)));
      _toast('旅行已保存在本机，原照引用保留；可另行确认生成');
    }catch(e){if(mounted)_error(e);}finally{if(mounted)setState(()=>_busy=false);}
  }
  Future<void> _generate()async{
    if(_busy||_saved==null)return;final epoch=_epoch;setState(()=>_busy=true);
    try{final updated=await generateLocalTravelImage(context,_saved!.id);
      if(updated!=null&&_valid(epoch))setState(()=>_saved=updated);
    }finally{if(mounted)setState(()=>_busy=false);}
  }
  @override Widget build(BuildContext context){
    final wo=context.wo,valid=_familyId==WoScope.of(context).currentFamilyId;
    return PopScope(canPop:!_busy,onPopInvokedWithResult:(didPop,_) {},child:WoScaffold(
      backgroundColor:wo.bg,appBar:WoAppBar(title:Text(_saved==null?'新的旅行':'旅行已保存在本机'),leading:WoIconButton(
        tooltip:'返回',icon:const Icon(Icons.arrow_back),onPressed:_busy?null:()=>Navigator.pop(context,_savedAnything)),
        actions:[if(_saved==null)WoTextButton(onPressed:_busy||!valid?null:_save,child:const Text('保存'))]),
      body:!valid?const Center(child:Text('家庭已变化，请返回原家庭后重试；已选来源文件未删除')):
      SafeArea(child:AbsorbPointer(absorbing:_busy,child:ListView(padding:const EdgeInsets.all(16),children:[
        WoListTile(leading:const Icon(Icons.place_outlined),title:Text(_city?.name??'城市 / 区县'),
          subtitle:const Text('仅记录在本机，不向天气或图片服务自动发送定位'),onTap:_saved==null?_pickCity:null),
        const SizedBox(height:12),
        WoTextField(controller:_place,readOnly:_saved!=null,maxLength:60,decoration:const InputDecoration(labelText:'具体地点（可选）')),
        WoListTile(leading:const Icon(Icons.link),title:const Text('关联回忆'),subtitle:Text(_memory?.title??'仅可关联全家可见回忆'),
          onTap:_saved==null?_pickMemory:null,trailing:_saved==null&&_memory!=null?WoIconButton(icon:const Icon(Icons.close),onPressed:()=>setState(()=>_memory=null)):null),
        const SizedBox(height:16),
        AspectRatio(aspectRatio:4/3,child:ClipRRect(borderRadius:BorderRadius.circular(18),child:InkWell(onTap:_saved==null?_pick:null,
          child:_thumbnail==null?ColoredBox(color:wo.bgTint,child:const Center(child:Icon(Icons.add_photo_alternate_outlined,size:48))):
            Image.file(_thumbnail!,fit:BoxFit.cover,errorBuilder:(_,__,___)=>const Center(child:Text('缩略图缺件，请重新选择')))))),
        const SizedBox(height:8),const Text('保留原照引用；手机间只同步缩略图，电脑备份才读取原照。'),
        const SizedBox(height:16),WoTextField(controller:_caption,readOnly:_saved!=null,maxLength:200,minLines:2,maxLines:4,decoration:const InputDecoration(labelText:'旅行文案（可选）')),
        const SizedBox(height:12),
        if(_busy)const Center(child:WoProgressIndicator()),
        if(_saved!=null)...[
          Text(_saved!.isFailed?'上次生成未完成，原照与旅行仍保留':_saved!.aiStatus=='ready'?'生成结果已保存在本机':'尚未向模型发送照片'),
          const SizedBox(height:12),WoFilledButton.icon(onPressed:_busy?null:_generate,icon:const Icon(Icons.auto_awesome),
            label:Text(_saved!.isFailed?'确认后重试风格图':'确认后生成风格图')),
          WoTextButton(onPressed:_busy?null:()=>Navigator.pop(context,true),child:const Text('完成并返回')),
        ]else const Text('保存只创建本地记录；模型生成是下一步单独授权操作。'),
      ]))),
    ));
  }
}

/// 创建与重试共用确认页，每次读取当前模型配置/发送副本，默认不授权。
Future<TravelTrip?> generateLocalTravelImage(BuildContext context,String tripId)async{
  final runtime=LocalRuntime.instance,fid=WoScope.of(context).currentFamilyId;
  if(runtime==null||fid==null)return null;
  try{
    final plan=await runtime.travels.planGeneration(fid,tripId);
    if(!context.mounted||WoScope.of(context).currentFamilyId!=fid)return null;
    var upload=false,reviewed=false;
    final yes=await showWoDialog<bool>(context:context,builder:(ctx)=>StatefulBuilder(builder:(ctx,setLocal)=>WoAlertDialog(
      title:const Text('本次生成授权'),content:SingleChildScrollView(child:Column(mainAxisSize:MainAxisSize.min,crossAxisAlignment:CrossAxisAlignment.start,children:[
        Image.memory(plan.image.bytes,height:160,fit:BoxFit.contain),const SizedBox(height:10),
        const Text('将发送上方去除元数据的缩略图副本，不发送原照、相册ID或本机句柄。'),
        const SizedBox(height:8),Text('模型：${plan.modelLabel}\n服务：${plan.endpoint}'),
        const SizedBox(height:8),Text('供应商留存说明：\n${plan.retentionNotice}'),
        ExpansionTile(title:const Text('查看本次提示词'),children:[Text(plan.prompt)]),
        CheckboxListTile(value:upload,onChanged:(v)=>setLocal(()=>upload=v==true),title:const Text('允许本次发送上方图片副本')),
        CheckboxListTile(value:reviewed,onChanged:(v)=>setLocal(()=>reviewed=v==true),title:const Text('已阅读并接受上述供应商留存政策')),
      ])),actions:[WoTextButton(onPressed:()=>Navigator.pop(ctx,false),child:const Text('取消')),
        WoFilledButton(onPressed:upload&&reviewed?()=>Navigator.pop(ctx,true):null,child:const Text('仅授权这一次'))],
    )));
    if(yes!=true||!context.mounted||WoScope.of(context).currentFamilyId!=fid)return null;
    final result=await runtime.travels.generate(fid,tripId,plan:plan,consent:ImageGenerationConsent(
      endpoint:plan.endpoint,retentionNotice:plan.retentionNotice,allowSourceUpload:true,providerPolicyReviewed:true,expectedModel:plan.modelLabel));
    runtime.changed();
    final trip=TravelTrip.fromJson(result);
    if(context.mounted)ScaffoldMessenger.of(context).showSnackBar(WoSnackBar(content:Text(trip.isFailed?'生成未完成，旅行和原照仍保留，可重新确认后重试':'风格图已保存在本机')));
    return trip;
  }catch(e){if(context.mounted)ScaffoldMessenger.of(context).showSnackBar(WoSnackBar(content:Text(e is ApiException?e.message:'图片模型暂不可用，本机旅行记录仍保留')));return null;}
}
