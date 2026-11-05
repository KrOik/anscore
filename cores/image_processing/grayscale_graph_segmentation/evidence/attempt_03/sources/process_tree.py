"""Bounded child launch. Windows children enter a kill-on-close job before resume."""
from __future__ import annotations
import os
import signal
import subprocess
import time


class WindowsJob:
    """Documented Job Object + suspended process + Toolhelp primary-thread resume."""
    def __init__(self) -> None:
        import ctypes as c
        from ctypes import wintypes as w
        self.c,self.w = c,w
        self.k = c.WinDLL('kernel32',use_last_error=True)
        class Basic(c.Structure):
            _fields_=[('process_time',c.c_int64),('job_time',c.c_int64),('flags',w.DWORD),
                      ('min_ws',c.c_size_t),('max_ws',c.c_size_t),('active',w.DWORD),
                      ('affinity',c.c_size_t),('priority',w.DWORD),('scheduling',w.DWORD)]
        class IO(c.Structure):
            _fields_=[(name,c.c_uint64) for name in ('read_ops','write_ops','other_ops','read_bytes','write_bytes','other_bytes')]
        class Extended(c.Structure):
            _fields_=[('basic',Basic),('io',IO),('process_mem',c.c_size_t),('job_mem',c.c_size_t),
                      ('peak_process',c.c_size_t),('peak_job',c.c_size_t)]
        class Thread(c.Structure):
            _fields_=[('size',w.DWORD),('usage',w.DWORD),('tid',w.DWORD),('pid',w.DWORD),
                      ('base',w.LONG),('delta',w.LONG),('flags',w.DWORD)]
        self.Thread = Thread
        self.k.CreateJobObjectW.argtypes=[c.c_void_p,w.LPCWSTR]
        self.k.CreateJobObjectW.restype=w.HANDLE
        self.k.SetInformationJobObject.argtypes=[w.HANDLE,c.c_int,c.c_void_p,w.DWORD]
        self.k.SetInformationJobObject.restype=w.BOOL
        self.k.AssignProcessToJobObject.argtypes=[w.HANDLE,w.HANDLE]
        self.k.AssignProcessToJobObject.restype=w.BOOL
        self.k.TerminateJobObject.argtypes=[w.HANDLE,w.UINT]
        self.k.TerminateJobObject.restype=w.BOOL
        self.k.CloseHandle.argtypes=[w.HANDLE]
        self.k.CloseHandle.restype=w.BOOL
        self.k.CreateToolhelp32Snapshot.argtypes=[w.DWORD,w.DWORD]
        self.k.CreateToolhelp32Snapshot.restype=w.HANDLE
        self.k.Thread32First.argtypes=[w.HANDLE,c.POINTER(Thread)]
        self.k.Thread32First.restype=w.BOOL
        self.k.Thread32Next.argtypes=[w.HANDLE,c.POINTER(Thread)]
        self.k.Thread32Next.restype=w.BOOL
        self.k.OpenThread.argtypes=[w.DWORD,w.BOOL,w.DWORD]
        self.k.OpenThread.restype=w.HANDLE
        self.k.ResumeThread.argtypes=[w.HANDLE]
        self.k.ResumeThread.restype=w.DWORD
        self.handle=self.k.CreateJobObjectW(None,None)
        if not self.handle:
            raise c.WinError(c.get_last_error())
        limits=Extended()
        limits.basic.flags=0x2000  # JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE; no breakaway.
        if not self.k.SetInformationJobObject(self.handle,9,c.byref(limits),c.sizeof(limits)):
            error=c.WinError(c.get_last_error());self.close();raise error

    def attach_and_resume(self,process: subprocess.Popen,deadline: float) -> None:
        c,k=self.c,self.k
        if not k.AssignProcessToJobObject(self.handle,int(process._handle)):
            raise c.WinError(c.get_last_error())
        snapshot=k.CreateToolhelp32Snapshot(0x00000004,0)  # TH32CS_SNAPTHREAD
        if snapshot == c.c_void_p(-1).value:
            raise c.WinError(c.get_last_error())
        threads=[]
        try:
            entry=self.Thread();entry.size=c.sizeof(entry)
            ok=k.Thread32First(snapshot,c.byref(entry))
            while ok:
                if entry.pid == process.pid:
                    threads.append(entry.tid)
                ok=k.Thread32Next(snapshot,c.byref(entry))
        finally:
            k.CloseHandle(snapshot)
        if len(threads)!=1:
            raise RuntimeError(f'suspended child has {len(threads)} threads, expected one')
        thread=k.OpenThread(0x0002,False,threads[0])  # THREAD_SUSPEND_RESUME
        if not thread:
            raise c.WinError(c.get_last_error())
        try:
            if time.monotonic() >= deadline:
                raise subprocess.TimeoutExpired(process.args,20)
            if k.ResumeThread(thread)==0xffffffff:
                raise c.WinError(c.get_last_error())
        finally:
            k.CloseHandle(thread)

    def close(self) -> None:
        if self.handle:
            handle=self.handle
            if not self.k.CloseHandle(handle):
                error=self.c.WinError(self.c.get_last_error())
                # Retain the handle until closure succeeds; explicitly kill on
                # this exceptional path even when the first close call failed.
                self.k.TerminateJobObject(handle,1)
                if self.k.CloseHandle(handle):
                    self.handle=None
                raise error
            self.handle=None


