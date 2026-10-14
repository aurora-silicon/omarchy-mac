#!/usr/bin/python
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Ryan Murray <ryan@aurorasilicon.org>
"""Ordinary first-launch bootstrap from image-owned pinned offline inputs."""
import importlib.util
import hashlib
import fcntl
import json
import os
from pathlib import Path, PurePosixPath
import posixpath
import shutil
import subprocess
import sys
import tarfile
import tempfile

SHARE = Path('/usr/share/aurora-steam-native')
POLICY = SHARE / 'offline-policy.json'
LAUNCHER = SHARE / 'bin/steam-native4k'
PROTON_ARCHIVE = SHARE / 'offline/vendor/GE-Proton11-7-aarch64.tar.gz'
PROTON_SHA256 = 'b77ac906186568c2f3c66674b85c712b145ccf73ff2718a50dd7bf6248b67ba3'
VENDOR_NTDLL_SHA256 = '6ba770ec0df52311b760a0866226a83c177f67227598f990942382cad42b4bc3'
GUARD = Path('/usr/lib/aurora-proton-sve-guard/ntdll.so')
GUARD_POLICY = Path('/usr/share/doc/aurora-proton-sve-guard/source-receipt.json')
PROTON_NAME = 'Aurora-GE-Proton11-7-aarch64'
FEX_DEPOT = Path('/usr/lib/aurora-fex-steam')
RUNTIME_INPUTS = {
    'arm': ('SteamLinuxRuntime_4-arm64.tar.xz', 'caa4b3bc3aad1cac43d94dbd802a963c13ed63ea1c414f04669ae402af505adf'),
    'guest': ('com.valvesoftware.SteamRuntime.Platform-amd64,i386-steamrt4-runtime.tar.gz', 'f7facbf357c729435ecb17fa5dddac1f1c19bb36dc0101590a312023272d8ac0'),
}
GRAPHICS_INPUTS = {
    Path('/usr/share/fex-emu/RootFS/default.erofs'): 'e9cb49edfb3820113b3bb3ee8d887a8b58a299a066dd04652bc75ddecfd456d2',
}
GRAPHICS_POLICIES = {
    Path('/usr/share/fex-emu/overlays/mesa-x86_64.erofs'): 'x86_64',
    Path('/usr/share/fex-emu/overlays/mesa-i386.erofs'): 'i386',
}


def graphics_inputs():
    inputs = dict(GRAPHICS_INPUTS)
    for image, architecture in GRAPHICS_POLICIES.items():
        policy = json.loads(trusted_path(Path(str(image) + '.json')).read_text())
        contract = {'schema': 1, 'role': 'fex-guest-mesa-overlay',
                    'source_commit': '524105acd30b58c7581ae7e0a1920e5775f9f792',
                    'architecture': architecture,
                    'build_version': '26.3.0-devel.20261014.g524105a-arch2',
                    'image_path': str(image)}
        if any(policy.get(key) != value for key, value in contract.items()):
            raise ValueError('package-owned Mesa source/target policy mismatch')
        pin = policy.get('image_sha256', '')
        if len(pin) != 64 or any(c not in '0123456789abcdef' for c in pin):
            raise ValueError('invalid package-owned Mesa artifact pin')
        inputs[image] = pin
    return inputs


def runtime_filter(member, destination):
    """Confine absolute sysroot symlinks to that archive's files/ root."""
    if member.issym() and member.linkname.startswith('/'):
        parts = PurePosixPath(member.name).parts
        if 'files' not in parts:
            raise ValueError('absolute runtime link outside declared files/ root')
        prefix = PurePosixPath(*parts[:parts.index('files') + 1])
        target = prefix / member.linkname.lstrip('/')
        normalized = PurePosixPath(posixpath.normpath(str(target)))
        if not normalized.is_relative_to(prefix):
            raise ValueError('runtime link escapes declared files/ root')
        member = member.replace(linkname=posixpath.relpath(str(normalized), str(PurePosixPath(member.name).parent)))
    return tarfile.data_filter(member, destination)


