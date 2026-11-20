import 'dart:io';
import 'package:flutter/material.dart';
import '../../../data/api_client.dart';
import '../../../local/attachments/attachment_descriptor.dart';
import '../../../local/plugins/pet_routes.dart';
import '../../../theme/wo_tokens.dart';

/// 只读取当前成员授权的独立副本；普通文件不会自动交给外部应用。
class PetAttachmentPanel extends StatefulWidget {
  const PetAttachmentPanel({super.key,required this.routes,required this.familyId,required this.recordId,required this.canWrite,this.onChanged});
  final PetRoutes routes;final String familyId,recordId;final bool canWrite;
  final Future<void> Function()? onChanged;
  @override State<PetAttachmentPanel> createState()=>_PetAttachmentPanelState();
}
class _PetAttachmentPanelState extends State<PetAttachmentPanel> {
  List<AttachmentDescriptor>? _items;bool _loading=false;String? _busy,_error;int _epoch=0;
  final _states=<String,String>{};
  @override void initState(){super.initState();_load();}
  @override void didUpdateWidget(covariant PetAttachmentPanel old){super.didUpdateWidget(old);
    if(old.recordId!=widget.recordId||old.familyId!=widget.familyId||old.routes!=widget.routes){_epoch++;_loading=false;_items=null;_states.clear();_load();}}
  Future<void> _load()async{
    if(_loading)return;setState(()=>_loading=true);final epoch=++_epoch,fid=widget.familyId,rid=widget.recordId;
    try{final rows=await widget.routes.listAttachments(fid,rid);if(mounted&&epoch==_epoch&&fid==widget.familyId&&rid==widget.recordId)setState((){_items=rows;_error=null;});}
    catch(e){if(mounted&&epoch==_epoch)setState((){_error=petAttachmentError(e);if(e is ApiException&&{403,404}.contains(e.statusCode))_items=[];});}
    finally{if(mounted&&epoch==_epoch)setState(()=>_loading=false);}
  }
  Future<void> _check(AttachmentDescriptor descriptor)async{
    if(_busy!=null)return;final epoch=_epoch,fid=widget.familyId,rid=widget.recordId,routes=widget.routes;setState(()=>_busy=descriptor.id);
    try{final file=await routes.attachmentFile(fid,rid,descriptor.id);
      if(!mounted||epoch!=_epoch)return;setState(()=>_states[descriptor.id]=file==null?'本机副本缺失；记录仍保留，可重新检查或等待已授权手机传输':'本机副本已通过摘要校验');
      if(file!=null&&descriptor.kind=='image')await Navigator.of(context).push(MaterialPageRoute<void>(builder:(_)=>_PetAttachmentImage(file:file,name:descriptor.displayName)));
    }catch(e){if(mounted&&epoch==_epoch)setState(()=>_states[descriptor.id]=petAttachmentError(e));}
    finally{if(mounted)setState(()=>_busy=null);}
  }
  Future<void> _delete(AttachmentDescriptor descriptor)async{
    if(_busy!=null||!widget.canWrite)return;
    final yes=await showDialog<bool>(context:context,builder:(context)=>AlertDialog(title:const Text('删除记录附件？'),
      content:Text('删除 ${descriptor.displayName} 的附件记录。该标识会留下删除墓碑，不能通过旧选择重试复活。'),
      actions:[TextButton(onPressed:()=>Navigator.pop(context,false),child:const Text('取消')),
        TextButton(onPressed:()=>Navigator.pop(context,true),child:const Text('删除附件'))]));
    if(yes!=true||!mounted)return;setState(()=>_busy=descriptor.id);
    try{await widget.routes.deleteAttachment(widget.familyId,widget.recordId,descriptor.id);await _load();await widget.onChanged?.call();}
    catch(e){if(mounted)setState(()=>_error=petAttachmentError(e));}
    finally{if(mounted)setState(()=>_busy=null);}
  }
  @override Widget build(BuildContext context)=>Column(crossAxisAlignment:CrossAxisAlignment.start,children:[
    Row(children:[Expanded(child:Text('记录附件',style:Theme.of(context).textTheme.titleMedium)),TextButton(onPressed:_loading||_busy!=null?null:_load,child:const Text('刷新附件'))]),
    const Text('每条记录最多 10 个，单个最多 20 MiB。图片为独立副本；普通文件仅显示信息，不自动打开。'),
    if(_loading)const LinearProgressIndicator(),if(_error!=null)Text(_error!),
    if(_items!=null&&_items!.isEmpty)const Text('尚无附件。'),
    for(final d in _items??<AttachmentDescriptor>[])ListTile(contentPadding:EdgeInsets.zero,
      leading:Icon(d.kind=='image'?Icons.image_outlined:Icons.description_outlined),title:Text(d.displayName),
      subtitle:Text('${(d.size/1024).toStringAsFixed(1)} KiB · ${_states[d.id]??'尚未核对本机副本'}'),
      onTap:_busy!=null?null:()=>_check(d),trailing:_busy==d.id?const SizedBox(width:20,height:20,child:WoProgressIndicator(strokeWidth:2)):
        widget.canWrite?IconButton(tooltip:'删除附件',onPressed:_busy!=null?null:()=>_delete(d),icon:const Icon(Icons.delete_outline)):const Icon(Icons.chevron_right)),
  ]);
}
class _PetAttachmentImage extends StatelessWidget {
  const _PetAttachmentImage({required this.file,required this.name});final File file;final String name;
  @override Widget build(BuildContext context)=>WoScaffold(appBar:WoAppBar(title:Text(name)),body:Center(child:InteractiveViewer(
    child:Image.file(file,errorBuilder:(_,__,___)=>const Text('本机副本当前不可预览，请返回重新核对；未改用远程原图。')))));
}
String petAttachmentError(Object error){
  if(error is ApiException)return error.message;
  if(error is AttachmentException)return switch(error.code){
    'attachment_missing'||'attachment_not_found'||'attachment_unavailable'=>'本机附件副本缺失，请重新检查或等待已授权手机传输',
    'selection_expired'||'selection_missing'||'selection_consumed'=>'选择已失效，请重新选择附件',
    'attachment_integrity'||'attachment_source_changed'=>'本机副本摘要或大小不一致，请等待重新传输，未展示损坏内容',
    'attachment_too_large'=>'单个附件不能超过 20 MiB',
    'media_requires_image_copy'=>'图片请使用图片副本入口，视频不属于普通文件附件',
    _=>'附件尚未完成，请重试；当前记录没有改用云端文件',
  };
  return '附件尚未完成，请检查本机权限与文件后重试';
}
