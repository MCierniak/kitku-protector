# Spike: can Windows block a keyboard without a driver or a hook?

This folder holds the experiments that decide how KitkuProtector blocks a keyboard.
They run inside Windows guests in the emulated lab (see `lab/README.md`), where a guest
has a PS/2, a USB and a virtio keyboard side by side. They answer three questions:

1. Can Windows stop a keyboard while it runs, and keep it stopped?
2. Does the keyboard stay dead on the lock screen, through sleep and until a restart?
3. How fast can a standard user trigger code that runs as SYSTEM?

`KitkuSpike.ps1` contains the test functions. Nothing in it installs software.
Three optional functions change settings and say so below: `Set-KitkuAllowDisable`,
`Install-KitkuTriggerProbe` and the persistent variants of test T4b.

## How the tests are run

- Inside a Windows guest, in an elevated 64-bit PowerShell, unless a test says otherwise.
- Each test names a keyboard under test. "Typing" on it means the host injects key
  presses into that one emulated keyboard; `lab/keyboard_routing.py` shows how.
- Guests are throwaway. If a keyboard stays dead, run `Restore-KitkuKeyboard -All`, or
  reset the guest.
- Every function writes to `KitkuSpike-<model>.log` next to the script.

Building Windows guests and driving them from the test rig is phase 1 of the plan. Until
that exists, the commands below can be typed into a guest by hand.

## The one check that needs a real laptop

The lab cannot tell you what your own laptop has. This is read-only and needs no admin.

PowerShell:

```powershell
Get-CimInstance Win32_PnPEntity -Filter "PNPClass='Keyboard'" | Where-Object Present | Format-List Name, Service, PNPDeviceID
```

Command Prompt:

```bat
pnputil /enum-devices /class Keyboard /connected
```

Expected output: one block per keyboard device. Read it like this:

| You see | Meaning |
| --- | --- |
| `Service : i8042prt`, ID starts with `ACPI\` | PS/2 keyboard |
| `Service : kbdhid`, ID starts with `HID\` | HID keyboard (USB, I2C, Bluetooth, Surface) |

## Loading the script

```powershell
cd <folder that contains KitkuSpike.ps1>
Set-ExecutionPolicy -Scope Process Bypass -Force
. .\KitkuSpike.ps1
```

Expected output: a `SESSION START` banner, the command list and the log file path.
After every sign-out, shutdown or restart the script has to be loaded again.

## T0: environment snapshot

No admin needed. Two lines are filled in only when it runs elevated.

```powershell
Get-KitkuEnvironment
```

Expected output: about 25 lines. The ones that matter:

| Line | What it tells us |
| --- | --- |
| `Windows` | Edition, version, build and architecture (x64 or ARM64) |
| `PowerShell ... language mode` | `FullLanguage` is needed for T2 to T8 |
| `Secure Boot`, `Device Guard`, `Code integrity policy` | Whether a kernel driver could load on this machine |
| `Fast Startup`, `Sleep states` | Which shutdown and sleep variants T5 has to cover |
| `Keyboard class filters` | Anything other than `kbdclass` means other software already filters the keyboard |
| `Sign-in policies` | Whether Ctrl+Alt+Del is required at sign-in |

## T1: keyboard inventory

No admin needed.

```powershell
Get-KitkuKeyboards -Detailed
```

Expected output: one block per keyboard, like this:

```text
[1] Standard PS/2 Keyboard
    InstanceId  : ACPI\XXX0000\4&12345678&0
    Transport   : PS/2 (i8042prt)
    Built-in    : True   (True = Windows places it in the "this computer" container)
    State       : 0x0180000A [STARTED DRIVER_LOADED] | problem 0 (none) | PnP status "OK"
    Disableable : False
