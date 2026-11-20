import 'dart:convert';
import 'dart:typed_data';
import 'package:crypto/crypto.dart' as crypto;
import 'package:flutter_test/flutter_test.dart';
import 'package:wo/local/backup/backup_models.dart';
import 'package:wo/local/backup/backup_transport.dart';
import 'package:wo/local/backup/mobile_backup_client.dart';
import 'package:wo/local/transport/native_local.dart';

class TestCrypto implements LocalCrypto {
  final secrets=<String,Uint8List>{};int counter=0;
  @override Future<Uint8List> random(int count) async=>Uint8List.fromList(List.generate(count,(i)=>(i+counter++)&255));
  @override Future<Uint8List> hash(Uint8List bytes)async=>Uint8List.fromList(crypto.sha256.convert(bytes).bytes);
  @override Future<Uint8List> hmac({required Uint8List key,required Uint8List data})async=>Uint8List.fromList(crypto.Hmac(crypto.sha256,key).convert(data).bytes);
  @override Future<void> putSecret(String h,Uint8List b)async{secrets[h]=Uint8List.fromList(b);}
  @override Future<Uint8List?> getSecret(String h)async=>secrets[h]==null?null:Uint8List.fromList(secrets[h]!);
  @override Future<void> deleteSecret(String h)async{secrets.remove(h);}
  @override Future<Uint8List> seal({required Uint8List key,required Uint8List nonce,required Uint8List plaintext,required Uint8List aad})=>throw UnimplementedError();
  @override Future<Uint8List> open({required Uint8List key,required Uint8List nonce,required Uint8List ciphertext,required Uint8List aad})=>throw UnimplementedError();
}
class FakeTransport implements BackupTransport {
  @override final origin=Uri.parse('https://127.0.0.1:9443');
  @override final pin='a'*64;
  final calls=<String>[];
  late Future<BackupReply> Function(String,String,Map<String,String>,Uint8List?) handle;
  @override Future<BackupReply> request(String method,String path,{Map<String,String> headers=const {},Uint8List? body,int maxResponseBytes=2*1024*1024}){
    calls.add('$method $path');return handle(method,path,headers,body);
  }
  @override void close(){}
}
class MemorySource implements BackupSource {
  MemorySource(this.bytes,{this.privacy=BackupPrivacy.public,String kind='records'})
    :entry=BackupEntry(id:'entry',kind:kind,size:bytes.length,sha256:crypto.sha256.convert(bytes).toString(),sourceExact:false);
  final Uint8List bytes;@override final BackupEntry entry;@override final BackupPrivacy privacy;
  @override Future<Stream<List<int>>> openRange(int offset,int length)async=>Stream.value(Uint8List.sublistView(bytes,offset,offset+length));
}
BackupReply jsonReply(Object value,{int status=200})=>BackupReply(status,{},utf8.encode(jsonEncode(value)));
Map<String,dynamic> statusJson(BackupEntry e,int offset,{bool done=false})=>{
  'scope':e.kind=='sealed'?'opaque_restricted_unverified':'declared_public_files','full_device_complete':false,
  'family_id':'family','backup_id':'backup','state':done?'verified':'uploading','complete':done&&e.kind!='sealed',
  if(done)'verified_at':'2026-11-20T00:00:00Z','issues':<String>[],
  'entries':[{'id':e.id,'kind':e.kind,'size':e.size,'offset':offset}]};
PairedComputer paired(FakeTransport transport)=>PairedComputer(origin:transport.origin,pin:transport.pin,
  familyId:'family',deviceId:'new-device',tokenRef:'wo.backup.token.${'1'*32}');
