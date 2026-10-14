#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""Stage clean native ARM64 kernel/header build inputs; never install or load them."""
import argparse
import hashlib
import json
import re
from pathlib import Path
import shutil
import struct
import subprocess
import tarfile
import tempfile

PIN = '5f6c917f2c824b3c87497e8bd7dd92a6de0efe60'


def sha(path):
    with path.open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()


def copy_tree(source, target):
    shutil.copytree(source, target, symlinks=True, dirs_exist_ok=True)


def archive(directory, path, name):
    with tarfile.open(path, 'w') as stream:
        stream.add(directory, arcname=name)


def verified_release(build):
    path = Path(build) / 'include/config/kernel.release'
    release = path.read_text().strip()
    if not re.fullmatch(r'[A-Za-z0-9._-]+', release) or not release.endswith('-aurora-g5f6c917'):
        raise ValueError('missing or wrong clean kernel release')
    return release


def verify_output_releases(image, modules, release):
    """Reject stale uncompressed build outputs; not compilation/ABI proof."""
    banners = re.findall(rb'Linux version ([0-9][^\s\x00]+)', Path(image).read_bytes())
    if not banners or set(banners) != {release.encode('ascii')}:
        raise ValueError('Image Linux version banner differs from release or is missing')
    paths = sorted(Path(modules).rglob('*.ko'))
    if not paths:
        raise ValueError('no installed uncompressed kernel modules')
    for path in paths:
        data = path.read_bytes()
        values = re.findall(rb'(?:^|\x00)vermagic=([^\x00]+)', data)
        if data[:4] != b'\x7fELF' or len(values) != 1 or values[0].split(b' ', 1)[0] != release.encode('ascii'):
            raise ValueError('module vermagic differs from release: ' + str(path))


def ready_recipe(template, directory):
    """Generate checksum-bound packaging for these new outputs, never old hashes."""
    text = Path(template).read_text()
    sources = re.findall("'([^']+)'", re.search(r'source=\((.*?)\)', text, re.S).group(1))
    receipt_name = 'reuse-receipt.json' if 'kernel-runtime.tar' in sources else 'native-helper-receipt.json'
    receipt = json.loads((Path(directory) / receipt_name).read_text())
    release = receipt.get('release', '')
    if receipt.get('build_mode') != 'clean-source' or receipt.get('requested_public_pin') != PIN or not re.fullmatch(r'[A-Za-z0-9._-]+', release) or not release.endswith('-aurora-g5f6c917'):
        raise ValueError('generated recipe needs exact clean source/release receipt')
    actual = receipt.get('actual_compile_source', receipt.get('source'))
    if actual != PIN or not re.fullmatch(r'[0-9a-f]{64}', receipt.get('config_sha256', '')):
        raise ValueError('generated recipe needs exact compile/config identity')
    config = Path(directory) / ('config' if 'config' in sources else 'stage/.config')
    if sha(config) != receipt['config_sha256']:
        raise ValueError('generated recipe configuration does not match receipt')
    if 'headers-stage.tar' in sources and verified_release(Path(directory) / 'stage') != release:
        raise ValueError('generated header release does not match receipt')
    version = release.replace('-', '.') + '.c' + receipt['config_sha256'][:12]
    text = re.sub(r'^pkgver=.*$', 'pkgver=' + version, text, count=1, flags=re.M)
    digests = []
    for name in sources:
        if Path(name).name != name:
            raise ValueError('generated recipe has an unsafe source input')
        digests.append(sha(Path(directory) / name))
    text = re.sub(r'sha256sums=\(.*?\)', 'sha256sums=(' + ' '.join(repr(value) for value in digests) + ')', text, count=1, flags=re.S)
    text = text.replace('# Incremental build of public 5f6c917 from the preserved d32 cache.\n# Rebuilt PMGR and SEP, relinked Image and updated the J700 DTB.\n', '')
    text = '# Generated packaging for new pinned public clean-source outputs; not a reproduction of old reuse hashes.\n' + text
    (Path(directory) / 'PKGBUILD').write_text(text)


