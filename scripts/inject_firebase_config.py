"""Write the official Firebase app configuration supplied by the release workflow."""

import base64
import binascii
import os
import plistlib
import sys
from pathlib import Path

encoded = os.environ.get("OPENPASTE_FIREBASE_CONFIG_B64", "")
if not encoded:
    sys.exit("Missing OPENPASTE_FIREBASE_CONFIG_B64 repository secret")

try:
    payload = base64.b64decode(encoded, validate=True)
    config = plistlib.loads(payload)
except (binascii.Error, ValueError, plistlib.InvalidFileException):
    sys.exit("Invalid Firebase configuration in repository secret")

if config.get("BUNDLE_ID") != "io.github.SwallOwDili.OpenPaste":
    sys.exit("Firebase configuration has the wrong bundle ID")
if not all(config.get(key) for key in ("API_KEY", "GOOGLE_APP_ID", "PROJECT_ID")):
    sys.exit("Firebase configuration is missing required fields")

target = Path(__file__).resolve().parents[1] / "Assets/GoogleService-Info.plist"
target.write_bytes(payload)
target.chmod(0o600)
print("Firebase configuration injected for release build")
