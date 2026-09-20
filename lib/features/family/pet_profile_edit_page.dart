import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../../data/api_client.dart';
import '../../data/image_pick.dart';
import '../../data/models.dart';
import '../../data/wo_session.dart';
import '../../theme/wo_tokens.dart';
import '../../widgets/pet_avatar.dart';

class PetProfileEditPage extends StatefulWidget {
  const PetProfileEditPage({super.key, this.pet, this.imagePicker});

  final Pet? pet;
  final Future<Uint8List?> Function()? imagePicker;

  @override
  State<PetProfileEditPage> createState() => _PetProfileEditPageState();
}

class _PetProfileEditPageState extends State<PetProfileEditPage> {
  late final TextEditingController _name;
  late final TextEditingController _emoji;
  late final TextEditingController _species;
  late final TextEditingController _breed;
  late final TextEditingController _notes;
  DateTime? _birthday;
  DateTime? _arrival;
  String? _sex;
  bool? _neutered;
  bool _estimated = false;
  bool _saving = false;
  Uint8List? _photo;

  @override
  void initState() {
    super.initState();
    final pet = widget.pet;
    _name = TextEditingController(text: pet?.name ?? '');
    _emoji = TextEditingController(text: pet?.emoji ?? '🐾');
    _species = TextEditingController(text: pet?.species ?? '');
    _breed = TextEditingController(text: pet?.breed ?? '');
    _notes = TextEditingController(text: pet?.notes ?? '');
    _birthday = pet?.birthday;
    _arrival = pet?.arrivalDate;
    _sex = pet?.sex;
    _neutered = pet?.neutered;
    _estimated = pet?.birthdayEstimated ?? false;
  }

  @override
  void dispose() {
    _name.dispose();
    _emoji.dispose();
    _species.dispose();
    _breed.dispose();
    _notes.dispose();
    super.dispose();
  }

  Future<DateTime?> _date(DateTime? initial) => showDatePicker(
        context: context,
        initialDate: initial ?? DateTime.now(),
        firstDate: DateTime(1980),
        lastDate: DateTime.now(),
      );

