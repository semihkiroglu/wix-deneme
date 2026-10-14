# Report whether the OS services required by the upstream MsiE2E tests can run in this container,
# and whether the failing call chains (ADSI machine context, firewall COM) work afterwards.
$ErrorActionPreference = 'Continue'
Write-Host "PROBE_HOST=$env:COMPUTERNAME"

function Probe-Service([string]$Name) {
    $query = (& sc.exe query $Name 2>&1) -join ' '
    $state = if ($query -match 'STATE\s+:\s+\d+\s+(\w+)') { $Matches[1] } else { 'MISSING' }
    if ($state -eq 'MISSING') { Write-Host "SVC $Name state=MISSING"; return }
    Write-Host "SVC $Name state=$state"
    if ($state -eq 'RUNNING') { Write-Host "SVC $Name START_SKIPPED already-running"; return }
    & cmd.exe /c "sc.exe config $Name start= demand" | Out-Null
    $startOutput = (& cmd.exe /c "net start $Name" 2>&1) -join ' | '
    $query2 = (& sc.exe query $Name 2>&1) -join ' '
    $state2 = if ($query2 -match 'STATE\s+:\s+\d+\s+(\w+)') { $Matches[1] } else { 'UNKNOWN' }
    Write-Host "SVC $Name start_state=$state2 output=$($startOutput.Substring(0, [Math]::Min(220, $startOutput.Length)))"
}

foreach ($name in @('LanmanServer', 'srvnet', 'mpssvc', 'BFE', 'COMSysApp', 'MSDTC', 'EventSystem', 'SamSS')) {
    Probe-Service $name
}

Write-Host '--- functional: ADSI machine context (UserGroupVerifier path) ---'
try {
    $entry = New-Object System.DirectoryServices.DirectoryEntry("WinNT://$env:COMPUTERNAME,computer")
    $entry.RefreshCache()
    Write-Host 'ADSI_REFRESH_OK'
} catch { Write-Host "ADSI_REFRESH_FAIL $($_.Exception.Message)" }
try {
    Add-Type -AssemblyName System.DirectoryServices.AccountManagement
    $ctx = New-Object System.DirectoryServices.AccountManagement.PrincipalContext('Machine')
    $group = [System.DirectoryServices.AccountManagement.GroupPrincipal]::FindByIdentity($ctx, 'Administrators')
    Write-Host "ADSI_FIND_OK name=$($group.Name)"
} catch { Write-Host "ADSI_FIND_FAIL $($_.Exception.Message)" }

Write-Host '--- functional: firewall COM (FirewallExtensionTests path) ---'
try {
    $policy = New-Object -ComObject HNetCfg.FWPolicy2
    $count = @($policy.Rules).Count
    Write-Host "FW_COM_OK rules=$count"
} catch { Write-Host "FW_COM_FAIL $($_.Exception.Message)" }

Write-Host '--- functional: netapi32 user add/delete (net user path) ---'
$out = (& cmd.exe /c 'net user wixprobe Pw!1234 /add' 2>&1) -join ' | '
Write-Host "NET_USER_ADD exit=$LASTEXITCODE output=$($out.Substring(0, [Math]::Min(220, $out.Length)))"
& cmd.exe /c 'net user wixprobe /delete' | Out-Null

Write-Host 'PROBE_DONE'
exit 0
