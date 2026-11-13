"""Single native operation for gui-session.mjs. No automatic activation or input replay."""
import ctypes
from ctypes import wintypes as W
import hashlib
import json
import os
import pathlib
import sys
import time
import uuid

u = ctypes.WinDLL('user32', use_last_error=True)
k = ctypes.WinDLL('kernel32', use_last_error=True)
u.SetProcessDpiAwarenessContext.argtypes = [W.HANDLE]
u.SetProcessDpiAwarenessContext(ctypes.c_void_p(-4))
u.GetForegroundWindow.restype = W.HWND
u.GetWindow.argtypes = [W.HWND, W.UINT]
u.GetWindow.restype = W.HWND
u.GetWindowRect.argtypes = [W.HWND, ctypes.POINTER(W.RECT)]
u.GetWindowThreadProcessId.argtypes = [W.HWND, ctypes.POINTER(W.DWORD)]
u.GetWindowTextLengthW.argtypes = [W.HWND]
u.GetWindowTextW.argtypes = [W.HWND, W.LPWSTR, ctypes.c_int]
u.IsWindowVisible.argtypes = [W.HWND]
u.IsIconic.argtypes = [W.HWND]
u.GetDpiForWindow.argtypes = [W.HWND]
u.SetForegroundWindow.argtypes = [W.HWND]
k.OpenProcess.argtypes = [W.DWORD, W.BOOL, W.DWORD]
k.OpenProcess.restype = W.HANDLE
k.GetProcessTimes.argtypes = [W.HANDLE] + [ctypes.POINTER(W.FILETIME)] * 4
k.CloseHandle.argtypes = [W.HANDLE]
EnumProc = ctypes.WINFUNCTYPE(W.BOOL, W.HWND, W.LPARAM)
u.EnumWindows.argtypes = [EnumProc, W.LPARAM]


def title(hwnd):
    buf = ctypes.create_unicode_buffer(u.GetWindowTextLengthW(hwnd) + 1)
    u.GetWindowTextW(hwnd, buf, len(buf))
    return buf.value


def frame(target):
    matches = []
    @EnumProc
    def each(hwnd, _):
        pid = W.DWORD()
        u.GetWindowThreadProcessId(hwnd, ctypes.byref(pid))
        if pid.value == target['pid'] and title(hwnd) == target['title'] and u.IsWindowVisible(hwnd):
            matches.append(hwnd)
        return True
    u.EnumWindows(each, 0)
    if len(matches) != 1:
        raise RuntimeError('Expected exactly one visible target window')
    hwnd = matches[0]
    if u.IsIconic(hwnd):
        raise RuntimeError('Target is minimized; explicit activation required')
    rect = W.RECT()
    if not u.GetWindowRect(hwnd, ctypes.byref(rect)):
        raise ctypes.WinError(ctypes.get_last_error())
    handle = k.OpenProcess(0x1000, False, target['pid'])
    if not handle:
        raise ctypes.WinError(ctypes.get_last_error())
    stamps = [W.FILETIME() for _ in range(4)]
    try:
        if not k.GetProcessTimes(handle, *[ctypes.byref(t) for t in stamps]):
            raise ctypes.WinError(ctypes.get_last_error())
    finally:
        k.CloseHandle(handle)
    started = str((stamps[0].dwHighDateTime << 32) | stamps[0].dwLowDateTime)
    unobscured = True
    higher = u.GetWindow(hwnd, 3)  # GW_HWNDPREV, never guess pixel visibility from focus alone
    while higher:
        if u.IsWindowVisible(higher) and not u.IsIconic(higher):
            other = W.RECT()
            u.GetWindowRect(higher, ctypes.byref(other))
            if max(rect.left, other.left) < min(rect.right, other.right) and max(rect.top, other.top) < min(rect.bottom, other.bottom):
                unobscured = False
                break
        higher = u.GetWindow(higher, 3)
    return {'window': {'id': int(hwnd), 'pid': target['pid'], 'startedAt': started,
            'title': target['title'], 'dpi': u.GetDpiForWindow(hwnd),
            'bounds': {'x': rect.left, 'y': rect.top, 'width': rect.right-rect.left, 'height': rect.bottom-rect.top}},
            'foreground': u.GetForegroundWindow() == hwnd, 'unobscured': unobscured}


