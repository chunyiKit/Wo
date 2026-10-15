"""仅校验仓库示例与门禁，不访问网络、不加载本机私有配置。"""
import json
from pathlib import Path
import re
import unittest

ROOT = Path(__file__).resolve().parents[2]
TARGET = 'https://trek.chunyi-work.online'


def values(relative):
    return dict(line.split('=', 1) for line in (ROOT / relative).read_text().splitlines()
                if line and not line.startswith('#') and '=' in line)


class WechatDomainConfigTest(unittest.TestCase):
    def test_selected_domain_matches_client_and_server_examples(self):
        source = (ROOT / 'miniprogram/core/config.ts').read_text()
        self.assertEqual(re.search(r"apiOrigin: '([^']+)'", source).group(1), TARGET)
        deploy = values('backend/deploy/env/deploy.env.example')
        self.assertEqual(deploy['WO_API_BASE_URL'], TARGET)
        self.assertEqual(deploy['WEB_BASE_URL'], TARGET)
        self.assertEqual(values('backend/deploy/env/app.env.example')['WEB_BASE_URL'], TARGET)
        self.assertEqual(json.loads((ROOT / 'config/app.example.json').read_text())['WO_API_BASE_URL'], TARGET)

    def test_real_login_remains_gated_and_secret_is_not_in_example(self):
        source = (ROOT / 'miniprogram/core/config.ts').read_text()
        self.assertRegex(source, r'connectionReady:\s*false')
        app = values('backend/deploy/env/app.env.example')
        self.assertEqual(app['WECHAT_APP_ID'], 'wx0619d005f568430c')
        self.assertEqual(app['WECHAT_APP_SECRET'], '')
        self.assertEqual(app['AUTH_DEV_SHIM_ENABLED'], 'false')

    def test_new_vhost_is_only_a_scoped_uninstalled_template(self):
        source = (ROOT / 'backend/deploy/nginx/wo-miniprogram.conf.example').read_text()
        active = '\n'.join(line for line in source.splitlines() if not line.strip().startswith('#'))
        self.assertEqual(re.findall(r'server_name\s+([^;]+);', active), ['trek.chunyi-work.online'])
        self.assertNotIn('default_server', active)
        self.assertNotIn('/etc/wo/tls', active)
        self.assertIn('/fullchain.pem;', active)
        self.assertIn('location /api/v1/', active)
        self.assertIn('proxy_pass http://127.0.0.1:8000;', active)
        self.assertNotIn('Access-Control-Allow-Origin *', active)
        setup = (ROOT / 'backend/deploy/setup-server.sh').read_text()
        self.assertNotIn('wo-miniprogram.conf', setup)
        legacy = (ROOT / 'backend/deploy/nginx/wo-backend.conf').read_text()
        self.assertIn('default_server', legacy)
        self.assertIn('/etc/wo/tls/server.crt', legacy)


if __name__ == '__main__':
    unittest.main()
