param(
    [switch]$Export,
    [switch]$Import,
    [string]$Path = (Get-Location).Path,
    [string]$Ova,
    [string]$Vm,
    [switch]$All
)

$ErrorActionPreference = "Stop"

# Requires VMware OVF Tool (ovftool). Set the OVFTOOL environment variable to
# its full path if it is not on PATH or in the default install location.
$InventoryFile = if ($env:VMWARE_INVENTORY) {
    $env:VMWARE_INVENTORY
} else {
    Join-Path $env:APPDATA "VMware\inventory.vmls"
}

function Find-OvfTool {
    if ($env:OVFTOOL) {
        if (-not (Get-Command $env:OVFTOOL -ErrorAction SilentlyContinue)) {
            throw "OVFTOOL is set but not executable: $env:OVFTOOL"
        }
        return $env:OVFTOOL
    }
    $command = Get-Command "ovftool" -CommandType Application -ErrorAction SilentlyContinue |
        Select-Object -First 1
    if ($command) {
        return $command.Source
    }
    $candidates = @()
    foreach ($root in @(${env:ProgramFiles(x86)}, $env:ProgramFiles)) {
        if ($root) {
            $candidates += Join-Path $root "VMware\VMware Workstation\OVFTool\ovftool.exe"
            $candidates += Join-Path $root "VMware\VMware OVF Tool\ovftool.exe"
        }
    }
    foreach ($candidate in $candidates) {
        if (Test-Path -LiteralPath $candidate -PathType Leaf) {
            return $candidate
        }
    }
    throw "Cannot find ovftool. Install VMware OVF Tool or set the OVFTOOL environment variable to its path."
}

# Workstation config files encode special characters as |XX (hex).
function ConvertFrom-VMwareValue([string]$Value) {
    return [regex]::Replace($Value, '\|([0-9A-Fa-f]{2})', {
        param($match)
        [string][char][Convert]::ToInt32($match.Groups[1].Value, 16)
    })
}

# Make a VM display name safe to use as a file or folder name.
function ConvertTo-SafeFileName([string]$Name) {
    $safe = $Name
    foreach ($character in [IO.Path]::GetInvalidFileNameChars() + [char[]]'/\:*?"<>|') {
        $safe = $safe.Replace([string]$character, "_")
    }
    $safe = $safe.TrimEnd(" ", ".")
    if ([string]::IsNullOrEmpty($safe)) {
        $safe = "VM"
    }
    return $safe
}

# Parse "all" or comma-separated VM numbers into zero-based indexes.
# Returns $null when the selection is invalid.
function Get-Selection([string]$Selection, [int]$Count) {
    $Selection = ($Selection -replace '\s', '')
    if ($Selection -eq "all") {
        return , @(0..($Count - 1))
    }
    $selected = @()
    foreach ($value in $Selection -split ',') {
        $number = 0
        if (-not [int]::TryParse($value, [ref]$number) -or $number -lt 1 -or $number -gt $Count) {
            return $null
        }
        if (($number - 1) -notin $selected) {
            $selected += $number - 1
        }
    }
    if ($selected.Count -eq 0) {
        return $null
    }
    return , $selected
}

if ($Export -eq $Import) {
    throw "Specify exactly one of -Export or -Import."
}
if ($Vm -and $All) {
    throw "Use either -Vm or -All, not both."
}
if ($Import) {
    if ($Vm -or $All) {
        throw "-Vm and -All can only be used with -Export."
    }
    if ([string]::IsNullOrWhiteSpace($Ova)) {
        throw "For import, specify the source OVA with -Ova OVA_FILE."
    }
    if (-not (Test-Path -LiteralPath $Ova -PathType Leaf)) {
        throw "OVA file does not exist: $Ova"
    }
} elseif ($Ova) {
    throw "-Ova can only be used with -Import."
}
$OvfTool = Find-OvfTool

if ($Import) {
    $name = [IO.Path]::GetFileNameWithoutExtension($Ova)
    $vmDirectory = Join-Path $Path $name
    if (Test-Path -LiteralPath $vmDirectory) {
        throw "Import destination already exists; refusing to overwrite: $vmDirectory"
    }
    New-Item -ItemType Directory -Path $vmDirectory -Force | Out-Null
    Write-Host "Importing $Ova to $vmDirectory"
    & $OvfTool --acceptAllEulas $Ova (Join-Path $vmDirectory "$name.vmx")
    if ($LASTEXITCODE -ne 0) {
        $exitCode = $LASTEXITCODE
        Remove-Item -LiteralPath $vmDirectory -Recurse -Force
        throw "ovftool failed to import '$Ova' (exit code $exitCode)."
    }
    return
}

