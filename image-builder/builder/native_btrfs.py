#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Ryan Murray
"""Freeze an explicitly pinned build-host Btrfs tool; never a target package."""
import argparse
import hashlib
import json
from pathlib import Path
import re
import shutil


def digest(path):
    with path.open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()


def validate(directory, expected):
    receipt = directory / 'receipt.json'
    if directory.is_symlink() or not directory.is_dir() or receipt.is_symlink() or not receipt.is_file():
        raise ValueError('unsafe native Btrfs directory/receipt')
    if receipt.stat().st_size > 1024 * 1024:
        raise ValueError('native Btrfs receipt is too large')
    if not re.fullmatch('[0-9a-f]{64}', expected) or digest(receipt) != expected:
        raise ValueError('native Btrfs receipt changed')
    data = json.loads(receipt.read_text())
    if set(data) != {'schema', 'version', 'files'} or data['schema'] != 1:
        raise ValueError('wrong native Btrfs receipt schema')
    if not isinstance(data['version'], str) or not data['version'].startswith('btrfs-progs v'):
        raise ValueError('missing native Btrfs version')
    files = data['files']
    if not isinstance(files, dict) or not 2 <= len(files) <= 32 or not {'btrfs', 'ld-linux-x86-64.so.2'} <= files.keys():
        raise ValueError('incomplete native Btrfs tool closure')
    total = 0
    for name, sha in files.items():
        if not re.fullmatch('[A-Za-z0-9_.+-]+', name) or name in {'.', '..'}:
            raise ValueError('unsafe native Btrfs file name')
        path = directory / name
        if path.stat().st_size > 64 * 1024 * 1024:
            raise ValueError('native Btrfs file is too large')
        if path.is_symlink() or not path.is_file() or not isinstance(sha, str) or digest(path) != sha:
            raise ValueError('native Btrfs file changed: ' + name)
        with path.open('rb') as stream:
            header = stream.read(20)
        if header[:6] != b'\x7fELF\x02\x01' or header[18:20] != b'\x3e\x00':
            raise ValueError('native Btrfs closure must be Linux x86_64 ELF')
        total += path.stat().st_size
    if total > 64 * 1024 * 1024:
        raise ValueError('native Btrfs tool closure is too large')
    return data


def freeze(source, destination, expected):
    data = validate(source, expected)
    destination.mkdir()
    for name in ['receipt.json', *data['files']]:
        shutil.copyfile(source / name, destination / name)
        (destination / name).chmod(0o500 if name in {'btrfs', 'snapper', 'ld-linux-x86-64.so.2'} else 0o400)
    validate(destination, expected)
    wrappers = destination / 'bin'
    wrappers.mkdir(mode=0o700)
    for tool in ('btrfs', 'snapper'):
        if tool not in data['files']:
            continue
        wrapper = wrappers / tool
        wrapper.write_text('#!/bin/bash\n'
                           'if [[ "$0" == /native-btrfs/bin/* ]]; then\n'
                           '  tool_root=/native-btrfs\n'
                           'else\n'
                           '  tool_root=/run/omarchy-builder/native-btrfs\n'
                           'fi\n'
                           'exec "$tool_root/ld-linux-x86-64.so.2" --library-path "$tool_root" '
                           f'"$tool_root/{tool}" "$@"\n')
        wrapper.chmod(0o500)
    if 'snapper' in data['files']:
        launcher = wrappers / 'snapper-leaf'
        launcher.write_text('#!/bin/bash\nset -euo pipefail\n'
                            'exec unshare --mount --fork /bin/bash '
                            '/run/omarchy-builder/native-btrfs/bin/snapper-leaf-run\n')
        runner = wrappers / 'snapper-leaf-run'
        runner.write_text('#!/bin/bash\nset -euo pipefail\n'
                          'mount --make-rprivate /\n'
                          'for tool in btrfs snapper; do\n'
                          '  mount --bind "/run/omarchy-builder/native-btrfs/bin/$tool" "/usr/bin/$tool"\n'
                          '  mount -o remount,bind,ro,exec,nosuid,nodev "/usr/bin/$tool"\n'
                          'done\n'
                          'exec /bin/bash /run/omarchy-builder/original-snapper.sh\n')
        launcher.chmod(0o500)
        runner.chmod(0o500)
    wrappers.chmod(0o500)
    destination.chmod(0o500)


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('directory', type=Path)
    parser.add_argument('--sha256', required=True)
    parser.add_argument('--output', type=Path)
    args = parser.parse_args()
    try:
        if args.output:
            freeze(args.directory, args.output, args.sha256)
        else:
            validate(args.directory, args.sha256)
    except (ValueError, OSError) as error:
        parser.exit(1, str(error) + '\n')
