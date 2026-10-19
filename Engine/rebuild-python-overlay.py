#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""Repack the authenticated deployed engine with a Python overlay.

The overlay is Python and data only. The engine's native code stays exactly
the authenticated base runtime (runtime-macho.json); the Swift restore-image
helper ships signed in the app bundle instead, where notarization accepts it.
"""
import argparse
import copy
import difflib
import gzip
import hashlib
import importlib.util
import io
import json
from pathlib import Path
import subprocess
import tarfile
import tempfile

BASE_SHA256 = '0cf1aa87760f90a545298b7cef737c9b497f2cad421d79ac59f557a81f2eb146'
BASE_SOURCE_COMMIT = '652c36254b12309d661dd4c427d616255f184f61'
BOOTSTRAP_MEMBERS = {
    'main.py': 'd7fb4fcc9bdc13cba5a9f9c9ecace6317c60d816915950d9dfa05f826737afbd',
    'asahi_firmware/bluetooth.py': 'aa12e6cd684ed5b55d732db1f040d84570537bacc991d03ee6f854cbb232c369',
}
BASE_COMMIT = 'f0469cea0899f3efed8efead604174c7a53c4451'

_SPEC = importlib.util.spec_from_file_location(
    'verify_source_lock', Path(__file__).resolve().parent / 'verify-source-lock.py')
VERIFY = importlib.util.module_from_spec(_SPEC)
_SPEC.loader.exec_module(VERIFY)
_SPEC = importlib.util.spec_from_file_location(
    'verify_engine_macho', Path(__file__).resolve().parent / 'verify-engine-macho.py')
MACHO = importlib.util.module_from_spec(_SPEC)
_SPEC.loader.exec_module(MACHO)


def sha256(data):
    return hashlib.sha256(data).hexdigest()


def git(directory, *arguments):
    return subprocess.run(['git', '-C', str(directory), *arguments],
                          check=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE).stdout


def archive_name(path):
    # build.sh flattens src/ into the package root; other Python packages keep their directory.
    return path.removeprefix('src/')


def apply_downstream_patch(patch, path, content):
    with tempfile.TemporaryDirectory() as scratch:
        target = Path(scratch) / path
        target.parent.mkdir(parents=True)
        target.write_bytes(content)
        git(scratch, 'init', '-q')
        try:
            git(scratch, 'apply', '--whitespace=nowarn', '--include=' + path, str(patch.resolve()))
        except subprocess.CalledProcessError as error:
            raise ValueError('downstream patch does not apply: ' + path) from error
        return target.read_bytes()


def upstream_delta(checkout, delta, archive, patch, base_patch, base_members=None):
    # The base keeps its native runtime and m1n1, so upstream may only have changed the listed Python files.
    VERIFY.require_upstream_delta(delta, patch.read_text(), base_patch.read_text())
    changed = git(checkout, 'diff', '--name-only', delta['base_commit'], 'HEAD').decode().splitlines()
    if sorted(changed) != sorted(item['path'] for item in delta['files']):
        raise ValueError('upstream changes since the base differ from the source lock')
    overlay = {}
    for item in delta['files']:
        path = item['path']
        base = git(checkout, 'show', delta['base_commit'] + ':' + path)
        new = git(checkout, 'show', 'HEAD:' + path)
        if sha256(base) != item['upstream_base_sha256'] or sha256(new) != item['upstream_sha256']:
            raise ValueError('upstream delta digest mismatch: ' + path)
        if item['downstream_patched']:
            # The base was built with the patch of its day; rebuilding it with that exact patch must
            # still reproduce what it shipped, while the new file takes the current patch.
            base = apply_downstream_patch(base_patch, path, base)
            new = apply_downstream_patch(patch, path, new)
            if sha256(base) != item['base_sha256'] or sha256(new) != item['sha256']:
                raise ValueError('patched upstream delta digest mismatch: ' + path)
        name = archive_name(path)
        try:
            shipped = archive.extractfile('./' + name).read()
        except KeyError as error:
            raise ValueError('base engine does not ship upstream file: ' + path) from error
        expected_base = item['base_sha256'] if base_members is None else base_members.get(name)
        if sha256(shipped) != expected_base:
            raise ValueError('base engine differs from the upstream base: ' + path)
        overlay[name] = new
    return overlay


def require_base(data, lock):
    if sha256(data) != BASE_SHA256:
        raise ValueError('base must be the exact published omarchy.28 engine')
    # Keep the original upstream delta proof while authenticating the published
    # bootstrap and the installer commit that produced it.
    build = lock['incremental_build']
    if (build['base_sha256'] != BASE_SHA256
            or build['base_source_commit'] != BASE_SOURCE_COMMIT
            or build['upstream_delta']['base_commit'] != BASE_COMMIT):
        raise ValueError('source lock names a different base than the published omarchy.28 engine')


def canonical_member(member):
    # Older Python writes zero in the fallback ustar timestamp when a PAX
    # mtime is present; newer Python writes its integer part. Use one exact
    # representation on every build host, preserving all payload bytes/modes.
    member = copy.copy(member)
    member.pax_headers = dict(member.pax_headers)
    member.mtime = int(member.mtime)
    member.pax_headers.pop('mtime', None)
    return member


def rebuild(checkout, base, output):
    root = Path(__file__).resolve().parent
    data = base.read_bytes()
    lock = json.loads((root / 'source-lock.json').read_text())
    require_base(data, lock)
    VERIFY.verify_upstream(root, lock, checkout)
    records = lock['downstream_overlay']['files']
    expected = {item['path'] for item in records if item['destination'].startswith('src/')}
    actual = {str(p.relative_to(root)) for p in (root / 'overlay/src').glob('*.py')}
    if expected != actual:
        raise ValueError('Python overlay inventory differs from source lock')
    base_patch = lock['incremental_build']['base_patch']
    for item in records + lock['build_recipe'] + [lock['downstream_overlay']['patch'], base_patch]:
        if sha256((root / item['path']).read_bytes()) != item['sha256']:
            raise ValueError('source lock digest mismatch: ' + item['path'])
    overlay = {Path(name).name: (root / name).read_bytes() for name in sorted(expected)}
    # Executables are the app's to sign: notarization rejects native code the
    # release signing cannot reach, and the engine archive is byte-pinned.
    if any(item['destination'].startswith('bin/') for item in records) or (root / 'overlay/bin').exists():
        raise ValueError('the engine overlay ships no tools; the app bundles its helpers')
    for item in records:
        if MACHO.is_macho((root / item['path']).read_bytes()):
            raise ValueError('the engine overlay carries native code: ' + item['path'])
    # The name is the lock's; Engine/engine_pin.py chooses it.
    overlay['engine-capabilities.json'] = b'{"schema":1,"nativeRecoveryInput":"helper-template-v1"}\n'
    overlay['version.tag'] = (lock['downstream_overlay']['version'] + '\n').encode()
    with tarfile.open(fileobj=io.BytesIO(data), mode='r:gz') as archive:
        # The engine carries its own installer metadata; the per-payload copy in the repository is a different file.
        if sha256(archive.extractfile('./installer_data.json').read()) != lock['validation_artifact']['metadata_sha256']:
            raise ValueError('base engine metadata differs from the source lock')
        delta = upstream_delta(checkout, lock['incremental_build']['upstream_delta'], archive,
                               root / lock['downstream_overlay']['patch']['path'],
                               root / base_patch['path'], BOOTSTRAP_MEMBERS)
        # The hook below rewrites the base archive's osinstall.py, so an upstream osinstall.py change would be lost.
        if delta.keys() & (overlay.keys() | {'osinstall.py'}):
            raise ValueError('upstream delta overlaps the downstream overlay or osinstall hook')
        overlay.update(delta)
        # The published bootstrap already includes these hooks. Recreate them
        # from the locked upstream and current patch rather than replaying an
        # old replacement against an already patched image.
        for source in ('src/osinstall.py', 'src/osenum.py'):
            original = git(checkout, 'show', 'HEAD:' + source)
            patched = apply_downstream_patch(root / lock['downstream_overlay']['patch']['path'], source, original)
            name = archive_name(source)
            if archive.extractfile('./' + name).read() != patched:
                raise ValueError('bootstrap hook differs from the locked source patch: ' + source)
            overlay[name] = patched
        output.parent.mkdir(parents=True, exist_ok=True)
        with output.open('xb') as raw, gzip.GzipFile(filename='', mode='wb', fileobj=raw, mtime=0, compresslevel=9) as gz:
            with tarfile.open(fileobj=gz, mode='w|', format=tarfile.PAX_FORMAT) as result:
                for member in archive.getmembers():
                    name = member.name.removeprefix('./')
                    if name in overlay or (name.startswith('._') and name[2:] in overlay):
                        continue
                    if '__pycache__' in name and any(Path(p).stem in name for p in overlay):
                        continue
                    result.addfile(canonical_member(member), archive.extractfile(member) if member.isfile() else None)
                for name, content in sorted(overlay.items()):
                    member = tarfile.TarInfo('./' + name)
                    member.mode = 0o644
                    member.mtime = 1786436181
                    member.size = len(content)
                    result.addfile(member, io.BytesIO(content))
    findings = MACHO.verify(output)
    if findings:
        output.unlink()
        raise ValueError('engine native code differs from the authenticated runtime: ' + '; '.join(findings))
    artifact = output.read_bytes()
    print(json.dumps({'file': str(output), 'size': len(artifact),
                      'sha256': sha256(artifact),
                      'base_sha256': BASE_SHA256}, sort_keys=True))


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('checkout', type=Path, help='asahi-installer checkout at the locked commit')
    parser.add_argument('base', type=Path)
    parser.add_argument('output', type=Path)
    args = parser.parse_args()
    rebuild(args.checkout.resolve(), args.base, args.output)
