"""只安装隔离包名到明确测试设备：已有同包名或残留数据即拒绝，绝不卸载/清库。"""
import argparse
import hashlib
import json
from pathlib import Path
import re
import subprocess
import shutil
import shlex
import tempfile


class SafetyError(RuntimeError):
    pass


def run(args, timeout=30):
    result = subprocess.run([str(value) for value in args], capture_output=True, text=True, timeout=timeout)
    if result.returncode:
        raise SafetyError(f'命令 {Path(str(args[0])).name} 失败（退出 {result.returncode}）；已停止，不自动修复设备')
    return result.stdout


def file_hash(path):
    with Path(path).open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()


def inspect_apk(apk, aapt, apksigner):
    apk = Path(apk).resolve()
    badging = run([aapt, 'dump', 'badging', apk])
    package = re.search(r"^package: name='([^']+)'", badging, re.M)
    activity = re.search(r"^launchable-activity: name='([^']+)'", badging, re.M)
    if not package:
        raise SafetyError('不能识别 APK 包名，拒绝安装')
    certificates = run([apksigner, 'verify', '--print-certs', apk])
    signers = {}
    for index, key, value in re.findall(r'^Signer #(\d+) certificate (DN|SHA-256 digest): (.+)$', certificates, re.M):
        signers.setdefault(index, {})['dn' if key == 'DN' else 'sha256'] = value.strip()
    if not signers or any(not re.fullmatch(r'[a-fA-F0-9]{64}', value.get('sha256', '')) for value in signers.values()):
        raise SafetyError('APK 验签没有给出证书 SHA-256，拒绝安装')
    return {'app_id': package[1], 'launch_activity': activity[1] if activity else None,
            'apk_bytes': apk.stat().st_size, 'apk_sha256': file_hash(apk), 'signers': list(signers.values())}


def adb_call(adb, serial, *args):
    return run([adb, '-s', serial, *args])


def guard_device(adb, serial, confirmed):
    if not confirmed or not serial or not re.fullmatch(r'[A-Za-z0-9][A-Za-z0-9_.:-]*', serial):
        raise SafetyError('必须明确序列号并确认 --confirm-test-device，不会自动选择设备')
    entries = run([adb, 'devices']).splitlines()
    if f'{serial}\tdevice' not in [line.strip() for line in entries]:
        raise SafetyError('指定设备未连接或未授权，未执行安装')


def require_package_absent(adb, serial, package):
    users = adb_call(adb, serial, 'shell', 'pm', 'list', 'users')
    ids = sorted(set(re.findall(r'UserInfo\{(\d+):', users)), key=int)
    if not ids:
        raise SafetyError('无法核对所有 Android 用户，拒绝安装')
    for user in ids:
        # -u 也检查已卸载但保留数据的包；仅查询明确目标包，避免记录无关应用列表。
        output = adb_call(adb, serial, 'shell', 'pm', 'list', 'packages', '-u', '--user', user, package)
        packages = {line.removeprefix('package:').strip() for line in output.splitlines() if line.startswith('package:')}
        if package in packages:
            raise SafetyError('设备中已有相同 app ID 或残留数据，拒绝安装；保留原应用及资料')
    return len(ids)


def install(apk, adb, aapt, apksigner, serial, confirmed=False,
            expected_package='io.github.chunyikit.wo.rebuild', launch=False):
    metadata = inspect_apk(apk, aapt, apksigner)
    if metadata['app_id'] != expected_package:
        raise SafetyError('实际 app ID 与明确预期不一致，拒绝安装')
    if not re.fullmatch(r'io\.github\.chunyikit\.wo\.rebuild(?:\.[a-zA-Z0-9_]+)*', expected_package):
        raise SafetyError('此入口仅接受 io.github.chunyikit.wo.rebuild 隔离测试包，拒绝生产包名')
    guard_device(adb, serial, confirmed)
    users = require_package_absent(adb, serial, expected_package)
    with tempfile.TemporaryDirectory(prefix='wo-isolated-install-') as directory:
        staged = Path(directory) / 'verified.apk'
        shutil.copyfile(apk, staged)
        if file_hash(staged) != metadata['apk_sha256']:
            raise SafetyError('APK 在检查后发生变化，拒绝安装')
        staged.chmod(0o400)
        # 最后核对后只使用 install，没有覆盖/降级/授权参数；竞态由 Android 拒绝。
        require_package_absent(adb, serial, expected_package)
        response = adb_call(adb, serial, 'install', '--no-incremental', str(staged))
        if 'Success' not in response.splitlines():
            raise SafetyError('设备未确认安装成功；未执行覆盖、卸载或清数据补救')

    report = {**metadata, 'status': 'installed_fresh_isolated_package', 'checked_android_user_count': users,
              'device_serial_sha256': hashlib.sha256(serial.encode()).hexdigest(),
              'existing_app_replaced': False, 'uninstall_executed': False, 'data_clear_executed': False,
              'runtime_permissions_granted_automatically': False, 'launched': False}
    if launch:
        if not metadata['launch_activity']:
            raise SafetyError('安装完成但没有可确认的启动 Activity，不启动')
        command = shlex.join(['am', 'start', '-W', '-n', f"{expected_package}/{metadata['launch_activity']}"])
        adb_call(adb, serial, 'shell', command)
        report['launched'] = True
    return report


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--apk', required=True)
    parser.add_argument('--serial')
    parser.add_argument('--inspect-only', action='store_true')
    parser.add_argument('--confirm-test-device', action='store_true')
    parser.add_argument('--expected-package', default='io.github.chunyikit.wo.rebuild')
    parser.add_argument('--adb', default='adb')
    parser.add_argument('--aapt', default='aapt')
    parser.add_argument('--apksigner', default='apksigner')
    parser.add_argument('--launch', action='store_true')
    parser.add_argument('--out', required=True)
    args = parser.parse_args()
    out = Path(args.out)
    if out.exists():
        parser.exit(2, '结果文件已存在，拒绝覆盖\n')
    try:
        if args.inspect_only:
            result = {**inspect_apk(args.apk, args.aapt, args.apksigner), 'status': 'inspected_only',
                      'device_contacted': False, 'uninstall_executed': False, 'data_clear_executed': False}
        else:
            result = install(args.apk, args.adb, args.aapt, args.apksigner, args.serial,
                             args.confirm_test_device, args.expected_package, args.launch)
    except (SafetyError, OSError, subprocess.SubprocessError) as error:
        timeout = isinstance(error, subprocess.TimeoutExpired)
        reason = '命令超时，结果未确定；只读核对隔离包是否存在，不要自动重试或清理' if timeout else str(error)
        result = {'status': 'uncertain' if timeout else 'refused_or_failed', 'reason': reason,
                  'uninstall_executed': False, 'data_clear_executed': False,
                  'permissions_granted_automatically': False}
        try:
            result['inspected_apk'] = inspect_apk(args.apk, args.aapt, args.apksigner)
        except (SafetyError, OSError, subprocess.SubprocessError):
            result['inspected_apk'] = {'verified': False}

        out.parent.mkdir(parents=True, exist_ok=True)
        out.write_text(json.dumps(result, ensure_ascii=False, indent=2) + '\n')
        parser.exit(2, str(error) + '\n')
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_text(json.dumps(result, ensure_ascii=False, indent=2) + '\n')
    print(json.dumps(result, ensure_ascii=False, indent=2))


if __name__ == '__main__':
    main()