def stage(source, build, output):
    source, build, output = source.resolve(), build.resolve(), output.resolve()
    if subprocess.check_output(['git', '-C', str(source), 'rev-parse', 'HEAD'], text=True).strip() != PIN:
        raise ValueError('wrong public source pin')
    if subprocess.check_output(['git', '-C', str(source), 'status', '--porcelain', '--untracked-files=all', '--ignored=matching'], text=True).strip():
        raise ValueError('kernel source contains undeclared changes or build inputs; use an external O= build')
    if sha(build / '.config') != sha(Path(__file__).resolve().parents[1] / 'recipes/kernel/config'):
        raise ValueError('effective build configuration differs from the published profile')
    release = verified_release(build)
    output.mkdir(parents=True, exist_ok=False)
    kernel, headers = output / 'kernel', output / 'headers'
    kernel.mkdir()
    headers.mkdir()
    reported_release = subprocess.check_output(['make', '-s', '-C', str(source), 'O=' + str(build), 'kernelrelease'], text=True).strip()
    if reported_release != release:
        raise ValueError('kernelrelease command differs from staged release')
    payload = kernel / 'payload'
    with tempfile.TemporaryDirectory(prefix='kernel-modules-stage-') as directory:
        subprocess.run(['make', '-C', str(source), 'O=' + str(build), 'INSTALL_MOD_PATH=' + directory, 'modules_install'], check=True)
        copy_tree(Path(directory) / 'lib/modules', payload / 'usr/lib/modules')
    modules = payload / 'usr/lib/modules' / release
    verify_output_releases(build / 'arch/arm64/boot/Image', payload / 'usr/lib/modules', release)
    for name in ('build', 'source'):
        link = modules / name
        if link.is_symlink():
            link.unlink()
    shutil.copyfile(build / 'arch/arm64/boot/Image', modules / 'vmlinuz')
    (modules / 'pkgbase').write_text('linux-aurora\n')
    dtbs = sorted((build / 'arch/arm64/boot/dts/apple').glob('*.dtb'))
    if len(dtbs) != 113 or not any(path.name == 't8140-j700.dtb' for path in dtbs):
        raise ValueError('incomplete pinned Apple DTB closure')
    (modules / 'dtbs').mkdir(exist_ok=True)
    for file in dtbs:
        shutil.copyfile(file, modules / 'dtbs' / file.name)
    subprocess.run(['depmod', '-b', str(payload / 'usr'), release], check=True)
    license_dir = payload / 'usr/share/licenses/linux-aurora'
    license_dir.mkdir(parents=True)
    shutil.copyfile(source / 'COPYING', license_dir / 'COPYING')
    copy_tree(source / 'LICENSES', license_dir / 'LICENSES')
    shutil.copyfile(build / '.config', kernel / 'config')
    receipt = {'requested_public_pin': PIN, 'actual_compile_source': PIN, 'build_mode': 'clean-source',
               'source_bit_reproducibility_claim': False, 'release': release, 'config_sha256': sha(build / '.config'),
               'files': {str(p.relative_to(payload)): sha(p) for p in payload.rglob('*') if p.is_file() and not p.is_symlink()}}
    (kernel / 'reuse-receipt.json').write_text(json.dumps(receipt, indent=2) + '\n')
    archive(payload, kernel / 'kernel-runtime.tar', '.')
    # Same native C helper/header contract as the current qualified reuse layout.
    hstage = headers / 'stage'
    hstage.mkdir()
    for directory in ('include', 'scripts', 'arch/arm64/include'):
        copy_tree(source / directory, hstage / directory)
        copy_tree(build / directory, hstage / directory)
    for name in ('.config', 'Module.symvers', 'System.map', 'vmlinux'):
        shutil.copyfile(build / name, hstage / name)
    for name in ('Makefile', 'arch/arm64/Makefile', 'kernel/Makefile'):
        target = hstage / name
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(source / name, target)
    for file in source.rglob('Kconfig*'):
        if file.is_file():
            target = hstage / file.relative_to(source)
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(file, target)
    for parent, pattern in [('drivers/md', '*.h'), ('net/mac80211', '*.h'), ('drivers/media/i2c', 'msp3400-driver.h'),
                            ('drivers/media/usb/dvb-usb', '*.h'), ('drivers/media/dvb-frontends', '*.h'),
                            ('drivers/media/tuners', '*.h'), ('drivers/iio/common/hid-sensors', '*.h')]:
        for file in (source / parent).glob(pattern):
            target = hstage / file.relative_to(source)
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(file, target)
    offset = hstage / 'arch/arm64/kernel/asm-offsets.s'
    offset.parent.mkdir(parents=True, exist_ok=True)
    shutil.copyfile(build / 'arch/arm64/kernel/asm-offsets.s', offset)
    helpers = []
    for file in (hstage / 'scripts').rglob('*'):
        if file.is_file() and not file.is_symlink():
            header = file.read_bytes()[:20]
            if header[:4] == b'\x7fELF':
                if struct.unpack_from('<H', header, 18)[0] != 183:
                    raise ValueError('header helper is not native AArch64: ' + str(file))
                helpers.append({'path': str(file.relative_to(hstage)), 'sha256': sha(file), 'machine': 'AArch64'})
    if not helpers:
        raise ValueError('no built native header helpers')
    for file in hstage.rglob('*'):
        if file.is_file() and not file.is_symlink() and file.suffix in ('.o', '.cmd', '.d', '.a'):
            file.unlink()
    receipt = {'status': 'PASS', 'source': PIN, 'requested_public_pin': PIN, 'build_mode': 'clean-source',
               'release': verified_release(hstage), 'config_sha256': sha(hstage / '.config'), 'helpers': helpers,
               'validation_scope': 'native helper ELF/config/source staging only; external module qualification is separate'}
    (headers / 'native-helper-receipt.json').write_text(json.dumps(receipt, indent=2) + '\n')
    shutil.copyfile(source / 'COPYING', headers / 'COPYING')
    archive(source / 'LICENSES', headers / 'LICENSES.tar', 'LICENSES')
    archive(hstage, headers / 'headers-stage.tar', 'stage')
    recipes = Path(__file__).resolve().parents[1] / 'recipes/kernel'
    ready_recipe(recipes / 'PKGBUILD', kernel)
    ready_recipe(recipes / 'headers/PKGBUILD', headers)
    print(json.dumps({'kernel': str(kernel), 'headers': str(headers), 'source': PIN, 'release': release}))


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ('source', 'build', 'output'):
        parser.add_argument(name, type=Path)
    args = parser.parse_args()
    stage(args.source, args.build, args.output)
