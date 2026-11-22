<#
KitkuSpike.ps1 - spike helpers for KitkuProtector.

Purpose
    Find out which built-in Windows mechanisms can block a keyboard at device level -
    without a kernel driver and without keyboard hooks. Written for the Windows guests
    of the emulated lab; it runs on a real machine just the same.

Usage (64-bit Windows PowerShell 5.1 or PowerShell 7)
    Set-ExecutionPolicy -Scope Process Bypass -Force
    . .\KitkuSpike.ps1
    Get-KitkuHelp

Notes
    * Nothing here installs software or changes settings permanently, except the
      optional functions that say so (Set-KitkuAllowDisable, Install-KitkuTriggerProbe).
    * Every function appends to a log file; its path is printed when the script loads.
      The log holds hardware model and device IDs, but no user name and no computer name.
    * This file is plain ASCII on purpose: Windows PowerShell 5.1 reads BOM-less
      scripts as ANSI.
    * See README.md next to this file for the test list and the expected outputs.
#>

$global:KitkuSpikeVersion = '1.0'

# ----------------------------------------------------------------------------------
# Logging
# ----------------------------------------------------------------------------------

function Get-KitkuModelSlug {
    try {
        $cs = Get-CimInstance -ClassName Win32_ComputerSystem -ErrorAction Stop
        $raw = ('{0}-{1}' -f $cs.Manufacturer, $cs.Model)
        $slug = ($raw -replace '[^A-Za-z0-9]+', '-').Trim('-')
        if ($slug.Length -gt 48) { $slug = $slug.Substring(0, 48) }
        if ($slug) { return $slug }
    } catch { }
    return 'unknown-model'
}

function Initialize-KitkuLog {
    $name = 'KitkuSpike-{0}.log' -f (Get-KitkuModelSlug)
    $candidates = @()
    if ($PSScriptRoot) { $candidates += $PSScriptRoot }
    $candidates += $env:TEMP
    foreach ($dir in $candidates) {
        $path = Join-Path $dir $name
        try {
            Add-Content -LiteralPath $path -Value '' -Encoding UTF8 -ErrorAction Stop
            $global:KitkuLogPath = $path
            return
        } catch { }
    }
    $global:KitkuLogPath = $null
}

function Write-KLog {
    param(
        [Parameter(Position = 0, ValueFromPipeline = $true)]
        [AllowEmptyString()][AllowNull()]
        [string]$Text = ''
    )
    process {
        Write-Host $Text
        if ($global:KitkuLogPath) {
            try { Add-Content -LiteralPath $global:KitkuLogPath -Value $Text -Encoding UTF8 -ErrorAction Stop } catch { }
        }
    }
}

