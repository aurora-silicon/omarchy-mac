#!/usr/bin/env python3
"""Native build-tool closure is pinned; it cannot become a target payload."""
import hashlib
import importlib.util
import json
from pathlib import Path
import subprocess
import tempfile
import unittest

spec = importlib.util.spec_from_file_location('native_btrfs', Path(__file__).parents[1] / 'builder/native_btrfs.py')
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


class NativeBtrfsTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.source = Path(self.tmp.name) / 'input'
        self.source.mkdir()
        self.header = b'\x7fELF\x02\x01' + bytes(12) + b'\x3e\x00' + bytes(44)
        self.files = {}
        for name in ('btrfs', 'snapper', 'ld-linux-x86-64.so.2', 'libc.so.6'):
            (self.source / name).write_bytes(self.header)
            self.files[name] = hashlib.sha256(self.header).hexdigest()
        self.write_receipt()

    def write_receipt(self):
        (self.source / 'receipt.json').write_text(json.dumps({'schema': 1, 'version': 'btrfs-progs v7.0', 'files': self.files}))
        self.sha = module.digest(self.source / 'receipt.json')

    def test_freeze_keeps_verified_bytes_and_only_named_closure(self):
        (self.source / 'unrelated-private-key').write_text('never copied')
        target = Path(self.tmp.name) / 'output'
        module.freeze(self.source, target, self.sha)
        self.assertEqual(set(p.name for p in target.iterdir()), {'receipt.json', 'bin', *self.files})
        module.validate(target, self.sha)
        self.assertIn('tool_root=/run/omarchy-builder/native-btrfs', (target / 'bin/btrfs').read_text())
        self.assertIn('tool_root=/native-btrfs', (target / 'bin/btrfs').read_text())
        self.assertIn('$tool_root/snapper', (target / 'bin/snapper').read_text())
        runner = (target / 'bin/snapper-leaf-run').read_text()
        self.assertIn('mount --make-rprivate /', runner)
        self.assertIn('exec /bin/bash -eE /run/omarchy-builder/original-snapper.sh', runner)
        self.assertNotIn('mkinitcpio', runner)
        self.assertFalse((target / 'bin/btrfs').stat().st_mode & 0o222)
        self.assertFalse(target.stat().st_mode & 0o222)

    def test_changed_receipt_or_binary_is_rejected(self):
        with self.assertRaisesRegex(ValueError, 'receipt changed'):
            module.validate(self.source, '0' * 64)
        (self.source / 'btrfs').write_bytes(self.header + b'changed')
        with self.assertRaisesRegex(ValueError, 'file changed'):
            module.validate(self.source, self.sha)

    def test_original_leaf_failure_cannot_fall_through_to_success(self):
        (self.source / 'xtables-nft-multi').write_bytes(self.header)
        self.files['xtables-nft-multi'] = hashlib.sha256(self.header).hexdigest()
        self.write_receipt()
        target = Path(self.tmp.name) / 'output'
        module.freeze(self.source, target, self.sha)
        leaf = Path(self.tmp.name) / 'original.sh'
        marker = Path(self.tmp.name) / 'false-pass'
        leaf.write_text('false\nprintf "incorrect success" > "' + str(marker) + '"\n')
        for kind in ['snapper', 'firewall']:
            runner = (target / ('bin/' + kind + '-leaf-run')).read_text()
            handoff = runner.splitlines()[-1].replace('/run/omarchy-builder/original-' + kind + '.sh', str(leaf))
            result = subprocess.run(['/bin/bash', '-c', handoff], capture_output=True, text=True)
            self.assertNotEqual(result.returncode, 0)
            self.assertFalse(marker.exists())

    def test_firewall_multicall_alias_dispatch_and_private_network(self):
        (self.source / 'xtables-nft-multi').write_bytes(self.header)
        self.files['xtables-nft-multi'] = hashlib.sha256(self.header).hexdigest()
        self.write_receipt()
        target = Path(self.tmp.name) / 'output'
        module.freeze(self.source, target, self.sha)
        launcher = (target / 'bin/firewall-leaf').read_text()
        self.assertIn('unshare --mount --net --fork', launcher)
        runner = (target / 'bin/firewall-leaf-run').read_text()
        self.assertEqual(runner.count('mount --bind'), 1)
        self.assertIn('/usr/bin/xtables-nft-multi', runner)
        self.assertIn('original-firewall.sh', runner)
        self.assertNotIn('mkinitcpio', runner)
        # Execute the generated basename dispatch with only the ELF loader leaf
        # intercepted. A shared-target mount must preserve both frontend aliases.
        fake = Path(self.tmp.name) / 'loader'
        fake.mkdir()
        loader = fake / 'ld-linux-x86-64.so.2'
        loader.write_text('#!/bin/bash\nprintf "%s\\n" "$XTABLES_LIBDIR" "$@"\n')
        loader.chmod(0o700)
        dispatcher = fake / 'xtables-nft-multi'
        dispatcher.write_text((target / 'bin/xtables-nft-multi').read_text().replace('/run/omarchy-builder/native-btrfs', str(fake)))
        dispatcher.chmod(0o700)
        for name in ['iptables', 'ip6tables', 'iptables-save', 'ip6tables-restore']:
            alias = fake / name
            alias.symlink_to('xtables-nft-multi')
            result = subprocess.run([str(alias), '-V'], capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(result.stdout.splitlines(), [str(fake), '--library-path', str(fake), str(fake / 'xtables-nft-multi'), name, '-V'])
        result = subprocess.run([str(dispatcher), '-V'], capture_output=True, text=True)
        self.assertEqual(result.returncode, 64)
        result = subprocess.run([str(dispatcher), 'iptables', '-V'], capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.splitlines()[-2:], ['iptables', '-V'])

    def test_symlink_and_path_escape_are_rejected(self):
        (self.source / 'btrfs').unlink()
        (self.source / 'btrfs').symlink_to('libc.so.6')
        with self.assertRaisesRegex(ValueError, 'file changed'):
            module.validate(self.source, self.sha)
        self.files['../escape'] = self.files['libc.so.6']
        self.write_receipt()
        with self.assertRaises(ValueError):
            module.validate(self.source, self.sha)

    def test_wrong_architecture_and_incomplete_closure_are_rejected(self):
        (self.source / 'btrfs').write_bytes(self.header[:18] + b'\xb7\x00' + self.header[20:])
        self.files['btrfs'] = module.digest(self.source / 'btrfs')
        self.write_receipt()
        with self.assertRaisesRegex(ValueError, 'x86_64 ELF'):
            module.validate(self.source, self.sha)
        del self.files['ld-linux-x86-64.so.2']
        self.write_receipt()
        with self.assertRaisesRegex(ValueError, 'incomplete'):
            module.validate(self.source, self.sha)


if __name__ == '__main__':
    unittest.main()
