<#
.SYNOPSIS
  Enable/disable the Windows hypervisor + VBS so VMware Workstation can expose
  nested VT-x/EPT (vhv.enable) to a guest (the KVM range-host VM).

.DESCRIPTION
  Disabling frees VT-x for VMware's own VMM -> real nested KVM works.
  Side effect: WSL2 and Docker Desktop stop working until you re-enable
  (they rely on the Windows hypervisor). Reboot required after either mode.
  Fully reversible: run with -Mode Enable to restore the defaults.

  Self-elevates via UAC. Writes a transcript to %TEMP%\host-hypervisor-toggle.log.

.EXAMPLE
  .\toggle-host-hypervisor.ps1 -Mode Disable   # for nested KVM (then reboot)
  .\toggle-host-hypervisor.ps1 -Mode Enable    # restore WSL2/Docker/VBS (then reboot)
#>
param(
    [ValidateSet('Disable','Enable')]
    [string]$Mode = 'Disable'
)

$log = Join-Path $env:TEMP 'host-hypervisor-toggle.log'

function Test-Admin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    (New-Object Security.Principal.WindowsPrincipal($id)).IsInRole(
        [Security.Principal.WindowsBuiltinRole]::Administrator)
}

if (-not (Test-Admin)) {
    Write-Host "[*] Requesting elevation (accept the UAC prompt)..." -ForegroundColor Cyan
    $p = Start-Process powershell -Verb RunAs -Wait -PassThru -ArgumentList @(
        '-ExecutionPolicy','Bypass','-File',"`"$PSCommandPath`"",'-Mode',$Mode)
    if (Test-Path $log) { Get-Content $log }
    if ($p.ExitCode -ne 0) { Write-Warning "Elevated run exit code: $($p.ExitCode)" }
    return
}

# --- elevated from here ---
"=== toggle-host-hypervisor  Mode=$Mode  $(Get-Date -Format s) ===" | Set-Content $log
$dg  = 'HKLM\SYSTEM\CurrentControlSet\Control\DeviceGuard'
$hvci= "$dg\Scenarios\HypervisorEnforcedCodeIntegrity"
$lsa = 'HKLM\SYSTEM\CurrentControlSet\Control\Lsa'

if ($Mode -eq 'Disable') {
    'hypervisorlaunchtype -> off'                       | Add-Content $log
    (bcdedit /set hypervisorlaunchtype off)        *>&1 | Add-Content $log
    'VBS EnableVirtualizationBasedSecurity -> 0'        | Add-Content $log
    (reg add $dg   /v EnableVirtualizationBasedSecurity /t REG_DWORD /d 0 /f) *>&1 | Add-Content $log
    'HVCI Enabled -> 0'                                 | Add-Content $log
    (reg add $hvci /v Enabled /t REG_DWORD /d 0 /f) *>&1 | Add-Content $log
    'Credential Guard LsaCfgFlags -> 0'                 | Add-Content $log
    (reg add $lsa  /v LsaCfgFlags /t REG_DWORD /d 0 /f) *>&1 | Add-Content $log
}
else {
    'hypervisorlaunchtype -> auto'                      | Add-Content $log
    (bcdedit /set hypervisorlaunchtype auto)       *>&1 | Add-Content $log
    'VBS EnableVirtualizationBasedSecurity -> 1'        | Add-Content $log
    (reg add $dg   /v EnableVirtualizationBasedSecurity /t REG_DWORD /d 1 /f) *>&1 | Add-Content $log
    'HVCI Enabled -> 1'                                 | Add-Content $log
    (reg add $hvci /v Enabled /t REG_DWORD /d 1 /f) *>&1 | Add-Content $log
}

'' | Add-Content $log
'>>> REBOOT REQUIRED for changes to take effect.' | Add-Content $log
"Mode=$Mode applied." | Add-Content $log
