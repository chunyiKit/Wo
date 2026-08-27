import 'package:flutter/material.dart';

import '../../../data/api_client.dart';
import '../../../data/models.dart';
import '../../../data/wo_session.dart';
import '../../../theme/wo_tokens.dart';
import '../../../widgets/async_view.dart';
import '../../../widgets/member_avatar.dart';
import '../../../widgets/pet_avatar.dart';
import '../../../widgets/wo_card.dart';
import 'pet_record_edit_page.dart';
import 'pet_settings_page.dart';

class PetDetailPage extends StatefulWidget {
  const PetDetailPage({super.key, required this.petId});

  final String petId;

  @override
  State<PetDetailPage> createState() => _PetDetailPageState();
}

class _PetDetailPageState extends State<PetDetailPage> {
  late Future<PetDashboard> _future;
  PetDashboard? _dashboard;
  bool _loaded = false;
  bool _loadingMore = false;
  final Set<String> _completing = {};

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (!_loaded) {
      _loaded = true;
      _future = _fetch()..then(_store);
    }
  }

  Future<PetDashboard> _fetch() {
    final session = WoScope.of(context);
    return session.api.petDashboard(session.currentFamilyId!, widget.petId);
  }

  void _store(PetDashboard value) {
    if (mounted) setState(() => _dashboard = value);
  }

  Future<void> _refreshSilently() async {
    try {
      _store(await _fetch());
    } catch (_) {
      // 页面保留旧聚合数据。
    }
  }

  Future<void> _retry() {
    setState(() {
      _dashboard = null;
      _future = _fetch()..then(_store);
    });
    return _future;
  }

  Future<void> _editRecord([PetRecord? record]) async {
    final changed = await Navigator.of(context).push<bool>(
      MaterialPageRoute(
        builder: (_) => PetRecordEditPage(petId: widget.petId, record: record),
      ),
    );
    if (changed == true) await _refreshSilently();
  }

  Future<void> _complete(PetCarePlan plan) async {
    if (_completing.contains(plan.id)) return;
    final session = WoScope.of(context);
    double? weight;
    if (plan.dataKind == 'weight') {
      final controller = TextEditingController();
      weight = await showWoDialog<double>(
        context: context,
        builder: (context) => WoAlertDialog(
          title: Text('完成 · ${plan.name}'),
          content: WoTextField(
            controller: controller,
            autofocus: true,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            decoration: const InputDecoration(labelText: '体重（kg）'),
          ),
          actions: [
            WoTextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('取消'),
            ),
            WoFilledButton(
              onPressed: () => Navigator.pop(
                context,
                double.tryParse(controller.text.trim()),
              ),
              child: const Text('完成'),
            ),
          ],
        ),
      );
      controller.dispose();
      if (weight == null) return;
    }
    setState(() => _completing.add(plan.id));
    try {
      await session.api.completePetPlan(
        session.currentFamilyId!,
        widget.petId,
        plan,
        weightKg: weight,
      );
      await _refreshSilently();
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          WoSnackBar(
            content: Text(error is ApiException ? error.message : '完成失败'),
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _completing.remove(plan.id));
    }
  }

  Future<void> _loadMore() async {
    final dashboard = _dashboard;
    if (dashboard == null || dashboard.recordsCursor == null || _loadingMore) {
      return;
    }
    setState(() => _loadingMore = true);
    try {
      final session = WoScope.of(context);
      final page = await session.api.petRecords(
        session.currentFamilyId!,
        widget.petId,
        cursor: dashboard.recordsCursor,
      );
      if (mounted) {
        setState(() {
          _dashboard = PetDashboard(
            pet: dashboard.pet,
            todayPlans: dashboard.todayPlans,
            upcomingPlans: dashboard.upcomingPlans,
            latestWeight: dashboard.latestWeight,
            weightTrend: dashboard.weightTrend,
            records: [...dashboard.records, ...page.items],
            recordsCursor: page.cursor,
          );
        });
      }
    } finally {
      if (mounted) setState(() => _loadingMore = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final dashboard = _dashboard;
    return WoScaffold(
      appBar: WoAppBar(
        title: Text(dashboard?.pet.name ?? '宠物主页'),
        actions: [
          if (dashboard != null)
            WoIconButton(
              tooltip: '档案与照护计划',
              icon: const Icon(Icons.settings_outlined),
              onPressed: () async {
                final changed = await Navigator.of(context).push<bool>(
                  MaterialPageRoute(
                    builder: (_) => PetSettingsPage(pet: dashboard.pet),
                  ),
                );
                if (changed == true || mounted) await _refreshSilently();
              },
            ),
        ],
      ),
      body: dashboard != null
          ? _content(dashboard)
          : AsyncView<PetDashboard>(
              future: _future,
              onRetry: _retry,
              builder: (_, value) => _content(_dashboard ?? value),
            ),
      floatingActionButton: WoFloatingActionButton.extended(
        onPressed: _editRecord,
        backgroundColor: context.wo.pet,
        foregroundColor: context.wo.fg,
        icon: const Icon(Icons.add),
        label: const Text('新增记录'),
      ),
    );
  }

  Widget _content(PetDashboard dashboard) {
    final pet = dashboard.pet;
    final wo = context.wo;
    final api = WoScope.api(context);
    return RefreshIndicator(
      onRefresh: _refreshSilently,
      child: ListView(
        padding: const EdgeInsets.fromLTRB(
          WoTokens.space4,
          WoTokens.space4,
          WoTokens.space4,
          100,
        ),
        children: [
          WoCard(
            color: wo.pet,
            padding: const EdgeInsets.all(WoTokens.space5),
            child: Row(
              children: [
                PetAvatar(
                  emoji: pet.emoji,
                  size: 76,
                  placeholderColor: wo.bgTint,
                  url: pet.photoUrl == null
                      ? null
                      : '${api.baseUrl}${pet.photoUrl}',
                  headers: api.imageHeaders,
                ),
                const SizedBox(width: WoTokens.space4),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        pet.name,
                        style: Theme.of(context).textTheme.headlineSmall,
                      ),
                      Text(
                        [pet.breed, pet.species]
                            .whereType<String>()
                            .where((value) => value.isNotEmpty)
                            .join(' · '),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: WoTokens.space5),
          _heading('今日照护', '${dashboard.todayPlans.length} 项'),
          if (dashboard.todayPlans.isEmpty)
            _empty('今天没有待完成的照护')
          else
            for (final plan in dashboard.todayPlans)
              _plan(plan, complete: true),
          const SizedBox(height: WoTokens.space5),
          _heading('最近体重', null),
          WoCard(
            child: dashboard.latestWeight == null
                ? const Text('还没有体重记录')
                : Row(
                    children: [
                      Text(
                        '${dashboard.latestWeight!.weightKg.toStringAsFixed(2)} kg',
                        style: Theme.of(context).textTheme.headlineSmall,
                      ),
                      const Spacer(),
                      Text(_ymd(dashboard.latestWeight!.occurredOn)),
                    ],
                  ),
          ),
          const SizedBox(height: WoTokens.space5),
          _heading('即将到期', null),
          if (dashboard.upcomingPlans.isEmpty)
            _empty('暂无即将到期事项')
          else
            for (final plan in dashboard.upcomingPlans) _plan(plan),
          const SizedBox(height: WoTokens.space5),
          _heading('健康时间线', '${dashboard.records.length} 条'),
          if (dashboard.records.isEmpty)
            _empty('新增第一条健康或日常记录')
          else
            for (final record in dashboard.records) _record(record),
          if (dashboard.recordsCursor != null)
            WoTextButton(
              onPressed: _loadingMore ? null : _loadMore,
              child: Text(_loadingMore ? '加载中…' : '加载更多'),
            ),
        ],
      ),
    );
  }

  Widget _heading(String title, String? trailing) => Padding(
    padding: const EdgeInsets.only(bottom: WoTokens.space2),
    child: Row(
      children: [
        Text(title, style: Theme.of(context).textTheme.titleMedium),
        const Spacer(),
        if (trailing != null) Text(trailing),
      ],
    ),
  );

  Widget _empty(String text) => Padding(
    padding: const EdgeInsets.symmetric(vertical: WoTokens.space4),
    child: Text(text, style: TextStyle(color: context.wo.fgMid)),
  );

  Widget _plan(PetCarePlan plan, {bool complete = false}) => Padding(
    padding: const EdgeInsets.only(bottom: WoTokens.space2),
    child: WoCard(
      child: Row(
        children: [
          Text(plan.typeEmoji, style: const TextStyle(fontSize: 25)),
          const SizedBox(width: WoTokens.space3),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(plan.name),
                Text(
                  plan.nextDueDate == null ? '未设置日期' : _ymd(plan.nextDueDate!),
                  style: TextStyle(color: context.wo.fgMid),
                ),
              ],
            ),
          ),
          if (complete)
            WoFilledButton.tonal(
              onPressed: _completing.contains(plan.id)
                  ? null
                  : () => _complete(plan),
              child: Text(_completing.contains(plan.id) ? '处理中' : '完成'),
            ),
        ],
      ),
    ),
  );

  Widget _record(PetRecord record) => Padding(
    padding: const EdgeInsets.only(bottom: WoTokens.space2),
    child: WoCard(
      onTap: () => _editRecord(record),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(record.typeEmoji, style: const TextStyle(fontSize: 25)),
          const SizedBox(width: WoTokens.space3),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(child: Text(record.name)),
                    Text(_ymd(record.occurredOn)),
                  ],
                ),
                if (record.weightKg != null)
                  Text('${record.weightKg!.toStringAsFixed(2)} kg'),
                if (record.note != null && record.note!.isNotEmpty)
                  Text(
                    record.note!,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(color: context.wo.fgMid),
                  ),
                const SizedBox(height: WoTokens.space2),
                Row(
                  children: [
                    MemberAvatar(
                      url: record.creatorAvatarUrl,
                      emoji: record.creatorEmoji ?? '👤',
                      size: 20,
                    ),
                    const SizedBox(width: 6),
                    Text(record.creatorName ?? '家庭成员'),
                    if (record.attachments.isNotEmpty) ...[
                      const Spacer(),
                      const Icon(Icons.attach_file, size: 16),
                      Text('${record.attachments.length}'),
                    ],
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    ),
  );
}

String _ymd(DateTime date) =>
    '${date.year}-${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')}';