def activate_runtime(tool, graphics):
    """Use the upstream PV emulator/graphics-provider depot contract."""
    trusted_path(FEX_DEPOT / 'emulator.json')
    runtime = tool / 'runtime'
    runtime.mkdir()
    for role, (name, pin) in RUNTIME_INPUTS.items():
        archive = trusted_path(SHARE / 'offline/vendor' / name)
        with archive.open('rb') as stream:
            if hashlib.file_digest(stream, 'sha256').hexdigest() != pin:
                raise ValueError('image-owned runtime archive hash mismatch: ' + role)
            stream.seek(0)
            destination = runtime / role
            destination.mkdir()
            with tarfile.open(fileobj=stream, mode='r:*') as tar:
                tar.extractall(destination, filter=runtime_filter)
    arm = runtime / 'arm/SteamLinuxRuntime_4-arm64'
    shutil.copyfile(arm / '_v2-entry-point', runtime / '_v2-entry-point')
    (runtime / '_v2-entry-point').chmod(0o755)
    (runtime / 'pressure-vessel').symlink_to('arm/SteamLinuxRuntime_4-arm64/pressure-vessel')
    # Adapt only the pinned generated run's runtime directory and architectures.
    # The original entrypoint and native pressure-vessel remain unchanged.
    run = (arm / 'run').read_text()
    if (run.count('dir=steamrt4_platform_4.0.20260805.254769') != 1
            or run.count('PRESSURE_VESSEL_ARCHITECTURES=aarch64-linux-gnu') != 1):
        raise ValueError('unexpected pinned runtime run contract')
    run = run.replace('dir=steamrt4_platform_4.0.20260805.254769', 'dir=guest')
    run = run.replace('PRESSURE_VESSEL_ARCHITECTURES=aarch64-linux-gnu', 'PRESSURE_VESSEL_ARCHITECTURES=x86_64-linux-gnu,i386-linux-gnu')
    (runtime / 'run').write_text(run)
    (runtime / 'run').chmod(0o755)
    graphics_root = tool / 'graphics'
    graphics_root.mkdir()
    for index, (image, pin) in enumerate(graphics.items()):
        trusted_path(image)
        if digest(image) != pin:
            raise ValueError('image-owned graphics RootFS hash mismatch')
        if index == 0:
            subprocess.run(['fsck.erofs', '--extract=' + str(graphics_root), str(image)], check=True)
            continue
        with tempfile.TemporaryDirectory(dir=tool) as temporary:
            overlay = Path(temporary)
            subprocess.run(['fsck.erofs', '--extract=' + str(overlay), str(image)], check=True)
            for path in sorted(overlay.rglob('*')):
                target = graphics_root / path.relative_to(overlay)
                if not target.parent.resolve().is_relative_to(graphics_root.resolve()):
                    raise ValueError('graphics overlay parent escapes its owned RootFS')
                if path.is_dir() and not path.is_symlink():
                    target.mkdir(parents=True, exist_ok=True)
                    continue
                if target.is_dir() and not target.is_symlink():
                    shutil.rmtree(target)
                elif target.exists() or target.is_symlink():
                    target.unlink()
                if path.is_symlink():
                    target.symlink_to(os.readlink(path))
                else:
                    shutil.copy2(path, target)
    provider = trusted_path(SHARE / 'graphics_provider.json')
    shutil.copyfile(provider, graphics_root / 'graphics_provider.json')
    (tool / 'fex').symlink_to(FEX_DEPOT)
    wrapper = tool / 'aurora-proton'
    wrapper.write_text('''#!/bin/bash
# SPDX-License-Identifier: MIT
# Copyright 2026 Ryan Murray <ryan@aurorasilicon.org>
set -euo pipefail
here=$(dirname -- "$(readlink -f -- "$0")")
verb=${1:?missing Proton verb}
shift
if [[ ${FEX_PORTABLE+set} && $FEX_PORTABLE != 1 ]]; then
  echo 'Aurora Proton requires FEX portable mode; preserving your incompatible setting' >&2
  exit 2
fi
export FEX_PORTABLE=1
export STEAM_COMPAT_MACHINE_ARCHITECTURE=${STEAM_COMPAT_MACHINE_ARCHITECTURE:-aarch64-linux-gnu}
export STEAM_COMPAT_EMULATOR=${STEAM_COMPAT_EMULATOR:-$here/fex/emulator.json}
export STEAM_COMPAT_GRAPHICS_PROVIDER=${STEAM_COMPAT_GRAPHICS_PROVIDER:-$here/graphics/graphics_provider.json}
exec "$here/runtime/_v2-entry-point" --verb="$verb" -- "$here/proton" "$verb" "$@"
''')
    wrapper.chmod(0o755)
    manifest = tool / 'toolmanifest.vdf'
    text = manifest.read_text()
    if text.count('"require_tool_appid" "4185400"') != 1 or text.count('"/proton %verb%"') != 1:
        raise ValueError('unexpected pinned Proton runtime dependency')
    text = text.replace('"require_tool_appid" "4185400"', '')
    manifest.write_text(text.replace('"/proton %verb%"', '"/aurora-proton %verb%"'))