```

- `Transport` answers PS/2 or HID.
- `Built-in` shows which of the lab's keyboards Windows treats as part of the computer.
  The app will use this to suggest the built-in keyboard, so note the value for each one.
- `Disableable : False` is expected for every keyboard. `True` would be a surprise worth recording.

Then store the ID of the keyboard under test. Use single quotes:

```powershell
$kb = '<InstanceId of the keyboard under test>'
```

T2 to T5 are run once per keyboard type.

## T2: Windows refuses a plain "disable"

Takes 10 seconds.

```powershell
Test-KitkuBlock -InstanceId $kb -Method Disable -Seconds 5 -Countdown 0
```

Expected output:

```text
  CM_Disable_DevNode(non-persistent) -> CR_NOT_DISABLEABLE (0x28) in 3 ms
  RESULT: NOT BLOCKED (the device is still running).
```

The keyboard keeps working. If it says `RESULT: BLOCKED` instead, this keyboard can be
disabled the simple way, which would be the best possible outcome.

## T3: stop and restart with Microsoft's own tool

Takes 10 seconds. This is the test that separates HID from PS/2.

```powershell
Test-KitkuRestart -InstanceId $kb
```

| Keyboard | Expected output | Meaning |
| --- | --- | --- |
| HID | `Device restarted successfully.` and the keyboard drops out for a moment | Windows can stop this keyboard while running |
| PS/2 | `System reboot is needed to complete configuration operations!` or `Device is pending system reboot to complete a previous operation.` The keyboard keeps working. | Windows cannot stop this keyboard while running |

The PS/2 row is a prediction, and confirming or refuting it is the point of the test.

## T4: stop the keyboard and hold it stopped

This is the main test. The keyboard is restored automatically after the time is up.

```powershell
Test-KitkuBlock -InstanceId $kb -Method Hold -Seconds 60
```

Expected output on a HID keyboard:

```text
  CM_Query_And_Remove_SubTree(NO_RESTART) -> CR_SUCCESS (0x00) in 180 ms
  state after block attempt : 0x........ [...] | problem NN (...)
  RESULT: BLOCKED. Try the keyboard now (60 s). Press Ctrl+C to restore early.
  ...
  restore step RESET         : CR_SUCCESS (0x00) (4 ms) -> ...
  restore step REENUM_DEVICE : CR_SUCCESS (0x00) (250 ms) -> 0x........ [STARTED DRIVER_LOADED] | problem 0 (none)
  RESTORED by step REENUM_DEVICE.
```

The numbers, the problem code and the restore step that works are unknown; the log records them.
A line starting with `!! the device came back BY ITSELF` means the block did not hold.

Expected output on a PS/2 keyboard (prediction):

```text
  CM_Query_And_Remove_SubTree(NO_RESTART) -> CR_REMOVE_VETOED (0x17) in 5 ms
  veto: PNP_VetoDevice (6), veto name "ACPI\..."
  RESULT: NOT BLOCKED (the device is still running).
