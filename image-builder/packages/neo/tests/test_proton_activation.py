#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
import hashlib
import importlib.util
import io
import json
import os
from pathlib import Path
import subprocess
import tarfile
import tempfile
import unittest
from unittest.mock import patch

SOURCE = Path(__file__).resolve().parents[1] / 'recipes/steam-native/steam-first-launch.py'
spec = importlib.util.spec_from_file_location('first_launch', SOURCE)
launch = importlib.util.module_from_spec(spec)
spec.loader.exec_module(launch)


class ProtonActivationTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.home = Path(self.temp.name)
        self.root = self.home / 'Steam'
        self.guard = self.home / 'guard.so'
        self.guard.write_bytes(b'guarded native library')
        self.archive = self.home / 'proton.tar.gz'
        self.patch = patch.multiple(launch, PROTON_ARCHIVE=self.archive, GUARD=self.guard,
                                    VENDOR_NTDLL_SHA256=hashlib.sha256(b'vendor library').hexdigest())
        self.patch.start()
        self.addCleanup(self.patch.stop)
        trust = patch.object(launch, 'trusted_path', side_effect=lambda p: p)
        trust.start()
        self.addCleanup(trust.stop)
        runtime = patch.object(launch, 'activate_runtime')
        self.runtime_mock = runtime
        runtime.start()
        self.addCleanup(runtime.stop)
        pin = patch.object(launch, 'guard_policy', return_value=launch.digest(self.guard))
        pin.start()
        self.addCleanup(pin.stop)
        graphics = patch.object(launch, 'graphics_inputs', return_value={})
        graphics.start()
        self.addCleanup(graphics.stop)
        self.make_archive()

    def make_archive(self, extra=None, vendor=b'vendor library'):
        files = {'files/lib/wine/aarch64-unix/ntdll.so': vendor,
                 'compatibilitytool.vdf': b'"GE-Proton11-7-aarch64" { "display_name" "GE-Proton11-7-aarch64" }'}
        with tarfile.open(self.archive, 'w:gz') as tar:
            for name, data in files.items():
                info = tarfile.TarInfo('GE-Proton11-7-aarch64/' + name)
                info.size = len(data)
                tar.addfile(info, io.BytesIO(data))
            if extra:
                tar.addfile(extra)
        launch.PROTON_SHA256 = launch.digest(self.archive)

    def test_fresh_tool_repeat_and_user_choices_preserved(self):
        self.root.mkdir()
        choice = self.root / 'config.vdf'
        choice.write_bytes(b'user compatibility choice')
        tool = launch.install_proton(self.root)
        self.assertEqual((tool / 'files/lib/wine/aarch64-unix/ntdll.so').read_bytes(), self.guard.read_bytes())
        self.assertIn(launch.PROTON_NAME, (tool / 'compatibilitytool.vdf').read_text())
        marker = (tool / 'aurora-source.json').stat().st_mtime_ns
        self.assertEqual(launch.install_proton(self.root), tool)
        self.assertEqual((tool / 'aurora-source.json').stat().st_mtime_ns, marker)
        self.assertEqual(choice.read_bytes(), b'user compatibility choice')

    def test_archive_mismatch_creates_no_tool(self):
        self.archive.write_bytes(b'substitution')
        with self.assertRaisesRegex(ValueError, 'archive hash'):
            launch.install_proton(self.root)
        self.assertFalse((self.root / 'compatibilitytools.d' / launch.PROTON_NAME).exists())

    def test_guard_mismatch_refused_before_user_state(self):
        self.guard.write_bytes(b'substitution')
        with self.assertRaisesRegex(ValueError, 'guard hash'):
            launch.install_proton(self.root)
        self.assertFalse(self.root.exists())

    def test_wrong_vendor_library_is_not_replaced(self):
        self.make_archive(vendor=b'wrong version')
        with self.assertRaisesRegex(ValueError, 'vendor ntdll'):
            launch.install_proton(self.root)

    def test_existing_user_tool_is_preserved(self):
        target = self.root / 'compatibilitytools.d' / launch.PROTON_NAME
        target.mkdir(parents=True)
        (target / 'user-file').write_bytes(b'preserve')
        with self.assertRaisesRegex(ValueError, 'preserving user state'):
            launch.install_proton(self.root)
        self.assertEqual((target / 'user-file').read_bytes(), b'preserve')

    def test_escaping_archive_link_is_refused(self):
        member = tarfile.TarInfo('GE-Proton11-7-aarch64/escape')
        member.type = tarfile.SYMTYPE
        member.linkname = '../../outside'
        self.make_archive(extra=member)
        with self.assertRaises(tarfile.FilterError):
            launch.install_proton(self.root)
        self.assertFalse((self.home / 'outside').exists())

    def test_pinned_runtime_entrypoint_and_provider_contract(self):
        self.runtime_mock.stop()
        share = self.home / 'share'
        vendor = share / 'offline/vendor'
        vendor.mkdir(parents=True)
        depot = self.home / 'depot'
        depot.mkdir()
        (depot / 'emulator.json').write_text('{}')
        (share / 'graphics_provider.json').write_text('{"graphics_provider_v0":{"root":"./"}}')
        inputs = {}
        for role in ['arm', 'guest']:
            archive = vendor / (role + '.tar.gz')
            files = {'files/fixture': b'guest runtime'}
            if role == 'arm':
                prefix = 'SteamLinuxRuntime_4-arm64/'
                files = {prefix + 'run': b'dir=steamrt4_platform_4.0.20260805.254769\nexport PRESSURE_VESSEL_ARCHITECTURES=aarch64-linux-gnu\n',
                         prefix + '_v2-entry-point': b'#!/bin/sh\n',
                         prefix + 'pressure-vessel/fixture': b'arm pv'}
            with tarfile.open(archive, 'w:gz') as tar:
                for name, data in files.items():
                    member = tarfile.TarInfo(name)
                    member.size = len(data)
                    tar.addfile(member, io.BytesIO(data))
            inputs[role] = (archive.name, launch.digest(archive))
        tool = self.home / 'tool'
        tool.mkdir()
        (tool / 'toolmanifest.vdf').write_text('"commandline" "/proton %verb%"\n"require_tool_appid" "4185400"\n')
        with patch.multiple(launch, SHARE=share, FEX_DEPOT=depot, RUNTIME_INPUTS=inputs, GRAPHICS_INPUTS={}):
            launch.activate_runtime(tool, {})
        manifest = (tool / 'toolmanifest.vdf').read_text()
        self.assertNotIn('require_tool_appid', manifest)
        self.assertIn('/aurora-proton %verb%', manifest)
        run = (tool / 'runtime/run').read_text()
        self.assertIn('dir=guest', run)
        self.assertIn('x86_64-linux-gnu,i386-linux-gnu', run)
        wrapper = (tool / 'aurora-proton').read_text()
        self.assertIn('FEX_PORTABLE=1', wrapper)
        self.assertIn('graphics/graphics_provider.json', wrapper)
        self.assertIn('--verb="$verb" -- "$here/proton" "$verb" "$@"', wrapper)
        # Execute the actual generated wrapper with only its leaf intercepted.
        # This checks argv/environment behavior without launching PV or a game.
        entry = tool / 'runtime/_v2-entry-point'
        entry.write_text('#!/usr/bin/env python3\nimport json,os,sys\nprint(json.dumps({"argv":sys.argv[1:],"env":{k:os.environ.get(k) for k in ["FEX_PORTABLE","STEAM_COMPAT_EMULATOR","STEAM_COMPAT_GRAPHICS_PROVIDER","STEAM_COMPAT_MACHINE_ARCHITECTURE"]}}))\n')
        env = dict(os.environ)
        for key in ['FEX_PORTABLE', 'STEAM_COMPAT_EMULATOR', 'STEAM_COMPAT_GRAPHICS_PROVIDER', 'STEAM_COMPAT_MACHINE_ARCHITECTURE']:
            env.pop(key, None)
        result = subprocess.run([str(tool / 'aurora-proton'), 'waitforexitandrun', 'game path.exe', '--flag'], env=env, capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        receipt = json.loads(result.stdout)
        self.assertEqual(receipt['argv'], ['--verb=waitforexitandrun', '--', str(tool.resolve() / 'proton'), 'waitforexitandrun', 'game path.exe', '--flag'])
        self.assertEqual(receipt['env']['FEX_PORTABLE'], '1')
        self.assertEqual(receipt['env']['STEAM_COMPAT_GRAPHICS_PROVIDER'], str(tool.resolve() / 'graphics/graphics_provider.json'))
        self.assertEqual(receipt['env']['STEAM_COMPAT_EMULATOR'], str(tool.resolve() / 'fex/emulator.json'))
        env.update(FEX_PORTABLE='1', STEAM_COMPAT_EMULATOR='/user/emulator.json', STEAM_COMPAT_GRAPHICS_PROVIDER='/user/provider.json')
        result = subprocess.run([str(tool / 'aurora-proton'), 'run'], env=env, capture_output=True, text=True)
        receipt = json.loads(result.stdout)
        self.assertEqual(receipt['env']['STEAM_COMPAT_EMULATOR'], '/user/emulator.json')
        self.assertEqual(receipt['env']['STEAM_COMPAT_GRAPHICS_PROVIDER'], '/user/provider.json')
        for value in ['0', '']:
            env['FEX_PORTABLE'] = value
            result = subprocess.run([str(tool / 'aurora-proton'), 'run'], env=env, capture_output=True, text=True)
            self.assertEqual(result.returncode, 2)
            self.assertIn('preserving your incompatible setting', result.stderr)
            self.assertFalse(result.stdout)

    def test_runtime_absolute_sysroot_link_is_confined(self):
        stage = self.home / 'runtime-stage'
        stage.mkdir()
        member = tarfile.TarInfo('files/etc/alsa/conf.d/10-samplerate.conf')
        member.type = tarfile.SYMTYPE
        member.linkname = '/usr/share/alsa/alsa.conf'
        filtered = launch.runtime_filter(member, str(stage))
        resolved = (stage / filtered.name).parent / filtered.linkname
        self.assertEqual(resolved.resolve(), (stage / 'files/usr/share/alsa/alsa.conf').resolve())
        for name, link in [('files/etc/bad', '/../../outside'), ('pressure-vessel/bad', '/usr/lib/bad')]:
            member.name, member.linkname = name, link
            with self.subTest(name=name), self.assertRaises(ValueError):
                launch.runtime_filter(member, str(stage))


if __name__ == '__main__':
    unittest.main()
