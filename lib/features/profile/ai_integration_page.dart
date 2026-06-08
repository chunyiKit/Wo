import 'package:flutter/material.dart';

import '../../data/api_client.dart';
import '../../data/models.dart';
import '../../data/wo_session.dart';
import '../../theme/wo_tokens.dart';
import '../../widgets/wo_card.dart';

/// AI 集成设置：按家庭、按类型（多模态 / 文本 / 图片生成 / 视频生成）配置模型与密钥。
///
/// 插件不再写死模型，只按类型请求 AI；这里配置每类用哪个服务。API Key 写后即加密入库、
/// 永不回显（只显示末 4 位）。仅管理员可编辑（后端也会兜底校验）。
class AiIntegrationPage extends StatefulWidget {
  const AiIntegrationPage({super.key});

  @override
  State<AiIntegrationPage> createState() => _AiIntegrationPageState();
}

class _AiIntegrationPageState extends State<AiIntegrationPage> {
  List<AiModelConfig>? _models;
  Object? _loadError;

  String? get _familyId => WoScope.of(context).currentFamilyId;

  bool get _isAdmin {
    final role = WoScope.of(context).currentFamily?.myRole;
    return role == 'owner' || role == 'admin';
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  Future<void> _load() async {
    setState(() => _loadError = null);
    final fid = _familyId;
    if (fid == null) {
      setState(() => _models = const []);
      return;
    }
    try {
      final models = await WoScope.api(context).aiModels(fid);
      if (mounted) setState(() => _models = models);
    } catch (e) {
      if (mounted) setState(() => _loadError = e);
    }
  }

  /// 编辑 / 删除后静默刷新：保留旧列表在屏，后台重拉就地替换，不闪。
  Future<void> _refresh() async {
    final fid = _familyId;
    if (fid == null) return;
    try {
      final models = await WoScope.api(context).aiModels(fid);
      if (mounted) setState(() => _models = models);
    } catch (_) {
      // 刷新失败维持旧数据。
    }
  }

  void _toast(String msg) {
    if (mounted) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(msg)));
    }
  }

  String _errText(Object e) => switch (e) {
        ApiException ex => ex.message,
        NetworkException ex => ex.message,
        _ => '操作失败，请稍后再试',
      };

  Future<void> _edit(AiModelConfig m) async {
    final fid = _familyId;
    if (fid == null) return;
    final changed = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      builder: (_) => _ModelEditorSheet(familyId: fid, model: m),
    );
    if (changed == true) await _refresh();
  }

  Future<void> _delete(AiModelConfig m) async {
    final fid = _familyId;
    if (fid == null) return;
    final api = WoScope.api(context); // capture before async gaps
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('删除「${m.typeLabel}」配置'),
        content: const Text('删除后，需要这类 AI 的功能将无法使用，直到重新配置。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    try {
      await api.deleteAiModel(fid, m.aiType);
      await _refresh();
      _toast('已删除');
    } catch (e) {
      _toast(_errText(e));
    }
  }

  Future<void> _test(AiModelConfig m) async {
    final fid = _familyId;
    if (fid == null) return;
    _toast('正在测试连接…');
    try {
      await WoScope.api(context).testAiModel(fid, m.aiType);
      _toast('连接正常');
    } catch (e) {
      _toast(_errText(e));
    }
  }

  @override
  Widget build(BuildContext context) {
    final wo = context.wo;
    final t = Theme.of(context).textTheme;
    return Scaffold(
      appBar: AppBar(title: const Text('AI 集成设置')),
      body: SafeArea(
        top: false,
        child: Builder(
          builder: (context) {
            if (_loadError != null) {
              return _ErrorRetry(onRetry: _load);
            }
            final models = _models;
            if (models == null) {
              return const Center(child: CircularProgressIndicator());
            }
            return ListView(
              padding: const EdgeInsets.fromLTRB(
                WoTokens.space4,
                WoTokens.space4,
                WoTokens.space4,
                WoTokens.space8,
              ),
              children: [
                Text(
                  '把各类 AI 服务接到这里，插件按「类型」自动调用对应模型。'
                  '密钥仅本家庭可用、加密保存、不会显示原文。',
                  style: t.bodySmall?.copyWith(color: wo.fgMid, height: 1.5),
                ),
                if (!_isAdmin) ...[
                  const SizedBox(height: WoTokens.space3),
                  Container(
                    padding: const EdgeInsets.all(WoTokens.space3),
                    decoration: BoxDecoration(
                      color: wo.bgTint,
                      borderRadius: BorderRadius.circular(WoTokens.space3),
                    ),
                    child: Text(
                      '只有管理员可以修改 AI 配置，你当前为只读查看。',
                      style: t.bodySmall?.copyWith(color: wo.fgMid),
                    ),
                  ),
                ],
                const SizedBox(height: WoTokens.space4),
                for (final m in models) ...[
                  _ModelCard(
                    model: m,
                    canEdit: _isAdmin,
                    onEdit: () => _edit(m),
                    onDelete: () => _delete(m),
                    onTest: () => _test(m),
                  ),
                  const SizedBox(height: WoTokens.space3),
                ],
              ],
            );
          },
        ),
      ),
    );
  }
}

