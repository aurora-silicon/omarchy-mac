#!/usr/bin/env python3
"""Verify and freeze a signed Apple Silicon candidate set; never trust artifact-supplied keys.

A set is the directory the candidate-set tool of omacom/omarchy-mac signs:
manifest.json, signing.json and signing.json.sig, and each package archive
with its detached .sig. Trust comes only from candidate-trust/ beside this
file, or an explicit operator-selected trust directory: the signer's
fingerprints, the digest of its public key and the package set the plan names. The key file that travels with a set is never read.

Besides the runtime and boot packages the plan names, a set may carry the
rest of the Apple default set's closure that the Apple repository order takes
from an Omarchy channel. Those, the boot packages and the boot package the
policy allows may come from that channel instead of a pull request build or
the source commit; each is still signed by the set's key.

The platform packages (omarchy-mac, omarchy-mac-boot) are versioned apart from
the runtime, so a set may carry them built from their own commit of a platform
repository (the policy's platform_repositories: omacom/omarchy-mac-pkgs, their
home, or the source repository they moved from). It says so in its signed
manifest, one entry per such package:

  "platform_sources": {"omarchy-mac": "<commit>", "omarchy-mac-boot": "<commit>"}

An operator may additionally pin boot or closure packages in trusted policy.json:

  "package_sources": {"mesa": {"repository": "aurora-silicon/mesa", "commit": "<full commit>"}}

Those packages must name exactly that repository and commit in the signed
manifest. This mapping is never taken from the candidate artifact, does not
admit other runtime sources, and does not replace signature or payload checks.
The operator-selected trust directory must contain policy.json and public.asc.

Each declared package must name that commit as its source and carry it as its
source revision. Any other runtime package from another commit is refused.

  candidate_set.py import --input DIR --output DIR --receipt-sha256 HEX
                          --manifest-sha256 HEX --source-commit HEX
  candidate_set.py describe --input DIR
"""
import argparse
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import re
import shutil
import stat
import struct
import subprocess
import sys
import tempfile

TRUST = Path(__file__).resolve().parent / 'candidate-trust'
HEX40 = re.compile(r'[0-9a-f]{40}')
HEX64 = re.compile(r'[0-9a-f]{64}')
ARCHIVE = re.compile(r'[A-Za-z0-9@._+:-]+\.pkg\.tar\.(xz|zst)')
# The runtime's Apple package list, by upstream's name, then an older runtime's.
APPLE_LISTS = ('usr/share/omarchy/install/omarchy-apple-silicon.packages',
               'usr/share/omarchy/install/omarchy-apple.packages')
# Where each runtime package records the commit it was built from.
REVISION_FILES = {
    'omarchy': 'usr/share/doc/omarchy/source-revision',
    'omarchy-settings': 'usr/share/doc/omarchy-settings/source-revision',
    'omarchy-mac': 'usr/share/omarchy-mac/source-revision',
    'omarchy-mac-boot': 'usr/share/omarchy-mac/boot-source-revision',
}
# Boot payloads the image is assembled and inspected from, and the one package
# that may carry each.
REQUIRED_OWNERS = {
    'usr/lib/asahi-boot/m1n1.bin': 'm1n1-aurora',
    'usr/lib/asahi-boot/u-boot-nodtb.bin': 'uboot-asahi',
    'usr/lib/omarchy/initcpio/omarchy-mac-encrypt': 'omarchy-mac-boot',
    'usr/lib/omarchy/mac-first-boot/omarchy-mac-first-boot': 'omarchy-mac-boot',
    'usr/share/libalpm/scripts/limine-apple-gate': 'limine-mkinitcpio-hook',
    'usr/share/omarchy/default/limine/limine.conf': 'omarchy-settings',
}
# A package the set took from an Omarchy channel's aarch64 repository, by its own file name.
CHANNEL_URL = re.compile(r'https://pkgs\.omarchy\.org/(edge|rc|stable)/aarch64/([^/]+)')
BAD_STATUS = re.compile(r'\b(BADSIG|ERRSIG|REVKEYSIG|EXPKEYSIG|EXPSIG|KEYREVOKED|KEYEXPIRED|SIGEXPIRED)\b')


