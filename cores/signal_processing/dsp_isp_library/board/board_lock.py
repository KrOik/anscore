"""Cooperative board lock: exclusive file at <repo>/.boardlock.

Multiple sessions may share the single Tang 20K DOCK.  Each holder writes
{pid, token, purpose, acquired_at, heartbeat_at} and refreshes
heartbeat_at while working.  A lock whose heartbeat is older than
STALE_SECONDS may be taken over (holder crashed or left without release).

Usage:
    lock = BoardLock(purpose='scale board test', output=out_dir)
    with lock:                     # waits up to `timeout` for acquisition
        ...board work...
"""
import json, os, secrets, threading, time
from pathlib import Path

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[2]
LOCK_PATH = ROOT / '.boardlock'
STALE_SECONDS = 90
HEARTBEAT_SECONDS = 10


class BoardLock:
    def __init__(self, purpose, output=None, timeout=120):
        self.path = LOCK_PATH
        self.owner = dict(pid=os.getpid(), token=secrets.token_hex(16),
                          purpose=purpose, output=str(output or ''),
                          acquired_at=time.time())
        self.timeout = timeout
        self._hb = None
        self.held = False

    # ------------------------------------------------------------
    def _read(self):
        try:
            return json.loads(self.path.read_text())
        except Exception:
            return None

    def _stale(self, rec):
        try:
            return (time.time() - float(rec.get('heartbeat_at',
                                               rec.get('acquired_at', 0)))
                    > STALE_SECONDS)
        except Exception:
            return True

    def acquire(self):
        deadline = time.time() + self.timeout
        while True:
            try:
                with self.path.open('x') as f:
                    json.dump(self.owner, f, indent=2)
                self.held = True
                self._start_heartbeat()
                return self
            except FileExistsError:
                rec = self._read()
                if rec is not None and not self._stale(rec):
                    if time.time() > deadline:
                        raise RuntimeError(
                            'board lock held by %s (pid=%s) since %s; '
                            'wait timeout' % (rec.get('purpose'),
                                              rec.get('pid'),
                                              rec.get('acquired_at')))
                    time.sleep(2)
                    continue
                # stale or unreadable lock: take over
                try:
                    self.path.unlink()
                except FileNotFoundError:
                    pass
                continue
            except Exception:
                raise

    def _start_heartbeat(self):
        def beat():
            while self.held:
                try:
                    rec = self._read()
                    if rec and rec.get('token') == self.owner['token']:
                        rec['heartbeat_at'] = time.time()
                        self.path.write_text(json.dumps(rec, indent=2))
                except Exception:
                    pass
                time.sleep(HEARTBEAT_SECONDS)
        self._hb = threading.Thread(target=beat, daemon=True)
        self._hb.start()

    def release(self):
        self.held = False
        if self._hb is not None:
            self._hb.join(timeout=HEARTBEAT_SECONDS + 2)
        try:
            rec = self._read()
            if rec and rec.get('token') == self.owner['token']:
                self.path.unlink()
        except FileNotFoundError:
            pass

    def __enter__(self):
        return self.acquire()

    def __exit__(self, *exc):
        self.release()
        return False
