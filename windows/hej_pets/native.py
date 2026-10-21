"""Small Windows-specific overlay adaptation; all other code remains previewable on Mac."""
import sys


def configure_overlay(window):
    if sys.platform != 'win32':
        return
    import ctypes
    from ctypes import wintypes
    user32=ctypes.WinDLL('user32',use_last_error=True)
    get_style=user32.GetWindowLongPtrW
    get_style.argtypes=[wintypes.HWND,ctypes.c_int];get_style.restype=ctypes.c_ssize_t
    set_style=user32.SetWindowLongPtrW
    set_style.argtypes=[wintypes.HWND,ctypes.c_int,ctypes.c_ssize_t];set_style.restype=ctypes.c_ssize_t
    set_pos=user32.SetWindowPos
    set_pos.argtypes=[wintypes.HWND,wintypes.HWND,ctypes.c_int,ctypes.c_int,ctypes.c_int,ctypes.c_int,wintypes.UINT]
    set_pos.restype=wintypes.BOOL
    hwnd=int(window.winId())
    style=get_style(hwnd,-20)
    # Qt's focus hint handles mouse activation but doesn't set WS_EX_NOACTIVATE.
    # Set it explicitly for consistent topmost, non-activating desktop pets.
    ctypes.set_last_error(0)
    previous=set_style(hwnd,-20,style|0x08000000|0x00000080)
    if not previous and ctypes.get_last_error():
        raise ctypes.WinError(ctypes.get_last_error())
    if not set_pos(hwnd,-1,0,0,0,0,0x0001|0x0002|0x0010|0x0020):
        raise ctypes.WinError(ctypes.get_last_error())
