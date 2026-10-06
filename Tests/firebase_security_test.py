import base64
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import tempfile
import unittest

SCRIPT = Path(__file__).resolve().parents[1] / 'scripts/inject_firebase_config.py'

class FirebaseSecurityTests(unittest.TestCase):
    def run_config(self, value):
        with tempfile.TemporaryDirectory() as tmp:
            root=Path(tmp)
            (root/'scripts').mkdir();(root/'Assets').mkdir()
            shutil.copyfile(SCRIPT,root/'scripts/inject_firebase_config.py')
            env=os.environ.copy();env['OPENPASTE_FIREBASE_CONFIG_B64']=value
            result=subprocess.run(['python3',str(root/'scripts/inject_firebase_config.py')],env=env,capture_output=True,text=True)
            target=root/'Assets/GoogleService-Info.plist'
            return result, target.exists(), (target.stat().st_mode & 0o777) if target.exists() else None

    def test_rejects_bad_inputs_without_writing_or_leaking(self):
        for value in ['', 'not-base64', base64.b64encode(b'not-plist').decode(),
            self.encode({'BUNDLE_ID':'wrong','API_KEY':'secret-fixture','GOOGLE_APP_ID':'app','PROJECT_ID':'project'}),
            self.encode({'BUNDLE_ID':'io.github.SwallOwDili.OpenPaste'})]:
            with self.subTest(value=value):
                result,exists,_=self.run_config(value)
                self.assertNotEqual(result.returncode,0)
                self.assertFalse(exists)
                self.assertNotIn('secret-fixture',result.stdout+result.stderr)

    @staticmethod
    def encode(config): return base64.b64encode(plistlib.dumps(config)).decode()

    def test_valid_configuration_is_private(self):
        result,exists,mode=self.run_config(self.encode({'BUNDLE_ID':'io.github.SwallOwDili.OpenPaste','API_KEY':'secret-fixture','GOOGLE_APP_ID':'app','PROJECT_ID':'project'}))
        self.assertEqual(result.returncode,0)
        self.assertTrue(exists); self.assertEqual(mode,0o600)
        self.assertNotIn('secret-fixture',result.stdout+result.stderr)

if __name__ == '__main__': unittest.main()
