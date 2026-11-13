import importlib.util
from pathlib import Path
import plistlib
import tempfile
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location('installer', Path(__file__).with_name('install-local-app.py'))
installer = importlib.util.module_from_spec(spec)
spec.loader.exec_module(installer)

class Runtime:
    def __init__(self, fail=False): self.fail = fail; self.launched = []; self.trashed = []; self.unregistered = []
    def validate(self, path): installer.bundle_info(path)
    def stop(self): pass
    def unregister(self, path): self.unregistered.append(path)
    def register(self, path): pass
    def trash(self, path):
        self.trashed.append(path)
        path.rename(path.with_name('Trash-' + path.name))
    def launch(self, path):
        self.launched.append(path)
        if self.fail and (path / 'version').read_text() == 'new': raise RuntimeError('launch failed')

class InstallTests(unittest.TestCase):
    def setUp(self):
        # Installer tests must never discover or relocate actual apps on this Mac.
        self.discovery = patch.object(installer, 'duplicate_candidates', return_value=[])
        self.discovery.start()
        self.addCleanup(self.discovery.stop)
    def bundle(self, root, name, version, identifier=installer.BUNDLE_ID):
        path = root / name
        (path / 'Contents').mkdir(parents=True)
        (path / 'Contents/Info.plist').write_bytes(plistlib.dumps({'CFBundleIdentifier': identifier}))
        (path / 'version').write_text(version)
        return path
    def test_replace_and_remove_transaction_files(self):
        with tempfile.TemporaryDirectory() as d:
            root = Path(d); src = self.bundle(root, 'source.app', 'new')
            dst = self.bundle(root, 'notchJP.app', 'old')
            installer.install(src, dst, Runtime())
            self.assertEqual((dst / 'version').read_text(), 'new')
            self.assertFalse(list(root.glob('.notchjp-install-*')))
    def test_failed_launch_restores_previous_version(self):
        with tempfile.TemporaryDirectory() as d:
            root = Path(d); src = self.bundle(root, 'source.app', 'new')
            dst = self.bundle(root, 'notchJP.app', 'old'); runtime = Runtime(fail=True)
            with self.assertRaises(RuntimeError): installer.install(src, dst, runtime)
            self.assertEqual((dst / 'version').read_text(), 'old')
            self.assertEqual(runtime.launched, [dst, dst])
    def test_legacy_name_is_restored_on_failure(self):
        with tempfile.TemporaryDirectory() as d:
            root = Path(d); src = self.bundle(root, 'source.app', 'new')
            old = self.bundle(root, 'notchi.app', 'old'); dst = root / 'notchJP.app'
            with self.assertRaises(RuntimeError): installer.install(src, dst, Runtime(fail=True))
            self.assertTrue(old.exists()); self.assertFalse(dst.exists())
    def test_unrelated_app_is_never_replaced(self):
        with tempfile.TemporaryDirectory() as d:
            root = Path(d); src = self.bundle(root, 'source.app', 'new')
            dst = self.bundle(root, 'notchJP.app', 'other', 'other.bundle')
            with self.assertRaises(ValueError): installer.install(src, dst, Runtime())
            self.assertEqual((dst / 'version').read_text(), 'other')

    def test_cleanup_keeps_installed_app_and_only_trashes_matching_bundles(self):
        with tempfile.TemporaryDirectory() as d:
            root = Path(d)
            dst = self.bundle(root, 'notchJP.app', 'new')
            old = self.bundle(root, 'old.app', 'old')
            other = self.bundle(root, 'other.app', 'other', 'other.bundle')
            runtime = Runtime()
            removed = installer.cleanup_duplicates(dst, [old, other, dst], runtime)
            self.assertEqual(removed, [old])
            self.assertEqual(runtime.trashed, [old])
            self.assertTrue(dst.exists()); self.assertTrue(other.exists())
            self.assertTrue((root / 'Trash-old.app').exists())

    def test_cleanup_does_not_follow_alias_to_installed_app(self):
        with tempfile.TemporaryDirectory() as d:
            root = Path(d); dst = self.bundle(root, 'notchJP.app', 'new')
            alias = root / 'alias.app'; alias.symlink_to(dst)
            runtime = Runtime()
            self.assertEqual(installer.cleanup_duplicates(dst, [alias], runtime), [])
            self.assertTrue(dst.exists()); self.assertTrue(alias.exists())

    def test_successful_update_cleans_duplicates_after_launch(self):
        with tempfile.TemporaryDirectory() as d:
            root = Path(d); src = self.bundle(root, 'source.app', 'new')
            dst = self.bundle(root, 'notchJP.app', 'old')
            legacy = self.bundle(root, 'notchi.app', 'old')
            runtime = Runtime()
            with patch.object(installer, 'duplicate_candidates', return_value=[src, legacy, dst]):
                installer.install(src, dst, runtime)
            self.assertEqual((dst / 'version').read_text(), 'new')
            self.assertCountEqual(runtime.trashed, [src, legacy])

    def test_failed_update_does_not_clean_duplicates(self):
        with tempfile.TemporaryDirectory() as d:
            root = Path(d); src = self.bundle(root, 'source.app', 'new')
            dst = self.bundle(root, 'notchJP.app', 'old'); runtime = Runtime(fail=True)
            with patch.object(installer, 'duplicate_candidates', return_value=[src]):
                with self.assertRaises(RuntimeError): installer.install(src, dst, runtime)
            self.assertTrue(src.exists()); self.assertEqual(runtime.trashed, [])

    def test_build_postaction_unregisters_only_build_copy(self):
        with tempfile.TemporaryDirectory() as d:
            root = Path(d); build = self.bundle(root, 'build.app', 'new')
            runtime = Runtime()
            installer.unregister_build(build, runtime)
            self.assertEqual(runtime.unregistered, [build])
            self.assertTrue(build.exists())
            self.assertEqual(runtime.trashed, [])
            installer.unregister_build(Path('/Applications/notchJP.app'), runtime)
            self.assertEqual(runtime.unregistered, [build])

if __name__ == '__main__': unittest.main()
