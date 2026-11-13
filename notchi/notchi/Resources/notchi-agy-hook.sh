#!/bin/bash
# notchJP: forwards AGY (Antigravity CLI) lifecycle events to the notchJP app over a Unix socket.
# Usage (set by the installer in ~/.gemini/config/hooks.json): notchjp-agy-hook.sh <Event>
# The payload AGY sends on stdin is read and discarded: nothing you type or that the model
# answers leaves AGY. Only the event name, the AGY process id and its working directory are sent.

cat > /dev/null

SOCKET_PATH="$HOME/Library/Application Support/Notchi/notchi.sock"
[ -S "$SOCKET_PATH" ] && [ -O "$SOCKET_PATH" ] || exit 0
export NOTCHI_SOCKET_PATH="$SOCKET_PATH"
export NJP_AGY_EVENT="$1"

/usr/bin/python3 -I -c "
import json
import os
import socket
import subprocess

mapping = {
    'PreInvocation': ('UserPromptSubmit', 'processing'),
    'PreToolUse': ('PreToolUse', 'running_tool'),
    'PostToolUse': ('PostToolUse', 'processing'),
    'Stop': ('Stop', 'waiting_for_input'),
}
event = os.environ.get('NJP_AGY_EVENT', '')
if event not in mapping:
    raise SystemExit(0)

def process_table():
    try:
        out = subprocess.check_output(['/bin/ps', '-axo', 'pid=,ppid=,command='], text=True, timeout=1)
    except Exception:
        return {}
    table = {}
    for line in out.splitlines():
        parts = line.strip().split(None, 2)
        if len(parts) < 3 or not parts[0].isdigit() or not parts[1].isdigit():
            continue
        tokens = parts[2].split()
        table[int(parts[0])] = {
            'ppid': int(parts[1]),
            'argv0': os.path.basename(tokens[0]).lower() if tokens else '',
            'args': tokens[1:],
        }
    return table

def agy_process():
    table = process_table()
    pid = os.getppid()
    seen = set()
    for _ in range(8):
        info = table.get(pid)
        if info is None or pid in seen:
            return None, None
        seen.add(pid)
        if info['argv0'] == 'agy':
            return pid, info
        if info['ppid'] <= 1 or info['ppid'] == pid:
            return None, None
        pid = info['ppid']
    return None, None

def working_directory(pid):
    try:
        out = subprocess.check_output(['/usr/sbin/lsof', '-a', '-p', str(pid), '-d', 'cwd', '-Fn'], text=True, timeout=1)
        for line in out.splitlines():
            if line.startswith('n'):
                return line[1:]
    except Exception:
        pass
    return os.getcwd()

pid, info = agy_process()
# One-shot print mode (agy -p / --print) is not a session worth announcing.
if info and any(arg in ('-p', '--print', '--prompt') for arg in info['args']):
    raise SystemExit(0)

normalized, status = mapping[event]
output = {
    'provider': 'agy',
    'session_id': 'agy-%d' % (pid or os.getppid()),
    'cwd': working_directory(pid) if pid else os.getcwd(),
    'event': normalized,
    'status': status,
    'interactive': True,
}
if pid:
    output['agy_process_id'] = pid

try:
    sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    sock.connect(os.environ['NOTCHI_SOCKET_PATH'])
    sock.sendall(json.dumps(output).encode())
    sock.close()
except Exception:
    pass
"

exit 0