function Write-KLogHeader {
    param([string]$Title)
    Write-KLog ''
    Write-KLog ('=' * 78)
    Write-KLog ('{0}   [{1}]' -f $Title, (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'))
    Write-KLog ('=' * 78)
}

# ----------------------------------------------------------------------------------
# Small helpers that also work in Constrained Language Mode
# ----------------------------------------------------------------------------------

function Test-KitkuElevated {
    # High (S-1-16-12288) or System (S-1-16-16384) integrity level means "elevated".
    $groups = & "$env:SystemRoot\System32\whoami.exe" /groups 2>$null
    return [bool]($groups -match 'S-1-16-(12288|16384)')
}

function Get-KitkuDevices {
    # Devices of the given setup classes, read through WMI (Win32_PnPEntity).
    param([string[]]$Classes, [switch]$PresentOnly)
    $filter = (($Classes | ForEach-Object { "PNPClass='{0}'" -f $_ }) -join ' OR ')
    $items = @(Get-CimInstance -ClassName Win32_PnPEntity -Filter $filter -ErrorAction Stop)
    if ($PresentOnly) { $items = @($items | Where-Object { $_.Present }) }
    return @($items | Sort-Object PNPClass, DeviceID)
}

function Get-KitkuProps {
    # Returns a hashtable: property key name -> value (missing keys are simply absent).
    param([string]$InstanceId, [string[]]$Keys)
    $result = @{}
    try {
        $entity = New-CimInstance -ClassName Win32_PnPEntity -Property @{ DeviceID = $InstanceId } -Key DeviceID -ClientOnly -ErrorAction Stop
        $reply = Invoke-CimMethod -InputObject $entity -MethodName GetDeviceProperties -Arguments @{ devicePropertyKeys = $Keys } -ErrorAction Stop
        foreach ($item in $reply.deviceProperties) { $result[$item.KeyName] = $item.Data }
    } catch { }
    return $result
}

function Get-KitkuChain {
    # The device and its ancestors, nearest first.
    param([string]$InstanceId)
    $chain = @()
    $id = $InstanceId
    for ($i = 0; ($i -lt 14) -and $id; $i++) {
        $p = Get-KitkuProps $id @('DEVPKEY_Device_Service', 'DEVPKEY_Device_Parent')
        # Plain hashtables on purpose: [pscustomobject] is not allowed in Constrained Language Mode.
        $chain += @{ InstanceId = [string]$id; Service = [string]$p['DEVPKEY_Device_Service'] }
        $id = $p['DEVPKEY_Device_Parent']
    }
    return $chain
}

function Get-KitkuTransport {
    # Classifies how the keyboard is attached. $Chain[0] is the keyboard device itself.
    param($Chain)
    $svc0 = [string]$Chain[0].Service
    $ids = (($Chain | ForEach-Object { $_.InstanceId }) -join '|')
    $svcs = (($Chain | ForEach-Object { $_.Service }) -join '|')
    if ($svc0 -eq 'i8042prt') { return 'PS/2 (i8042prt)' }
    if ($ids -match '(^|\|)TERMINPUT_BUS\\') { return 'Remote Desktop (virtual)' }
    if ($svc0 -eq 'kbdhid') {
        if (($ids -match '(^|\|)(BTHENUM|BTHLE|BTHLEDEVICE)\\') -or ($svcs -match 'HidBth|BthLEEnum')) { return 'HID over Bluetooth' }
        if ($svcs -match '(^|\|)hidi2c') { return 'HID over I2C' }
        if ($svcs -match '(^|\|)hidspi') { return 'HID over SPI' }
        if ($ids -match '(^|\|)USB\\') { return 'HID over USB' }
        if ($ids -match '2DEDC554-A829-42AB-90E9-E4E4B4772981') { return 'HID over Surface SAM' }
        return 'HID (other bus)'
    }
    return ('other (service: {0})' -f $svc0)
}

function Format-KitkuDn {
    # Human-readable subset of the DN_* status flags.
    param($Status)
    if ($null -eq $Status) { return 'n/a' }
    $s = [uint32]$Status
    $names = @()
    if ($s -band 0x00000008) { $names += 'STARTED' }
    if ($s -band 0x00000002) { $names += 'DRIVER_LOADED' }
    if ($s -band 0x00000400) { $names += 'HAS_PROBLEM' }
    if ($s -band 0x00002000) { $names += 'DISABLEABLE' }
    if ($s -band 0x00004000) { $names += 'REMOVABLE' }
    if ($s -band 0x00000100) { $names += 'NEED_RESTART' }
    if ($s -band 0x00040000) { $names += 'WILL_BE_REMOVED' }
    if ($s -band 0x00010000) { $names += 'QUERY_REMOVE_PENDING' }
    if ($s -band 0x00020000) { $names += 'QUERY_REMOVE_ACTIVE' }
    if ($s -band 0x02000000) { $names += 'DEVICE_DISCONNECTED' }
    return ('0x{0:X8} [{1}]' -f $s, ($names -join ' '))
}

$global:KitkuProblemNames = @{
    0 = 'none'; 1 = 'NOT_CONFIGURED'; 10 = 'FAILED_START'; 14 = 'NEED_RESTART'; 18 = 'REINSTALL'
    21 = 'WILL_BE_REMOVED'; 22 = 'DISABLED'; 24 = 'DEVICE_NOT_THERE'; 28 = 'FAILED_INSTALL'
    32 = 'DISABLED_SERVICE'; 43 = 'FAILED_POST_START'; 44 = 'HALTED'; 45 = 'PHANTOM'
    46 = 'SYSTEM_SHUTDOWN'; 47 = 'HELD_FOR_EJECT'
}

function Format-KitkuProblem {
    param($Problem)
    if ($null -eq $Problem) { return 'n/a' }
    $n = [int]$Problem
    $name = $global:KitkuProblemNames[$n]
    if (-not $name) { $name = '?' }
    return ('{0} ({1})' -f $n, $name)
}

# ----------------------------------------------------------------------------------
# T0 - environment snapshot (read-only, no admin needed; a few lines need admin)
# ----------------------------------------------------------------------------------

function Get-KitkuEnvironment {
    Write-KLogHeader 'T0 ENVIRONMENT'
    Write-KLog ('spike script version   : {0}' -f $global:KitkuSpikeVersion)

    try {
        $cv = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' -ErrorAction Stop
        $os = Get-CimInstance Win32_OperatingSystem -ErrorAction Stop
        Write-KLog ('Windows                : {0} | edition {1} | version {2} | build {3}.{4} | {5}' -f `
            $os.Caption, $cv.EditionID, $cv.DisplayVersion, $cv.CurrentBuild, $cv.UBR, $os.OSArchitecture)
    } catch { Write-KLog ('Windows                : (failed to read: {0})' -f $_.Exception.Message) }

    try {
        $cs = Get-CimInstance Win32_ComputerSystem -ErrorAction Stop
        Write-KLog ('Machine                : {0} {1} | PCSystemType {2} (2 = laptop) | domain-joined: {3}' -f `
            $cs.Manufacturer, $cs.Model, $cs.PCSystemType, $cs.PartOfDomain)
    } catch { Write-KLog 'Machine                : (failed to read)' }

    Write-KLog ('PowerShell             : {0} {1} | language mode: {2} | process arch: {3} | WOW64: {4}' -f `
        $PSVersionTable.PSEdition, $PSVersionTable.PSVersion, $ExecutionContext.SessionState.LanguageMode, `
        $env:PROCESSOR_ARCHITECTURE, [bool]$env:PROCESSOR_ARCHITEW6432)
    Write-KLog ('Elevated console       : {0}' -f (Test-KitkuElevated))

    try { Write-KLog ('Secure Boot            : {0}' -f (Confirm-SecureBootUEFI -ErrorAction Stop)) }
    catch { Write-KLog ('Secure Boot            : unknown ({0})' -f $_.Exception.Message.Trim()) }

    try {
        $dg = Get-CimInstance -Namespace 'root\Microsoft\Windows\DeviceGuard' -ClassName Win32_DeviceGuard -ErrorAction Stop
        Write-KLog ('Device Guard           : VBS status {0} (2 = running) | services running: [{1}] (2 = memory integrity/HVCI)' -f `
            $dg.VirtualizationBasedSecurityStatus, ($dg.SecurityServicesRunning -join ','))
        Write-KLog ('Code integrity policy  : kernel-mode {0} | user-mode {1}   (0 = off, 1 = audit, 2 = enforced)' -f `
            $dg.CodeIntegrityPolicyEnforcementStatus, $dg.UsermodeCodeIntegrityPolicyEnforcementStatus)
    } catch { Write-KLog ('Device Guard           : unknown ({0})' -f $_.Exception.Message.Trim()) }

    try {
        $sac = (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\CI\Policy' -ErrorAction Stop).VerifiedAndReputablePolicyState
        Write-KLog ('Smart App Control      : {0}   (0 = off, 1 = on, 2 = evaluation, empty = not present)' -f $sac)
    } catch { Write-KLog 'Smart App Control      : not present' }

    try {
        $fs = (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Power' -ErrorAction Stop).HiberbootEnabled
        Write-KLog ('Fast Startup           : {0}   (1 = on)' -f $fs)
    } catch { Write-KLog 'Fast Startup           : unknown' }

    Write-KLog 'Sleep states (powercfg /a):'
    try { & "$env:SystemRoot\System32\powercfg.exe" /a 2>&1 | ForEach-Object { Write-KLog ('    {0}' -f $_) } }
    catch { Write-KLog '    (powercfg failed)' }

    try {
        $kp = Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Services\kbdclass\Parameters' -ErrorAction Stop
        Write-KLog ('kbdclass AllowDisable  : {0}   (empty = not set, which is the default)' -f $kp.AllowDisable)
    } catch { Write-KLog 'kbdclass AllowDisable  : unknown' }

    try {
        $cls = Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Class\{4d36e96b-e325-11ce-bfc1-08002be10318}' -ErrorAction Stop
        Write-KLog ('Keyboard class filters : upper [{0}] | lower [{1}]   (default: upper = kbdclass only)' -f `
            ($cls.UpperFilters -join ', '), ($cls.LowerFilters -join ', '))
    } catch { Write-KLog 'Keyboard class filters : unknown' }

    try {
        $pol = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System' -ErrorAction Stop
        Write-KLog ('Sign-in policies       : DisableCAD = {0} (0 = Ctrl+Alt+Del required) | SoftwareSASGeneration = {1}' -f `
            $pol.DisableCAD, $pol.SoftwareSASGeneration)
    } catch { Write-KLog 'Sign-in policies       : unknown' }

    try {
        $help = & "$env:SystemRoot\System32\pnputil.exe" /disable-device /? 2>&1
        Write-KLog ('pnputil /force support : {0}' -f [bool]($help -match '/force'))
    } catch { Write-KLog 'pnputil /force support : unknown (pnputil failed)' }

    try {
        $kf = Get-WindowsOptionalFeature -Online -FeatureName 'Client-KeyboardFilter' -ErrorAction Stop
        Write-KLog ('Keyboard Filter feature: {0}' -f $kf.State)
    } catch { Write-KLog ('Keyboard Filter feature: unknown or not available ({0})' -f $_.Exception.Message.Trim()) }

    try {
        $ep = Get-ExecutionPolicy -List | ForEach-Object { '{0}={1}' -f $_.Scope, $_.ExecutionPolicy }
        Write-KLog ('Execution policy       : {0}' -f ($ep -join '; '))
    } catch { }

    Write-KLog ''
    Write-KLog ('Log file: {0}' -f $global:KitkuLogPath)
}

# ----------------------------------------------------------------------------------
# T1 - keyboard inventory: PS/2 or HID, built-in or external (read-only, no admin)
# ----------------------------------------------------------------------------------

function Get-KitkuKeyboards {
    param(
        [switch]$Detailed,   # also dump all present Keyboard / HIDClass / Mouse devices
        [switch]$PassThru    # also return objects
    )
    Write-KLogHeader 'T1 KEYBOARDS'
    $keys = @(
        'DEVPKEY_Device_Service', 'DEVPKEY_Device_InLocalMachineContainer', 'DEVPKEY_Device_ContainerId',
        'DEVPKEY_Device_DevNodeStatus', 'DEVPKEY_Device_ProblemCode', 'DEVPKEY_Device_Capabilities',
        'DEVPKEY_Device_UpperFilters', 'DEVPKEY_Device_LowerFilters', 'DEVPKEY_Device_BusReportedDeviceDesc'
    )
    $devices = @()
    try { $devices = @(Get-KitkuDevices -Classes @('Keyboard') -PresentOnly) }
    catch {
        Write-KLog ('Could not list devices through WMI ({0}). Falling back to pnputil:' -f $_.Exception.Message.Trim())
        & "$env:SystemRoot\System32\pnputil.exe" /enum-devices /class Keyboard /connected 2>&1 | ForEach-Object { Write-KLog ('    {0}' -f $_) }
        Write-KLog 'An "Instance ID" starting with ACPI\ is a PS/2 keyboard; one starting with HID\ is a HID keyboard.'
        return
    }
    if ($devices.Count -eq 0) { Write-KLog 'No present keyboard devices found.'; return }

    $out = @()
    $n = 0
    foreach ($d in $devices) {
        $n++
        $p = Get-KitkuProps $d.DeviceID $keys
        $chain = @(Get-KitkuChain $d.DeviceID)
        $transport = Get-KitkuTransport $chain
        $status = $p['DEVPKEY_Device_DevNodeStatus']
        $disableable = $false
        if ($null -ne $status) { $disableable = [bool]([uint32]$status -band 0x2000) }
        $obj = @{
            Index       = $n
            Name        = $d.Name
            InstanceId  = $d.DeviceID
            Transport   = $transport
            BuiltIn     = $p['DEVPKEY_Device_InLocalMachineContainer']
            Service     = $p['DEVPKEY_Device_Service']
            Disableable = $disableable
            Status      = $status
            Problem     = $p['DEVPKEY_Device_ProblemCode']
        }
        $out += $obj

        Write-KLog ''
        Write-KLog ('[{0}] {1}' -f $n, $d.Name)
        Write-KLog ('    InstanceId  : {0}' -f $d.DeviceID)
        Write-KLog ('    Transport   : {0}' -f $transport)
        Write-KLog ('    Built-in    : {0}   (True = Windows places it in the "this computer" container)' -f $obj.BuiltIn)
        Write-KLog ('    State       : {0} | problem {1} | PnP status "{2}"' -f (Format-KitkuDn $status), (Format-KitkuProblem $obj.Problem), $d.Status)
        Write-KLog ('    Disableable : {0}' -f $disableable)
        Write-KLog ('    Capabilities: {0} | bus-reported name: "{1}"' -f $p['DEVPKEY_Device_Capabilities'], $p['DEVPKEY_Device_BusReportedDeviceDesc'])
        Write-KLog ('    Dev filters : upper [{0}] | lower [{1}]' -f ($p['DEVPKEY_Device_UpperFilters'] -join ', '), ($p['DEVPKEY_Device_LowerFilters'] -join ', '))
        Write-KLog '    Ancestors   :'
        foreach ($c in $chain) { Write-KLog ('        {0}   (service: {1})' -f $c.InstanceId, $c.Service) }
    }

    Write-KLog ''
    Write-KLog 'How to read this: Transport "PS/2 (i8042prt)" means a PS/2 keyboard; "HID over ..." means a HID keyboard.'
    Write-KLog 'The built-in keyboard is normally the one with Built-in = True.'

    if ($Detailed) {
        Write-KLog ''
        Write-KLog '--- all present Keyboard / HIDClass / Mouse devices ---'
        Write-KLog 'class | status | service | built-in | container | instance id | name | parent'
        $all = @(Get-KitkuDevices -Classes @('Keyboard', 'HIDClass', 'Mouse') -PresentOnly)
        foreach ($d in $all) {
            $p = Get-KitkuProps $d.DeviceID @('DEVPKEY_Device_Service', 'DEVPKEY_Device_InLocalMachineContainer',
                'DEVPKEY_Device_ContainerId', 'DEVPKEY_Device_DevNodeStatus', 'DEVPKEY_Device_Parent')
            $st = $p['DEVPKEY_Device_DevNodeStatus']
            $stText = 'n/a'
            if ($null -ne $st) { $stText = ('0x{0:X8}' -f [uint32]$st) }
            Write-KLog ('{0} | {1} | {2} | {3} | {4} | {5} | {6} | {7}' -f $d.PNPClass, $stText, $p['DEVPKEY_Device_Service'],
                $p['DEVPKEY_Device_InLocalMachineContainer'], $p['DEVPKEY_Device_ContainerId'], $d.DeviceID, $d.Name,
                $p['DEVPKEY_Device_Parent'])
        }
    }

    Write-KLog ''
    Write-KLog ('Log file: {0}' -f $global:KitkuLogPath)
    if ($PassThru) {
        if ($ExecutionContext.SessionState.LanguageMode -eq 'FullLanguage') {
            return @($out | ForEach-Object { New-Object psobject -Property $_ })
        }
        return $out
    }
}

# ----------------------------------------------------------------------------------
# Native API access (needs Full Language Mode). Used by the tests below.
# ----------------------------------------------------------------------------------

$global:KitkuNativeSource = @'
using System;
using System.Text;
using System.Threading;
using System.Runtime.InteropServices;

public static class KitkuNative
{
    [DllImport("cfgmgr32.dll", CharSet = CharSet.Unicode)]
    public static extern uint CM_Locate_DevNodeW(out uint pdnDevInst, string pDeviceID, uint ulFlags);

    [DllImport("cfgmgr32.dll")]
    public static extern uint CM_Get_DevNode_Status(out uint pulStatus, out uint pulProblemNumber, uint dnDevInst, uint ulFlags);

    [DllImport("cfgmgr32.dll")]
    public static extern uint CM_Get_Parent(out uint pdnDevInst, uint dnDevInst, uint ulFlags);

    [DllImport("cfgmgr32.dll", CharSet = CharSet.Unicode)]
    public static extern uint CM_Query_And_Remove_SubTreeW(uint dnAncestor, out int pVetoType, StringBuilder pszVetoName, uint ulNameLength, uint ulFlags);

    [DllImport("cfgmgr32.dll", CharSet = CharSet.Unicode)]
    public static extern uint CM_Request_Device_EjectW(uint dnDevInst, out int pVetoType, StringBuilder pszVetoName, uint ulNameLength, uint ulFlags);

    [DllImport("cfgmgr32.dll")]
    public static extern uint CM_Setup_DevNode(uint dnDevInst, uint ulFlags);

    [DllImport("cfgmgr32.dll")]
    public static extern uint CM_Reenumerate_DevNode(uint dnDevInst, uint ulFlags);

    [DllImport("cfgmgr32.dll")]
    public static extern uint CM_Disable_DevNode(uint dnDevInst, uint ulFlags);

    [DllImport("cfgmgr32.dll")]
    public static extern uint CM_Enable_DevNode(uint dnDevInst, uint ulFlags);

    [StructLayout(LayoutKind.Sequential, Pack = 1)]
    private struct TokPriv1Luid { public int Count; public long Luid; public int Attr; }

    [DllImport("advapi32.dll", SetLastError = true)]
    private static extern bool OpenProcessToken(IntPtr processHandle, int desiredAccess, out IntPtr tokenHandle);

    [DllImport("advapi32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    private static extern bool LookupPrivilegeValueW(string systemName, string name, out long luid);

    [DllImport("advapi32.dll", SetLastError = true)]
    private static extern bool AdjustTokenPrivileges(IntPtr tokenHandle, bool disableAll, ref TokPriv1Luid newState, int bufferLength, IntPtr previousState, IntPtr returnLength);

    [DllImport("kernel32.dll")]
    private static extern IntPtr GetCurrentProcess();

    [DllImport("kernel32.dll")]
    private static extern bool CloseHandle(IntPtr handle);

    // Enables a privilege in this process. Returns 0 on success, otherwise a Win32
    // error code (1300 = the account does not hold the privilege).
    public static int EnablePrivilege(string name)
    {
        IntPtr token;
        if (!OpenProcessToken(GetCurrentProcess(), 0x0020 | 0x0008, out token)) return Marshal.GetLastWin32Error();
        try
        {
            long luid;
            if (!LookupPrivilegeValueW(null, name, out luid)) return Marshal.GetLastWin32Error();
            TokPriv1Luid tp;
            tp.Count = 1;
            tp.Luid = luid;
            tp.Attr = 0x00000002;
            if (!AdjustTokenPrivileges(token, false, ref tp, 0, IntPtr.Zero, IntPtr.Zero)) return Marshal.GetLastWin32Error();
            return Marshal.GetLastWin32Error();
        }
        finally
        {
            CloseHandle(token);
        }
    }

    [DllImport("advapi32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    private static extern IntPtr OpenSCManagerW(string machineName, string databaseName, uint desiredAccess);

    [DllImport("advapi32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    private static extern IntPtr OpenServiceW(IntPtr scManager, string serviceName, uint desiredAccess);

    [DllImport("advapi32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    private static extern bool StartServiceW(IntPtr service, uint argc, IntPtr argv);

    [DllImport("advapi32.dll", SetLastError = true)]
    private static extern bool CloseServiceHandle(IntPtr handle);

    // -1 = start call still in progress, 0 = StartService succeeded, otherwise Win32 error.
    public static volatile int LastServiceStartError = -1;

    // Starts a service on a background thread and returns immediately.
    public static void StartServiceAsync(string name)
    {
        LastServiceStartError = -1;
        Thread thread = new Thread(delegate()
        {
            int err = 0;
            IntPtr scm = OpenSCManagerW(null, null, 0x0001);
            if (scm == IntPtr.Zero) { LastServiceStartError = Marshal.GetLastWin32Error(); return; }
            IntPtr svc = OpenServiceW(scm, name, 0x0010);
            if (svc == IntPtr.Zero)
            {
                err = Marshal.GetLastWin32Error();
                CloseServiceHandle(scm);
                LastServiceStartError = err;
                return;
            }
            if (!StartServiceW(svc, 0, IntPtr.Zero)) err = Marshal.GetLastWin32Error();
            CloseServiceHandle(svc);
            CloseServiceHandle(scm);
            LastServiceStartError = err;
        });
        thread.IsBackground = true;
        thread.Start();
    }
}
'@

function Initialize-KitkuNative {
    if ('KitkuNative' -as [type]) { return $true }
    if ($ExecutionContext.SessionState.LanguageMode -ne 'FullLanguage') {
        Write-KLog 'This console runs in Constrained Language Mode, so the API tests cannot run here.'
        Write-KLog 'T0 and T1 still work. For the other tests you need a console in Full Language Mode.'
        return $false
    }
    try {
        Add-Type -TypeDefinition $global:KitkuNativeSource -ErrorAction Stop
        return $true
    } catch {
        Write-KLog ('Could not compile the native API helper: {0}' -f $_.Exception.Message)
        return $false
    }
}

function Assert-KitkuAdmin {
    if (-not (Test-KitkuElevated)) {
        throw 'This test needs an elevated console (right-click PowerShell, "Run as administrator").'
    }
    if ($env:PROCESSOR_ARCHITEW6432) {
        throw 'This is a 32-bit PowerShell on 64-bit Windows. Start the 64-bit "Windows PowerShell" instead.'
    }
    if (-not (Initialize-KitkuNative)) { throw 'Native API helper is not available.' }
    $err = [KitkuNative]::EnablePrivilege('SeLoadDriverPrivilege')
    if ($err -ne 0) { Write-KLog ('  note: could not enable SeLoadDriverPrivilege (Win32 error {0})' -f $err) }
}

$global:KitkuCrNames = @{
    0 = 'CR_SUCCESS'; 4 = 'CR_INVALID_FLAG'; 5 = 'CR_INVALID_DEVNODE'; 13 = 'CR_NO_SUCH_DEVNODE'
    19 = 'CR_FAILURE'; 23 = 'CR_REMOVE_VETOED'; 30 = 'CR_INVALID_DEVICE_ID'; 31 = 'CR_INVALID_DATA'
    34 = 'CR_NEED_RESTART'; 36 = 'CR_DEVICE_NOT_THERE'; 40 = 'CR_NOT_DISABLEABLE'; 42 = 'CR_QUERY_VETOED'
    50 = 'CR_NO_CM_SERVICES'; 51 = 'CR_ACCESS_DENIED'; 52 = 'CR_CALL_NOT_IMPLEMENTED'
}

$global:KitkuVetoNames = @(
    'TypeUnknown', 'LegacyDevice', 'PendingClose', 'WindowsApp', 'WindowsService', 'OutstandingOpen', 'Device',
    'Driver', 'IllegalDeviceRequest', 'InsufficientPower', 'NonDisableable', 'LegacyDriver', 'InsufficientRights',
    'AlreadyRemoved'
)

function Format-KitkuCr {
    param($Cr)
    $n = [int]$Cr
    $name = $global:KitkuCrNames[$n]
    if (-not $name) { $name = 'CR_?' }
    return ('{0} (0x{1:X2})' -f $name, $n)
}

function Format-KitkuVeto {
    param($Veto, [string]$Name)
    $n = [int]$Veto
    $text = '?'
    if (($n -ge 0) -and ($n -lt $global:KitkuVetoNames.Count)) { $text = $global:KitkuVetoNames[$n] }
    return ('PNP_Veto{0} ({1}), veto name "{2}"' -f $text, $n, $Name)
}

function Get-KitkuDevInst {
    # Returns the device instance handle, or throws.
    param([string]$InstanceId)
    $dev = [uint32]0
    $cr = [KitkuNative]::CM_Locate_DevNodeW([ref]$dev, $InstanceId, 0)
    if ($cr -ne 0) {
        $cr2 = [KitkuNative]::CM_Locate_DevNodeW([ref]$dev, $InstanceId, 1)
        if ($cr2 -ne 0) { throw ('Device not found: {0} ({1})' -f $InstanceId, (Format-KitkuCr $cr)) }
        Write-KLog '  note: the device is only known as a "phantom" (not in the live device tree).'
    }
    return $dev
}

function Get-KitkuStatus {
    param([string]$InstanceId)
    $dev = [uint32]0
    $cr = [KitkuNative]::CM_Locate_DevNodeW([ref]$dev, $InstanceId, 0)
    if ($cr -ne 0) {
        return [pscustomobject]@{ Started = $false; Text = ('not in the live device tree: {0}' -f (Format-KitkuCr $cr)) }
    }
    $st = [uint32]0
    $pb = [uint32]0
    $cr = [KitkuNative]::CM_Get_DevNode_Status([ref]$st, [ref]$pb, $dev, 0)
    if ($cr -ne 0) {
        return [pscustomobject]@{ Started = $false; Text = ('status unavailable: {0}' -f (Format-KitkuCr $cr)) }
    }
    return [pscustomobject]@{
        Started = [bool]($st -band 0x8)
        Text    = ('{0} | problem {1}' -f (Format-KitkuDn $st), (Format-KitkuProblem $pb))
    }
}

function Wait-KitkuStarted {
    # Waits until the device reports "started" (or not), up to $TimeoutMs. Returns the last status.
    param([string]$InstanceId, [bool]$WantStarted, [int]$TimeoutMs = 3000)
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    do {
        $s = Get-KitkuStatus $InstanceId
        if ($s.Started -eq $WantStarted) { return $s }
        Start-Sleep -Milliseconds 100
    } while ($sw.ElapsedMilliseconds -lt $TimeoutMs)
    return $s
}

# ----------------------------------------------------------------------------------
# Blocking and restoring
# ----------------------------------------------------------------------------------

function Invoke-KitkuBlock {
    # Applies one blocking method. Returns $true when the device is no longer started.
    param([string]$InstanceId, [string]$Method)
    $dev = Get-KitkuDevInst $InstanceId
    $pnputil = "$env:SystemRoot\System32\pnputil.exe"
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    switch ($Method) {
        'Hold' {
            # CM_REMOVE_UI_NOT_OK (1) | CM_REMOVE_NO_RESTART (2)
            $veto = [int]0
            $name = New-Object System.Text.StringBuilder 260
            $cr = [KitkuNative]::CM_Query_And_Remove_SubTreeW($dev, [ref]$veto, $name, 260, 3)
            $sw.Stop()
            Write-KLog ('  CM_Query_And_Remove_SubTree(NO_RESTART) -> {0} in {1} ms' -f (Format-KitkuCr $cr), $sw.ElapsedMilliseconds)
            if ($cr -ne 0) { Write-KLog ('  veto: {0}' -f (Format-KitkuVeto $veto $name.ToString())) }
        }
        'RemoveDisable' {
            # CM_REMOVE_UI_NOT_OK (1) | CM_REMOVE_DISABLE (4)
            $veto = [int]0
            $name = New-Object System.Text.StringBuilder 260
            $cr = [KitkuNative]::CM_Query_And_Remove_SubTreeW($dev, [ref]$veto, $name, 260, 5)
            $sw.Stop()
            Write-KLog ('  CM_Query_And_Remove_SubTree(DISABLE) -> {0} in {1} ms' -f (Format-KitkuCr $cr), $sw.ElapsedMilliseconds)
            if ($cr -ne 0) { Write-KLog ('  veto: {0}' -f (Format-KitkuVeto $veto $name.ToString())) }
        }
        'Disable' {
            # CM_DISABLE_UI_NOT_OK (4), deliberately without CM_DISABLE_PERSIST (8)
            $cr = [KitkuNative]::CM_Disable_DevNode($dev, 4)
            $sw.Stop()
            Write-KLog ('  CM_Disable_DevNode(non-persistent) -> {0} in {1} ms' -f (Format-KitkuCr $cr), $sw.ElapsedMilliseconds)
        }
        'PnpUtilForce' {
            $output = & $pnputil /disable-device $InstanceId /force 2>&1
            $code = $LASTEXITCODE
            $sw.Stop()
            Write-KLog ('  pnputil /disable-device /force -> exit code {0} in {1} ms' -f $code, $sw.ElapsedMilliseconds)
            $output | ForEach-Object { Write-KLog ('    | {0}' -f $_) }
        }
        'PnpUtil' {
            $output = & $pnputil /disable-device $InstanceId 2>&1
            $code = $LASTEXITCODE
            $sw.Stop()
            Write-KLog ('  pnputil /disable-device -> exit code {0} in {1} ms' -f $code, $sw.ElapsedMilliseconds)
            $output | ForEach-Object { Write-KLog ('    | {0}' -f $_) }
        }
        default { throw ('Unknown method: {0}' -f $Method) }
    }
    $s = Wait-KitkuStarted -InstanceId $InstanceId -WantStarted $false -TimeoutMs 3000
    Write-KLog ('  state after block attempt : {0}' -f $s.Text)
    return (-not $s.Started)
}

function Invoke-KitkuRestore {
    # Tries the restore steps one by one and reports which step brought the device back.
    param([string]$InstanceId, [string]$Method = 'Hold')
    $pnputil = "$env:SystemRoot\System32\pnputil.exe"
    $s = Get-KitkuStatus $InstanceId
    Write-KLog ('  restore: state before : {0}' -f $s.Text)
    if ($s.Started) {
        Write-KLog '  restore: the device is running - nothing to do.'
        return $true
    }
    if ($Method -eq 'Hold') {
        $steps = @('RESET', 'REENUM_DEVICE', 'REENUM_PARENT', 'READY', 'ENABLE', 'PNPUTIL_ENABLE', 'PNPUTIL_SCAN')
    } else {
        $steps = @('ENABLE', 'PNPUTIL_ENABLE', 'RESET', 'REENUM_DEVICE', 'REENUM_PARENT', 'READY', 'PNPUTIL_SCAN')
    }
    foreach ($step in $steps) {
        $result = ''
        $wait = 3000
        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        try {
            $dev = Get-KitkuDevInst $InstanceId
            switch ($step) {
                'RESET' {
                    $result = Format-KitkuCr ([KitkuNative]::CM_Setup_DevNode($dev, 4))
                    $wait = 500
                }
                'REENUM_DEVICE' { $result = Format-KitkuCr ([KitkuNative]::CM_Reenumerate_DevNode($dev, 1)) }
                'REENUM_PARENT' {
                    $parent = [uint32]0
                    $cr = [KitkuNative]::CM_Get_Parent([ref]$parent, $dev, 0)
                    if ($cr -eq 0) { $result = Format-KitkuCr ([KitkuNative]::CM_Reenumerate_DevNode($parent, 1)) }
                    else { $result = ('CM_Get_Parent failed: {0}' -f (Format-KitkuCr $cr)) }
                }
                'READY' { $result = Format-KitkuCr ([KitkuNative]::CM_Setup_DevNode($dev, 0)) }
                'ENABLE' { $result = Format-KitkuCr ([KitkuNative]::CM_Enable_DevNode($dev, 0)) }
                'PNPUTIL_ENABLE' {
                    $output = & $pnputil /enable-device $InstanceId 2>&1
                    $result = ('exit code {0}: {1}' -f $LASTEXITCODE, (($output | Select-Object -Last 2) -join ' / '))
                }
                'PNPUTIL_SCAN' {
                    $output = & $pnputil /scan-devices 2>&1
                    $result = ('exit code {0}' -f $LASTEXITCODE)
                    $wait = 6000
                }
            }
        } catch {
            $result = ('error: {0}' -f $_.Exception.Message)
        }
        $sw.Stop()
        $s = Wait-KitkuStarted -InstanceId $InstanceId -WantStarted $true -TimeoutMs $wait
        Write-KLog ('  restore step {0,-14}: {1} ({2} ms) -> {3}' -f $step, $result, $sw.ElapsedMilliseconds, $s.Text)
        if ($s.Started) {
            Write-KLog ('  RESTORED by step {0}.' -f $step)
            return $true
        }
    }
    Write-KLog '  NOT RESTORED. Restart Windows (Start > Power > Restart) to get the keyboard back.'
    return $false
}

function Test-KitkuBlockAllowed {
    # Guards the methods that may leave a persistent "disabled" flag behind.
    param([string]$InstanceId, [string]$Method, [bool]$AllowPs2)
    $svc = (Get-KitkuProps $InstanceId @('DEVPKEY_Device_Service'))['DEVPKEY_Device_Service']
    $risky = @('RemoveDisable', 'PnpUtilForce', 'PnpUtil') -contains $Method
    if (($svc -eq 'i8042prt') -and $risky -and (-not $AllowPs2)) {
        Write-KLog ('  REFUSED: method {0} is not run on a PS/2 keyboard.' -f $Method)
        Write-KLog '  Reason: if Windows cannot stop the device now, it may disable it at the next boot instead.'
        return $false
    }
    return $true
}

# T3 - stop and restart with Microsoft's own tool
function Test-KitkuRestart {
    param([Parameter(Mandatory = $true)][string]$InstanceId)
    Write-KLogHeader 'T3 RESTART-DEVICE'
    Assert-KitkuAdmin
    Write-KLog ('device: {0}' -f $InstanceId)
    Write-KLog ('  state before : {0}' -f (Get-KitkuStatus $InstanceId).Text)
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $output = & "$env:SystemRoot\System32\pnputil.exe" /restart-device $InstanceId 2>&1
    $code = $LASTEXITCODE
    $sw.Stop()
    Write-KLog ('  pnputil /restart-device -> exit code {0} in {1} ms' -f $code, $sw.ElapsedMilliseconds)
    $output | ForEach-Object { Write-KLog ('    | {0}' -f $_) }
    Start-Sleep -Milliseconds 500
    Write-KLog ('  state after  : {0}' -f (Get-KitkuStatus $InstanceId).Text)
    Write-KLog ('Log file: {0}' -f $global:KitkuLogPath)
}

# T4 - block, hold for some seconds, restore automatically
function Test-KitkuBlock {
    param(
        [Parameter(Mandatory = $true)][string]$InstanceId,
        [ValidateSet('Hold', 'Disable', 'RemoveDisable', 'PnpUtil', 'PnpUtilForce')][string]$Method = 'Hold',
        [int]$Seconds = 60,
        [int]$Countdown = 5,
        [switch]$AllowPs2
    )
    Write-KLogHeader ('T4 BLOCK TEST - method {0}' -f $Method)
    Assert-KitkuAdmin
    Write-KLog ('device: {0}' -f $InstanceId)
    if (-not (Test-KitkuBlockAllowed $InstanceId $Method ([bool]$AllowPs2))) { return }
    Write-KLog ('  state before : {0}' -f (Get-KitkuStatus $InstanceId).Text)
    Write-KLog ('  The keyboard is blocked for {0} s and then restored automatically.' -f $Seconds)
    Write-KLog '  To test stuck keys: hold a key on that keyboard down while the countdown runs.'
    for ($i = $Countdown; $i -gt 0; $i--) {
        Write-Host ('  blocking in {0} ...' -f $i)
        Start-Sleep -Seconds 1
    }
    $blocked = $false
    try {
        $blocked = Invoke-KitkuBlock -InstanceId $InstanceId -Method $Method
        if (-not $blocked) {
            Write-KLog '  RESULT: NOT BLOCKED (the device is still running).'
        } else {
            Write-KLog ('  RESULT: BLOCKED. Try the keyboard now ({0} s). Press Ctrl+C to restore early.' -f $Seconds)
            $cameBack = $false
            for ($t = 1; $t -le $Seconds; $t++) {
                Start-Sleep -Seconds 1
                $s = Get-KitkuStatus $InstanceId
                if ($s.Started -and (-not $cameBack)) {
                    $cameBack = $true
                    Write-KLog ('  !! the device came back BY ITSELF after {0} s: {1}' -f $t, $s.Text)
                }
                if (($t % 10) -eq 0) { Write-KLog ('  t={0,3}s state: {1}' -f $t, $s.Text) }
            }
        }
    } finally {
        Write-KLog '  restoring ...'
        $ok = Invoke-KitkuRestore -InstanceId $InstanceId -Method $Method
        Write-KLog ('  final state  : {0}' -f (Get-KitkuStatus $InstanceId).Text)
        Write-KLog ('Log file: {0}' -f $global:KitkuLogPath)
    }
}

# T5 - block and leave blocked (for the sleep / lock / shutdown / restart checks)
function Block-KitkuKeyboard {
    param(
        [Parameter(Mandatory = $true)][string]$InstanceId,
        [ValidateSet('Hold', 'Disable', 'RemoveDisable', 'PnpUtilForce')][string]$Method = 'Hold',
        [switch]$AllowPs2
    )
    Write-KLogHeader ('T5 BLOCK AND LEAVE - method {0}' -f $Method)
    Assert-KitkuAdmin
    Write-KLog ('device: {0}' -f $InstanceId)
    if (-not (Test-KitkuBlockAllowed $InstanceId $Method ([bool]$AllowPs2))) { return }
    Write-KLog ('  state before : {0}' -f (Get-KitkuStatus $InstanceId).Text)
    $blocked = Invoke-KitkuBlock -InstanceId $InstanceId -Method $Method
    if ($blocked) {
        Write-KLog '  RESULT: BLOCKED and left blocked.'
        Write-KLog ('  To restore:  Restore-KitkuKeyboard -InstanceId "{0}" -Method {1}' -f $InstanceId, $Method)
        Write-KLog '  Or simply :  Restore-KitkuKeyboard -All'
    } else {
        Write-KLog '  RESULT: NOT BLOCKED (the device is still running).'
    }
    Write-KLog ('Log file: {0}' -f $global:KitkuLogPath)
}

function Get-KitkuState {
    # One line per keyboard: is it running right now? Use after sleep, lock, sign-out, shutdown, restart.
    param([string]$Note = '')
    Write-KLogHeader ('STATE CHECK {0}' -f $Note)
    $native = Initialize-KitkuNative
    foreach ($d in @(Get-KitkuDevices -Classes @('Keyboard'))) {
        if ($native) {
            $s = Get-KitkuStatus $d.DeviceID
            # Skip keyboards that are simply unplugged (known to Windows, but not connected now).
            if (($s.Text -like 'not in the live device tree*') -and (-not $d.Present)) { continue }
            $running = 'STOPPED'
            if ($s.Started) { $running = 'running' }
            Write-KLog ('{0,-8} {1}   {2}' -f $running, $d.DeviceID, $s.Text)
        } elseif ($d.Present) {
            Write-KLog ('{0,-8} {1}   problem {2}' -f $d.Status, $d.DeviceID, (Format-KitkuProblem $d.ConfigManagerErrorCode))
        }
    }
    Write-KLog ('Log file: {0}' -f $global:KitkuLogPath)
}

function Restore-KitkuKeyboard {
    param(
        [string]$InstanceId,
        [ValidateSet('Hold', 'Disable', 'RemoveDisable', 'PnpUtil', 'PnpUtilForce')][string]$Method = 'Hold',
        [switch]$All    # restore every keyboard that is in the device tree but not running
    )
    Write-KLogHeader 'RESTORE'
    Assert-KitkuAdmin
    if ($All) {
        $found = $false
        foreach ($d in @(Get-KitkuDevices -Classes @('Keyboard'))) {
            $s = Get-KitkuStatus $d.DeviceID
            # Skip keyboards that are simply unplugged (known to Windows, but not connected now).
            if (($s.Text -like 'not in the live device tree*') -and (-not $d.Present)) { continue }
            if ($s.Started) { continue }
            $found = $true
            Write-KLog ('device: {0}' -f $d.DeviceID)
            [void](Invoke-KitkuRestore -InstanceId $d.DeviceID -Method $Method)
        }
        if (-not $found) { Write-KLog 'All keyboards in the device tree are running.' }
    } elseif ($InstanceId) {
        Write-KLog ('device: {0}' -f $InstanceId)
        [void](Invoke-KitkuRestore -InstanceId $InstanceId -Method $Method)
    } else {
        Write-KLog 'Give -InstanceId "<id>" or -All.'
    }
    Write-KLog ('Log file: {0}' -f $global:KitkuLogPath)
}

# ----------------------------------------------------------------------------------
# T6 (optional) - the kbdclass "AllowDisable" developer switch
# ----------------------------------------------------------------------------------

function Set-KitkuAllowDisable {
    # Sets (or with -Remove deletes) HKLM\SYSTEM\CurrentControlSet\Services\kbdclass\Parameters\AllowDisable.
    # Takes effect after a restart. Affects all keyboards. Always undo with -Remove after the test.
    param([switch]$Remove)
    Write-KLogHeader 'T6 ALLOWDISABLE SWITCH'
    if (-not (Test-KitkuElevated)) { throw 'This needs an elevated console.' }
    $path = 'HKLM:\SYSTEM\CurrentControlSet\Services\kbdclass\Parameters'
    if ($Remove) {
        Remove-ItemProperty -Path $path -Name 'AllowDisable' -ErrorAction SilentlyContinue
        Write-KLog 'AllowDisable removed. Restart Windows to return to the default behaviour.'
    } else {
        New-ItemProperty -Path $path -Name 'AllowDisable' -PropertyType DWord -Value 1 -Force | Out-Null
        Write-KLog 'AllowDisable = 1 written. Restart Windows, then run: Get-KitkuKeyboards'
        Write-KLog 'Undo later with: Set-KitkuAllowDisable -Remove   (and restart again)'
    }
}

# ----------------------------------------------------------------------------------
# T7 (optional) - how fast can a standard user trigger SYSTEM code?
# ----------------------------------------------------------------------------------

$global:KitkuProbeName = 'KitkuSpikeProbe'

function Get-KitkuProbeDir { return (Join-Path $env:ProgramData 'KitkuSpike') }

function Install-KitkuTriggerProbe {
    # Creates a temporary scheduled task and a temporary service, both running as SYSTEM,
    # both startable by interactive users. Each only writes a small flag file.
    Write-KLogHeader 'T7 TRIGGER PROBE - INSTALL'
    Assert-KitkuAdmin
    $dir = Get-KitkuProbeDir
    $cmd = Join-Path $env:SystemRoot 'System32\cmd.exe'
    if (($dir -match '\s') -or ($cmd -match '\s')) { throw 'Unexpected space in a system path; probe not installed.' }
    New-Item -ItemType Directory -Path $dir -Force | Out-Null

    # Scheduled task
    $service = New-Object -ComObject Schedule.Service
    $service.Connect()
    $folder = $service.GetFolder('\')
    $def = $service.NewTask(0)
    $def.RegistrationInfo.Description = 'KitkuProtector spike: latency probe. Safe to delete.'
    $def.Principal.LogonType = 5        # TASK_LOGON_SERVICE_ACCOUNT
    $def.Principal.RunLevel = 1         # highest
    $def.Settings.AllowDemandStart = $true
    $def.Settings.DisallowStartIfOnBatteries = $false
    $def.Settings.StopIfGoingOnBatteries = $false
    $def.Settings.ExecutionTimeLimit = 'PT1M'
    $def.Settings.MultipleInstances = 2 # ignore new
    $def.Settings.Priority = 4          # normal priority (the default 7 is below normal)
    $action = $def.Actions.Create(0)    # TASK_ACTION_EXEC
    $action.Path = $cmd
    $action.Arguments = ('/c echo task>{0}' -f (Join-Path $dir 'task.flag'))
    $task = $folder.RegisterTaskDefinition($global:KitkuProbeName, $def, 6, 'SYSTEM', $null, 5)
    $sddl = $task.GetSecurityDescriptor(4)
    $task.SetSecurityDescriptor(($sddl + '(A;;FRFX;;;IU)'), 0)
    Write-KLog ('task registered, security descriptor: {0}' -f $task.GetSecurityDescriptor(4))

    # Demand-start service
    $binPath = ('{0} /c echo svc>{1}' -f $cmd, (Join-Path $dir 'svc.flag'))
    if (-not (Get-Service -Name $global:KitkuProbeName -ErrorAction SilentlyContinue)) {
        New-Service -Name $global:KitkuProbeName -BinaryPathName $binPath -StartupType Manual `
            -DisplayName 'KitkuProtector spike latency probe (safe to delete)' | Out-Null
    }
    $svcSddl = 'D:(A;;CCLCSWRPWPDTLOCRRC;;;SY)(A;;CCDCLCSWRPWPDTLOCRSDRCWDWO;;;BA)(A;;CCLCSWRPLOCRRC;;;IU)(A;;CCLCSWLOCRRC;;;SU)'
    $output = & "$env:SystemRoot\System32\sc.exe" sdset $global:KitkuProbeName $svcSddl 2>&1
    Write-KLog ('service created, sdset: {0}' -f ($output -join ' '))
    Write-KLog 'Now open a NORMAL (not elevated) PowerShell, load this script and run: Measure-KitkuTrigger'
    Write-KLog 'Afterwards, back in the elevated console: Remove-KitkuTriggerProbe'
}

function Measure-KitkuTrigger {
    # Run this in a normal, non-elevated console to also prove that a standard user may start both.
    param([int]$Runs = 5)
    Write-KLogHeader 'T7 TRIGGER PROBE - MEASURE'
    if (-not (Initialize-KitkuNative)) { return }
    Write-KLog ('elevated console: {0}   (False is the interesting case)' -f (Test-KitkuElevated))
    if (-not (Get-Service -Name $global:KitkuProbeName -ErrorAction SilentlyContinue)) {
        Write-KLog 'The probe is not installed. Run Install-KitkuTriggerProbe in an elevated console first.'
        return
    }
    $dir = Get-KitkuProbeDir
    $taskFlag = Join-Path $dir 'task.flag'
    $svcFlag = Join-Path $dir 'svc.flag'
    $taskMs = @()
    $svcMs = @()

    for ($i = 1; $i -le $Runs; $i++) {
        # --- scheduled task ---
        try {
            $service = New-Object -ComObject Schedule.Service
            $service.Connect()
            $task = $service.GetFolder('\').GetTask($global:KitkuProbeName)
            $before = [System.IO.File]::GetLastWriteTimeUtc($taskFlag)
            $sw = [System.Diagnostics.Stopwatch]::StartNew()
            [void]$task.Run($null)
            $seen = $false
            while ($sw.ElapsedMilliseconds -lt 10000) {
                if ([System.IO.File]::GetLastWriteTimeUtc($taskFlag) -ne $before) { $seen = $true; break }
            }
            $sw.Stop()
            if ($seen) { $taskMs += $sw.ElapsedMilliseconds; Write-KLog ('  run {0}: task    -> SYSTEM code ran after {1} ms' -f $i, $sw.ElapsedMilliseconds) }
            else { Write-KLog ('  run {0}: task    -> no result within 10 s' -f $i) }
        } catch {
            Write-KLog ('  run {0}: task    -> FAILED: {1}' -f $i, $_.Exception.Message)
        }
        Start-Sleep -Milliseconds 1500

        # --- demand-start service ---
        try {
            $before = [System.IO.File]::GetLastWriteTimeUtc($svcFlag)
            $sw = [System.Diagnostics.Stopwatch]::StartNew()
            [KitkuNative]::StartServiceAsync($global:KitkuProbeName)
            $seen = $false
            while ($sw.ElapsedMilliseconds -lt 10000) {
                if ([System.IO.File]::GetLastWriteTimeUtc($svcFlag) -ne $before) { $seen = $true; break }
                $err = [KitkuNative]::LastServiceStartError
                if (($err -gt 0) -and ($err -ne 1053)) { break }
            }
            $sw.Stop()
            if ($seen) { $svcMs += $sw.ElapsedMilliseconds; Write-KLog ('  run {0}: service -> SYSTEM code ran after {1} ms' -f $i, $sw.ElapsedMilliseconds) }
            else { Write-KLog ('  run {0}: service -> no result (StartService error {1}; 5 = access denied)' -f $i, [KitkuNative]::LastServiceStartError) }
        } catch {
            Write-KLog ('  run {0}: service -> FAILED: {1}' -f $i, $_.Exception.Message)
        }
        # The probe payload is not a real service, so Windows reports error 1053 for it; wait until that settles.
        for ($w = 0; $w -lt 400; $w++) {
            Start-Sleep -Milliseconds 100
            if ([KitkuNative]::LastServiceStartError -ne -1) {
                $st = (Get-Service -Name $global:KitkuProbeName -ErrorAction SilentlyContinue).Status
                if ("$st" -eq 'Stopped') { break }
            }
        }
    }

    foreach ($pair in @(@('task', $taskMs), @('service', $svcMs))) {
        $values = @($pair[1] | Sort-Object)
        if ($values.Count -gt 0) {
            $median = $values[[int][math]::Floor(($values.Count - 1) / 2)]
            Write-KLog ('  {0,-7}: {1} of {2} runs ok | min {3} ms | median {4} ms | max {5} ms' -f $pair[0], $values.Count, $Runs, $values[0], $median, $values[-1])
        } else {
            Write-KLog ('  {0,-7}: no successful run' -f $pair[0])
        }
    }
    Write-KLog ('Log file: {0}' -f $global:KitkuLogPath)
}

function Remove-KitkuTriggerProbe {
    Write-KLogHeader 'T7 TRIGGER PROBE - REMOVE'
    if (-not (Test-KitkuElevated)) { throw 'This needs an elevated console.' }
    try {
        $service = New-Object -ComObject Schedule.Service
        $service.Connect()
        $service.GetFolder('\').DeleteTask($global:KitkuProbeName, 0)
        Write-KLog 'task removed'
    } catch { Write-KLog ('task not removed: {0}' -f $_.Exception.Message) }
    $output = & "$env:SystemRoot\System32\sc.exe" delete $global:KitkuProbeName 2>&1
    Write-KLog ('service delete: {0}' -f ($output -join ' '))
    Remove-Item -LiteralPath (Get-KitkuProbeDir) -Recurse -Force -ErrorAction SilentlyContinue
    Write-KLog 'probe folder removed'
}

# ----------------------------------------------------------------------------------
# T8 (optional) - can a standard user stop a keyboard with the "safe removal" call?
# ----------------------------------------------------------------------------------

function Test-KitkuEjectAsUser {
    # Run in a NORMAL (not elevated) console. If it succeeds, restore from the elevated console.
    param([Parameter(Mandatory = $true)][string]$InstanceId)
    Write-KLogHeader 'T8 EJECT REQUEST AS STANDARD USER'
    if (-not (Initialize-KitkuNative)) { return }
    Write-KLog ('elevated console: {0}   (False is the interesting case)' -f (Test-KitkuElevated))
    Write-KLog ('device: {0}' -f $InstanceId)
    Write-KLog ('  state before : {0}' -f (Get-KitkuStatus $InstanceId).Text)
    $dev = Get-KitkuDevInst $InstanceId
    $veto = [int]0
    $name = New-Object System.Text.StringBuilder 260
    $cr = [KitkuNative]::CM_Request_Device_EjectW($dev, [ref]$veto, $name, 260, 0)
    Write-KLog ('  CM_Request_Device_Eject -> {0}' -f (Format-KitkuCr $cr))
    if ($cr -ne 0) { Write-KLog ('  veto: {0}' -f (Format-KitkuVeto $veto $name.ToString())) }
    Start-Sleep -Milliseconds 500
    $s = Get-KitkuStatus $InstanceId
    Write-KLog ('  state after  : {0}' -f $s.Text)
    if (-not $s.Started) {
        Write-KLog '  The keyboard was stopped WITHOUT admin rights.'
        Write-KLog ('  Restore it from the elevated console: Restore-KitkuKeyboard -InstanceId "{0}"' -f $InstanceId)
    }
    Write-KLog ('Log file: {0}' -f $global:KitkuLogPath)
}

# ----------------------------------------------------------------------------------

function Get-KitkuHelp {
    $lines = @(
        '',
        'KitkuSpike - test commands (details and expected outputs: README.md)',
        '',
        '  T0  Get-KitkuEnvironment                                   no admin   read-only',
        '  T1  Get-KitkuKeyboards -Detailed                           no admin   read-only (PS/2 or HID?)',
        '  T3  Test-KitkuRestart -InstanceId "<id>"                   admin      keyboard drops for a moment',
        '  T4  Test-KitkuBlock   -InstanceId "<id>" -Method Hold      admin      blocks 60 s, restores by itself',
        '      other methods: Disable, RemoveDisable, PnpUtil, PnpUtilForce',
        '  T5  Block-KitkuKeyboard -InstanceId "<id>"                 admin      stays blocked',
        '      Get-KitkuState "after sleep"                           any        is it still blocked?',
        '      Restore-KitkuKeyboard -All                             admin      panic button',
        '  T6  Set-KitkuAllowDisable / -Remove                        admin      optional',
        '  T7  Install-KitkuTriggerProbe, Measure-KitkuTrigger,',
        '      Remove-KitkuTriggerProbe                               admin+user optional',
        '  T8  Test-KitkuEjectAsUser -InstanceId "<id>"               no admin   optional',
        '',
        ('  Log file: {0}' -f $global:KitkuLogPath),
        ''
    )
    $lines | ForEach-Object { Write-Host $_ }
}

Initialize-KitkuLog
Write-KLogHeader ('SESSION START - KitkuSpike {0}' -f $global:KitkuSpikeVersion)
Get-KitkuHelp
