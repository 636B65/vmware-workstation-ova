#!/usr/bin/env bash
set -euo pipefail

# Requires VMware OVF Tool (ovftool). Set OVFTOOL to its full path if it is
# not on PATH or in the default install location.
INVENTORY_FILE="${VMWARE_INVENTORY:-$HOME/.vmware/inventory.vmls}"

fail() {
  printf 'Error: %s\n' "$*" >&2
  exit 1
}

warn() {
  printf 'Warning: %s\n' "$*" >&2
}

usage() {
  printf 'Usage:\n  %s -export [-vm NUMBERS | -all] [-path DESTINATION_DIRECTORY]\n  %s -import -ova OVA_FILE [-path DESTINATION_DIRECTORY]\n' "$0" "$0"
}

find_ovftool() {
  if [[ -n "${OVFTOOL:-}" ]]; then
    [[ -x "$OVFTOOL" ]] || command -v "$OVFTOOL" >/dev/null 2>&1 ||
      fail "OVFTOOL is set but not executable: $OVFTOOL"
    printf '%s\n' "$OVFTOOL"
    return
  fi
  if command -v ovftool >/dev/null 2>&1; then
    command -v ovftool
    return
  fi
  local candidate
  for candidate in /usr/lib/vmware-ovftool/ovftool /usr/bin/ovftool; do
    if [[ -x "$candidate" ]]; then
      printf '%s\n' "$candidate"
      return
    fi
  done
  fail "Cannot find ovftool. Install VMware OVF Tool or set OVFTOOL to its path."
}

# Workstation config files encode special characters as |XX (hex).
decode_vmware_value() {
  local value="$1" decoded="" character
  while [[ "$value" =~ ^([^|]*)\|([0-9A-Fa-f]{2})(.*)$ ]]; do
    printf -v character '%b' "\\x${BASH_REMATCH[2]}"
    decoded+="${BASH_REMATCH[1]}$character"
    value="${BASH_REMATCH[3]}"
  done
  printf '%s' "$decoded$value"
}

