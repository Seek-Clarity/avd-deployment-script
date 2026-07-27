[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$RegistrationToken,

    [Parameter(Mandatory = $false)]
    [string]$Proxy,

    [switch]$Force
)

# -----------------------------
# Globals / Logging
# -----------------------------
$ErrorActionPreference = 'Stop'
$LogRoot   = 'C:\AVD\Logs'
$LogFile   = Join-Path $LogRoot 'install-avd.log'
$TempRoot  = Join-Path $env:TEMP 'AVDAgentInstall'
$AgentMsi  = 'https://aka.ms/avdagent'
$BootMsi   = 'https://aka.ms/avdbootloader'
$AgentPath = Join-Path $TempRoot 'RDAgent.msi'
$BootPath  = Join-Path $TempRoot 'RDAgentBootLoader.msi'

function Write-Log {
    param([string]$Message, [string]$Level='INFO')
    $ts = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss.fff')
    $line = "[$ts][$Level] $Message"
    Write-Output $line
    Add-Content -Path $LogFile -Value $line
}

function New-DirectorySafe {
    param([string]$Path)
    if (-not (Test-Path $Path)) { New-Item -ItemType Directory -Path $Path | Out-Null }
}

function Invoke-With-Retry {
    param(
        [scriptblock]$Script,
        [int]$Retries = 5,
        [int]$DelaySeconds = 5,
        [string]$Description = 'operation'
    )
    for ($i=1; $i -le $Retries; $i++) {
        try {
            Write-Log "Attempt $i/$($Retries): $Description"
            & $Script
            Write-Log "$Description succeeded."
            return
        } catch {
            Write-Log "$Description failed: $($_.Exception.Message)" 'WARN'
            if ($i -eq $Retries) {
                throw
            }
            Start-Sleep -Seconds $DelaySeconds
        }
    }
}

# -----------------------------
# Prep logging & environment
# -----------------------------
try {
    New-DirectorySafe $LogRoot
    New-DirectorySafe $TempRoot
    Write-Log "=== Starting Enhanced AVD Registration Script ==="
    Write-Log "Script arguments: Proxy='${Proxy}', Force=$Force"
    Write-Log ("Token length received: {0}" -f ($RegistrationToken.Length))
} catch {
    # last-resort write to console if log path creation fails
    Write-Output "Log init failed: $($_.Exception.Message)"
}

# -----------------------------
# Disable DVD / CD-ROM
# -----------------------------
try {
    Write-Log "Disabling CD-ROM driver so Azure virtual DVD is removed after reboot"
    Set-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Services\cdrom' -Name Start -Value 4 -Type DWord
    Write-Log "CD-ROM driver disabled successfully"
} catch {
    Write-Log "Failed to disable CD-ROM driver: $($_.Exception.Message)" 'WARN'
}

# -----------------------------
# Basic validation
# -----------------------------
if (-not $RegistrationToken -or $RegistrationToken.Trim().Length -lt 16) {
    Write-Log "Registration token missing or too short." 'ERROR'
    exit 10
}
# Heuristic: JWToken-like (not enforced—AVD tokens can vary)
if ($RegistrationToken -notmatch '^[A-Za-z0-9-_]+\.[A-Za-z0-9-_]+\.[A-Za-z0-9-_]+$' -and $RegistrationToken.Length -lt 100) {
    Write-Log "Registration token does not look like a typical JWT; continuing, but verify correctness." 'WARN'
}

# Optional proxy
if ($Proxy) {
    try {
        Write-Log "Setting WinHTTP proxy: $Proxy"
        netsh winhttp set proxy $Proxy | Out-Null
    } catch {
        Write-Log "Failed to set WinHTTP proxy: $($_.Exception.Message)" 'WARN'
    }
}

# TLS hardening
[System.Net.ServicePointManager]::SecurityProtocol = [System.Net.SecurityProtocolType]::Tls12

