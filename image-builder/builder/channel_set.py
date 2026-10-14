#!/usr/bin/env python3
"""Resolve and freeze an Apple Silicon package set from a pinned Omarchy channel database.

Channel mode builds a public image from what an Omarchy channel serves, instead
of from a hand-signed candidate set. The set is the runtime and boot packages
the trust policy names, read from a snapshot of the channel's repository
database (omarchy.db) whose sha256 the inputs record pinned when it was
resolved. Each archive must be the one that database lists (file name, size,
sha256, name, version and architecture) and carry a detached signature by the
Omarchy package signing key. Trust comes only from the "channel" section of
candidate-trust/policy.json and the key file it pins by sha256 and fingerprint;
the candidate test key is never accepted here, and the Omarchy key is never
accepted for a candidate set.

The channel's runtime may be named apart from its role: edge serves the
desktop as omarchy-dev and omarchy-settings-dev, which provide (and conflict
with) omarchy and omarchy-settings. The policy maps each runtime role to the
package that fills it, and that package must provide the role.

The frozen set has candidate_set.py's layout (import.json beside the archives
and their signatures, read-only), so the builder installs and inspects it the
same way, with "kind": "channel", "candidate_only": false (a public image: no
test image pin, the release profile), the database's sha256, the set's
manifest and its digest. A runtime package records its source commit when it
ships a source revision file; the -dev runtime ships none, and is identified
by its version and archive digest.

  channel_set.py files --db FILE --lane LANE
  channel_set.py import --db FILE --db-sha256 HEX --lane LANE --packages DIR --output DIR
  channel_set.py describe --db FILE --lane LANE --packages DIR
  channel_set.py verify-installed --db FILE --db-sha256 HEX --records FILE --cache DIR
"""
import argparse
import hashlib
import importlib.util
import json
from pathlib import Path
import re
import subprocess
import sys
import tempfile

HERE = Path(__file__).resolve().parent
TRUST = HERE / 'candidate-trust'
HEX40 = re.compile(r'[0-9A-F]{40}')
HEX64 = re.compile(r'[0-9a-f]{64}')
LANE = re.compile(r'edge|rc|stable')
# What a pacman version and name look like in a repository database.
NAME = re.compile(r'[A-Za-z0-9@._+-]+')
VERSION = re.compile(r'([0-9]+:)?[A-Za-z0-9._+]+-[0-9]+(\.[0-9]+)?')


def _load(name):
    spec = importlib.util.spec_from_file_location(name, HERE / f'{name}.py')
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


candidate_set = _load('candidate_set')
require = candidate_set.require
digest = candidate_set.digest


def load_policy(trust=TRUST):
    """The candidate policy and its channel section, with the channel key checked against its pins."""
    policy = candidate_set.load_policy(trust)
    channel = policy.get('channel')
    require(isinstance(channel, dict), 'the trust policy names no channel trust root')
    key = channel.get('public_key', '')
    require(re.fullmatch(r'[A-Za-z0-9._-]+\.asc', key) is not None, 'invalid channel trust anchor')
    require(digest(trust / key) == channel.get('public_key_sha256'), 'channel trust anchor checksum mismatch')
    for field in ('primary_fingerprint', 'signing_fingerprint'):
        require(HEX40.fullmatch(channel.get(field, '')) is not None, 'invalid channel trust anchor fingerprint')
    require(channel['primary_fingerprint'] != policy['primary_fingerprint'].upper(),
            'the channel trust root is the candidate test key')
    roles = channel.get('runtime_packages')
    require(isinstance(roles, dict) and set(roles) == set(policy['runtime_packages'])
            and all(isinstance(n, str) and NAME.fullmatch(n) for n in roles.values())
            and len(set(roles.values())) == len(roles), 'invalid channel runtime packages')
    require(isinstance(channel.get('lanes'), list) and channel['lanes'], 'the trust policy names no channel lane')
    return policy, channel


def desc_fields(text):
    fields, key = {}, None
    for line in text.splitlines():
        if line.startswith('%') and line.endswith('%') and len(line) > 2:
            key = line.strip('%')
            require(key not in fields, f'a database entry names %{key}% twice')
            fields[key] = []
        elif line and key:
            fields[key].append(line)
    return fields


