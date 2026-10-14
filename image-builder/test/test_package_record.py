#!/usr/bin/env python3
"""Required stock archives retain their pinned repository and byte identity."""
import hashlib
import json
from pathlib import Path
import subprocess
import shutil
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]


class StockRecordTest(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.base = Path(self.temporary.name)
        self.repositories = self.base / 'repos'
        self.cache = self.base / 'cache'
        self.cache.mkdir()
        self.archive = self.cache / 'stock-1-1-aarch64.pkg.tar.xz'
        self.archive.write_bytes(b'exact signed stock archive fixture')
        self.sha256 = hashlib.sha256(self.archive.read_bytes()).hexdigest()
        self.write_database(self.sha256)
        self.policy = self.base / 'policy.json'
        self.policy.write_text(json.dumps({'runtime_packages': [], 'boot_packages': [], 'refused_packages': [],
            'required_stock_packages': {'stock': {'repository': 'asahi-alarm', 'version': '1-1', 'sha256': self.sha256}}}))
        self.root = self.base / 'root'
        desc = self.root / 'var/lib/pacman/local/stock-1-1/desc'
        desc.parent.mkdir(parents=True)
        desc.write_text('%NAME%\nstock\n\n%VERSION%\n1-1\n\n')
        self.candidates = self.base / 'import.json'
        self.candidates.write_text('{"packages": []}')

    def write_database(self, sha256):
        database = self.repositories / 'asahi-alarm/asahi-alarm.db'
        database.parent.mkdir(parents=True, exist_ok=True)
        desc = self.base / 'db/stock-1-1/desc'
        desc.parent.mkdir(parents=True, exist_ok=True)
        desc.write_text(f'%NAME%\nstock\n\n%VERSION%\n1-1\n\n%FILENAME%\n{self.archive.name}\n\n%SHA256SUM%\n{sha256}\n\n')
        subprocess.run(['bsdtar', '-czf', str(database), '-C', str(desc.parent.parent), 'stock-1-1'], check=True)

    def run_record(self, requests=False, order='asahi-alarm'):
        command = ['python3', str(ROOT / 'builder/package_record.py'), '--repositories', str(self.repositories),
                   '--stock-policy', str(self.policy)]
        if requests:
            command += ['--stock-requests']
        else:
            command += ['--root', str(self.root), '--order', order, '--cache', str(self.cache),
                        '--candidates', str(self.candidates)]
        return subprocess.run(command, capture_output=True, text=True)

    def test_exact_stock_request_and_archive_provenance(self):
        request = self.run_record(requests=True)
        self.assertEqual(request.returncode, 0, request.stderr)
        self.assertEqual(request.stdout, 'asahi-alarm/stock=1-1\n')
        record = self.run_record()
        self.assertEqual(record.returncode, 0, record.stderr)
        self.assertIn(f'stock|1-1|asahi-alarm|{self.archive.name}|{self.sha256}', record.stdout)

    def test_same_version_with_different_database_archive_stops_before_install(self):
        self.write_database('0' * 64)
        result = self.run_record(requests=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('does not match the required stock archive', result.stderr)

    def test_tampered_cached_stock_archive_is_refused(self):
        self.archive.write_bytes(b'tampered')
        result = self.run_record()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('does not trace to a pinned database and archive', result.stderr)

    def test_required_stock_package_must_be_installed(self):
        (self.root / 'var/lib/pacman/local/stock-1-1/desc').unlink()
        result = self.run_record()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('required stock packages are not installed', result.stderr)

    def test_identical_archive_in_earlier_repository_keeps_declared_stock_origin(self):
        extra = self.repositories / 'extra/extra.db'
        extra.parent.mkdir()
        shutil.copyfile(self.repositories / 'asahi-alarm/asahi-alarm.db', extra)
        result = self.run_record(order='extra,asahi-alarm')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('stock|1-1|asahi-alarm|', result.stdout)

    def test_wrong_installed_stock_version_is_refused(self):
        (self.root / 'var/lib/pacman/local/stock-1-1/desc').write_text('%NAME%\nstock\n\n%VERSION%\n2-1\n\n')
        result = self.run_record()
        self.assertNotEqual(result.returncode, 0)

    def test_required_stock_repository_cannot_be_substituted(self):
        extra = self.repositories / 'extra/extra.db'
        extra.parent.mkdir()
        shutil.copyfile(self.repositories / 'asahi-alarm/asahi-alarm.db', extra)
        (self.repositories / 'asahi-alarm/asahi-alarm.db').unlink()
        result = self.run_record(order='extra')
        self.assertNotEqual(result.returncode, 0)


if __name__ == '__main__':
    unittest.main()
