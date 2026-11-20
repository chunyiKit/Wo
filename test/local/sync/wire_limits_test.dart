// 准备测试，不代表本轮执行了Dart或手机SDK。
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:wo/local/sync/sync_wire.dart';

void main(){
  test('预认证帧在读body前按header拒绝超限，不等待或分配超大JSON',()async{
    final listener=await ServerSocket.bind(InternetAddress.loopbackIPv4,0);
    final accepted=listener.first;final sender=await Socket.connect(InternetAddress.loopbackIPv4,listener.port);
    final receiver=await accepted,frames=WireFrames(receiver);
    try{
      final header=ByteData(4)..setUint32(0,2049,Endian.big);sender.add(header.buffer.asUint8List());await sender.flush();
      await expectLater(frames.read(maxBytes:2048).timeout(const Duration(seconds:1)),throwsFormatException);
    }finally{await frames.close();sender.destroy();await listener.close();}
  });
  test('close唤醒等帧读取并且可重复，不滞留到30秒超时',()async{
    final listener=await ServerSocket.bind(InternetAddress.loopbackIPv4,0);
    final accepted=listener.first;final sender=await Socket.connect(InternetAddress.loopbackIPv4,listener.port);
    final frames=WireFrames(await accepted);
    try{
      final waiting=frames.read();final expectation=expectLater(waiting.timeout(const Duration(seconds:1)),throwsA(isA<SocketException>()));
      await frames.close();await expectation;await frames.close();
    }finally{sender.destroy();await listener.close();}
  });
}
