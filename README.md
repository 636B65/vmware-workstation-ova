# VMware Workstation OVA export and import

The export command reads the VMware Workstation library inventory, lists
registered VMs, and lets you choose one or more VMs by number. It does not
need a separate VM list/config file.

## Requirements

- VMware Workstation with VMs added to its library.
- VMware OVF Tool installed and `ovftool` available on `PATH`.
- For export, shut down VMs first for a consistent export.

The scripts read the Workstation inventory file from its standard location:

- Linux: `~/.vmware/inventory.vmls`
- Windows: `%APPDATA%\VMware\inventory.vmls`

To use a different inventory file, set `VMWARE_INVENTORY` to its full path
before running the script.

## Bash

Export all registered VMs or choose specific VM numbers:

```bash
./vmware-ova.sh -export
```

The script prompts for VM numbers. Enter one number, a comma-separated list
such as `1,3`, or `all`. The default export location is the current directory.
Use `-path` to choose another location:

```bash
./vmware-ova.sh -export -path "/backup/VM exports"
```

Import an OVA by providing its path; `-path` sets the destination directory:

```bash
./vmware-ova.sh -import -ova "/backup/Accounting.ova" -path "/vmware/imported"
```

If the script is not executable yet, run `chmod +x vmware-ova.sh` once.

## PowerShell

Export VMs from the Workstation inventory:

```powershell
.\vmware-ova.ps1 -Export
```

At the prompt, enter a VM number, comma-separated numbers such as `1,3`, or
`all`. The default export location is the current directory. Override it with
`-Path`:

```powershell
.\vmware-ova.ps1 -Export -Path "E:\VM exports"
```

Import an OVA:

```powershell
.\vmware-ova.ps1 -Import -Ova "E:\Backups\Accounting.ova" -Path "D:\VMs\Imported"
```

PowerShell may require allowing local scripts for the current process:

```powershell
Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass
```

## Output and safety

Each exported VM is written as `<VM name>.ova` in the selected destination.
Each imported OVA is placed in a subfolder named after the OVA, with the VMX
file inside it. The scripts refuse to overwrite existing exports or import
folders. Missing/stale VM entries in Workstation's inventory are skipped with
a warning.
