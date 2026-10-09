import json
import os
from pathlib import Path
import re
import shutil
import stat
import subprocess
import tempfile
import unittest
import uuid


ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT / 'Sources/AppEnvironment.swift'
ACCEPTANCE_PARENT = ROOT / 'build/acceptance'
SUITE_PREFIX = 'io.github.SwallOwDili.OpenPaste.acceptance.'


def remove_path(path):
    if path.is_symlink() or path.is_file():
        path.unlink(missing_ok=True)
    else:
        shutil.rmtree(path, ignore_errors=True)


class AppEnvironmentRuntimeTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.build = tempfile.TemporaryDirectory(prefix='openpaste-environment-test-')
        build = Path(cls.build.name)
        main = build / 'main.swift'
        main.write_text(r'''
import Foundation

let currentDirectory = ProcessInfo.processInfo.environment["OPENPASTE_CWD_OVERRIDE"]
    .map { URL(fileURLWithPath: $0, isDirectory: true) }
let environment: AppEnvironment
do {
    environment = try AppEnvironment.resolve(currentDirectory: currentDirectory)
} catch {
    FileHandle.standardError.write(Data(error.localizedDescription.utf8))
    exit(2)
}
if let value = ProcessInfo.processInfo.environment["OPENPASTE_WRITE_PROBE"] {
    environment.defaults.set(value, forKey: "OpenPasteAcceptanceProbe")
    environment.defaults.synchronize()
}
if let path = ProcessInfo.processInfo.environment["OPENPASTE_VALIDATE_DATA_ROOT"] {
    do {
        _ = try environment.validateDataRoot(URL(fileURLWithPath: path, isDirectory: true))
    } catch {
        FileHandle.standardError.write(Data(error.localizedDescription.utf8))
        exit(3)
    }
}
if let path = ProcessInfo.processInfo.environment["OPENPASTE_WRITE_DATA_ROOT"] {
    environment.defaults.set(path, forKey: "dataDirectory")
    environment.defaults.synchronize()
}
let result: [String: Any] = [
    "acceptanceMode": environment.acceptanceMode,
    "allowAnalytics": environment.allowAnalytics,
    "allowPasteDiscovery": environment.allowPasteDiscovery,
    "defaultDataRoot": environment.defaultDataRoot.path,
    "previewCacheRoot": environment.previewCacheRoot.path,
    "usesStandardDefaults": environment.defaults === UserDefaults.standard,
    "probe": environment.defaults.string(forKey: "OpenPasteAcceptanceProbe") ?? ""
]
let data = try! JSONSerialization.data(withJSONObject: result, options: [.sortedKeys])
print(String(data: data, encoding: .utf8)!)
''')
        cls.executable = build / 'environment-probe'
        subprocess.run(
            ['swiftc', str(SOURCE), str(main), '-o', str(cls.executable)],
            cwd=ROOT, check=True, capture_output=True, text=True)

    @classmethod
    def tearDownClass(cls):
        cls.build.cleanup()

    def profile(self):
        profile = uuid.uuid4()
        root = ACCEPTANCE_PARENT / str(profile).upper()
        suite = SUITE_PREFIX + str(profile)
        self.addCleanup(remove_path, root)
        self.addCleanup(
            subprocess.run, ['defaults', 'delete', suite],
            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, check=False)
        return profile, root

    def run_probe(self, *arguments, root=None, extra_environment=None):
        environment = os.environ.copy()
        environment.pop('OPENPASTE_ACCEPTANCE_ROOT', None)
        environment.pop('OPENPASTE_WRITE_PROBE', None)
        environment.pop('OPENPASTE_CWD_OVERRIDE', None)
        environment.pop('OPENPASTE_VALIDATE_DATA_ROOT', None)
        environment.pop('OPENPASTE_WRITE_DATA_ROOT', None)
        if root is not None:
            environment['OPENPASTE_ACCEPTANCE_ROOT'] = str(root)
        if extra_environment:
            environment.update(extra_environment)
        return subprocess.run(
            [str(self.executable), *arguments], cwd=ROOT, env=environment,
            capture_output=True, text=True)

    def test_production_defaults_remain_standard(self):
        result = self.run_probe()
        self.assertEqual(result.returncode, 0, result.stderr)
        value = json.loads(result.stdout)
        self.assertFalse(value['acceptanceMode'])
        self.assertTrue(value['usesStandardDefaults'])
        self.assertTrue(value['allowAnalytics'])
        self.assertTrue(value['allowPasteDiscovery'])
        self.assertTrue(value['defaultDataRoot'].endswith('/Application Support/OpenPaste'))
        self.assertTrue(value['previewCacheRoot'].endswith('/Caches/OpenPaste/LinkPreviews'))

    def test_acceptance_profile_is_namespaced_and_survives_restart(self):
        profile, root = self.profile()
        first = self.run_probe(
            '--acceptance-profile', str(profile), root=root,
            extra_environment={'OPENPASTE_WRITE_PROBE': 'persisted'})
        self.assertEqual(first.returncode, 0, first.stderr)
        value = json.loads(first.stdout)
        self.assertTrue(value['acceptanceMode'])
        self.assertFalse(value['usesStandardDefaults'])
        self.assertFalse(value['allowAnalytics'])
        self.assertFalse(value['allowPasteDiscovery'])
        self.assertEqual(value['defaultDataRoot'], str(root / 'Application Support/OpenPaste'))
        self.assertEqual(value['previewCacheRoot'], str(root / 'Caches/OpenPaste/LinkPreviews'))
        self.assertTrue((root / '.openpaste-acceptance-profile').is_file())
        self.assertEqual(stat.S_IMODE(root.stat().st_mode), 0o700)

        restarted = self.run_probe('--acceptance-profile', str(profile), root=root)
        self.assertEqual(restarted.returncode, 0, restarted.stderr)
        self.assertEqual(json.loads(restarted.stdout)['probe'], 'persisted')

        other_profile, other_root = self.profile()
        isolated = self.run_probe(
            '--acceptance-profile', str(other_profile), root=other_root)
        self.assertEqual(isolated.returncode, 0, isolated.stderr)
        isolated_value = json.loads(isolated.stdout)
        self.assertEqual(isolated_value['probe'], '')

    def test_both_gates_are_required(self):
        profile, root = self.profile()
        missing_root = self.run_probe('--acceptance-profile', str(profile))
        self.assertNotEqual(missing_root.returncode, 0)
        missing_profile = self.run_probe(root=root)
        self.assertNotEqual(missing_profile.returncode, 0)
        invalid_profile = self.run_probe(
            '--acceptance-profile', 'not-a-uuid', root=root)
        self.assertNotEqual(invalid_profile.returncode, 0)

    def test_root_must_be_absolute_profile_directory(self):
        profile, _ = self.profile()
        relative = self.run_probe(
            '--acceptance-profile', str(profile), root=Path('build/acceptance') / str(profile))
        self.assertNotEqual(relative.returncode, 0)
        wrong_name = ACCEPTANCE_PARENT / ('wrong-' + str(profile))
        self.addCleanup(remove_path, wrong_name)
        wrong = self.run_probe('--acceptance-profile', str(profile), root=wrong_name)
        self.assertNotEqual(wrong.returncode, 0)

    def test_nonempty_unmarked_root_is_rejected(self):
        profile, root = self.profile()
        root.mkdir(parents=True)
        (root / 'existing-data').write_text('must not be overwritten')
        result = self.run_probe('--acceptance-profile', str(profile), root=root)
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual((root / 'existing-data').read_text(), 'must not be overwritten')

    def test_mismatched_marker_is_rejected(self):
        profile, root = self.profile()
        root.mkdir(parents=True)
        (root / '.openpaste-acceptance-profile').write_text('different profile')
        result = self.run_probe('--acceptance-profile', str(profile), root=root)
        self.assertNotEqual(result.returncode, 0)

    def test_symbolic_link_root_is_rejected(self):
        profile, root = self.profile()
        target = ACCEPTANCE_PARENT / (str(profile) + '-target')
        target.mkdir(parents=True)
        root.parent.mkdir(parents=True, exist_ok=True)
        root.symlink_to(target, target_is_directory=True)
        self.addCleanup(remove_path, target)
        result = self.run_probe('--acceptance-profile', str(profile), root=root)
        self.assertNotEqual(result.returncode, 0)

    def test_dangling_symbolic_link_root_is_rejected(self):
        profile, root = self.profile()
        root.parent.mkdir(parents=True, exist_ok=True)
        root.symlink_to(root.parent / 'missing-target', target_is_directory=True)
        result = self.run_probe('--acceptance-profile', str(profile), root=root)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('symbolic links', result.stderr)

    def test_production_and_icloud_roots_are_rejected(self):
        profile, _ = self.profile()
        home = Path.home()
        production = home / 'Library/Application Support/OpenPaste'
        production_root = production / 'build/acceptance' / str(profile)
        production_result = self.run_probe(
            '--acceptance-profile', str(profile), root=production_root,
            extra_environment={'OPENPASTE_CWD_OVERRIDE': str(production)})
        self.assertNotEqual(production_result.returncode, 0)
        self.assertIn('production home or data directory', production_result.stderr)

        icloud = home / 'Library/Mobile Documents'
        icloud_root = icloud / 'build/acceptance' / str(profile)
        icloud_result = self.run_probe(
            '--acceptance-profile', str(profile), root=icloud_root,
            extra_environment={'OPENPASTE_CWD_OVERRIDE': str(icloud)})
        self.assertNotEqual(icloud_result.returncode, 0)
        self.assertIn('iCloud Drive', icloud_result.stderr)

    def test_saved_and_migration_data_roots_must_stay_inside_profile(self):
        profile, root = self.profile()
        outside = ACCEPTANCE_PARENT / (str(profile) + '-outside')
        inside = root / 'Custom Data'
        created = self.run_probe('--acceptance-profile', str(profile), root=root)
        self.assertEqual(created.returncode, 0, created.stderr)

        accepted = self.run_probe(
            '--acceptance-profile', str(profile), root=root,
            extra_environment={'OPENPASTE_VALIDATE_DATA_ROOT': str(inside)})
        self.assertEqual(accepted.returncode, 0, accepted.stderr)
        rejected = self.run_probe(
            '--acceptance-profile', str(profile), root=root,
            extra_environment={'OPENPASTE_VALIDATE_DATA_ROOT': str(outside)})
        self.assertNotEqual(rejected.returncode, 0)
        self.assertIn('must stay inside', rejected.stderr)
        self.assertFalse(outside.exists())

        saved = self.run_probe(
            '--acceptance-profile', str(profile), root=root,
            extra_environment={'OPENPASTE_WRITE_DATA_ROOT': str(outside)})
        self.assertEqual(saved.returncode, 0, saved.stderr)
        restarted = self.run_probe('--acceptance-profile', str(profile), root=root)
        self.assertNotEqual(restarted.returncode, 0)
        self.assertIn('data directory', restarted.stderr)
        self.assertIn('must stay inside', restarted.stderr)
        self.assertFalse(outside.exists())

    def test_data_and_cache_subpath_symbolic_links_are_rejected(self):
        for subpath in (
                Path('Application Support/OpenPaste'),
                Path('Caches/OpenPaste/LinkPreviews')):
            with self.subTest(subpath=str(subpath)):
                profile, root = self.profile()
                target = ACCEPTANCE_PARENT / (str(profile) + '-target')
                self.addCleanup(remove_path, target)
                created = self.run_probe(
                    '--acceptance-profile', str(profile), root=root)
                self.assertEqual(created.returncode, 0, created.stderr)
                target.mkdir(parents=True)
                link = root / subpath
                link.parent.mkdir(parents=True)
                link.symlink_to(target, target_is_directory=True)

                restarted = self.run_probe(
                    '--acceptance-profile', str(profile), root=root)
                self.assertNotEqual(restarted.returncode, 0)
                self.assertIn('symbolic links', restarted.stderr)

