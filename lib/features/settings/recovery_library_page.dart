import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';

import '../../local/backup/backup_models.dart';
import '../../local/backup/mobile_backup_controller.dart';
import '../../local/backup/portable_archive.dart';
import '../../local/backup/recovery_workspace.dart';
import '../../local/media/owned_media_store.dart';
import '../../theme/wo_tokens.dart';
import '../../widgets/wo_card.dart';
import 'local_backup_page.dart';

typedef RecoveryBackupController = Future<MobileBackupController> Function(String workspaceId);

/// 独立恢复资料库：不切换家庭，不启动普通插件，不把历史身份当作当前授权。
class RecoveryLibraryPage extends StatefulWidget {
  const RecoveryLibraryPage({super.key,required this.store,this.pendingRestore,this.backupControllerFor});
  final RecoveryWorkspaceStore store;
  final PortableRestore? pendingRestore;
  final RecoveryBackupController? backupControllerFor;
  @override State<RecoveryLibraryPage> createState()=>_RecoveryLibraryPageState();
}

class _RecoveryLibraryPageState extends State<RecoveryLibraryPage> {
  List<RecoveryWorkspace>? _items;
  RecoveryPreview? _preview;
  String? _listError,_previewError;
  bool _refreshing=false,_previewBusy=false,_importBusy=false;
  int _previewEpoch=0;
  @override void initState(){super.initState();unawaited(_refresh());unawaited(_loadPreview());}
  @override void didUpdateWidget(covariant RecoveryLibraryPage oldWidget){
    super.didUpdateWidget(oldWidget);
    if(oldWidget.pendingRestore!=widget.pendingRestore||oldWidget.store!=widget.store){
      _preview=null;_previewError=null;unawaited(_loadPreview());
      if(oldWidget.store!=widget.store){_items=null;unawaited(_refresh());}
    }
  }
  Future<void> _refresh()async{
    if(_refreshing)return;setState(()=>_refreshing=true);final store=widget.store;
    try{final rows=await store.list();if(mounted&&widget.store==store)setState((){_items=rows;_listError=null;});}
    catch(e){if(mounted&&widget.store==store)setState(()=>_listError=_recoveryError(e));}
    finally{if(mounted)setState(()=>_refreshing=false);}
  }
  Future<void> _loadPreview()async{
    final epoch=++_previewEpoch,restore=widget.pendingRestore,store=widget.store;
    if(restore==null){if(mounted)setState((){_preview=null;_previewError=null;_previewBusy=false;});return;}
    setState((){_previewBusy=true;_previewError=null;});
    try{final plan=await store.preview(restore);if(mounted&&epoch==_previewEpoch)setState(()=>_preview=plan);}
    catch(e){if(mounted&&epoch==_previewEpoch)setState((){_preview=null;_previewError=_recoveryError(e);});}
    finally{if(mounted&&epoch==_previewEpoch)setState(()=>_previewBusy=false);}
  }
  Future<void> _import()async{
    final restore=widget.pendingRestore,plan=_preview,store=widget.store;
    if(restore==null||plan==null||_importBusy||_previewBusy)return;
    var understood=false;
    final confirmed=await showDialog<bool>(context:context,builder:(dialogContext)=>StatefulBuilder(builder:(context,update)=>AlertDialog(
      title:const Text('加入独立恢复资料库？'),
      content:SingleChildScrollView(child:Column(mainAxisSize:MainAxisSize.min,crossAxisAlignment:CrossAxisAlignment.start,children:[
        Text('记录 ${plan.documentCount} 项；缺件 ${plan.missingCount} 项；原件保真待确认 ${plan.unverifiedCount} 项。'),
        const SizedBox(height:WoTokens.space3),Text(_evidenceNotice(plan.evidenceVersion)),
        const SizedBox(height:WoTokens.space3),const Text('只建立本机独立、只读的历史资料库。不会覆盖当前家庭，不恢复旧成员身份或伴侣绑定，不向家庭手机同步。'),
        const SizedBox(height:WoTokens.space3),const Text('本次归档指纹'),SelectableText(plan.fingerprint,style:const TextStyle(fontFamily:'monospace',fontSize:12)),
        CheckboxListTile(contentPadding:EdgeInsets.zero,value:understood,onChanged:(value)=>update(()=>understood=value??false),
          title:const Text('我理解资料库与正常业务恢复的区别，并确认加入这份归档')),
      ])),actions:[TextButton(onPressed:()=>Navigator.pop(dialogContext,false),child:const Text('暂不加入')),
        FilledButton(onPressed:understood?()=>Navigator.pop(dialogContext,true):null,child:const Text('确认加入独立资料库'))],
    )));
    if(confirmed!=true||!mounted)return;
    if(widget.pendingRestore!=restore||widget.store!=store||_preview?.fingerprint!=plan.fingerprint){await _loadPreview();return;}
    setState(()=>_importBusy=true);
    try{
      final workspace=await store.importVerified(restore,confirmed:true,expectedFingerprint:plan.fingerprint);
      if(!mounted||widget.store!=store)return;
      setState(()=>_items=[workspace,...?_items?.where((row)=>row.id!=workspace.id)]);
      ScaffoldMessenger.of(context).showSnackBar(WoSnackBar(content:const Text('已加入独立恢复资料库，当前家庭资料保持原样')));
      await _refresh();
    }catch(e){if(mounted)ScaffoldMessenger.of(context).showSnackBar(WoSnackBar(content:Text(_recoveryError(e))));}
    finally{if(mounted)setState(()=>_importBusy=false);}
  }
  Future<void> _open(RecoveryWorkspace workspace)async{
    await Navigator.of(context).push(MaterialPageRoute<void>(builder:(_)=>_RecoveryWorkspacePage(
      store:widget.store,workspace:workspace,backupControllerFor:widget.backupControllerFor)));
    if(mounted)await _refresh();
  }
  Widget _panel(String title,List<Widget> children)=>Padding(padding:const EdgeInsets.only(bottom:WoTokens.space4),child:WoCard(
    child:Column(crossAxisAlignment:CrossAxisAlignment.start,children:[Text(title,style:Theme.of(context).textTheme.titleMedium),const SizedBox(height:WoTokens.space3),...children])));
  @override Widget build(BuildContext context){
    final items=_items,plan=_preview;
    return WoScaffold(appBar:WoAppBar(title:const Text('独立恢复资料库'),actions:[IconButton(tooltip:'刷新资料库',onPressed:_refreshing||_importBusy?null:_refresh,icon:const Icon(Icons.refresh))]),
      body:SafeArea(top:false,child:RefreshIndicator(onRefresh:_refresh,child:ListView(physics:const AlwaysScrollableScrollPhysics(),padding:const EdgeInsets.all(WoTokens.space4),children:[
        _panel('历史资料，只在此处读取',[
          const Text('这里的资料与当前家庭业务数据库分开，不参与普通插件、提醒或手机合并。旧记录中的成员、家庭和设备标签不代表当前身份或权限。'),
          const SizedBox(height:WoTokens.space2),const Text('即使文件摘要校验成功，也不能称为完整整机恢复。'),
        ]),
        if(widget.pendingRestore!=null)_panel('待确认的已校验归档',[
          if(_previewBusy)const LinearProgressIndicator(semanticsLabel:'正在读取归档预览'),
          if(_previewError!=null)...[Text(_previewError!),TextButton(onPressed:_previewBusy||_importBusy?null:_loadPreview,child:const Text('重新读取预览'))],
          if(plan!=null)...[
            Text('来源家庭标签：${plan.sourceFamilyId}'),Text('记录 ${plan.documentCount} 项 · 缺件 ${plan.missingCount} 项 · 原件保真待确认 ${plan.unverifiedCount} 项'),
            const SizedBox(height:WoTokens.space2),Text(_evidenceNotice(plan.evidenceVersion)),
            const SizedBox(height:WoTokens.space2),const Text('归档指纹'),SelectableText(plan.fingerprint,style:const TextStyle(fontFamily:'monospace',fontSize:12)),
            const SizedBox(height:WoTokens.space3),FilledButton(onPressed:_previewBusy||_importBusy?null:_import,child:Text(_importBusy?'正在加入独立资料库…':'预览后确认加入')),
          ],
        ]),
        if(_refreshing&&items!=null)const LinearProgressIndicator(semanticsLabel:'正在静默刷新资料库'),
        if(_listError!=null)Padding(padding:const EdgeInsets.only(bottom:WoTokens.space3),child:Text(_listError!)),
        if(items==null&&_refreshing)const Center(child:Padding(padding:EdgeInsets.all(WoTokens.space4),child:WoProgressIndicator())),
        if(items!=null&&items.isEmpty)const Text('尚未加入历史归档。请在电脑备份页下载并用恢复密钥校验，再确认加入独立资料库。'),
        for(final workspace in items??<RecoveryWorkspace>[])Padding(padding:const EdgeInsets.only(bottom:WoTokens.space3),child:WoCard(
          onTap:()=>_open(workspace),child:Column(crossAxisAlignment:CrossAxisAlignment.start,children:[
            Text('历史归档 · ${workspace.documentCount} 条记录',style:Theme.of(context).textTheme.titleMedium),
            Text('来源家庭标签：${workspace.sourceFamilyId}'),Text('缺件 ${workspace.missingCount} 项 · 原件保真待确认 ${workspace.unverifiedCount} 项'),
            const SizedBox(height:WoTokens.space2),Text(_evidenceNotice(workspace.evidenceVersion)),
            const SizedBox(height:WoTokens.space2),const Text('独立只读 · 不加入当前家庭 · 不向手机同步'),
            const Align(alignment:Alignment.centerRight,child:Icon(Icons.chevron_right)),
          ]))),
      ]))));
  }
}

