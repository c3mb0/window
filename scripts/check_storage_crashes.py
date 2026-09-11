#!/usr/bin/env python3
"""Kill real SQLite/BEAM and DuckDB processes at commit boundaries in temp dirs."""
import json
import os
from pathlib import Path
import select
import signal
import sqlite3
import struct
import subprocess
import tempfile
import time

ROOT = Path(__file__).resolve().parents[1]
HELPER = ROOT / 'native/archive/target/debug/window-archive'

def line_until(stream, expected, timeout=30):
    deadline = time.monotonic() + timeout
    data = b''
    while time.monotonic() < deadline:
        if select.select([stream], [], [], .1)[0]:
            chunk = os.read(stream.fileno(), 4096)
            if not chunk: raise AssertionError(f'process exited before {expected}: {data[-1000:]}')
            data += chunk
            if expected in data: return
    raise AssertionError(f'timeout waiting for {expected}: {data[-1000:]}')

def send(child, request):
    data = json.dumps(request).encode()
    child.stdin.write(struct.pack('>I', len(data)) + data)
    child.stdin.flush()

def read_exact(stream, n, timeout=10):
    data = b''
    deadline = time.monotonic() + timeout
    while len(data) < n and time.monotonic() < deadline:
        if select.select([stream], [], [], .1)[0]:
            part = os.read(stream.fileno(), n-len(data))
            if not part: raise AssertionError('archive EOF')
            data += part
    assert len(data) == n, 'archive timeout'
    return data

def response(child):
    size, = struct.unpack('>I', read_exact(child.stdout, 4))
    return json.loads(read_exact(child.stdout, size))

def archive(directory, fault=None):
    env = {**os.environ}
    env.pop('WINDOW_ARCHIVE_TEST_FAULT', None)
    if fault: env['WINDOW_ARCHIVE_TEST_FAULT'] = fault
    return subprocess.Popen([str(HELPER), str(Path(directory)/'history.duckdb')],
        stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, env=env, bufsize=0)

for point, expected in [('before_sqlite_commit', 0), ('after_sqlite_commit', 1)]:
    with tempfile.TemporaryDirectory(prefix='window-storage-crash-') as directory:
        env = {**os.environ, 'WINDOW_SERVER': '0', 'WINDOW_OPEN_BROWSER': '0'}
        child = subprocess.Popen(['mix', 'run', '--no-start', 'scripts/storage_crash_fixture.exs', directory, point],
            cwd=ROOT, env=env, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, start_new_session=True)
        try:
            line_until(child.stdout, b'FAULT_READY')
        finally:
            os.killpg(child.pid, signal.SIGKILL)
            child.wait(timeout=5)
        db = sqlite3.connect(Path(directory)/'current.sqlite')
        assert db.execute('select count(*) from sessions').fetchone()[0] == expected
        assert db.execute('select count(*) from outbox').fetchone()[0] == expected
        if expected:
            db.row_factory = sqlite3.Row
            events = [dict(row) for row in db.execute('select * from outbox')]
            # Kill DuckDB while its transaction is open: no partial history commits.
            worker = archive(directory, 'before_commit')
            try:
                send(worker, {'op':'append', 'events':events})
                line_until(worker.stderr, b'FAULT_BEFORE_COMMIT')
            finally:
                worker.kill(); worker.wait(timeout=5)
            worker = archive(directory)
            try:
                send(worker, {'op':'status'})
                assert response(worker) == {'ok': {'events':0}}
                send(worker, {'op':'append', 'events':events})
                assert response(worker)['ok']['ids'] == [events[0]['id']]
            finally:
                # After DuckDB commit, before SQLite acknowledgment.
                worker.kill(); worker.wait(timeout=5)
            assert db.execute('select count(*) from outbox').fetchone()[0] == 1
            worker = archive(directory)
            try:
                send(worker, {'op':'append', 'events':events})
                assert response(worker)['ok']['ids'] == [events[0]['id']]
                send(worker, {'op':'status'})
                assert response(worker) == {'ok': {'events':1}}
                send(worker, {'op':'timeline', 'session_id':'session'})
                archived = response(worker)['ok']['events'][0]['payload']
                assert archived == db.execute('select payload from sessions').fetchone()[0]
            finally:
                worker.kill(); worker.wait(timeout=5)
        db.close()
        print(f'PASS: SIGKILL at {point}, state/outbox count={expected}', flush=True)
print('PASS: DuckDB pre-commit kill rolls back; post-commit/pre-ack kill retries without duplication')
