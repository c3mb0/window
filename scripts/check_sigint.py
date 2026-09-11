#!/usr/bin/env python3
"""Real VM + PTY shutdown check. No user shells, browser, or network startup."""
import os
from pathlib import Path
import pty
import signal
import subprocess
import tempfile
import time
import select
ROOT = Path(__file__).resolve().parents[1]
HELPER = os.environ.get('CHECK_HELPER', str(ROOT / 'vendor/play/target/debug/pty_helper'))
def processes():
    rows = subprocess.check_output(['/bin/ps', '-axo', 'pid=,ppid='], text=True)
    return {int(a): int(b) for a,b in (line.split() for line in rows.splitlines())}
def descendants(root, rows):
    found = {root}
    while True:
        more = {pid for pid,parent in rows.items() if parent in found}
        if more <= found: return found
        found |= more
for delivery in ['pid', 'group']:
    with tempfile.TemporaryDirectory(prefix='window-sigint-') as temp:
        marker = Path(temp) / 'pids'
        master, slave = pty.openpty()
        env = {**os.environ, 'CHECK_HELPER': HELPER, 'CHECK_MARKER': str(marker), 'WINDOW_OPEN_BROWSER': '0', 'MIX_REBAR3': subprocess.check_output(['which','rebar3'],text=True).strip()}
        env.pop('WINDOW_SERVER', None)
        child = subprocess.Popen([str(ROOT / 'scripts/runtime'),'scripts/sigint_fixture.exs'],cwd=ROOT,env=env,stdin=slave,stdout=slave,stderr=slave,start_new_session=True)
        os.close(slave)
        owned = {child.pid}
        try:
            deadline = time.monotonic()+15
            while time.monotonic()<deadline:
                owned |= descendants(child.pid, processes())
                if select.select([master],[],[],.05)[0]:
                    try: os.read(master,65536)
                    except OSError: pass
                if marker.exists() and len(marker.read_text().splitlines())>=2:
                    # Observe the foreground child too, not only shell startup.
                    shell = int(marker.read_text().splitlines()[0])
                    rows = processes()
                    if len([p for p,parent in rows.items() if parent==shell]) >= 2:
                        owned |= descendants(child.pid, rows)
                        break
                if child.poll() is not None: raise AssertionError('fixture exited before readiness')
            else: raise AssertionError('fixture readiness deadline')
            assert len(owned)>=5, owned
            started=time.monotonic()
            if delivery=='pid': os.kill(child.pid,signal.SIGINT)
            else: os.killpg(child.pid,signal.SIGINT)
            os.close(master); master=None
            child.wait(timeout=2)
            while time.monotonic()-started<2 and owned & processes().keys(): time.sleep(.02)
            remaining=owned & processes().keys()
            assert not remaining, f'owned processes survived SIGINT: {sorted(remaining)}'
            print(f'PASS {delivery}: {len(owned)} owned processes absent in {time.monotonic()-started:.3f}s',flush=True)
        finally:
            if master is not None: os.close(master)
            # Explicit cleanup on failure, limited to this fixture's observed tree.
            for pid in owned:
                try: os.kill(pid,signal.SIGKILL)
                except ProcessLookupError: pass
            child.wait(timeout=3)
