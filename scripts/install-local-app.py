#!/usr/bin/env python3
"""Validate, stage and replace only notchJP; restore the installed bundle on failure."""
import argparse
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import tempfile
import time
import uuid

BUNDLE_ID = 'com.ruban.notchi'
REGISTER = '/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister'

def bundle_info(path):
    with (path / 'Contents/Info.plist').open('rb') as stream:
        value = plistlib.load(stream)
    if value.get('CFBundleIdentifier') != BUNDLE_ID:
        raise ValueError('O aplicativo não é o notchJP esperado: ' + str(path))
    return value

class MacRuntime:
    def validate(self, path):
        info = bundle_info(path)
        executable = info.get('CFBundleExecutable', '')
        if not executable or Path(executable).name != executable or not (path / 'Contents/MacOS' / executable).is_file():
            raise ValueError('Executável inválido')
        subprocess.run(['codesign', '--verify', '--deep', '--strict', str(path)], check=True)
    def stop(self):
        # A normal quit gives the application a chance to release its resources.
        processes = subprocess.check_output(['pgrep', '-x', 'notchi'], text=True) if subprocess.run(['pgrep', '-x', 'notchi'], stdout=subprocess.DEVNULL).returncode == 0 else ''
        if processes:
            subprocess.run(['osascript', '-e', 'tell application id "com.ruban.notchi" to quit'], check=True)
            for _ in range(50):
                if subprocess.run(['pgrep', '-x', 'notchi'], stdout=subprocess.DEVNULL).returncode != 0:
                    return
                time.sleep(0.1)
            raise RuntimeError('O notchJP não fechou; instalação cancelada.')
    def launch(self, path):
        self.register(path)
        subprocess.run(['open', str(path)], check=True)
        executable = str(path / 'Contents/MacOS' / bundle_info(path)['CFBundleExecutable'])
        for _ in range(30):
            processes = subprocess.check_output(['ps', '-Ao', 'comm='], text=True).splitlines()
            if executable in [line.strip() for line in processes]:
                time.sleep(2)
                if executable in subprocess.check_output(['ps', '-Ao', 'comm='], text=True):
                    return
            time.sleep(0.2)
        raise RuntimeError('A nova versão não permaneceu aberta.')
    def unregister(self, path):
        subprocess.run([REGISTER, '-u', str(path)], check=False)
    def register(self, path):
        subprocess.run([REGISTER, '-f', str(path)], check=True)
    def trash(self, path):
        trash = Path.home() / '.Trash'
        trash.mkdir(exist_ok=True)
        target = trash / (path.stem + '-duplicado-' + uuid.uuid4().hex[:8] + '.app')
        shutil.move(str(path), str(target))
        return target

def duplicate_candidates(destination, source=None):
    """Only app bundles in known installation/build locations; never user data."""
    home = Path.home()
    repo = Path(__file__).resolve().parent.parent
    candidates = set()
    for directory in [destination.parent, home / 'Applications']:
        if directory.exists():
            candidates.update(directory.glob('*.app'))
    for directory in [repo / 'build', home / 'Library/Caches/Notchi']:
        if directory.exists():
            candidates.update(directory.rglob('*.app'))
    # Old validation builds created by local Claude jobs.
    candidates.update((home / '.claude/jobs').glob('*/tmp/dd/Build/Products/*/*.app'))
    if source:
        candidates.add(source)
    return candidates

def cleanup_duplicates(destination, candidates, runtime=None):
    runtime = runtime or MacRuntime()
    runtime.validate(destination)
    keep = destination.resolve()
    removed = []
    for path in sorted(set(candidates)):
        if path.is_symlink() or path.resolve() == keep or not path.is_dir():
            continue
        # Never relocate an ancestor of the retained application.
        if path.resolve() in keep.parents:
            continue
        try:
            bundle_info(path)
        except (OSError, ValueError, plistlib.InvalidFileException):
            continue
        runtime.unregister(path)
        runtime.trash(path)
        removed.append(path)
    runtime.register(destination)
    return removed

def unregister_build(path, runtime=None):
    """Scheme post-action: build products must not become installed-app entries."""
    runtime = runtime or MacRuntime()
    if path.resolve().parent in [Path('/Applications'), Path.home() / 'Applications']:
        return
    if path.exists():
        bundle_info(path)
        runtime.unregister(path)

def install(source, destination, runtime=None):
    runtime = runtime or MacRuntime()
    runtime.validate(source)
    if destination.exists():
        bundle_info(destination)
    legacy = destination.parent / 'notchi.app'
    old = destination if destination.exists() else (legacy if legacy.exists() else None)
    if old:
        bundle_info(old)
    stage = Path(tempfile.mkdtemp(prefix='.notchjp-install-', dir=destination.parent))
    candidate, backup = stage / 'candidate.app', stage / 'previous.app'
    committed = False
    try:
        shutil.copytree(source, candidate, symlinks=True)
        runtime.validate(candidate)
        runtime.stop()
        if old:
            old.rename(backup)
        try:
            candidate.rename(destination)
            runtime.launch(destination)
        except Exception:
            runtime.stop()
            if destination.exists():
                shutil.rmtree(destination)
            if backup.exists():
                backup.rename(old)
                runtime.launch(old)
            raise
        committed = True
        if old and old != destination:
            runtime.unregister(old)
    finally:
        # If rollback itself failed, keep the only remaining previous version for recovery.
        if backup.exists() and not destination.exists() and old and not old.exists():
            backup.rename(old)
        if not backup.exists() or committed:
            shutil.rmtree(stage)
    if committed:
        cleanup_duplicates(destination, duplicate_candidates(destination, source), runtime)

if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('source', type=Path, nargs='?')
    parser.add_argument('--destination', type=Path, default=Path('/Applications/notchJP.app'))
    parser.add_argument('--cleanup-only', action='store_true')
    parser.add_argument('--unregister-build', type=Path)
    args = parser.parse_args()
    if args.unregister_build:
        unregister_build(args.unregister_build)
    elif args.cleanup_only:
        removed = cleanup_duplicates(args.destination, duplicate_candidates(args.destination))
        print('Cópias duplicadas movidas para a Lixeira:', len(removed))
    elif args.source:
        install(args.source, args.destination)
        print('notchJP instalado e aberto com sucesso; cópia única mantida.')
    else:
        parser.error('Informe o app de origem ou --cleanup-only.')
