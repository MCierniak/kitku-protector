#!/usr/bin/env python3
"""Lab experiment: can QEMU deliver a key press to ONE chosen emulated keyboard?

The guest gets three keyboards at once: PS/2 (i8042), USB and virtio. The USB and the
virtio keyboard are each bound to their own display device; the PS/2 keyboard is left
unbound. Keys are then injected over QMP, and a small Linux live guest reports which of
its input devices produced events.

Any Linux live image with a root shell on the serial console works; the Alpine "virt"
ISO is small and boots within seconds:
    https://dl-cdn.alpinelinux.org/alpine/latest-stable/releases/x86_64/

Inside the development container QEMU runs in the lab container, and this script asks
the lab daemon to start it (KITKU_LAB_URL is set there). The ISO then has to be in the
workspace, which both containers see at the same path:
    python3 spike/lab/keyboard_routing.py --iso lab/iso/alpine-virt-3.24.4-x86_64.iso --accel kvm

With QEMU installed locally and no lab daemon, QEMU is started directly:
    python3 spike/lab/keyboard_routing.py --iso alpine-virt-3.24.4-x86_64.iso

Expected result: every injection reaches exactly one keyboard.
    send-key (no target)             -> AT Translated Set 2 keyboard
    input-send-event device=dispA    -> QEMU QEMU USB Keyboard
    input-send-event device=dispB    -> QEMU Virtio Keyboard
    input-send-event device=vga0     -> AT Translated Set 2 keyboard
"""

import argparse
import json
import os
import socket
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.parse
import urllib.request

MARKER = b"__DONE__"
MACHINE_NAME = "keyboard-routing"
LAB_QMP_PORT = 14444
LAB_SERIAL_PORT = 14445


def parse_args():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--iso", required=True, help="Linux live ISO with a root shell on the serial console")
    parser.add_argument("--accel", default="tcg", choices=["tcg", "kvm"], help="tcg needs no privileges; kvm is faster")
    parser.add_argument("--lab-url", default=os.environ.get("KITKU_LAB_URL"),
                        help="lab daemon to start QEMU through (default: $KITKU_LAB_URL; unset = start QEMU locally)")
    parser.add_argument("--qemu", default="qemu-system-x86_64", help="local QEMU binary (default: from PATH)")
    parser.add_argument("--firmware-dir", action="append", default=[],
                        help="extra directory with BIOS files; only for a local QEMU that is not installed system-wide")
    parser.add_argument("--boot-timeout", type=int, default=420, help="seconds to wait for the login prompt")
    return parser.parse_args()


def qemu_arguments(args, iso, serial, qmp):
    """QEMU command line without the binary: three keyboards, two of them bound to displays."""
    accel = "kvm" if args.accel == "kvm" else "tcg,thread=multi"
    cpu = "host" if args.accel == "kvm" else "max"
    arguments = ["-accel", accel, "-machine", "q35", "-cpu", cpu, "-m", "1024", "-smp", "2",
                 "-nodefaults", "-display", "none"]
    for directory in args.firmware_dir:
        arguments += ["-L", os.path.abspath(directory)]
    arguments += [
        # One display device per keyboard that should be addressable on its own.
        "-device", "VGA,id=vga0",
        "-device", "bochs-display,id=dispA",
        "-device", "bochs-display,id=dispB",
        "-device", "qemu-xhci,id=xhci",
        "-device", "usb-kbd,bus=xhci.0,id=kbdU,display=dispA",
        "-device", "virtio-keyboard-pci,id=kbdV,display=dispB",
        "-drive", f"file={iso},media=cdrom,if=none,id=cd0,readonly=on",
        "-device", "ide-cd,drive=cd0,bus=ide.0",
        "-boot", "d",
        "-serial", serial,
        "-qmp", qmp,
    ]
    return arguments


