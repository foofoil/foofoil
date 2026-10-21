#!/usr/bin/env python3
"""P0a feasibility gates. Evidence is retained even when a capability is blocked."""
import json
import os
from pathlib import Path
import socket
import subprocess
import tempfile
import time

ROOT = Path(__file__).resolve().parents[2]
OUTPUT = ROOT / 'build/terminal-control-prototype'
APP = OUTPUT / 'TerminalControlProbe.app'
CLIENT = OUTPUT / 'probe-client'
results = []


def call(action, path=None):
    command = [str(CLIENT), str(APP), action]
    if path is not None:
        command.append(str(path))
    run = subprocess.run(command, capture_output=True, text=True, timeout=20)
    if not run.stdout.strip():
        raise RuntimeError(f'{action}: no response: {run.stderr.strip()}')
    reply = json.loads(run.stdout)
    results.append({'action': action, 'response': reply})
    if run.returncode != (0 if reply['ok'] else 1):
        raise RuntimeError(f'{action}: unexpected exit {run.returncode}')
    return reply


def check(name, condition):
    results.append({'check': name, 'passed': bool(condition)})
    print(f"{'PASS' if condition else 'FAIL'} {name}", flush=True)


def wait_exit(pid):
    deadline = time.monotonic() + 5
    while time.monotonic() < deadline:
        try:
            os.kill(pid, 0)
        except ProcessLookupError:
            return
        time.sleep(.05)
    raise RuntimeError('Probe did not terminate')


def main():
    try:
        # 夹具位于仓库 build 下，不落在可默认读取的 Downloads 或共享系统临时目录。
        with tempfile.TemporaryDirectory(prefix='fixture-', dir=OUTPUT) as directory:
            source = Path(directory) / 'source.txt'
            source.write_text('generated fixture only\n')
            try:
                # 先退出旧原型，避免复用旧进程或旧的隐式文件授权。
                call('reset')
                stopped = call('quit')
                wait_exit(stopped['process'])
                baseline = subprocess.run([str(OUTPUT / 'pty-baseline'), '/bin/zsh', str(source)],
                                          capture_output=True, text=True, timeout=10)
                results.append({'baseline': baseline.stdout, 'exit': baseline.returncode})
                check('unconfined baseline supports foreground process group', 'PGRP_OK' in baseline.stdout)
                denied = call('path-only', source)
                check('path alone does not grant file access', not denied['ok'])
                before = call('shell', source)
                before_output = before.get('details', {}).get('output', '')
                check('PTY and interactive shell before file delivery', 'TTY_OK' in before_output)
                check('shell cannot bypass file authorization', 'FILE_DENIED' in before_output)
                check('sandbox zsh supports terminal foreground process group', 'PGRP_OK' in before_output)
                bash_baseline = subprocess.run([str(OUTPUT / 'pty-baseline'), '/bin/bash', str(source)],
                                              capture_output=True, text=True, timeout=10)
                results.append({'bash_baseline': bash_baseline.stdout, 'exit': bash_baseline.returncode})
                check('unconfined bash baseline supports foreground process group', 'PGRP_OK' in bash_baseline.stdout)
                bash_output = call('shell-bash', source).get('details', {}).get('output', '')
                check('sandbox bash supports terminal foreground process group', 'PGRP_OK' in bash_output)
                check('shell cannot write to ungranted directory', 'WRITE_DENIED' in before_output)
                started = call('socket-start')
                check('bind and listen with product Release sandbox', started['ok'])
                if started['ok']:
                    path = started['details']['path']
                    check('socket has private mode', os.stat(path).st_mode & 0o777 == 0o600)
                    check('socket directory has private mode', os.stat(Path(path).parent).st_mode & 0o777 == 0o700)
                    try:
                        with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as connection:
                            connection.settimeout(3)
                            connection.connect(path)
                            accepted = call('socket-poll')
                            check('same-user external client receives reply', connection.recv(32) == b'probe-ok\n')
                            check('server verifies peer uid', accepted.get('details', {}).get('peer_uid') == str(os.getuid()))
                    except OSError as error:
                        results.append({'socket_error': error.errno})
                        check('same-user external client receives reply', False)
                acquired = call('acquire', source)
                check('explicit file delivery grants host access', acquired['ok'])
                after = call('shell', source)
                output = after.get('details', {}).get('output', '')
                check('PTY and interactive shell after file delivery', 'TTY_OK' in output)
                check('delivered file is readable by shell', 'FILE_OK' in output)
                check('working directory is accessible to shell', 'CWD_OK' in output)
                call('hide')
                check('requests preserve hidden app state', all(call('status').get('hiddenAfter') for _ in range(3)))
                stopped = call('quit')
                wait_exit(stopped['process'])
                restored = call('restore')
                check('file bookmark restores in new process', restored['ok'] and restored['process'] != stopped['process'])
                check('explicit directory capability delivered', call('grant', Path(directory))['ok'])
                directory_shell = call('shell', source).get('details', {}).get('output', '')
                check('directory grant permits shell writes', 'WRITE_OK' in directory_shell)
                tool = OUTPUT / 'fixture-tool'
                check('explicit executable capability delivered', call('grant', tool)['ok'])
                tool_baseline = subprocess.run([str(OUTPUT / 'pty-baseline'), '/bin/zsh', str(tool), 'tool'],
                                              capture_output=True, text=True, timeout=10)
                results.append({'tool_baseline': tool_baseline.stdout, 'exit': tool_baseline.returncode})
                check('unconfined baseline runs external signed tool',
                      tool_baseline.returncode == 0 and 'fixture-tool 1' in tool_baseline.stdout)
                version = call('tool-version', tool).get('details', {})
                check('sandbox shell runs explicitly delivered external tool',
                      version.get('status') == '0' and 'fixture-tool 1' in version.get('output', ''))
            finally:
                try:
                    call('reset')
                finally:
                    stopped = call('quit')
                    wait_exit(stopped['process'])
    except Exception as error:
        results.append({'exception': type(error).__name__, 'message': str(error)})
        check('verification completes without tool error', False)
    finally:
        report = {'scope': 'development-signed standalone probe using product Release entitlements; not distribution acceptance',
                  'results': results, 'failed': sum(item.get('passed') is False for item in results)}
        (OUTPUT / 'results.json').write_text(json.dumps(report, indent=2) + '\n')
        print(f"Report: {OUTPUT / 'results.json'}")
    return int(report['failed'] > 0)


if __name__ == '__main__':
    raise SystemExit(main())