def read_database(path):
    """name -> desc fields for every package the repository database at PATH lists."""
    entries = {}
    with tempfile.TemporaryDirectory(prefix='channel-db-') as scratch:
        listing = subprocess.run(['bsdtar', '-tf', str(path)], capture_output=True, text=True)
        require(listing.returncode == 0, 'the channel database is not a repository database')
        for member in listing.stdout.splitlines():
            parts = member.rstrip('/').split('/')
            require(len(parts) in (1, 2) and all(p not in ('', '.', '..') for p in parts)
                    and (len(parts) == 1 or parts[1] in ('desc', 'files')),
                    f'unexpected member in the channel database: {member}')
        subprocess.run(['bsdtar', '-xf', str(path), '-C', scratch], check=True,
                       stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
        for desc in sorted(Path(scratch).glob('*/desc')):
            fields = desc_fields(desc.read_text())
            single = {}
            for key in ('NAME', 'VERSION', 'FILENAME', 'SHA256SUM', 'CSIZE', 'ARCH'):
                values = fields.get(key, [])
                require(len(values) == 1, f'{desc.parent.name} has no single %{key}%')
                single[key] = values[0]
            require(NAME.fullmatch(single['NAME']) and VERSION.fullmatch(single['VERSION'])
                    and desc.parent.name == f"{single['NAME']}-{single['VERSION']}"
                    and HEX64.fullmatch(single['SHA256SUM']) and single['CSIZE'].isdigit()
                    and candidate_set.ARCHIVE.fullmatch(single['FILENAME']),
                    f'malformed channel database entry {desc.parent.name}')
            require(single['NAME'] not in entries, f"the channel database lists {single['NAME']} twice")
            entries[single['NAME']] = {**fields, **{k: [v] for k, v in single.items()}}
    return entries


def provided(entry):
    """The names ENTRY provides, without version constraints."""
    return {re.split(r'[<>=]', value, maxsplit=1)[0] for value in entry.get('PROVIDES', [])}


def resolve(entries, policy, channel):
    """The set's packages in the database ENTRIES: (role or name, group, entry)."""
    chosen = []
    for role, name in channel['runtime_packages'].items():
        entry = entries.get(name)
        require(entry is not None, f'the channel database does not list {name}')
        require(role == name or role in provided(entry), f'{name} does not provide {role}')
        chosen.append((role, 'runtime', entry))
    for name in policy['boot_packages']:
        entry = entries.get(name)
        require(entry is not None, f'the channel database does not list {name}')
        chosen.append((name, 'boot', entry))
    names = [entry['NAME'][0] for _, _, entry in chosen]
    require(not set(names) & set(policy['refused_packages']), 'refused package in the set')
    for _, _, entry in chosen:
        require(entry['ARCH'][0] == 'aarch64', f"{entry['NAME'][0]} is not an aarch64 package")
    return chosen


def manifest(chosen, lane, database_sha256, channel):
    return {
        'schema': 1,
        'kind': 'channel',
        'channel': lane,
        'repository': channel['repository'],
        'database_sha256': database_sha256,
        'signer': channel['primary_fingerprint'],
        'packages': sorted(({'name': e['NAME'][0], 'version': e['VERSION'][0], 'filename': e['FILENAME'][0],
                             'sha256': e['SHA256SUM'][0], 'size': int(e['CSIZE'][0]), 'group': group,
                             **({'role': role} if group == 'runtime' else {})}
                            for role, group, e in chosen), key=lambda p: p['name']),
    }


def keyring(home, trust, channel):
    home.chmod(0o700)
    subprocess.run(['gpg', '--homedir', str(home), '--batch', '--dearmor', '--output', str(home / 'trusted.gpg'),
                    str(trust / channel['public_key'])], check=True, stdout=subprocess.DEVNULL,
                   stderr=subprocess.PIPE)


def verify_archive(home, path, entry, channel):
    """PATH is the archive ENTRY lists, signed by the channel key alone."""
    name = entry['NAME'][0]
    require(path.stat().st_size == int(entry['CSIZE'][0]) and digest(path) == entry['SHA256SUM'][0],
            f'{path.name} is not the archive the channel database lists')
    signature = Path(str(path) + '.sig')
    require(signature.is_file() and not signature.is_symlink(), f'unsigned package: {path.name}')
    candidate_set.verify_signature(home, path, channel)
    fields = candidate_set.pkginfo(path)
    require(fields.get('pkgname') == [name] and fields.get('pkgver') == entry['VERSION']
            and fields.get('arch') == entry['ARCH'], f'package metadata mismatch: {name}')
    return fields


def files(database, lane, trust=TRUST):
    policy, channel = load_policy(trust)
    require(LANE.fullmatch(lane) is not None and lane in channel['lanes'], f'channel mode does not build {lane}')
    return [e['FILENAME'][0] for _, _, e in resolve(read_database(database), policy, channel)]


def snapshot(database, database_sha256, lane, packages, destination, trust=TRUST):
    """Verifies the set the pinned DATABASE names from the archives in PACKAGES and freezes it in DESTINATION."""
    require(HEX64.fullmatch(database_sha256) is not None, 'invalid database hash')
    require(LANE.fullmatch(lane) is not None, 'invalid channel')
    require(packages.is_dir() and not packages.is_symlink(), 'unsafe package directory')
    policy, channel = load_policy(trust)
    require(lane in channel['lanes'], f'channel mode does not build {lane}')
    destination.mkdir(mode=0o700)  # Exclusive: a failed import is never reused.
    candidate_set.copy_file(database.parent, database.name, destination)
    frozen = destination / database.name
    require(digest(frozen) == database_sha256, 'the channel database changed since it was pinned')
    chosen = resolve(read_database(frozen), policy, channel)
    frozen.unlink()
    record = manifest(chosen, lane, database_sha256, channel)
    text = json.dumps(record, indent=2, sort_keys=True) + '\n'
    (destination / 'manifest.json').write_text(text)
    payloads, fields_of, commits = {}, {}, {}
    with tempfile.TemporaryDirectory(prefix='channel-trust-') as temporary:
        home = Path(temporary)
        keyring(home, trust, channel)
        for role, group, entry in chosen:
            filename = entry['FILENAME'][0]
            candidate_set.copy_file(packages, filename, destination)
            # A missing signature is refused below, by name.
            if (packages / (filename + '.sig')).exists():
                candidate_set.copy_file(packages, filename + '.sig', destination)
            path = destination / filename
            fields_of[role] = verify_archive(home, path, entry, channel)
            payloads[role] = candidate_set.payload_paths(path)
            minimum = policy['minimum_versions'].get(entry['NAME'][0])
            require(minimum is None or candidate_set.vercmp(entry['VERSION'][0], minimum) >= 0,
                    f"{entry['NAME'][0]} {entry['VERSION'][0]} is below the minimum {minimum}")
            if group == 'runtime':
                revision_file = candidate_set.REVISION_FILES[role]
                if revision_file in payloads[role]:
                    revision = candidate_set.member(path, revision_file).decode().strip()
                    require(candidate_set.HEX40.fullmatch(revision) is not None,
                            f'{entry["NAME"][0]} carries a malformed source revision')
                    commits[role] = revision
    candidate_set.verify_payloads(payloads)
    names = {role: entry['NAME'][0] for role, _, entry in chosen}
    versions = {role: entry['VERSION'][0] for role, _, entry in chosen}
    require(versions['omarchy'] == versions['omarchy-settings'], 'mixed desktop versions')
    settings = names['omarchy-settings']
    require(any(re.split(r'[<>=]', d, maxsplit=1)[0] == settings
                and d in (settings, f"{settings}={versions['omarchy-settings']}",
                          f"{settings}={versions['omarchy-settings'].rsplit('-', 1)[0]}")
                for d in fields_of['omarchy'].get('depend', [])), 'the runtime does not depend on its settings package')
    _, apple = candidate_set.apple_list(destination / next(e['FILENAME'][0] for r, _, e in chosen if r == 'omarchy'))
    require({'omarchy-mac', 'omarchy-mac-boot'} <= {line.strip() for line in apple.splitlines()},
            'the Apple package list lacks the add-on or boot package')
    packages_record = [{'name': p['name'], 'version': p['version'], 'filename': p['filename'], 'sha256': p['sha256'],
                        'group': p['group'], 'origin': 'channel',
                        **({'role': p['role']} if 'role' in p else {}),
                        **({'source_commit': commits[p['role']]} if p.get('role') in commits else {})}
                       for p in record['packages']]
    summary = {
        'schema': 1,
        'kind': 'channel',
        'set': f'omarchy-{lane}-{database_sha256[:12]}',
        'candidate_only': False,
        'channel': lane,
        'source_commit': None,
        'signer': channel['primary_fingerprint'],
        'database_sha256': database_sha256,
        'manifest_sha256': hashlib.sha256(text.encode()).hexdigest(),
        'set_sha256': candidate_set.set_digest(record),
        'packages': packages_record,
    }
    (destination / 'import.json').write_text(json.dumps(summary, indent=2, sort_keys=True) + '\n')
    for path in destination.iterdir():
        path.chmod(0o444)
    destination.chmod(0o555)
    return summary


def describe(database, lane, packages, trust=TRUST):
    """Verifies the set in a scratch copy and prints the values an inputs record pins."""
    with tempfile.TemporaryDirectory(prefix='channel-describe-') as scratch:
        summary = snapshot(database, digest(database), lane, packages, Path(scratch) / 'set', trust)
        for path in (Path(scratch) / 'set').iterdir():
            path.chmod(0o644)
        (Path(scratch) / 'set').chmod(0o755)
    return summary


def verify_installed(database, database_sha256, records, cache, trust=TRUST):
    """Every package RECORDS (package_record.py's lines) traces to the channel repository is the
    pinned DATABASE's archive in CACHE, signed by the channel key alone. Returns how many."""
    policy, channel = load_policy(trust)
    require(digest(database) == database_sha256, 'the channel database changed since it was pinned')
    entries = read_database(database)
    count = 0
    with tempfile.TemporaryDirectory(prefix='channel-trust-') as temporary:
        home = Path(temporary)
        keyring(home, trust, channel)
        for line in records.read_text().splitlines():
            name, version, repository, filename, sha256 = line.split('|')
            if repository != channel['repository']:
                continue
            entry = entries.get(name)
            require(entry is not None and entry['VERSION'] == [version] and entry['FILENAME'] == [filename]
                    and entry['SHA256SUM'] == [sha256], f'{name} {version} is not the pinned channel database\'s')
            path = cache / filename
            require(path.is_file() and not path.is_symlink(), f'{filename} is not in the package cache')
            verify_archive(home, path, entry, channel)
            count += 1
    return count


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    commands = parser.add_subparsers(dest='command', required=True)
    listed = commands.add_parser('files')
    imported = commands.add_parser('import')
    described = commands.add_parser('describe')
    installed = commands.add_parser('verify-installed')
    for command in (listed, imported, described, installed):
        command.add_argument('--db', type=Path, required=True)
    for command in (listed, imported, described):
        command.add_argument('--lane', required=True)
    for command in (imported, described):
        command.add_argument('--packages', type=Path, required=True)
    for command in (imported, installed):
        command.add_argument('--db-sha256', required=True)
    imported.add_argument('--output', type=Path, required=True)
    installed.add_argument('--records', type=Path, required=True)
    installed.add_argument('--cache', type=Path, required=True)
    args = parser.parse_args(argv)
    try:
        if args.command == 'files':
            print('\n'.join(files(args.db, args.lane)))
            return 0
        if args.command == 'verify-installed':
            count = verify_installed(args.db, args.db_sha256, args.records, args.cache)
            print(f'verified={count}')
            return 0
        if args.command == 'import':
            summary = snapshot(args.db, args.db_sha256, args.lane, args.packages, args.output)
        else:
            summary = describe(args.db, args.lane, args.packages)
    except (ValueError, OSError, KeyError, TypeError, subprocess.CalledProcessError, json.JSONDecodeError) as error:
        print(f'channel_set: {error}', file=sys.stderr)
        return 1
    for key in ('set', 'signer', 'database_sha256', 'manifest_sha256', 'set_sha256'):
        print(f'{key}={summary[key]}')
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