# Operator-selected image targets, not runtime or feature overrides. Generic is
# the existing cross-board profile; Neo is bound to its public firmware facts.
IMAGE_TARGET_PROFILES = {
    'generic': {'compatible': 'apple,arm-platform', 'board': None, 'supported_fw': ['13.5', '14.8.3']},
    'neo-j700': {'compatible': 'apple,j700', 'board': 'apple,j700', 'supported_fw': ['26.6.2']},
}
STAGE1_PATH = 'usr/lib/aura/aura-stage1.bin'
STAGE1_MAGIC = b'AURORA-S1-CFG01\0'
STAGE1_BODY = struct.Struct('<II40s192s')


def image_target_profile(policy):
    name = policy.get('image_target_profile', 'generic')
    require(isinstance(name, str) and name in IMAGE_TARGET_PROFILES, 'unsupported trusted image target profile')
    return name


def bare_stage1(data):
    """Unfilled distribution Stage1; target UUID/path and CRC belong to install."""
    require(data.endswith(b'STACKBOT') and data.count(STAGE1_MAGIC) == 1,
            'common Stage1 must be bare with one config block and STACKBOT tail')
    offset = data.index(STAGE1_MAGIC) + len(STAGE1_MAGIC)
    require(offset + STAGE1_BODY.size + 4 <= len(data) - 8, 'common Stage1 config is truncated')
    version, window, uuid, path = STAGE1_BODY.unpack_from(data, offset)
    crc, = struct.unpack_from('<I', data, offset + STAGE1_BODY.size)
    require(version == 1 and window == 0 and not any(uuid) and not any(path) and crc == 0,
            'common Stage1 must have the unfilled version-1 config and zero CRC sentinel')
    return hashlib.sha256(data).hexdigest()


def require(ok, message):
    if not ok:
        raise ValueError(message)


