import 'package:flutter/material.dart';

import '../../data/device_cache.dart';
import '../../theme/wo_tokens.dart';
import '../../widgets/wo_card.dart';

/// 清除缓存：展示「应用占用大小」及其构成（数据缓存 / 历史安装包 / 应用数据），
/// 并可分别清理「数据缓存」与「历史安装包」。
///
/// 刷新约定（见 CLAUDE.md「列表页刷新不能闪一下」）：测算结果缓存进 [_usage]，
/// 清理后**就地更新数字**而非整页转圈；仅首屏与首屏失败重试才显示加载态。
class CacheCleanupPage extends StatefulWidget {
  const CacheCleanupPage({super.key});

  @override
  State<CacheCleanupPage> createState() => _CacheCleanupPageState();
}

enum _Section { dataCache, apk }

class _CacheCleanupPageState extends State<CacheCleanupPage> {
  final _service = DeviceCacheService();

  CacheUsage? _usage; // null = 首屏测算中。
  Object? _error; // 首屏测算失败。
  _Section? _clearing; // 正在清理的项，期间禁用按钮。

  @override
  void initState() {
    super.initState();
    _measure();
  }

  Future<void> _measure() async {
    try {
      final usage = await _service.measure();
      if (!mounted) return;
      setState(() {
        _usage = usage;
        _error = null;
      });
    } catch (e) {
      if (mounted) setState(() => _error = e);
    }
  }

  /// 首屏失败时的重试：回到加载态再测算。
  void _retry() {
    setState(() {
      _usage = null;
      _error = null;
    });
    _measure();
  }

  Future<void> _clear(_Section section) async {
    final before = _usage;
    final confirmed = await _confirm(section);
    if (!confirmed || !mounted) return;

    setState(() => _clearing = section);
    try {
      switch (section) {
        case _Section.dataCache:
          await _service.clearDataCache();
        case _Section.apk:
          await _service.clearApks();
      }
      final after = await _service.measure();
      final freed = _freed(section, before, after);
      if (!mounted) return;
      setState(() {
        _usage = after;
        _clearing = null;
      });
      _toast(freed > 0 ? '已清理 ${formatBytes(freed)}' : '没有可清理的内容');
    } catch (_) {
      if (!mounted) return;
      setState(() => _clearing = null);
      _toast('清理失败，请稍后再试');
    }
  }

  int _freed(_Section section, CacheUsage? before, CacheUsage after) {
    if (before == null) return 0;
    final delta = switch (section) {
      _Section.dataCache => before.dataCacheBytes - after.dataCacheBytes,
      _Section.apk => before.apkBytes - after.apkBytes,
    };
    return delta < 0 ? 0 : delta;
  }

  Future<bool> _confirm(_Section section) async {
    final (title, body) = switch (section) {
      _Section.dataCache => (
          '清理数据缓存？',
          '将清空已缓存的图片与临时文件。不影响你的数据，下次浏览会重新加载。',
        ),
      _Section.apk => (
          '清理历史安装包？',
          '将删除检查更新时下载的安装包。下次更新会重新下载，不影响已安装的应用。',
        ),
    };
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title),
        content: Text(body),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('清理'),
          ),
        ],
      ),
    );
    return ok ?? false;
  }

  void _toast(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..clearSnackBars()
      ..showSnackBar(SnackBar(content: Text(msg)));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('清除缓存')),
      body: SafeArea(top: false, child: _body(context)),
    );
  }

  Widget _body(BuildContext context) {
    final usage = _usage;
    if (usage == null) {
      if (_error != null) return _ErrorRetry(onRetry: _retry);
      return const Center(child: CircularProgressIndicator());
    }
    return ListView(
      padding: const EdgeInsets.all(WoTokens.space5),
      children: [
        _TotalHero(usage: usage),
        const SizedBox(height: WoTokens.space6),
        _sectionLabel(context, '可清理空间'),
        const SizedBox(height: WoTokens.space2),
        WoCard(
          padding: EdgeInsets.zero,
          child: Column(
            children: [
              _UsageRow(
                icon: Icons.image_outlined,
                title: '数据缓存',
                subtitle: '图片、临时文件',
                bytes: usage.dataCacheBytes,
                busy: _clearing == _Section.dataCache,
                disabled: _clearing != null,
                onClear: () => _clear(_Section.dataCache),
              ),
              const _RowDivider(),
              _UsageRow(
                icon: Icons.archive_outlined,
                title: '历史安装包',
                subtitle: '检查更新时下载的安装包',
                bytes: usage.apkBytes,
                busy: _clearing == _Section.apk,
                disabled: _clearing != null,
                onClear: () => _clear(_Section.apk),
              ),
            ],
          ),
        ),
        const SizedBox(height: WoTokens.space5),
        _sectionLabel(context, '不可清理'),
        const SizedBox(height: WoTokens.space2),
        WoCard(
          padding: EdgeInsets.zero,
          child: _UsageRow(
            icon: Icons.lock_outline,
            title: '应用数据',
            subtitle: '登录、设置等核心数据',
            bytes: usage.appDataBytes,
          ),
        ),
      ],
    );
  }

  Widget _sectionLabel(BuildContext context, String text) {
    final wo = context.wo;
    final t = Theme.of(context).textTheme;
    return Padding(
      padding: const EdgeInsets.only(left: WoTokens.space2),
      child: Text(text, style: t.bodySmall?.copyWith(color: wo.fgMid)),
    );
  }
}

