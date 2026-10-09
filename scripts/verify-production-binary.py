"""Reject test entry points in a binary intended for distribution."""

from pathlib import Path
import subprocess
import sys


TEST_FLAGS = {
    "--capture-boundary-test",
    "--clipboard-write-test",
    "--code-style-test",
    "--content-editing-test",
    "--current-clipboard-test",
    "--data-directory-test",
    "--drag-provider-test",
    "--feature-ui-test",
    "--force-manual",
    "--filter-test",
    "--interaction-policy-test",
    "--keyboard-test",
    "--layout-test",
    "--maintenance-test",
    "--navigation-test",
    "--paste-import-inspect",
    "--paste-import-test",
    "--paste-import-unit-test",
    "--paste-queue-test",
    "--permission-monitor-test",
    "--preview-cache-test",
    "--preview",
    "--recording-pause-test",
    "--self-test",
    "--shortcut-model-test",
    "--shortcut-test",
    "--storage-recovery-test",
    "--translation-config-test",
    "--translation-test",
    "--translation-ui-test",
    "--translation-workflow-test",
    "--ui-test",
    "--update-test",
}

TEST_SYMBOLS = {
    "runCaptureBoundaryTests",
    "runClipboardWriteTests",
    "runCodeStyleTests",
    "runContentEditingTests",
    "runCurrentClipboardTests",
    "runDataDirectoryTests",
    "runDragProviderTests",
    "runFilterTests",
    "runInteractionPolicyTests",
    "runKeyboardTests",
    "runLinkPreviewBoundaryTests",
    "runMaintenanceTests",
    "runNavigationTests",
    "runPasteImportTests",
    "runPasteImportUnitTests",
    "runPasteQueueTests",
    "runPermissionMonitorTests",
    "runPreviewTests",
    "runRecordingPauseTests",
    "runSettingsPageCacheTests",
    "runShortcutTests",
    "runStorageRecoveryTests",
    "runTests",
    "runTranslationConfigTests",
    "runTranslationTests",
    "runUpdateTests",
}


def main() -> None:
    if len(sys.argv) != 2:
        raise SystemExit("usage: verify-production-binary.py BINARY")
    binary = Path(sys.argv[1])
    payload = binary.read_bytes()
    leaked_flags = sorted(flag for flag in TEST_FLAGS if flag.encode() in payload)

    symbols = subprocess.run(
        ["nm", str(binary)], check=True, capture_output=True, text=True
    ).stdout
    demangled = subprocess.run(
        ["xcrun", "swift-demangle"], input=symbols, check=True,
        capture_output=True, text=True
    ).stdout
    leaked_symbols = sorted(
        symbol for symbol in TEST_SYMBOLS
        if f"OpenPaste.{symbol}(" in demangled
    )

    if leaked_flags or leaked_symbols:
        details = []
        if leaked_flags:
            details.append("flags: " + ", ".join(leaked_flags))
        if leaked_symbols:
            details.append("symbols: " + ", ".join(leaked_symbols))
        raise SystemExit("Production binary contains test code (" + "; ".join(details) + ")")
    print("Production binary contains no known test entry points")


if __name__ == "__main__":
    main()
