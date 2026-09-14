#!/usr/bin/env python3
"""Explicit, authenticated Codex compatibility lane; never part of unit tests."""
import argparse
import hashlib
import json
import os
import signal
from pathlib import Path
import shutil
import subprocess
import tempfile


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--model', default='gpt-6-astra', help='An installed model advertising async questions')
    modes = parser.add_mutually_exclusive_group()
    modes.add_argument('--remaining', action='store_true', help='Run only session approval, plan, prompt, and Stop probes')
    modes.add_argument('--edits', action='store_true', help='Run native file-change approvals in a read-only sandbox')
    modes.add_argument('--blocking', action='store_true', help='Run the legacy blocking-question probe in Plan mode')
    args = parser.parse_args()
    root = Path(__file__).resolve().parents[1]
    codex, tmux = shutil.which('codex'), shutil.which('tmux')
    if not codex or not tmux:
        parser.error('Install and authenticate Codex CLI, and install tmux, before running this lane.')
    print(subprocess.check_output([codex, '--version'], text=True).strip(), flush=True)
    print(f'Testing model {args.model} with disposable conversations and files.', flush=True)
    sources = [root / 'Flotilla/Services/Companion' / name for name in ('CodexCompanionAdapter.swift', 'ProviderRPC.swift')]
    sources.append(root / 'Scripts/Compatibility/CodexCompanionProbe.swift')
    with tempfile.TemporaryDirectory(prefix='flotilla-codex-probe-package-') as package:
        package = Path(package)
        target = package / 'Sources/Verify'
        target.mkdir(parents=True)
        for source in sources:
            shutil.copy2(source, target / source.name)
            print(f'{source.relative_to(root)} sha256={hashlib.sha256(source.read_bytes()).hexdigest()}', flush=True)
        (package / 'Package.swift').write_text('''// swift-tools-version: 6.2
import PackageDescription
let package = Package(name: "Verify", platforms: [.macOS(.v26)], dependencies: [
    .package(path: %s), .package(path: %s)
], targets: [.executableTarget(name: "Verify", dependencies: ["SessionKit", "CompanionKit"])])
''' % (json.dumps(str(root / 'Packages/SessionKit')), json.dumps(str(root / 'Packages/CompanionKit'))))
        artifact = Path(tempfile.mkdtemp(prefix='flotilla-codex-live-', dir='/tmp'))
        (artifact / 'metadata.json').write_text(json.dumps({'version': subprocess.check_output([codex, '--version'], text=True).strip(), 'model': args.model, 'sources': {str(source.relative_to(root)): hashlib.sha256(source.read_bytes()).hexdigest() for source in sources}}, indent=2))
        environment = dict(os.environ, FLOTILLA_VERIFY_CODEX=codex, FLOTILLA_VERIFY_TMUX=tmux, FLOTILLA_VERIFY_MODEL=args.model, FLOTILLA_VERIFY_ROOT=str(artifact))
        command = ['swift', 'run', '--package-path', str(package), 'Verify']
        if args.remaining:
            command.append('--remaining')
        if args.blocking:
            command.append('--blocking')
        if args.edits:
            command.append('--edits')
        child = subprocess.Popen(command, env=environment, start_new_session=True)
        try:
            return child.wait(timeout=1200)
        finally:
            if child.poll() is None:
                os.killpg(child.pid, signal.SIGTERM)
                try:
                    child.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    os.killpg(child.pid, signal.SIGKILL)
                    child.wait()
            socket = artifact / 'tmux-socket'
            if socket.exists():
                subprocess.run([tmux, '-L', socket.read_text(), 'kill-server'], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            (artifact / 'home/auth.json').unlink(missing_ok=True)


if __name__ == '__main__':
    raise SystemExit(main())
