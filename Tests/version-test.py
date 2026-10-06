#!/usr/bin/env python3
import importlib.util
import os
import sys
sys.dont_write_bytecode = True
from pathlib import Path
import unittest
from unittest.mock import patch

script = Path(__file__).resolve().parents[1] / 'scripts' / 'version.py'
spec = importlib.util.spec_from_file_location('release_version', script)
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)

class ReleaseVersionTests(unittest.TestCase):
    def test_stable_and_prerelease(self):
        for tag, expected in [('v1.2.3', '1.2.3'), ('1.2.3', '1.2.3'), ('v1.2.3-beta.1', '1.2.3-beta.1')]:
            with self.subTest(tag=tag), patch.dict(os.environ, {'OPENPASTE_VERSION': tag}, clear=True):
                info = module.metadata()
                self.assertEqual(info['OpenPasteReleaseVersion'], expected)
                self.assertEqual(info['CFBundleShortVersionString'], '1.2.3')
                self.assertEqual(info['CFBundleVersion'], '1')

    def test_without_git_is_draft(self):
        with patch.dict(os.environ, {}, clear=True), patch.object(module, 'git_value', return_value=''):
            info = module.metadata()
            self.assertEqual(info['OpenPasteReleaseVersion'], 'draft')
            self.assertEqual(info['CFBundleShortVersionString'], '0.0.0')
            self.assertEqual(info['OpenPasteVersionSource'], 'draft')

    def test_branch_commit(self):
        def git(*args):
            return 'a1b2c3d4' + '0' * 32 if args[0] == 'rev-parse' else 'feature/search'
        with patch.dict(os.environ, {}, clear=True), patch.object(module, 'git_value', side_effect=git):
            self.assertEqual(module.metadata()['OpenPasteReleaseVersion'], 'feature/search-a1b2c3d4')
        with patch.dict(os.environ, {'OPENPASTE_VERSION': 'v2.0.0'}, clear=True), patch.object(module, 'git_value', side_effect=git):
            self.assertEqual(module.metadata()['OpenPasteReleaseVersion'], '2.0.0')

    def test_detached_ci_branch(self):
        def git(*args):
            return 'a1b2c3d4' + '0' * 32 if args[0] == 'rev-parse' else ''
        with patch.dict(os.environ, {'GITHUB_HEAD_REF': 'fix/search'}, clear=True), patch.object(module, 'git_value', side_effect=git):
            self.assertEqual(module.metadata()['OpenPasteReleaseVersion'], 'fix/search-a1b2c3d4')

    def test_invalid_tags(self):
        for tag in ['v1.2', 'v01.2.3', 'v1.2.3\nBAD=value', '$(echo hi)', 'v1.2.3/path', 'v1.2.3+metadata', '']:
            with self.subTest(tag=tag), patch.dict(os.environ, {'OPENPASTE_VERSION': tag}):
                with self.assertRaises(ValueError):
                    module.metadata()

    def test_default_local_build_number(self):
        with patch.dict(os.environ, {}, clear=True):
            self.assertEqual(module.metadata()['CFBundleVersion'], '1')

    def test_github_run_number(self):
        with patch.dict(os.environ, {'GITHUB_RUN_NUMBER': '123'}, clear=True):
            self.assertEqual(module.metadata()['CFBundleVersion'], '123')

    def test_invalid_github_run_numbers(self):
        for build in ['0', '-1', '123\nBAD=value', '1000000000', '']:
            with self.subTest(build=build), patch.dict(os.environ, {'OPENPASTE_VERSION': 'v1.2.3', 'GITHUB_RUN_NUMBER': build}, clear=True):
                with self.assertRaises(ValueError):
                    module.metadata()

if __name__ == '__main__':
    unittest.main()
