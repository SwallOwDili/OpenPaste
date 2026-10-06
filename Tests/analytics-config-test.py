import plistlib
from pathlib import Path

root = Path(__file__).resolve().parents[1]
app = root / "build/OpenPaste.app/Contents"
with (app / "Info.plist").open("rb") as stream:
    info = plistlib.load(stream)
source_config = root / "Assets/GoogleService-Info.plist"
bundled_config = app / "Resources/GoogleService-Info.plist"
assert source_config.exists() == bundled_config.exists()

assert info["FIREBASE_ANALYTICS_COLLECTION_ENABLED"] is False
assert info["GOOGLE_ANALYTICS_IDFV_COLLECTION_ENABLED"] is False
assert info["FirebaseAutomaticScreenReportingEnabled"] is False
assert info["FirebaseAppDelegateProxyEnabled"] is False
if bundled_config.exists():
    with bundled_config.open("rb") as stream:
        service = plistlib.load(stream)
    assert info["CFBundleIdentifier"] == service["BUNDLE_ID"]
    assert service["GOOGLE_APP_ID"]
print("Analytics bundle configuration passed")
