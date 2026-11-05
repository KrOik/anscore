# SPDX-License-Identifier: Apache-2.0
# ANSCORE tree supervisor adapted from the original B28 matching runner.
# This new copy checks close/termination and surfaces bounded cleanup failure.
import ctypes,os,signal,subprocess,time,sys
if sys.flags.optimize:raise RuntimeError('optimized Python forbidden')

class WindowsJob:
    """Place a suspended child in a kill-on-close Job before any compiler code runs."""
    def __init__(self):
        from ctypes import wintypes as wt
        class Basic(ctypes.Structure):
            _fields_ = [('process_time', ctypes.c_int64), ('job_time', ctypes.c_int64),
                        ('flags', wt.DWORD), ('min_working_set', ctypes.c_size_t),
                        ('max_working_set', ctypes.c_size_t), ('active_limit', wt.DWORD),
                        ('affinity', ctypes.c_size_t), ('priority', wt.DWORD), ('scheduling', wt.DWORD)]
        class Io(ctypes.Structure):
            _fields_ = [(p, ctypes.c_uint64) for p in ['read_ops', 'write_ops', 'other_ops', 'read_bytes', 'write_bytes', 'other_bytes']]
        class Extended(ctypes.Structure):
            _fields_ = [('basic', Basic), ('io', Io), ('process_memory', ctypes.c_size_t),
                        ('job_memory', ctypes.c_size_t), ('peak_process', ctypes.c_size_t), ('peak_job', ctypes.c_size_t)]
        self.kernel = ctypes.WinDLL('kernel32', use_last_error=True)
        self.kernel.CreateJobObjectW.argtypes = [ctypes.c_void_p, wt.LPCWSTR]
        self.kernel.CreateJobObjectW.restype = wt.HANDLE
        self.kernel.SetInformationJobObject.argtypes = [wt.HANDLE, ctypes.c_int, ctypes.c_void_p, wt.DWORD]
        self.kernel.SetInformationJobObject.restype = wt.BOOL
        self.kernel.AssignProcessToJobObject.argtypes = [wt.HANDLE, wt.HANDLE]
        self.kernel.AssignProcessToJobObject.restype = wt.BOOL
        self.kernel.TerminateJobObject.argtypes = [wt.HANDLE, wt.UINT]
        self.kernel.TerminateJobObject.restype = wt.BOOL
        self.kernel.CloseHandle.argtypes = [wt.HANDLE]
        self.kernel.CloseHandle.restype = wt.BOOL
        self.handle = self.kernel.CreateJobObjectW(None, None)
        if not self.handle:
            raise ctypes.WinError(ctypes.get_last_error())
        limits = Extended();limits.basic.flags = 0x2000  # JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE
        if not self.kernel.SetInformationJobObject(self.handle, 9, ctypes.byref(limits), ctypes.sizeof(limits)):
            error = ctypes.WinError(ctypes.get_last_error());self.close();raise error

    def assign_and_resume(self, child, deadline):
        if not self.kernel.AssignProcessToJobObject(self.handle, int(child._handle)):
            raise ctypes.WinError(ctypes.get_last_error())
        if time.monotonic() >= deadline:
            raise subprocess.TimeoutExpired(child.args, 20)
        # Popen closes the primary thread handle. Resume the assigned suspended process
        # through the native system call; no external helper or uncontained child runs.
        native = ctypes.WinDLL('ntdll')
        native.NtResumeProcess.argtypes = [ctypes.c_void_p]
        native.NtResumeProcess.restype = ctypes.c_long
        status = native.NtResumeProcess(int(child._handle))
        if status != 0:
            raise OSError(f'NtResumeProcess status 0x{status & 0xffffffff:08x}')

    def terminate(self):
        if self.handle and not self.kernel.TerminateJobObject(self.handle, 1):
            raise ctypes.WinError(ctypes.get_last_error())
        return True

    def close(self):
        if self.handle:
            if not self.kernel.CloseHandle(self.handle):
                raise ctypes.WinError(ctypes.get_last_error())
            self.handle = None


def run_child(command, env):
    start = time.monotonic();deadline = start+20.0
    job = None;child = None;raw_out = raw_err = b'';cleanup = {};timed_out = False;error = None
    try:
        kwargs = dict(cwd=command['cwd'], env=env, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        if os.name == 'nt':
            job = WindowsJob()
            kwargs['creationflags'] = 0x4 | subprocess.CREATE_NEW_PROCESS_GROUP | subprocess.CREATE_NO_WINDOW
        else:
            kwargs['start_new_session'] = True
        child = subprocess.Popen(command['argv'], **kwargs)
        cleanup['pid'] = child.pid
        if job:
            job.assign_and_resume(child, deadline);cleanup['contained_before_resume'] = True
        try:
            remaining = deadline-time.monotonic()
            if remaining <= 0:
                raise subprocess.TimeoutExpired(command['argv'], 20)
            raw_out, raw_err = child.communicate(timeout=remaining)
        except subprocess.TimeoutExpired as exc:
            timed_out = True;raw_out = exc.stdout or b'';raw_err = exc.stderr or b''
            cleanup['deadline_reached_seconds'] = round(time.monotonic()-start, 6)
            if job:
                cleanup['terminate_job_sent'] = job.terminate();job.close()
            else:
                os.killpg(child.pid, signal.SIGKILL);cleanup['killpg_sent'] = True
            # Only drain already terminated processes; no extension of execution time.
            try:
                raw_out, raw_err = child.communicate(timeout=0.5)
            except subprocess.TimeoutExpired as drain:
                raw_out = drain.stdout or raw_out;raw_err = drain.stderr or raw_err
                cleanup['drain_incomplete'] = True
    except subprocess.TimeoutExpired as exc:
        timed_out = True;error = type(exc).__name__+': '+str(exc)
        cleanup['deadline_reached_seconds'] = round(time.monotonic()-start, 6)
    except Exception as exc:
        error = type(exc).__name__+': '+str(exc)
    finally:
        if job:
            try:
                job.close()  # Kill-on-close also covers descendants after parent exit.
                cleanup['job_closed'] = True
            except Exception as close_error:
                cleanup['job_close_error'] = type(close_error).__name__+': '+str(close_error)
                error = (error+'; ' if error else '')+cleanup['job_close_error']
                # Retain the handle on failed close. This runs even for an exited
                # parent; killing only the parent cannot contain descendants.
                try:
                    cleanup['terminate_after_close_failure'] = job.terminate()
                except Exception as terminate_error:
                    cleanup['job_terminate_error'] = type(terminate_error).__name__+': '+str(terminate_error)
                try:
                    job.close();cleanup['final_job_close'] = True
                except Exception as final_error:
                    cleanup['final_job_close_error'] = type(final_error).__name__+': '+str(final_error)
        if child is not None and child.poll() is None:
            try:
                if os.name != 'nt': os.killpg(child.pid, signal.SIGKILL)
                child.kill()
                raw_out, raw_err = child.communicate(timeout=0.5)
            except Exception as exc:
                cleanup['fallback_error'] = type(exc).__name__+': '+str(exc)
    return dict(exit_code=None if child is None else child.returncode,
                elapsed_seconds=round(time.monotonic()-start, 6), timed_out=timed_out,
                supervision=cleanup, launch_error=error), raw_out, raw_err



