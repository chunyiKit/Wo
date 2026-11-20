import 'dart:async';
import 'dart:io';
import 'package:flutter/foundation.dart';
import '../local_store.dart';
import '../transport/native_local.dart';
import 'peer_registry.dart';
import 'sync_policy.dart';
import 'sync_wire.dart';

/// 前台发现/连接只是传输适配；身份/范围由registry、业务增量由strategy决定。
class LocalSyncCoordinator extends ChangeNotifier {
  LocalSyncCoordinator({required this.store,required this.registry,required this.crypto,
    required this.discovery,required this.strategy,this.onChanged});
  final LocalStore store;final PeerRegistry registry;final LocalCrypto crypto;
  final NativeDiscovery discovery;final IncrementalSyncStrategy strategy;
  final Future<void> Function()? onChanged;
  ServerSocket? _server;StreamSubscription<Socket>? _listener;
  StreamSubscription<LocalDiscoveryEvent>? _discovered;Timer? _timer;
  final _hints=<String,LocalDiscoveryEvent>{},_busy=<String,Object>{},_sockets=<Socket>{};
  final _incomingSockets=<Socket>{},_tasks=<Future<void>>{};
  final _sessions=<String,_PeerSession>{};
  final _manualHints=<String,LocalDiscoveryEvent>{};
  final _lastContact=<String,DateTime>{};
  static const _directionGrace=Duration(seconds:15);
  static const _sessionBudget=Duration(minutes:2);
  Future<void> _lifecycle=Future<void>.value();
  bool _running=false,_disposed=false;int _generation=0,_readyGeneration=0,_cursor=0;
  String _status='前台局域网同步尚未启动';
  String get status=>_status;int? get port=>_server?.port;
  DateTime? lastContact(String linkId)=>_lastContact[linkId];
  /// 仅枚举本机接口，不查询SSID/位置或访问网络；结果仅用于本页人工核对。
  Future<List<String>> localAddresses()async{
    try{
      final interfaces=await NetworkInterface.list(includeLoopback:false,includeLinkLocal:true,type:InternetAddressType.any);
      final found=<String>{};
      for(final network in interfaces){for(final address in network.addresses){
        if(!address.isLoopback&&localAddress(address))found.add(address.address);
      }}
      final values=found.toList()..sort((a,b){final av4=InternetAddress.tryParse(a)?.type==InternetAddressType.IPv4,bv4=InternetAddress.tryParse(b)?.type==InternetAddressType.IPv4;return av4==bv4?a.compareTo(b):av4?-1:1;});
      return values.take(16).toList();
    }catch(_){return const [];}
  }
  /// 只对已经逐对授权的link重试；未发现地址时不猜测主机或扩大信任。
  Future<void> syncNow({String? peerId})async{
    await start();final epoch=_generation;if(!_alive(epoch)||_readyGeneration!=epoch)return;
    _message('正在尝试已授权设备；未发现时请核对局域网权限、保持两端前台或手动填写地址',epoch);
    await _connectKnown(epoch,force:true,peerId:peerId);
  }
  Future<void> connectManually(PeerLink peer,String address,int port)async{
    final epoch=_generation;if(!_alive(epoch))return;
    final ip=InternetAddress.tryParse(address);
    if(ip==null||!localAddress(ip)||port<1||port>65535)throw const FormatException('手动地址须为私有局域网IP');
    final current=(await registry.links()).where((link)=>link.id==peer.id&&link.active&&link.familyId==peer.familyId&&link.remoteDeviceId==peer.remoteDeviceId).firstOrNull;
    if(current==null)throw const FormatException('配对已失效');
    await registry.scopes(current);if(!_alive(epoch))return;
    // 用户明确提供的提示只在本次前台内存存在，后台/暂停即清；身份仍须PSK握手。
    _manualHints[current.remoteDeviceId]=LocalDiscoveryEvent(event:'found',deviceId:current.remoteDeviceId,address:ip.address,port:port);
    _message('已保留本次前台地址提示，正在核对已配对设备',epoch);
    await connect(current,ip.address,port);
  }
  Object? _claimSession(PeerLink peer,Socket socket,bool client){
    final preferred=client?store.deviceId.compareTo(peer.remoteDeviceId)<0:peer.remoteDeviceId.compareTo(store.deviceId)<0;
    final old=_sessions[peer.id];
    if(old!=null){
      if(!preferred||old.preferred)return null;
      old.socket.destroy(); // 双方并发拨号时保留同一个“较小ID发起”的方向。
    }
    final token=Object();_sessions[peer.id]=_PeerSession(socket,token,preferred);return token;
  }
  void _releaseSession(String id,Object? token){if(token!=null&&identical(_sessions[id]?.token,token))_sessions.remove(id);}