def digest(file):
    with file.open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()


def guard_policy():
    policy = json.loads(trusted_path(GUARD_POLICY).read_text())
    contract = {
        'schema': 1, 'role': 'ge-proton-native-ntdll-sve-guard',
        'target': 'GE-Proton11-7-aarch64',
        'ge_public_commit': 'c191f35dcebbeccfacd3b4c6f6eea026e588c1c2',
        'wine_public_commit': '46b29104e3741fe23bf5e2547196a253aab88c89',
        'staging_public_commit': '6cc805ea57132eeaf44764e9213823c9b8d0d300',
        'public_guard_commit': 'a1b375b287fe6db4d2e95beb9d945af15b3ef9db',
        'guard_patch_sha256': 'db9da41be4dda3cb89cfec3d6ad7360a7260de023a3007048542202ab57106fe',
        'vendor_sha256': VENDOR_NTDLL_SHA256,
        'vk_xml_sha256': '264d0d7350e37d70c82407fb430d085040fc01a9a961d43dec8c2d6ed1dfd183',
        'video_xml_sha256': 'd018b914014c06605e367a3b929670511e6f6de2f225c405a8b5e2d912408b76',
    }
    if any(policy.get(key) != value for key, value in contract.items()):
        raise ValueError('package-owned guard source/target policy mismatch')
    pin = policy.get('new_sha256', '')
    if len(pin) != 64 or any(c not in '0123456789abcdef' for c in pin):
        raise ValueError('invalid package-owned guard artifact pin')
    return pin


def install_proton(root):
    """Add a guarded compatibility tool without changing Steam user choices."""
    archive = trusted_path(PROTON_ARCHIVE)
    guard = trusted_path(GUARD)
    guard_sha256 = guard_policy()
    graphics = graphics_inputs()
    if digest(guard) != guard_sha256:
        raise ValueError('package-owned Proton guard hash mismatch')
    tools = root / 'compatibilitytools.d'
    tools.mkdir(parents=True, exist_ok=True)
    target = tools / PROTON_NAME
    expected = {'activation_schema': 2, 'archive_sha256': PROTON_SHA256, 'guard_sha256': guard_sha256,
                'runtime_inputs': RUNTIME_INPUTS,
                'graphics_inputs': {str(path): pin for path, pin in graphics.items()},
                'fex_source_commit': '14c92681f4d62cf84d901460e0358de09c8847a7'}
    expected = json.loads(json.dumps(expected))
    with (tools / '.aurora-proton.lock').open('a') as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        if target.exists() or target.is_symlink():
            marker = target / 'aurora-source.json'
            if (target.is_symlink() or not marker.is_file()
                    or json.loads(marker.read_text()) != expected
                    or digest(target / 'files/lib/wine/aarch64-unix/ntdll.so') != guard_sha256):
                raise ValueError('existing Aurora Proton tool differs; preserving user state')
            return target
        # Validate the exact archive through the same descriptor used to unpack.
        with archive.open('rb') as stream:
            if hashlib.file_digest(stream, 'sha256').hexdigest() != PROTON_SHA256:
                raise ValueError('image-owned Proton archive hash mismatch')
            stream.seek(0)
            with tempfile.TemporaryDirectory(prefix='.aurora-proton-', dir=tools) as temporary:
                stage = Path(temporary)
                with tarfile.open(fileobj=stream, mode='r:gz') as tar:
                    members = tar.getmembers()
                    if any(member.name.split('/')[0] != 'GE-Proton11-7-aarch64' for member in members):
                        raise ValueError('unexpected Proton archive root')
                    tar.extractall(stage, members=members, filter='data')
                tool = stage / 'GE-Proton11-7-aarch64'
                ntdll = tool / 'files/lib/wine/aarch64-unix/ntdll.so'
                if ntdll.is_symlink() or digest(ntdll) != VENDOR_NTDLL_SHA256:
                    raise ValueError('Proton vendor ntdll identity mismatch')
                shutil.copyfile(guard, ntdll)
                manifest = tool / 'compatibilitytool.vdf'
                text = manifest.read_text()
                if text.count('"GE-Proton11-7-aarch64"') != 2:
                    raise ValueError('unexpected Proton compatibility tool manifest')
                manifest.write_text(text.replace('"GE-Proton11-7-aarch64"', '"' + PROTON_NAME + '"'))
                activate_runtime(tool, graphics)
                (tool / 'aurora-source.json').write_text(json.dumps(expected, sort_keys=True) + '\n')
                tool.rename(target)
    return target


