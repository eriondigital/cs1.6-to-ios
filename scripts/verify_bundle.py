#!/usr/bin/env python3
"""
Sanity checks for the assembled CS16.app before it is signed and zipped:
  - every file the engine / YaPB will look for at runtime is present
  - every Mach-O is arm64 and built for the expected platform
  - every @rpath / @loader_path / @executable_path dependency resolves inside the bundle
  - the CS extras pack carries the YaPB waypoint graphs
Exits non-zero on hard failures.

usage: verify_bundle.py <path to CS16.app> [library arch suffix: arm64|amd64] [Mach-O arch: arm64|x86_64]
"""
import glob
import os
import subprocess
import sys
import zipfile

app = os.path.abspath(sys.argv[1])
libarch = sys.argv[2] if len(sys.argv) > 2 else 'arm64'
macho_arch = sys.argv[3] if len(sys.argv) > 3 else 'arm64'
errors, warnings = [], []


def run(*cmd):
    return subprocess.run(cmd, capture_output=True, text=True).stdout


def need(rel, what):
    path = os.path.join(app, rel)
    if os.path.exists(path):
        print(f'  [ok] {rel}')
    else:
        errors.append(f'missing {rel} ({what})')


print('Required files:')
need('xash', 'main executable')
need('Info.plist', 'bundle info')
need('SDL2.framework/SDL2', 'SDL2')
need('filesystem_stdio.dylib', 'engine filesystem, also loaded by ReGameDLL')
need(f'cstrike/cl_dlls/client_ios_{libarch}.dylib', 'CS client')
need(f'cstrike/cl_dlls/menu_ios_{libarch}.dylib', 'CS menu')
need(f'cstrike/dlls/yapb_ios_{libarch}.dylib', 'YaPB, loaded with -dll @yapb')
need(f'cstrike/dlls/cs_{libarch}.dylib', 'ReGameDLL, loaded by YaPB')
need('cstrike/extras.pk3', 'CS16 client extras: touch layouts, menu art, bot data')
need('valve/extras.pk3', 'engine extras: fonts, touch icons')

refs = sorted(os.path.basename(p) for p in glob.glob(os.path.join(app, 'libref_*.dylib')))
print(f'  renderers: {", ".join(refs) or "NONE"}')
if not refs:
    errors.append('no renderer libraries (libref_*.dylib)')

# ---- Mach-O checks
machos = []
for dirpath, dirnames, filenames in os.walk(app):
    for name in filenames:
        path = os.path.join(dirpath, name)
        with open(path, 'rb') as f:
            magic = f.read(4)
        if magic in (b'\xcf\xfa\xed\xfe', b'\xca\xfe\xba\xbe'):
            machos.append(path)

print(f'\nMach-O files: {len(machos)}')
for path in machos:
    rel = os.path.relpath(path, app)
    archs = run('lipo', '-archs', path).split()
    loadcmds = run('otool', '-l', path)

    platforms = set()
    lines = loadcmds.splitlines()
    rpaths = []
    for i, line in enumerate(lines):
        line = line.strip()
        if line.startswith('platform '):
            platforms.add(line.split()[1])
        if line == 'cmd LC_RPATH':
            for j in range(i + 1, min(i + 4, len(lines))):
                if lines[j].strip().startswith('path '):
                    rpaths.append(lines[j].strip().split()[1])

    deps = []
    for line in run('otool', '-L', path).splitlines()[1:]:
        line = line.strip()
        if line:
            deps.append(line.split(' (')[0])

    print(f'  {rel}: archs={",".join(archs)} platform={",".join(sorted(platforms)) or "?"} rpaths={rpaths}')
    if macho_arch not in archs:
        errors.append(f'{rel} has no {macho_arch} slice ({archs})')

    loader_dir = os.path.dirname(path)
    exec_dir = app
    for dep in deps:
        if dep.startswith(('/usr/lib/', '/System/')):
            continue
        candidates = []
        if dep.startswith('@rpath/'):
            for rp in rpaths:
                base = rp.replace('@loader_path', loader_dir).replace('@executable_path', exec_dir)
                candidates.append(os.path.join(base, dep[len('@rpath/'):]))
        elif dep.startswith('@loader_path/'):
            candidates.append(os.path.join(loader_dir, dep[len('@loader_path/'):]))
        elif dep.startswith('@executable_path/'):
            candidates.append(os.path.join(exec_dir, dep[len('@executable_path/'):]))
        else:
            candidates.append(dep)

        # a library's own install name shows up in otool -L as well
        if os.path.basename(dep) == os.path.basename(path):
            continue
        if not any(os.path.exists(c) for c in candidates):
            errors.append(f'{rel}: dependency {dep} does not resolve (rpaths {rpaths})')

# ---- extras content
pk3 = os.path.join(app, 'cstrike', 'extras.pk3')
if os.path.exists(pk3):
    names = zipfile.ZipFile(pk3).namelist()
    graphs = [n for n in names if n.endswith('.graph')]
    print(f'\ncstrike/extras.pk3: {len(names)} files, {len(graphs)} YaPB graphs')
    if not graphs:
        warnings.append('no YaPB waypoint graphs in extras.pk3, bots will build them on first map load')
    if 'touch.cfg' not in names:
        errors.append('touch.cfg not found in cstrike/extras.pk3 (touch controls)')
    leftovers = [n for n in names if n.startswith(('sound/', 'maps/', 'media/'))]
    if leftovers:
        errors.append(f'game content left in extras.pk3: {leftovers[:5]}')

for w in warnings:
    print(f'WARNING: {w}')
for e in errors:
    print(f'ERROR: {e}')

if errors:
    sys.exit(1)
print('\nBundle looks good.')
