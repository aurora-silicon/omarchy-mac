#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""Materialize a published component's immutable, checksum-pinned reuse inputs."""
import argparse
import hashlib
import json
from pathlib import Path
import shutil
import urllib.request


def digest(path):
    with path.open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()


def fetch(record, root):
    root = Path(root)
    planned = []
    # Validate the complete public contract before accepting even a cache hit.
    for asset in record['assets']:
        name = asset['name']
        if Path(name).name != name or name in ('', '.', '..'):
            raise ValueError('unsafe asset name')
        directory = Path(asset.get('directory', ''))
        if directory.is_absolute() or '..' in directory.parts:
            raise ValueError('unsafe asset directory')
        url = asset.get('url')
        if not url or not url.startswith('https://'):
            raise ValueError('publisher must qualify an immutable public URL for ' + name)
        planned.append((asset, root / directory / name, url))
    for asset, target, url in planned:
        target.parent.mkdir(parents=True, exist_ok=True)
        if target.exists():
            if target.is_symlink() or digest(target) != asset['sha256']:
                raise ValueError('existing asset differs from public lock: ' + asset['name'])
            continue
        with urllib.request.urlopen(url) as response, target.open('xb') as stream:
            shutil.copyfileobj(response, stream)
        if digest(target) != asset['sha256']:
            target.unlink()
            raise ValueError('public asset checksum mismatch: ' + asset['name'])


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('ledger', type=Path)
    parser.add_argument('component')
    parser.add_argument('output', type=Path)
    args = parser.parse_args()
    fetch(json.loads(args.ledger.read_text())['components'][args.component], args.output)
