#!/usr/bin/env python3
"""Exercise the actual built CLI and host; only close windows created by this run."""
import argparse
import json
import os
from pathlib import Path
import shlex
import subprocess
import tempfile
import time

parser = argparse.ArgumentParser()
parser.add_argument('app', type=Path)
args = parser.parse_args()
app = args.app.resolve()
cli = app / 'Contents/MacOS/foil'
output = Path(__file__).resolve().parents[1] / 'build/terminal-foil-verification'
output.mkdir(parents=True, exist_ok=True)
results = []
windows = []
boards = []


def check(name, condition):
    results.append({'check': name, 'passed': bool(condition)})
    print(f"{'PASS' if condition else 'FAIL'} {name}", flush=True)


def call(*command, data=None):
    invocation = [str(cli), *command, '--app', str(app), '--session', str(session)]
    run = subprocess.run(invocation, input=data, text=True, capture_output=True, timeout=40)
    reply = json.loads(run.stdout)
    results.append({'command': list(command), 'exit': run.returncode, 'response': reply})
    if bool(reply.get('error')) != bool(run.returncode):
        raise RuntimeError(f'Inconsistent CLI exit for {command[0]}')
    return reply


def wait_for(path):
    deadline = time.monotonic() + 10
    while time.monotonic() < deadline:
        if path.exists():
            return True
        time.sleep(.05)
    return False


with tempfile.TemporaryDirectory(prefix='fixture-', dir=output) as directory:
    root = Path(directory)
    session = root / 'credential.json'
    try:
        source = root / 'reference.md'
        source.write_text('# Native terminal verification\n')
        shown = call('show', str(source), '--incognito', '--request-id', 'probe-show')
        board = shown.get('board_id')
        if board:
            boards.append(board)
        check('existing show FILE works over shared control', shown.get('status') == 'ready' and board is not None)
        source.write_text('# Updated reference\n')
        updated = call('update', board, str(source), '--expected-revision', '1')
        check('existing update preserves board and increments revision', updated.get('board_id') == board and updated.get('revision') == 2)
        stdin = call('open', '--stdin', '--type', 'markdown', data='# Streamed Markdown\n' + 'x' * 100_000)
        if stdin.get('board_id'):
            boards.append(stdin['board_id'])
        check('bounded multi-read stdin Markdown', stdin.get('status') == 'ready')
        (root / '.zshrc').write_text('export HISTFILE=/dev/null\n')
        child = root / 'child'
        marker = root / 'started'
        version = root / 'opencode-version'
        ssh = root / 'ssh-config'
        ssh.write_text('Host foofoil-probe.invalid\n HostName example.invalid\n Port 2222\n User foofoil-probe\n')
        ssh_output = root / 'ssh-output'
        command = (f'/usr/bin/ssh -G -F {shlex.quote(str(ssh))} foofoil-probe.invalid > {shlex.quote(str(ssh_output))}\n'
                   f'sleep 60 &\nprintf "%s" $! > {shlex.quote(str(child))}\nprintf started > {shlex.quote(str(marker))}\n')
        opencode = Path.home() / '.opencode/bin/opencode'
        if opencode.is_file() and os.access(opencode, os.X_OK):
            command = f'{shlex.quote(str(opencode))} --version > {shlex.quote(str(version))}\n' + command
        created = call('terminal', 'create', '--title', 'Terminal verification', '--cwd', str(root), '--command', command,
                       '--incognito', '--env', f'ZDOTDIR={root}', '--request-id', 'probe-terminal')
        window = created.get('window', {})
        identifier = window.get('id')
        if not identifier:
            raise RuntimeError(f'Terminal creation failed: {created.get("error")}')
        windows.append(identifier)
        check('terminal created as running native session', window.get('terminal_state') == 'running')
        check('startup command ran in actual app', wait_for(marker))
        check('system SSH reads explicit config without connecting', ssh_output.exists() and 'port 2222' in ssh_output.read_text())
        if opencode.is_file():
            check('installed OpenCode executable runs outside sandbox', version.exists() and bool(version.read_text().strip()))
        duplicate = call('terminal', 'create', '--title', 'Terminal verification', '--cwd', str(root), '--command', command,
                         '--incognito', '--env', f'ZDOTDIR={root}', '--request-id', 'probe-terminal')
        check('retry does not create another session', duplicate.get('window', {}).get('id') == identifier)
        hidden = call('hide', identifier)
        check('hide preserves terminal identity', hidden.get('window', {}).get('visible') is False and hidden.get('window', {}).get('terminal_id') == window.get('terminal_id'))
        inspected = call('inspect', identifier)
        check('inspect excludes scripts and environment', 'terminal' not in inspected and 'environment' not in inspected.get('window', {}))
        opacity = call('set', identifier, 'opacity', '.85')
        check('window property modification uses native 10% rounding', opacity.get('window', {}).get('opacity') == .9)
        listed = call('list', '--scope', 'all')
        check('explicit general list contains terminal', any(x['id'] == identifier for x in listed.get('windows', [])))
        blocked = call('close', identifier, '--scope', 'all')
        check('busy close returns without GUI confirmation', blocked.get('error') == 'CONFIRMATION_REQUIRED')
        forced = call('close', identifier, '--scope', 'all', '--force')
        check('explicit force closes managed terminal', forced.get('error') is None)
        pid = int(child.read_text())
        deadline = time.monotonic() + 5
        while time.monotonic() < deadline:
            try:
                os.kill(pid, 0)
            except ProcessLookupError:
                break
            time.sleep(.05)
        else:
            check('managed background process exits', False)
        if time.monotonic() < deadline:
            check('managed background process exits', True)
        windows.remove(identifier)
        bash_marker = root / 'bash-started'
        bash = call('terminal', 'create', '--shell', '/bin/bash', '--cwd', str(root), '--incognito',
                    '--command', f'printf bash-ok > {shlex.quote(str(bash_marker))}', 
                    '--env', 'HISTFILE=/dev/null')
        bash_id = bash.get('window', {}).get('id')
        if bash_id:
            windows.append(bash_id)
        check('bash initialization runs inside native terminal', wait_for(bash_marker) and bash_marker.read_text() == 'bash-ok')
    except Exception as error:
        results.append({'exception': type(error).__name__, 'message': str(error)})
        check('verification completed', False)
    finally:
        for identifier in windows:
            call('close', identifier, '--scope', 'all', '--force')
        for board in boards:
            call('close', board)
        report = {'scope': 'actual development-signed non-sandboxed host and native CLI', 'results': results,
                  'failed': sum(x.get('passed') is False for x in results)}
        (output / 'results.json').write_text(json.dumps(report, ensure_ascii=False, indent=2) + '\n')
        print(f"Report: {output / 'results.json'}")
raise SystemExit(int(report['failed'] > 0))
