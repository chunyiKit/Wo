import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import '../transport/native_local.dart';
import 'backup_models.dart';

bool backupConstantTimeEquals(List<int> a,List<int> b) {
  var difference=a.length^b.length;
  for(var i=0;i<a.length;i++){difference |= a[i]^(i<b.length?b[i]:0);}
  return difference==0;
}
String backupHex(List<int> bytes)=>bytes.map((b)=>b.toRadixString(16).padLeft(2,'0')).join();

class BackupReply {
  BackupReply(this.status,Map<String,String> headers,List<int> body)
    :headers=Map.unmodifiable(headers.map((k,v)=>MapEntry(k.toLowerCase(),v))),body=Uint8List.fromList(body);
  final int status;final Map<String,String> headers;final Uint8List body;
}
abstract class BackupTransport {
  Uri get origin;
  String get pin;
  Future<BackupReply> request(String method,String path,{Map<String,String> headers=const {},
    Uint8List? body,int maxResponseBytes=2*1024*1024});
  void close();
}

/// 唯一真实网络实现。先完成无 HTTP 的 TLS 预握手，再把已核对 DER 同步固定到 HTTP。
/// 注入 mock transport 可测试业务契约，不代表实际 TLS/手机互通已验证。
class PinnedBackupTransport implements BackupTransport {
  PinnedBackupTransport._(this.origin,this.pin,this._http,this._certificate);
  @override final Uri origin;
  @override final String pin;
  final HttpClient _http;final X509Certificate _certificate;
  bool _closed=false;
  static bool _current(X509Certificate certificate) {
    final now=DateTime.now().toUtc();return !now.isBefore(certificate.startValidity.toUtc())&&!now.isAfter(certificate.endValidity.toUtc());
  }
  static Future<PinnedBackupTransport> connect({required Uri origin,required String pin,required LocalCrypto crypto}) async {
    validateComputerOrigin(origin,pin);
    SecureSocket? probe;
    try {
      // 预握手没有 HTTP、配对码、token、Cookie、正文；只允许当前有效证书完成握手。
      probe=await SecureSocket.connect(origin.host,origin.hasPort?origin.port:443,
        context:SecurityContext(withTrustedRoots:false),timeout:const Duration(seconds:15),
        supportedProtocols:const ['http/1.1'],onBadCertificate:(certificate)=>_current(certificate));
      final certificate=probe.peerCertificate;
      if(certificate==null||!_current(certificate)) throw const BackupException('invalid_certificate');
      final der=Uint8List.fromList(certificate.der);
      final expected=Uint8List.fromList(List.generate(32,(i)=>int.parse(pin.substring(i*2,i*2+2),radix:16)));
      final actual=await crypto.hash(der);
      if(actual.length!=32||!backupConstantTimeEquals(expected,actual)) throw const BackupException('certificate_pin_mismatch');
      final client=HttpClient(context:SecurityContext(withTrustedRoots:false));
      client.findProxy=(_)=>'DIRECT';
      client.connectionTimeout=const Duration(seconds:15);
      client.idleTimeout=const Duration(seconds:30);
      client.badCertificateCallback=(candidate,host,port)=>host==origin.host&&port==(origin.hasPort?origin.port:443)&&
        _current(candidate)&&backupConstantTimeEquals(der,candidate.der);
      return PinnedBackupTransport._(origin,pin,client,certificate);
    } on BackupException {rethrow;} catch (_) {throw const BackupException('tls_connection_failed',retryable:true);}
    finally {probe?.destroy();}
  }
  @override Future<BackupReply> request(String method,String path,{Map<String,String> headers=const {},
      Uint8List? body,int maxResponseBytes=2*1024*1024}) async {
    if(_closed||!_current(_certificate))throw const BackupException('transport_closed_or_certificate_expired');
    if(!path.startsWith('/v1/')||path.startsWith('//')||maxResponseBytes<0||maxResponseBytes>backupChunkBytes||
        (body?.length??0)>backupChunkBytes)throw const BackupException('invalid_transport_request');
    final relative=Uri.parse(path);final uri=origin.resolveUri(relative);
    if(relative.hasScheme||relative.hasAuthority||relative.hasFragment||uri.origin!=origin.origin)throw const BackupException('cross_origin_forbidden');
    HttpClientRequest? request;
    try {
      request=await _http.openUrl(method,uri).timeout(const Duration(seconds:20));
      request.followRedirects=false;request.maxRedirects=0;
      headers.forEach((name,value){request!.headers.set(name,value);});
      request.contentLength=body?.length??0;
      if(body!=null)request.add(body);
      final response=await request.close().timeout(const Duration(minutes:15));
      if(response.contentLength>maxResponseBytes){await response.listen((_){}).cancel();throw const BackupException('response_limit');}
      final builder=BytesBuilder(copy:false);var count=0;
      await for(final chunk in response.timeout(const Duration(seconds:30))) {
        count+=chunk.length;if(count>maxResponseBytes)throw const BackupException('response_limit');builder.add(chunk);
      }
      final values=<String,String>{};response.headers.forEach((k,v){values[k.toLowerCase()]=v.join(',');});
      return BackupReply(response.statusCode,values,builder.takeBytes());
    } on BackupException {request?.abort();rethrow;} catch (_) {request?.abort();throw const BackupException('connection_interrupted',retryable:true);}
  }
  @override void close(){_closed=true;_http.close(force:true);}
}
