# dgpu-probe.ps1
# Read-only PnP probe: dump AMD dGPUs, ASMedia dock routers, USB4 audio devices,
# children of the failing router, and recent USB4/AMD-driver events.
# Used to diagnose "USB4 dock only enumerates audio, not the dGPU" symptom.

$ErrorActionPreference = 'Continue'

function Get-CmHex {
    param($obj)
    if ($obj.PSObject.Properties['ConfigManagerErrorCode']) {
        '0x{0:X2}' -f [int]$obj.ConfigManagerErrorCode
    } else { 'n/a' }
}

function Show-Row {
    param($d)
    [pscustomobject]@{
        Class    = $d.Class
        Name     = $d.FriendlyName
        Status   = $d.Status
        CM       = Get-CmHex $d
        Instance = $d.InstanceId
    }
}

Write-Host '== AMD dGPU entries (class=Display, vendor=0x1002) ==' -ForegroundColor Cyan
Get-PnpDevice -ErrorAction SilentlyContinue |
    Where-Object { $_.InstanceId -match 'PCI\\VEN_1002' -and $_.Class -eq 'Display' } |
    ForEach-Object { Show-Row $_ } |
    Format-Table -AutoSize -Wrap

Write-Host '== AMD iGPU entry (graphics, not RX) ==' -ForegroundColor Cyan
Get-PnpDevice -ErrorAction SilentlyContinue |
    Where-Object { $_.InstanceId -match 'PCI\\VEN_1002' -and $_.Class -ne 'Display' } |
    ForEach-Object { Show-Row $_ } |
    Format-Table -AutoSize -Wrap

Write-Host '== ASMedia 246x dock routers ==' -ForegroundColor Cyan
Get-PnpDevice -ErrorAction SilentlyContinue |
    Where-Object { $_.InstanceId -match 'VID_174C' } |
    ForEach-Object { Show-Row $_ } |
    Format-Table -AutoSize -Wrap

Write-Host '== Audio devices anywhere (USB4 audio is the giveaway) ==' -ForegroundColor Cyan
Get-PnpDevice -ErrorAction SilentlyContinue |
    Where-Object { $_.Class -eq 'Audio' -or $_.Class -eq 'AudioEndpoint' -or $_.Class -eq 'Media' -or $_.FriendlyName -match 'Audio|Speaker|Headset|Mic' } |
    ForEach-Object { Show-Row $_ } |
    Format-Table -AutoSize -Wrap

Write-Host '== Children of the failing ASMedia router (instance suffix 6&3332B0CA) ==' -ForegroundColor Cyan
$failingRouter = Get-PnpDevice -ErrorAction SilentlyContinue |
    Where-Object { $_.InstanceId -match 'VID_174C&PID_2461\\6&3332B0CA' } |
    Select-Object -First 1
if ($failingRouter) {
    Write-Host ("  Parent: {0}  status={1}  CM={2}" -f $failingRouter.FriendlyName, $failingRouter.Status, (Get-CmHex $failingRouter)) -ForegroundColor Yellow
    $children = Get-PnpDevice -ErrorAction SilentlyContinue |
        Where-Object { $_.InstanceId.StartsWith($failingRouter.InstanceId) -and $_.InstanceId -ne $failingRouter.InstanceId }
    if ($children) {
        $children | ForEach-Object { Show-Row $_ } | Format-Table -AutoSize -Wrap
    } else {
        Write-Host "  (no children enumerated under this router)" -ForegroundColor Yellow
    }
} else {
    Write-Host "  (could not locate the failing ASMedia router instance)" -ForegroundColor Yellow
}

Write-Host '== Children of the OK ASMedia router (instance suffix 6&104D0238) ==' -ForegroundColor Cyan
$okRouter = Get-PnpDevice -ErrorAction SilentlyContinue |
    Where-Object { $_.InstanceId -match 'VID_174C&PID_2461\\6&104D0238' } |
    Select-Object -First 1
if ($okRouter) {
    Write-Host ("  Parent: {0}  status={1}  CM={2}" -f $okRouter.FriendlyName, $okRouter.Status, (Get-CmHex $okRouter)) -ForegroundColor Yellow
    $children = Get-PnpDevice -ErrorAction SilentlyContinue |
        Where-Object { $_.InstanceId.StartsWith($okRouter.InstanceId) -and $_.InstanceId -ne $okRouter.InstanceId }
    if ($children) {
        $children | ForEach-Object { Show-Row $_ } | Format-Table -AutoSize -Wrap
    } else {
        Write-Host "  (no children enumerated under this router)" -ForegroundColor Yellow
    }
} else {
    Write-Host "  (could not locate the OK ASMedia router instance)" -ForegroundColor Yellow
}

Write-Host '== Recent USB4 / AMD driver / kernel events (last 1h) ==' -ForegroundColor Cyan
try {
    Get-WinEvent -FilterHashtable @{ LogName='System'; StartTime=(Get-Date).AddHours(-1) } -ErrorAction Stop |
        Where-Object { $_.ProviderName -match 'Thunderbolt|USB4|atikmdag|amdfendr|amdkmdag|DriverFrameworks-UserMode' } |
        Select-Object -First 20 -Property TimeCreated, ProviderName, Id, LevelDisplayName, Message |
        ForEach-Object {
            $firstLine = ($_.Message -split "`r?`n")[0]
            Write-Host ("  {0:HH:mm:ss} [{1}] {2}/{3} :: {4}" -f $_.TimeCreated, $_.LevelDisplayName, $_.ProviderName, $_.Id, $firstLine)
        }
} catch {
    Write-Host "  (no events / provider log unavailable)" -ForegroundColor Yellow
}