/// 单个类型的配置卡片。
class _ModelCard extends StatelessWidget {
  const _ModelCard({
    required this.model,
    required this.canEdit,
    required this.onEdit,
    required this.onDelete,
    required this.onTest,
  });

  final AiModelConfig model;
  final bool canEdit;
  final VoidCallback onEdit;
  final VoidCallback onDelete;
  final VoidCallback onTest;

  @override
  Widget build(BuildContext context) {
    final wo = context.wo;
    final t = Theme.of(context).textTheme;
    final m = model;

    return WoCard(
      padding: const EdgeInsets.all(WoTokens.space4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text(
                m.typeLabel,
                style: t.titleSmall?.copyWith(fontWeight: FontWeight.w700),
              ),
              const SizedBox(width: WoTokens.space2),
              if (!m.callable) _Chip(text: '预留', color: wo.fgDim),
              const Spacer(),
              if (m.configured)
                _Chip(
                  text: m.enabled ? '已启用' : '已停用',
                  color: m.enabled ? wo.accent : wo.fgDim,
                ),
            ],
          ),
          const SizedBox(height: WoTokens.space2),
          if (m.configured) ...[
            Text(
              '${m.label} · ${m.model}',
              style: t.bodyMedium?.copyWith(color: wo.fg),
            ),
            const SizedBox(height: 2),
            Text(
              m.baseUrl ?? '',
              style: t.bodySmall?.copyWith(color: wo.fgDim),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            const SizedBox(height: 2),
            Text(
              m.hasKey ? '密钥 ••••${m.keyHint}' : '未设置密钥',
              style: t.bodySmall?.copyWith(color: wo.fgMid),
            ),
          ] else
            Text(
              m.callable ? '未配置' : '未配置（暂未接入插件，可先留好配置）',
              style: t.bodyMedium?.copyWith(color: wo.fgMid),
            ),
          const SizedBox(height: WoTokens.space3),
          Row(
            children: [
              if (m.configured && m.callable)
                TextButton(onPressed: onTest, child: const Text('测试连接')),
              const Spacer(),
              if (canEdit) ...[
                if (m.configured)
                  TextButton(
                    onPressed: onDelete,
                    child: Text('删除', style: TextStyle(color: wo.danger)),
                  ),
                FilledButton.tonal(
                  onPressed: onEdit,
                  child: Text(m.configured ? '编辑' : '配置'),
                ),
              ],
            ],
          ),
        ],
      ),
    );
  }
}