```

While the keyboard is blocked, inject keys and record what Windows receives:

| # | Check | Expected |
| --- | --- | --- |
| a | Type on the blocked keyboard | Nothing arrives |
| b | Type on another keyboard | Arrives normally |
| c | Send Ctrl+Alt+Del on the blocked keyboard | Nothing happens |

### T4 stuck-key run

Keys held down at the moment of blocking may stay "pressed". Run it again and hold
a letter key and Shift on the keyboard under test during the countdown, by injecting
key-down events without the matching key-up:

```powershell
Test-KitkuBlock -InstanceId $kb -Method Hold -Seconds 20 -Countdown 8
```

Record two things: does the letter keep repeating after the block starts, and does
typing on another keyboard produce capitals as if Shift were stuck? The expected result
is unknown.

### T4b: two more methods (HID keyboards only)

Run these only if T3 reported `Device restarted successfully`. The script refuses them on
a PS/2 keyboard, because Windows might disable that keyboard at the next boot instead.

```powershell
Test-KitkuBlock -InstanceId $kb -Method RemoveDisable -Seconds 20
Test-KitkuBlock -InstanceId $kb -Method PnpUtilForce  -Seconds 20
```

Expected output: unknown for both. Possible results:

| Output | Meaning |
| --- | --- |
| `CR_REMOVE_VETOED` with `PNP_VetoNonDisableable (10)` | Windows applies the "not disableable" rule to this call too |
| `Device disabled successfully.` and `problem 22 (DISABLED)` | Microsoft's tool can force-disable a keyboard; a second candidate mechanism |
| `Cannot disable critical system device.` | `/force` did not help |

If `PnpUtilForce` blocked the keyboard, check whether that block survives a restart:

```powershell
Block-KitkuKeyboard -InstanceId $kb -Method PnpUtilForce
# restart Windows, load the script again, then:
Get-KitkuState 'after restart, PnpUtilForce'
Restore-KitkuKeyboard -InstanceId $kb -Method PnpUtilForce
```

`STOPPED` after the restart means this method is persistent, which makes it less safe.

## T5: does the block hold through real use?

Run it only if T4 said `BLOCKED`. After each step run the state check with a note, so
the log shows which step it belongs to.

```powershell
Block-KitkuKeyboard -InstanceId $kb
```

| Step | Do this | Then run | Expected |
| --- | --- | --- | --- |
| 1 | Run `pnputil /scan-devices` in a second elevated console | `Get-KitkuState 'after scan'` | `STOPPED` |
| 2 | Add a USB keyboard to the guest, then remove it | `Get-KitkuState 'after usb'` | `STOPPED` |
| 3 | Lock the session. Type the password on the blocked keyboard. | `Get-KitkuState 'after lock'` | Still locked; `STOPPED` |
| 4 | Type the password on another keyboard | nothing | The session unlocks |
| 5 | Sleep the guest, then wake it | `Get-KitkuState 'after sleep'` | `STOPPED` |
| 6 | Hibernate the guest with `shutdown /h`, then power on | `Get-KitkuState 'after hibernate'` | `STOPPED` |
| 7 | Sign out and sign in. Load the script. | `Get-KitkuState 'after sign-out'` | `STOPPED` |
| 8 | Shut down with Fast Startup on, then power on. Load the script. | `Get-KitkuState 'after shutdown'` | Unknown. It may still be `STOPPED`. |
| 9 | Restart. Load the script. | `Get-KitkuState 'after restart'` | `running` |

If a step shows `running` earlier than expected, record the step and block again before continuing.
Afterwards:

```powershell
Restore-KitkuKeyboard -All
```

Two checks are done by hand through the guest's screen, once: what Device Manager shows
for the blocked keyboard, and whether a sign-in with only the mouse and the On-Screen
Keyboard works while every keyboard is blocked.

## T6 (optional): the developer switch in the keyboard driver

Windows' keyboard class driver reads a registry value named `AllowDisable`. Microsoft's
driver developer described it as meant for developers' own machines. The test shows
whether a plain "disable" works once it is set. It affects all keyboards and needs two restarts.

```powershell
Set-KitkuAllowDisable
# restart Windows, load the script, set $kb again, then:
Get-KitkuKeyboards
Test-KitkuBlock -InstanceId $kb -Method Disable -Seconds 30
Set-KitkuAllowDisable -Remove
# restart Windows
```

Expected output after the first restart: `Disableable : True` for HID keyboards, then
`CM_Disable_DevNode(non-persistent) -> CR_SUCCESS`, `problem 22 (DISABLED)` and
`RESTORED by step ENABLE`. For a PS/2 keyboard the result is unknown, and it is the
second independent answer to "can PS/2 be stopped".

## T7 (optional): task or service?

This measures how long it takes from a standard user's request until code runs as SYSTEM,
for a scheduled task and for a demand-start service. It also proves that a standard user
may start them.

Elevated console:

```powershell
Install-KitkuTriggerProbe
```

Normal, non-elevated console of a standard user:

```powershell
. .\KitkuSpike.ps1
Measure-KitkuTrigger
```

Elevated console again:

```powershell
Remove-KitkuTriggerProbe
```

Expected output of the measurement, which can take a few minutes:

```text
  run 1: task    -> SYSTEM code ran after 420 ms
  run 1: service -> SYSTEM code ran after 60 ms
  ...
  task   : 5 of 5 runs ok | min ... ms | median ... ms | max ... ms
  service: 5 of 5 runs ok | min ... ms | median ... ms | max ... ms
