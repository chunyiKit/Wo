import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../../../data/api_client.dart';
import '../../../data/image_pick.dart';
import '../../../data/models.dart';
import '../../../data/wo_session.dart';
import '../../../theme/wo_tokens.dart';
import '../../../local/local_runtime.dart';
import '../../../local/attachments/attachment_descriptor.dart';
import 'pet_attachment_panel.dart';

class PetRecordEditPage extends StatefulWidget {
  const PetRecordEditPage({
    super.key,
    required this.petId,
    this.record,
    this.initialTypeId,
  });

  final String petId;
  final PetRecord? record;
  final String? initialTypeId;

  @override
  State<PetRecordEditPage> createState() => _PetRecordEditPageState();
}

class _PetRecordEditPageState extends State<PetRecordEditPage> {
  late final TextEditingController _name;
  late final TextEditingController _note;
  late final TextEditingController _weight;
  late Future<List<PetRecordType>> _typesFuture;
  String? _typeId;
  DateTime _date = DateTime.now();
  DateTime? _nextDate;
  String _unit = 'none';
  int _interval = 1;
  Uint8List? _attachment;
  final _localSelections=<AttachmentSelectionMetadata>[];
  String? _savedRecordId,_savedFamilyId,_typesFamily;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    final record = widget.record;
    _savedRecordId=record?.id;
    _name = TextEditingController(text: record?.name ?? '');
    _note = TextEditingController(text: record?.note ?? '');
    _weight = TextEditingController(
      text: record?.weightKg?.toStringAsFixed(2) ?? '',
    );
    _typeId = record?.recordTypeId ?? widget.initialTypeId;
    _date = record?.occurredOn ?? DateTime.now();
    _nextDate = record?.nextDueDate;
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final fid = WoScope.of(context).currentFamilyId!;
    if(_savedRecordId!=null)_savedFamilyId??=fid;
    if(_typesFamily!=fid){_typesFamily=fid;_typesFuture = WoScope.api(context).petRecordTypes(fid);}
  }

  @override
  void dispose() {
    final routes=LocalRuntime.instance?.pets;
    if(routes!=null){for(final selection in _localSelections){routes.releaseAttachmentSelection(selection.token,familyId:_savedFamilyId,recordId:_savedRecordId).catchError((Object _){});}}
    _name.dispose();
    _note.dispose();
    _weight.dispose();
    super.dispose();
  }

  Future<DateTime?> _pick(DateTime initial) => showDatePicker(
        context: context,
        // 和记录页共用导航栈，让 Android 预测式返回优先取消日历。
        useRootNavigator: false,
        initialDate: initial,
        firstDate: DateTime(1980),
        lastDate: DateTime(2100),
      );

  bool get _canWrite {
    final session=WoScope.of(context),runtime=LocalRuntime.instance;
    return !session.api.isLocal||widget.record==null||session.currentFamily?.myRole=='owner'||widget.record!.createdBy==runtime?.store.deviceId;
  }
  Future<void> _pickLocalAttachment(String purpose)async{
    if(_saving||!_canWrite)return;final runtime=LocalRuntime.instance,session=WoScope.of(context);
    if(runtime==null||!session.api.isLocal)return;
    if((widget.record?.attachments.length??0)+_localSelections.length>=10){ScaffoldMessenger.of(context).showSnackBar(WoSnackBar(content:const Text('每条记录最多10个附件')));return;}
    setState(()=>_saving=true);
    try{final selected=await runtime.pets.pickAttachment(session.currentFamilyId!,purpose:purpose);
      if(selected!=null){if(mounted){setState(()=>_localSelections.add(selected));}else{await runtime.pets.releaseAttachmentSelection(selected.token);}}}
    catch(e){if(mounted)ScaffoldMessenger.of(context).showSnackBar(WoSnackBar(content:Text(petAttachmentError(e))));}
    finally{if(mounted)setState(()=>_saving=false);}
  }
  Future<void> _save(List<PetRecordType> types) async {
    final typeId = _typeId;
    if (typeId == null || _name.text.trim().isEmpty || _saving || !_canWrite) return;
    final selected = types.firstWhere((item) => item.id == typeId);
    final weight = double.tryParse(_weight.text.trim());
    if (selected.isWeight && weight == null) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(WoSnackBar(content: Text('体重记录需要填写 kg 数值')));
      return;
    }
    setState(() => _saving = true);
    final session = WoScope.of(context);
    final fid = session.currentFamilyId!;
    try {
      PetRecord result;
      if (_savedRecordId == null) {
        result = await session.api.createPetRecord(
          fid,
          widget.petId,
          recordTypeId: typeId,
          name: _name.text.trim(),
          occurredOn: _date,
          note: _note.text.trim(),
          weightKg: selected.isWeight ? weight : null,
          nextDueDate: _nextDate,
          recurrenceUnit: _unit,
          recurrenceInterval: _interval,
        );
      } else {
        result = await session.api.updatePetRecord(
          fid,
          widget.petId,
          _savedRecordId!,
          recordTypeId: typeId,
          name: _name.text.trim(),
          occurredOn: _date,
          note: _note.text.trim(),
          weightKg: selected.isWeight ? weight : null,
          nextDueDate: _nextDate,
        );
      }
      _savedRecordId=result.id;_savedFamilyId=fid;
      if(session.api.isLocal){
        final runtime=LocalRuntime.instance;if(runtime==null)throw StateError('local_runtime_unavailable');
        while(_localSelections.isNotEmpty){final selection=_localSelections.first;
          await runtime.pets.addAttachment(fid,result.id,selection);_localSelections.removeAt(0);}
      }
      if (_attachment != null && !session.api.isLocal) {
        await session.api.uploadPetRecordAttachment(
          fid,
          result.id,
          bytes: _attachment!,
        );
      }
      if (mounted) Navigator.of(context).pop(true);
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          WoSnackBar(
            content: Text(_savedRecordId!=null&&widget.record==null?'记录已保存；附件尚未全部保存，可在本页重试：${petAttachmentError(error)}':petAttachmentError(error)),
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) => FutureBuilder<List<PetRecordType>>(
        future: _typesFuture,
        builder: (context, snapshot) {
          final types = snapshot.data;
          return WoScaffold(
            appBar: WoAppBar(
              title: Text(widget.record == null ? '新增记录' : '编辑记录'),
              actions: [
                WoTextButton(
                  onPressed:
                      types == null || _saving || !_canWrite ? null : () => _save(types),
                  child: const Text('保存'),
                ),
              ],
            ),
            body: snapshot.hasError?Center(child:Text(snapshot.error is ApiException?(snapshot.error as ApiException).message:'记录类型读取失败，请返回重试')):
                types == null?const Center(child:WoProgressIndicator()):!_canWrite?_readOnly():_form(types),
          );
        },
      );

  Widget _readOnly(){final record=widget.record!,session=WoScope.of(context),runtime=LocalRuntime.instance;
    return ListView(padding:const EdgeInsets.all(WoTokens.space5),children:[
      const Text('当前记录只读；只有记录作者或家庭所有者可以修改和删除附件。'),
      Text(record.name),if(record.note!=null)Text(record.note!),const SizedBox(height:WoTokens.space4),
      if(runtime!=null)PetAttachmentPanel(routes:runtime.pets,familyId:session.currentFamilyId!,recordId:record.id,canWrite:false),
    ]);}
  Widget _form(List<PetRecordType> types) {
    _typeId ??= types.isEmpty ? null : types.first.id;
    final selected = types.where((item) => item.id == _typeId).firstOrNull;
    return ListView(
      padding: const EdgeInsets.all(WoTokens.space5),
      children: [
        WoDropdownButtonFormField<String>(
          initialValue: _typeId,
          decoration: const InputDecoration(labelText: '记录类型 *'),
          items: [
            for (final item in types)
              DropdownMenuItem(
                value: item.id,
                child: Text('${item.emoji} ${item.name}'),
              ),
          ],
          onChanged: (value) => setState(() => _typeId = value),
        ),
        const SizedBox(height: WoTokens.space4),
        WoTextField(
          controller: _name,
          decoration: const InputDecoration(labelText: '记录名称 *'),
        ),
        if (selected?.isWeight == true) ...[
          const SizedBox(height: WoTokens.space4),
          WoTextField(
            controller: _weight,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            decoration: const InputDecoration(labelText: '体重（kg）*'),
          ),
        ],
        const SizedBox(height: WoTokens.space3),
        WoListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('发生日期'),
          subtitle: Text(_ymd(_date)),
          onTap: () async {
            final value = await _pick(_date);
            if (value != null && mounted) setState(() => _date = value);
          },
        ),
        const SizedBox(height: WoTokens.space3),
        WoTextField(
          controller: _note,
          maxLines: 4,
          decoration: const InputDecoration(labelText: '备注'),
        ),
        const SizedBox(height: WoTokens.space2),
        WoSwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('设置下次日期'),
          subtitle: const Text('可选；保存时同时建立灵活照护计划'),
          value: _nextDate != null,
          onChanged: (value) async {
            if (!value) {
              setState(() => _nextDate = null);
              return;
            }
            final date = await _pick(
              DateTime.now().add(const Duration(days: 30)),
            );
            if (date != null && mounted) setState(() => _nextDate = date);
          },
        ),
        if (_nextDate != null) ...[
          const SizedBox(height: WoTokens.space2),
          WoListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('下次日期'),
            subtitle: Text(_ymd(_nextDate!)),
            onTap: () async {
              final value = await _pick(_nextDate!);
              if (value != null && mounted) setState(() => _nextDate = value);
            },
          ),
          const SizedBox(height: WoTokens.space3),
          Row(
            children: [
              Expanded(
                child: WoDropdownButtonFormField<String>(
                  initialValue: _unit,
                  decoration: const InputDecoration(labelText: '周期'),
                  items: const [
                    DropdownMenuItem(value: 'none', child: Text('仅一次')),
                    DropdownMenuItem(value: 'day', child: Text('每 N 天')),
                    DropdownMenuItem(value: 'week', child: Text('每 N 周')),
                    DropdownMenuItem(value: 'month', child: Text('每 N 月')),
                    DropdownMenuItem(value: 'year', child: Text('每 N 年')),
                  ],
                  onChanged: (value) => setState(() => _unit = value ?? 'none'),
                ),
              ),
              if (_unit != 'none') ...[
                const SizedBox(width: WoTokens.space3),
                SizedBox(
                  width: 96,
                  child: WoDropdownButtonFormField<int>(
                    initialValue: _interval,
                    decoration: const InputDecoration(labelText: 'N'),
                    items: [
                      for (var value = 1; value <= 12; value++)
                        DropdownMenuItem(value: value, child: Text('$value')),
                    ],
                    onChanged: (value) =>
                        setState(() => _interval = value ?? 1),
                  ),
                ),
              ],
            ],
          ),
        ],
        const SizedBox(height: WoTokens.space4),
        if(WoScope.of(context).api.isLocal)...[
          const Text('选择的是独立附件副本，不引用回忆原件。保存后再逐个校验；取消编辑不会上传到云端。'),
          Wrap(spacing:WoTokens.space2,children:[
            WoOutlinedButton.icon(onPressed:_saving?null:()=>_pickLocalAttachment('pet_image_copy'),icon:const Icon(Icons.image_outlined),label:const Text('选择图片副本')),
            WoOutlinedButton.icon(onPressed:_saving?null:()=>_pickLocalAttachment('pet_file_copy'),icon:const Icon(Icons.description_outlined),label:const Text('选择 PDF 或文件')),
          ]),
          for(final selection in _localSelections)ListTile(contentPadding:EdgeInsets.zero,title:Text(safeAttachmentDisplayName(selection.displayName)),
            subtitle:Text('${(selection.size/1024).toStringAsFixed(1)} KiB · 待保存'),trailing:IconButton(tooltip:'移除待保存附件',onPressed:_saving?null:()async{
              try{await LocalRuntime.instance!.pets.releaseAttachmentSelection(selection.token,familyId:_savedFamilyId,recordId:_savedRecordId);if(mounted)setState(()=>_localSelections.remove(selection));}
              catch(e){if(mounted)ScaffoldMessenger.of(context).showSnackBar(WoSnackBar(content:Text(petAttachmentError(e))));}},icon:const Icon(Icons.close))),
          if(_savedRecordId!=null&&LocalRuntime.instance!=null)PetAttachmentPanel(key:ValueKey(_savedRecordId),routes:LocalRuntime.instance!.pets,
            familyId:WoScope.of(context).currentFamilyId!,recordId:_savedRecordId!,canWrite:_canWrite),
        ]else WoOutlinedButton.icon(
          onPressed: _saving?null:() async {
            final bytes = await pickAndCompressImage();
            if (bytes != null && mounted) setState(() => _attachment = bytes);
          },
          icon: const Icon(Icons.attach_file),
          label: Text(_attachment == null ? '添加图片附件' : '已选择 1 张图片'),
        ),
      ],
    );
  }
}

String _ymd(DateTime date) =>
    '${date.year}-${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')}';