class _RecoveryWorkspacePage extends StatefulWidget {
  const _RecoveryWorkspacePage({required this.store,required this.workspace,this.backupControllerFor});
  final RecoveryWorkspaceStore store;final RecoveryWorkspace workspace;final RecoveryBackupController? backupControllerFor;
  @override State<_RecoveryWorkspacePage> createState()=>_RecoveryWorkspacePageState();
}
class _RecoveryWorkspacePageState extends State<_RecoveryWorkspacePage> {
  List<RecoveryDocument>? _documents;List<OwnedMediaAsset>? _assets;
  bool _loading=false,_backupBusy=false;String? _error;
  @override void initState(){super.initState();unawaited(_refresh());}
  Future<void> _refresh()async{
    if(_loading)return;setState(()=>_loading=true);
    try{final results=await Future.wait<Object>([widget.store.documents(widget.workspace.id),widget.store.assets(widget.workspace.id)]);
      if(mounted)setState((){_documents=results[0] as List<RecoveryDocument>;_assets=results[1] as List<OwnedMediaAsset>;_error=null;});
    }catch(e){if(mounted)setState(()=>_error=_recoveryError(e));}
    finally{if(mounted)setState(()=>_loading=false);}
  }
  Future<void> _backup()async{
    final load=widget.backupControllerFor;if(load==null||_backupBusy)return;setState(()=>_backupBusy=true);
    try{final controller=await load(widget.workspace.id);
      if(controller.familyId!=widget.workspace.sourceFamilyId||controller.deviceId!=widget.workspace.ownerDeviceId)throw const BackupException('recovery_backup_identity_mismatch');
      if(!mounted)return;await Navigator.of(context).push(MaterialPageRoute<void>(builder:(_)=>LocalBackupPage(controller:controller)));
    }catch(e){if(mounted)ScaffoldMessenger.of(context).showSnackBar(WoSnackBar(content:Text(_recoveryError(e))));}
    finally{if(mounted)setState(()=>_backupBusy=false);}
  }
  void _document(RecoveryDocument document){Navigator.of(context).push(MaterialPageRoute<void>(builder:(_)=>_RecoveryDocumentPage(document:document)));}
  Widget _history(){
    final rows=_documents;if(rows==null)return _initial();if(rows.isEmpty)return const Center(child:Text('此资料库没有可显示的业务记录。'));
    return ListView.builder(padding:const EdgeInsets.all(WoTokens.space4),itemCount:rows.length,itemBuilder:(context,index){final row=rows[index];
      return ListTile(key:ValueKey('${row.space}|${row.collection}|${row.id}'),leading:Icon(row.deleted?Icons.history_toggle_off:Icons.description_outlined),
        title:Text(_collectionLabel(row.collection)),subtitle:Text('记录 ${row.id}${row.deleted?' · 删除墓碑':''}'),trailing:const Icon(Icons.chevron_right),onTap:()=>_document(row));});
  }
  Widget _initial()=>Center(child:_loading?const WoProgressIndicator():Text(_error??'尚未读取资料，点击右上角刷新重试'));
  @override Widget build(BuildContext context)=>DefaultTabController(length:2,child:WoScaffold(
    appBar:WoAppBar(title:const Text('历史资料'),bottom:const TabBar(tabs:[Tab(text:'历史记录'),Tab(text:'本机原件')]),actions:[
      if(widget.backupControllerFor!=null)IconButton(tooltip:'独立资料库再备份',onPressed:_backupBusy?null:_backup,icon:const Icon(Icons.backup_outlined)),
      IconButton(tooltip:'静默刷新',onPressed:_loading?null:_refresh,icon:const Icon(Icons.refresh)),
    ]),body:SafeArea(top:false,child:Column(crossAxisAlignment:CrossAxisAlignment.stretch,children:[
      Padding(padding:const EdgeInsets.all(WoTokens.space3),child:Text('独立只读。${_evidenceNotice(widget.workspace.evidenceVersion)} 不应用到当前家庭或同步。')),
      if(_loading&&_documents!=null)const LinearProgressIndicator(semanticsLabel:'正在静默刷新历史资料'),
      if(_backupBusy)const LinearProgressIndicator(semanticsLabel:'正在打开独立资料库备份'),
      if(_error!=null)Padding(padding:const EdgeInsets.symmetric(horizontal:WoTokens.space3),child:Text(_error!)),
      Expanded(child:TabBarView(children:[_history(),_media()])),
    ]))));
  String? _openingAsset;
  Future<void> _openAsset(OwnedMediaAsset asset)async{
    if(_openingAsset!=null||asset.kind=='records')return;
    setState(()=>_openingAsset=asset.id);
    try{
      final workspaceId=widget.workspace.id;
      if(asset.workspaceId!=workspaceId)throw const BackupException('recovery_asset_scope_mismatch');
      // 所有文件都由owned store按workspace和新ID核验，绝不拼路径或使用旧照片URI。
      var file=await widget.store.media.verifiedFile(workspaceId,asset.id);
      var kind=asset.kind,thumbnailOnly=asset.kind=='thumbnail',originalUnavailable=false;
      if(file==null&&asset.thumbnailId!=null){
        file=await widget.store.media.verifiedFile(workspaceId,asset.thumbnailId!);
        kind='thumbnail';thumbnailOnly=true;originalUnavailable=true;
      }
      if(!mounted)return;
      if(file==null){ScaffoldMessenger.of(context).showSnackBar(WoSnackBar(content:const Text('原件当前不可读取，已有记录与缺件声明仍保留')));return;}
      final verified=file;
      await Navigator.of(context).push(MaterialPageRoute<void>(builder:(_)=>_RecoveryMediaPage(
        file:verified,kind:kind,thumbnailOnly:thumbnailOnly,originalUnavailable:originalUnavailable,sourceExact:asset.sourceExact)));
    }catch(e){if(mounted)ScaffoldMessenger.of(context).showSnackBar(WoSnackBar(content:Text(_recoveryError(e))));}
    finally{if(mounted)setState(()=>_openingAsset=null);}
  }
  Widget _media(){
    final assets=_assets;if(assets==null)return _initial();if(assets.isEmpty)return const Center(child:Text('此资料库没有媒体文件，缺件声明仍在记录中保留。'));
    return ListView.builder(padding:const EdgeInsets.all(WoTokens.space4),itemCount:assets.length,itemBuilder:(context,index){final asset=assets[index],opening=_openingAsset==assets[index].id;
      return ListTile(key:ValueKey(asset.id),leading:Icon(switch(asset.kind){'video'=>Icons.video_file_outlined,'photo'=>Icons.photo_outlined,'thumbnail'=>Icons.image_outlined,_=>Icons.description_outlined}),
        title:Text(_assetKind(asset.kind)),subtitle:Text(_assetStatus(asset)),
        trailing:opening?const SizedBox(width:20,height:20,child:WoProgressIndicator(strokeWidth:2)):
          asset.kind=='records'?null:const Icon(Icons.chevron_right),
        onTap:asset.kind=='records'||_openingAsset!=null?null:()=>_openAsset(asset));});
  }
}