Future<MobileBackupClient> client(FakeTransport transport,TestCrypto c)async{
  final p=paired(transport);await c.putSecret(p.tokenRef,Uint8List.fromList(utf8.encode('2'*64)));
  return MobileBackupClient(transport:transport,crypto:c,computer:p);
}
class MemoryReceive implements BackupReceiveStore {
  BackupManifest? manifest;final data=BytesBuilder();bool finished=false;
  @override Future<void> bind(BackupManifest m)async{manifest=m;}
  @override Future<int> verifiedOffset(BackupEntry e)async=>data.length;
  @override Future<void> append(BackupEntry e,int offset,Uint8List bytes,String sha)async{
    expect(offset,data.length);expect(crypto.sha256.convert(bytes).toString(),sha);data.add(bytes);
  }
  @override Future<void> finish(BackupManifest m)async{expect(crypto.sha256.convert(data.toBytes()).toString(),m.entries.single.sha256);finished=true;}
}
void main(){
  test('pair stores native secret reference only; no token in reusable configuration',()async{
    final t=FakeTransport(),c=TestCrypto();t.handle=(m,p,h,b)async{
      expect(h.containsKey('Authorization'),false);expect(jsonDecode(utf8.decode(b!)),{'code':'3'*64,'family':'family','device':'new-device'});
      return jsonReply({'token':'4'*64,'family':'family','device':'new-device'},status:201);
    };
    final result=await MobileBackupClient.pair(transport:t,crypto:c,oneTimeCode:'3'*64,familyId:'family',deviceId:'new-device');
    expect(result.tokenRef.startsWith('wo.backup.token.'),true);expect(utf8.decode((await c.getSecret(result.tokenRef))!),'4'*64);
    expect(result.tokenRef.contains('4'*64),false);
  });
  test('ambiguous one-time pairing failure is not automatically retried',()async{
    final t=FakeTransport();t.handle=(m,p,h,b)async=>throw const BackupException('interrupted',retryable:true);
    await expectLater(MobileBackupClient.pair(transport:t,crypto:TestCrypto(),oneTimeCode:'3'*64,familyId:'family',deviceId:'new-device'),
      throwsA(isA<BackupException>().having((e)=>e.code,'code','pair_outcome_unknown')));expect(t.calls.length,1);
  });
  test('upload validates local source and SHA; follows acknowledged offset',()async{
    final t=FakeTransport(),c=TestCrypto();final source=MemorySource(Uint8List.fromList([1,2,3,4]));
    final manifest=BackupManifest(familyId:'family',backupId:'backup',entries:[source.entry]);
    t.handle=(m,p,h,b)async{
      expect(h['Authorization'],'Bearer ${'2'*64}');
      if(m=='POST'&&p=='/v1/backups')return jsonReply({'ok':true},status:201);
      if(m=='GET')return jsonReply(statusJson(source.entry,2));
      if(m=='PUT'){expect(p.endsWith('offset=2'),true);expect(b,[3,4]);expect(h['X-Chunk-SHA256'],crypto.sha256.convert([3,4]).toString());return jsonReply({'offset':4});}
      return jsonReply(statusJson(source.entry,4,done:true));
    };
    final result=await (await client(t,c)).upload(manifest,[source]);expect(result.complete,true);expect(result.fullDeviceComplete,false);
  });
  test('restricted raw source cannot be uploaded as public',()async{
    final t=FakeTransport(),c=TestCrypto();final source=MemorySource(Uint8List.fromList([1]),privacy:BackupPrivacy.restricted);
    final m=BackupManifest(familyId:'family',backupId:'backup',entries:[source.entry]);
    await expectLater((await client(t,c)).upload(m,[source]),throwsA(isA<BackupException>().having((e)=>e.code,'code','restricted_requires_sealed')));expect(t.calls,isEmpty);
  });
  test('fetch checks exact immutable range and full receiver digest',()async{
    final t=FakeTransport(),c=TestCrypto();final source=MemorySource(Uint8List.fromList([1,2,3]));
    final m=BackupManifest(familyId:'family',backupId:'backup',entries:[source.entry]);
    t.handle=(method,p,h,b)async{
      if(p.endsWith('/manifest'))return jsonReply(m.toJson());
      expect(h['Range'],'bytes=0-2');expect(h['If-Range'],'"${source.entry.sha256}"');
      return BackupReply(206,{'Content-Range':'bytes 0-2/3','Content-Length':'3','ETag':'"${source.entry.sha256}"'},source.bytes);
    };
    final receive=MemoryReceive();await (await client(t,c)).fetch(m,receive);expect(receive.finished,true);
  });
  test('partial or wrong range is never committed to receiver',()async{
    final t=FakeTransport(),c=TestCrypto();final source=MemorySource(Uint8List.fromList([1,2,3]));
    final m=BackupManifest(familyId:'family',backupId:'backup',entries:[source.entry]);
    t.handle=(method,p,h,b)async=>p.endsWith('/manifest')?jsonReply(m.toJson()):BackupReply(200,{},[1]);
    final receive=MemoryReceive();await expectLater((await client(t,c)).fetch(m,receive),throwsA(isA<BackupException>()));expect(receive.data.length,0);expect(receive.finished,false);
  });
  test('case duplicates, nonopaque sealed, missing claims and cross-family rejected',(){
    BackupEntry e(String id)=>BackupEntry(id:id,kind:'records',size:1,sha256:'a'*64,sourceExact:false);
    expect(()=>BackupManifest(familyId:'family',backupId:'backup',entries:[e('ID'),e('id')]),throwsA(isA<BackupException>()));
    expect(()=>BackupEntry(id:'sealed',kind:'sealed',size:121,sha256:'a'*64,sourceExact:false,label:'private title'),throwsA(isA<BackupException>()));
    expect(()=>BackupEntry(id:'photo',kind:'photo',size:1,sha256:'a'*64,sourceExact:false,missing:'cloud_only'),throwsA(isA<BackupException>()));
    expect(()=>validateComputerOrigin(Uri.parse('http://127.0.0.1'),'a'*64),throwsA(isA<BackupException>()));
    expect(backupConstantTimeEquals([1,2],[1,3]),false);expect(backupConstantTimeEquals([1],[1,0]),false);
  });
}
