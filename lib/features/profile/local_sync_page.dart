import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../../data/wo_session.dart';
import '../../local/local_runtime.dart';
import '../../local/sync/peer_registry.dart';
import '../../local/sync/sync_coordinator.dart';
import '../../theme/wo_tokens.dart';
import '../../widgets/member_avatar.dart';

/// 配对文本就是一次性授权，不自动读取剪贴板或生成/接受邀请。
class LocalSyncPage extends StatefulWidget {
  const LocalSyncPage({super.key});
  @override
  State<LocalSyncPage> createState() => _LocalSyncPageState();
}

class _LocalSyncPageState extends State<LocalSyncPage> with WidgetsBindingObserver {
  final _input = TextEditingController();
  LocalRuntime? _runtime;
  List<PeerLink>? _peers;
  final _members = <String, Map<String, dynamic>>{};
  final _families = <String, String>{};
  PairInvitation? _invitation;
  String? _qr, _error;
  Timer? _timer;
  bool _busy = false, _fetching = false;
  int _ticks = 0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _runtime = LocalRuntime.instance;
    _runtime?.sync.addListener(_statusChanged);
    unawaited(_load());
    _timer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted || WidgetsBinding.instance.lifecycleState == AppLifecycleState.paused ||
          WidgetsBinding.instance.lifecycleState == AppLifecycleState.detached) return;
      if (_invitation != null) {
        if (_remaining <= 0) _eraseInvitation();
        setState(() {});
      }
      if (++_ticks % 3 == 0) unawaited(_load());
    });
  }
  int get _remaining => _invitation == null ? 0 :
    ((_invitation!.expires - DateTime.now().millisecondsSinceEpoch) / 1000).ceil();
  void _statusChanged() { if (mounted) setState(() {}); }
  void _eraseInvitation() {
    final old = _invitation;
    _invitation = null; _qr = null;
    if (old != null) old.secret.fillRange(0, old.secret.length, 0);
  }
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) {
      _eraseInvitation(); _input.clear();
      if (mounted) setState(() {});
    } else { unawaited(_load()); }
  }
  Future<void> _load() async {
    final runtime = _runtime;
    if (runtime == null || _fetching) return;
    _fetching = true;
    try {
      final peers = await runtime.registry.links();
      final members = <String, Map<String, dynamic>>{}, families = <String, String>{};
      for (final peer in peers) {
        final member = await runtime.store.get(peer.familyId,
          '/families/${peer.familyId}/members', peer.remoteDeviceId);
        if (member != null && member['status'] == 'active' &&
            member['user_id'] == peer.remoteDeviceId && member['family_id'] == peer.familyId) {
          members[peer.id] = member;
        }
        final family = await runtime.store.get(peer.familyId,
          '/families/${peer.familyId}/family', peer.familyId);
        families[peer.familyId] = family?['name'] as String? ?? '待完成首次同步的家庭';
      }
      if (!mounted) return;
      setState(() {
        _peers = peers; _members..clear()..addAll(members);
        _families..clear()..addAll(families);
      });
    } catch (_) {
      if (mounted) setState(() => _error = '配对列表未能读取，已保留现有显示');
    } finally { _fetching = false; }
  }
  Future<void> _run(Future<void> Function() action) async {
    if (_busy) return;
    setState(() { _busy = true; _error = null; });
    try { await action(); await _load(); }
    catch (_) { if (mounted) setState(() => _error = '操作未完成，请核对邀请有效期、家庭权限或局域网连接'); }
    finally { if (mounted) setState(() => _busy = false); }
  }
  Future<bool> _confirm(String title, String message, String action) async =>
    await showWoDialog<bool>(context: context, builder: (dialog) => WoAlertDialog(
      title: Text(title), content: Text(message), actions: [
        WoTextButton(onPressed: () => Navigator.pop(dialog, false), child: const Text('取消')),
        WoFilledButton(onPressed: () => Navigator.pop(dialog, true), child: Text(action)),
      ],
    )) == true;

  Future<void> _create() async {
    final runtime = _runtime, fid = WoScope.of(context).currentFamilyId;
    if (runtime == null || fid == null || _busy) return;
    final yes = await _confirm('授权另一台手机',
      '持有邀请的设备可加入当前家庭并读取家庭共享记录。请面对面核对对方身份；私密内容不会共享，伴侣内容需另行双方确认。邀请含密钥，不要转发或截图外传。', '生成五分钟邀请');
    if (!yes || !mounted) return;
    await _run(() async {
      final invitation = await runtime.registry.createInvitation(fid);
      if (!mounted) { invitation.secret.fillRange(0, invitation.secret.length, 0); return; }
      _eraseInvitation(); setState(() { _invitation = invitation; _qr = invitation.encode(); });
    });
  }
  Future<void> _accept() async {
    final runtime = _runtime;
    if (runtime == null || _busy) return;
    PairInvitation invitation;
    try { invitation = PairInvitation.parse(_input.text.trim()); }
    catch (_) { setState(() => _error = '邀请无效或已过期，请向当面核对的家人重新获取'); return; }
    try {
      final yes = await _confirm('确认配对授权',
        '家庭：${invitation.familyName}\n设备：${invitation.deviceId}\n请在另一台手机核对这两个标识。确认后将建立家庭数据同步授权；本机现有家庭不会被覆盖。私密内容不会共享，伴侣内容需要另行双方确认。', '确认并建立配对');
      if (!yes || !mounted) return;
      await _run(() async {
        await runtime.registry.accept(invitation);
        _input.clear();
        await runtime.sync.start();
      });
    } finally { invitation.secret.fillRange(0, invitation.secret.length, 0); }
  }
  Future<void> _couple(PeerLink peer, bool value) async {
    if (_busy) return;
    final yes = await _confirm(value ? '确认伴侣范围' : '暂停伴侣同步', value
      ? '只应为已当面确认的伴侣设备开启。双方都确认后才交换这个配对的伴侣回忆。私密回忆仍只在本机。已经传出的内容无法远程收回。'
      : '停止后续伴侣范围传输；两端已复制的内容仍可能保留。此操作不会把伴侣回忆改为全家可见。', value ? '我确认此伴侣' : '暂停后续传输');
    if (!yes || !mounted) return;
    await _run(() => _runtime!.sync.coupleConsent(peer.id, local: value));
  }
  Future<void> _revoke(PeerLink peer) async {
    if (_busy) return;
    final yes = await _confirm('撤销这台设备',
      '将关闭此配对的连接并拒绝本机后续同步。其他配对不会自动被撤销，也不能删除对方离线保存或另行复制的历史内容。', '撤销本机配对');
    if (!yes || !mounted) return;
    await _run(() => _runtime!.sync.revoke(peer.id));
  }
  Future<void> _manual(PeerLink peer) async {
    if (_busy || !peer.active) return;
    final address = TextEditingController(), port = TextEditingController();
    try {
      final yes = await showWoDialog<bool>(context: context, builder: (dialog) => WoAlertDialog(
        title: const Text('连接已配对手机'),
        content: Column(mainAxisSize: MainAxisSize.min, children: [
          const Text('仅输入对方在同一 Wi-Fi 显示的私有 IP 和监听端口。握手仍会核对已配对身份。'),
          TextField(controller: address, maxLength: 128, decoration: const InputDecoration(labelText: '私有 IP（不含协议或路径）')),
          TextField(controller: port, maxLength: 5, keyboardType: TextInputType.number, decoration: const InputDecoration(labelText: '监听端口')),
        ]), actions: [
          WoTextButton(onPressed: () => Navigator.pop(dialog, false), child: const Text('取消')),
          WoFilledButton(onPressed: () => Navigator.pop(dialog, true), child: const Text('连接')),
        ],
      ));
      if (yes != true || !mounted) return;
      final ip = InternetAddress.tryParse(address.text.trim()), number = int.tryParse(port.text.trim());
      if (ip == null || !LocalSyncCoordinator.localAddress(ip) || number == null || number < 1 || number > 65535) {
        setState(() => _error = '请输入有效的私有局域网 IP 和 1–65535 端口'); return;
      }
      await _run(() async { await _runtime!.sync.start(); await _runtime!.sync.connect(peer, ip.address, number); });
    } finally { address.dispose(); port.dispose(); }
  }

  Widget _peer(PeerLink peer) {
    final member = _members[peer.id];
    return Card(key: ValueKey(peer.id), child: Padding(
      padding: const EdgeInsets.all(WoTokens.space4), child: Column(
        crossAxisAlignment: CrossAxisAlignment.start, children: [
          WoListTile(contentPadding: EdgeInsets.zero,
            leading: MemberAvatar(url: member?['avatar_url'] as String?, emoji: member?['avatar_emoji'] as String? ?? '👤', size: 36),
            title: Text(member?['display_name'] as String? ?? '待确认的家人设备'),
            subtitle: Text('${_families[peer.familyId] ?? peer.familyId}\n${peer.remoteDeviceId}'),
            isThreeLine: true,
            trailing: Text(peer.active ? '已配对' : '已撤销'),
          ),
          if (peer.active) ...[
            WoSwitchListTile(contentPadding: EdgeInsets.zero, title: const Text('允许此配对的伴侣回忆同步'),
              subtitle: Text(peer.coupleLocal && peer.coupleRemote ? '双方已确认此配对范围' : peer.coupleRemote ? '对方已确认，等待本机确认' : '对方尚未确认；不会传输伴侣回忆'),
              value: peer.coupleLocal, onChanged: _busy ? null : (value) => unawaited(_couple(peer, value))),
            Wrap(spacing: WoTokens.space2, children: [
              WoOutlinedButton(onPressed: _busy ? null : () => unawaited(_manual(peer)), child: const Text('手动连接')),
              WoTextButton(onPressed: _busy ? null : () => unawaited(_revoke(peer)), child: const Text('撤销此配对')),
            ]),
          ],
        ],
      ),
    ));
  }
  @override
  Widget build(BuildContext context) {
    final runtime = _runtime;
    return WoScaffold(appBar: WoAppBar(title: const Text('本地配对与同步')),
      body: SafeArea(top: false, child: ListView(padding: const EdgeInsets.all(WoTokens.space5), children: [
        const Text('两端打开 App、连接同一 Wi-Fi 后自动发现已配对手机。只交换家庭记录及获双方许可的伴侣记录、回忆缩略图；照片和视频原件只备份到电脑。私密回忆不向手机广播。'),
        const SizedBox(height: WoTokens.space4),
        Text(runtime?.sync.status ?? '本机同步尚未就绪'),
        if (runtime?.sync.port != null) SelectableText('本机监听端口：${runtime!.sync.port}'),
        Wrap(spacing: WoTokens.space2, children: [
          WoOutlinedButton(onPressed: _busy || runtime == null ? null : () => unawaited(_run(runtime.sync.start)), child: const Text('启动前台发现')),
          WoTextButton(onPressed: _busy || runtime == null ? null : () => unawaited(_run(runtime.sync.stop)), child: const Text('暂停前台发现')),
        ]),
        const SizedBox(height: WoTokens.space4),
        WoFilledButton(onPressed: _busy || runtime == null ? null : () => unawaited(_create()), child: const Text('邀请另一台手机')),
        if (_qr != null && _remaining > 0) ...[
          const SizedBox(height: WoTokens.space4),
          Center(child: QrImageView(data: _qr!, size: 220, backgroundColor: Colors.white)),
          Text('剩余 $_remaining 秒；含配对密钥，请勿转发或截图外传。离开前台会隐藏。'),
          SelectableText(_qr!, style: Theme.of(context).textTheme.bodySmall),
          WoTextButton(onPressed: () => setState(_eraseInvitation), child: const Text('隐藏本页邀请')),
        ],
        const SizedBox(height: WoTokens.space5),
        TextField(controller: _input, maxLength: 4096, minLines: 2, maxLines: 5,
          autocorrect: false, enableSuggestions: false, decoration: const InputDecoration(labelText: '输入家人当面提供的完整邀请文本')),
        WoFilledButton(onPressed: _busy || runtime == null ? null : () => unawaited(_accept()), child: const Text('核对并接受邀请')),
        if (_error != null) Padding(padding: const EdgeInsets.symmetric(vertical: WoTokens.space3), child: Text(_error!)),
        const SizedBox(height: WoTokens.space5),
        Text('已配对设备', style: Theme.of(context).textTheme.titleMedium),
        if (runtime != null && _peers == null) const Padding(padding: EdgeInsets.all(WoTokens.space4), child: LinearProgressIndicator()),
        if (_peers?.isEmpty == true) const Text('尚未与其他手机建立配对'),
        for (final peer in _peers ?? <PeerLink>[]) _peer(peer),
      ])),
    );
  }
  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this); _timer?.cancel();
    _runtime?.sync.removeListener(_statusChanged); _eraseInvitation(); _input.dispose();
    super.dispose();
  }
}
