#!/usr/bin/env python3
"""只运行无SDK的Python契约/独立模型；不把跳过的Dart入口算通过。"""
from pathlib import Path
import argparse
import importlib
import json
import sys
import unittest

ROOT = Path(__file__).resolve().parents[2]
# 该测试会执行Dart；Python-only检查不导入它。
EXCLUDED = {'test_chat_pagination': 'requires_dart_execution_not_authorized'}
# 新增模块必须先只读审查其子进程/网络行为，再明确列入；禁止自动执行未知测试。
SDK_FREE_MODULES = ('test_connection_config', 'test_finance_frontier_contract', 'test_finance_sync_contract', 'test_finance_ui_contract', 'test_local_chat_contract', 'test_local_memory_ui_contract', 'test_local_plant_weather_ui_contract', 'test_local_sync_settings_contract', 'test_local_travel_contract', 'test_mobile_runtime_contract', 'test_mobile_source_contract', 'test_native_local_contract', 'test_native_media_contract', 'test_owned_media_contract', 'test_peer_media_contract', 'test_pending_upload_journal_contract', 'test_platform_backup_policy', 'test_rebuild_tools', 'test_recovery_library_ui_contract', 'test_sync_policy_contract', 'test_travel_policy_contract', 'test_travel_sync_adapter_contract')

def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--log', type=Path)
    parser.add_argument('--report', type=Path)
    args = parser.parse_args()
    sys.path.insert(0, str(ROOT))
    found = {path.stem for path in (ROOT / 'tool/tests').glob('test_*.py')}
    unknown = found.difference(SDK_FREE_MODULES).difference(EXCLUDED)
    if unknown:
        print(json.dumps({'unreviewed_modules': sorted(unknown), 'executed': False}))
        return 2
    suite = unittest.TestSuite()
    selected = []
    for name in SDK_FREE_MODULES:
        module = importlib.import_module('tool.tests.' + name)
        suite.addTests(unittest.defaultTestLoader.loadTestsFromModule(module))
        selected.append(name)
    log = args.log.open('w') if args.log else sys.stderr
    try:
        result = unittest.TextTestRunner(stream=log, verbosity=2).run(suite)
    finally:
        if args.log:
            log.close()
    report = {'suite_kind': 'python_source_contracts_and_independent_models',
        'dart_executed': False, 'native_executed': False,
        'tests_run': result.testsRun, 'failures': len(result.failures),
        'errors': len(result.errors), 'skipped': len(result.skipped),
        'selected_modules': selected, 'excluded_modules': EXCLUDED,
        'successful': result.wasSuccessful()}
    if args.report:
        args.report.write_text(json.dumps(report, ensure_ascii=False, indent=2) + '\n')
    print(json.dumps(report, ensure_ascii=False))
    return 0 if result.wasSuccessful() else 1

if __name__ == '__main__':
    raise SystemExit(main())
