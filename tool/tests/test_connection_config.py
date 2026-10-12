"""连接配置回归；远程命令和 Flutter 使用替身，不操作线上环境。

python3 -m unittest discover -s tool/tests -p test_connection_config.py -v
"""
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
LOADER = ROOT / "backend/deploy/config.sh"


class ConnectionConfigTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="wo config ")
        self.addCleanup(self.temp.cleanup)
        self.directory = Path(self.temp.name)
        self.config = self.directory / "deploy.env"
        self.record = self.directory / "calls"
        self.env = {k: v for k, v in os.environ.items()
                    if not k.startswith("WO_") and k != "WEB_BASE_URL"}
        self.env["WO_DEPLOY_CONFIG_FILE"] = str(self.config)
        self.env["WO_TEST_CALLS"] = str(self.record)
        self.env["PATH"] = f"{self.directory}:{self.env['PATH']}"
        for name in ("flutter", "ssh", "scp", "rsync", "curl", "openssl", "sudo", "apt-get"):
            stub = self.directory / name
            stub.write_text(
                '#!/usr/bin/env bash\n'
                'printf "%s\\n" "${0##*/}" "$@" >> "$WO_TEST_CALLS"\n'
                'if [[ "${0##*/}" == curl ]]; then echo \'{"success":true}\'; fi\n'
            )
            stub.chmod(0o755)

    def run_bash(self, *args, **environment):
        return subprocess.run(["bash", *map(str, args)], cwd=ROOT,
                              env={**self.env, **environment}, text=True,
                              capture_output=True, timeout=20)

    def load(self, command, **environment):
        return self.run_bash("-c", 'set -eu; source "$1"; wo_load_config; ' + command,
                             "bash", LOADER, **environment)

    def test_config_loads_and_exports_to_child_process(self):
        self.config.write_text("WO_API_BASE_URL=https://api.wo.test\nWO_SSH_HOST=ssh.wo.test\n")
        result = self.load('wo_require_config WO_API_BASE_URL WO_SSH_HOST; '
                           'bash -c \'printf "%s|%s" "$WO_API_BASE_URL" "$WO_SSH_HOST"\'')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout, "https://api.wo.test|ssh.wo.test")

    def test_environment_overrides_file_including_empty_value(self):
        self.config.write_text("WO_API_BASE_URL=https://file.wo.test\n")
        result = self.load('wo_require_config WO_API_BASE_URL; printf "%s" "$WO_API_BASE_URL"',
                           WO_API_BASE_URL="https://override.wo.test")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout, "https://override.wo.test")
        result = self.load("wo_require_config WO_API_BASE_URL", WO_API_BASE_URL="")
        self.assertNotEqual(result.returncode, 0)

    def test_explicit_missing_file_and_example_values_are_rejected(self):
        result = self.load("wo_require_config WO_API_BASE_URL")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("不存在", result.stderr)
        self.config.write_text("WO_API_BASE_URL=https://api.example.com\n")
        result = self.load("wo_require_config WO_API_BASE_URL")
        self.assertNotEqual(result.returncode, 0)

    def test_missing_config_stops_scripts_before_external_commands(self):
        self.config.write_text("")
        for script in ("deploy.sh", "release.sh", "publish-apk.sh", "check-version.sh",
                       "setup-server.sh", "tls/generate-certs.sh", "tls/install-on-server.sh"):
            with self.subTest(script=script):
                result = self.run_bash(ROOT / "backend/deploy" / script)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("请在", result.stderr)
                self.assertFalse(self.record.exists(), result.stdout)

    def test_version_query_uses_api_config_and_preserves_ca_path(self):
        self.config.write_text("WO_API_BASE_URL=https://api.wo.test/\n"
                               "WO_CA_CERT='/tmp/wo certificate.crt'\n")
        result = self.run_bash(ROOT / "backend/deploy/check-version.sh")
        self.assertEqual(result.returncode, 0, result.stderr)
        args = self.record.read_text().splitlines()
        self.assertIn("/tmp/wo certificate.crt", args)
        self.assertIn("https://api.wo.test/api/v1/app/version", args)

    def test_deploy_uses_separate_ssh_and_api_hosts_and_excludes_local_config(self):
        self.config.write_text("WO_API_BASE_URL=https://api.wo.test\nWO_SSH_HOST=ssh.wo.test\n")
        result = self.run_bash(ROOT / "backend/deploy/deploy.sh", "--skip-tests")
        self.assertEqual(result.returncode, 0, result.stderr)
        args = self.record.read_text().splitlines()
        self.assertIn("ubuntu@ssh.wo.test", args)
        self.assertIn("https://api.wo.test/api/v1/health", args)
        self.assertIn("deploy/env/deploy.env", args)

    def test_flutter_receives_config_file_and_original_arguments(self):
        app_config = self.directory / "app.local.json"
        app_config.write_text(json.dumps({"WO_API_BASE_URL": "https://api.wo.test"}))
        result = self.run_bash(ROOT / "tool/flutter.sh", "build", "apk", "--release",
                               WO_APP_CONFIG_FILE=str(app_config))
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.record.read_text().splitlines(), [
            "flutter", "build", "apk", "--release", f"--dart-define-from-file={app_config}"])

    def test_invalid_app_config_is_rejected_before_flutter_runs(self):
        app_config = self.directory / "app.local.json"
        for data in ("{", "null", "[]", '{}', '{"WO_API_BASE_URL": 42}',
                     '{"WO_API_BASE_URL":"https://api.example.com"}',
                     '{"WO_API_BASE_URL":"https://api.wo.test/api/v1"}'):
            with self.subTest(data=data):
                app_config.write_text(data)
                result = self.run_bash(ROOT / "tool/flutter.sh", "run",
                                       WO_APP_CONFIG_FILE=str(app_config))
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("App 配置错误", result.stderr)
                self.assertFalse(self.record.exists())


if __name__ == "__main__":
    unittest.main()