def trusted_path(path):
    """Image inputs and their parents must be root-owned and non-writable."""
    path = Path(path)
    if not path.is_absolute():
        raise ValueError('offline policy paths must be absolute')
    for component in (path, *path.parents):
        info = component.lstat()
        if component.is_symlink() or info.st_uid != 0 or info.st_mode & 0o022:
            raise ValueError(f'untrusted image input: {component}')
    return path


def bootstrap(home, policy_path=POLICY):
    trusted_path(policy_path)
    policy = json.loads(policy_path.read_text())
    manifest = trusted_path(policy['manifest'])
    cache = trusted_path(policy['archives'])
    # This pin is package-owned policy, independently supplied by the reviewed
    # vendor receipt. Never derive the trust anchor from cache bytes.
    pin = policy['manifest_sha256']
    if len(pin) != 64 or any(c not in '0123456789abcdef' for c in pin):
        raise ValueError('invalid package-owned manifest pin')
    spec = importlib.util.spec_from_file_location('steam_installer', SHARE / 'install-steam-arm64.py')
    installer = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(installer)
    entries = installer.offline_entries(installer.offline_manifest(manifest, pin))
    for entry in entries:
        trusted_path(cache / entry['file'])
    root = home / '.local/share/Steam-ARM64'
    # The public helper verifies and snapshots every archive before extraction.
    # It refuses existing state and has no network fallback in offline mode.
    installer.install_client(root, cache, offline=True, manifest_path=manifest, manifest_sha256=pin)
    installer.install_launcher(root, home / '.local', home)
    return root


def main(argv=None):
    if os.geteuid() == 0:
        raise SystemExit('Start Steam as the desktop user, not root')
    args = sys.argv[1:] if argv is None else argv
    home = Path.home()
    explicit_root = os.environ.get('AURORA_STEAM_ROOT')
    root = Path(explicit_root) if explicit_root else (home / '.steam/root').resolve()
    if not explicit_root and not (root / 'steamrtarm64/steam').is_file():
        try:
            root = bootstrap(home)
        except (OSError, ValueError, KeyError) as error:
            raise SystemExit(f'Offline Steam bootstrap refused: {error}') from error
        os.environ['AURORA_STEAM_ROOT'] = str(root)
    try:
        install_proton(root)
    except (OSError, ValueError, KeyError, tarfile.TarError, subprocess.CalledProcessError) as error:
        raise SystemExit(f'Offline Proton activation refused: {error}') from error
    # The exact public launcher retains all arguments and graphics/session
    # policy. Tests replace execv; package installation never calls this code.
    os.execv(str(LAUNCHER), [str(LAUNCHER), *args])


if __name__ == '__main__':
    main()