class LocalMachine:
    """QEMU started as a child process, reached through UNIX sockets."""

    def __init__(self, args, iso):
        run_dir = tempfile.mkdtemp(prefix="kitku-routing-")
        os.chdir(run_dir)  # UNIX socket paths are limited to 107 bytes, so use short relative names
        arguments = qemu_arguments(args, iso, "unix:serial.sock,server=on,wait=off", "unix:qmp.sock,server=on,wait=off")
        self.process = subprocess.Popen([args.qemu, *arguments], stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
        self.serial_address, self.qmp_address = "serial.sock", "qmp.sock"

    def failure(self):
        if self.process.poll() is None:
            return None
        return "QEMU exited early:\n" + self.process.stdout.read().decode(errors="replace")

    def stop(self):
        self.process.terminate()
        try:
            self.process.wait(10)
        except subprocess.TimeoutExpired:
            self.process.kill()


class LabMachine:
    """QEMU started by the lab daemon in the lab container, reached over TCP."""

    def __init__(self, args, iso):
        self.url = args.lab_url.rstrip("/")
        host = urllib.parse.urlparse(self.url).hostname
        arguments = qemu_arguments(args, iso, f"tcp:0.0.0.0:{LAB_SERIAL_PORT},server=on,wait=off",
                                   f"tcp:0.0.0.0:{LAB_QMP_PORT},server=on,wait=off")
        self.request("DELETE", f"/vms/{MACHINE_NAME}", allow_missing=True)
        self.request("POST", "/vms", {"name": MACHINE_NAME, "args": arguments})
        self.serial_address, self.qmp_address = (host, LAB_SERIAL_PORT), (host, LAB_QMP_PORT)

    def request(self, method, path, body=None, allow_missing=False):
        data = json.dumps(body).encode() if body is not None else None
        request = urllib.request.Request(self.url + path, data=data, method=method,
                                         headers={"Content-Type": "application/json"})
        try:
            with urllib.request.urlopen(request, timeout=30) as response:
                return json.loads(response.read())
        except urllib.error.HTTPError as error:
            if allow_missing and error.code == 404:
                return None
            raise SystemExit(f"lab daemon refused {method} {path}: {error.read().decode(errors='replace')}")

    def failure(self):
        state = self.request("GET", f"/vms/{MACHINE_NAME}")
        if state["state"] == "running":
            return None
        return "QEMU exited early:\n" + self.request("GET", f"/vms/{MACHINE_NAME}/log")["log"]

    def stop(self):
        self.request("DELETE", f"/vms/{MACHINE_NAME}", allow_missing=True)


def connect(address, machine, timeout=20):
    """Connect to a socket that QEMU creates shortly after starting (UNIX path or host and port)."""
    family = socket.AF_UNIX if isinstance(address, str) else socket.AF_INET
    deadline = time.time() + timeout
    while time.time() < deadline:
        failure = machine.failure()
        if failure:
            raise SystemExit(failure)
        try:
            sock = socket.socket(family)
            sock.connect(address)
            return sock
        except OSError:
            time.sleep(0.3)
    raise SystemExit(f"could not connect to {address}")


class SerialShell:
    """Minimal driver for a root shell on the guest's serial console."""

    def __init__(self, sock):
        self.sock = sock
        self.sock.settimeout(1.0)
        self.buffer = b""

    def read_until(self, marker, timeout):
        deadline = time.time() + timeout
        while time.time() < deadline:
            if marker in self.buffer:
                end = self.buffer.index(marker) + len(marker)
                out, self.buffer = self.buffer[:end], self.buffer[end:]
                return out
            try:
                chunk = self.sock.recv(65536)
                if chunk:
                    self.buffer += chunk
            except socket.timeout:
                pass
        tail = self.buffer[-600:].decode(errors="replace")
        raise SystemExit(f"timeout waiting for {marker!r}; last guest output:\n{tail}")

    def run(self, command, timeout=60):
        # The marker is split by quotes in the command, so the echoed command line cannot
        # be mistaken for the end of the output.
        self.sock.sendall(command.encode() + b"; echo __DO''NE__\n")
        out = self.read_until(MARKER, timeout).decode(errors="replace")
        self.read_until(b"\n", 5)
        lines = [line.rstrip("\r") for line in out.replace(MARKER.decode(), "").split("\n")]
        return "\n".join(line for line in lines if line.strip() and "__DO''NE__" not in line).strip()


class Qmp:
    """Minimal QMP client: one command, one reply."""

    def __init__(self, sock):
        self.stream = sock.makefile("rw")
        json.loads(self.stream.readline())  # greeting
        self.command("qmp_capabilities")

    def command(self, execute, **arguments):
        message = {"execute": execute}
        if arguments:
            message["arguments"] = arguments
        self.stream.write(json.dumps(message) + "\n")
        self.stream.flush()
        while True:
            reply = json.loads(self.stream.readline())
            if "return" in reply or "error" in reply:
                return reply


def key_press(qcode):
    key = {"type": "qcode", "data": qcode}
    return [
        {"type": "key", "data": {"down": True, "key": key}},
        {"type": "key", "data": {"down": False, "key": key}},
    ]


def parse_pairs(text):
    """Turn "eventN|value" lines into a dictionary, ignoring anything else on the console."""
    result = {}
    for line in text.splitlines():
        if "|" in line:
            node, value = line.split("|", 1)
            result[node.split()[-1]] = value
    return result


def main():
    args = parse_args()
    iso = os.path.abspath(args.iso)
    where = f"lab daemon at {args.lab_url}" if args.lab_url else "local QEMU"
    machine = LabMachine(args, iso) if args.lab_url else LocalMachine(args, iso)
    try:
        shell = SerialShell(connect(machine.serial_address, machine))
        started = time.time()
        shell.read_until(b"login:", args.boot_timeout)
        print(f"guest booted in {time.time() - started:.0f} s ({where}, accelerator: {args.accel})")
        shell.sock.sendall(b"root\n")
        shell.read_until(b"#", 30)
        shell.run("stty -echo")
        shell.run("modprobe -a i8042 atkbd xhci_pci usbhid hid_generic virtio_input evdev 2>/dev/null; sleep 3")
        names = parse_pairs(shell.run(
            'for d in /sys/class/input/event*; do echo "$(basename $d)|$(cat $d/device/name)"; done'))
        print("input devices in the guest:")
        for node, name in sorted(names.items()):
            print(f"  {node}: {name}")
        shell.run("for f in /dev/input/event*; do (cat $f > /tmp/$(basename $f).bin &); done; sleep 1")

        qmp = Qmp(connect(machine.qmp_address, machine))

        def sizes():
            out = shell.run('for f in /tmp/event*.bin; do echo "$(basename $f .bin)|$(wc -c < $f)"; done')
            return {node: int(size) for node, size in parse_pairs(out).items()}

        steps = [
            ("send-key (no target)", lambda: qmp.command("send-key", keys=[{"type": "qcode", "data": "a"}])),
            ("input-send-event device=dispA", lambda: qmp.command("input-send-event", device="dispA", events=key_press("b"))),
            ("input-send-event device=dispB", lambda: qmp.command("input-send-event", device="dispB", events=key_press("c"))),
            ("input-send-event device=vga0", lambda: qmp.command("input-send-event", device="vga0", events=key_press("d"))),
        ]
        print("\nRESULTS (which guest input device produced events)")
        single_target = True
        for label, inject in steps:
            before = sizes()
            reply = inject()
            time.sleep(2.5)
            after = sizes()
            hit = [names.get(node, node) for node in after if after[node] != before.get(node, 0)]
            status = "ok" if "return" in reply else "QMP error: " + reply["error"].get("desc", "?")
            print(f"  {label:32s} -> {', '.join(hit) if hit else 'NO device received anything'}   [{status}]")
            single_target = single_target and len(hit) == 1
        print("\nVERDICT:", "every injection reached exactly one keyboard" if single_target else "routing is NOT one-to-one")
        return 0 if single_target else 1
    finally:
        machine.stop()


if __name__ == "__main__":
    sys.exit(main())
