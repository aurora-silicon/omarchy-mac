#!/usr/bin/env python3
"""Package the pinned Aurora J700 audio stack for a running system or image."""
import argparse
import hashlib
import json
from pathlib import Path
import shutil
import struct
import subprocess

PINS = {
    'speakerguardd': 'e03febfe52a540e9255036a01e18030e0a5135f9',
    'asahi-audio': 'b2da7512e9bfcd5837355d2393f3c43219acf6b9',
    'alsa-ucm-conf-asahi': 'e55107ad9ba220a2772dbe4d55438cd1ec669288',
}


def require(condition, message):
    if not condition:
        raise ValueError(message)


def replace_once(text, old, new):
    require(text.count(old) == 1, "Pinned speaker unit text changed: " + old.splitlines()[0])
    return text.replace(old, new, 1)


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def run(*args, **kwargs):
    return subprocess.check_output(args, **kwargs).decode().strip()


def install(source, root, destination, mode=0o644):
    target = root / destination
    target.parent.mkdir(parents=True, exist_ok=True)
    shutil.copyfile(source, target)
    target.chmod(mode)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    for name in PINS:
        parser.add_argument('--' + name, type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    sources = {name: getattr(args, name.replace('-', '_')).resolve() for name in PINS}
    for name, source in sources.items():
        require(run('git', '-C', str(source), 'rev-parse', 'HEAD') == PINS[name], name + " source pin differs")
        require(not run('git', '-C', str(source), 'status', '--porcelain', '--untracked-files=no'), name + " source has changes")
    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=True)
    stage = output / 'stage'
    require(not stage.exists(), 'use a fresh output directory')
    stage.mkdir()
    records = []

    def package(name, version, root, dependencies, legacy=None, previous=None):
        source_name = legacy or name
        stamp = run('git', '-C', str(sources[source_name]), 'show', '-s', '--format=%ct', 'HEAD')
        inventory = {str(p.relative_to(root)): sha(p) for p in sorted(root.rglob('*')) if p.is_file()}
        doc = root / 'usr/share/doc' / name / 'aurora-build.json'
        doc.parent.mkdir(parents=True, exist_ok=True)
        doc.write_text(json.dumps({'repository': 'https://github.com/aurora-silicon/' + source_name,
                                   'commit': PINS[source_name], 'files': inventory}, indent=2) + '\n')
        info = [f'pkgname = {name}', f'pkgbase = {name}', f'pkgver = {version}',
                f'pkgdesc = Aurora Apple Silicon audio: {name}',
                f'url = https://github.com/aurora-silicon/{source_name}', f'builddate = {stamp}',
                'packager = Aurora Silicon', 'arch = aarch64',
                'license = BSD' if source_name == 'alsa-ucm-conf-asahi' else 'license = MIT',
                f'size = {sum(p.stat().st_size for p in root.rglob("*") if p.is_file())}',
                *['depend = ' + dep for dep in dependencies],
                *[entry for alias in (legacy, previous) if alias for entry in
                  (f'provides = {alias}={version}', f'conflict = {alias}', f'replaces = {alias}')]]
        (root / '.PKGINFO').write_text('\n'.join(info) + '\n')
        archive = output / f'{name}-{version}-aarch64.pkg.tar.zst'
        subprocess.run(['tar', '--sort=name', '--owner=0', '--group=0', '--numeric-owner',
                        '--mtime=@' + stamp, '--use-compress-program=zstd -T2 -8',
                        '-cf', str(archive), '-C', str(root), '.PKGINFO', 'usr'], check=True)
        records.append({'name': name, 'version': version, 'file': archive.name,
                        'sha256': sha(archive), 'source': PINS[source_name]})

    root = stage / 'speakerguardd'
    source = sources['speakerguardd']
    binary = source / 'target/aarch64-unknown-linux-gnu/release/speakerguardd'
    elf = binary.read_bytes()[:20]
    require(elf[:6] == b'\x7fELF\x02\x01' and struct.unpack_from('<H', elf, 18)[0] == 183, 'speaker executable is not AArch64 ELF64')
    install(binary, root, 'usr/bin/speakerguardd', 0o755)
    install(source / 'conf/apple/j700.conf', root, 'usr/share/speakerguardd/apple/j700.conf')
    install(source / '95-speakerguardd.rules', root, 'usr/lib/udev/rules.d/95-speakerguardd.rules')
    install(source / 'LICENSE', root, 'usr/share/licenses/speakerguardd/LICENSE')
    # The capture-only AOP card can enumerate first. Bind this J700 service to
    # the speaker card instead of the daemon's first-Apple-card default.
    unit = (source / 'speakerguardd.service').read_text()
    unit = replace_once(unit, 'ExecStart=/usr/bin/speakerguardd -c /usr/share/speakerguardd',
                        'ExecStart=/usr/bin/speakerguardd -c /usr/share/speakerguardd -C AppleJ700')
    unit = replace_once(unit, 'Description=Speaker Protection Daemon (feed-forward)',
                        'Description=Speaker Protection Daemon (feed-forward)\nStartLimitIntervalSec=60\nStartLimitBurst=10')
    unit = replace_once(unit, 'StartLimitInterval=60\nStartLimitBurst=10\n', '')
    path = root / 'usr/lib/systemd/system/speakerguardd.service'
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(unit)
    # Keep the feedback daemon available on other supported Macs; only J700
    # is handed to the new feed-forward daemon by the model-specific udev rule.
    condition = root / 'usr/lib/speakerguardd/use-feedback-guard'
    condition.parent.mkdir(parents=True, exist_ok=True)
    condition.write_text('#!/bin/sh\n'
                         'test -r /proc/device-tree/compatible || exit 0\n'
                         'tr "\\000" "\\n" < /proc/device-tree/compatible | grep -Fxq apple,j700 && exit 1\n'
                         'exit 0\n')
    condition.chmod(0o755)
    drop = root / 'usr/lib/systemd/system/speakersafetyd.service.d/50-j700-guard.conf'
    drop.parent.mkdir(parents=True, exist_ok=True)
    drop.write_text('[Service]\nExecCondition=/usr/lib/speakerguardd/use-feedback-guard\n')
    package('speakerguardd', '0.1.0.aurora2-' + PINS['speakerguardd'][:12], root, ['glibc', 'libgcc'])

    root = stage / 'alsa-ucm-conf-asahi'
    shutil.copytree(sources['alsa-ucm-conf-asahi'] / 'ucm2', root / 'usr/share/alsa/ucm2')
    install(sources['alsa-ucm-conf-asahi'] / 'LICENSE.asahi', root,
            'usr/share/licenses/alsa-ucm-conf-asahi/LICENSE.asahi')
    package('alsa-ucm-conf-aurora', '10.aurora2-' + PINS['alsa-ucm-conf-asahi'][:12], root,
            ['alsa-ucm-conf'], legacy='alsa-ucm-conf-asahi', previous='alsa-ucm-conf-asahi-aurora')

    root = stage / 'asahi-audio'
    subprocess.run(['make', '-C', str(sources['asahi-audio']), 'install',
                    'DESTDIR=' + str(root), 'PREFIX=/usr'], check=True)
    install(sources['asahi-audio'] / 'LICENSE', root, 'usr/share/licenses/asahi-audio/LICENSE')
    package('aurora-audio', '4.1.aurora2-' + PINS['asahi-audio'][:12], root,
            ['alsa-ucm-conf-aurora', 'pipewire-audio', 'wireplumber', 'bankstown',
             'lsp-plugins-lv2', 'speakersafetyd', 'speakerguardd'], legacy='asahi-audio', previous='asahi-audio-aurora')
    (output / 'manifest.json').write_text(json.dumps(records, indent=2) + '\n')
    print(json.dumps(records, indent=2))


if __name__ == '__main__':
    main()
