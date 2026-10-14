#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# Copyright 2026 Ryan Murray <ryan@aurorasilicon.org>
"""Fetch public inputs, then prepare/build a new owned source tree offline."""
import argparse
import hashlib
import json
from pathlib import Path
import re
import shutil
import subprocess
import urllib.request

HERE = Path(__file__).resolve().parent
GE = 'c191f35dcebbeccfacd3b4c6f6eea026e588c1c2'
WINE = '46b29104e3741fe23bf5e2547196a253aab88c89'
STAGING = '6cc805ea57132eeaf44764e9213823c9b8d0d300'
WINEOPENXR_TREE = '146b3ba2857a16cc8e0acfe7cda4a181f557b658'
INPUTS = {
    'guard.patch': ('https://raw.githubusercontent.com/aurora-silicon/aurora-steam-native/a1b375b287fe6db4d2e95beb9d945af15b3ef9db/proton/wine-arm64-sve-payload-guard.patch', 'db9da41be4dda3cb89cfec3d6ad7360a7260de023a3007048542202ab57106fe'),
    'vk.xml': ('https://raw.githubusercontent.com/KhronosGroup/Vulkan-Docs/v1.4.357/xml/vk.xml', '264d0d7350e37d70c82407fb430d085040fc01a9a961d43dec8c2d6ed1dfd183'),
    'video.xml': ('https://raw.githubusercontent.com/KhronosGroup/Vulkan-Docs/v1.4.357/xml/video.xml', 'd018b914014c06605e367a3b929670511e6f6de2f225c405a8b5e2d912408b76'),
}


def run(*args, cwd=None):
    subprocess.run(args, cwd=cwd, check=True)


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def verify_inputs(work):
    openxr = subprocess.check_output(['git', '-C', str(work / 'ge'), 'rev-parse', 'HEAD:wineopenxr'], text=True).strip()
    if openxr != WINEOPENXR_TREE or not (work / 'ge/wineopenxr').is_dir():
        raise ValueError('tracked public wineopenxr source tree mismatch')
    for name, (_, expected) in INPUTS.items():
        if digest(work / 'inputs' / name) != expected:
            raise ValueError('public input identity mismatch: ' + name)
    for directory, expected in [('ge', GE), ('ge/wine', WINE), ('ge/wine-staging', STAGING)]:
        source = work / directory
        actual = subprocess.check_output(['git', '-C', str(source), 'rev-parse', 'HEAD'], text=True).strip()
        if actual != expected:
            raise ValueError('public source identity mismatch: ' + directory)
        dirty = subprocess.check_output(['git', '-C', str(source), 'status', '--porcelain', '--untracked-files=all', '--ignored'], text=True)
        if dirty:
            raise ValueError('modified public build inputs: ' + directory)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('mode', choices=['fetch', 'build'])
    parser.add_argument('work', type=Path)
    args = parser.parse_args()
    work = args.work.resolve()
    if args.mode == 'fetch':
        # Fetch owns a new directory; no operator source checkout is reset.
        work.mkdir(parents=True, exist_ok=False)
        run('git', 'clone', '--filter=blob:none', '--no-checkout', 'https://github.com/GloriousEggroll/proton-ge-custom.git', str(work / 'ge'))
        run('git', 'checkout', '--detach', GE, cwd=work / 'ge')
        run('git', 'submodule', 'update', '--init', 'wine', 'wine-staging', cwd=work / 'ge')
        run('git', 'fetch', 'origin', 'e813ca5771658b00875924ab88d525322e50d39f', cwd=work / 'ge/wine')
        (work / 'inputs').mkdir()
        for name, (url, _) in INPUTS.items():
            urllib.request.urlretrieve(url, work / 'inputs' / name)
        verify_inputs(work)
        return
    verify_inputs(work)
    if (work / 'source').exists() or (work / 'build').exists():
        raise ValueError('build requires new owned source/build output paths')
    # Public GE preparation intentionally modifies its owned Wine checkout.
    # Verify the distributed adapter matches the public GE Wine section.
    upstream = (work / 'ge/patches/protonprep-valve-staging.sh').read_text()
    adapter = (HERE / 'prepare-wine-only.sh').read_text()
    section = upstream[upstream.index('### (2) WINE PATCHING ###'):upstream.index('### END WINE PATCHING ###') + len('### END WINE PATCHING ###')]
    if section.strip() not in adapter:
        raise ValueError('Wine preparation adapter differs from pinned public GE section')
    run('bash', str(HERE / 'prepare-wine-only.sh'), cwd=work / 'ge')
    shutil.copytree(work / 'ge/wine', work / 'source')
    source = work / 'source'
    with (work / 'inputs/guard.patch').open('rb') as patch:
        subprocess.run(['patch', '-Np1'], cwd=source, stdin=patch, check=True)
    run('python3', 'dlls/winevulkan/make_vulkan', '-x', str(work / 'inputs/vk.xml'), '-X', str(work / 'inputs/video.xml'), cwd=source)
    run('perl', 'tools/make_specfiles', cwd=source)
    build = work / 'build'
    build.mkdir()
    run(str(source / 'configure'), '--host=aarch64-linux-gnu', '--enable-win64', '--disable-tests', '--without-x', '--without-wayland', '--without-freetype', cwd=build)
    run('make', '-j', __import__('os').environ.get('OMARCHY_BUILD_JOBS', '10'), 'dlls/ntdll/ntdll.so', cwd=build)
    package = work / 'package'
    package.mkdir()
    for original, name in [(build / 'dlls/ntdll/ntdll.so', 'ntdll.so'), (source / 'COPYING.LIB', 'COPYING.LIB')]:
        shutil.copyfile(original, package / name)
    receipt = {'schema': 1, 'role': 'ge-proton-native-ntdll-sve-guard', 'target': 'GE-Proton11-7-aarch64',
               'ge_public_commit': GE, 'wine_public_commit': WINE, 'staging_public_commit': STAGING,
               'public_guard_commit': 'a1b375b287fe6db4d2e95beb9d945af15b3ef9db',
               'vendor_sha256': '6ba770ec0df52311b760a0866226a83c177f67227598f990942382cad42b4bc3',
               'guard_patch_sha256': INPUTS['guard.patch'][1],
               'vk_xml_sha256': INPUTS['vk.xml'][1], 'video_xml_sha256': INPUTS['video.xml'][1],
               'public_inputs': {name: {'url': url, 'sha256': sha} for name, (url, sha) in INPUTS.items()},
               'new_sha256': digest(package / 'ntdll.so'), 'wine_or_game_execution': False}
    (package / 'source-receipt.json').write_text(json.dumps(receipt, indent=2) + '\n')
    recipe = (HERE / 'PKGBUILD').read_text()
    sums = 'sha256sums=(' + ' '.join(digest(package / name) for name in ['ntdll.so', 'COPYING.LIB', 'source-receipt.json']) + ')'
    recipe = re.sub(r'sha256sums=\([^)]*\)', sums, recipe)
    (package / 'PKGBUILD').write_text(recipe)


if __name__ == '__main__':
    main()