# Make a VM display name safe to use as a file or folder name.
safe_file_name() {
  local name="$1"
  name="${name//[\/\\:*?\"<>|]/_}"
  name="${name%"${name##*[![:space:].]}"}"
  [[ -n "$name" ]] || name="VM"
  printf '%s' "$name"
}

# Parse "all" or comma-separated VM numbers into the global "selected" array.
parse_selection() {
  local selection="${1//[[:space:]]/}" value index existing duplicate
  local -a requested=()
  selected=()
  if [[ "${selection,,}" == "all" ]]; then
    selected=("${!vm_paths[@]}")
    return 0
  fi
  IFS=',' read -r -a requested <<< "$selection"
  for value in "${requested[@]}"; do
    if [[ ! "$value" =~ ^[0-9]+$ ]] || ((10#$value < 1 || 10#$value > ${#vm_paths[@]})); then
      selected=()
      return 1
    fi
    index=$((10#$value - 1))
    duplicate=false
    for existing in "${selected[@]}"; do
      [[ "$existing" == "$index" ]] && duplicate=true && break
    done
    [[ "$duplicate" == true ]] || selected+=("$index")
  done
  ((${#selected[@]} > 0))
}

mode=""
destination="$PWD"
ova_file=""
vm_selection=""
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
    -vm)
      (($# >= 2)) || fail "-vm requires VM numbers, such as 1,3."
      [[ -z "$vm_selection" ]] || fail "Use -vm or -all only once."
      vm_selection="$2"
      shift
      ;;
    -all)
      [[ -z "$vm_selection" ]] || fail "Use -vm or -all only once."
      vm_selection="all"
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
if [[ "$mode" == "import" ]]; then
  [[ -z "$vm_selection" ]] || fail "-vm and -all can only be used with -export."
  [[ -n "$ova_file" ]] || fail "For import, specify the source OVA with -ova OVA_FILE."
  [[ -f "$ova_file" ]] || fail "OVA file does not exist: $ova_file"
else
  [[ -z "$ova_file" ]] || fail "-ova can only be used with -import."
fi
ovftool="$(find_ovftool)"

if [[ "$mode" == "import" ]]; then
  name="$(basename "${ova_file%.*}")"
  vm_dir="$destination/$name"
  [[ ! -e "$vm_dir" ]] || fail "Import destination already exists; refusing to overwrite: $vm_dir"
  mkdir -p "$vm_dir"
  printf 'Importing %s to %s\n' "$ova_file" "$vm_dir"
  if ! "$ovftool" --acceptAllEulas "$ova_file" "$vm_dir/$name.vmx"; then
    rm -rf -- "$vm_dir"
    fail "ovftool failed to import '$ova_file'."
  fi
  exit 0
fi

[[ -f "$INVENTORY_FILE" ]] || fail "VMware Workstation inventory not found: $INVENTORY_FILE. Add VMs to the Workstation library or set VMWARE_INVENTORY to the inventory.vmls path."

# Read vmlistN.config and vmlistN.DisplayName entries from the inventory.
declare -A inventory_config=() inventory_name=()
declare -a inventory_order=()
while IFS=$'\t' read -r entry key value; do
  key="${key,,}"
  if [[ "$key" == "config" ]]; then
    [[ -n "${inventory_config[$entry]+set}" ]] || inventory_order+=("$entry")
    inventory_config[$entry]="$(decode_vmware_value "$value")"
  elif [[ "$key" == "displayname" ]]; then
    inventory_name[$entry]="$(decode_vmware_value "$value")"
  fi
done < <(sed -nE 's/^[[:space:]]*vmlist([0-9]+)\.([A-Za-z]+)[[:space:]]*=[[:space:]]*"([^"]*)".*/\1\t\2\t\3/p' "$INVENTORY_FILE")

declare -a vm_paths=() vm_names=() vm_locked=()
declare -A seen_paths=()
for entry in "${inventory_order[@]}"; do
  vmx="${inventory_config[$entry]}"
  # Library folders are also vmlist entries; only VMX paths are VMs.
  [[ "${vmx,,}" == *.vmx ]] || continue
  [[ -z "${seen_paths[$vmx]+set}" ]] || continue
  seen_paths[$vmx]=1
  if [[ ! -f "$vmx" ]]; then
    warn "inventory VMX is missing, skipping: $vmx"
    continue
  fi
  display_name="${inventory_name[$entry]:-}"
  [[ -n "$display_name" ]] || display_name="$(basename "${vmx%.*}")"
  vm_paths+=("$vmx")
  vm_names+=("$display_name")
  if [[ -e "$vmx.lck" ]]; then
    vm_locked+=(true)
  else
    vm_locked+=(false)
  fi
done
((${#vm_paths[@]} > 0)) || fail "No existing VMX files found in VMware Workstation inventory: $INVENTORY_FILE"

printf 'VMs in VMware Workstation inventory:\n'
for i in "${!vm_paths[@]}"; do
  status=""
  [[ "${vm_locked[$i]}" == false ]] || status=" (running or locked)"
  printf '  %d) %s%s\n     %s\n' "$((i + 1))" "${vm_names[$i]}" "$status" "${vm_paths[$i]}"
done

declare -a selected=()
if [[ -n "$vm_selection" ]]; then
  parse_selection "$vm_selection" || fail "Invalid -vm value: $vm_selection. Use numbers from the list, such as 1,3."
else
  [[ -t 0 ]] || fail "VM selection requires an interactive terminal; use -vm NUMBERS or -all."
  while true; do
    read -r -p "Select VM number(s), comma-separated, or 'all': " selection
    parse_selection "$selection" && break
    printf "Enter valid VM number(s), separated by commas, or 'all'.\n" >&2
  done
fi

# Check every destination before exporting anything.
declare -a export_indexes=() export_outputs=()
declare -A planned_outputs=()
skipped=0
for index in "${selected[@]}"; do
  if [[ "${vm_locked[$index]}" == true ]]; then
    warn "'${vm_names[$index]}' is running or locked (${vm_paths[$index]}.lck exists); shut it down first. Skipping."
    skipped=$((skipped + 1))
    continue
  fi
  output="$destination/$(safe_file_name "${vm_names[$index]}").ova"
  [[ ! -e "$output" ]] || fail "Export already exists; refusing to overwrite: $output"
  [[ -z "${planned_outputs[$output]+set}" ]] || fail "Several selected VMs would be exported to $output; rename one of them in Workstation."
  planned_outputs[$output]=1
  export_indexes+=("$index")
  export_outputs+=("$output")
done

failed=0
if ((${#export_indexes[@]} > 0)); then
  mkdir -p "$destination"
fi
for i in "${!export_indexes[@]}"; do
  index="${export_indexes[$i]}"
  output="${export_outputs[$i]}"
  printf 'Exporting %s to %s\n' "${vm_names[$index]}" "$output"
  if ! "$ovftool" --acceptAllEulas "${vm_paths[$index]}" "$output"; then
    rm -f -- "$output"
    warn "ovftool failed to export '${vm_names[$index]}'."
    failed=$((failed + 1))
  fi
done

if ((skipped > 0 || failed > 0)); then
  fail "$((${#export_indexes[@]} - failed)) VM(s) exported, $failed failed, $skipped skipped."
fi
printf '%d VM(s) exported.\n' "${#export_indexes[@]}"
