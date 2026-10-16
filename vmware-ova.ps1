param(
    [switch]$Export,
    [switch]$Import,
    [string]$Path = (Get-Location).Path,
    [string]$Ova
)

$ErrorActionPreference = "Stop"

# Requires VMware OVF Tool (ovftool), available on PATH.
$OvfTool = "ovftool"
$InventoryFile = if ($env:VMWARE_INVENTORY) {
    $env:VMWARE_INVENTORY
} else {
    Join-Path $env:APPDATA "VMware\inventory.vmls"
}

if ($Export -eq $Import) {
    throw "Specify exactly one of -Export or -Import."
}
$mode = if ($Export) { "export" } else { "import" }
if (-not (Get-Command $OvfTool -ErrorAction SilentlyContinue)) {
    throw "Cannot find '$OvfTool'. Install VMware OVF Tool or set `$OvfTool to its path."
}

$sources = @()
if ($mode -eq "export") {
    if (-not (Test-Path -LiteralPath $InventoryFile -PathType Leaf)) {
        throw "VMware Workstation inventory not found: $InventoryFile. Add VMs to the Workstation library or set VMWARE_INVENTORY to the inventory.vmls path."
    }
    foreach ($line in Get-Content -LiteralPath $InventoryFile) {
        if ($line -match '^\s*vmlist\d+\.config\s*=\s*"([^"]+)"') {
            $vmx = $Matches[1]
            if (Test-Path -LiteralPath $vmx -PathType Leaf) {
                $sources += $vmx
            } else {
                Write-Warning "Inventory VMX is missing, skipping: $vmx"
            }
        }
    }
    if ($sources.Count -eq 0) {
        throw "No existing VMX files found in VMware Workstation inventory: $InventoryFile"
    }
} else {
    if ([string]::IsNullOrWhiteSpace($Ova)) {
        throw "For import, specify the source OVA with -Ova OVA_FILE."
    }
    if (-not (Test-Path -LiteralPath $Ova -PathType Leaf)) {
        throw "OVA file does not exist: $Ova"
    }
    $sources = @($Ova)
}

if ($mode -eq "export") {
    Write-Host "VMs in VMware Workstation inventory:"
} else {
    Write-Host "OVA to import:"
}
for ($i = 0; $i -lt $sources.Count; $i++) {
    Write-Host ("  {0}) {1}" -f ($i + 1), [IO.Path]::GetFileName($sources[$i]))
    Write-Host "     $($sources[$i])"
}

while ($true) {
    $selection = (Read-Host "Select VM number(s), comma-separated, or 'all'").Trim()
    if ($selection -eq "all") {
        $selected = @(0..($sources.Count - 1))
        break
    }
    $requested = $selection -split ','
    $selected = @()
    $valid = $requested.Count -gt 0
    foreach ($value in $requested) {
        $number = 0
        if (-not [int]::TryParse($value.Trim(), [ref]$number) -or
            $number -lt 1 -or $number -gt $sources.Count) {
            $valid = $false
            break
        }
        $index = $number - 1
        if ($index -notin $selected) {
            $selected += $index
        }
    }
    if ($valid -and $selected.Count -gt 0) {
        break
    }
    Write-Warning "Enter valid VM number(s), separated by commas, or 'all'."
}

New-Item -ItemType Directory -Path $Path -Force | Out-Null
foreach ($index in $selected) {
    $source = $sources[$index]
    $name = [IO.Path]::GetFileNameWithoutExtension($source)
    if ($mode -eq "export") {
        $output = Join-Path $Path "$name.ova"
        if (Test-Path -LiteralPath $output) {
            throw "Export already exists; refusing to overwrite: $output"
        }
        & $OvfTool --acceptAllEulas $source $output
        if ($LASTEXITCODE -ne 0) {
            throw "ovftool failed to export '$source' (exit code $LASTEXITCODE)."
        }
    } else {
        $vmDirectory = Join-Path $Path $name
        $vmx = Join-Path $vmDirectory "$name.vmx"
        if (Test-Path -LiteralPath $vmDirectory) {
            throw "Import destination already exists; refusing to overwrite: $vmDirectory"
        }
        New-Item -ItemType Directory -Path $vmDirectory | Out-Null
        & $OvfTool --acceptAllEulas $source $vmx
        if ($LASTEXITCODE -ne 0) {
            throw "ovftool failed to import '$source' (exit code $LASTEXITCODE)."
        }
    }
}
