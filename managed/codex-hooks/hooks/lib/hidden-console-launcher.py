from __future__ import annotations

from contextlib import ExitStack
import ctypes
from ctypes import wintypes
import msvcrt
import os
import subprocess
import sys


_STD_INPUT_HANDLE = -10
_STD_OUTPUT_HANDLE = -11
_STD_ERROR_HANDLE = -12
_DUPLICATE_SAME_ACCESS = 0x00000002
_INVALID_HANDLE_VALUE = ctypes.c_void_p(-1).value


def _duplicate_standard_stream(identifier: int, flags: int, mode: str):
    kernel32 = ctypes.WinDLL("kernel32", use_last_error=True)
    kernel32.GetStdHandle.argtypes = [wintypes.DWORD]
    kernel32.GetStdHandle.restype = wintypes.HANDLE
    kernel32.GetCurrentProcess.restype = wintypes.HANDLE
    kernel32.DuplicateHandle.argtypes = [
        wintypes.HANDLE,
        wintypes.HANDLE,
        wintypes.HANDLE,
        ctypes.POINTER(wintypes.HANDLE),
        wintypes.DWORD,
        wintypes.BOOL,
        wintypes.DWORD,
    ]
    kernel32.DuplicateHandle.restype = wintypes.BOOL

    source = kernel32.GetStdHandle(identifier)
    source_value = ctypes.cast(source, ctypes.c_void_p).value
    if source_value in (None, _INVALID_HANDLE_VALUE):
        return None

    current_process = kernel32.GetCurrentProcess()
    duplicate = wintypes.HANDLE()
    if not kernel32.DuplicateHandle(
        current_process,
        source,
        current_process,
        ctypes.byref(duplicate),
        0,
        True,
        _DUPLICATE_SAME_ACCESS,
    ):
        raise ctypes.WinError(ctypes.get_last_error())

    descriptor = msvcrt.open_osfhandle(duplicate.value, flags)
    return os.fdopen(descriptor, mode, buffering=0)


def _report_launch_failure(stderr_stream, error: BaseException) -> None:
    if stderr_stream is None:
        return
    message = (
        f"hidden-console-launcher: failed to start target: "
        f"{type(error).__name__}: {error}\n"
    )
    try:
        stderr_stream.write(message.encode("utf-8", errors="backslashreplace"))
        stderr_stream.flush()
    except (OSError, ValueError):
        pass


def main(arguments: list[str]) -> int:
    with ExitStack() as stack:
        stderr_stream = None
        try:
            stderr_stream = _duplicate_standard_stream(
                _STD_ERROR_HANDLE, os.O_WRONLY | os.O_BINARY, "wb"
            )
            if stderr_stream is not None:
                stack.enter_context(stderr_stream)
            if os.name != "nt":
                raise RuntimeError("hidden console launcher requires Windows")
            if not arguments:
                raise ValueError("target executable is required")
            stdin_stream = _duplicate_standard_stream(
                _STD_INPUT_HANDLE, os.O_RDONLY | os.O_BINARY, "rb"
            )
            stdout_stream = _duplicate_standard_stream(
                _STD_OUTPUT_HANDLE, os.O_WRONLY | os.O_BINARY, "wb"
            )
            for stream in (stdin_stream, stdout_stream):
                if stream is not None:
                    stack.enter_context(stream)
        except (OSError, RuntimeError, ValueError) as error:
            _report_launch_failure(stderr_stream, error)
            return 127

        try:
            completed = subprocess.run(
                arguments,
                check=False,
                stdin=stdin_stream if stdin_stream is not None else subprocess.DEVNULL,
                stdout=stdout_stream if stdout_stream is not None else subprocess.DEVNULL,
                stderr=stderr_stream if stderr_stream is not None else subprocess.DEVNULL,
                creationflags=subprocess.CREATE_NO_WINDOW,
            )
        except (OSError, ValueError) as error:
            _report_launch_failure(stderr_stream, error)
            return 127
    return completed.returncode


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