class _Chip extends StatelessWidget {
  const _Chip({required this.text, required this.color});
  final String text;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(WoTokens.chipRadius),
      ),
      child: Text(
        text,
        style: TextStyle(
          color: color,
          fontSize: 11,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}

/// 编辑某类型配置的底部表单。返回 true 表示有保存改动。
class _ModelEditorSheet extends StatefulWidget {
  const _ModelEditorSheet({required this.familyId, required this.model});

  final String familyId;
  final AiModelConfig model;

  @override
  State<_ModelEditorSheet> createState() => _ModelEditorSheetState();
}

class _ModelEditorSheetState extends State<_ModelEditorSheet> {
  late final TextEditingController _label;
  late final TextEditingController _baseUrl;
  late final TextEditingController _model;
  final _apiKey = TextEditingController();

  late bool _enabled;
  bool _obscure = true;
  bool _busy = false;

  AiModelConfig get _m => widget.model;

  @override
  void initState() {
    super.initState();
    _label = TextEditingController(text: _m.label ?? '');
    _baseUrl = TextEditingController(text: _m.baseUrl ?? '');
    _model = TextEditingController(text: _m.model ?? '');
    _enabled = _m.configured ? _m.enabled : true;
  }

  @override
  void dispose() {
    _label.dispose();
    _baseUrl.dispose();
    _model.dispose();
    _apiKey.dispose();
    super.dispose();
  }

  void _toast(String msg) {
    if (mounted) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(msg)));
    }
  }

  Future<void> _save() async {
    if (_busy) return;
    final label = _label.text.trim();
    final baseUrl = _baseUrl.text.trim();
    final model = _model.text.trim();
    if (label.isEmpty || baseUrl.isEmpty || model.isEmpty) {
      _toast('名称 / 接口地址 / 模型 都要填写');
      return;
    }
    // 首次配置必须填 key；编辑时留空表示保留原 key。
    if (!_m.hasKey && _apiKey.text.trim().isEmpty) {
      _toast('请填写 API Key');
      return;
    }
    setState(() => _busy = true);
    try {
      await WoScope.api(context).updateAiModel(
        widget.familyId,
        _m.aiType,
        label: label,
        baseUrl: baseUrl,
        model: model,
        apiKey: _apiKey.text.trim().isEmpty ? null : _apiKey.text.trim(),
        enabled: _enabled,
      );
      if (mounted) Navigator.pop(context, true);
    } catch (e) {
      if (mounted) setState(() => _busy = false);
      final msg = switch (e) {
        ApiException ex => ex.message,
        NetworkException ex => ex.message,
        _ => '保存失败，请稍后再试',
      };
      _toast(msg);
    }
  }

  @override
  Widget build(BuildContext context) {
    final wo = context.wo;
    final t = Theme.of(context).textTheme;
    final bottom = MediaQuery.of(context).viewInsets.bottom;

    return Padding(
      padding: EdgeInsets.only(bottom: bottom),
      child: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(WoTokens.space5),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                '${_m.configured ? '编辑' : '配置'}「${_m.typeLabel}」模型',
                style: t.titleMedium?.copyWith(fontWeight: FontWeight.w700),
              ),
              if (!_m.callable) ...[
                const SizedBox(height: 4),
                Text(
                  '该类型暂无插件调用，可先把配置留好，将来直接生效。',
                  style: t.bodySmall?.copyWith(color: wo.fgMid),
                ),
              ],
              const SizedBox(height: WoTokens.space4),
              TextField(
                controller: _label,
                decoration: const InputDecoration(
                  labelText: '名称',
                  hintText: '如 Kimi、DeepSeek',
                ),
              ),
              const SizedBox(height: WoTokens.space3),
              TextField(
                controller: _baseUrl,
                keyboardType: TextInputType.url,
                autocorrect: false,
                decoration: const InputDecoration(
                  labelText: '接口地址（base_url）',
                  hintText: 'https://api.moonshot.cn/v1',
                ),
              ),
              const SizedBox(height: WoTokens.space3),
              TextField(
                controller: _model,
                autocorrect: false,
                decoration: const InputDecoration(
                  labelText: '模型 id',
                  hintText: '如 kimi-k2.6、deepseek-chat',
                ),
              ),
              const SizedBox(height: WoTokens.space3),
              TextField(
                controller: _apiKey,
                obscureText: _obscure,
                autocorrect: false,
                enableSuggestions: false,
                decoration: InputDecoration(
                  labelText: 'API Key',
                  hintText: _m.hasKey
                      ? '已配置 ••••${_m.keyHint}，留空则不修改'
                      : '粘贴你的 API Key',
                  suffixIcon: IconButton(
                    icon: Icon(
                      _obscure ? Icons.visibility_off : Icons.visibility,
                    ),
                    onPressed: () => setState(() => _obscure = !_obscure),
                  ),
                ),
              ),
              const SizedBox(height: WoTokens.space2),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('启用'),
                subtitle: const Text('停用后这类 AI 将视为未配置'),
                value: _enabled,
                onChanged: (v) => setState(() => _enabled = v),
              ),
              const SizedBox(height: WoTokens.space3),
              FilledButton(
                onPressed: _busy ? null : _save,
                child: _busy
                    ? const SizedBox(
                        height: 18,
                        width: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Text('保存'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ErrorRetry extends StatelessWidget {
  const _ErrorRetry({required this.onRetry});
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final wo = context.wo;
    final t = Theme.of(context).textTheme;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(WoTokens.space6),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text('加载失败', style: t.titleMedium),
            const SizedBox(height: WoTokens.space2),
            Text(
              '请检查网络后重试。',
              style: t.bodyMedium?.copyWith(color: wo.fgMid),
            ),
            const SizedBox(height: WoTokens.space4),
            FilledButton(onPressed: onRetry, child: const Text('重试')),
          ],
        ),
      ),
    );
  }
}