# -----------------------------
# Download MSIs with retries
# -----------------------------
try {
    Invoke-With-Retry -Description 'Download AVD Agent MSI' -Script {
        Invoke-WebRequest -Uri $AgentMsi -OutFile $AgentPath -UseBasicParsing
        if (-not (Test-Path $AgentPath) -or (Get-Item $AgentPath).Length -lt 1MB) { throw "Agent MSI not downloaded correctly." }
    }
    Invoke-With-Retry -Description 'Download AVD BootLoader MSI' -Script {
        Invoke-WebRequest -Uri $BootMsi -OutFile $BootPath -UseBasicParsing
        if (-not (Test-Path $BootPath) -or (Get-Item $BootPath).Length -lt 1MB) { throw "BootLoader MSI not downloaded correctly." }
    }
} catch {
    Write-Log "Download failure: $($_.Exception.Message)" 'ERROR'
    exit 20
}

# -----------------------------
# Install or Repair Agent / BootLoader
# -----------------------------
function Install-AgentMSI($path, $name) {
    Write-Log "Installing $name..."

    # Build safe log path
    $AgentLog = Join-Path $env:ProgramData "AVD\RDAgent.msi.log"
    New-Item -ItemType Directory -Force -Path (Split-Path $AgentLog) | Out-Null

    # Build argument list safely
    $azArgs = "/i `"$path`" REGISTRATIONTOKEN=`"$RegistrationToken`" /qn /norestart REBOOT=ReallySuppress /l*v `"$AgentLog`""
    $p = Start-Process msiexec.exe -ArgumentList $azArgs -Wait -PassThru
    if ($p.ExitCode -ne 0) {
        Write-Log "$name failed with exit code $($p.ExitCode)" "ERROR"
        exit 40
    }
}

function Install-BootMSI($path, $name) {
    Write-Log "Installing $name..."

    $BootLog = Join-Path $env:ProgramData "AVD\RDAgentBootLoader.msi.log"
    New-Item -ItemType Directory -Force -Path (Split-Path $BootLog) | Out-Null

    $azArgs1 = "/i `"$path`" /qn /norestart REBOOT=ReallySuppress /l*v `"$BootLog`""
    $p = Start-Process msiexec.exe -ArgumentList $azArgs1 -Wait -PassThru
    if ($p.ExitCode -ne 0) {
        Write-Log "$name failed with exit code $($p.ExitCode)" "ERROR"
        exit 40
    }
}

Install-AgentMSI $AgentPath "AVD Agent"
Install-BootMSI $BootPath  "AVD BootLoader"

# -----------------------------
# Start services & Verify
# -----------------------------
function Start-And-CheckService {
    param([string]$Name, [int]$TimeoutSec = 180)
    try {
        $svc = Get-Service -Name $Name -ErrorAction Stop
        if ($svc.Status -ne 'Running') {
            Write-Log "Starting service '$Name'..."
            Start-Service -Name $Name
        }
        # Wait for running
        $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
        while ($stopwatch.Elapsed.TotalSeconds -lt $TimeoutSec) {
            $svc.Refresh()
            if ($svc.Status -eq 'Running') { 
                Write-Log "Service '$Name' is running."
                return
            }
            Start-Sleep -Seconds 3
        }
        throw "Service '$Name' did not reach 'Running' within ${TimeoutSec}s (current: $($svc.Status))"
    } catch {
        throw
    }
}

try {
    # BootLoader triggers registration; agent should already be present
    Start-And-CheckService -Name 'RDAgent'
    Start-And-CheckService -Name 'RDAgentBootLoader'
} catch {
    Write-Log "Service start failure: $($_.Exception.Message)" 'ERROR'
    exit 40
}

# Optional: check event logs for quick signals (non-fatal)
try {
    $recent = Get-WinEvent -FilterHashtable @{ LogName='Microsoft-Windows-RemoteDesktopServices-RdpCoreTS/Operational'; StartTime=(Get-Date).AddMinutes(-10) } -ErrorAction SilentlyContinue
    if ($recent) { Write-Log "Recent RDS events found (this is informational)." }
} catch { }

# -----------------------------
# Cleanup
# -----------------------------
try {
    if (Test-Path $TempRoot) { Remove-Item $TempRoot -Recurse -Force }
    Write-Log "Cleanup complete."
} catch {
    Write-Log "Cleanup warning: $($_.Exception.Message)" 'WARN'
}

Write-Log "=== AVD Host Registration completed successfully ==="
Start-Sleep -Seconds 2
Restart-Computer -Force