class _RecoveryDocumentPage extends StatelessWidget {
  const _RecoveryDocumentPage({required this.document});
  final RecoveryDocument document;
  @override Widget build(BuildContext context)=>WoScaffold(appBar:WoAppBar(title:const Text('历史记录原文')),
    body:SafeArea(top:false,child:SingleChildScrollView(padding:const EdgeInsets.all(WoTokens.space4),child:Column(crossAxisAlignment:CrossAxisAlignment.start,children:[
      const Text('只读历史字段，不代表当前成员身份或授权；文本中的网址不会自动执行。'),
      const SizedBox(height:WoTokens.space3),Text('集合：${document.collection}'),Text('记录：${document.id}'),Text('原范围标签：${document.space}'),
      if(document.deleted)const Text('此项为删除墓碑，保留其历史证据，不恢复到普通插件。'),
      const SizedBox(height:WoTokens.space4),SelectableText(const JsonEncoder.withIndent('  ').convert(document.fields),style:const TextStyle(fontFamily:'monospace',fontSize:13)),
    ]))));
}

class _RecoveryMediaPage extends StatefulWidget {
  const _RecoveryMediaPage({required this.file,required this.kind,required this.thumbnailOnly,required this.originalUnavailable,required this.sourceExact});
  final File file;final String kind;final bool thumbnailOnly,originalUnavailable,sourceExact;
  @override State<_RecoveryMediaPage> createState()=>_RecoveryMediaPageState();
}
class _RecoveryMediaPageState extends State<_RecoveryMediaPage> {
  VideoPlayerController? _video;bool _ready=false,_previewFailed=false;
  @override void initState(){super.initState();if(widget.kind=='video')unawaited(_initializeVideo());}
  Future<void> _initializeVideo()async{
    final controller=VideoPlayerController.file(widget.file);_video=controller;
    try{await controller.initialize();if(mounted)setState(()=>_ready=true);}
    catch(_){if(mounted)setState(()=>_previewFailed=true);}
  }
  @override void dispose(){_video?.dispose();super.dispose();}
  Future<void> _toggle()async{final controller=_video;if(controller==null||!_ready)return;
    try{if(controller.value.isPlaying){await controller.pause();}else{await controller.play();}if(mounted)setState((){});}
    catch(_){if(mounted)setState(()=>_previewFailed=true);}
  }
  Widget _unavailable()=>const Padding(padding:EdgeInsets.all(WoTokens.space4),child:Text('归档文件字节仍保留，当前设备未能预览此格式；预览失败不表示文件缺失。',textAlign:TextAlign.center));
  Widget _videoView(){
    final controller=_video;if(_previewFailed)return _unavailable();if(!_ready||controller==null)return const WoProgressIndicator();
    return Column(mainAxisSize:MainAxisSize.min,children:[
      AspectRatio(aspectRatio:controller.value.aspectRatio>0?controller.value.aspectRatio:16/9,child:VideoPlayer(controller)),
      VideoProgressIndicator(controller,allowScrubbing:true),
      IconButton(tooltip:controller.value.isPlaying?'暂停':'播放',onPressed:_toggle,icon:Icon(controller.value.isPlaying?Icons.pause_circle_outline:Icons.play_circle_outline)),
    ]);
  }
  @override Widget build(BuildContext context)=>WoScaffold(appBar:WoAppBar(title:Text(widget.thumbnailOnly?'仅缩略图':'私有本机原件')),
    body:SafeArea(top:false,child:Column(crossAxisAlignment:CrossAxisAlignment.stretch,children:[
      Padding(padding:const EdgeInsets.all(WoTokens.space3),child:Text(widget.originalUnavailable?
        '原件不可读取，当前仅展示保留的缩略图；不能视为完整恢复。':
        widget.thumbnailOnly?'仅展示缩略图；此项不声明对应原件是否可用。':
        widget.sourceExact?'此文件已按归档摘要校验；它不代表整机业务恢复。':'已校验归档文件字节，但未确认是未改动原件。')),
      Expanded(child:Center(child:widget.kind=='video'?_videoView():InteractiveViewer(minScale:0.5,maxScale:5,
        child:Image.file(widget.file,fit:BoxFit.contain,errorBuilder:(_,__,___)=>_unavailable())))),
    ])));
}

