#!/usr/bin/env python3
"""Expose Apollo's virtual input devices to the container compositor.

Apollo creates uinput devices in the shared kernel. The container has its own
/dev tmpfs, so the event nodes created by the host udev instance are not
visible inside the container. This helper copies only the expected Apollo
device nodes into /dev/input and publishes matching udev database records and
netlink events so libinput can hotplug them.

The broker is intentionally narrow: it only matches the fixed device names
created by inputtino. Extra names can be added with INPUT_EXTRA_NAMES.
"""

from __future__ import annotations

import os
import socket
import stat
import sys
import time

INPUT_DIR = "/dev/input"
UDEV_RUN = "/run/udev"
NETLINK_KOBJECT_UEVENT = 15
UDEV_GROUP = 2
MAJOR_INPUT = 13
POLL_SECONDS = 0.25
SEQNUM = 0

TARGETS = {
    "Mouse passthrough": "mouse",
    "Keyboard passthrough": "keyboard",
    "Touch passthrough": "touchscreen",
    "Pen passthrough": "tablet",
}

TYPE_PROPERTIES = {
    "mouse": "ID_INPUT_MOUSE",
    "keyboard": "ID_INPUT_KEYBOARD",
    "touchscreen": "ID_INPUT_TOUCHSCREEN",
    "tablet": "ID_INPUT_TABLET",
    "joystick": "ID_INPUT_JOYSTICK",
}


def read_text(path: str) -> str:
    with open(path, encoding="utf-8", errors="replace") as handle:
        return handle.read().strip()


def event_names() -> dict[str, str]:
    names: dict[str, str] = {}
    for entry in os.listdir("/sys/class/input"):
        if not entry.startswith("event"):
            continue
        try:
            names[entry] = read_text(f"/sys/class/input/{entry}/device/name")
        except OSError:
            continue
    return names


def classify(name: str, extra_names: set[str]) -> str | None:
    if name in TARGETS:
        return TARGETS[name]
    if name in extra_names:
        return "joystick"
    return None


def ensure_runtime_dirs() -> None:
    os.makedirs(INPUT_DIR, exist_ok=True)
    os.makedirs(f"{UDEV_RUN}/data", exist_ok=True)
    open(f"{UDEV_RUN}/control", "a", encoding="utf-8").close()


def send_uevent(devpath: str, devname: str, minor: int, device_type: str) -> None:
    global SEQNUM

    SEQNUM += 1
    properties = [
        "ACTION=add",
        f"DEVPATH={devpath}",
        "SUBSYSTEM=input",
        f"DEVNAME={devname}",
        f"MAJOR={MAJOR_INPUT}",
        f"MINOR={minor}",
        "ID_INPUT=1",
        f"{TYPE_PROPERTIES[device_type]}=1",
        "ID_SEAT=seat0",
        f"SEQNUM={SEQNUM}",
    ]

    payload = f"add@{devpath}\0" + "\0".join(properties) + "\0"
    sock = socket.socket(socket.AF_NETLINK, socket.SOCK_RAW, NETLINK_KOBJECT_UEVENT)
    try:
        sock.bind((0, 0))
        sock.sendto(payload.encode(), (0, UDEV_GROUP))
    finally:
        sock.close()


def write_udev_database(devname: str, minor: int, device_type: str) -> None:
    entries = [
        f"E:DEVNAME=/dev/{devname}",
        f"E:MAJOR={MAJOR_INPUT}",
        f"E:MINOR={minor}",
        "E:SUBSYSTEM=input",
        "E:ID_INPUT=1",
        f"E:{TYPE_PROPERTIES[device_type]}=1",
        "E:ID_SEAT=seat0",
    ]
    path = f"{UDEV_RUN}/data/c{MAJOR_INPUT}:{minor}"
    with open(path, "w", encoding="utf-8") as handle:
        handle.write("\n".join(entries) + "\n")


def expose(event: str, device_type: str, input_gid: int) -> bool:
    dev = read_text(f"/sys/class/input/{event}/dev")
    major_text, minor_text = dev.split(":", 1)
    major = int(major_text)
    minor = int(minor_text)
    if major != MAJOR_INPUT:
        print(f"skip {event}: unexpected major {major}", flush=True)
        return False

    devname = f"input/{event}"
    node = f"/dev/{devname}"
    if not os.path.exists(node):
        os.mknod(node, stat.S_IFCHR | 0o660, os.makedev(major, minor))
    os.chown(node, 0, input_gid)
    os.chmod(node, 0o660)

    devpath = os.path.realpath(f"/sys/class/input/{event}")
    if devpath.startswith("/sys"):
        devpath = devpath[4:]

    write_udev_database(devname, minor, device_type)
    send_uevent(devpath, devname, minor, device_type)
    print(f"exposed {node} as {device_type}", flush=True)
    return True


def main() -> int:
    ensure_runtime_dirs()
    input_gid = int(os.environ.get("INPUT_GID", "0"))
    extra_names = {
        name.strip()
        for name in os.environ.get("INPUT_EXTRA_NAMES", "").split(",")
        if name.strip()
    }

    baseline = set(event_names())
    print(
        f"watching for Apollo input devices; baseline={len(baseline)} "
        f"input_gid={input_gid}",
        flush=True,
    )

    while True:
        for event, name in event_names().items():
            if event in baseline:
                continue
            device_type = classify(name, extra_names)
            if device_type is None:
                continue
            try:
                if expose(event, device_type, input_gid):
                    baseline.add(event)
            except OSError as error:
                print(f"failed to expose {event} ({name}): {error}", flush=True)
                baseline.add(event)
        time.sleep(POLL_SECONDS)


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except KeyboardInterrupt:
        raise SystemExit(0) from None
