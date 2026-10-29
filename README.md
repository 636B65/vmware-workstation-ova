# VMware Workstation OVA export and import

The export command reads the VMware Workstation library inventory, lists
registered VMs, and lets you choose one or more VMs by number. It does not
need a separate VM list/config file.

## Requirements

- VMware Workstation with VMs added to its library.
- VMware OVF Tool (`ovftool`). The scripts look for it on `PATH` and in the
  default install locations (`/usr/lib/vmware-ovftool` on Linux, the
  Workstation `OVFTool` folder or `VMware OVF Tool` under Program Files on
  Windows). To use another copy, set the `OVFTOOL` environment variable to its
  full path.
- For export, shut down VMs first. A VM whose `.vmx.lck` lock folder exists is
  shown as "running or locked" and is skipped. If Workstation crashed and left
  a stale lock behind, remove the `.lck` folder when the VM is not running.

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

The script lists VMs by their Workstation display name and prompts for VM
numbers. Enter one number, a comma-separated list such as `1,3`, or `all`. The
default export location is the current directory. Use `-path` to choose another
location:

```bash
./vmware-ova.sh -export -path "/backup/VM exports"
```

To run without a prompt, for example from cron, pass the selection with `-vm`
or export everything with `-all`:

```bash
./vmware-ova.sh -export -vm 1,3 -path "/backup/VM exports"
./vmware-ova.sh -export -all -path "/backup/VM exports"
```

Import an OVA by providing its path; `-path` sets the destination directory.
Import does not prompt:

```bash
./vmware-ova.sh -import -ova "/backup/Accounting.ova" -path "/vmware/imported"
```

If the script is not executable yet, run `chmod +x vmware-ova.sh` once. The
Bash script needs Bash 4.4 or later.

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

Skip the prompt with `-Vm` or `-All`, for example in a scheduled task:

```powershell
.\vmware-ova.ps1 -Export -Vm 1,3 -Path "E:\VM exports"
.\vmware-ova.ps1 -Export -All -Path "E:\VM exports"
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

Each exported VM is written as `<display name>.ova` in the selected
destination; characters that are not allowed in file names are replaced with
`_`. Each imported OVA is placed in a subfolder named after the OVA, with the
VMX file inside it.

- The scripts refuse to overwrite existing exports or import folders. All
  export destinations are checked before the first export starts, including
  two selected VMs that would get the same file name.
- If `ovftool` fails, the partial `.ova` or import folder is removed. Exports
  continue with the remaining VMs.
- Missing/stale VM entries and library folders in Workstation's inventory are
  skipped; missing VMs are reported with a warning.
- The script exits with a non-zero status if any selected VM was skipped or
  failed to export, so scheduled jobs can detect it.
