#!/usr/bin/env python3
"""Write the licence texts of every crate compiled into windrose-heal.exe.

windrose-heal.exe links its Rust dependencies statically, and most of their licences
(MIT, BSD, Apache-2.0, Zlib) ask that their notices travel with the binary. This reads
`cargo metadata` for the release target, follows only normal (not build or dev)
dependencies from the windrose-heal package, and writes each crate's own licence files.
Crates whose licence files are the same text are listed together under one copy.

Usage:
  python scripts/third-party-licenses.py tools/windrose-heal/Cargo.toml \
      x86_64-pc-windows-msvc tools/windrose-heal/THIRD-PARTY-LICENSES.txt

Fails (exit 1) when a crate has no licence file and no licence field, so a new
dependency cannot ship without its notice.
"""

import hashlib
import json
import os
import re
import subprocess
import sys

LICENSE_NAME = re.compile(r'^(licen[cs]e|copying|notice|unlicense|copyright)([-_.].*)?$', re.IGNORECASE)


def vendored_licence_files(crate_dir, depth=3, limit=20):
    # A -sys crate builds C libraries it carries in sub-folders (librocksdb-sys: rocksdb and snappy; lz4-sys: liblz4;
    # zstd-sys: zstd), and their licences travel with the program too.
    found = []
    for here, dirs, files in os.walk(crate_dir):
        rel = os.path.relpath(here, crate_dir)
        level = 0 if rel == '.' else rel.count(os.sep) + 1
        dirs[:] = sorted(d for d in dirs if not d.startswith('.') and d.lower() not in ('tests', 'test', 'examples', 'doc', 'docs', 'benches', 'target', 'contrib', 'java'))
        if level >= depth:
            dirs[:] = []
        if level == 0:
            continue
        for name in sorted(files):
            if LICENSE_NAME.match(name):
                found.append((rel.replace(os.sep, '/') + '/' + name))
                if len(found) >= limit:
                    return found
    return found


def licence_files(crate_dir, licence_file_field, sys_crate=False):
    found = []
    if licence_file_field:
        p = os.path.join(crate_dir, licence_file_field)
        if os.path.isfile(p):
            found.append(licence_file_field.replace('\\', '/'))
    try:
        top = sorted(os.listdir(crate_dir))
    except OSError:
        return found
    for name in top:
        if LICENSE_NAME.match(name) and os.path.isfile(os.path.join(crate_dir, name)) and name not in found:
            found.append(name)
    if sys_crate or not found:
        found += [f for f in vendored_licence_files(crate_dir) if f not in found]
    return found


def read_text(path):
    with open(path, 'rb') as f:
        data = f.read()
    text = data.decode('utf-8', errors='replace').replace('\r\n', '\n').replace('\r', '\n')
    return text.strip('\n') + '\n'


def main(argv):
    if len(argv) != 4:
        print(__doc__, file=sys.stderr)
        return 2
    manifest, target, out_path = argv[1], argv[2], argv[3]
    meta = json.loads(subprocess.run(
        ['cargo', 'metadata', '--format-version', '1', '--locked', '--filter-platform', target,
         '--manifest-path', manifest],
        check=True, stdout=subprocess.PIPE).stdout)
    packages = {p['id']: p for p in meta['packages']}
    nodes = {n['id']: n for n in meta['resolve']['nodes']}
    root = meta['resolve']['root']
    if root is None:
        print('cargo metadata has no root package', file=sys.stderr)
        return 1

    seen = set()
    stack = [root]
    while stack:
        node_id = stack.pop()
        if node_id in seen:
            continue
        seen.add(node_id)
        for dep in nodes[node_id]['deps']:
            if any(kind['kind'] is None for kind in dep['dep_kinds']):
                stack.append(dep['pkg'])
    seen.discard(root)

    crates = []
    problems = []
    for pkg_id in seen:
        pkg = packages[pkg_id]
        crate_dir = os.path.dirname(pkg['manifest_path'])
        files = licence_files(crate_dir, pkg.get('license_file'), pkg['name'].endswith('-sys'))
        texts = [(f, read_text(os.path.join(crate_dir, f))) for f in files]
        licence = pkg.get('license') or ''
        if not texts and not licence:
            problems.append(f"{pkg['name']} {pkg['version']}")
        crates.append({
            'name': pkg['name'],
            'version': pkg['version'],
            'license': licence or 'see the licence text',
            'repository': pkg.get('repository') or '',
            'texts': texts,
        })
    if problems:
        print('no licence file and no licence field: ' + ', '.join(sorted(problems)), file=sys.stderr)
        return 1
    crates.sort(key=lambda c: (c['name'].lower(), c['version']))

    # One copy of each distinct licence text, with every crate that ships it (the Apache-2.0 text alone is in about 40
    # crates; MIT texts differ by their copyright lines and each is kept).
    texts = {}
    for c in crates:
        for name, text in c['texts']:
            key = hashlib.sha256(text.encode('utf-8')).hexdigest()
            entry = texts.setdefault(key, {'text': text, 'crates': []})
            entry['crates'].append(f"{c['name']} {c['version']} ({name})")

    lines = [
        'Third-party licences: windrose-heal.exe',
        '=' * 39,
        '',
        f'windrose-heal.exe is built from tools/windrose-heal and links the {len(crates)} Rust crates below',
        f'into the program ({target}). Below the list, each distinct licence text appears once,',
        'headed by the crates (and their file names) that carry it.',
        '',
        'Crates',
        '------',
        '',
    ]
    for c in crates:
        repo = f"  {c['repository']}" if c['repository'] else ''
        lines.append(f"{c['name']} {c['version']}  ({c['license']}){repo}")
        if not c['texts']:
            lines.append('    (no licence file in the crate; the licence named above applies)')
    lines.append('')
    for entry in sorted(texts.values(), key=lambda e: e['crates'][0].lower()):
        lines.append('-' * 78)
        for i in range(0, len(entry['crates']), 3):
            lines.append(', '.join(entry['crates'][i:i + 3]))
        lines.append('')
        lines.append(entry['text'].rstrip('\n'))
        lines.append('')
    with open(out_path, 'w', encoding='utf-8', newline='\r\n') as f:
        f.write('\n'.join(lines))
    print(f'{out_path}: {len(crates)} crates, {len(texts)} distinct licence texts')
    return 0


if __name__ == '__main__':
    sys.exit(main(sys.argv))
