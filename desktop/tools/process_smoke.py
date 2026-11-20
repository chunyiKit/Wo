"""Linux 本机两进程 TLS 冒烟；只接受本任务生成的合成媒体，所有凭据留在/tmp私有目录。"""
import argparse
import hashlib
import http.client
import json
import os
from pathlib import Path
import selectors
import shutil
import signal
import ssl
import subprocess
import tempfile
from urllib.parse import urlsplit


def sha(path):
    with Path(path).open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()


def private_json(path, value):
    with os.fdopen(os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600), 'w') as stream:
        json.dump(value, stream)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--binary', required=True)
    parser.add_argument('--fixtures', required=True)
    args = parser.parse_args()
    binary = str(Path(args.binary).resolve())
    source = Path(args.fixtures).resolve()
    evidence = json.loads((source / 'source-evidence.json').read_text())
    assert evidence['fixture'] == 'wo-generated-synthetic-media-v1' and not evidence['contains_user_data']
    work = Path(tempfile.mkdtemp(prefix='wo-process-smoke-'))
    os.chmod(work, 0o700)
    files = work / 'sources'
    files.mkdir(mode=0o700)
    manifest = json.loads((source / 'manifest.json').read_text())
    for entry in manifest['entries']:
        shutil.copyfile(source / (entry['id'] + '.bin'), files / (entry['id'] + '.bin'))
        assert sha(files / (entry['id'] + '.bin')) == entry['sha256']
    private_json(work / 'manifest.json', manifest)
    log = (work / 'server.private.log').open('x')
    process = subprocess.Popen([binary, 'serve', '--data', str(work / 'server'), '--listen', '127.0.0.1:0'],
                               stdout=subprocess.PIPE, stderr=log, text=True)
    result = {'fixture_only': True, 'external_network_used': False, 'runtime': str(work),
              'native_platform': 'linux', 'server_and_client_separate_processes': True,
              'mobile_import_completed': False, 'mac_windows_native_tested': False}
    try:
        selector = selectors.DefaultSelector()
        selector.register(process.stdout, selectors.EVENT_READ)
        if not selector.select(10):
            raise RuntimeError('local server did not start')
        startup = json.loads(process.stdout.readline())
        assert startup['event'] == 'listening'
        origin = urlsplit(startup['url'])
        cookie = ''

        def admin(method, path, body=None):
            nonlocal cookie
            # 自签本机TLS：先核对确切SHA256，之后才发送管理码或Cookie。
            context = ssl.SSLContext(ssl.PROTOCOL_TLS_CLIENT)
            context.minimum_version = ssl.TLSVersion.TLSv1_3
            context.check_hostname = False
            context.verify_mode = ssl.CERT_NONE
            conn = http.client.HTTPSConnection(origin.hostname, origin.port, context=context, timeout=30)
            conn.connect()
            assert hashlib.sha256(conn.sock.getpeercert(binary_form=True)).hexdigest() == startup['pin']
            headers = {'Content-Type': 'application/json'}
            if cookie:
                headers['Cookie'] = cookie
            conn.request(method, path, body=None if body is None else json.dumps(body), headers=headers)
            response = conn.getresponse()
            payload = response.read()
            if response.getheader('Set-Cookie'):
                cookie = response.getheader('Set-Cookie').split(';')[0]
            status = response.status
            conn.close()
            return status, payload

        def run(*arguments, success=True):
            command = subprocess.run([binary, *map(str, arguments)], capture_output=True, text=True, timeout=120)
            if success and command.returncode:
                raise RuntimeError('CLI failed: ' + arguments[0] + ': ' + command.stderr[:500])
            if not success:
                assert command.returncode != 0
                return None
            return json.loads(command.stdout)

        assert admin('GET', '/admin/backups')[0] == 401
        assert admin('POST', '/admin/session', {'secret': startup['admin_code']})[0] == 200
        code, data = admin('POST', '/admin/pair', {'family': manifest['family_id']})
        assert code == 201
        invitation = json.loads(data)
        private_json(work / 'pairing.private.json', {'server': startup['url'], 'pin': startup['pin'],
                     'code': invitation['code'], 'family': manifest['family_id'], 'device': 'synthetic-process-phone'})
        connection = work / 'connection.private.json'
        run('pair', '--pairing-file', work / 'pairing.private.json', '--out', connection)
        sent = run('upload', '--connection', connection, '--manifest', work / 'manifest.json', '--files', files)
        assert sent['complete'] and not sent['full_device_complete']
        fetched = run('fetch', '--connection', connection, '--backup', manifest['backup_id'], '--cache', work / 'cache')
        assert fetched['complete']
        run('fetch', '--connection', connection, '--backup', manifest['backup_id'], '--cache', work / 'cache')
        checked = []
        for entry in manifest['entries']:
            suffix = Path('backups') / manifest['family_id'] / manifest['backup_id'] / 'entries' / (entry['id'] + '.blob')
            assert sha(work / 'server' / suffix) == entry['sha256'] == sha(work / 'cache' / suffix)
            checked.append({key: entry[key] for key in ['id', 'kind', 'size', 'sha256']})
        result['source_computer_restored_sha_equal'] = checked
        inner = {'version': 1, 'family_id': manifest['family_id'], 'entries': [
            {key: e.get(key, '') for key in ['id', 'kind', 'size', 'sha256', 'source_exact']} | {'missing_reason': ''}
            for e in manifest['entries']]}
        private_json(work / 'inner.private.json', inner)
        key = work / 'content.private.key'
        with os.fdopen(os.open(key, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600), 'wb') as stream:
            stream.write(os.urandom(32))
        sealed = work / 'private.woseal'
        sealed_info = run('pack-sealed', '--manifest', work / 'inner.private.json', '--files', files,
                          '--key-file', key, '--backup', 'restricted-process', '--entry', 'opaque', '--out', sealed)
        sealed_input = work / 'sealed-input'
        sealed_input.mkdir(mode=0o700)
        shutil.copyfile(sealed, sealed_input / 'opaque.bin')
        outer = {'version': 1, 'family_id': manifest['family_id'], 'backup_id': 'restricted-process',
                 'entries': [{'id': 'opaque', 'kind': 'sealed', **sealed_info}]}
        private_json(work / 'outer.json', outer)
        restricted = run('upload', '--connection', connection, '--manifest', work / 'outer.json', '--files', sealed_input)
        assert not restricted['complete'] and restricted['scope'] == 'opaque_restricted_unverified'
        assert admin('GET', '/admin/backups/' + manifest['family_id'] + '/restricted-process/files/opaque')[0] == 403
        run('fetch', '--connection', connection, '--backup', 'restricted-process', '--cache', work / 'sealed-cache')
        cipher = work / 'sealed-cache' / 'backups' / manifest['family_id'] / 'restricted-process/entries/opaque.blob'
        target = work / 'restored-new-device'
        restored = run('restore-sealed', '--file', cipher, '--key-file', key, '--family', manifest['family_id'],
                       '--backup', 'restricted-process', '--entry', 'opaque', '--out', target)
        assert restored['complete'] and not restored['records_applied']
        assert restored['new_family_id'] != manifest['family_id']
        for entry in manifest['entries']:
            mapped = restored['files'][entry['id']]
            assert mapped['new_id'] != entry['id'] and sha(mapped['path']) == entry['sha256']
        run('restore-sealed', '--file', cipher, '--key-file', key, '--family', manifest['family_id'],
            '--backup', 'restricted-process', '--entry', 'opaque', '--out', target, success=False)
        wrong = work / 'wrong.private.key'
        with os.fdopen(os.open(wrong, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600), 'wb') as stream:
            stream.write(os.urandom(32))
        run('restore-sealed', '--file', cipher, '--key-file', wrong, '--family', manifest['family_id'],
            '--backup', 'restricted-process', '--entry', 'opaque', '--out', work / 'wrong-output', success=False)
        assert not (work / 'wrong-output').exists()
        result.update({'restricted_server_complete': False, 'restricted_admin_download_status': 403,
                       'restored_new_family': restored['new_family_id'], 'restored_new_device': restored['new_device_id'],
                       'records_applied': False, 'existing_destination_refused': True, 'wrong_key_published_nothing': True})
        code, data = admin('GET', '/admin/backups')
        assert code == 200
        result['web_api_backups'] = json.loads(data)
        assert admin('POST', '/admin/revoke', {'family': manifest['family_id'], 'device': 'synthetic-process-phone'})[0] == 200
        run('fetch', '--connection', connection, '--backup', manifest['backup_id'], '--cache', work / 'revoked-cache', success=False)
        result['revoked_new_request_refused'] = True
    finally:
        process.send_signal(signal.SIGINT)
        try:
            process.wait(timeout=15)
        except subprocess.TimeoutExpired:
            process.kill()
            process.wait()
        log.close()
    assert process.returncode == 0 and not (work / 'server/.state/serve.lock').exists()
    result['graceful_server_exit_and_lock_cleanup'] = True
    result['result'] = 'PASS'
    (work / 'smoke-result.json').write_text(json.dumps(result, ensure_ascii=False, indent=2) + '\n')
    print(json.dumps({'result': 'PASS', 'evidence': str(work / 'smoke-result.json'), 'source_sha_verified': checked}))


if __name__ == '__main__':
    main()