  bool _alive(int epoch)=>!_disposed&&_running&&epoch==_generation;
  void _check(int epoch){if(!_alive(epoch))throw StateError('同步前台会话已结束');}
  void _message(String text,[int? epoch]){
    if(_disposed||epoch!=null&&!_alive(epoch))return;
    _status=text;notifyListeners();
  }
  Future<void> _queueLife(Future<void> Function() action){
    final result=Completer<void>();
    _lifecycle=_lifecycle.then((_)async{try{await action();result.complete();}catch(e,s){result.completeError(e,s);}});
    return result.future;
  }
  Future<void> _track(Future<void> task){
    _tasks.add(task);
    unawaited(task.then<void>((_){_tasks.remove(task);},onError:(Object _,StackTrace __){_tasks.remove(task);}));
    return task;
  }
  Future<void> start(){
    if(_disposed||_running)return Future<void>.value();
    _running=true;final epoch=++_generation;
    return _queueLife(()=>_start(epoch));
  }
  Future<void> _start(int epoch)async{
    if(!_alive(epoch))return;
    try{
      ServerSocket bound;
      try{bound=await ServerSocket.bind(InternetAddress.anyIPv6,0,v6Only:false,shared:false);}
      catch(_){if(!_alive(epoch))return;bound=await ServerSocket.bind(InternetAddress.anyIPv4,0,shared:false);}
      if(!_alive(epoch)){await bound.close();return;}
      _server=bound;_readyGeneration=epoch;
      _listener=bound.listen((socket){
        if(!_alive(epoch)||_incomingSockets.length>=4){socket.destroy();return;}
        _incomingSockets.add(socket);
        unawaited(_track(_serve(socket,epoch)).then<void>((_){_incomingSockets.remove(socket);},onError:(Object _,StackTrace __){_incomingSockets.remove(socket);}));
      },onError:(Object _){_message('本机同步监听暂不可用',epoch);});
      _discovered=discovery.events.listen((event){
        if(!_alive(epoch)||event.deviceId==store.deviceId)return;
        if(event.event=='lost'){_hints.remove(event.deviceId);}
        else{
          // 平台若给出多个地址，保留可用 IPv4；绝不把地址提示当作已认证设备。
          final old=_hints[event.deviceId],next=InternetAddress.tryParse(event.address);
          final previous=old==null?null:InternetAddress.tryParse(old.address);
          if(next==null||!localAddress(next))return;
          if(previous?.type!=InternetAddressType.IPv4||next?.type==InternetAddressType.IPv4){
            if(_hints.containsKey(event.deviceId)||_hints.length<128)_hints[event.deviceId]=event;
          }
          unawaited(_connectKnown(epoch));
        }
      },onError:(Object _){_message('局域网发现不可用，可核对系统权限或手动连接',epoch);});
      try{await discovery.start(serviceName:store.deviceId,port:bound.port);_message('前台已就绪，等待已授权设备',epoch);}
      catch(_){_message('系统尚未允许局域网发现，已保留本机资料',epoch);}
      if(!_alive(epoch))return;
      _timer=Timer.periodic(const Duration(seconds:3),(_){if(_alive(epoch))unawaited(_connectKnown(epoch));});
      await _connectKnown(epoch);
    }catch(_){
      if(_alive(epoch)){_message('局域网启动未完成，本机读写仍可用',epoch);_running=false;_readyGeneration=0;_generation++;await _cleanup();}
    }
  }
  Future<void> stop(){
    // 立即失效旧异步工作；串行清理完才允许下一代绑定/广告，避免旧stop关闭新start。
    _running=false;_readyGeneration=0;_generation++;_timer?.cancel();_timer=null;_hints.clear();_manualHints.clear();_lastContact.clear();_message('前台局域网同步已暂停，手动地址提示已清除');
    for(final socket in _sockets.toList()){socket.destroy();}
    return _queueLife(_cleanup);
  }
  Future<void> _cleanup()async{
    _timer?.cancel();_timer=null;
    final discovered=_discovered,listener=_listener,server=_server;
    _discovered=null;_listener=null;_server=null;
    for(final socket in _sockets.toList()){socket.destroy();}
    try{await discovered?.cancel();}catch(_){}
    try{await discovery.stop();}catch(_){}
    try{await listener?.cancel();}catch(_){}
    try{await server?.close();}catch(_){}
    // stop完成后runtime才可关SQLite；不让已开始的merge回调悬在已关闭的store上。
    final tasks=_tasks.toList();if(tasks.isNotEmpty){await Future.wait(tasks.map((t)=>t.catchError((Object _){})));}
    _sockets.clear();_incomingSockets.clear();_busy.clear();_hints.clear();_manualHints.clear();_sessions.clear();_lastContact.clear();
  }
  static bool localAddress(InternetAddress address){
    if(address.isLoopback)return true;final b=address.rawAddress;
    bool ipv4(int at)=>b[at]==127||b[at]==10||b[at]==172&&b[at+1]>=16&&b[at+1]<=31||
      b[at]==192&&b[at+1]==168||b[at]==169&&b[at+1]==254;
    if(b.length==4)return ipv4(0);
    if(b.length==16&&b.take(10).every((x)=>x==0)&&b[10]==255&&b[11]==255)return ipv4(12);
    return b.length==16&&((b[0]&254)==252||b[0]==254&&(b[1]&192)==128);
  }
  Future<void> _connectKnown(int epoch,{bool force=false,String? peerId})async{
    if(!_alive(epoch))return;List<PeerLink> links;
    try{links=await registry.links();}catch(_){_message('配对资料需要核对，未向未知设备发送数据',epoch);return;}
    if(!_alive(epoch)||links.isEmpty)return;
    _cursor%=links.length;final ordered=[...links.skip(_cursor),...links.take(_cursor)];var started=0;
    for(final peer in ordered){
      if(!_alive(epoch))return;
      if(peerId!=null&&peer.id!=peerId)continue;
      final hint=_manualHints[peer.remoteDeviceId]??_hints[peer.remoteDeviceId];if(!peer.active||hint==null||_busy.containsKey(peer.id)||_sessions.containsKey(peer.id))continue;
      bool pending;try{pending=await store.privateValue('sync-pending-family:${peer.id}')==true;}catch(_){_message('配对资料暂不可读，保留本机记录等待重试',epoch);return;}
      if(!_alive(epoch))return;
      // 已知家庭扫码接受方可能ID较大，而邀请方尚无link；首次必须允许其主动握手。
      // 正常联系后由较小ID维持轮询；长期未成功联系允许反向拨号，容忍单向发现丢失。
      final contacted=_lastContact[peer.id],elapsed=contacted==null?null:DateTime.now().toUtc().difference(contacted);
      if(!force&&!pending&&store.deviceId.compareTo(peer.remoteDeviceId)>0&&elapsed!=null&&!elapsed.isNegative&&elapsed<_directionGrace)continue;
      if(_busy.length>=3)break;
      unawaited(connect(peer,hint.address,hint.port));_cursor=(links.indexOf(peer)+1)%links.length;if(++started>=3)break;
    }
  }
  Future<void> connect(PeerLink peer,String address,int port){
    final epoch=_generation;
    if(!_alive(epoch)||_readyGeneration!=epoch||_busy.containsKey(peer.id)||_sessions.containsKey(peer.id)||_busy.length>=3)return Future<void>.value();
    final ip=InternetAddress.tryParse(address);
    if(ip==null||!localAddress(ip)||port<1||port>65535){_message('未连接非私有局域网广告，可核对Wi-Fi地址',epoch);return Future<void>.value();}
    final token=Object();_busy[peer.id]=token;
    return _track(_connect(peer,ip,port,epoch,token));
  }
  Future<void> _connect(PeerLink peer,InternetAddress ip,int port,int epoch,Object token)async{
    Socket? socket;SecureSyncChannel? channel;WireFrames? frames;Object? lease;Timer? budget;var dirty=false;
    try{
      socket=await Socket.connect(ip,port,timeout:const Duration(seconds:8));
      if(!_alive(epoch)){socket.destroy();return;}
      _sockets.add(socket);final connected=socket;budget=Timer(_sessionBudget,()=>connected.destroy());frames=WireFrames(socket);
      channel=await SecureSyncChannel.authenticate(frames:frames,crypto:crypto,registry:registry,client:true,outgoing:peer);_check(epoch);
      lease=_claimSession(channel.link,socket,true);if(lease==null)return;
      final changed=await _clientRounds(channel,epoch,(){dirty=true;});_check(epoch);
      final joined=await _joinIfReady(peer,epoch);_check(epoch);
      if((changed||joined||dirty)&&_alive(epoch)){await onChanged?.call();dirty=false;}
      _lastContact[peer.id]=DateTime.now().toUtc();_message('已完成本轮授权增量合并',epoch);
    }catch(_){if(lease==null||identical(_sessions[peer.id]?.token,lease))_message('同步未完成，将保留本机记录并在前台重试',epoch);}
    finally{
      budget?.cancel();_releaseSession(peer.id,lease);
      try{if(channel!=null){await channel.close();}else{await frames?.close();}}catch(_){}
      socket?.destroy();if(socket!=null)_sockets.remove(socket);
      if(identical(_busy[peer.id],token))_busy.remove(peer.id);
      // 已提交的增量不因后续断线丢失权限刷新；后台epoch失效则交给回前台读取。
      if(dirty&&_alive(epoch)){try{await onChanged?.call();}catch(_){}}
    }
  }
  Future<void> _serve(Socket socket,int epoch)async{
    if(!_alive(epoch)||!localAddress(socket.remoteAddress)){socket.destroy();return;}
    _sockets.add(socket);final frames=WireFrames(socket);SecureSyncChannel? channel;Object? lease;var dirty=false;
    final budget=Timer(_sessionBudget,()=>socket.destroy());
    try{
      final known=(await registry.links()).map((p)=>p.id).toSet();_check(epoch);
      channel=await SecureSyncChannel.authenticate(frames:frames,crypto:crypto,registry:registry,client:false);_check(epoch);
      dirty=!known.contains(channel.link.id);
      lease=_claimSession(channel.link,socket,false);if(lease==null)return;
      final changed=await _serverRounds(channel,epoch,(){dirty=true;});_check(epoch);
      final joined=await _joinIfReady(channel.link,epoch);_check(epoch);
      if((changed||joined||dirty)&&_alive(epoch)){await onChanged?.call();dirty=false;}
      _lastContact[channel.link.id]=DateTime.now().toUtc();_message('已完成本轮授权增量合并',epoch);
    }catch(_){if(lease==null||identical(_sessions[channel?.link.id]?.token,lease))_message('未接受未认证或不完整的同步请求',epoch);}
    finally{budget.cancel();if(channel!=null)_releaseSession(channel.link.id,lease);try{if(channel!=null){await channel.close();}else{await frames.close();}}catch(_){}socket.destroy();_sockets.remove(socket);if(dirty&&_alive(epoch)){try{await onChanged?.call();}catch(_){}}}
  }
  Future<void> _offers(SecureSyncChannel channel,int epoch,void Function() touched)async{
    _check(epoch);final peer=channel.link;
    await registry.scopes(peer);_check(epoch);
    final local=(await registry.links()).where((p)=>p.id==peer.id&&p.active).firstOrNull;_check(epoch);
    if(local==null)throw const FormatException('配对已撤销');
    if(channel.client){await channel.send({'t':'offer','couple':local.coupleLocal});_check(epoch);}
    final offer=await channel.receive();_check(epoch);
    if(offer.length!=2||offer['t']!='offer'||offer['couple'] is! bool)throw const FormatException('受限范围确认无效');
    if(local.coupleRemote!=offer['couple'])touched();
    await registry.coupleConsent(peer.id,remote:offer['couple'] as bool);_check(epoch);
    if(!channel.client){await channel.send({'t':'offer','couple':local.coupleLocal});_check(epoch);}
  }
  Future<bool> _clientRounds(SecureSyncChannel channel,int epoch,void Function() touched)async{
    var changed=false;await _offers(channel,epoch,touched);
    for(var round=0;round<16;round++){
      _check(epoch);final local=await strategy.state(channel.link);_check(epoch);await channel.send(local);_check(epoch);
      final remote=await channel.receive();_check(epoch);
      final outgoing=await strategy.delta(channel.link,remote);_check(epoch);await channel.send(outgoing);_check(epoch);
      final incoming=await channel.receive();_check(epoch);
      if((incoming['ops'] as List).isNotEmpty||(incoming['thumbs'] as List).isNotEmpty)touched();
      _check(epoch);await strategy.apply(channel.link,incoming);_check(epoch);
      changed=changed||(incoming['ops'] as List).isNotEmpty||(incoming['thumbs'] as List).isNotEmpty;
      final again=round<15&&(outgoing['more']==true||incoming['more']==true);
      await channel.send({'t':'ack','again':again});_check(epoch);if(!again)break;
    }return changed;
  }
  Future<bool> _serverRounds(SecureSyncChannel channel,int epoch,void Function() touched)async{
    var changed=false;await _offers(channel,epoch,touched);
    for(var round=0;round<16;round++){
      _check(epoch);final remote=await channel.receive();_check(epoch);
      final local=await strategy.state(channel.link);_check(epoch);await channel.send(local);_check(epoch);
      final incoming=await channel.receive();_check(epoch);
      if((incoming['ops'] as List).isNotEmpty||(incoming['thumbs'] as List).isNotEmpty)touched();
      _check(epoch);await strategy.apply(channel.link,incoming);_check(epoch);
      changed=changed||(incoming['ops'] as List).isNotEmpty||(incoming['thumbs'] as List).isNotEmpty;
      final outgoing=await strategy.delta(channel.link,remote);_check(epoch);await channel.send(outgoing);_check(epoch);
      final ack=await channel.receive();_check(epoch);if(ack.length!=2||ack['t']!='ack'||ack['again'] is! bool)throw const FormatException('增量确认无效');if(ack['again']!=true)break;
    }return changed;
  }
  Future<bool> _joinIfReady(PeerLink peer,int epoch)async{
    _check(epoch);if(await store.privateValue('sync-pending-family:${peer.id}')!=true)return false;_check(epoch);
    final fid=peer.familyId,family=await store.get(peer.familyId,'/families/${peer.familyId}/family',peer.familyId),member=await store.get(peer.familyId,'/families/${peer.familyId}/members',store.deviceId);_check(epoch);
    if(family==null||member?['status']!='active'||member?['user_id']!=store.deviceId||member?['family_id']!=fid||!['owner','member'].contains(member?['role']))return false;
    final families=((await store.privateValue('families') as List?)??[]).cast<String>().toSet()..add(fid);
    final profile=Map<String,dynamic>.from(await store.privateValue('self-profile') as Map);_check(epoch);
    await store.batch([{'space':fid,'collection':'/families/$fid/members','id':store.deviceId,'fields':{'display_name':profile['display_name'],'avatar_emoji':profile['avatar_emoji']}}],
      privateUpdates:{'families':families.toList(),'current-family':fid,'sync-pending-family:${peer.id}':null});return true;
  }
  Future<void> coupleConsent(String id,{required bool local})async{
    if(_disposed)return;await registry.coupleConsent(id,local:local);if(_disposed)return;
    // 当前授权变更后关闭全部在途连接，下一轮重新交换双方当前同意；不重启后台发现。
    for(final socket in {..._sockets,..._incomingSockets}){socket.destroy();}
    _message(local?'本机已确认伴侣范围，仍需对方确认':'已停止后续伴侣同步；旧副本无法收回');
    await onChanged?.call();
  }
  Future<void> revoke(String id)async{
    if(_disposed)return;await registry.revoke(id);if(_disposed)return;
    for(final s in {..._sockets,..._incomingSockets}){s.destroy();}_message('后续同步已撤销；已复制的数据无法收回');
    await onChanged?.call();
  }
  @override void dispose(){if(_disposed)return;_disposed=true;unawaited(stop());super.dispose();}
}

class _PeerSession {
  _PeerSession(this.socket,this.token,this.preferred);
  final Socket socket;final Object token;final bool preferred;
}
