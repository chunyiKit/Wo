import 'dart:async';
import 'dart:typed_data';
import 'package:crypto/crypto.dart' as crypto;
import 'backup_models.dart';

class ArchiveReader {
  ArchiveReader(Stream<List<int>> stream):_iterator=StreamIterator(stream);
  final StreamIterator<List<int>> _iterator;
  List<int> _pending=const [];int _position=0;
  Future<Uint8List> upTo(int count) async {
    if(count<0||count>8*1024*1024)throw const BackupException('archive_read_limit');
    final out=Uint8List(count);var written=0,empty=0;
    while(written<count){
      if(_position==_pending.length){
        if(!await _iterator.moveNext())break;
        _pending=_iterator.current;_position=0;
        if(_pending.length>8*1024*1024)throw const BackupException('source_chunk_limit');
        if(_pending.isEmpty){if(++empty>100)throw const BackupException('source_no_progress');continue;}
        empty=0;
      }
      final n=(count-written).clamp(0,_pending.length-_position).toInt();
      out.setRange(written,written+n,_pending,_position);written+=n;_position+=n;
    }
    return written==count?out:Uint8List.sublistView(out,0,written);
  }
  Future<Uint8List> exact(int count)async{final b=await upTo(count);if(b.length!=count)throw const BackupException('archive_truncated');return b;}
  Future<void> eof()async{if((await upTo(1)).isNotEmpty)throw const BackupException('archive_trailing_bytes');}
  Future<void> close()=>_iterator.cancel();
}
class _DigestSink implements Sink<crypto.Digest> {
  crypto.Digest? value;
  @override void add(crypto.Digest data){if(value!=null)throw StateError('digest already supplied');value=data;}
  @override void close(){}
}
class ArchiveSha256 {
  ArchiveSha256(){_sink=crypto.sha256.startChunkedConversion(_output);}
  final _output=_DigestSink();late final Sink<List<int>> _sink;bool _finished=false;
  void add(List<int> bytes){if(_finished)throw StateError('digest closed');_sink.add(bytes);}
  Uint8List finish(){if(_finished)throw StateError('digest closed');_finished=true;_sink.close();return Uint8List.fromList(_output.value!.bytes);}
}
Uint8List archiveJoin(Iterable<List<int>> values){final b=BytesBuilder(copy:false);for(final v in values){b.add(v);}return b.takeBytes();}
