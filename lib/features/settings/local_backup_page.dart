import 'dart:async';
import 'package:flutter/material.dart';
import '../../local/backup/backup_models.dart';
import '../../local/backup/mobile_backup_controller.dart';
import '../../local/backup/recovery_workspace.dart';
import 'recovery_library_page.dart';
import '../../theme/wo_tokens.dart';
import '../../widgets/wo_card.dart';

class LocalBackupPage extends StatefulWidget {
  const LocalBackupPage({super.key,required this.controller,this.recoveryStore,this.recoveryBackupControllerFor});
  final MobileBackupController controller;
  final Future<RecoveryWorkspaceStore> Function()? recoveryStore;
  final Future<MobileBackupController> Function(String)? recoveryBackupControllerFor;
  @override State<LocalBackupPage> createState()=>_LocalBackupPageState();
}
class _LocalBackupPageState extends State<LocalBackupPage> {
  final _origin=TextEditingController(),_pin=TextEditingController(),_code=TextEditingController(),_family=TextEditingController(),_importKey=TextEditingController();
  bool _allowPublic=false;
  MobileBackupController get c=>widget.controller;
  @override void initState(){super.initState();_family.text=c.familyId;c.addListener(_changed);unawaited(_initialize());}
  void _changed(){if(mounted)setState((){});}
  Future<void> _initialize()async{
    if(!c.busy)await _perform(c.load);
    if(!mounted)return;final computer=c.computer;if(computer!=null){_origin.text=computer.origin.toString();_pin.text=computer.pin;_family.text=computer.familyId;}if(mounted)setState((){});
  }
  @override void dispose(){c.removeListener(_changed);for(final field in [_origin,_pin,_code,_family,_importKey]){field.dispose();}super.dispose();}
  Future<void> _perform(Future<dynamic> Function() action)async{
    try{await action();}catch(e){if(mounted)ScaffoldMessenger.of(context).showSnackBar(WoSnackBar(content:Text(_errorText(e is BackupException?e:null))));}
  }
  Future<void> _pair()async{
    final code=_code.text.trim();_code.clear();
    await _perform(()=>c.pair(origin:Uri.parse(_origin.text.trim()),pin:_pin.text.trim().toLowerCase(),oneTimeCode:code,targetFamilyId:_family.text.trim()));
  }
  Future<void> _showKey()async{
    try{final key=await c.revealRecoveryKey();if(!mounted)return;
      final saved=await showDialog<bool>(context:context,builder:(context)=>AlertDialog(
        title:const Text('保存恢复密钥'),content:SingleChildScrollView(child:Column(mainAxisSize:MainAxisSize.min,crossAxisAlignment:CrossAxisAlignment.start,children:[
          const Text('请另存到你独立控制的安全位置，不发送给共享电脑。只有本机保存的密钥引用，无法在手机丢失后恢复。'),
          const SizedBox(height:WoTokens.space4),SelectableText(key,style:const TextStyle(fontFamily:'monospace')),
        ])),actions:[TextButton(onPressed:()=>Navigator.pop(context,false),child:const Text('关闭，尚未另存')),
          FilledButton(onPressed:()=>Navigator.pop(context,true),child:const Text('我已另存到安全位置'))]));
      if(saved==true)await _perform(c.acknowledgeRecoveryKeySaved);
    }catch(_){if(mounted)ScaffoldMessenger.of(context).showSnackBar(WoSnackBar(content:Text(_errorText(c.error))));}
  }
  Future<void> _openRecoveryLibrary()async{
    final factory=widget.recoveryStore;if(factory==null)return;
    await _perform(()async{final store=await factory();if(!mounted)return;
      await Navigator.of(context).push(MaterialPageRoute<void>(builder:(_)=>RecoveryLibraryPage(
        store:store,pendingRestore:c.lastRestore,backupControllerFor:widget.recoveryBackupControllerFor)));
    });
  }
  Future<void> _import()async{final value=_importKey.text.trim();_importKey.clear();await _perform(()=>c.importRecoveryKey(value));}
  Future<void> _discardUpload()async{
    final yes=await showDialog<bool>(context:context,builder:(context)=>AlertDialog(title:const Text('放弃这次续传？'),
      content:const Text('本机会释放这次冻结的备份来源。电脑上已接收的片段不会删除，手机原资料不受影响。'),
      actions:[TextButton(onPressed:()=>Navigator.pop(context,false),child:const Text('继续保留')),
        TextButton(onPressed:()=>Navigator.pop(context,true),child:const Text('放弃续传'))]));
    if(yes==true)await _perform(c.discardPendingUpload);
  }
  Widget _section(String title,List<Widget> children)=>Padding(padding:const EdgeInsets.only(bottom:WoTokens.space4),child:WoCard(
    child:Column(crossAxisAlignment:CrossAxisAlignment.start,children:[Text(title,style:Theme.of(context).textTheme.titleMedium),const SizedBox(height:WoTokens.space3),...children])));
  Widget _field(TextEditingController value,String label,{bool secret=false,String? hint,int? maxLength})=>Padding(padding:const EdgeInsets.only(bottom:WoTokens.space3),
    child:TextField(controller:value,enabled:!c.busy,obscureText:secret,autocorrect:false,enableSuggestions:false,maxLength:maxLength,
      onChanged:(_)=>setState((){}),keyboardType:secret?TextInputType.visiblePassword:TextInputType.text,decoration:InputDecoration(labelText:label,hintText:hint)));
  bool get _destinationMatches {final p=c.computer;return p!=null&&_origin.text.trim()==p.origin.toString()&&_pin.text.trim().toLowerCase()==p.pin&&_family.text.trim()==p.familyId;}
  @override Widget build(BuildContext context){
    final paired=c.computer,result=c.lastRestore;
    return WoScaffold(appBar:WoAppBar(title:const Text('电脑备份与恢复校验')),body:SafeArea(top:false,child:ListView(
      padding:const EdgeInsets.all(WoTokens.space4),children:[
        const Padding(padding:EdgeInsets.only(bottom:WoTokens.space4),child:Text('资料继续保存在手机。电脑只接收你主动发起的备份，不反向覆盖手机。')),
        if(c.busy)...[LinearProgressIndicator(semanticsLabel:_phaseText(c.phase)),const SizedBox(height:WoTokens.space2),Text(_phaseText(c.phase)),const SizedBox(height:WoTokens.space4)],
        if(c.error!=null)_section('这次操作尚未完成',[Text(_errorText(c.error))]),
        if(c.cleanupWarning)_section('暂存清理未完成',[const Text('部分本机暂存未能清理。已校验的电脑归档状态以列表为准；这不代表已经删除暂存字节。')]),
        _section('配对电脑',[
          if(paired!=null)...[Text('当前电脑：${paired.origin}'),Text('归档所属家庭：${paired.familyId}'),const SizedBox(height:WoTokens.space3)],
          _field(_origin,'电脑 HTTPS 地址',hint:'https://192.168.1.10:9443'),
          _field(_pin,'电脑证书 SHA-256 指纹',hint:'核对电脑显示的 64 位指纹',maxLength:64),
          _field(_family,'电脑配对码所属家庭',hint:'当前家庭备份，或你要取回的归档家庭'),
          _field(_code,'电脑生成的一次配对码',secret:true,maxLength:64),
          const Text('请在电脑端明确核对地址、证书指纹与配对家庭。取回旧家庭归档不会替换本机当前家庭。'),
          const SizedBox(height:WoTokens.space3),Wrap(spacing:WoTokens.space3,runSpacing:WoTokens.space2,children:[
            FilledButton(onPressed:c.busy?null:_pair,child:const Text('核对并配对')),
            if(paired!=null)TextButton(onPressed:c.busy?null:()=>_perform(c.forgetComputer),child:const Text('移除本机配对凭据')),
          ]),if(paired!=null)const Text('移除凭据不会撤销电脑端设备记录；重新配对前可能需要在电脑移除旧记录。'),
          if(paired!=null&&!_destinationMatches)const Text('地址、指纹或家庭已修改，请先配对新设置；备份仍只使用当前已配对电脑。'),
        ]),
        _section('恢复密钥',[
          Text(!c.hasRecoveryKey?'尚未设置恢复密钥':c.recoveryKeySavedAcknowledged?'你已确认另存恢复密钥':'目前只有本机密钥；尚未确认另存'),
          const Text('私密、伴侣内容和记录会加密后备份。电脑不持有这把密钥。'),
          const SizedBox(height:WoTokens.space3),Wrap(spacing:WoTokens.space3,runSpacing:WoTokens.space2,children:[
            if(!c.hasRecoveryKey)OutlinedButton(onPressed:c.busy?null:()=>_perform(c.createRecoveryKey),child:const Text('创建恢复密钥')),
            if(c.hasRecoveryKey)OutlinedButton(onPressed:c.busy?null:_showKey,child:const Text('查看并另存恢复密钥')),
          ]),const SizedBox(height:WoTokens.space3),
          _field(_importKey,'导入你已保管的 64 位恢复密钥',secret:true,maxLength:64),
          TextButton(onPressed:c.busy?null:_import,child:const Text('导入到本机安全存储')),
          const Text('导入只选择当前用于校验的密钥，不改写电脑归档。导入后请再次查看并确认保管，才能发起新备份。'),
        ]),
        _section('发起备份',[
          CheckboxListTile(contentPadding:EdgeInsets.zero,value:_allowPublic,onChanged:c.busy||c.hasPendingUpload?null:(v)=>setState(()=>_allowPublic=v??false),
            title:const Text('允许电脑直接读取家庭公开照片与视频'),subtitle:const Text('默认不开放明文；私密、伴侣媒体与全部记录始终加密。')),
          FilledButton(onPressed:c.busy||!_destinationMatches||c.hasPendingUpload||!c.recoveryKeySavedAcknowledged?null:
            ()=>_perform(()=>c.startBackup(allowPublicMediaOnComputer:_allowPublic)),child:const Text('备份当前授权资料到电脑')),
          if(!c.recoveryKeySavedAcknowledged)const Text('请先设置并另存恢复密钥。'),
          if(paired!=null&&paired.familyId!=c.familyId)const Text('当前配对用于取回其它家庭的归档；发起本家庭备份需重新配对。'),
          if(c.hasPendingUpload)...[
            const SizedBox(height:WoTokens.space3),const Text('这次备份保留了同一份加密归档与原件快照，可以显式续传。重启 App 后会核对同一身份、电脑指纹和密钥，再续传同一份冻结字节；不会自动重新加密。'),
            Wrap(spacing:WoTokens.space3,children:[OutlinedButton(onPressed:c.busy?null:()=>_perform(c.retryUpload),child:const Text('续传这次备份')),
              TextButton(onPressed:c.busy?null:_discardUpload,child:const Text('放弃这次续传'))]),
          ],
          for(final note in c.coverageNotes)Padding(padding:const EdgeInsets.only(top:WoTokens.space2),child:Text(note)),
          for(final omitted in c.omittedScopes)Padding(padding:const EdgeInsets.only(top:WoTokens.space2),child:Text('未包含：$omitted')),
          for(final issue in c.sourceIssuesByReason.entries)Text('${_missingText(issue.key)}：${issue.value} 项'),
          if(c.lastUpload!=null)...[const SizedBox(height:WoTokens.space3),Text(c.lastUpload!.scope=='opaque_restricted_unverified'
            ?'电脑已保存并校验密文字节；内层内容仍须持钥手机验证。':'电脑已校验本次声明的文件字节。'),
            if(!c.lastUpload!.complete)const Text('存在缺件、原件保真未确认或受限密文，不能称完整备份。'),
            const Text('本次结果不代表整机插件资料或业务恢复已经完成。')],
        ]),
        _section('电脑上的归档',[
          OutlinedButton(onPressed:c.busy||!_destinationMatches?null:()=>_perform(c.refreshBackups),child:const Text('读取归档列表')),
          if(c.backups.isEmpty)const Text('尚未读取到可显示的归档。'),
          for(final backup in c.backups)Padding(padding:const EdgeInsets.only(top:WoTokens.space3),child:Column(crossAxisAlignment:CrossAxisAlignment.start,children:[
            Text('备份 ${backup.backupId}',style:Theme.of(context).textTheme.bodyMedium),Text(_statusText(backup)),
            if(backup.verifiedAt.isNotEmpty)Text('最近字节校验：${backup.verifiedAt}'),
            TextButton(onPressed:c.busy||!_destinationMatches||backup.verifiedAt.isEmpty?null:()=>_perform(()=>c.downloadBackup(backup.backupId)),child:const Text('下载并校验到本机隔离区')),
          ])),
        ]),
        if(c.hasDownload||c.canRetryDownload)_section('本机隔离校验',[
          Text(c.downloadVerified?'已核对下载文件全文摘要。尚未导入相册或资料库。':'下载尚未完整校验，不能作为恢复结果。'),
          Wrap(spacing:WoTokens.space3,children:[OutlinedButton(onPressed:c.busy?null:()=>_perform(c.retryDownload),child:const Text('继续下载与校验')),
            TextButton(onPressed:c.busy?null:()=>_perform(c.discardDownloadCache),child:const Text('清理这次下载缓存'))]),
          for(final entry in c.downloadedEntries.where((e)=>e.missing.isNotEmpty))Text(_missingText(entry.missing)),
          for(final entry in c.downloadedSealedEntries)OutlinedButton(onPressed:c.busy||!c.downloadVerified||!c.hasRecoveryKey||c.lastRestore!=null?null:
            ()=>_perform(()=>c.verifyRestrictedRestore(entry.id)),child:const Text('用恢复密钥验证并解包到新隔离区')),
          const Text('没有自动导入或覆盖现有资料的操作。恢复密钥错误或内容损坏时不会发布成功结果。'),
        ]),
        if(result!=null)_section('受限归档已验证，尚未导入',[
          Text('新隔离文件 ${result.files.length} 项；缺失 ${result.missing.length} 项；原件保真待确认 ${result.unverifiedOriginals.length} 项。'),
          const Text('已生成新文件和身份。记录仍是惰性归档，没有写入现有数据库；不会沿用旧照片权限、URI 或设备身份。'),
          const Text('受限内容继续保持受限，不自动恢复伴侣绑定或改成全家可见。'),
          if(!result.declaredBytesComplete)const Text('声明内容仍不完整。已有缩略图和缺件声明保留，缺原件不冒充完整。'),
          const Text('此入口只处理持钥验证的加密归档内部条目；外层公开备份文件尚未纳入资料库。缺少原操作或撤权证明时，禁止恢复为正常家庭业务库。'),
          if(widget.recoveryStore!=null)OutlinedButton(onPressed:c.busy?null:_openRecoveryLibrary,child:const Text('预览并确认保存为私有只读资料库')),
        ]),
      ])));
  }
}
String _phaseText(MobileBackupPhase phase)=>switch(phase){
  MobileBackupPhase.idle=>'等待操作',MobileBackupPhase.loading=>'正在读取本机设置或归档状态',MobileBackupPhase.pairing=>'正在核对电脑并配对',
  MobileBackupPhase.preparing=>'正在冻结来源并准备加密归档',MobileBackupPhase.uploading=>'正在上传，失败后可保留本次来源续传',
  MobileBackupPhase.downloading=>'正在下载并校验隔离缓存',MobileBackupPhase.verifying=>'正在验证恢复密钥与归档',
  MobileBackupPhase.completed=>'本次操作完成',MobileBackupPhase.failed=>'本次操作尚未完成'};
