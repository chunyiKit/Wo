import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import '../local_store.dart';
import '../transport/native_local.dart';
import 'peer_registry.dart';
import 'strict_json.dart';

const syncWireVersion=1;
const syncMaxFrameBytes=4*1024*1024;
const syncMaxPlainBytes=2*1024*1024;
const _maxHandshakeBytes=2048;
Uint8List _handshakeBytes32(Object? value){
  if(value is! String||value.length!=43)throw const FormatException('握手字段大小无效');
  final bytes=un64(value);if(bytes.length!=32)throw const FormatException('握手字段大小无效');return bytes;
}
Uint8List wireBytes(Object? value)=>Uint8List.fromList(utf8.encode(LocalStore.canonical(value)));
bool secureEqual(List<int> a,List<int> b){var difference=a.length^b.length;for(var i=0;i<a.length;i++){difference|=a[i]^(i<b.length?b[i]:0);}return difference==0;}
class WireFrames {
  WireFrames(this.socket){_subscription=socket.listen(_add,onError:(Object e){_error=e;_wake();},onDone:(){_done=true;_wake();});}
  final Socket socket;late final StreamSubscription<Uint8List> _subscription;
  final _chunks=ListQueue<Uint8List>();int _available=0,_head=0;Completer<void>? _waiting;Object? _error;bool _done=false;
  void _wake(){final wait=_waiting;_waiting=null;if(wait!=null&&!wait.isCompleted)wait.complete();}
  void _add(Uint8List bytes){if(_available+bytes.length>2*(syncMaxFrameBytes+4)){_error=const FormatException('同步缓冲过大');socket.destroy();_wake();return;}_chunks.add(bytes);_available+=bytes.length;if(_available>syncMaxFrameBytes+4)_subscription.pause();_wake();}
  Future<Uint8List> _take(int count)async{
    if(_error!=null)throw _error!;
    while(_available<count){if(_error!=null)throw _error!;if(_done)throw const SocketException('同步已断开');_waiting??=Completer<void>();await _waiting!.future.timeout(const Duration(seconds:30));}
    if(_error!=null)throw _error!;
    final data=Uint8List(count);var written=0;while(written<count){final first=_chunks.first;final n=(count-written)<(first.length-_head)?count-written:first.length-_head;data.setRange(written,written+n,first,_head);written+=n;_head+=n;_available-=n;if(_head==first.length){_chunks.removeFirst();_head=0;}}
    if(_subscription.isPaused&&_available<=syncMaxFrameBytes+4)_subscription.resume();return data;
  }
  Future<Map<String,dynamic>> read({int maxBytes=syncMaxFrameBytes})async{if(maxBytes<2||maxBytes>syncMaxFrameBytes)throw ArgumentError('invalid frame limit');final header=await _take(4);final size=ByteData.sublistView(header).getUint32(0,Endian.big);if(size<2||size>maxBytes)throw const FormatException('同步帧大小无效');final raw=await _take(size);final value=decodeStrictJson(utf8.decode(raw));if(value is! Map<String,dynamic>)throw const FormatException('同步对象无效');return value;}
  Future<void> write(Map<String,dynamic> value)async{final raw=wireBytes(value);if(raw.length>syncMaxFrameBytes)throw const FormatException('同步帧过大');final header=ByteData(4)..setUint32(0,raw.length,Endian.big);socket.add(header.buffer.asUint8List());socket.add(raw);await socket.flush().timeout(const Duration(seconds:30));}
  Future<void> close()async{_done=true;_wake();socket.destroy();await _subscription.cancel();}
}
class SecureSyncChannel {
  SecureSyncChannel._(this.frames,this.crypto,this.sessionId,this.sendKey,this.receiveKey,this.client,this.link);
  final WireFrames frames;final LocalCrypto crypto;final String sessionId;
  final Uint8List sendKey,receiveKey;final bool client;final PeerLink link;int _sent=0,_received=0;Future<void> _sendQueue=Future<void>.value();bool _failed=false,_reading=false,_closed=false;
  static Future<SecureSyncChannel> authenticate({required WireFrames frames,required LocalCrypto crypto,required PeerRegistry registry,
    required bool client,PeerLink? outgoing})async{
    PeerLink link;Map<String,dynamic> hello;Uint8List nc,ns;
    if(client){if(outgoing==null||!outgoing.active)throw const FormatException('配对不可用');link=PeerLink.fromJson(outgoing.toJson());nc=await crypto.random(32);hello={'v':1,'t':'hello','link':link.id,'from':registry.store.deviceId,'to':link.remoteDeviceId,'n':wire64(nc)};await frames.write(hello);}
    else{hello=await frames.read(maxBytes:_maxHandshakeBytes);if(hello.length!=6||hello['v'] is! int||hello['v']!=1||hello['t']!='hello'||hello['to']!=registry.store.deviceId||hello['from'] is! String||!syncId(hello['from'] as String)||hello['link'] is! String||(hello['link'] as String).length!=36||hello['n'] is! String||(hello['n'] as String).length!=43)throw const FormatException('握手无效');
      final found=await registry.lookup(hello['link'] as String,hello['from'] as String);if(found==null)throw const FormatException('设备尚未授权');link=found;nc=_handshakeBytes32(hello['n']);}
    if(nc.length!=32)throw const FormatException('握手随机数无效');final secret=await crypto.getSecret(link.secretRef);if(secret==null)throw const FormatException('配对密钥不可用');
    try{
      if(secret.length!=32)throw const FormatException('配对密钥不可用');
      Map<String,dynamic> challenge;
      if(client){challenge=await frames.read(maxBytes:_maxHandshakeBytes);if(challenge.length!=4||challenge['v'] is! int||challenge['v']!=1||challenge['t']!='challenge'||challenge['n'] is! String||challenge['proof'] is! String)throw const FormatException('握手响应无效');ns=_handshakeBytes32(challenge['n']);}
      else{ns=await crypto.random(32);challenge={'v':1,'t':'challenge','n':wire64(ns)};}
      if(ns.length!=32)throw const FormatException('握手随机数无效');
      final transcript=LocalStore.canonical([link.id,hello['from'],hello['to'],wire64(nc),wire64(ns)]);
      Future<Uint8List> proof(String role)=>crypto.hmac(key:secret,data:Uint8List.fromList(utf8.encode('WO-SYNC/1/$role\n$transcript')));
      if(client){if(!secureEqual(_handshakeBytes32(challenge['proof']),await proof('server')))throw const FormatException('设备认证失败');await frames.write({'v':1,'t':'proof','proof':wire64(await proof('client'))});}
      else{challenge['proof']=wire64(await proof('server'));await frames.write(challenge);final response=await frames.read(maxBytes:_maxHandshakeBytes);if(response.length!=3||response['v'] is! int||response['v']!=1||response['t']!='proof'||response['proof'] is! String||!secureEqual(_handshakeBytes32(response['proof']),await proof('client')))throw const FormatException('设备认证失败');}
      await registry.authenticated(link);
      final salt=await crypto.hash(Uint8List.fromList(utf8.encode('WO-SYNC/1/session\n$transcript')));final prk=await crypto.hmac(key:salt,data:secret);
      try{final c2s=await crypto.hmac(key:prk,data:Uint8List.fromList([...utf8.encode('c2s'),1]));final s2c=await crypto.hmac(key:prk,data:Uint8List.fromList([...utf8.encode('s2c'),1]));
        return SecureSyncChannel._(frames,crypto,wire64(salt),client?c2s:s2c,client?s2c:c2s,client,link);
      }finally{prk.fillRange(0,prk.length,0);}
    }finally{secret.fillRange(0,secret.length,0);}
  }
  Uint8List _nonce(int seq,bool sending){final clientDirection=sending?client:!client;final b=ByteData(12)..setUint32(0,clientDirection?0x57534331:0x57535331,Endian.big)..setUint64(4,seq,Endian.big);return b.buffer.asUint8List();}
  Uint8List _aad(int seq,bool sending)=>Uint8List.fromList(utf8.encode('WO-SYNC/1/$sessionId/${(sending?client:!client)?'c2s':'s2c'}/$seq'));
  Future<void> send(Map<String,dynamic> value){
    final work=_sendQueue.then((_)async{if(_failed||_closed)throw const FormatException('同步会话已失败');try{await _send(value);}catch(_){_failed=true;rethrow;}});_sendQueue=work.then<void>((_) {},onError:(Object _,StackTrace __){});return work;
  }
  Future<void> _send(Map<String,dynamic> value)async{if(_sent>=9007199254740991)throw const FormatException('同步会话需要更新');final plain=wireBytes(value);if(plain.length>syncMaxPlainBytes)throw const FormatException('同步内容过大');final seq=_sent++;final cipher=await crypto.seal(key:sendKey,nonce:_nonce(seq,true),plaintext:plain,aad:_aad(seq,true));await frames.write({'v':1,'t':'sealed','sid':sessionId,'seq':seq,'data':wire64(cipher)});}
  Future<Map<String,dynamic>> receive()async{if(_reading||_failed||_closed)throw const FormatException('同步读取状态无效');_reading=true;try{return await _receive();}catch(_){_failed=true;rethrow;}finally{_reading=false;}}
  Future<Map<String,dynamic>> _receive()async{final j=await frames.read();if(_received>=9007199254740991)throw const FormatException('同步会话需要更新');if(j.length!=5||j['v'] is! int||j['v']!=1||j['t']!='sealed'||j['sid']!=sessionId||j['seq'] is! int||j['seq']!=_received||j['data'] is! String)throw const FormatException('同步会话或顺序无效');final cipher=un64(j['data'] as String);if(cipher.length>syncMaxPlainBytes+16)throw const FormatException('同步密文过大');final plain=await crypto.open(key:receiveKey,nonce:_nonce(_received,false),ciphertext:cipher,aad:_aad(_received,false));_received++;final j2=decodeStrictJson(utf8.decode(plain));if(j2 is! Map<String,dynamic>)throw const FormatException('同步内容无效');return j2;}
  Future<void> close()async{if(_closed)return;_closed=true;_failed=true;sendKey.fillRange(0,sendKey.length,0);receiveKey.fillRange(0,receiveKey.length,0);await frames.close();}
}