if (-not (Test-Path -LiteralPath $InventoryFile -PathType Leaf)) {
    throw "VMware Workstation inventory not found: $InventoryFile. Add VMs to the Workstation library or set VMWARE_INVENTORY to the inventory.vmls path."
}

# Read vmlistN.config and vmlistN.DisplayName entries from the inventory.
$configs = [ordered]@{}
$displayNames = @{}
foreach ($line in Get-Content -LiteralPath $InventoryFile -Encoding UTF8) {
    if ($line -match '^\s*vmlist(\d+)\.(config|DisplayName)\s*=\s*"([^"]*)"') {
        $value = ConvertFrom-VMwareValue $Matches[3]
        if ($Matches[2] -eq "config") {
            $configs[$Matches[1]] = $value
        } else {
            $displayNames[$Matches[1]] = $value
        }
    }
}

$vms = @()
$seenPaths = @{}
foreach ($entry in $configs.Keys) {
    $vmx = $configs[$entry]
    # Library folders are also vmlist entries; only VMX paths are VMs.
    if ($vmx -notlike "*.vmx" -or $seenPaths.ContainsKey($vmx)) {
        continue
    }
    $seenPaths[$vmx] = $true
    if (-not (Test-Path -LiteralPath $vmx -PathType Leaf)) {
        Write-Warning "Inventory VMX is missing, skipping: $vmx"
        continue
    }
    $displayName = $displayNames[$entry]
    if ([string]::IsNullOrWhiteSpace($displayName)) {
        $displayName = [IO.Path]::GetFileNameWithoutExtension($vmx)
    }
    $vms += [pscustomobject]@{
        Vmx    = $vmx
        Name   = $displayName
        Locked = Test-Path -LiteralPath "$vmx.lck"
    }
}
if ($vms.Count -eq 0) {
    throw "No existing VMX files found in VMware Workstation inventory: $InventoryFile"
}

Write-Host "VMs in VMware Workstation inventory:"
for ($i = 0; $i -lt $vms.Count; $i++) {
    $status = if ($vms[$i].Locked) { " (running or locked)" } else { "" }
    Write-Host ("  {0}) {1}{2}" -f ($i + 1), $vms[$i].Name, $status)
    Write-Host "     $($vms[$i].Vmx)"
}

if ($All) {
    $selected = Get-Selection "all" $vms.Count
} elseif ($Vm) {
    $selected = Get-Selection $Vm $vms.Count
    if ($null -eq $selected) {
        throw "Invalid -Vm value: $Vm. Use numbers from the list, such as 1,3."
    }
} else {
    if ([Console]::IsInputRedirected) {
        throw "VM selection requires an interactive console; use -Vm NUMBERS or -All."
    }
    while ($true) {
        $selected = Get-Selection ([string](Read-Host "Select VM number(s), comma-separated, or 'all'")) $vms.Count
        if ($null -ne $selected) {
            break
        }
        Write-Warning "Enter valid VM number(s), separated by commas, or 'all'."
    }
}

# Check every destination before exporting anything.
$exports = @()
$plannedOutputs = @{}
$skipped = 0
foreach ($index in $selected) {
    $vmInfo = $vms[$index]
    if ($vmInfo.Locked) {
        Write-Warning "'$($vmInfo.Name)' is running or locked ($($vmInfo.Vmx).lck exists); shut it down first. Skipping."
        $skipped++
        continue
    }
    $output = Join-Path $Path "$(ConvertTo-SafeFileName $vmInfo.Name).ova"
    if (Test-Path -LiteralPath $output) {
        throw "Export already exists; refusing to overwrite: $output"
    }
    if ($plannedOutputs.ContainsKey($output)) {
        throw "Several selected VMs would be exported to $output; rename one of them in Workstation."
    }
    $plannedOutputs[$output] = $true
    $exports += [pscustomobject]@{ Vm = $vmInfo; Output = $output }
}

$failed = 0
if ($exports.Count -gt 0) {
    New-Item -ItemType Directory -Path $Path -Force | Out-Null
}
foreach ($item in $exports) {
    Write-Host "Exporting $($item.Vm.Name) to $($item.Output)"
    & $OvfTool --acceptAllEulas $item.Vm.Vmx $item.Output
    if ($LASTEXITCODE -ne 0) {
        Write-Warning "ovftool failed to export '$($item.Vm.Name)' (exit code $LASTEXITCODE)."
        Remove-Item -LiteralPath $item.Output -Force -ErrorAction SilentlyContinue
        $failed++
    }
}

if ($skipped -gt 0 -or $failed -gt 0) {
    throw "$($exports.Count - $failed) VM(s) exported, $failed failed, $skipped skipped."
}
Write-Host "$($exports.Count) VM(s) exported."