def execute(argv: list[str],cwd,env: dict,hard_seconds: int=20) -> dict:
    start=time.monotonic()
    child=None;job=None
    output,error=b'',b''
    timed_out=False;failure=None;cleanup={}
    try:
        launch=dict(cwd=cwd,env=env,stdin=subprocess.DEVNULL,stdout=subprocess.PIPE,
                    stderr=subprocess.PIPE,executable=argv[0])
        if os.name=='nt':
            job=WindowsJob()
            # Assignment occurs while the sole primary thread remains suspended.
            launch['creationflags']=0x00000004|subprocess.CREATE_NEW_PROCESS_GROUP|subprocess.CREATE_NO_WINDOW
        else:
            launch['start_new_session']=True
        child=subprocess.Popen(argv,**launch)
        if job:
            job.attach_and_resume(child,start+hard_seconds)
        remaining=hard_seconds-(time.monotonic()-start)
        if remaining<=0:
            raise subprocess.TimeoutExpired(argv,hard_seconds)
        output,error=child.communicate(timeout=remaining)
    except subprocess.TimeoutExpired as exc:
        timed_out=True;failure='hard20s process-tree timeout'
        output,error=exc.output or b'',exc.stderr or b''
    except Exception as exc:
        failure=f'{type(exc).__name__}: {exc}'
    finally:
        if job:
            try:
                job.close();cleanup['windows_kill_on_close_job_closed']=True
            except Exception as exc:
                cleanup['job_close_error']=str(exc)
                failure=failure or 'Job Object cleanup failed'
        elif child and (failure or child.poll() is None):
            try:
                os.killpg(child.pid,signal.SIGKILL)
                cleanup['posix_process_group_killed']=True
            except ProcessLookupError:
                pass
            except Exception as exc:
                cleanup['killpg_error']=str(exc)
                failure=failure or 'process-group cleanup failed'
        if child and failure:
            if child.poll() is None:
                try:
                    child.kill();cleanup['parent_kill_sent']=True
                except Exception as exc:
                    cleanup['parent_kill_error']=str(exc)
            try:
                output,error=child.communicate(timeout=3)
            except subprocess.TimeoutExpired as exc:
                output,error=exc.output or output,exc.stderr or error
                cleanup['bounded_drain_exhausted']=True
            except Exception as exc:
                cleanup['drain_error']=str(exc)
        if child:
            for pipe in (child.stdout,child.stderr):
                if pipe:
                    try: pipe.close()
                    except Exception as exc: cleanup.setdefault('pipe_close_errors',[]).append(str(exc))
    return dict(argv=argv,pid=child.pid if child else None,returncode=child.poll() if child else None,
                stdout=output,stderr=error,timed_out=timed_out,failure=failure,
                elapsed_seconds=round(time.monotonic()-start,6),process_tree_cleanup=cleanup)