class AppEnvironmentWiringTests(unittest.TestCase):
    def test_production_defaults_access_is_centralized(self):
        offenders = []
        direct_standard = re.compile(
            r'UserDefaults\.standard|\bUserDefaults\s*=\s*\.standard\b')
        for path in (ROOT / 'Sources').glob('*.swift'):
            if path.name == 'AppEnvironment.swift' or path.stem.endswith('Tests'):
                continue
            if direct_standard.search(path.read_text()):
                offenders.append(path.name)
        self.assertEqual(offenders, [], 'Use AppEnvironment.current.defaults in ' + ', '.join(offenders))

    def test_source_architecture_smoke_only(self):
        # These source checks are smoke checks, not evidence of runtime isolation.
        # Consumer behavior is exercised by StorageRecoveryTests and TranslationConfigTests.
        expected = {
            'DataDirectory.swift': 'AppEnvironment.current.defaultDataRoot',
            'RichPreviews.swift': 'AppEnvironment.current.previewCacheRoot',
            'Translation.swift': 'AppEnvironment.current.defaults',
            'UsageAnalytics.swift': 'AppEnvironment.current.allowAnalytics',
            'PasteImport.swift': 'AppEnvironment.current.allowPasteDiscovery',
        }
        for filename, expression in expected.items():
            with self.subTest(file=filename):
                source = (ROOT / 'Sources' / filename).read_text()
                self.assertIn(expression, source)

    def test_environment_source_has_no_direct_keychain_calls(self):
        source = SOURCE.read_text()
        self.assertNotIn('SecItem', source)
        self.assertNotIn('Security', source)

    def test_acceptance_path_validation_is_wired_at_consumers(self):
        environment = SOURCE.read_text()
        model = (ROOT / 'Sources/Model.swift').read_text()
        data_directory = (ROOT / 'Sources/DataDirectory.swift').read_text()
        rich_previews = (ROOT / 'Sources/RichPreviews.swift').read_text()
        self.assertIn(
            'resolved.validateDataRoot(resolved.defaultDataRoot', environment)
        self.assertIn(
            'resolved.validateCacheRoot(resolved.previewCacheRoot', environment)
        self.assertIn('defaults.string(forKey: "dataDirectory")', environment)
        self.assertIn(
            'AppEnvironment.current.validateDataRoot(selectedRoot)', model)
        self.assertGreaterEqual(
            data_directory.count('environment.validateDataRoot('), 3)
        self.assertIn('validateCacheRoot(', rich_previews)
        self.assertIn(
            'case .failure(let error): self.directoryStatus = "切换失败：',
            data_directory)


if __name__ == '__main__':
    unittest.main()