def digest(path):
    with open(path, 'rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()


def rpmvercmp(a, b):
    """libalpm's rpmvercmp, segment by segment."""
    if a == b:
        return 0
    i = j = 0
    while i < len(a) and j < len(b):
        start_i, start_j = i, j
        while i < len(a) and not a[i].isalnum():
            i += 1
        while j < len(b) and not b[j].isalnum():
            j += 1
        if i == len(a) or j == len(b):
            break
        # More separators before a segment makes it the newer version.
        if i - start_i != j - start_j:
            return 1 if i - start_i > j - start_j else -1
        numeric = a[i].isdigit()
        kind = str.isdigit if numeric else str.isalpha
        end_i, end_j = i, j
        while end_i < len(a) and kind(a[end_i]):
            end_i += 1
        while end_j < len(b) and kind(b[end_j]):
            end_j += 1
        if end_j == j:
            return 1 if numeric else -1
        first, second = a[i:end_i], b[j:end_j]
        if numeric:
            first, second = first.lstrip('0'), second.lstrip('0')
            if len(first) != len(second):
                return 1 if len(first) > len(second) else -1
        if first != second:
            return 1 if first > second else -1
        i, j = end_i, end_j
    if i == len(a) and j == len(b):
        return 0
    if (i == len(a) and not b[j].isalpha()) or (i < len(a) and a[i].isalpha()):
        return -1
    return 1


def vercmp(a, b):
    """pacman's vercmp for [epoch:]version[-release] strings."""
    def split(value):
        epoch, _, rest = value.rpartition(':') if ':' in value else ('0', '', value)
        version, _, release = rest.partition('-')
        return epoch or '0', version, release or None

    epoch_a, version_a, release_a = split(a)
    epoch_b, version_b, release_b = split(b)
    result = rpmvercmp(epoch_a, epoch_b) or rpmvercmp(version_a, version_b)
    if result == 0 and release_a is not None and release_b is not None:
        result = rpmvercmp(release_a, release_b)
    return result


def read_trust_file(trust, name):
    fd = os.open(trust / name, os.O_RDONLY | os.O_NOFOLLOW)
    with os.fdopen(fd, 'rb') as stream:
        require(stat.S_ISREG(os.fstat(stream.fileno()).st_mode), 'non-regular trust input: ' + name)
        data = stream.read(1048577)
    require(len(data) <= 1048576, 'trust input is too large: ' + name)
    return data


def public_trust_key(trust):
    """Read public key packets only; never follow a key symlink or import secrets."""
    public_key = read_trust_file(trust, 'public.asc')
    with tempfile.TemporaryDirectory(prefix='candidate-public-key-') as temporary:
        packets = subprocess.run(['gpg', '--homedir', temporary, '--batch', '--list-packets'],
                                 input=public_key, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    require(packets.returncode == 0 and b':public key packet:' in packets.stdout
            and b':secret key packet:' not in packets.stdout
            and b':secret sub key packet:' not in packets.stdout,
            'candidate trust key must contain public key packets only')
    return public_key


def load_policy(trust=TRUST):
    require(trust.is_dir() and not trust.is_symlink(), 'unsafe trust directory')
    policy = json.loads(read_trust_file(trust, 'policy.json'))
    require(policy.get('schema') == 1, 'unsupported candidate policy')
    require(hashlib.sha256(public_trust_key(trust)).hexdigest() == policy['public_key_sha256'],
            'trust anchor checksum mismatch')
    for key in ('primary_fingerprint', 'signing_fingerprint'):
        require(HEX40.fullmatch(policy[key].lower()) is not None, 'invalid trust anchor fingerprint')
    image_target_profile(policy)
    sources = policy.get('package_sources', {})
    require(isinstance(sources, dict), 'invalid trusted package sources')
    for name, source in sources.items():
        require(isinstance(name, str) and re.fullmatch(r'[A-Za-z0-9@._+:-]+', name) is not None
                and name not in policy['runtime_packages'] and name not in policy['refused_packages'],
                'invalid trusted source package: ' + str(name))
        require(isinstance(source, dict) and set(source) == {'repository', 'commit'}
                and isinstance(source['repository'], str)
                and re.fullmatch(r'[A-Za-z0-9][A-Za-z0-9_.-]*/[A-Za-z0-9][A-Za-z0-9_.-]*',
                                 source['repository']) is not None
                and isinstance(source['commit'], str) and HEX40.fullmatch(source['commit']) is not None,
                'invalid trusted package source: ' + name)
    stock_packages(policy)
    return policy


def stock_packages(policy):
    """Exact stock archives required by the operator, from pinned databases."""
    stock = policy.get('required_stock_packages', {})
    require(isinstance(stock, dict), 'invalid required stock packages')
    for name, package in stock.items():
        require(isinstance(name, str) and re.fullmatch(r'[A-Za-z0-9@._+:-]+', name) is not None
                and name not in policy['runtime_packages'] + policy['boot_packages'] + policy['refused_packages'],
                'invalid required stock package: ' + str(name))
        require(isinstance(package, dict) and set(package) == {'repository', 'version', 'sha256'}
                and package['repository'] in ('asahi-alarm', 'core', 'extra', 'alarm', 'aur', 'omarchy')
                and isinstance(package['version'], str)
                and re.fullmatch(r'[A-Za-z0-9.+_:~\-]+', package['version']) is not None
                and isinstance(package['sha256'], str) and HEX64.fullmatch(package['sha256']) is not None,
                'invalid required stock archive: ' + name)
    return stock


def set_digest(manifest):
    lines = sorted((f"{p['name']} {p['version']} {p['filename']} {p['sha256']}\n" for p in manifest['packages']),
                   key=lambda line: line.encode())
    return hashlib.sha256(''.join(lines).encode()).hexdigest()


def copy_file(root, name, destination):
    require(re.fullmatch(r'[A-Za-z0-9@+_.:-]+', name) is not None and name not in ('.', '..'), 'unsafe filename')
    fd = os.open(root / name, os.O_RDONLY | os.O_NOFOLLOW)
    with os.fdopen(fd, 'rb') as source:
        require(stat.S_ISREG(os.fstat(source.fileno()).st_mode), 'non-regular input')
        with (destination / name).open('xb') as target:
            shutil.copyfileobj(source, target)


def freeze_trust(root, destination, policy_sha256=None, public_key_sha256=None):
    """Copy only public trust inputs into an exclusive, verified snapshot."""
    require(root.is_dir() and not root.is_symlink(), 'unsafe trust directory')
    destination.mkdir(mode=0o700)
    (destination / 'policy.json').write_bytes(read_trust_file(root, 'policy.json'))
    public_key = public_trust_key(root)
    (destination / 'public.asc').write_bytes(public_key)
    policy = load_policy(destination)
    identities = {'candidate_trust_policy_sha256': digest(destination / 'policy.json'),
                  'candidate_trust_public_key_sha256': policy['public_key_sha256']}
    require(policy_sha256 is None or identities['candidate_trust_policy_sha256'] == policy_sha256,
            'candidate trust policy changed since resolution')
    require(public_key_sha256 is None or identities['candidate_trust_public_key_sha256'] == public_key_sha256,
            'candidate trust public key changed since resolution')
    for path in destination.iterdir():
        path.chmod(0o444)
    destination.chmod(0o555)
    return identities


def verify_signature(home, path, policy):
    """PATH's detached signature, checked by gpgv against the pinned key alone."""
    result = subprocess.run(['gpgv', '--homedir', str(home), '--keyring', str(home / 'trusted.gpg'),
                             '--status-fd', '1', str(path) + '.sig', str(path)],
                            stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    statuses = result.stdout.splitlines()
    valid = [line.split() for line in statuses if line.startswith('[GNUPG:] VALIDSIG ')]
    require(result.returncode == 0 and len(valid) == 1, 'invalid signature: ' + path.name)
    require(valid[0][2] == policy['signing_fingerprint'].upper()
            and valid[0][-1] == policy['primary_fingerprint'].upper(), 'unapproved signer: ' + path.name)
    require(not any(BAD_STATUS.search(line) for line in statuses), 'expired or revoked signature: ' + path.name)


def member(package, name):
    return subprocess.check_output(['bsdtar', '-xOf', str(package), name])


def apple_list(package):
    """The Apple package list the runtime archive ships, as (member, text). A
    link is passed over: bsdtar reads it as empty, and the list it names is a
    member of its own."""
    for name in APPLE_LISTS:
        entry = subprocess.run(['bsdtar', '-tvf', str(package), name], capture_output=True, text=True)
        if entry.returncode == 0 and entry.stdout.startswith('-'):
            return name, member(package, name).decode()
    raise ValueError('the runtime ships no Apple package list (omarchy-apple-silicon.packages or omarchy-apple.packages)')


def payload_paths(package):
    listing = subprocess.check_output(['bsdtar', '-tf', str(package)], text=True).splitlines()
    return {path.removeprefix('./') for path in listing
            if not path.endswith('/') and not path.removeprefix('./').startswith('.')}


def pkginfo(package):
    fields = {}
    for line in member(package, '.PKGINFO').decode().splitlines():
        if ' = ' in line:
            key, value = line.split(' = ', 1)
            fields.setdefault(key, []).append(value)
    return fields


def from_channel(origin, filename):
    # A release asset cannot hold the colon of an epoch, so the set names it with a dot.
    match = CHANNEL_URL.fullmatch(origin.get('url', ''))
    return (match is not None and match[2].replace(':', '.') == filename
            and origin.get('channel') == f'omacom {match[1]} aarch64' and 'commit' not in origin)


def verify_payloads(payloads, target_profile="generic"):
    """Every file has one owner, and each boot payload the image needs its expected one."""
    owners = {}
    for name, paths in sorted(payloads.items()):
        for path in paths:
            require(path not in owners, f'candidate payload ownership conflict: {path} ({owners.get(path)}, {name})')
            owners[path] = name
    for path, owner in REQUIRED_OWNERS.items():
        require(owners.get(path) == owner, f'{path} is not in {owner}')
    if target_profile == 'neo-j700':
        require(owners.get(STAGE1_PATH) == 'm1n1-aurora', 'common Stage1 is not owned by m1n1-aurora')
    kernels = [p for p in payloads.get('linux-aurora', ()) if PurePosixPath(p).match('usr/lib/modules/*/vmlinuz')]
    require(len(kernels) == 1, 'linux-aurora does not carry one kernel')
    release = PurePosixPath(kernels[0]).parts[3]
    dtbs = [p for p in payloads['linux-aurora'] if PurePosixPath(p).match(f'usr/lib/modules/{release}/dtbs/*.dtb')]
    require(dtbs, 'linux-aurora carries no device trees')
    require(not any('omarchy-arm-repository.key' in path for path in owners), 'a fork repository key is in the set')
    return owners


def snapshot(root, destination, receipt_sha256, source_commit, manifest_sha256=None, trust=TRUST):
    require(HEX64.fullmatch(receipt_sha256) is not None, 'invalid receipt hash')
    require(manifest_sha256 is None or HEX64.fullmatch(manifest_sha256) is not None, 'invalid manifest hash')
    require(HEX40.fullmatch(source_commit) is not None, 'invalid source commit')
    require(root.is_dir() and not root.is_symlink(), 'unsafe input directory')
    policy = load_policy(trust)
    runtime, boot = set(policy['runtime_packages']), set(policy['boot_packages'])
    destination.mkdir(mode=0o700)  # Exclusive: a failed import is never reused.
    for name in ('signing.json', 'signing.json.sig', 'manifest.json'):
        copy_file(root, name, destination)
    require(digest(destination / 'signing.json') == receipt_sha256, 'receipt checksum mismatch')
    with tempfile.TemporaryDirectory(prefix='candidate-trust-') as temporary:
        home = Path(temporary)
        home.chmod(0o700)
        subprocess.run(['gpg', '--homedir', str(home), '--batch', '--dearmor', '--output', str(home / 'trusted.gpg'),
                        str(trust / 'public.asc')], check=True, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
        verify_signature(home, destination / 'signing.json', policy)
        receipt = json.loads((destination / 'signing.json').read_text())
        require(receipt.get('schema') == 1, 'wrong candidate receipt')
        signer = receipt.get('signer', {})
        require(signer.get('fingerprint', '').upper() == policy['primary_fingerprint'].upper()
                and signer.get('key_sha256') == policy['public_key_sha256'], 'receipt signer mismatch')
        require(digest(destination / 'manifest.json') == receipt.get('manifest_sha256'), 'build manifest mismatch')
        require(manifest_sha256 is None or receipt['manifest_sha256'] == manifest_sha256, 'build manifest mismatch')
        data = json.loads((destination / 'manifest.json').read_text())
        source = data.get('source', {})
        require(data.get('schema') == 1 and data.get('candidate_only') is True
                and data.get('set') == receipt.get('set')
                and source.get('repository') == policy['source_repository']
                and source.get('commit') == source_commit, 'wrong build manifest')
        require(data.get('set_sha256') == set_digest(data) == receipt.get('set_sha256'), 'set digest mismatch')
        packages = data['packages']
        names = [p['name'] for p in packages]
        require(len(set(names)) == len(names), 'duplicate package in the set')
        require(not set(names) & set(policy['refused_packages']), 'refused package in the set')
        require(not set(names) & set(stock_packages(policy)), 'stock package also supplied as a candidate')
        require(runtime | boot <= set(names), 'wrong package set: missing '
                + ', '.join(sorted(runtime | boot - set(names))))
        declared = data.get('platform_sources', {})
        require(isinstance(declared, dict), 'invalid platform sources')
        for name, commit in declared.items():
            require(name in policy['platform_packages'], 'platform sources name a package that is not a platform package: '
                    + str(name))
            require(isinstance(commit, str) and HEX40.fullmatch(commit) is not None,
                    'invalid platform source commit: ' + name)
            require(commit != source_commit, "platform sources name the set's own commit: " + name)
        signatures = {entry['file']: entry for entry in receipt.get('signatures', [])}
        require(len(signatures) == len(receipt.get('signatures', []))
                and set(signatures) == {p['filename'] for p in packages}, 'unexpected signed inventory')
        versions, payloads, fields_of, origins, commits = {}, {}, {}, {}, {}
        for package in packages:
            name, filename = package['name'], package['filename']
            require(ARCHIVE.fullmatch(filename) is not None, 'invalid archive name')
            copy_file(root, filename, destination)
            copy_file(root, filename + '.sig', destination)
            path = destination / filename
            entry = signatures[filename]
            require(digest(path) == package['sha256'] == entry['sha256'], 'signed file checksum mismatch')
            require(digest(Path(str(path) + '.sig')) == entry['signature_sha256'], 'signature file mismatch')
            verify_signature(home, path, policy)
            fields = pkginfo(path)
            # Only the closure may hold architecture-independent packages (a keyring, fonts).
            arches = ['aarch64'] if name in runtime | boot else ['aarch64', 'any']
            require(fields.get('pkgname') == [name] and fields.get('pkgver') == [package['version']]
                    and fields.get('arch') == [package['arch']] and package['arch'] in arches,
                    'package metadata mismatch: ' + name)
            origin = package.get('source', {})
            if name in runtime:
                revision = member(path, REVISION_FILES[name]).decode().strip()
                if name in declared:
                    require(origin.get('repository') in policy['platform_repositories']
                            and origin.get('commit') == declared[name] == revision, 'mixed package sources: ' + name)
                    origins[name] = 'platform ' + revision
                elif origin.get('repository') == policy['source_repository'] and origin.get('commit') == source_commit:
                    require(revision == source_commit, 'mixed package sources: ' + name)
                    origins[name] = 'commit'
                else:
                    # Published from another commit; the revision it names is recorded.
                    require(name in policy['channel_runtime_packages'] and from_channel(origin, filename)
                            and HEX40.fullmatch(revision) is not None, 'mixed package sources: ' + name)
                    origins[name] = 'channel ' + revision
                commits[name] = revision
            elif name in policy.get('package_sources', {}):
                pinned_source = policy['package_sources'][name]
                require(origin.get('repository') == pinned_source['repository']
                        and origin.get('commit') == pinned_source['commit'],
                        'unapproved pinned package source: ' + name)
                origins[name] = 'trusted-source'
                commits[name] = pinned_source['commit']
            elif name in boot:
                require((origin.get('repository') == policy['boot_repository']
                         and HEX40.fullmatch(origin.get('commit', '')) is not None) or from_channel(origin, filename),
                        'unknown boot package source: ' + name)
                origins[name] = 'channel' if from_channel(origin, filename) else 'pull-request'
            else:
                require(from_channel(origin, filename), 'unknown closure package source: ' + name)
                origins[name] = 'channel'
            minimum = policy['minimum_versions'].get(name)
            require(minimum is None or vercmp(package['version'], minimum) >= 0,
                    f'{name} {package["version"]} is below the minimum {minimum}')
            versions[name] = package['version']
            payloads[name] = payload_paths(path)
            fields_of[name] = fields
        target_profile = image_target_profile(policy)
        verify_payloads(payloads, target_profile)
        if target_profile == 'neo-j700':
            aura = destination / next(p['filename'] for p in packages if p['name'] == 'm1n1-aurora')
            bare_stage1(member(aura, STAGE1_PATH))
        # pkgrel describes packaging, not the upstream source version. Official
        # runtime/settings recipes may release their packaging independently;
        # both archives have already proved the same exact source commit above.
        desktop_version = versions['omarchy'].rsplit('-', 1)[0]
        settings_version = versions['omarchy-settings'].rsplit('-', 1)[0]
        require(desktop_version == settings_version, 'mixed desktop versions')
        settings_pins = [dependency[len('omarchy-settings='):]
                         for dependency in fields_of['omarchy'].get('depend', [])
                         if dependency.startswith('omarchy-settings=')]
        require(settings_pins and all(pin in (settings_version, versions['omarchy-settings'])
                                      for pin in settings_pins), 'missing or incompatible settings version pin')
        for name in ('omarchy-mac', 'omarchy-mac-boot'):
            pins = [d for d in fields_of[name].get('depend', []) if d.startswith('omarchy=')]
            require(all(pin[len('omarchy='):] in (versions['omarchy'], versions['omarchy'].rsplit('-', 1)[0])
                        for pin in pins), f'{name} pins another omarchy')
        _, apple = apple_list(destination / next(p['filename'] for p in packages if p['name'] == 'omarchy'))
        require({'omarchy-mac', 'omarchy-mac-boot'} <= {line.strip() for line in apple.splitlines()},
                'the Apple package list lacks the add-on or boot package')
    summary = {
        'schema': 1,
        'candidate_trust_policy_sha256': digest(trust / 'policy.json'),
        'candidate_trust_public_key_sha256': policy['public_key_sha256'],
        'set': data['set'],
        'candidate_only': data['candidate_only'] is True,
        'source_commit': source_commit,
        'signer': policy['primary_fingerprint'].upper(),
        'receipt_sha256': receipt_sha256,
        'manifest_sha256': receipt['manifest_sha256'],
        'set_sha256': data['set_sha256'],
        'packages': [{'name': p['name'], 'version': p['version'], 'filename': p['filename'], 'sha256': p['sha256'],
                      'group': 'runtime' if p['name'] in runtime else 'boot' if p['name'] in boot else 'closure',
                      'origin': origins[p['name']],
                      **({'source_commit': commits[p['name']]} if p['name'] in commits else {}),
                      **({'source_repository': policy['package_sources'][p['name']]['repository']}
                         if origins[p['name']] == 'trusted-source' else {})} for p in packages],
    }
    if target_profile != 'generic':
        summary['image_target_profile'] = target_profile
    (destination / 'import.json').write_text(json.dumps(summary, indent=2, sort_keys=True) + '\n')
    for path in destination.iterdir():
        path.chmod(0o444)
    destination.chmod(0o555)
    return summary


def describe(root, trust=TRUST):
    """Verifies the set in a scratch copy and prints the values an inputs record pins."""
    receipt = json.loads((root / 'signing.json').read_text())
    manifest = json.loads((root / 'manifest.json').read_text())
    with tempfile.TemporaryDirectory(prefix='candidate-describe-') as scratch:
        summary = snapshot(root, Path(scratch) / 'set', digest(root / 'signing.json'),
                           manifest.get('source', {}).get('commit', ''), receipt.get('manifest_sha256'), trust)
        for path in (Path(scratch) / 'set').iterdir():
            path.chmod(0o644)
        (Path(scratch) / 'set').chmod(0o755)
    return summary


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    commands = parser.add_subparsers(dest='command', required=True)
    imported = commands.add_parser('import')
    imported.add_argument('--input', type=Path, required=True)
    imported.add_argument('--output', type=Path, required=True)
    imported.add_argument('--receipt-sha256', required=True)
    imported.add_argument('--manifest-sha256', required=True)
    imported.add_argument('--source-commit', required=True)
    described = commands.add_parser('describe')
    described.add_argument('--input', type=Path, required=True)
    for command in (imported, described):
        command.add_argument('--trust-dir', type=Path, default=TRUST,
                             help='operator-controlled policy.json and public.asc directory')
    profiled = commands.add_parser('target-profile')
    profiled.add_argument('--name', choices=IMAGE_TARGET_PROFILES, required=True)
    frozen = commands.add_parser('freeze-trust')
    frozen.add_argument('--input', type=Path, required=True)
    frozen.add_argument('--output', type=Path, required=True)
    frozen.add_argument('--policy-sha256')
    frozen.add_argument('--public-key-sha256')
    args = parser.parse_args(argv)
    try:
        if args.command == 'target-profile':
            print(json.dumps(IMAGE_TARGET_PROFILES[args.name], sort_keys=True))
            return 0
        if args.command == 'freeze-trust':
            identities = freeze_trust(args.input, args.output, args.policy_sha256, args.public_key_sha256)
            for key, value in identities.items():
                print(f'{key}={value}')
            return 0
        if args.command == 'import':
            summary = snapshot(args.input, args.output, args.receipt_sha256, args.source_commit,
                               args.manifest_sha256, args.trust_dir)
        else:
            summary = describe(args.input, args.trust_dir)
    except (ValueError, OSError, KeyError, TypeError, subprocess.CalledProcessError, json.JSONDecodeError) as error:
        print(f'candidate_set: {error}', file=sys.stderr)
        return 1
    for key in ('set', 'source_commit', 'signer', 'receipt_sha256', 'manifest_sha256', 'set_sha256',
                'candidate_trust_policy_sha256', 'candidate_trust_public_key_sha256'):
        print(f'{key}={summary[key]}')
    if 'image_target_profile' in summary:
        print('image_target_profile=' + summary['image_target_profile'])
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
