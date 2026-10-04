"""Verify the installed app and compare a real changed build's identity."""
import hashlib
import json
from pathlib import Path
import plistlib
import re
import subprocess

ROOT=Path(__file__).resolve().parents[3]
IDENTIFIER='com.benpham.livestems'
EXECUTABLE='LiveStems'
PACKAGE_TYPE='APPL'
CANDIDATES=(Path('/Applications/Live Stems.app'), Path.home()/'Applications/Live Stems.app',
            ROOT/'outputs/Live Stems.app')
OUT=ROOT/'outputs/live-stems-acceptance'

def bundle_metadata(path):
    info_path=path/'Contents/Info.plist'
    settings_path=path/'Contents/Resources/local.json'
    with info_path.open('rb') as stream:
        info=plistlib.load(stream)
    settings=json.loads(settings_path.read_text())
    root=settings.get('root')
    if not isinstance(root,str) or not root:
        raise ValueError('local.json has no string root')
    resolved_root=Path(root).expanduser().resolve()
    if info.get('CFBundleIdentifier') != IDENTIFIER:
        raise ValueError('bundle identifier is not com.benpham.livestems')
    if info.get('CFBundleExecutable') != EXECUTABLE:
        raise ValueError('bundle executable is not LiveStems')
    if info.get('CFBundlePackageType') != PACKAGE_TYPE:
        raise ValueError('bundle package type is not APPL')
    if resolved_root != ROOT.resolve():
        raise ValueError(f'local.json root is outside this workspace: {resolved_root}')
    executable_path=path/'Contents/MacOS'/EXECUTABLE
    if not executable_path.is_file():
        raise ValueError('bundle executable is missing')
    return {'bundle_identifier': info['CFBundleIdentifier'],
            'bundle_executable': info['CFBundleExecutable'],
            'bundle_package_type': info['CFBundlePackageType'],
            'workspace_root': str(resolved_root)}

def select_app():
    invalid=[]
    for path in CANDIDATES:
        if not path.is_dir() and not path.is_symlink():
            continue
        if path.is_symlink():
            invalid.append(f'{path}: symlink')
            continue
        try:
            metadata=bundle_metadata(path)
        except (OSError, ValueError, json.JSONDecodeError, plistlib.InvalidFileException) as error:
            invalid.append(f'{path}: {error}')
            continue
        return path, metadata
    if invalid:
        raise AssertionError('No validated Live Stems bundle; existing candidates failed: '
                             + '; '.join(invalid))
    raise AssertionError('No existing Live Stems bundle candidate')

APP, APP_METADATA=select_app()

def capture(args):
    p=subprocess.run(args,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,text=True,check=True)
    return p.stdout

def requirement(text):
    return next(line.strip().removeprefix('# ') for line in text.splitlines() if 'designated =>' in line)

def digest(text):
    return re.search(r'^CDHash=(.+)$',text,re.M).group(1)

def sha(path):
    h=hashlib.sha256()
    with path.open('rb') as f:
        for block in iter(lambda:f.read(1024*1024),b''):h.update(block)
    return h.hexdigest()

capture(['codesign','--verify','--strict',str(APP)])
current=capture(['codesign','-d','-r-',str(APP)])
details=capture(['codesign','-dvvv',str(APP)])
first=(OUT/'signed-first-requirement.txt').read_text()
previous=max((ROOT/'work').glob('live-stems-package.*/Previous.app'),key=lambda p:p.parent.stat().st_mtime)
first_details=capture(['codesign','-dvvv',str(previous)])
assert requirement(capture(['codesign','-d','-r-',str(previous)]))==requirement(first)
assert requirement(first)==requirement(current),'Changed build has a different permission identity'
assert 'cdhash' not in requirement(current),'App remains ad hoc signed'
assert 'identifier "com.benpham.livestems"' in requirement(current)
assert digest(details)!=digest(first_details),'A different signed build was not tested'
# Exercise the real installer failure path. It must reject before touching the app.
before=sha(APP/'Contents/MacOS/LiveStems')
import os
env=dict(os.environ,LIVE_STEMS_SIGNING_IDENTITY='invalid')
failure=subprocess.run(['bash',str(ROOT/'outputs/live-stems-source/script/build_and_run.sh'),'--build-only'],env=env,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,text=True)
assert failure.returncode==3 and 'not stopped or replaced' in failure.stdout
assert sha(APP/'Contents/MacOS/LiveStems')==before
report={'status':'pass','strict_signature':True,'stable_designated_requirement':True,
        'first_cdhash':digest(first_details),'changed_cdhash':digest(details),
        'previous_bundle':str(previous.relative_to(ROOT)),
        'selected_app':str(APP),'selected_bundle':APP_METADATA,
        'invalid_certificate_rejected_before_replacement':True,
        'capture_relaunch':'pending physical UI check','macos_may_require_initial_grant':True}
(OUT/'signing.json').write_text(json.dumps(report,indent=2)+'\n')
print('PASS strict signature, stable identity across a changed build, packaged source, and safe installer rejection')