```

The numbers above are guesses. `FAILED: Access is denied` or `StartService error 5`
means a standard user could not start it, which is just as important to know.
Windows reports error 1053 for the probe service; that is expected, because the probe is
not a real service.

## T8 (optional): can a standard user stop a keyboard?

Normal, non-elevated console. Windows lets interactive users request "safe removal" of
some devices without admin rights. This checks whether that reaches a keyboard.

```powershell
Test-KitkuEjectAsUser -InstanceId $kb
```

Expected output (prediction): `CR_REMOVE_VETOED` or `CR_ACCESS_DENIED`, and the keyboard
keeps working. If the keyboard stops, restore it from the elevated console with
`Restore-KitkuKeyboard -All`.

## Lab check: one key press, one keyboard

`lab/keyboard_routing.py` proves the property the whole lab rests on: QEMU can deliver a
key press to one chosen emulated keyboard. It boots a small Linux live image with three
keyboards and reports which one received each injected key. It needs the Alpine "virt"
ISO in `lab/iso/`, and no Windows. Run it inside the development container (see
`lab/README.md`); it asks the lab container to start QEMU.

```bash
python3 spike/lab/keyboard_routing.py --iso lab/iso/alpine-virt-3.24.4-x86_64.iso --accel kvm
```

Expected output, as measured with QEMU 10.2.1 and KVM:

```text
guest booted in 5 s (lab daemon at http://lab:7780, accelerator: kvm)
...
RESULTS (which guest input device produced events)
  send-key (no target)             -> AT Translated Set 2 keyboard   [ok]
  input-send-event device=dispA    -> QEMU QEMU USB Keyboard   [ok]
  input-send-event device=dispB    -> QEMU Virtio Keyboard   [ok]
  input-send-event device=vga0     -> AT Translated Set 2 keyboard   [ok]

VERDICT: every injection reached exactly one keyboard
```

Without KVM (`--accel tcg`) the same guest takes about half a minute to boot.

## Experiments that change persistent settings

Run these in a guest that is reset afterwards.

### E1: driver swap

Give the keyboard device a driver that does not fit it, through Device Manager: Update
driver, Browse my computer, Let me pick, untick "Show compatible hardware", choose another
model. Do it once for the PS/2 keyboard and once for the USB keyboard.

| Question | Why it matters |
| --- | --- |
| Does the keyboard go silent at once, or only after a restart? | A swap that needs a restart cannot be the one-click toggle |
| Is the keyboard still silent after a restart? | It is expected to be, which removes the "a restart always unblocks" fail-safe |
| Does Windows put the fitting driver back by itself? | It would make the block unreliable |

### E2: restart-based off switch for a PS/2 keyboard

Mark the PS/2 keyboard as disabled with `pnputil /disable-device "<InstanceId>" /force`,
restart, and check with `Get-KitkuState`. Then run `pnputil /enable-device "<InstanceId>"`
and restart again.

| Outcome | Meaning |
| --- | --- |
| Keyboard dead after the first restart, alive after the second | PS/2 keyboards can be switched off without a driver or a hook, at the price of a restart each way |
| Keyboard still alive after the first restart | This route does not exist either |

## Results

The answers go into the PRD: the chosen blocking mechanism, task or service, and what
the app does on PS/2 keyboards.
