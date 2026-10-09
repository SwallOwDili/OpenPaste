import re
from pathlib import Path
import unittest


ROOT = Path(__file__).resolve().parents[1]

# These executable entry points are deterministic checks in the dedicated
# OPENPASTE_TESTING executable: they use
# fixtures, temporary storage, isolated pasteboards, or the localhost
# translation fixture and do not open application windows.
REQUIRED_HEADLESS_CHECKS = {
    '--capture-boundary-test',
    '--clipboard-write-test',
    '--code-style-test',
    '--content-editing-test',
    '--current-clipboard-test',
    '--data-directory-test',
    '--drag-provider-test',
    '--filter-test',
    '--interaction-policy-test',
    '--maintenance-test',
    '--navigation-test',
    '--paste-import-unit-test',
    '--paste-queue-test',
    '--permission-monitor-test',
    '--preview-cache-test',
    '--recording-pause-test',
    '--storage-recovery-test',
    '--self-test',
    '--shortcut-model-test',
    '--translation-test',
    '--translation-config-test',
    '--update-test',
}

# These are intentionally outside automated release logic checks. The Paste
# entries inspect a user's installed Paste data. GUI checks require a foreground
# desktop, and some temporarily use the real clipboard or system permissions.
MANUAL_OR_INSPECTION_CHECKS = {
    '--paste-import-test',
    '--paste-import-inspect',
}

GUI_CHECKS = {
    '--feature-ui-test',
    '--keyboard-test',
    '--layout-test',
    '--shortcut-test',
    '--translation-ui-test',
    '--translation-workflow-test',
    '--ui-test',
}


def flags_in(path):
    return set(re.findall(r'--[a-z0-9-]+(?:test|inspect)', path.read_text()))


class TestEntrypoints(unittest.TestCase):
    def test_all_executable_check_flags_are_classified(self):
        source = '\n'.join(path.read_text() for path in (ROOT / 'Sources').glob('*.swift'))
        discovered = set(re.findall(r'--[a-z0-9-]+(?:test|inspect)', source))
        self.assertEqual(discovered,
                         REQUIRED_HEADLESS_CHECKS | MANUAL_OR_INSPECTION_CHECKS | GUI_CHECKS)

    def test_terminal_dispatch_is_fully_classified(self):
        source = (ROOT / 'Sources/main.swift').read_text()
        start = source.index('if CommandLine.arguments.contains("--interaction-policy-test")')
        end = source.index('\n} else {\n    let app = NSApplication.shared', start)
        dispatched = set(re.findall(r'--[a-z0-9-]+(?:test|inspect)', source[start:end]))
        self.assertEqual(dispatched, REQUIRED_HEADLESS_CHECKS | MANUAL_OR_INSPECTION_CHECKS)
        self.assertGreater(source.rfind('#if OPENPASTE_TESTING', 0, start), -1)
        self.assertGreater(source.find('#else', end), end)

    def test_both_release_check_scripts_run_every_headless_check(self):
        for relative in ('scripts/unit-tests.sh', 'scripts/check.sh'):
            with self.subTest(script=relative):
                flags = flags_in(ROOT / relative)
                self.assertEqual(flags, REQUIRED_HEADLESS_CHECKS)

    def test_manifest_excludes_test_sources_from_production(self):
        manifest = (ROOT / 'Package.swift').read_text()
        test_sources = {
            path.name for path in (ROOT / 'Sources').glob('*Tests.swift')
        } | {'Tests.swift'}
        configured = set(re.findall(
            r'"([A-Za-z]+Tests\.swift|Tests\.swift)"', manifest))
        self.assertEqual(configured, test_sources)
        self.assertIn(
            'exclude: openPasteTesting ? [] : testOnlySources', manifest)
        self.assertIn('.define("OPENPASTE_TESTING")', manifest)
        self.assertNotIn('.linkedFramework("Security")', manifest)

    def test_test_builds_use_an_isolated_scratch_directory(self):
        for relative in ('scripts/unit-tests.sh', 'scripts/check.sh'):
            with self.subTest(script=relative):
                source = (ROOT / relative).read_text()
                self.assertIn('OPENPASTE_TESTING=1 swift build', source)
                self.assertIn('swiftpm-tests-${arch}', source)
                self.assertIn('--manifest-cache none', source)
                self.assertIn('scripts/prepare-test-scratch.sh "$arch"', source)

    def test_test_scratch_reuses_the_production_cache(self):
        source = (ROOT / 'scripts/prepare-test-scratch.sh').read_text()
        self.assertIn('production_scratch="build/swiftpm-${arch}"', source)
        self.assertIn('test_scratch="build/swiftpm-tests-${arch}"', source)
        self.assertIn('ditto --clone "$production_scratch" "$clone_scratch"', source)
        self.assertIn('mv "$clone_scratch" "$test_scratch"', source)

    def test_packaging_rejects_test_entry_points(self):
        build = (ROOT / 'scripts/build.sh').read_text()
        verifier = (ROOT / 'scripts/verify-production-binary.py').read_text()
        self.assertIn(
            'Refusing to package an OPENPASTE_TESTING build.', build)
        self.assertIn('scripts/verify-production-binary.py', build)
        classified = (REQUIRED_HEADLESS_CHECKS |
                      MANUAL_OR_INSPECTION_CHECKS | GUI_CHECKS)
        for flag in classified:
            self.assertIn(f'"{flag}"', verifier)


if __name__ == '__main__':
    unittest.main()
