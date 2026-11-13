import plistlib
from pathlib import Path
import tempfile
import unittest
from verify_public_build import verify


class PublicBuildTests(unittest.TestCase):
    def test_public_bundle_rejects_private_configuration(self):
        base = dict(NJPDistributionEdition='public', SUEnableAutomaticChecks=False, SUAutomaticallyUpdate=False)
        with tempfile.TemporaryDirectory() as directory:
            app = Path(directory) / 'Demo.app'
            info = app / 'Contents/Info.plist'
            info.parent.mkdir(parents=True)
            info.write_bytes(plistlib.dumps(base))
            verify(app)
            for key, value in [('NJPDistributionEdition', 'private'), ('SUFeedURL', 'https://example.invalid/feed'),
                               ('SUPublicEDKey', ''), ('NJPUpdateAccessToken', ''),
                               ('SUEnableAutomaticChecks', True), ('SUAutomaticallyUpdate', True)]:
                with self.subTest(key=key):
                    info.write_bytes(plistlib.dumps(base | {key: value}))
                    with self.assertRaises(ValueError):
                        verify(app)
            info.write_bytes(plistlib.dumps({'NJPDistributionEdition': 'public'}))
            with self.assertRaises(ValueError):
                verify(app)


if __name__ == '__main__':
    unittest.main()