String _evidenceNotice(int version)=>switch(version){
  1=>'v1 记录没有操作历史或授权证据，不能重建旧成员权限。',
  0=>'归档没有可用记录证据；媒体校验不等于业务恢复。',
  _=>'记录来源与历史授权仍未证实，不能据此恢复旧成员权限。',
};
String _collectionLabel(String collection){
  final parts=collection.split('/').where((part)=>part.isNotEmpty).toList();
  return parts.length>2?parts.skip(2).join('/'):'历史记录';
}
String _assetKind(String kind)=>switch(kind){'photo'=>'照片原件','video'=>'视频原件','thumbnail'=>'缩略图',_=>'记录归档原字节'};
String _assetStatus(OwnedMediaAsset asset){
  if(!asset.available)return '${switch(asset.status){'copying'=>'复制尚未完成','failed'=>'复制未完成，可从同一归档重试',_=>'缺件或当前不可读取'}}；已有文字记录保留';
  if(asset.kind=='records')return '原始记录字节已保留；可在历史记录页阅读或独立再备份';
  if(asset.kind=='thumbnail')return '缩略图字节已保存；不表示原件存在';
  return asset.sourceExact?'已保存，打开前重新校验摘要':'已保存，原件保真待确认';
}
String _recoveryError(Object error){
  final code=error is BackupException?error.code:error is OwnedMediaException?error.code:'';
  return switch(code){
    'recovery_confirmation_changed'=>'归档与确认时不一致，未导入。请重新读取预览。',
    'recovery_confirmation_required'=>'需要先预览并明确确认，当前资料未被覆盖。',
    'unsupported_recovery_evidence'=>'这份记录证据格式暂不支持，未加入资料库。',
    'recovery_records_integrity'=>'记录文件摘要不匹配，未加入资料库。',
    'recovery_unknown_schema'=>'归档含当前未支持的记录类型，未作为成功导入。',
    'recovery_backup_identity_mismatch'=>'独立资料库的备份身份不匹配，没有使用当前家庭替代。',
    'private_acl_unavailable'=>'此平台未验证私有目录权限，已停止打开或写入明文。',
    _=>'操作未完成，现有资料保持原样。请核对同一已校验归档后显式重试。',
  };
}
