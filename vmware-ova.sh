#!/usr/bin/env bash
set -euo pipefail

# Requires VMware OVF Tool (ovftool), available on PATH.
OVFTOOL="ovftool"
INVENTORY_FILE="${VMWARE_INVENTORY:-$HOME/.vmware/inventory.vmls}"

fail() {
  printf 'Error: %s\n' "$*" >&2
  exit 1
}

usage() {
  printf 'Usage:\n  %s -export [-path DESTINATION_DIRECTORY]\n  %s -import -ova OVA_FILE [-path DESTINATION_DIRECTORY]\n' "$0" "$0"
}

mode=""
destination="$PWD"
ova_file=""
while (($# > 0)); do
  case "$1" in
    -export)
      [[ -z "$mode" ]] || fail "Choose only one of -export or -import."
      mode="export"
      ;;
    -import)
      [[ -z "$mode" ]] || fail "Choose only one of -export or -import."
      mode="import"
      ;;
    -path)
      (($# >= 2)) || fail "-path requires a destination directory."
      destination="$2"
      shift
      ;;
    -ova)
      (($# >= 2)) || fail "-ova requires an OVA file path."
      ova_file="$2"
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      usage >&2
      fail "Unknown argument: $1"
      ;;
  esac
  shift
done

[[ -n "$mode" ]] || { usage >&2; fail "Specify -export or -import."; }
command -v "$OVFTOOL" >/dev/null 2>&1 || fail "Cannot find '$OVFTOOL'. Install VMware OVF Tool or set OVFTOOL to its path."

declare -a sources=()
if [[ "$mode" == "export" ]]; then
  [[ -f "$INVENTORY_FILE" ]] || fail "VMware Workstation inventory not found: $INVENTORY_FILE. Add VMs to the Workstation library or set VMWARE_INVENTORY to the inventory.vmls path."
  while IFS= read -r vmx; do
    [[ -n "$vmx" ]] || continue
    if [[ -f "$vmx" ]]; then
      sources+=("$vmx")
    else
      printf 'Warning: inventory VMX is missing, skipping: %s\n' "$vmx" >&2
    fi
  done < <(sed -nE 's/^[[:space:]]*vmlist[0-9]+\.config[[:space:]]*=[[:space:]]*"([^"]+)".*/\1/p' "$INVENTORY_FILE")
  ((${#sources[@]} > 0)) || fail "No existing VMX files found in VMware Workstation inventory: $INVENTORY_FILE"
else
  [[ -n "$ova_file" ]] || fail "For import, specify the source OVA with -ova OVA_FILE."
  [[ -f "$ova_file" ]] || fail "OVA file does not exist: $ova_file"
  sources+=("$ova_file")
fi

if [[ "$mode" == "export" ]]; then
  printf 'VMs in VMware Workstation inventory:\n'
else
  printf 'OVA to import:\n'
fi
for i in "${!sources[@]}"; do
  printf '  %d) %s\n     %s\n' "$((i + 1))" "$(basename "${sources[$i]}")" "${sources[$i]}"
done

[[ -t 0 ]] || fail "VM selection requires an interactive terminal."
while true; do
  read -r -p "Select VM number(s), comma-separated, or 'all': " selection
  selection="${selection//[[:space:]]/}"
  if [[ "$selection" == "all" ]]; then
    selected=("${!sources[@]}")
    break
  fi
  IFS=',' read -r -a requested <<< "$selection"
  selected=()
  valid=true
  for value in "${requested[@]}"; do
    if [[ ! "$value" =~ ^[0-9]+$ ]] || ((value < 1 || value > ${#sources[@]})); then
      valid=false
      break
    fi
    index=$((value - 1))
    duplicate=false
    for existing in "${selected[@]}"; do
      [[ "$existing" == "$index" ]] && duplicate=true && break
    done
    [[ "$duplicate" == true ]] || selected+=("$index")
  done
  if [[ "$valid" == true && ${#selected[@]} -gt 0 ]]; then
    break
  fi
  printf "Enter valid VM number(s), separated by commas, or 'all'.\n" >&2
done

mkdir -p "$destination"
for index in "${selected[@]}"; do
  source="${sources[$index]}"
  name="$(basename "${source%.*}")"
  if [[ "$mode" == "export" ]]; then
    output="$destination/$name.ova"
    [[ ! -e "$output" ]] || fail "Export already exists; refusing to overwrite: $output"
    "$OVFTOOL" --acceptAllEulas "$source" "$output"
  else
    vm_dir="$destination/$name"
    vmx="$vm_dir/$name.vmx"
    [[ ! -e "$vm_dir" ]] || fail "Import destination already exists; refusing to overwrite: $vm_dir"
    mkdir -p "$vm_dir"
    "$OVFTOOL" --acceptAllEulas "$source" "$vmx"
  fi
done
