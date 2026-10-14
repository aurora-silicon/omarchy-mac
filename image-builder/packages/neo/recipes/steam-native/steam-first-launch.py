#!/usr/bin/python
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Ryan Murray <ryan@aurorasilicon.org>
"""Ordinary first-launch bootstrap from image-owned pinned offline inputs."""
import importlib.util
import json
import os
from pathlib import Path
import sys

SHARE = Path('/usr/share/aurora-steam-native')
POLICY = SHARE / 'offline-policy.json'
LAUNCHER = SHARE / 'bin/steam-native4k'


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
    # The exact public launcher retains all arguments and graphics/session
    # policy. Tests replace execv; package installation never calls this code.
    os.execv(str(LAUNCHER), [str(LAUNCHER), *args])


if __name__ == '__main__':
    main()
