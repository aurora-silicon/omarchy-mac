#!/usr/bin/env python3
"""Seal the Neo installer's catalog to one OS image.

The catalog in RELEASE_DIR names one model. This points it at the engine, the
image package and the installer metadata published under --base-url, names
the DMG the build will publish there, raises the sequence, and signs the exact
bytes with the raw Ed25519 catalog key, checking the signature against the
release's trust root. The app built from RELEASE_DIR carries the pair as its sealed
catalog, so its download URLs are fixed for that build.
"""
import argparse
import datetime
import hashlib
import json
import time
from pathlib import Path

from cryptography.hazmat.primitives.asymmetric.ed25519 import (
    Ed25519PrivateKey,
    Ed25519PublicKey,
)


def digest(path):
    hasher = hashlib.sha256()
    with path.open('rb') as file:
        for block in iter(lambda: file.read(1 << 20), b''):
            hasher.update(block)
    return 'sha256:' + hasher.hexdigest()


def artifact(base_url, path):
    return {
        'sourceURL': f'{base_url}/{path.name}',
        'fileName': path.name,
        'sizeBytes': path.stat().st_size,
    }


parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
parser.add_argument('release_dir', type=Path, help='holds catalog.json and trust-root.ed25519.pub')
parser.add_argument('--key', type=Path, required=True, help='raw 32-byte Ed25519 catalog signing key')
parser.add_argument('--base-url', required=True, help='public folder the engine, image, metadata and DMG are published in')
parser.add_argument('--engine', type=Path, required=True, help='the engine the app pins, installer-<version>.tar.gz')
parser.add_argument('--image', type=Path, required=True, help='the OS image package (.zip)')
parser.add_argument('--metadata', type=Path, required=True, help='the installer_data JSON naming that package')
parser.add_argument('--build-number', required=True, help='the app build number; names the DMG')
parser.add_argument('--revision', required=True, help='the installer commit the app is built from')
parser.add_argument('--evidence', required=True, help='a name for this release, such as developer-neo-<flavor>-<date>')
args = parser.parse_args()

base_url = args.base_url.rstrip('/')
catalog_path = args.release_dir / 'catalog.json'
catalog = json.loads(catalog_path.read_text())
if len(catalog['models']) != 1:
    raise SystemExit('the Neo catalog names exactly one model')

now = int(time.time())
catalog['sequence'] = max(now, catalog['sequence'] + 1)
catalog['issuedAt'] = datetime.datetime.fromtimestamp(now, datetime.UTC).strftime('%Y-%m-%dT%H:%M:%SZ')
catalog['installer']['downloadURL'] = f'{base_url}/Omarchy-Installer-Neo-macOS27-{args.build_number}.dmg'
model = catalog['models'][0]
if not (args.engine.name.startswith('installer-') and args.engine.name.endswith('.tar.gz')):
    raise SystemExit('the engine is named installer-<version>.tar.gz')
model['engineVersion'] = args.engine.name[len('installer-'):-len('.tar.gz')]
model['engineDigest'] = digest(args.engine)
model['engineArtifact'] = artifact(base_url, args.engine)
model['downstreamRevision'] = args.revision
model['evidenceRevision'] = args.evidence
model['metadataDigest'] = digest(args.metadata)
model['payloadDigest'] = digest(args.image)
model['metadataArtifact'] = artifact(base_url, args.metadata)
model['payloadArtifact'] = artifact(base_url, args.image)

payload = (json.dumps(catalog, indent=2) + '\n').encode()
signature = Ed25519PrivateKey.from_private_bytes(args.key.read_bytes()).sign(payload)
trust_root = (args.release_dir / 'trust-root.ed25519.pub').read_bytes()
Ed25519PublicKey.from_public_bytes(trust_root).verify(signature, payload)
catalog_path.write_bytes(payload)
(args.release_dir / 'catalog.json.sig').write_bytes(signature)
print(f'sealed {catalog_path} to {model["payloadArtifact"]["sourceURL"]}')
