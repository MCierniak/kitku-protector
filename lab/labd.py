#!/usr/bin/env python3
"""labd - control daemon of the KitkuProtector test lab.

Runs inside the lab container and starts QEMU processes on request from the development
container. Plain HTTP with JSON bodies, standard library only.

    GET    /health            daemon, QEMU and KVM status
    GET    /vms               all known machines
    POST   /vms               start one: {"name": "demo", "args": ["-machine", "q35", ...]}
    GET    /vms/<name>        state of one machine
    GET    /vms/<name>/log    last part of QEMU's output
    DELETE /vms/<name>        stop it and forget it

The caller chooses TCP ports for QMP and serial consoles in the QEMU arguments, for
example "-qmp tcp:0.0.0.0:4444,server=on,wait=off", and then connects to them directly.

There is no authentication. The daemon must only be reachable on the private network
between the two containers; do not publish its port.
"""

import json
import os
import re
import signal
import subprocess
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

QEMU = os.environ.get("KITKU_QEMU", "qemu-system-x86_64")
STATE_DIR = os.environ.get("KITKU_LAB_STATE", "/var/lib/kitku-lab")
PORT = int(os.environ.get("KITKU_LABD_PORT", "7780"))
NAME_PATTERN = re.compile(r"^[a-z0-9][a-z0-9-]{0,31}$")
MAX_ARGS = 400
LOG_TAIL_BYTES = 8000

machines = {}
machines_lock = threading.Lock()


def qemu_version():
    try:
        out = subprocess.run([QEMU, "--version"], capture_output=True, text=True, timeout=10).stdout
        return out.splitlines()[0] if out else None
    except (OSError, subprocess.SubprocessError):
        return None


def log_tail(path):
    try:
        with open(path, "rb") as handle:
            handle.seek(0, os.SEEK_END)
            size = handle.tell()
            handle.seek(max(0, size - LOG_TAIL_BYTES))
            return handle.read().decode(errors="replace")
    except OSError:
        return ""


def describe(name, machine):
    code = machine["process"].poll()
    return {
        "name": name,
        "pid": machine["process"].pid,
        "state": "running" if code is None else "exited",
        "exit_code": code,
        "started": machine["started"],
        "args": machine["args"],
    }


def start_machine(name, args):
    if not isinstance(name, str) or not NAME_PATTERN.match(name):
        return 400, {"error": "name must match " + NAME_PATTERN.pattern}
    if not isinstance(args, list) or len(args) > MAX_ARGS or not all(isinstance(a, str) for a in args):
        return 400, {"error": "args must be a list of strings"}
    with machines_lock:
        existing = machines.get(name)
        if existing is not None and existing["process"].poll() is None:
            return 409, {"error": f"machine {name} is already running"}
        run_dir = os.path.join(STATE_DIR, "run", name)
        os.makedirs(run_dir, exist_ok=True)
        log_path = os.path.join(run_dir, "qemu.log")
        with open(log_path, "wb") as log:
            try:
                process = subprocess.Popen(
                    [QEMU, "-name", name, *args], cwd=run_dir, stdin=subprocess.DEVNULL,
                    stdout=log, stderr=subprocess.STDOUT, start_new_session=True)
            except OSError as error:
                return 500, {"error": f"could not start {QEMU}: {error}"}
        machines[name] = {"process": process, "args": args, "started": time.time(), "log": log_path}
    # A wrong argument makes QEMU exit at once; report that instead of a dead machine.
    time.sleep(0.7)
    if process.poll() is not None:
        return 400, {"error": "QEMU exited immediately", "exit_code": process.returncode, "log": log_tail(log_path)}
    return 201, describe(name, machines[name])


def stop_machine(name):
    with machines_lock:
        machine = machines.pop(name, None)
    if machine is None:
        return 404, {"error": f"no machine named {name}"}
    process = machine["process"]
    if process.poll() is None:
        process.terminate()
        try:
            process.wait(10)
        except subprocess.TimeoutExpired:
            process.kill()
            process.wait(10)
    return 200, {"name": name, "state": "stopped", "exit_code": process.returncode}


class Handler(BaseHTTPRequestHandler):
    server_version = "labd/0.1"

    def reply(self, status, body):
        data = json.dumps(body).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def parts(self):
        return [part for part in self.path.split("?")[0].split("/") if part]

    def do_GET(self):
        parts = self.parts()
        if parts == ["health"]:
            self.reply(200, {
                "status": "ok",
                "qemu": qemu_version(),
                "kvm": os.access("/dev/kvm", os.R_OK | os.W_OK),
                "machines": len(machines),
            })
        elif parts == ["vms"]:
            with machines_lock:
                self.reply(200, [describe(name, machine) for name, machine in machines.items()])
        elif len(parts) == 2 and parts[0] == "vms":
            machine = machines.get(parts[1])
            if machine is None:
                self.reply(404, {"error": f"no machine named {parts[1]}"})
            else:
                self.reply(200, describe(parts[1], machine))
        elif len(parts) == 3 and parts[0] == "vms" and parts[2] == "log":
            machine = machines.get(parts[1])
            if machine is None:
                self.reply(404, {"error": f"no machine named {parts[1]}"})
            else:
                self.reply(200, {"name": parts[1], "log": log_tail(machine["log"])})
        else:
            self.reply(404, {"error": "unknown path"})

    def do_POST(self):
        if self.parts() != ["vms"]:
            self.reply(404, {"error": "unknown path"})
            return
        try:
            length = int(self.headers.get("Content-Length", "0"))
            body = json.loads(self.rfile.read(length) or b"{}")
        except (ValueError, json.JSONDecodeError):
            self.reply(400, {"error": "body must be JSON"})
            return
        status, result = start_machine(body.get("name"), body.get("args"))
        self.reply(status, result)

    def do_DELETE(self):
        parts = self.parts()
        if len(parts) == 2 and parts[0] == "vms":
            status, result = stop_machine(parts[1])
            self.reply(status, result)
        else:
            self.reply(404, {"error": "unknown path"})

    def log_message(self, format, *args):
        sys.stderr.write("labd: " + (format % args) + "\n")


def main():
    os.makedirs(os.path.join(STATE_DIR, "run"), exist_ok=True)
    server = ThreadingHTTPServer(("0.0.0.0", PORT), Handler)

    def shutdown(signum, frame):
        for name in list(machines):
            stop_machine(name)
        threading.Thread(target=server.shutdown, daemon=True).start()

    signal.signal(signal.SIGTERM, shutdown)
    signal.signal(signal.SIGINT, shutdown)
    sys.stderr.write(f"labd: listening on port {PORT}; {qemu_version()}; kvm={os.access('/dev/kvm', os.R_OK | os.W_OK)}\n")
    server.serve_forever()
    return 0


if __name__ == "__main__":
    sys.exit(main())
