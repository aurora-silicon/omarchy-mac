#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""Pure source/guard fixtures. No compiler, package install or hardware operation."""
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]


def load(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


fex = load('fex_sources', ROOT / 'recipes/fex/sources.py')
reuse = load('reuse_inputs', ROOT / 'scripts/fetch-reuse.py')
kernel_stage = load('kernel_stage', ROOT / 'scripts/stage-kernel-inputs.py')


class SourceGuardTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.repo = Path(self.temp.name) / 'source'
        self.repo.mkdir()
        self.git('init', '-q')
        (self.repo / '.gitignore').write_text('ignored-input.h\n')
        (self.repo / 'source.c').write_text('public source\n')
        self.git('add', '.')
        self.git('-c', 'user.name=Fixture', '-c', 'user.email=fixture@example.invalid', 'commit', '-qm', 'fixture')
        self.record = {'commit': self.git('rev-parse', 'HEAD'), 'tree': self.git('rev-parse', 'HEAD^{tree}')}

    def git(self, *args):
        return subprocess.check_output(['git', '-C', str(self.repo), *args], text=True).strip()

    def test_clean_source_passes_but_tracked_untracked_and_ignored_inputs_fail(self):
        fex.verify_checkout(self.repo, self.record)
        for name in ['source.c', 'untracked-input.h', 'ignored-input.h']:
            with self.subTest(name=name):
                file = self.repo / name
                original = file.read_bytes() if file.exists() else None
                file.write_text('injected build input\n')
                with self.assertRaisesRegex(ValueError, 'modified public source'):
                    fex.verify_checkout(self.repo, self.record)
                if original is None:
                    file.unlink()
                else:
                    file.write_bytes(original)

    def test_wrong_commit_or_tree_is_refused(self):
        for field in ['commit', 'tree']:
            record = dict(self.record, **{field: '0' * 40})
            with self.subTest(field=field), self.assertRaisesRegex(ValueError, 'identity mismatch'):
                fex.verify_checkout(self.repo, record)

    def test_declared_build_output_outside_source_does_not_inject_inputs(self):
        output = self.repo.parent / 'build'
        output.mkdir()
        (output / 'generated.o').write_bytes(b'declared output')
        fex.verify_checkout(self.repo, self.record)

    def test_pinned_license_blobs_and_embedded_softfloat_notices_are_preserved(self):
        license_file = self.repo / 'LICENSE'
        license_file.write_bytes(b'fixture license\n')
        prefix = b'/* Copyright Fixture. Redistribution and use are permitted. */'
        for path in ['External/SoftFloat-3e/src/a.c', 'External/SoftFloat-3e/include/b.h']:
            file = self.repo / path
            file.parent.mkdir(parents=True, exist_ok=True)
            file.write_bytes(prefix + b'\nint fixture;\n')
        self.git('add', '.')
        self.git('-c', 'user.name=Fixture', '-c', 'user.email=fixture@example.invalid', 'commit', '-qm', 'notices')
        lock = self.repo.parent / 'notices.json'
        lock.write_text(json.dumps([{'repository_path': '.', 'path': 'LICENSE',
                                    'sha256': hashlib.sha256(license_file.read_bytes()).hexdigest()}]))
        destination = self.repo.parent / 'notices'
        fex.notices(lock, self.repo, destination)
        self.assertEqual((destination / 'LICENSE').read_bytes(), license_file.read_bytes())
        embedded = list((destination / 'External/SoftFloat-3e').glob('NOTICE-*.txt'))
        self.assertEqual(len(embedded), 1)
        self.assertEqual(embedded[0].read_bytes(), prefix)

    def test_runtime_default_and_optional_local_sources_are_verified(self):
        for package in ['omarchy', 'omarchy-settings']:
            recipe = ROOT / 'recipes/runtime' / package / 'PKGBUILD'
            srcdir = self.repo.parent / package
            srcdir.mkdir()
            subprocess.run(['git', 'clone', '-q', str(self.repo), str(srcdir / 'omarchy')], check=True)
            for local in ['', str(self.repo)]:
                script = 'source "$1"\n_commit=$2\nsrcdir=$3\nOMARCHY_SRC=$4\nprepare\n'
                env = dict(os.environ, CARCH='aarch64')
                result = subprocess.run(['bash', '-c', script, 'fixture', str(recipe), self.record['commit'], str(srcdir), local], env=env, capture_output=True, text=True)
                self.assertEqual(result.returncode, 0, result.stderr)
            (self.repo / 'ignored-input.h').write_text('unapproved input')
            script = 'source "$1"\n_commit=$2\nsrcdir=$3\nOMARCHY_SRC=$4\nprepare\n'
            result = subprocess.run(['bash', '-e', '-c', script, 'fixture', str(recipe), self.record['commit'], str(srcdir), str(self.repo)], env=dict(os.environ, CARCH='aarch64'), capture_output=True, text=True)
            self.assertNotEqual(result.returncode, 0)
            (self.repo / 'ignored-input.h').unlink()


class RecipeContractTests(unittest.TestCase):
    def test_overlay_current_source_version_and_cross_input(self):
        directory = ROOT / 'recipes/mesa-overlays'
        text = (directory / 'PKGBUILD').read_text()
        self.assertIn('524105acd30b58c7581ae7e0a1920e5775f9f792', text)
        self.assertIn('pkgver=26.3.0.devel.20261014.g524105a', text)
        self.assertIn("'cross_x86'", text)
        self.assertIn(hashlib.sha256((directory / 'cross_x86').read_bytes()).hexdigest(), text)
        self.assertIn('echo "$_overlay_build_version" >VERSION', text)
        self.assertNotIn('$epoch', text)
        result = subprocess.check_output(['bash', '-c', 'source "$1"; printf "%s" "$_overlay_build_version"', 'fixture', str(directory / 'PKGBUILD')], text=True)
        self.assertEqual(result, '26.3.0-devel.20261014.g524105a-arch2')

    def test_overlay_policy_is_generated_from_actual_output_bytes(self):
        directory = ROOT / 'recipes/mesa-overlays'
        with tempfile.TemporaryDirectory() as temp:
            image = Path(temp) / 'mesa-x86_64.erofs'
            image.write_bytes(b'fresh compiled image fixture')
            subprocess.run(['bash', '-c', 'source "$1"; write_overlay_policy "$2" x86_64',
                            'fixture', str(directory / 'PKGBUILD'), str(image)], check=True)
            policy = json.loads(image.with_name(image.name + '.json').read_text())
            self.assertEqual(policy, {'schema': 1, 'role': 'fex-guest-mesa-overlay',
                'source_commit': '524105acd30b58c7581ae7e0a1920e5775f9f792',
                'architecture': 'x86_64', 'build_version': '26.3.0-devel.20261014.g524105a-arch2',
                'image_path': '/usr/share/fex-emu/overlays/mesa-x86_64.erofs',
                'image_sha256': hashlib.sha256(image.read_bytes()).hexdigest()})
            image.write_bytes(b'different clean build')
            subprocess.run(['bash', '-c', 'source "$1"; write_overlay_policy "$2" x86_64',
                            'fixture', str(directory / 'PKGBUILD'), str(image)], check=True)
            self.assertNotEqual(json.loads(image.with_name(image.name + '.json').read_text())['image_sha256'], policy['image_sha256'])

    def test_actual_final_steam_support_is_checksum_bound(self):
        directory = ROOT / 'recipes/steam-native'
        recipe = (directory / 'PKGBUILD').read_text()
        self.assertIn('pkgrel=3', recipe)
        self.assertIn('aurora-proton-sve-guard aurora-fex-steam erofs-utils', recipe)
        self.assertIn('a1b375b287fe6db4d2e95beb9d945af15b3ef9db', recipe)
        for name in ['steam-first-launch.py', 'offline-policy.json']:
            self.assertIn(hashlib.sha256((directory / name).read_bytes()).hexdigest(), recipe)
        policy = json.loads((directory / 'offline-policy.json').read_text())
        self.assertEqual(policy['manifest_sha256'], '65079d08bbcc0e7fdc3d9b153aadc4c9befc62913c3e4ee0b02425690366f15f')
        self.assertNotIn('install=', recipe)

    def test_fex_support_hashes_and_native_clean_build_default(self):
        directory = ROOT / 'recipes/fex'
        text = (directory / 'PKGBUILD').read_text()
        for name in ['sources.py', 'source-lock.json', 'guest-rpms.lock.json', 'license-notices.json', 'reuse.lock.json', 'x86-64.cmake', 'x86-32.cmake']:
            self.assertIn(name, text)
            self.assertIn(hashlib.sha256((directory / name).read_bytes()).hexdigest(), text)
        self.assertIn('cmake -S "$srcdir/FEX" -B build', text)
        self.assertIn('-DBUILD_THUNKS=ON', text)
        self.assertNotIn('FEX_OWNED_BUILD_DIR', text)
        self.assertNotIn('CMAKE_CXX_COMPILER_WORKS', text)
        for item in json.loads((directory / 'source-lock.json').read_text()):
            self.assertNotIn('posixtest-bins', item['path'])

    def test_reuse_requires_public_url_and_exact_hash(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            artifact = root / 'package'
            artifact.write_bytes(b'reviewed')
            lock = root / 'lock.json'
            data = {'publication_url': None, 'archive_sha256': hashlib.sha256(b'reviewed').hexdigest(), 'source_commit': '14c92681f4d62cf84d901460e0358de09c8847a7'}
            lock.write_text(json.dumps(data))
            with self.assertRaisesRegex(ValueError, 'public URL'):
                fex.verify_reuse(artifact, lock)
            data['publication_url'] = 'https://example.invalid/releases/v1/package'
            lock.write_text(json.dumps(data))
            fex.verify_reuse(artifact, lock)
            artifact.write_bytes(b'substituted')
            with self.assertRaisesRegex(ValueError, 'differs'):
                fex.verify_reuse(artifact, lock)

    def test_public_development_lock_is_complete_and_qualified(self):
        rows = json.loads((ROOT / 'recipes/fex/guest-rpms.lock.json').read_text())
        qualification = json.loads((ROOT / 'recipes/fex/development-qualification.json').read_text())
        self.assertEqual(len(rows), 107)
        self.assertEqual(qualification['sha256_passed'], 107)
        self.assertFalse(qualification['cryptographic_rpm_signature_verification_performed'])
        self.assertEqual(hashlib.sha256((ROOT / 'recipes/fex/guest-rpms.lock.json').read_bytes()).hexdigest(), qualification['development_lock_sha256'])
        for row in rows:
            self.assertIn('/data/signed/f577861e/', row['url'])
            self.assertIn('source_build_id', row)
            self.assertRegex(row['sha256'], r'^[0-9a-f]{64}$')

    def test_source_and_asset_paths_refuse_escape(self):
        for path in ['', '/absolute', '../outside', 'inside/../../outside']:
            with self.subTest(path=path), self.assertRaises(ValueError):
                fex.relative(path)
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            with self.assertRaisesRegex(ValueError, 'unsafe asset directory'):
                reuse.fetch({'assets': [{'name': 'file', 'directory': '../escape', 'sha256': '0' * 64}]}, root)
            with self.assertRaisesRegex(ValueError, 'immutable public URL'):
                reuse.fetch({'assets': [{'name': 'file', 'sha256': '0' * 64, 'url': None}]}, root)

    def test_public_url_gate_precedes_exact_cache_acceptance(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            cached = root / 'private-exact-cache'
            cached.write_bytes(b'known')
            record = {'assets': [{'name': cached.name, 'sha256': hashlib.sha256(b'known').hexdigest(), 'url': None}]}
            with self.assertRaisesRegex(ValueError, 'immutable public URL'):
                reuse.fetch(record, root)
            self.assertEqual(cached.read_bytes(), b'known')

    def test_clean_kernel_staging_emits_new_checksum_bound_recipes(self):
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory)
            for name, body in [('kernel-runtime.tar', b'new clean outputs'), ('reuse-receipt.json', json.dumps({'actual_compile_source': kernel_stage.PIN, 'requested_public_pin': kernel_stage.PIN, 'build_mode': 'clean-source', 'release': '7.1.12-aurora-g5f6c917', 'config_sha256': hashlib.sha256(b'actual config').hexdigest()}).encode()), ('config', b'actual config')]:
                (output / name).write_bytes(body)
            template = ROOT / 'recipes/kernel/PKGBUILD'
            kernel_stage.ready_recipe(template, output)
            generated = (output / 'PKGBUILD').read_text()
            self.assertIn('new pinned public clean-source outputs', generated)
            for name in ['kernel-runtime.tar', 'reuse-receipt.json', 'config']:
                self.assertIn(hashlib.sha256((output / name).read_bytes()).hexdigest(), generated)
            self.assertIn('pkgver=7.1.12.aurora.g5f6c917.c', generated)
            receipt_path = output / 'reuse-receipt.json'
            receipt = json.loads(receipt_path.read_text())
            for key in ['requested_public_pin', 'actual_compile_source', 'release', 'build_mode', 'config_sha256']:
                receipt_path.write_text(json.dumps(dict(receipt, **{key: 'wrong'})))
                with self.assertRaises(ValueError):
                    kernel_stage.ready_recipe(template, output)
            receipt_path.write_text(json.dumps(receipt))
            old_hashes = re.findall("'([^']+)'", re.search(r'sha256sums=\((.*?)\)', template.read_text(), re.S).group(1))
            for digest in old_hashes:
                self.assertNotIn(digest, generated)

    def test_clean_receipt_verifier_and_release_bound_header_destination(self):
        def verifier(template, root):
            text = template.read_text()
            script = text.split("<<'", 1)[1].split("\n", 1)[1]
            script = script.split("\nVERIFY", 1)[0] if "\nVERIFY" in script else script.split("\nPY", 1)[0]
            return subprocess.run([sys.executable, '-c', script, str(root)], capture_output=True)
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            release = '7.1.12-aurora-g5f6c917'
            (root / 'config').write_bytes(b'config')
            image = root / 'usr/lib/modules' / release / 'vmlinuz'
            image.parent.mkdir(parents=True)
            image.write_bytes(b'image')
            receipt = {'build_mode': 'clean-source', 'actual_compile_source': kernel_stage.PIN,
                       'requested_public_pin': kernel_stage.PIN, 'release': release,
                       'config_sha256': hashlib.sha256(b'config').hexdigest(),
                       'files': {str(image.relative_to(root)): hashlib.sha256(b'image').hexdigest()}}
            target = root / 'reuse-receipt.json'
            target.write_text(json.dumps(receipt))
            template = ROOT / 'recipes/kernel/PKGBUILD'
            self.assertEqual(verifier(template, root).returncode, 0)
            for key in ['actual_compile_source', 'requested_public_pin', 'release', 'config_sha256']:
                bad = dict(receipt, **{key: 'wrong'})
                target.write_text(json.dumps(bad))
                self.assertNotEqual(verifier(template, root).returncode, 0, key)
            target.write_text(json.dumps({'actual_incremental_source': kernel_stage.PIN, 'files': receipt['files']}))
            self.assertEqual(verifier(template, root).returncode, 0)
            stage = root / 'stage'
            (stage / 'include/config').mkdir(parents=True)
            (stage / '.config').write_bytes(b'config')
            (stage / 'include/config/kernel.release').write_text(release + '\n')
            self.assertEqual(kernel_stage.verified_release(stage), release)
            hreceipt = {'status': 'PASS', 'build_mode': 'clean-source', 'source': kernel_stage.PIN,
                        'requested_public_pin': kernel_stage.PIN, 'release': release,
                        'config_sha256': receipt['config_sha256'], 'helpers': []}
            header_receipt = root / 'native-helper-receipt.json'
            header_receipt.write_text(json.dumps(hreceipt))
            header_template = ROOT / 'recipes/kernel/headers/PKGBUILD'
            self.assertEqual(verifier(header_template, root).returncode, 0)
            header_receipt.write_text(json.dumps(dict(hreceipt, release='7.1.12-wrong')))
            self.assertNotEqual(verifier(header_template, root).returncode, 0)
            (stage / 'include/config/kernel.release').write_text('7.1.12-aurora-j700-beta-r69-20261014\n')
            with self.assertRaisesRegex(ValueError, 'release'):
                kernel_stage.verified_release(stage)
            header_receipt.write_text(json.dumps({'status': 'PASS', 'config_sha256': receipt['config_sha256'], 'helpers': []}))
            self.assertEqual(verifier(header_template, root).returncode, 0)
            (stage / 'include/config/kernel.release').unlink()
            self.assertNotEqual(verifier(header_template, root).returncode, 0)
            with self.assertRaises(FileNotFoundError):
                kernel_stage.verified_release(stage)
            package = header_template.read_text().split('package() {', 1)[1]
            self.assertIn('release=$(cat stage/include/config/kernel.release)', package)
            self.assertNotIn('local release=7.1.12-aurora-j700', package)

    def test_stale_image_and_module_releases_fail_closed(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            image = root / 'Image'
            modules = root / 'modules'
            modules.mkdir()
            module = modules / 'test.ko'
            release = '7.1.12-aurora-g5f6c917'
            image.write_bytes(b'header\x00Linux version ' + release.encode() + b' (builder)\x00')
            module.write_bytes(b'\x7fELF' + b'\x00' * 16 + b'vermagic=' + release.encode() + b' SMP aarch64\x00')
            kernel_stage.verify_output_releases(image, modules, release)
            valid_image, valid_module = image.read_bytes(), module.read_bytes()
            for data in [b'no banner', valid_image.replace(release.encode(), b'7.1.12-aurora-j700-beta-r69-20261014')]:
                image.write_bytes(data)
                with self.assertRaisesRegex(ValueError, 'Image'):
                    kernel_stage.verify_output_releases(image, modules, release)
            image.write_bytes(valid_image)
            for data in [b'not ELF', valid_module.replace(release.encode(), b'7.1.12-old'), b'\x7fELF\x00no vermagic']:
                module.write_bytes(data)
                with self.assertRaisesRegex(ValueError, 'vermagic'):
                    kernel_stage.verify_output_releases(image, modules, release)
            module.unlink()
            with self.assertRaisesRegex(ValueError, 'no installed'):
                kernel_stage.verify_output_releases(image, modules, release)

    def test_private_controller_paths_and_binaries_are_absent(self):
        for file in ROOT.rglob('*'):
            if file.is_file() and '__pycache__' not in file.parts:
                self.assertNotIn(file.suffix, ['.rpm', '.zst', '.bin', '.o', '.so'])
                if file.suffix not in ['.md'] and file.name != 'test_recipes.py':
                    text = file.read_text()
                    self.assertNotIn('/srv/aurora/', text, str(file))
                    self.assertNotIn('/work/evidence/', text, str(file))


@unittest.skipUnless(sys.platform.startswith('linux'), 'Arch package() requires GNU install')
class UBootDeviceTreePackagingTests(unittest.TestCase):
    def package_fixture(self, models):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            source = root / 'uboot'
            dtbs = source / 'build/dts/upstream/src/arm64/apple'
            dtbs.mkdir(parents=True)
            (source / 'build/u-boot-nodtb.bin').write_bytes(b'unchanged boot payload')
            (source / 'build/.config').write_text('CONFIG_OF_BOARD=y\n')
            (source / 'Licenses').mkdir()
            (source / 'Licenses/README').write_text('upstream license fixture\n')
            for name, model in models.items():
                (dtbs / name).write_text(model + '\n')
            tools = root / 'bin'
            tools.mkdir()
            reader = tools / 'fdtget'
            reader.write_text('#!/bin/sh\ncat "$1"\n')
            reader.chmod(0o755)
            env = dict(os.environ, PATH=str(tools) + os.pathsep + os.environ['PATH'], pkgdir=str(root / 'pkg'))
            result = subprocess.run(['bash', '-e', '-c', 'source "$1"; package', 'fixture',
                                     str(ROOT / 'recipes/uboot/PKGBUILD')], cwd=root, env=env,
                                    text=True, capture_output=True)
            selected = sorted(p.name for p in (root / 'pkg/usr/lib/asahi-boot/dtb').glob('*.dtb'))
            if result.returncode == 0:
                self.assertEqual((root / 'pkg/usr/lib/asahi-boot/u-boot-nodtb.bin').read_bytes(), b'unchanged boot payload')
            return result, selected

    def test_only_compiled_apple_silicon_mac_models_are_packaged(self):
        result, selected = self.package_fixture({'t8103-j274.dtb': 'Apple Mac mini (M1, 2020)',
            't8103-j456.dtb': 'Apple iMac (M1, 2021)', 't8012-j132.dtb': 'Apple T2 MacBookPro15,2',
            's8000-n71.dtb': 'Apple iPhone 6s'})
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(selected, ['t8103-j274.dtb', 't8103-j456.dtb'])

    def test_no_compiled_mac_model_refuses_package(self):
        result, selected = self.package_fixture({'s8000-n71.dtb': 'Apple iPhone 6s'})
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('No compiled Apple Silicon Mac device trees', result.stderr)
        self.assertEqual(selected, [])

    def test_missing_compiled_device_trees_refuses_package(self):
        result, selected = self.package_fixture({})
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(selected, [])


if __name__ == '__main__':
    unittest.main()