/// 顶部「应用占用大小」展示：大号总量 + 三段构成比例条。
class _TotalHero extends StatelessWidget {
  const _TotalHero({required this.usage});

  final CacheUsage usage;

  @override
  Widget build(BuildContext context) {
    final wo = context.wo;
    final t = Theme.of(context).textTheme;
    return WoCard(
      padding: const EdgeInsets.all(WoTokens.space6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            '应用占用',
            style: t.bodyMedium?.copyWith(color: wo.fgMid),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: WoTokens.space2),
          Text(
            formatBytes(usage.totalBytes),
            style: t.displaySmall?.copyWith(
              color: wo.fg,
              fontWeight: FontWeight.w700,
            ),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: WoTokens.space5),
          _ProportionBar(usage: usage),
          const SizedBox(height: WoTokens.space2),
          Text(
            '「窝」在本机使用的存储空间',
            style: t.bodySmall?.copyWith(color: wo.fgMid),
            textAlign: TextAlign.center,
          ),
        ],
      ),
    );
  }
}

/// 三类占用的比例条：数据缓存 / 安装包 / 应用数据。
class _ProportionBar extends StatelessWidget {
  const _ProportionBar({required this.usage});

  final CacheUsage usage;

  @override
  Widget build(BuildContext context) {
    final wo = context.wo;
    final total = usage.totalBytes;
    if (total <= 0) {
      return Container(
        height: 8,
        decoration: BoxDecoration(
          color: wo.bgTint,
          borderRadius: BorderRadius.circular(999),
        ),
      );
    }
    final segments = <(int, Color)>[
      (usage.dataCacheBytes, wo.accent),
      (usage.apkBytes, wo.accentDeep),
      (usage.appDataBytes, wo.bgTint),
    ].where((s) => s.$1 > 0).toList(growable: false);

    return ClipRRect(
      borderRadius: BorderRadius.circular(999),
      child: SizedBox(
        height: 8,
        child: Row(
          children: [
            for (final (bytes, color) in segments)
              Expanded(
                flex: bytes,
                child: Container(color: color),
              ),
          ],
        ),
      ),
    );
  }
}

/// 单行占用项：图标 + 标题/副标题 + 大小，可选清理按钮 / 进行中转圈。
class _UsageRow extends StatelessWidget {
  const _UsageRow({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.bytes,
    this.onClear,
    this.busy = false,
    this.disabled = false,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final int bytes;
  final VoidCallback? onClear;
  final bool busy;
  final bool disabled;

  @override
  Widget build(BuildContext context) {
    final wo = context.wo;
    final t = Theme.of(context).textTheme;
    return Padding(
      padding: const EdgeInsets.symmetric(
        horizontal: WoTokens.space4,
        vertical: WoTokens.space3,
      ),
      child: Row(
        children: [
          Icon(icon, color: wo.fgMid, size: 22),
          const SizedBox(width: WoTokens.space3),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: t.bodyLarge),
                const SizedBox(height: 2),
                Text(
                  subtitle,
                  style: t.bodySmall?.copyWith(color: wo.fgMid),
                ),
              ],
            ),
          ),
          const SizedBox(width: WoTokens.space3),
          Text(
            formatBytes(bytes),
            style: t.bodyMedium?.copyWith(
              color: wo.fg,
              fontWeight: FontWeight.w600,
            ),
          ),
          if (onClear != null) ...[
            const SizedBox(width: WoTokens.space2),
            _ClearAction(
              busy: busy,
              // 没有可清理内容、或正有其它项在清理时禁用。
              onPressed: (disabled || bytes <= 0) ? null : onClear,
            ),
          ],
        ],
      ),
    );
  }
}

class _ClearAction extends StatelessWidget {
  const _ClearAction({required this.busy, required this.onPressed});

  final bool busy;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    if (busy) {
      return const SizedBox(
        width: 56,
        height: 36,
        child: Center(
          child: SizedBox(
            width: 18,
            height: 18,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
        ),
      );
    }
    return TextButton(onPressed: onPressed, child: const Text('清理'));
  }
}

class _RowDivider extends StatelessWidget {
  const _RowDivider();

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(left: WoTokens.space4 + 22 + WoTokens.space3),
      child: Divider(height: 1, color: context.wo.hairline),
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
            const Text('😣', style: TextStyle(fontSize: 40)),
            const SizedBox(height: WoTokens.space4),
            Text('读取占用失败', style: t.titleMedium),
            const SizedBox(height: WoTokens.space2),
            Text(
              '无法测算本机存储占用',
              style: t.bodySmall?.copyWith(color: wo.fgMid),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: WoTokens.space5),
            FilledButton.tonal(onPressed: onRetry, child: const Text('重试')),
          ],
        ),
      ),
    );
  }
}
