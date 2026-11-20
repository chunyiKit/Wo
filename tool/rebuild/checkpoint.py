"""仅从已提交 Git 对象制作本地源码检查点，不打包工作区/凭据/配对资料。"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import tempfile


class CheckpointError(RuntimeError):
    pass


def git(repo, *args, data=None):
    result = subprocess.run(['git', '-C', str(repo), *args], input=data, capture_output=True)
    if result.returncode:
        raise CheckpointError(f'Git 操作失败：{args[0]}（退出 {result.returncode}）')
    return result.stdout


def sha(path):
    with Path(path).open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()


def bad_path(path):
    p = path.lower()
    if p.endswith(('.example', '.sample', '.template')):
        return False
    name = p.rsplit('/', 1)[-1]
    return bool(re.search(r'(?:^|/)(?:\.env(?:\.[^/]*)?|.*\.local\.json|[^/]*\.private-defines\.json|[^/]*\.secret|[^/]*\.(?:key|jks|keystore|p12|pfx|sqlite|sqlite3|db|wobak|apk))$', p)
                or name in ['pair.json', 'pairing.json', 'credentials.json', 'service-account.json', 'service_account.json']
                or (name.endswith('.json') and re.search(r'(?:^|[._-])(?:pair|pairing|credentials|secrets)(?:[._-]|$)', name)))


def content_issues(data, path=''):
    reasons = []
    if re.search(rb'-----BEGIN (?:[A-Z0-9 ]+ )?PRIVATE KEY-----', data):
        reasons.append('private_key_material')
    if re.search(rb'(?<![A-Za-z0-9])sk-(?:proj-|svcacct-)?[A-Za-z0-9_-]{24,}', data):
        reasons.append('api_key_like_value')
    if re.search(rb'(?<![A-Za-z0-9])AKID[A-Za-z0-9]{24,}', data):
        reasons.append('cloud_access_key_like_value')
    # 只扫描赋给凭据字段的长字符串；占位符/明确合成样本不当成真实凭据。
    pattern = rb'''(?i)(?<![A-Za-z0-9_])(?:api[_-]?key|client[_-]?secret|master[_-]?secret|access[_-]?token|refresh[_-]?token|password|passwd)[\"']?\s*[=:]\s*["']([^"'\r\n]{12,})["']'''
    for match in re.finditer(pattern, data):
        value = match[1].lower()
        if any(word in value for word in [b'test', b'example', b'demo', b'synthetic', b'placeholder', b'your_', b'your-', b'changeme', b'dummy', b'xxxx', b'${', b'getenv', b'fromenvironment']):
            continue
        if path.startswith(('test/', 'tool/tests/', 'backend/tests/')) and b'password' in match[0].lower():
            continue
        reasons.append('credential_literal')
        break
    return sorted(set(reasons))


def scan(repo, revisions):
    objects = git(repo, 'rev-list', '--objects', *revisions).decode().splitlines()
    issues = []
    checked = set()
    for line in objects:
        oid, _, path = line.partition(' ')
        if path and bad_path(path):
            issues.append({'path': path, 'reason': 'sensitive_file_path'})
        if oid in checked:
            continue
        checked.add(oid)
        if git(repo, 'cat-file', '-t', oid).strip() not in [b'blob', b'commit', b'tag']:
            continue
        size = int(git(repo, 'cat-file', '-s', oid))
        if size > 64 * 1024 * 1024:
            issues.append({'path': path, 'reason': 'blob_exceeds_scan_limit'})
            continue
        for reason in content_issues(git(repo, 'cat-file', '-p', oid), path):
            issues.append({'path': path, 'reason': reason})
    return issues


def checkpoint(repo, out, ref=None, base=None):
    repo, out = Path(repo).resolve(), Path(out).resolve()
    if out.exists():
        raise CheckpointError('输出目录必须全新，不能覆盖既有检查点')
    if out.is_relative_to(repo):
        raise CheckpointError('检查点必须保存在仓库外，避免被提交或递归打包')
    ref = ref or git(repo, 'symbolic-ref', '--quiet', 'HEAD').decode().strip()
    if not ref.startswith('refs/heads/'):
        raise CheckpointError('只接受明确本地分支，不接受任意 rev-list 参数')
    git(repo, 'check-ref-format', ref)
    head = git(repo, 'rev-parse', '--verify', ref + '^{commit}').decode().strip()
    if base and not re.fullmatch(r'[a-fA-F0-9]{40}', base):
        raise CheckpointError('基础提交必须是完整 40 位 SHA')
    if base:
        git(repo, 'merge-base', '--is-ancestor', base, head)
    all_issues = scan(repo, [ref])
    out.mkdir(parents=True, mode=0o700)
    report = {'head': head, 'tree': git(repo, 'rev-parse', head + '^{tree}').decode().strip(),
              'ref': ref, 'base': base, 'kind': None, 'source_only': True,
              'untracked_files_included': False, 'git_config_included': False,
              'cross_failure_domain_saved': False, 'secret_scan': 'passed' if not all_issues else 'full_history_rejected',
              'full_history_scan_findings': all_issues, 'restored_tree_verified': False,
              'same_cloud_storage_warning': '此目录只是本地冗余，不代表跨故障域或永久保存。'}
    if not all_issues:
        artifact = out / 'source.bundle'
        git(repo, 'bundle', 'create', str(artifact), ref)
        git(repo, 'bundle', 'verify', str(artifact))
        branch = ref.removeprefix('refs/heads/')
        with tempfile.TemporaryDirectory(prefix='wo-checkpoint-verify-') as directory:
            target = Path(directory) / 'restore'
            result = subprocess.run(['git', 'clone', '--quiet', '--branch', branch, str(artifact), str(target)], capture_output=True)
            if result.returncode:
                raise CheckpointError('bundle 临时恢复 clone 失败')
            restored = git(target, 'rev-parse', 'HEAD').decode().strip()
            if restored != head or git(target, 'rev-parse', 'HEAD^{tree}') != git(repo, 'rev-parse', head + '^{tree}'):
                raise CheckpointError('bundle 恢复提交或 tree 不一致')
            git(target, 'fsck', '--full', '--no-reflogs')
        report.update({'kind': 'git_bundle', 'bundle_verified': True, 'restored_tree_verified': True,
                       'restored_commit': head, 'standalone_history': True})
    else:
        if not base or base == head:
            report.update({'kind': 'baseline_reference_only', 'standalone_history': False,
                           'reason': '完整历史扫描未通过；没有可安全导出的新增提交，必须保留/取得基础仓库。'})
            (out / 'manifest.json').write_text(json.dumps(report, ensure_ascii=False, indent=2) + '\n')
            return report
        new_issues = scan(repo, [base + '..' + head])
        patch = git(repo, 'format-patch', '--stdout', '--binary', '--full-index', base + '..' + head)
        patch_issues = content_issues(patch)
        if new_issues or patch_issues:
            report.update({'kind': 'refused', 'patch_findings': new_issues,
                           'patch_content_reasons': patch_issues})
            (out / 'manifest.json').write_text(json.dumps(report, ensure_ascii=False, indent=2) + '\n')
            raise CheckpointError('新增提交/补丁也含敏感风险，已拒绝导出；报告不包含凭据值')
        artifact = out / 'module.patch'
        artifact.write_bytes(patch)
        with tempfile.TemporaryDirectory(prefix='wo-patch-verify-') as directory:
            target = Path(directory) / 'restore'
            result = subprocess.run(['git', 'clone', '--quiet', '--no-hardlinks', '--no-checkout', str(repo), str(target)], capture_output=True)
            if result.returncode:
                raise CheckpointError('补丁基础临时 clone 失败')
            git(target, 'checkout', '--quiet', '--detach', base)
            git(target, 'config', 'user.name', 'Checkpoint Verification')
            git(target, 'config', 'user.email', 'checkpoint@invalid.local')
            git(target, 'am', '--quiet', str(artifact))
            if git(target, 'rev-parse', 'HEAD^{tree}') != git(repo, 'rev-parse', head + '^{tree}'):
                raise CheckpointError('补丁恢复后的 tree 与来源不同')
        report.update({'kind': 'format_patch', 'standalone_history': False,
                       'requires_base_commit': base, 'restored_tree_verified': True,
                       'exact_original_commit_restored': False})
    report.update({'artifact': artifact.name, 'bytes': artifact.stat().st_size, 'sha256': sha(artifact)})
    (out / 'manifest.json').write_text(json.dumps(report, ensure_ascii=False, indent=2) + '\n')
    return report


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--repo', default=str(Path(__file__).resolve().parents[2]))
    parser.add_argument('--out', required=True)
    parser.add_argument('--ref')
    parser.add_argument('--base')
    args = parser.parse_args()
    os.umask(0o077)
    try:
        report = checkpoint(args.repo, args.out, args.ref, args.base)
        print(json.dumps(report, ensure_ascii=False, indent=2))
        if report['kind'] == 'baseline_reference_only':
            parser.exit(3, '只记录基础 SHA，尚没有可恢复源码检查点；未宣称备份成功。\n')
    except (CheckpointError, OSError) as error:
        parser.exit(2, str(error) + '\n')


if __name__ == '__main__':
    main()
