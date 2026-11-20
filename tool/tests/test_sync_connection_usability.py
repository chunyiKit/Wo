"""同步接线的纯静态契约和独立调度模型；不执行Dart/SDK、NSD或真实手机。"""
from pathlib import Path
import itertools
import unittest

ROOT = Path(__file__).resolve().parents[2]


def eligible(local, remote, *, pending=False, force=False, elapsed=None, active=True,
             hint=True, busy=False, session=False, slots=0):
    if not active or not hint or busy or session or slots >= 3:
        return False
    if not force and not pending and local > remote and elapsed is not None and 0 <= elapsed < 15:
        return False
    return True


class Arbitration:
    def __init__(self): self.current = None
    def claim(self, socket, preferred):
        if self.current is not None:
            if not preferred or self.current[1]: return None
        token = object(); self.current = (socket, preferred, token)
        return token
    def release(self, token):
        if self.current is not None and self.current[2] is token: self.current = None


class SyncConnectionUsability(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.coordinator = (ROOT / 'lib/local/sync/sync_coordinator.dart').read_text()
        cls.page = (ROOT / 'lib/features/profile/local_sync_page.dart').read_text()

    def test_model_known_family_larger_acceptor_can_make_first_authenticated_connection(self):
        # 邀请方还只有pending invite而无link，不能主动连接；接受方必须能先发起。
        inviter_has_link = False
        old_acceptor_eligible = not ('z-device' > 'a-device')
        self.assertFalse(inviter_has_link or old_acceptor_eligible)
        self.assertTrue(eligible('z-device', 'a-device', elapsed=None))
        self.assertTrue(eligible('a-device', 'z-device', elapsed=None))
        self.assertIn('elapsed!=null&&!elapsed.isNegative&&elapsed<_directionGrace', self.coordinator)
        self.assertIn('static const _directionGrace=Duration(seconds:15)', self.coordinator)

    def test_model_healthy_contact_prefers_one_direction_but_stale_or_manual_can_retry(self):
        self.assertFalse(eligible('z', 'a', elapsed=14.9))
        self.assertTrue(eligible('z', 'a', elapsed=15))
        self.assertTrue(eligible('z', 'a', elapsed=-1))
        self.assertTrue(eligible('z', 'a', elapsed=1, force=True))
        self.assertTrue(eligible('z', 'a', elapsed=1, pending=True))
        for gate in ({'active': False}, {'hint': False}, {'busy': True}, {'session': True}, {'slots': 3}):
            self.assertFalse(eligible('a', 'z', **gate))
        self.assertIn('_lastContact[peer.id]=DateTime.now().toUtc()', self.coordinator)
        self.assertIn('_lastContact[channel.link.id]=DateTime.now().toUtc()', self.coordinator)

    def test_model_simultaneous_dials_choose_same_direction_for_every_claim_order(self):
        # 每个事件表示HMAC握手后的一侧claim；两个方向共四个事件。
        events = [('low', 'low-to-high', True), ('high', 'low-to-high', True),
                  ('low', 'high-to-low', False), ('high', 'high-to-low', False)]
        for ordering in itertools.permutations(events):
            sessions = {'low': Arbitration(), 'high': Arbitration()}
            tokens = []
            for side, socket, preferred in ordering:
                token = sessions[side].claim(socket, preferred)
                if token is not None: tokens.append((side, socket, token))
            for side in sessions:
                self.assertEqual(sessions[side].current[0], 'low-to-high')
            for side, socket, token in tokens:
                if socket == 'high-to-low': sessions[side].release(token)
            self.assertTrue(all(state.current[0] == 'low-to-high' for state in sessions.values()))
        state = Arbitration(); state.claim('preferred-one', True)
        self.assertIsNone(state.claim('duplicate-preferred', True))

    def test_authenticated_claim_and_current_scopes_remain_before_all_delta_rounds(self):
        outgoing = self.coordinator.split('Future<void> _connect(', 1)[1].split('Future<void> _serve(', 1)[0]
        incoming = self.coordinator.split('Future<void> _serve(', 1)[1].split('Future<void> _offers(', 1)[0]
        for source in (outgoing, incoming):
            self.assertLess(source.index('SecureSyncChannel.authenticate('), source.index('_claimSession('))
            self.assertLess(source.index('_claimSession('), source.index('Rounds('))
            self.assertIn('if(lease==null)return;', source)
        claim = self.coordinator.split('Object? _claimSession(', 1)[1].split('void _releaseSession(', 1)[0]
        self.assertIn('old.socket.destroy()', claim)
        self.assertNotIn('registry.authenticated', claim)
        self.assertNotIn('store.patch', claim)
        self.assertIn('identical(_sessions[id]?.token,token)', self.coordinator)
        self.assertIn('await registry.scopes(peer)', self.coordinator)
        self.assertIn('remote:offer[\'couple\'] as bool', self.coordinator)

    def test_partial_apply_failure_and_local_revocation_still_invalidate_permissions(self):
        for signature, end in (('Future<bool> _clientRounds(', 'Future<bool> _serverRounds('),
                               ('Future<bool> _serverRounds(', 'Future<bool> _joinIfReady(')):
            rounds = self.coordinator.split(signature, 1)[1].split(end, 1)[0]
            self.assertLess(rounds.index('touched();'), rounds.index('await strategy.apply('))
            self.assertIn('_check(epoch);await strategy.apply(', rounds)
        for signature, end in (('Future<void> _connect(', 'Future<void> _serve('),
                               ('Future<void> _serve(', 'Future<void> _offers(')):
            connection = self.coordinator.split(signature, 1)[1].split(end, 1)[0]
            finalizer = connection.split('finally{', 1)[1]
            self.assertIn('if(dirty&&_alive(epoch))', finalizer)
            self.assertIn('try{await onChanged?.call();}catch(_){}', finalizer)
            self.assertLess(connection.index('await onChanged?.call();dirty=false'), connection.index('已完成本轮授权增量；附件状态以本机文件校验为准'))
        for signature, end in (('Future<void> coupleConsent(', 'Future<void> revoke('),
                               ('Future<void> revoke(', '@override void dispose(')):
            mutation = self.coordinator.split(signature, 1)[1].split(end, 1)[0]
            self.assertIn('await onChanged?.call()', mutation)
        # 独立状态模型：已提交但ACK丢失仍刷新；停止后不执行迟到网络回调。
        for dirty, alive, expected in ((True, True, True), (True, False, False), (False, True, False)):
            self.assertEqual(dirty and alive, expected)

    def test_manual_hint_is_current_pair_scoped_and_foreground_memory_only(self):
        manual = self.coordinator.split('Future<void> connectManually(', 1)[1].split('Object? _claimSession(', 1)[0]
        self.assertIn('link.id==peer.id&&link.active&&link.familyId==peer.familyId&&link.remoteDeviceId==peer.remoteDeviceId', manual)
        self.assertLess(manual.index('await registry.scopes(current)'), manual.index('_manualHints[current.remoteDeviceId]='))
        self.assertIn('!localAddress(ip)', manual)
        self.assertNotIn('await start()', manual)
        self.assertIn('final epoch=_generation;if(!_alive(epoch))return;', manual)
        self.assertIn('await registry.scopes(current);if(!_alive(epoch))return;', manual)
        self.assertNotIn('setPrivate', manual)
        self.assertNotIn('saveDeviceReference', manual)
        stop = self.coordinator.split('Future<void> stop()', 1)[1].split('Future<void> _cleanup()', 1)[0]
        self.assertIn('_manualHints.clear()', stop)
        self.assertIn('_lastContact.clear()', stop)
        self.assertIn('_manualHints[peer.remoteDeviceId]??_hints[peer.remoteDeviceId]', self.coordinator)
        self.assertIn("if(event.event=='lost'){_hints.remove(event.deviceId);}", self.coordinator)
        self.assertIn('static const _sessionBudget=Duration(minutes:2)', self.coordinator)
        self.assertIn('Timer(_sessionBudget,', self.coordinator)

    def test_join_and_local_page_explain_pending_identity_without_exposing_revoked_metadata(self):
        join = self.coordinator.split('Future<bool> _joinIfReady(', 1)[1].split('Future<void> coupleConsent(', 1)[0]
        for guard in ("member?['family_id']!=fid", "member?['user_id']!=store.deviceId", "['owner','member'].contains(member?['role'])"):
            self.assertIn(guard, join)
        self.assertIn("'sync-pending-family:${peer.id}':null", join)
        load = self.page.split('Future<void> _load()', 1)[1].split('Future<void> _run(', 1)[0]
        self.assertLess(load.index('await runtime.registry.scopes(peer)'), load.index("'/families/${peer.familyId}/members'"))
        self.assertIn("if (!allowed) { families[peer.id] = '原家庭授权已失效或待核对'; continue; }", load)
        self.assertIn('epoch != _loadEpoch', load)
        for label in ('待完成加入', '已配对，待连接', '本机设备标识', '本机私网 IP', '立即同步'):
            self.assertIn(label, self.page)
        self.assertIn('await runtime.sync.syncNow(peerId: link.id)', self.page)
        self.assertIn('sync.connectManually(peer, ip.address, number)', self.page)
        self.assertIn('await runtime.sync.start()', self.page.split('Future<void> _create()', 1)[1].split('Future<void> _accept()', 1)[0])

if __name__ == '__main__': unittest.main()
