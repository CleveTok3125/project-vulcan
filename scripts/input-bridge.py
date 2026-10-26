#!/usr/bin/env python3
"""Forward Apollo passthrough input to the game's Xwayland display.

Sway runs with the headless backend, so it has no libinput seat and ignores
the event nodes exposed by input-broker. The game itself runs under gamescope
on a private Xwayland display, so this bridge injects evdev events through
XTest instead of routing them through Sway.
"""

from __future__ import annotations

import ctypes
import os
import select
import struct
import time

INPUT_DIR = "/dev/input"
SYSFS_DIR = "/sys/class/input"
DEVICE_NAMES = {
    "Keyboard passthrough": "keyboard",
    "Mouse passthrough": "mouse",
}
EVENT_SIZE = struct.calcsize("llHHi")
POLL_SECONDS = 0.25

EV_KEY = 1
EV_REL = 2

REL_X = 0
REL_Y = 1
REL_HWHEEL = 6
REL_WHEEL = 8

BTN_LEFT = 0x110
BTN_RIGHT = 0x111
BTN_MIDDLE = 0x112
BTN_SIDE = 0x113
BTN_EXTRA = 0x114

MOUSE_BUTTONS = {
    BTN_LEFT: 1,
    BTN_MIDDLE: 2,
    BTN_RIGHT: 3,
    BTN_SIDE: 8,
    BTN_EXTRA: 9,
}



class XTest:
    """Minimal XTest wrapper for key, button, and relative motion events."""

    def __init__(self, display_name: str) -> None:
        self.x11 = ctypes.CDLL("libX11.so.6")
        self.xtst = ctypes.CDLL("libXtst.so.6")

        self.x11.XOpenDisplay.argtypes = [ctypes.c_char_p]
        self.x11.XOpenDisplay.restype = ctypes.c_void_p
        self.x11.XFlush.argtypes = [ctypes.c_void_p]
        self.x11.XFlush.restype = ctypes.c_int

        self.xtst.XTestFakeKeyEvent.argtypes = [
            ctypes.c_void_p,
            ctypes.c_uint,
            ctypes.c_int,
            ctypes.c_ulong,
        ]
        self.xtst.XTestFakeKeyEvent.restype = ctypes.c_int
        self.xtst.XTestFakeButtonEvent.argtypes = [
            ctypes.c_void_p,
            ctypes.c_uint,
            ctypes.c_int,
            ctypes.c_ulong,
        ]
        self.xtst.XTestFakeButtonEvent.restype = ctypes.c_int
        self.xtst.XTestFakeRelativeMotionEvent.argtypes = [
            ctypes.c_void_p,
            ctypes.c_int,
            ctypes.c_int,
            ctypes.c_ulong,
        ]
        self.xtst.XTestFakeRelativeMotionEvent.restype = ctypes.c_int

        self.display = self.x11.XOpenDisplay(display_name.encode())
        if not self.display:
            raise OSError(f"cannot open X display {display_name}")

    def key(self, keycode: int, pressed: bool) -> None:
        if 0 < keycode < 248:
            self.xtst.XTestFakeKeyEvent(
                self.display, keycode + 8, 1 if pressed else 0, 0
            )

    def button(self, button: int, pressed: bool) -> None:
        self.xtst.XTestFakeButtonEvent(
            self.display, button, 1 if pressed else 0, 0
        )

    def motion(self, dx: int, dy: int) -> None:
        if dx or dy:
            self.xtst.XTestFakeRelativeMotionEvent(self.display, dx, dy, 0)

    def flush(self) -> None:
        self.x11.XFlush(self.display)


def read_text(path: str) -> str:
    with open(path, encoding="utf-8", errors="replace") as handle:
        return handle.read().strip()


def device_nodes() -> dict[str, str]:
    nodes: dict[str, str] = {}
    try:
        entries = os.listdir(SYSFS_DIR)
    except OSError:
        return nodes

    for entry in entries:
        if not entry.startswith("event"):
            continue
        try:
            name = read_text(f"{SYSFS_DIR}/{entry}/device/name")
        except OSError:
            continue
        if name in DEVICE_NAMES:
            nodes[f"{INPUT_DIR}/{entry}"] = DEVICE_NAMES[name]
    return nodes


def handle_event(xtest: XTest, event_type: int, code: int, value: int) -> bool:
    if event_type == EV_KEY:
        if code in MOUSE_BUTTONS:
            xtest.button(MOUSE_BUTTONS[code], value != 0)
            return True
        if code < 0x100:
            xtest.key(code, value != 0)
            return True
        return False

    if event_type == EV_REL:
        if code == REL_X:
            xtest.motion(value, 0)
            return True
        if code == REL_Y:
            xtest.motion(0, value)
            return True
        if code == REL_WHEEL:
            button = 4 if value > 0 else 5
            for _ in range(abs(value)):
                xtest.button(button, True)
                xtest.button(button, False)
            return True
        if code == REL_HWHEEL:
            button = 6 if value > 0 else 7
            for _ in range(abs(value)):
                xtest.button(button, True)
                xtest.button(button, False)
            return True
    return False


def open_device(path: str) -> int | None:
    try:
        return os.open(path, os.O_RDONLY | os.O_NONBLOCK)
    except OSError:
        return None


def close_device(fd: int) -> None:
    try:
        os.close(fd)
    except OSError:
        pass


def main() -> int:
    display_name = os.environ.get("DISPLAY", ":2")
    xtest: XTest | None = None
    devices: dict[int, str] = {}
    buffers: dict[int, bytes] = {}

    print(f"watching input devices for display {display_name}", flush=True)

    while True:
        if xtest is None:
            try:
                xtest = XTest(display_name)
                print(f"connected to X display {display_name}", flush=True)
            except OSError as error:
                print(f"waiting for X display: {error}", flush=True)
                time.sleep(1)
                continue

        wanted = device_nodes()
        for fd, path in list(devices.items()):
            if path not in wanted:
                close_device(fd)
                devices.pop(fd, None)
                buffers.pop(fd, None)

        for path in wanted:
            if path in devices.values():
                continue
            fd = open_device(path)
            if fd is None:
                continue
            devices[fd] = path
            buffers[fd] = b""
            print(f"opened {path}", flush=True)

        if not devices:
            time.sleep(POLL_SECONDS)
            continue

        try:
            ready, _, _ = select.select(list(devices), [], [], POLL_SECONDS)
        except OSError as error:
            print(f"select failed: {error}", flush=True)
            time.sleep(POLL_SECONDS)
            continue

        for fd in ready:
            try:
                data = os.read(fd, EVENT_SIZE * 64)
            except BlockingIOError:
                continue
            except OSError as error:
                print(f"read {devices.get(fd, fd)} failed: {error}", flush=True)
                close_device(fd)
                devices.pop(fd, None)
                buffers.pop(fd, None)
                continue

            if not data:
                close_device(fd)
                devices.pop(fd, None)
                buffers.pop(fd, None)
                continue

            buffer = buffers.get(fd, b"") + data
            emitted = False
            while len(buffer) >= EVENT_SIZE:
                raw = buffer[:EVENT_SIZE]
                buffer = buffer[EVENT_SIZE:]
                _, _, event_type, code, value = struct.unpack("llHHi", raw)
                if handle_event(xtest, event_type, code, value):
                    emitted = True
            buffers[fd] = buffer
            if emitted:
                xtest.flush()

    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except KeyboardInterrupt:
        raise SystemExit(0)
