#!/usr/bin/env python3
"""Build a relocatable Apple Silicon app and DMG without installing or launching it."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import shutil
import subprocess
import tarfile

PACKAGE = Path(__file__).resolve().parents[1]

def run(*args, **kwargs):
    return subprocess.run(list(map(str, args)), check=True, timeout=kwargs.pop('timeout', 180), **kwargs)

def output(*args):
    return run(*args, capture_output=True, text=True).stdout

def macho(path):
    if path.is_symlink() or not path.is_file(): return False
    with path.open('rb') as f: magic = f.read(4)
    return magic in (b'\xcf\xfa\xed\xfe', b'\xce\xfa\xed\xfe', b'\xca\xfe\xba\xbe', b'\xbe\xba\xfe\xca')

def audit(app):
    report = []
    for path in app.rglob('*'):
        if path.is_symlink():
            if not path.resolve().is_relative_to(app.resolve()):
                raise ValueError(f'External symlink in app: {path}')
        if not macho(path): continue
        build = output('vtool', '-show-build', path)
        versions = re.findall(r'\bminos\s+(\d+)\.(\d+)', build)
        if not versions: versions = re.findall(r'\bversion\s+(\d+)\.(\d+)', output('otool','-l',path))[:1]
        if not versions or any(tuple(map(int,v)) > (14,2) for v in versions):
            raise ValueError(f'Binary exceeds macOS 14.2 or has no target: {path}\n{build}')
        rpaths=re.findall(r'cmd LC_RPATH\s+cmdsize \d+\s+path (.*?) \(offset',output('otool','-l',path))
        if any(r.startswith('/') and not r.startswith(('/usr/lib/','/System/Library/')) for r in rpaths):
            raise ValueError(f'External runtime search path in {path}: {rpaths}')
        deps = output('otool','-L',path)
        for line in deps.splitlines()[1:]:
            dep = line.strip().split(' (')[0]
            if dep.startswith('/') and not dep.startswith(('/System/Library/','/usr/lib/')):
                raise ValueError(f'External dependency in {path}: {dep}')
        report.append({'path':str(path.relative_to(app)), 'minimum_versions':versions,'rpaths':rpaths})
    return report

def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output',required=True,type=Path,help='Fresh output folder')
    parser.add_argument('--python',required=True,type=Path,help='Relocatable CPython 3.12 prefix, such as uv python dir')
    parser.add_argument('--wheels',required=True,type=Path,help='Wheels matching packaging/runtime-lock.json')
    parser.add_argument('--models',required=True,type=Path)
    parser.add_argument('--identity',default='-',help='Code-signing identity; default ad hoc for local preview')
    parser.add_argument('--binary',type=Path,help='Existing release binary; default builds the package')
    parser.add_argument('--skip-dmg',action='store_true',help='Build app only')
    args=parser.parse_args()
    dest=args.output.resolve()
    if dest.exists(): parser.error('Output already exists; choose a fresh folder.')
    if not (args.python/'bin/python3.12').is_file(): parser.error('CPython 3.12 prefix is missing.')
    lock=json.loads((PACKAGE/'packaging/runtime-lock.json').read_text())
    wheels=[]
    for item in lock:
        path=args.wheels/item['filename']
        if hashlib.sha256(path.read_bytes()).hexdigest()!=item['sha256']:
            raise ValueError(f'Wheel digest mismatch: {path}')
        wheels.append(path)
    binary=args.binary
    if binary is None:
        run('swift','build','-c','release','--package-path',PACKAGE,timeout=600)
        binary=Path(output('swift','build','-c','release','--package-path',PACKAGE,'--show-bin-path').strip())/'LiveStems'
    dest.mkdir(parents=True)
    volume='Live Stems'
    stage=dest/'Disk Image'
    app=stage/'Live Stems.app'
    resources=app/'Contents/Resources'
    (app/'Contents/MacOS').mkdir(parents=True)
    resources.mkdir()
    run('vtool','-set-build-version','macos','14.2',output('xcrun','--show-sdk-version').strip(),'-replace','-output',app/'Contents/MacOS/LiveStems',binary)
    info=plistlib.loads((PACKAGE/'Resources/Info.plist').read_bytes())
    info.update(CFBundleShortVersionString='0.2.0',CFBundleVersion='3')
    (app/'Contents/Info.plist').write_bytes(plistlib.dumps(info))
    shutil.copy2(PACKAGE/'Resources/LiveStems.icns',resources)
    shutil.copytree(PACKAGE/'worker',resources/'worker',ignore=shutil.ignore_patterns('__pycache__','*.pyc'))
    runtime=resources/'Runtime'
    shutil.copytree(args.python,runtime,symlinks=True,ignore=shutil.ignore_patterns('__pycache__','*.pyc','site-packages'))
    site=runtime/'lib/python3.12/site-packages'
    site.mkdir()
    # Wheel installation handles RECORD, data directories, and dependency metadata.
    run(args.python/'bin/python3.12','-m','pip','install','--no-deps','--no-index','--no-compile','--target',site,*wheels)
    models=resources/'Models'
    models.mkdir()
    for name in ['htdemucs','htdemucs_ft']:
        config=args.models/(name+'_config.json')
        weights=args.models/(name+'.safetensors')
        expected=json.loads(config.read_text())['safetensors_sha256']
        if hashlib.sha256(weights.read_bytes()).hexdigest()!=expected:
            raise ValueError(f'Model digest mismatch: {name}')
        shutil.copy2(config,models)
        shutil.copy2(weights,models)
    # demucs-mlx tolerates read-only caches and then rechecks the digest each launch.
    # Prevent its digest stamps from changing the signed app bundle.
    for path in models.iterdir(): path.chmod(0o444)
    models.chmod(0o555)
    shutil.copy2(PACKAGE/'LICENSE',resources/'LICENSE')
    (resources/'OPEN-SOURCE.txt').write_text('Live Stems: GPL-2.0-or-later.\nSource: https://github.com/benpham3206/live-stems\nRubber Band and libsamplerate notices: see included corresponding-source archive.\nPython and package licences are retained under Runtime/lib/python3.12 and *.dist-info.\nModels: Meta Demucs, MIT; see model licence included here.\n')
    shutil.copy2(PACKAGE/'packaging/DEMUCS-LICENSE',resources/'DEMUCS-LICENSE')
    # Keep dependency notices in the binary distribution, not just the source archive.
    notices=resources/'ThirdParty'
    notices.mkdir()
    for name in ['rubberband','libsamplerate']:
        vendor=PACKAGE/'Sources/PitchCore/vendor'/('rubberband-4.0.0' if name=='rubberband' else 'libsamplerate-0.2.2')
        for pattern in ['COPYING*','LICENSE*','AUTHORS*']:
            for path in vendor.glob(pattern):
                if path.is_file(): shutil.copy2(path,notices/(name+'-'+path.name))
    # uv rewrites the standalone Python dylib ID to its installed prefix.
    # Make every reference to that prefix relative before signing the copy.
    for path in runtime.rglob('*'):
        if not macho(path): continue
        if path.suffix == '.dylib':
            run('install_name_tool','-id','@loader_path/'+path.name,path)
        for line in output('otool','-L',path).splitlines()[1:]:
            dep=line.strip().split(' (')[0]
            if dep.startswith(str(args.python.resolve())+'/'):
                target=runtime/Path(dep).relative_to(args.python.resolve())
                if not target.is_file(): raise ValueError(f'Missing bundled dependency: {target}')
                replacement='@loader_path/'+os.path.relpath(target,path.parent)
                run('install_name_tool','-change',dep,replacement,path)
    # SwiftPM can leave a toolchain search path in an otherwise portable binary.
    executable=app/'Contents/MacOS/LiveStems'
    for rpath in re.findall(r'cmd LC_RPATH\s+cmdsize \d+\s+path (.*?) \(offset',output('otool','-l',executable)):
        if rpath.startswith('/') and not rpath.startswith(('/usr/lib/','/System/Library/')):
            run('install_name_tool','-delete_rpath',rpath,executable)
    report=audit(app)
    (dest/'binary-audit.json').write_text(json.dumps(report,indent=2)+'\n')
    # Sign leaf binaries before sealing the enclosing app. No --deep signing.
    for path in app.rglob('*'):
        if macho(path): run('codesign','--force','--sign',args.identity,path)
    run('codesign','--force','--sign',args.identity,app)
    run('codesign','--verify','--deep','--strict',app)
    run(runtime/'bin/python3.12','-I','-B','-c','import mlx.core, numpy, demucs_mlx; print("bundled runtime imports: ok")')
    # Include the complete current source alongside the app in the DMG.
    files=output('git','-C',PACKAGE,'ls-files','--cached','--others','--exclude-standard','-z').split('\0')
    source=stage/'Live Stems Source.tar.gz'
    with tarfile.open(source,'w:gz') as archive:
        for name in sorted(set(files)):
            path=PACKAGE/name
            if name and path.is_file(): archive.add(path,arcname='live-stems/'+name,recursive=False)
    if not args.skip_dmg:
        (stage/'Applications').symlink_to('/Applications')
        (stage/'.background').mkdir()
        run('swift',PACKAGE/'packaging/dmg-background.swift',stage/'.background/background.png')
        rw=dest/'layout.dmg'
        run('hdiutil','create','-size','1800m','-fs','HFS+','-volname',volume,'-srcfolder',stage,'-format','UDRW',rw,timeout=300)
        mount=dest/'Mounted'
        mount.mkdir()
        run('hdiutil','attach',rw,'-mountpoint',mount,'-nobrowse')
        try:
            # Hide the source archive before Finder computes icon placement.
            run('chflags','hidden',mount/'Live Stems Source.tar.gz')
            run('osascript',PACKAGE/'packaging/layout.applescript',mount,timeout=60)
        finally:
            run('hdiutil','detach',mount,timeout=60)
        dmg=dest/'Live Stems.dmg'
        run('hdiutil','convert',rw,'-format','UDZO','-imagekey','zlib-level=9','-o',dmg,timeout=300)
        run('hdiutil','verify',dmg,timeout=120)
    print(f'App ready: {app}\nLocal preview signing only. Public release requires Developer ID signing and notarization.')

if __name__=='__main__': main()