def verified(target, expected=None):
    if u.GetAsyncKeyState(0x1B) & 0x8000:
        raise RuntimeError('physical Esc: GUI session stopped')
    current = frame(target)
    if not current['foreground'] or not current['unobscured']:
        raise RuntimeError('Target lost focus or is occluded; no capture/input permitted')
    if expected is not None and current['window'] != expected:
        raise RuntimeError('Window identity, geometry or DPI changed')
    return current


def capture(target):
    before = verified(target, target.get('window'))
    root = pathlib.Path(os.path.abspath(target['evidenceRoot']))
    if root.drive.lower() != 'd:' or root == pathlib.Path('D:/'):
        raise RuntimeError('Evidence directory must be an absolute D drive directory')
    # Avoid writing through a junction/symlink; caller never chooses a screenshot filename.
    for parent in (root, *root.parents):
        if parent.exists() and (parent.is_symlink() or parent.is_junction()):
            raise RuntimeError('Evidence directory contains a reparse point')
    from PIL import ImageGrab
    b = before['window']['bounds']
    image = ImageGrab.grab(bbox=(b['x'], b['y'], b['x']+b['width'], b['y']+b['height']), all_screens=True)
    verified(target, before['window'])  # do not save an image after focus/identity changes
    if image.width != b['width'] or image.height != b['height']:
        raise RuntimeError('Screenshot and physical window geometry differ')
    root.mkdir(parents=True, exist_ok=True)
    path = root / (str(uuid.uuid4()) + '.png')
    image.save(path)
    digest = hashlib.sha256(path.read_bytes()).hexdigest()
    before['screenshots'] = [{'id': digest, 'path': str(path), 'originX': 0, 'originY': 0, 'width': image.width, 'height': image.height}]
    return before


def click(target):
    expected = target['window']
    verified(target, expected)
    x, y = target['x'], target['y']
    b = expected['bounds']
    if not (isinstance(x, (int, float)) and isinstance(y, (int, float)) and 0 <= x < b['width'] and 0 <= y < b['height']):
        raise RuntimeError('Point outside observed window')
    if not u.SetCursorPos(round(b['x']+x), round(b['y']+y)):
        raise ctypes.WinError(ctypes.get_last_error())
    time.sleep(0.15)  # allow the target to process mouse-enter before a normal press
    verified(target, expected)
    u.mouse_event(0x0002, 0, 0, 0, 0)
    try:
        time.sleep(0.08)
    finally:
        u.mouse_event(0x0004, 0, 0, 0, 0)  # always release, including capture/focus errors
    verified(target, expected)
    return {'status': 'input-sent'}


def main():
    action, target = sys.argv[1], json.loads(sys.argv[2])
    if not isinstance(target.get('pid'), int) or target['pid'] <= 0 or not isinstance(target.get('title'), str) or not target['title']:
        raise RuntimeError('Exact observed process ID and title required')
    if action == 'observe':
        return capture(target)
    if action == 'verify':
        return verified(target, target.get('window'))
    if action == 'click':
        return click(target)
    if action == 'activate':
        current = frame(target)
        if not current['foreground']:
            if not u.SetForegroundWindow(current['window']['id']):
                raise RuntimeError('Explicit activation denied; activate target manually')
        return {'status': 'activated'}
    raise RuntimeError('Unsupported native action')


if __name__ == '__main__':
    try:
        print(json.dumps(main(), ensure_ascii=True))
    except Exception as error:
        print(json.dumps({'error': str(error)}, ensure_ascii=True))
        sys.exit(1)
