import 'dart:io';

import 'package:flutter/material.dart';

import '../../../data/wo_session.dart';
import '../../../local/local_runtime.dart';
import '../../../theme/wo_tokens.dart';

/// 旅行只展示核权后的本机缩略图，绝不把自定义URL交给网络缓存。
class LocalTravelThumbnail extends StatefulWidget {
  const LocalTravelThumbnail({super.key,required this.tripId,this.fit=BoxFit.cover,
    this.placeholderColor=Colors.transparent});
  final String tripId;
  final BoxFit fit;
  final Color placeholderColor;
  @override State<LocalTravelThumbnail> createState()=>_LocalTravelThumbnailState();
}
class _LocalTravelThumbnailState extends State<LocalTravelThumbnail>{
  Future<File?>? _file;
  String? _family;
  int? _revision;
  @override void didUpdateWidget(covariant LocalTravelThumbnail old){super.didUpdateWidget(old);if(old.tripId!=widget.tripId)_file=null;}
  Widget _missing()=>ColoredBox(color:widget.placeholderColor,child:const Center(child:Icon(Icons.image_not_supported_outlined)));
  @override Widget build(BuildContext context){
    final runtime=LocalRuntime.instance,fid=WoScope.of(context).currentFamilyId;if(runtime==null||fid==null)return _missing();
    return ValueListenableBuilder<int>(valueListenable:runtime.changes,builder:(context,revision,_){
      if(_file==null||_family!=fid||_revision!=revision){_family=fid;_revision=revision;_file=runtime.travels.displayFile(fid,widget.tripId);}
      return FutureBuilder<File?>(future:_file,builder:(context,snapshot){
        if(snapshot.connectionState!=ConnectionState.done||snapshot.hasError||snapshot.data==null)return _missing();
        return Image.file(snapshot.data!,fit:widget.fit,cacheWidth:512,gaplessPlayback:false,errorBuilder:(_,__,___)=>_missing());
      });
    });
  }
}

Future<void> openLocalTravelOriginal(BuildContext context,String tripId)async{
  final runtime=LocalRuntime.instance,fid=WoScope.of(context).currentFamilyId;var opened=false;
  if(runtime!=null&&fid!=null){try{opened=await runtime.travels.openOriginal(fid,tripId);}catch(_){} }
  if(context.mounted&&!opened)ScaffoldMessenger.of(context).showSnackBar(WoSnackBar(content:const Text(
    '本机无法读取原照：可能只有同步缩略图，或需要原设备权限、下载原件后重试。电脑备份缺原件时不会视为完整。')));
}
