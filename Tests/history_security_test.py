import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

SCRIPT = Path(__file__).resolve().parents[1] / 'scripts/security-check.sh'


class HistorySecurityTests(unittest.TestCase):
    def run_scan(self, commits, explicit_base=None):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            (root / 'scripts').mkdir()
            (root / 'Tests').mkdir()
            (root / 'Tests/fixture_security_test.py').write_text(
                'import unittest\nclass Fixture(unittest.TestCase):\n'
                '    def test_fixture(self): self.assertTrue(True)\n')
            (root / 'bin').mkdir()
            shutil.copyfile(SCRIPT, root / 'scripts/security-check.sh')
            scanner = root / 'bin/gitleaks'
            scanner.write_text('#!/bin/sh\nprintf "%s\\n" "$*" >> "$SCAN_CALLS"\n')
            scanner.chmod(0o755)
            def git(*args):
                subprocess.run(['git', *args], cwd=root, check=True, capture_output=True)
            git('init', '-b', 'main')
            git('config', 'user.name', 'Test')
            git('config', 'user.email', 'test@example.invalid')
            for i in range(commits):
                (root / 'fixture.txt').write_text(str(i))
                git('add', '.')
                git('commit', '-m', 'Fixture')
            env = os.environ.copy()
            env.pop('SECURITY_BASE', None)
            env['PATH'] = str(root / 'bin') + os.pathsep + env['PATH']
            env['SCAN_CALLS'] = str(root / 'calls')
            if explicit_base is not None:
                env['SECURITY_BASE'] = explicit_base
            result = subprocess.run(['zsh', str(root / 'scripts/security-check.sh')],
                                    env=env, capture_output=True, text=True)
            return result, (root / 'calls').read_text().splitlines()

    def test_initial_commit_scans_tree_without_nonexistent_parent(self):
        result, calls = self.run_scan(1)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(len(calls), 1)
        self.assertTrue(calls[0].startswith('dir '))

    def test_parent_commit_keeps_history_scan(self):
        result, calls = self.run_scan(2)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(len(calls), 2)
        self.assertTrue(calls[1].startswith('git '))

    def test_invalid_explicit_base_still_blocks(self):
        result, _ = self.run_scan(1, 'HEAD^')
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('Invalid security scan base', result.stderr)


if __name__ == '__main__':
    unittest.main()