  Future<void> _save() async {
    if (_name.text.trim().isEmpty || _saving) return;
    final session = WoScope.of(context);
    final fid = session.currentFamilyId;
    if (fid == null) return;
    setState(() => _saving = true);
    try {
      Pet pet;
      if (widget.pet == null) {
        pet = await session.api.createPet(
          fid,
          name: _name.text.trim(),
          emoji: _emoji.text.trim().isEmpty ? '🐾' : _emoji.text.trim(),
          species: _species.text.trim(),
          breed: _breed.text.trim(),
          sex: _sex,
          birthday: _birthday,
          birthdayEstimated: _estimated,
          arrivalDate: _arrival,
          neutered: _neutered,
          notes: _notes.text.trim(),
        );
      } else {
        pet = await session.api.updatePet(
          fid,
          widget.pet!.id,
          name: _name.text.trim(),
          emoji: _emoji.text.trim().isEmpty ? '🐾' : _emoji.text.trim(),
          species: _species.text.trim(),
          breed: _breed.text.trim(),
          sex: _sex,
          birthday: _birthday,
          birthdayEstimated: _estimated,
          arrivalDate: _arrival,
          neutered: _neutered,
          notes: _notes.text.trim(),
        );
      }
      if (_photo != null) {
        pet = await session.api.uploadPetPhoto(fid, pet.id, bytes: _photo!);
      }
      if (mounted) Navigator.of(context).pop(pet);
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          WoSnackBar(
            content: Text(error is ApiException ? error.message : '保存失败'),
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _archive() async {
    final pet = widget.pet;
    final fid = WoScope.of(context).currentFamilyId;
    if (pet == null || fid == null) return;
    final yes = await showWoDialog<bool>(
      context: context,
      builder: (context) => WoAlertDialog(
        title: const Text('归档宠物档案'),
        content: Text('归档「${pet.name}」后将不再出现在宠物列表，历史记录仍会保留。'),
        actions: [
          WoTextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          WoFilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('归档'),
          ),
        ],
      ),
    );
    if (yes != true || !mounted) return;
    await WoScope.api(context).archivePet(fid, pet.id);
    if (mounted) Navigator.of(context).pop(pet);
  }

  @override
  Widget build(BuildContext context) {
    final pet = widget.pet;
    final api = WoScope.api(context);
    final wo = context.wo;
    return WoScaffold(
      appBar: WoAppBar(
        title: Text(pet == null ? '添加宠物' : '编辑宠物档案'),
        actions: [
          WoTextButton(
            onPressed: _saving ? null : _save,
            child: const Text('保存'),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(WoTokens.space5),
        children: [
          Center(
            child: GestureDetector(
              key: const ValueKey('pet-photo-picker'),
              onTap: () async {
                final bytes = await (widget.imagePicker?.call() ??
                    pickAndCompressImage(maxEdge: 1024));
                if (bytes != null && mounted) setState(() => _photo = bytes);
              },
              child: Stack(
                children: [
                  PetAvatar(
                    emoji: _emoji.text.isEmpty ? '🐾' : _emoji.text,
                    size: 96,
                    placeholderColor: wo.pet,
                    bytes: _photo,
                    url: pet?.photoUrl == null
                        ? null
                        : '${api.baseUrl}${pet!.photoUrl}',
                    headers: api.imageHeaders,
                  ),
                  const Positioned(
                    right: 0,
                    bottom: 0,
                    child: CircleAvatar(
                      radius: 16,
                      child: Icon(Icons.camera_alt_outlined, size: 17),
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: WoTokens.space5),
          WoTextField(
            controller: _name,
            decoration: const InputDecoration(labelText: '名字 *'),
          ),
          const SizedBox(height: WoTokens.space4),
          WoTextField(
            controller: _emoji,
            maxLength: 4,
            decoration: const InputDecoration(labelText: 'Emoji 回退头像'),
            onChanged: (_) => setState(() {}),
          ),
          const SizedBox(height: WoTokens.space4),
          Row(
            children: [
              Expanded(
                child: WoTextField(
                  controller: _species,
                  decoration: const InputDecoration(labelText: '物种'),
                ),
              ),
              const SizedBox(width: WoTokens.space3),
              Expanded(
                child: WoTextField(
                  controller: _breed,
                  decoration: const InputDecoration(labelText: '品种'),
                ),
              ),
            ],
          ),
          const SizedBox(height: WoTokens.space4),
          WoDropdownButtonFormField<String>(
            initialValue: _sex,
            decoration: const InputDecoration(labelText: '性别'),
            items: const [
              DropdownMenuItem(value: 'male', child: Text('公')),
              DropdownMenuItem(value: 'female', child: Text('母')),
              DropdownMenuItem(value: 'unknown', child: Text('未知')),
            ],
            onChanged: (value) => setState(() => _sex = value),
          ),
          const SizedBox(height: WoTokens.space3),
          WoListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('生日'),
            subtitle: Text(_birthday == null ? '未设置' : _ymd(_birthday!)),
            trailing: const Icon(Icons.calendar_today_outlined),
            onTap: () async {
              final value = await _date(_birthday);
              if (value != null && mounted) setState(() => _birthday = value);
            },
          ),
          const SizedBox(height: WoTokens.space2),
          WoSwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('生日为估算日期'),
            value: _estimated,
            onChanged: (value) => setState(() => _estimated = value),
          ),
          const SizedBox(height: WoTokens.space2),
          WoListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('到家日期'),
            subtitle: Text(_arrival == null ? '未设置' : _ymd(_arrival!)),
            trailing: const Icon(Icons.home_outlined),
            onTap: () async {
              final value = await _date(_arrival);
              if (value != null && mounted) setState(() => _arrival = value);
            },
          ),
          const SizedBox(height: WoTokens.space3),
          WoDropdownButtonFormField<bool>(
            initialValue: _neutered,
            decoration: const InputDecoration(labelText: '绝育状态'),
            items: const [
              DropdownMenuItem(value: true, child: Text('已绝育')),
              DropdownMenuItem(value: false, child: Text('未绝育')),
            ],
            onChanged: (value) => setState(() => _neutered = value),
          ),
          const SizedBox(height: WoTokens.space4),
          WoTextField(
            controller: _notes,
            maxLines: 4,
            decoration: const InputDecoration(labelText: '备注'),
          ),
          if (pet != null) ...[
            const SizedBox(height: WoTokens.space6),
            WoTextButton(
              onPressed: _archive,
              style: WoTextButton.styleFrom(foregroundColor: Colors.redAccent),
              child: const Text('归档宠物档案'),
            ),
          ],
        ],
      ),
    );
  }
}

String _ymd(DateTime date) =>
    '${date.year}-${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')}';