String _statusText(BackupStatus status)=>switch(status.state){'uploading'=>'上传未完成','unreadable'=>'归档当前无法读取',
  _=>status.scope=='opaque_restricted_unverified'?'密文字节已校验，内层尚待持钥验证':status.complete?'声明的公开文件已校验':'缺件或原件保真未确认'};
String _missingText(String reason)=>switch(reason){'permission_denied'=>'原件读取权限被拒绝','cloud_only'=>'原件仅在云端，当前未读到',
  'not_exact_original'=>'未能确认取得未改动原件','not_on_device'=>'当前设备没有可读取原件','source_not_exact'=>'原件保真尚未确认',_=>'原件当前不可读取'};
String _errorText(BackupException? error){
  if(error?.httpStatus==401||error?.httpStatus==403)return '配对凭据无效、已撤销或范围不匹配，请核对电脑端授权。';
  return switch(error?.code){
    'certificate_pin_mismatch'=>'证书指纹不匹配，没有发送配对码或资料。请重新核对电脑显示的指纹。',
    'invalid_pair_request'=>'请填写有效家庭标识及电脑生成的 64 位配对码。',
    'explicit_https_and_pin_required'=>'请填写明确的 HTTPS 地址和 64 位证书指纹。',
    'pair_outcome_unknown'=>'配对结果不确定，一次码可能已消费。请在电脑核对设备记录并生成新的配对码。',
    'pair_saved_on_computer_but_local_save_failed'=>'电脑可能已登记本机，但本机未能保存凭据。请在电脑移除该设备后重新配对。',
    'recovery_key_not_saved'=>'请先另存恢复密钥并明确确认。只保存在旧手机里的引用不能用于丢机恢复。',
    'recovery_key_unavailable'=>'本机没有可用恢复密钥，请导入你独立保管的密钥。',
    'invalid_recovery_key'=>'恢复密钥应为 64 位十六进制内容。',
    'vault_authentication_failed'=>'密钥、归档所属家庭或密文认证不匹配，没有生成已验证恢复结果。',
    'frozen_backup_already_pending'=>'已有冻结备份等待续传；请续传或明确放弃，不能同时准备另一份原件快照。',
    'finish_or_discard_pending_job'=>'请先完成或明确放弃当前上传/下载任务，再更换电脑。',
    'discard_previous_download_first'=>'请先清理上一次下载缓存，再选择另一份归档。',
    'paired_family_is_restore_only'=>'当前配对家庭与本机家庭不同，只可用于取回归档。',
    'pending_upload_binding_changed'=>'续传与当前身份、家庭、电脑或密钥不匹配，已停止；请使用原授权配置处理原任务。',
    'pending_upload_not_ready'=>'上次冻结尚未完成；请显式放弃这次任务，再生成新的备份。',
    'pending_upload_source_changed'=>'续传来源已损坏或改变，未上传；请显式放弃这次任务。',
    'pending_upload_authentication_failed'=>'本机续传记录认证失败，未恢复任务或发送资料。',
    'source_changed'=>'冻结来源已改变，未作为成功备份提交。请放弃这次续传后重新准备。',
    'private_acl_unavailable'=>'此平台的私有恢复目录尚未通过权限校验，已停止写入明文。',
    _=>'操作未完成，资料仍保留在本机。请核对配置、网络与原件权限后显式重试。',
  };
}
