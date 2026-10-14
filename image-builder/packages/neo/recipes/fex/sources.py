#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""Public pinned FEX inputs, build-only sysroot and optional admitted reuse."""
import argparse
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import shutil
import subprocess
import urllib.request


def sha(path):
    with Path(path).open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()


def relative(value):
    if not value:
        raise ValueError('empty input path')
    path = PurePosixPath(value)
    if path.is_absolute() or any(part in ('', '..') for part in path.parts):
        raise ValueError('unsafe input path')
    return path


def verify_checkout(root, record):
    root = Path(root)
    for expression, expected in [('HEAD', record['commit']), ('HEAD^{tree}', record['tree'])]:
        actual = subprocess.check_output(['git', '-C', str(root), 'rev-parse', expression], text=True).strip()
        if actual != expected:
            raise ValueError('public source identity mismatch: ' + str(root))
    if subprocess.check_output(['git', '-C', str(root), 'status', '--porcelain', '--untracked-files=all', '--ignored=matching'], text=True).strip():
        raise ValueError('modified public source: ' + str(root))


def fetch(lock, root):
    records = json.loads(Path(lock).read_text())
    verify_checkout(root, records[0])
    # Each gitlink's checked commit and tree must agree with the published lock.
    for item in sorted(records[1:], key=lambda row: len(PurePosixPath(row['path']).parts)):
        child = relative(item['path'])
        parents = [record for record in records if record['path'] == '.'
                   or child.is_relative_to(PurePosixPath(record['path'])) and record['path'] != item['path']]
        parent = max(parents, key=lambda row: len(PurePosixPath(row['path']).parts))
        parent_path = Path(root) / relative(parent['path'])
        local = child if parent['path'] == '.' else child.relative_to(PurePosixPath(parent['path']))
        subprocess.run(['git', '-C', str(parent_path), 'submodule', 'update', '--init', '--', str(local)], check=True)
        verify_checkout(Path(root) / child, item)


def verify_reuse(archive, lock):
    record = json.loads(Path(lock).read_text())
    if not (record.get('publication_url') or '').startswith('https://'):
        raise ValueError('reuse artifact has no qualified immutable public URL yet')
    if sha(archive) != record['archive_sha256']:
        raise ValueError('reuse archive differs from reviewed public artifact')
    if record['source_commit'] != '14c92681f4d62cf84d901460e0358de09c8847a7':
        raise ValueError('wrong FEX reuse source')
    return record


def sysroot(lock, destination, cache):
    destination, cache = Path(destination), Path(cache)
    if destination.exists():
        raise ValueError('sysroot output already exists')
    records = json.loads(Path(lock).read_text())
    cache.mkdir(parents=True, exist_ok=True)
    destination.mkdir()
    for item in records:
        name = str(relative(item['filename']))
        if '/' in name or not item['url'].startswith('https://kojipkgs.fedoraproject.org/') or '/data/signed/f577861e/' not in item['url']:
            raise ValueError('unsupported development RPM origin')
        package = cache / name
        if not package.exists():
            with urllib.request.urlopen(item['url']) as response, package.open('xb') as stream:
                shutil.copyfileobj(response, stream)
        if sha(package) != item['sha256']:
            raise ValueError('development RPM hash mismatch: ' + name)
        for member in subprocess.check_output(['bsdtar', '-tf', str(package)], text=True).splitlines():
            relative(member.removeprefix('./'))
        subprocess.run(['bsdtar', '-xpf', str(package), '-C', str(destination), '--no-same-owner', '--safe-writes'], check=True)
        # Prevent absolute guest links from selecting native host files.
        for link in destination.rglob('*'):
            if link.is_symlink() and os.readlink(link).startswith('/'):
                target = destination / os.readlink(link).lstrip('/')
                link.unlink()
                link.symlink_to(os.path.relpath(target, link.parent))
    for required in ['usr/include/c++/16', 'usr/lib64', 'usr/lib']:
        if not (destination / required).exists():
            raise ValueError('incomplete dual-ABI development sysroot')
    (destination / 'public-rpm-inputs.json').write_text(json.dumps(records, sort_keys=True, indent=2) + '\n')


def notices(lock, source, destination):
    source, destination = Path(source), Path(destination)
    for item in json.loads(Path(lock).read_text()):
        repository = relative(item['repository_path'])
        path = relative(item['path'])
        data = subprocess.check_output(['git', '-C', str(source / repository), 'show', 'HEAD:' + str(path)])
        if hashlib.sha256(data).hexdigest() != item['sha256']:
            raise ValueError('license notice identity mismatch: ' + str(repository / path))
        target = destination / repository / path
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_bytes(data)
    # This pinned SoftFloat tree embeds its BSD notice in source headers, not
    # a COPYING file. Preserve every distinct initial redistribution notice.
    files = subprocess.check_output(['git', '-C', str(source), 'ls-files', 'External/SoftFloat-3e'], text=True).splitlines()
    notices = {}
    for path in files:
        data = subprocess.check_output(['git', '-C', str(source), 'show', 'HEAD:' + path])
        begin = data.find(b'/*')
        end = data.find(b'*/', begin)
        if begin >= 0 and end >= 0:
            block = data[begin:end + 2]
            if b'Redistribution and use' in block and b'Copyright' in block:
                notices[hashlib.sha256(block).hexdigest()] = block
    if not notices:
        raise ValueError('pinned SoftFloat redistribution notices are missing')
    target = destination / 'External/SoftFloat-3e'
    target.mkdir(parents=True, exist_ok=True)
    for digest, data in notices.items():
        (target / ('NOTICE-' + digest[:16] + '.txt')).write_bytes(data)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('mode', choices=['fetch', 'sysroot', 'verify-reuse', 'notices'])
    parser.add_argument('lock', type=Path)
    parser.add_argument('path', type=Path)
    parser.add_argument('--output', type=Path)
    parser.add_argument('--cache', type=Path)
    args = parser.parse_args()
    if args.mode == 'fetch':
        fetch(args.lock, args.path)
    elif args.mode == 'verify-reuse':
        verify_reuse(args.path, args.lock)
    elif args.mode == 'notices':
        notices(args.lock, args.path, args.output)
    else:
        sysroot(args.lock, args.path, args.cache)


if __name__ == '__main__':
    main()
