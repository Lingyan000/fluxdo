"""验证路径分流和零测试防护，防止漏跑平台或消耗无关额度。"""
import unittest
from network_checks import plan, nonzero_rust_result


class SelectionTest(unittest.TestCase):
    def test_documentation_skips_expensive_jobs(self):
        result = plan(['docs/diagnostics/report.txt', 'README.md'])
        self.assertFalse(any(result[key] for key in ('dart', 'rust', 'python')))
        self.assertEqual(result['platforms']['include'], [])

    def test_shared_core_checks_all_native_backends(self):
        result = plan(['core/net_core/vendor/rama-quic/src/proto/mod.rs'])
        self.assertTrue(result['rust'])
        self.assertTrue(result['python'])
        self.assertEqual({p['platform'] for p in result['platforms']['include']},
                         {'android', 'apple', 'windows'})

    def test_platform_only_changes_do_not_build_other_platforms(self):
        for file, platform in [('ios/Runner/BrowserIdentity.swift', 'apple'),
                               ('android/app/build.gradle', 'android'),
                               ('windows/runner/main.cpp', 'windows')]:
            self.assertEqual([p['platform'] for p in plan([file])['platforms']['include']], [platform])

    def test_dart_change_does_not_build_native_backends(self):
        result = plan(['lib/services/network/core/net_core_service.dart'])
        self.assertTrue(result['dart'])
        self.assertFalse(result['rust'])
        self.assertEqual(result['platforms']['include'], [])

    def test_ci_change_runs_fast_checks_and_manual_can_request_platforms(self):
        result = plan(['.github/workflows/network-regression.yaml'])
        self.assertTrue(all(result[key] for key in ('dart', 'rust', 'python')))
        self.assertEqual(result['platforms']['include'], [])
        self.assertEqual(len(plan([], True)['platforms']['include']), 3)

    def test_zero_filtered_or_failed_tests_cannot_pass(self):
        for result in ['running 0 tests\ntest result: ok. 0 passed; 0 failed;',
                       'test result: FAILED. 12 passed; 1 failed;', 'build succeeded']:
            self.assertFalse(nonzero_rust_result(result))
        self.assertTrue(nonzero_rust_result('test result: ok. 138 passed; 0 failed; 0 ignored;'))


if __name__ == '__main__':
    unittest.main()
