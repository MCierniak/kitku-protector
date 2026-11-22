# KitkuProtector test lab

The lab runs Windows guests in QEMU so that keyboard blocking can be tested without a
laptop. It consists of two containers that start together:

| Container | Contents | Role |
| --- | --- | --- |
| `dev` | Python, pytest, git, Claude Code | The development container. Tests and tools run here. |
| `lab` | QEMU with KVM, UEFI firmware, software TPM, `labd` | Runs the guests. Controlled by `dev` over the private network between the two. |

## Requirements

- Linux or WSL2 with Docker and Docker Compose.
- `/dev/kvm` on the host. On WSL2 that means Windows 11 with nested virtualisation, which is on by default.
- VS Code with the Dev Containers extension, or the `devcontainer` command-line tool.

## Starting it

In VS Code, opened on this folder: run **Dev Containers: Reopen in Container**.

From a shell:

```bash
devcontainer up --workspace-folder .
```

Either way `.devcontainer/initialize.sh` runs on the host first. It writes
`.devcontainer/.env` so that the containers use your user name, your home directory and
the same workspace path as the host.

## What the development container shares with the host

| Host path | In the container | Why |
| --- | --- | --- |
| This repository | Same absolute path | Claude Code and the PRP tools key their state by that path |
| `~/.claude` | Same path | Claude Code login, settings, skills, sessions and memory |
| This repository's PRP store under `~/.prp` | Same path | PRD, plans and reports stay in one place |

Claude Code's state file is `~/.claude/.claude.json` inside the container. It is seeded
once from the host's `~/.claude.json`; after that the two are independent.

## What the lab container sees

| Source | In the container | Access |
| --- | --- | --- |
| This repository | Same absolute path | Read-only |
| Installation media | `/iso` | Read-only |
| Docker volume `lab-data` | `/var/lib/kitku-lab` | Disk images, overlays, TPM state, logs |

Installation media default to `lab/iso/` in this repository, which is never committed.
To use another directory, create `.devcontainer/local.env`:

```text
KITKU_ISO_DIR=/mnt/d/ISO
```

## Talking to the lab

`labd` listens on `http://lab:7780`; the address is in `KITKU_LAB_URL` inside `dev`.

| Request | Effect |
| --- | --- |
| `GET /health` | QEMU version and whether KVM is usable |
| `POST /vms` with `{"name": "...", "args": [...]}` | Start QEMU with these arguments |
| `GET /vms`, `GET /vms/<name>` | State of the machines |
| `GET /vms/<name>/log` | Last part of QEMU's output |
| `DELETE /vms/<name>` | Stop a machine |

The caller picks TCP ports for QMP and serial consoles in the QEMU arguments and connects
to `lab:<port>` directly.

```bash
curl -s "$KITKU_LAB_URL/health"
```

Expected output:

```json
{"status": "ok", "qemu": "QEMU emulator version 10.2.1 (Debian 1:10.2.1+ds-1ubuntu3.3)", "kvm": true, "machines": 0}
```

## Checking the whole chain

This boots a small Linux guest with three keyboards in the lab and types on each one
separately. It needs the Alpine "virt" ISO in `lab/iso/`.

```bash
python3 spike/lab/keyboard_routing.py --iso lab/iso/alpine-virt-3.24.4-x86_64.iso --accel kvm
```

Expected output ends with:

```text
VERDICT: every injection reached exactly one keyboard
```

## Limits

- `labd` has no authentication. It is reachable only from the `dev` container; do not
  publish its port.
- No port is published to the host. To watch a guest's screen, give QEMU `-vnc 0.0.0.0:0`
  and publish port 5900 in a compose override file.
- `labd` is a first cut: it starts and stops QEMU and nothing else. Building Windows
  guests, disk overlays and the TPM are still to come.
