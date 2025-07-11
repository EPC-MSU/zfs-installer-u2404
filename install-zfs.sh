#!/bin/bash

# shellcheck disable=SC2016 # single quoted strings with characters used for interpolation

set -o errexit
set -o pipefail
set -o nounset

# VARIABLES/CONSTANTS ##########################################################

# Variables set (indirectly) by the user
#
# The passphrase has a special workflow - it's sent to a named pipe (see create_passphrase_named_pipe()).
# The same strategy can possibly be used for `v_root_passwd` (the difference being that is used
# inside a jail); logging the ZFS commands is enough, for now.
#
# Note that `ZFS_PASSPHRASE` considers the unset state (see help).

v_boot_partition_size=       # Integer number with `M` or `G` suffix
v_bpool_create_options=      # array; see defaults below for format
v_passphrase=
v_root_password=             # Debian-only
v_rpool_name=
v_rpool_create_options=      # array; see defaults below for format
v_dataset_create_options=    # string; see help for format
declare -A v_vdev_configs    # ([0,1,2]=mirror, ...)
declare -a v_selected_disks  # (/dev/by-id/disk_id, ...)
v_swap_size=                 # integer
v_free_tail_space=           # integer

# Variables set during execution

v_linux_distribution=        # Debian, Ubuntu, ... WATCH OUT: not necessarily from `lsb_release` (ie. UbuntuServer)
v_use_ppa=                   # 1=true, false otherwise (applies only to Ubuntu-based).
v_temp_volume_device=        # /dev/zdN; scope: setup_partitions -> sync_os_temp_installation_dir_to_rpool
v_suitable_disks=()          # (/dev/by-id/disk_id, ...); scope: find_suitable_disks -> select_disk

# Constants
#
# Note that Linux Mint is "Linuxmint" from v20 onwards. This actually helps, since some operations are
# specific to it.

c_hotswap_file=$PWD/install-zfs.hotswap.sh # see hotswap() for an explanation.

c_bpool_name=bpool
c_ppa=ppa:jonathonf/zfs
c_efi_system_partition_size=512 # megabytes
c_default_boot_partition_size=2048 # megabytes
c_memory_warning_limit=$((3584 - 128)) # megabytes; exclude some RAM, which can be occupied/shared
c_default_bpool_create_options=(
  -o ashift=12
  -o autotrim=on
  -d
  -o feature@async_destroy=enabled
  -o feature@bookmarks=enabled
  -o feature@embedded_data=enabled
  -o feature@empty_bpobj=enabled
  -o feature@enabled_txg=enabled
  -o feature@extensible_dataset=enabled
  -o feature@filesystem_limits=enabled
  -o feature@hole_birth=enabled
  -o feature@large_blocks=enabled
  -o feature@lz4_compress=enabled
  -o feature@spacemap_histogram=enabled
  -O acltype=posixacl
  -O compression=lz4
  -O devices=off
  -O normalization=formD
  -O relatime=on
  -O xattr=sa
)
c_default_rpool_create_options=(
  -o ashift=12
  -o autotrim=on
  -O acltype=posixacl
  -O compression=lz4
  -O dnodesize=auto
  -O normalization=formD
  -O relatime=on
  -O xattr=sa
  -O devices=off
)
c_dataset_options_help='# The defaults create a root pool similar to the Ubuntu default; see the script help for details.
# Double quotes are forbidden; lines starting with a hash (`#`) are ignored.
# Parameters and command substitutions are applied; useful variables are $c_zfs_mount_dir and $v_rpool_name.
'
# Can't include double quotes, due to the templating logic.
# KUbuntu has a /home/.directory, which must not be a separate dataset (it's a symlink).
#
c_default_dataset_create_options='
ROOT                           mountpoint=/ com.ubuntu.zsys:bootfs=yes com.ubuntu.zsys:last-used=$(date +%s)
ROOT/srv                       com.ubuntu.zsys:bootfs=no
ROOT/usr                       canmount=off com.ubuntu.zsys:bootfs=no
ROOT/usr/local
ROOT/var                       canmount=off com.ubuntu.zsys:bootfs=no
ROOT/var/games
ROOT/var/lib
ROOT/var/lib/AccountsService
ROOT/var/lib/apt
ROOT/var/lib/dpkg
ROOT/var/lib/NetworkManager
ROOT/var/log
ROOT/var/mail
ROOT/var/snap
ROOT/var/spool
ROOT/var/www
ROOT/tmp                       com.ubuntu.zsys:bootfs=no

USERDATA                       mountpoint=/ canmount=off
USERDATA/root                  mountpoint=/root canmount=on com.ubuntu.zsys:bootfs-datasets=$v_rpool_name/ROOT

$(find $c_installed_os_mount_dir/home -mindepth 1 -maxdepth 1 -not -name '\''.*'\'' -printf '\''
USERDATA/%P                    mountpoint=/home/%P canmount=on com.ubuntu.zsys:bootfs-datasets=$v_rpool_name/%P
'\'')
'
c_zfs_mount_dir=/mnt
c_installed_os_mount_dir=/target
declare -A c_supported_linux_distributions=([Debian]="10 11" [Ubuntu]="24.04" [UbuntuServer]="18.04 20.04 22.04" [LinuxMint]="19.1 19.2 19.3" [Linuxmint]="20 20.1" [elementary]=5.1)
c_temporary_volume_size=12  # gigabytes; large enough - Debian, for example, takes ~8 GiB.
c_passphrase_named_pipe=$(dirname "$(mktemp)")/zfs-installer.pp.fifo
c_dns=8.8.8.8

c_log_dir=$(dirname "$(mktemp)")/zfs-installer
c_install_log=$c_log_dir/install.log
c_os_information_log=$c_log_dir/os_information.log
c_running_processes_log=$c_log_dir/running_processes.log
c_disks_log=$c_log_dir/disks.log
c_zfs_module_version_log=$c_log_dir/updated_module_versions.log

# On a system, while installing Ubuntu 18.04(.4), all the `udevadm settle` invocations timed out.
#
# It's not clear why this happens, so we set a large enough timeout. On systems without this issue,
# the timeout won't matter, while on systems with the issue, the timeout will be enough to ensure
# that the devices are created.
#
# Note that the strategy of continuing in any case (`|| true`) is not the best, however, the exit
# codes are not documented.
#
c_udevadm_settle_timeout=10 # seconds

# HELPER FUNCTIONS #############################################################

# Invoke a function, with a primitive dynamic dispatch based on the distribution.
#
# Format: `invoke "function" [--optional]`.
#
# A target function must exist, otherwise a error is raised, unless `--optional` is specified.
# `--optional` is useful when a step is specific to a single distribution, e.g. Debian's root password.
#
# WATCH OUT! Don't forget *not* to call this from an ovverridden function, otherwise, it will call itself
# endlessly!
#
# Examples:
#
#   $ function install_jail_zfs_packages { :; }
#   $ function install_jail_zfs_packages_Debian { :; }
#   $ invoke "install_jail_zfs_packages"
#
#   If the distribution is `Debian`, the second will be invoked, otherwise, the first.
#
#   $ function update_zed_cache_Ubuntu { :; }
#   $ invoke "update_zed_cache" --optional
#
#   If the distribution is `Debian`, nothing will happen.
#
#   $ function update_zed_cache_Ubuntu { :; }
#   $ invoke "update_zed_cache"
#
#   If the distribution is `Debian`, an error will be raised.
#
function invoke {
  local base_fx_name=$1
  local distro_specific_fx_name=$1_$v_linux_distribution
  local invoke_option=${2:-}

  if [[ ! $invoke_option =~ ^(|--optional)$ ]]; then
    >&2 echo "Invalid invoke() option: $invoke_option"
    exit 1
  fi

  hot_swap_script

  # Invoke it regardless when it's not optional.

  if declare -f "$distro_specific_fx_name" > /dev/null; then
    print_step_info_header "$distro_specific_fx_name"

    "$distro_specific_fx_name"
  elif declare -f "$base_fx_name" > /dev/null || [[ ! $invoke_option == "--optional" ]]; then
    print_step_info_header "$base_fx_name"

    "$base_fx_name"
  fi
}

# Tee-hee-hee!!
#
# This is extremely useful for debugging long procedures. Since bash scripts can't be modified while
# running, this allows the dev to create a snapshot, and if the script fails after that, resume and
# add the hotswap script, so that the new code will be loaded automatically.
#
function hot_swap_script {
  if [[ -f $c_hotswap_file ]]; then
    # shellcheck disable=1090 # can't follow; the file might not exist anyway.
    source "$c_hotswap_file"
  fi
}

function print_step_info_header {
  local function_name=$1

  echo -n "
###############################################################################
# $function_name
###############################################################################
"
}

function print_variables {
  for variable_name in "$@"; do
    declare -n variable_reference="$variable_name"

    echo -n "$variable_name:"

    case "$(declare -p "$variable_name")" in
    "declare -a"* )
      for entry in "${variable_reference[@]}"; do
        echo -n " \"$entry\""
      done
      ;;
    "declare -A"* )
      for key in "${!variable_reference[@]}"; do
        echo -n " $key=\"${variable_reference[$key]}\""
      done
      ;;
    * )
      echo -n " $variable_reference"
      ;;
    esac

    echo
  done

  echo
}

# Very annoyingly, some distros (e.g. Linux Mint) have a "reduced" version of add-apt-repository
#
function checked_add_apt_repository {
  local repository=$1
  local option=${2:-} # optional: `--chroot`

  local add_repo_command=(add-apt-repository --yes "$repository")

  if add-apt-repository --help | grep -q "\--no-update"; then
    # Assume that when this option isn't available, no update is performed. The fragmentation is a PITA.
    #
    add_repo_command+=(--no-update)
  fi

  case $option in
  '')
    "${add_repo_command[@]}"
    ;;
  --chroot)
    chroot_execute "${add_repo_command[*]}"
    ;;
  *)
    >&2 echo "Unexpected checked_add_apt_repository option: $2"
    exit 1
  esac
}

# Prints the zpool create vdev options, for the current v_vdev_configs; for example:
#
#     mirror vdev1-part3 vdev2-part3 mirror vdev3-part3 vdev4-part3
#
# Input: $1 = `rpool`, `bpool`, `-` (the last doesn't append anything).
#
function compose_pool_create_vdev_options {
  case $1 in
  rpool)
    local partition_suffix=-part3;;
  bpool)
    local partition_suffix=-part2;;
  -)
    local partition_suffix=;;
  *)
    >&2 echo "Wrong compose_pool_create_vdev_options() parameter: \`$1\`"
    exit 1
  esac

  local result=

  # First, we must put all the striping vdevs (which have blank vdev type).
  #
  for device_indexes in "${!v_vdev_configs[@]}"; do
    local vdev_type=${v_vdev_configs[$device_indexes]}

    if [[ -z $vdev_type ]]; then
      mapfile -d, -t device_indexes < <(echo -n "$device_indexes")

      for device_index in "${device_indexes[@]}"; do
        result+=" ${v_selected_disks[$device_index]}$partition_suffix"
      done
    fi
  done

  # Then, all the other types.
  #
  for device_indexes in "${!v_vdev_configs[@]}"; do
    local vdev_type=${v_vdev_configs[$device_indexes]}

    if [[ -n $vdev_type ]]; then
      result+=" $vdev_type"

      mapfile -d, -t device_indexes < <(echo -n "$device_indexes")

      for device_index in "${device_indexes[@]}"; do
        result+=" ${v_selected_disks[$device_index]}$partition_suffix"
      done
    fi
  done

  echo -n "$result" | sed -e 's/^ //'
}

function chroot_execute {
  chroot $c_zfs_mount_dir bash -c "$1"
}

# PROCEDURE STEP FUNCTIONS #####################################################

function display_help_and_exit {
  local help
  help='Usage: install-zfs.sh [-h|--help]

Sets up and install a ZFS Ubuntu installation.

This script needs to be run with admin permissions, from a Live CD.

The procedure can be entirely automated via environment variables:

- ZFS_OS_INSTALLATION_SCRIPT : path of a script to execute instead of Ubiquity (see dedicated section below)
- ZFS_USE_PPA                : set to 1 to use packages from `'"$c_ppa"'` (automatically set to true if the O/S version doesn'\''t ship at least v0.8)
- ZFS_SELECTED_DISKS         : full path of the devices to create the pool on, comma-separated
- ZFS_BOOT_PARTITION_SIZE    : integer number with `M` or `G` suffix (defaults to `'${c_default_boot_partition_size}M'`)
- ZFS_PASSPHRASE             : set non-blank to encrypt the pool, and blank not to. if unset, it will be asked.
- ZFS_DEBIAN_ROOT_PASSWORD
- ZFS_RPOOL_NAME
- ZFS_BPOOL_CREATE_OPTIONS   : boot pool options to set on creation (see defaults below)
- ZFS_RPOOL_CREATE_OPTIONS   : root pool options to set on creation (see defaults below)
- ZFS_VDEV_CONFIGS           : example: `[0,1]=mirror, [2,3]=mirror`; the (0-based) indexes refer to the selected disks
- ZFS_DATASET_CREATE_OPTIONS : see explanation below
- ZFS_NO_INFO_MESSAGES       : set 1 to skip informational messages
- ZFS_SWAP_SIZE              : swap size (integer); set 0 for no swap
- ZFS_FREE_TAIL_SPACE        : leave free space at the end of each disk (integer), for example, for a swap partition

- ZFS_SKIP_LIVE_ZFS_MODULE_INSTALL : (debug) set 1 to skip installing the ZFS package on the live system; speeds up installation on preset machines

When installing the O/S via $ZFS_OS_INSTALLATION_SCRIPT, the root pool is mounted as `'$c_zfs_mount_dir'`; the requisites are:

1. the virtual filesystems must be mounted in `'$c_zfs_mount_dir'` (ie. `for vfs in proc sys dev; do mount --rbind /$vfs '$c_zfs_mount_dir'/$vfs; done`)
2. internet must be accessible while chrooting in `'$c_zfs_mount_dir'` (ie. `echo nameserver '$c_dns' >> '$c_zfs_mount_dir'/etc/resolv.conf`)
3. `'$c_zfs_mount_dir'` must be left in a dismountable state (e.g. no file locks, no swap etc.);

Boot pool default create options: '"${c_default_bpool_create_options[*]/#-/$'\n'  -}"'

Root pool default create options: '"${c_default_rpool_create_options[*]/#-/$'\n'  -}"'

The root pool dataset creation options can be specified by passing a string of whom each line has:

- the dataset name (without the pool)
- the options (without `-o`)

The defaults, which create a root pool similar to the Ubuntu default, are:

'"$(echo -n "$c_default_dataset_create_options" | sed 's/^/  /')"'

Double quotes are forbidden. Parameters and command substitutions are applied; useful variables are $c_zfs_mount_dir and $v_rpool_name.

Datasets are created after the operating system is installed; at that stage, it'\'' mounted in the directory specified by $c_zfs_mount_dir.
'

  echo "$help"

  exit 0
}

function activate_debug {
  mkdir -p "$c_log_dir"

  exec 5> "$c_install_log"
  BASH_XTRACEFD="5"
  set -x
}

function set_distribution_data {
  v_linux_distribution="$(lsb_release --id --short)"

  if [[ "$v_linux_distribution" == "Ubuntu" ]] && grep -q '^Status: install ok installed$' < <(dpkg -s ubuntu-server 2> /dev/null); then
    v_linux_distribution="UbuntuServer"
  fi

  v_linux_version="$(lsb_release --release --short)"
}

function store_os_distro_information {
  lsb_release --all > "$c_os_information_log"

  # Madness, in order not to force the user to invoke "sudo -E".
  # Assumes that the user runs exactly `sudo bash`; it's not a (current) concern if the user runs off specification.
  # Not found when running via SSH - inspect the processes for finding this information.
  #
  perl -lne 'BEGIN { $/ = "\0" } print if /^XDG_CURRENT_DESKTOP=/' /proc/"$PPID"/environ >> "$c_os_information_log"
}

function store_os_distro_information_Debian {
  store_os_distro_information

  echo "DEBIAN_VERSION=$(cat /etc/debian_version)" >> "$c_os_information_log"
}

# Simplest and most solid way to gather the desktop environment (!).
# See note in store_os_distro_information().
#
function store_running_processes {
  ps ax --forest > "$c_running_processes_log"
}

function check_prerequisites {
  local distro_version_regex=\\b${v_linux_version//./\\.}\\b

  if [[ ! -d /sys/firmware/efi ]]; then
    echo 'System firmware directory not found; make sure to boot in EFI mode!'
    exit 1
  elif [[ $(id -u) -ne 0 ]]; then
    echo 'This script must be run with administrative privileges!'
    exit 1
  elif [[ -n ${ZFS_OS_INSTALLATION_SCRIPT:-} && ! -x $ZFS_OS_INSTALLATION_SCRIPT ]]; then
    echo "The custom O/S installation script provided doesn't exist or is not executable!"
    exit 1
  elif [[ ! -v c_supported_linux_distributions["$v_linux_distribution"] ]]; then
    echo "This Linux distribution ($v_linux_distribution) is not supported!"
    exit 1
  elif [[ ! ${c_supported_linux_distributions["$v_linux_distribution"]} =~ $distro_version_regex ]]; then
    echo "This Linux distribution version ($v_linux_version) is not supported; supported versions: ${c_supported_linux_distributions["$v_linux_distribution"]}"
    exit 1
  elif [[ ${ZFS_USE_PPA:-} == "1" && $v_linux_distribution == "UbuntuServer" ]]; then
    # As of Jun/2021, it breaks the installation.
    #
    echo "The PPA is not (currently) supported on Ubuntu Server! It's still possible to add it after the installation, but there are no guarantees."
    exit 1
  elif ! ping -c 1 "$c_dns" > /dev/null; then
    echo "Can't contact the DNS ($c_dns)!"
    exit 1
  fi

  set +x

  if [[ -v ZFS_PASSPHRASE && -n $ZFS_PASSPHRASE && ${#ZFS_PASSPHRASE} -lt 8 ]]; then
    echo "The passphase provided is too short; at least 8 chars required."
    exit 1
  fi

  set -x
}

function display_intro_banner {
  local dialog_message='Hello!

This script will prepare the ZFS pools on the system, install Ubuntu, and configure the boot.

In order to stop the procedure, hit Esc twice during dialogs (excluding yes/no ones), or Ctrl+C while any operation is running.
'

  if [[ -z ${ZFS_NO_INFO_MESSAGES:-} ]]; then
    whiptail --msgbox "$dialog_message" 30 100
  fi
}

function check_system_memory {
    local system_memory
    system_memory=$(free -m | perl -lane 'print @F[1] if $. == 2')

    if [[ $system_memory -lt $c_memory_warning_limit && -z ${ZFS_NO_INFO_MESSAGES:-} ]]; then
      # A workaround for these cases is to use the swap generate, but this can potentially cause troubles
      # (severe compilation slowdowns) if a user tries to compensate too little memory with a large swapfile.
      #
      local dialog_message='WARNING! In some cases, the ZFS modules require compilation.

On systems with relatively little RAM and many hardware threads, the procedure may crash during the compilation (e.g. 3 GB/16 threads).

In such cases, the module building may fail abruptly, either without visible errors (leaving "process killed" messages in the syslog), or with package installation errors (leaving odd errors in the module'\''s `make.log`).'

      whiptail --msgbox "$dialog_message" 30 100
    fi
}

function save_disks_log {
  # shellcheck disable=SC2012 # `ls` may clean the output, but in this case, it doesn't matter
  ls -l /dev/disk/by-id | tail -n +2 | perl -lane 'print "@F[8..10]"' > "$c_disks_log"

  all_disk_ids=$(find /dev/disk/by-id -mindepth 1 -regextype awk -not -regex '.+-part[0-9]+$' | sort)

  while read -r disk_id || [[ -n $disk_id ]]; do
    cat >> "$c_disks_log" << LOG

## DEVICE: $disk_id ################################

$(udevadm info --query=property "$(readlink -f "$disk_id")")

LOG
  done < <(echo -n "$all_disk_ids")
}

function find_suitable_disks {
  # In some freaky cases, `/dev/disk/by-id` is not up to date, so we refresh. One case is after
  # starting a VirtualBox VM that is a full clone of a suspended VM with snapshots.
  #
  udevadm trigger

  local candidate_disk_ids
  local mounted_devices

  # Iterating via here-string generates an empty line when no devices are found. The options are
  # either using this strategy, or adding a conditional.
  #
  candidate_disk_ids=$(find /dev/disk/by-id -regextype awk -regex '.+/(ata|nvme|scsi|mmc)-.+' -not -regex '.+-part[0-9]+$' | sort)
  mounted_devices="$(df | awk 'BEGIN {getline} {print $1}' | xargs -n 1 lsblk -no pkname 2> /dev/null | sort -u || true)"

  while read -r disk_id || [[ -n $disk_id ]]; do
    local device_info
    local block_device_basename

    device_info="$(udevadm info --query=property "$(readlink -f "$disk_id")")"
    block_device_basename="$(basename "$(readlink -f "$disk_id")")"

    # It's unclear if it's possible to establish with certainty what is an internal disk:
    #
    # - there is no (obvious) spec around
    # - pretty much everything has `DEVTYPE=disk`, e.g. LUKS devices
    # - ID_TYPE is optional
    #
    # Therefore, it's probably best to rely on the id name, and just filter out optical devices.
    #
    if ! grep -q '^ID_TYPE=cd$' <<< "$device_info"; then
      if ! grep -q "^$block_device_basename\$" <<< "$mounted_devices"; then
        v_suitable_disks+=("$disk_id")
      fi
    fi
  done < <(echo -n "$candidate_disk_ids")

  if [[ ${#v_suitable_disks[@]} -eq 0 ]]; then
    local dialog_message='No suitable disks have been found!

If you'\''re running inside a VMWare virtual machine, you need to add set `disk.EnableUUID = "TRUE"` in the .vmx configuration file.

If you think this is a bug, please open an issue on https://github.com/64kramsystem/zfs-installer/issues, and attach the file `'"$c_disks_log"'`.
'
    whiptail --msgbox "$dialog_message" 30 100

    exit 1
  fi

  print_variables v_suitable_disks
}

# By using a FIFO, we avoid having to hide statements like `echo $v_passphrase | zpoool create ...`
# from the logs.
#
function create_passphrase_named_pipe {
  mkfifo "$c_passphrase_named_pipe"
}

function register_exit_hook {
  function _exit_hook {
    rm -f "$c_passphrase_named_pipe"

    set +x

    # Only the meaningful variable(s) are printed.
    # In order to print the password, the store strategy should be changed, as the pipes may be empty.
    #
    echo "
Currently set exports, for performing an unattended (as possible) installation with the same configuration:

export ZFS_USE_PPA=$v_use_ppa
export ZFS_SELECTED_DISKS=$(IFS=,; echo -n "${v_selected_disks[*]}")
export ZFS_VDEV_CONFIGS='$(declare -p v_vdev_configs | perl -pe 's/.*?\((.+)\)/\1/')'
export ZFS_BOOT_PARTITION_SIZE=$v_boot_partition_size
export ZFS_PASSPHRASE=$(printf %q "$v_passphrase")
export ZFS_DEBIAN_ROOT_PASSWORD=$(printf %q "$v_root_password")
export ZFS_RPOOL_NAME=$v_rpool_name
export ZFS_BPOOL_CREATE_OPTIONS=\"${v_bpool_create_options[*]}\"
export ZFS_RPOOL_CREATE_OPTIONS=\"${v_rpool_create_options[*]}\"
export ZFS_NO_INFO_MESSAGES=1
export ZFS_SWAP_SIZE=$v_swap_size
export ZFS_FREE_TAIL_SPACE=$v_free_tail_space"

    set -x
  }
  trap _exit_hook EXIT
}

function prepare_standard_repositories {
  # Make sure it's enabled. Ubuntu MATE has it, while the standard Ubuntu doesn't.
  # The program exits with success if the repository is already enabled.
  #
  checked_add_apt_repository universe
}

# Mint 20 has the CDROM repository enabled, but apt fails when updating due to it (or possibly due
# to it being incorrectly setup).
#
function prepare_standard_repositories_Linuxmint {
  perl -i -pe 's/^(deb cdrom)/# $1/' /etc/apt/sources.list

  # The universe repository may be already enabled, but it's more solid to ensure it.
  #
  prepare_standard_repositories
}

function prepare_standard_repositories_Debian {
  # Debian doesn't require universe (for dialog).
  :
}

function update_apt_index {
  apt update
}

function set_use_zfs_ppa {
  local zfs_package_version
  zfs_package_version=$(apt show zfsutils-linux 2> /dev/null | perl -ne 'print /^Version: (\d+\.\d+)/')

  # Test returns true if $zfs_package_version is blank.
  #
  if [[ ${ZFS_USE_PPA:-} == "1" ]] || dpkg --compare-versions "$zfs_package_version" lt 0.8; then
    v_use_ppa=1
  fi
}

function set_use_zfs_ppa_Debian {
  # Only update apt; in this case, ZFS packages are handled in a specific way.
  :
}

# Whiptail's lack of multiline editing is quite painful.
#
function install_host_base_packages {
  # `efibootmgr` needs installation on all the systems.
  # the other packages are each required by different distros, so for simplicity, they're all packed
  # together.
  #
  apt install -y efibootmgr dialog software-properties-common
}

function select_disks {
  if [[ -n ${ZFS_SELECTED_DISKS:-} ]]; then
    mapfile -d, -t v_selected_disks < <(echo -n "$ZFS_SELECTED_DISKS")
  else
    while true; do
      local menu_entries_option=()
      local block_device_basename

      if [[ ${#v_suitable_disks[@]} -eq 1 ]]; then
        local disk_selection_status=ON
      else
        local disk_selection_status=OFF
      fi

      # St00pid simple way of sorting by block device name. Relies on the tokens not including whitespace.

      for disk_id in "${v_suitable_disks[@]}"; do
        block_device_basename="$(basename "$(readlink -f "$disk_id")")"
        menu_entries_option+=("$disk_id ($block_device_basename) $disk_selection_status")
      done

      # shellcheck disable=2207 # cheating here, for simplicity (alternative: add tr and mapfile).
      menu_entries_option=($(printf $'%s\n' "${menu_entries_option[@]}" | sort -k 2))

      local dialog_message="Select the ZFS devices.

Devices with mounted partitions, cdroms, and removable devices are not displayed!
"
      mapfile -t v_selected_disks < <(whiptail --checklist --separate-output "$dialog_message" 30 100 $((${#menu_entries_option[@]} / 3)) "${menu_entries_option[@]}" 3>&1 1>&2 2>&3)

      if [[ ${#v_selected_disks[@]} -gt 0 ]]; then
        break
      fi
    done
  fi

  print_variables v_selected_disks
}

function select_vdev_configs {
  if [[ -n ${ZFS_VDEV_CONFIGS:-} ]]; then
    eval declare -gA v_vdev_configs=\("$ZFS_VDEV_CONFIGS"\)
  elif [[ ${#v_selected_disks[@]} -eq 1 ]]; then
    # Formally, this is striping.
    #
    v_vdev_configs[0]=
  else
    while true; do
      # Since the values (group disks) are represented by strings, there's no direct way of counting
      # all of them.
      # Remember that in $v_vdev_configs, keys are the indexes!
      #
      local all_vdev_disks_count
      all_vdev_disks_count=$(echo "${!v_vdev_configs[@]}" | perl -pe 's/[, ]/\n/g' | wc -l)

      if [[ $all_vdev_disks_count -eq ${#v_selected_disks[@]} ]]; then
        break
      fi

      local current_setup
      current_setup=$(compose_pool_create_vdev_options -)

      local dialog_message
      dialog_message="Choose the disk group type.

Disks for this group will be selected in the next dialog.

This and the next dialog will be repeated until all the groups are defined, so that it's possible to configure complex setups.

WARNING! The installer allows creating pools with different replication levels (eg. stripe + mirror), and it also doesn't verify their correctness.

Current pool creation setup: ${current_setup:-(none)}"

      local vdev_types_option=(
        ""       Striping  OFF
        mirror   Mirroring OFF
        raidz    RAIDZ1    OFF
        raidz2   RAIDZ2    OFF
        raidz3   RAIDZ3    OFF
      )

      local current_vdev_type
      current_vdev_type=$(whiptail --radiolist "$dialog_message" 30 100 $((${#vdev_types_option[@]} / 3)) "${vdev_types_option[@]}" 3>&1 1>&2 2>&3)

      local dialog_message="Choose the disks for the current disk group.

If any disks are remaining, they will be made available for another group."

      local current_vdev_disks_option=()

      for (( i = 0; i < ${#v_selected_disks[@]}; i++ )); do
        if ! echo "${!v_vdev_configs[@]}" | perl -pe 's/[, ]/\n/g' | grep "^$i$"; then
          local disk_basename
          disk_basename=$(basename "${v_selected_disks[i]}")
          current_vdev_disks_option+=("$i" "$disk_basename" OFF)
        fi
      done

      local current_vdev_indexes
      current_vdev_indexes=$(whiptail --checklist --separate-output "$dialog_message" 30 100 $((${#current_vdev_disks_option[@]} / 3)) "${current_vdev_disks_option[@]}" 3>&1 1>&2 2>&3)

      if [[ -n $current_vdev_indexes ]]; then
        current_vdev_indexes=${current_vdev_indexes//$'\n'/,}
        current_vdev_indexes=${current_vdev_indexes%,}
        v_vdev_configs[$current_vdev_indexes]=$current_vdev_type
      fi
    done
  fi
}

function ask_root_password_Debian {
  set +x
  if [[ -n ${ZFS_DEBIAN_ROOT_PASSWORD:-} ]]; then
    v_root_password="$ZFS_DEBIAN_ROOT_PASSWORD"
  else
    local password_invalid_message=
    local password_repeat=-

    while [[ $v_root_password != "$password_repeat" || -z $v_root_password ]]; do
      v_root_password=$(whiptail --passwordbox "${password_invalid_message}Please enter the root account password (can't be empty):" 30 100 3>&1 1>&2 2>&3)
      password_repeat=$(whiptail --passwordbox "Please repeat the password:" 30 100 3>&1 1>&2 2>&3)

      password_invalid_message="Passphrase empty, or not matching! "
    done
  fi
  set -x
}

function ask_encryption {
  set +x

  if [[ -v ZFS_PASSPHRASE ]]; then
    v_passphrase=$ZFS_PASSPHRASE
  else
    local passphrase_repeat=_
    local passphrase_invalid_message=

    while [[ $v_passphrase != "$passphrase_repeat" || ${#v_passphrase} -lt 8 ]]; do
      local dialog_message="${passphrase_invalid_message}Please enter the passphrase (8 chars min.):

Leave blank to keep encryption disabled.
"

      v_passphrase=$(whiptail --passwordbox "$dialog_message" 30 100 3>&1 1>&2 2>&3)

      if [[ -z $v_passphrase ]]; then
        break
      fi

      passphrase_repeat=$(whiptail --passwordbox "Please repeat the passphrase:" 30 100 3>&1 1>&2 2>&3)

      passphrase_invalid_message="Passphrase too short, or not matching! "
    done
  fi

  set -x
}

function ask_boot_partition_size {
  if [[ -n ${ZFS_BOOT_PARTITION_SIZE:-} ]]; then
    v_boot_partition_size=$ZFS_BOOT_PARTITION_SIZE
  else
   local boot_partition_size_invalid_message=

    while [[ ! $v_boot_partition_size =~ ^[0-9]+[MGmg]$ ]]; do
      v_boot_partition_size=$(whiptail --inputbox "${boot_partition_size_invalid_message}Enter the boot partition size.

Supported formats: '512M', '3G'" 30 100 ${c_default_boot_partition_size}M 3>&1 1>&2 2>&3)

      boot_partition_size_invalid_message="Invalid boot partition size! "
    done
  fi

  print_variables v_boot_partition_size
}

function ask_swap_size {
  if [[ -n ${ZFS_SWAP_SIZE:-} ]]; then
    v_swap_size=$ZFS_SWAP_SIZE
  else
   local swap_size_invalid_message=

    while [[ ! $v_swap_size =~ ^[0-9]+$ ]]; do
      v_swap_size=$(whiptail --inputbox "${swap_size_invalid_message}Enter the swap size in GiB (0 for no swap):" 30 100 2 3>&1 1>&2 2>&3)

      swap_size_invalid_message="Invalid swap size! "
    done
  fi

  print_variables v_swap_size
}

function ask_free_tail_space {
  if [[ -n ${ZFS_FREE_TAIL_SPACE:-} ]]; then
    v_free_tail_space=$ZFS_FREE_TAIL_SPACE
  else
    local tail_space_invalid_message=
    local tail_space_message="${tail_space_invalid_message}Enter the space in GiB to leave at the end of each disk (0 for none).

If the tail space is less than the space required for the temporary O/S installation, it will be reclaimed after it.

WATCH OUT! In rare cases, the reclamation may cause an error; if this happens, set the tail space to ${c_temporary_volume_size} gigabytes. It's still possible to reclaim the space after the ZFS installation is over.

For detailed informations, see the wiki page: https://github.com/64kramsystem/zfs-installer/wiki/Tail-space-reclamation-issue.
"

    while [[ ! $v_free_tail_space =~ ^[0-9]+$ ]]; do
      v_free_tail_space=$(whiptail --inputbox "$tail_space_message" 30 100 0 3>&1 1>&2 2>&3)

      tail_space_invalid_message="Invalid size! "
    done
  fi

  print_variables v_free_tail_space
}

function ask_rpool_name {
  if [[ -n ${ZFS_RPOOL_NAME:-} ]]; then
    v_rpool_name=$ZFS_RPOOL_NAME
  else
    local rpool_name_invalid_message=

    while [[ ! $v_rpool_name =~ ^[a-z][a-zA-Z_:.-]+$ ]]; do
      v_rpool_name=$(whiptail --inputbox "${rpool_name_invalid_message}Insert the name for the root pool" 30 100 rpool 3>&1 1>&2 2>&3)

      rpool_name_invalid_message="Invalid pool name! "
    done
  fi

  print_variables v_rpool_name
}

function ask_pool_create_options {
  local bpool_create_options_message='Insert the create options for the boot pool

The mount-related options are automatically added, and must not be specified.'

  local raw_bpool_create_options=${ZFS_BPOOL_CREATE_OPTIONS:-$(whiptail --inputbox "$bpool_create_options_message" 30 100 -- "${c_default_bpool_create_options[*]}" 3>&1 1>&2 2>&3)}

  mapfile -d' ' -t v_bpool_create_options < <(echo -n "$raw_bpool_create_options")

  local rpool_create_options_message='Insert the create options for the root pool

The encryption/mount-related options are automatically added, and must not be specified.'

  local raw_rpool_create_options=${ZFS_RPOOL_CREATE_OPTIONS:-$(whiptail --inputbox "$rpool_create_options_message" 30 100 -- "${c_default_rpool_create_options[*]}" 3>&1 1>&2 2>&3)}

  mapfile -d' ' -t v_rpool_create_options < <(echo -n "$raw_rpool_create_options")

  print_variables v_bpool_create_options v_rpool_create_options
}

function ask_dataset_create_options {
  if [[ -n ${ZFS_DATASET_CREATE_OPTIONS:-} ]]; then
    v_dataset_create_options=$ZFS_DATASET_CREATE_OPTIONS
  else
    while true; do
      local tempfile
      tempfile=$(mktemp)

      echo "$c_dataset_options_help$c_default_dataset_create_options" > "$tempfile"

      local user_value
      user_value=$(dialog --editbox "$tempfile" 30 120 3>&1 1>&2 2>&3)

      if [[ -n $user_value && $user_value != *\"* ]]; then
        v_dataset_create_options=$(echo "$user_value" | perl -ne 'print unless /^\s*#/')
        break
      fi
    done
  fi

  print_variables v_dataset_create_options
}

function install_host_zfs_packages {
  if [[ $v_use_ppa == "1" ]]; then
    if [[ ${ZFS_SKIP_LIVE_ZFS_MODULE_INSTALL:-} != "1" ]]; then
      checked_add_apt_repository "$c_ppa"
      apt update

      # Libelf-dev allows `CONFIG_STACK_VALIDATION` to be set - it's optional, but good to have.
      # Module compilation log: `/var/lib/dkms/zfs/**/*/make.log` (adjust according to version).
      #
      echo "zfs-dkms zfs-dkms/note-incompatible-licenses note true" | debconf-set-selections
      apt install --yes libelf-dev zfs-dkms

      systemctl stop zfs-zed
      modprobe -r zfs
      modprobe zfs
      systemctl start zfs-zed
    fi
  fi

  # Required only by some distros.
  #
  apt install --yes zfsutils-linux

  zfs --version > "$c_zfs_module_version_log" 2>&1
}

function install_host_zfs_packages_Debian {
  if [[ ${ZFS_SKIP_LIVE_ZFS_MODULE_INSTALL:-} != "1" ]]; then
    echo "zfs-dkms zfs-dkms/note-incompatible-licenses note true" | debconf-set-selections

    echo "deb http://deb.debian.org/debian buster contrib" >> /etc/apt/sources.list
    echo "deb http://deb.debian.org/debian buster-backports main contrib" >> /etc/apt/sources.list
    apt update

    apt install --yes -t buster-backports zfs-dkms

    modprobe zfs
  fi

  zfs --version > "$c_zfs_module_version_log" 2>&1
}

function install_host_zfs_packages_UbuntuServer {
  if [[ $v_use_ppa != "1" ]]; then
    apt install --yes zfsutils-linux efibootmgr

    zfs --version > "$c_zfs_module_version_log" 2>&1
  elif [[ ${ZFS_SKIP_LIVE_ZFS_MODULE_INSTALL:-} != "1" ]]; then
    # This is not needed on UBS 20.04, which has the modules built-in - incidentally, if attempted,
    # it will cause /dev/disk/by-id changes not to be recognized.
    #
    # On Ubuntu Server, `/lib/modules` is a SquashFS mount, which is read-only.
    #
    cp -R /lib/modules /tmp/
    systemctl stop 'systemd-udevd*'
    umount /lib/modules
    rm -r /lib/modules
    ln -s /tmp/modules /lib
    systemctl start --all 'systemd-udevd*'

    # Additionally, the linux packages for the running kernel are not installed, at least when
    # the standard installation is performed. Didn't test on the HWE option; if it's not required,
    # this will be a no-op.
    #
    apt update
    apt install --yes "linux-headers-$(uname -r)"

    install_host_zfs_packages
  else
    apt install --yes efibootmgr
  fi
}

function setup_partitions {
  local required_tail_space=$((v_free_tail_space > c_temporary_volume_size ? v_free_tail_space : c_temporary_volume_size))

  for selected_disk in "${v_selected_disks[@]}"; do
    # wipefs doesn't fully wipe ZFS labels.
    #
    find "$(dirname "$selected_disk")" -name "$(basename "$selected_disk")-part*" -exec bash -c '
      zpool labelclear -f "$1" 2> /dev/null || true
    ' _ {} \;

    # More thorough than `sgdisk --zap-all`.
    #
    wipefs --all "$selected_disk"

    sgdisk -n1:1M:+"${c_efi_system_partition_size}M" -t1:EF00 "$selected_disk" # EFI boot
    sgdisk -n2:0:+"$v_boot_partition_size"           -t2:BF01 "$selected_disk" # Boot pool
    sgdisk -n3:0:"-${required_tail_space}G"          -t3:BF01 "$selected_disk" # Root pool
    sgdisk -n4:0:0                                   -t4:8300 "$selected_disk" # Temporary partition
  done

  # The partition symlinks are not immediately created, so we wait.
  #
  # There is still a hard to reproduce issue where `zpool create rpool` fails with:
  #
  #   cannot resolve path '/dev/disk/by-id/<disk_id>-part2'
  #
  # It's a race condition (waiting more solves the problem), but it's not clear which exact event
  # to wait on.
  # There's no relation to the missing symlinks - the issue also happened for partitions that
  # didn't need a `sleep`.
  #
  # Using `partprobe` doesn't solve the problem.
  #
  # Replacing the `-L` test with `-e` is a potential solution, but couldn't check on the
  # destination files, due to the nondeterministic nature of the problem.
  #
  # Current attempt: `udevadm`, which should be the cleanest approach.
  #
  udevadm settle --timeout "$c_udevadm_settle_timeout" || true

  # for disk in "${v_selected_disks[@]}"; do
  #   part_indexes=(1 2 3)
  #
  #   for part_i in "${part_indexes[@]}"; do
  #     while [[ ! -L "${disk}-part${part_i}" ]]; do sleep 0.25; done
  #   done
  # done

  for selected_disk in "${v_selected_disks[@]}"; do
    mkfs.fat -F 32 -n EFI "${selected_disk}-part1"
  done

  v_temp_volume_device=$(readlink -f "${v_selected_disks[0]}-part4")
}

function install_operating_system {
  local dialog_message='The Ubuntu GUI installer will now be launched.

Proceed with the configuration as usual, then, at the partitioning stage:

- check `Something Else` -> `Continue`
- select `'"$v_temp_volume_device"'` -> `Change`
  - set `Use as:` to `Ext4`
  - check `Format the partition:`
  - set `Mount point` to `/` -> `OK` -> `Continue`
- `Install Now` -> `Continue`
- at the end, choose `Continue Testing`
'

  if [[ -z ${ZFS_NO_INFO_MESSAGES:-} ]]; then
    whiptail --msgbox "$dialog_message" 30 100
  fi

  # The display is restricted only to the owner (`user`), so we need to allow any user to access
  # it.
  #
  sudo -u "$SUDO_USER" env DISPLAY=:0 xhost +

  #DISPLAY=:0 ubiquity --no-bootloader
  DISPLAY=:0 sudo -u ubuntu ubuntu-desktop-bootstrap

  swapoff -a

  # /target is not always unmounted; the reason is unclear. A possibility is that if there is an
  # active swapfile under `/target` and ubiquity fails to unmount /target, it fails silently,
  # leaving `/target` mounted.
  # For this reason, if it's not mounted, we remount it.
  #
  # Note that we assume that the user created only one partition on the temp volume, as expected.
  #
  if ! mountpoint -q "$c_installed_os_mount_dir"; then
    mount "$v_temp_volume_device" "$c_installed_os_mount_dir"
  fi

  rm -f "$c_installed_os_mount_dir/swapfile"
}

function install_operating_system_Debian {
  # The temporary volume size displayed is an approximation of the format used by the installer,
  # but it's acceptable - the complexity required is not worth (eg. converting hypothetical units,
  # etc.).
  #
  local dialog_message='The Debian GUI installer will now be launched.

Proceed with the configuration as usual, then, at the partitioning stage:

- check `Manual partitioning` -> `Next`
- click on `'"${v_temp_volume_device}"'` in the filesystems panel -> `Edit`
  - click on `Format`
  - set `Mount Point` to `/` -> `OK`
- `Next`
- follow through the installation (ignore the EFI partition warning)
- at the end, uncheck `Restart now`, and click `Done`
'

  if [[ -z ${ZFS_NO_INFO_MESSAGES:-} ]]; then
    whiptail --msgbox "$dialog_message" 30 100
  fi

  # See install_operating_system().
  #
  sudo -u "$SUDO_USER" env DISPLAY=:0 xhost +

  DISPLAY=:0 calamares

  mkdir -p "$c_installed_os_mount_dir"

  # Note how in Debian, for reasons currenly unclear, the mount fails if the partition is passed;
  # it requires the device to be passed.
  #
  mount "${v_temp_volume_device}" "$c_installed_os_mount_dir"

  # We don't use chroot()_execute here, as it works on $c_zfs_mount_dir (which is synced on a
  # later stage).
  #
  set +x
  chroot "$c_installed_os_mount_dir" bash -c "echo root:$(printf "%q" "$v_root_password") | chpasswd"
  set -x

  # The installer doesn't set the network interfaces, so, for convenience, we do it.
  #
  for interface in $(ip addr show | perl -lne '/^\d+: (?!lo:)(\w+)/ && print $1' ); do
    cat > "$c_installed_os_mount_dir/etc/network/interfaces.d/$interface" <<CONF
  auto $interface
  iface $interface inet dhcp
CONF
  done
}

function install_operating_system_UbuntuServer {
  # O/S Installation
  #
  # Subiquity is designed to prevent the user from opening a terminal, which is (to say the least)
  # incongruent with the audience.

  local selected_disk_subiquity_name
  selected_disk_subiquity_name=$(lsblk -o model,serial -d -n "${v_selected_disks[0]}" | awk '{ print $1 "_" $2 }')

  local dialog_message='You'\''ll now need to run the Ubuntu Server installer (Subiquity).

Switch back to the original terminal (Ctrl+Alt+F1), then proceed with the configuration as usual.

When the update option is presented, choose to update Subiquity to the latest version.

At the partitioning stage:

- select `Custom storage layout` -> `Done`
- select `'"$selected_disk_subiquity_name"'`/`partition 4` -> `Edit`
  - set `Format:` to `ext4` (mountpoint will be automatically selected)
  - click `Save`
- click `Done` -> `Continue` (ignore warning)
- follow through the installation, until the end (after the updates are applied)
- switch back to this terminal (Ctrl+Alt+F2), and continue (tap Enter)

Do not continue in this terminal (tap Enter) now!

You can switch anytime to this terminal, and back, in order to read the instructions.
'

  whiptail --msgbox "$dialog_message" 30 100

  swapoff -a

  # See note in install_operating_system(). It's not clear whether this is required on Ubuntu
  # Server, but it's better not to take risks.
  #
  if ! mountpoint -q "$c_installed_os_mount_dir"; then
    # There must be a conspiracy 🙄 `/target` used to be created before [20.04.2].
    #
    if [[ ! -d $c_installed_os_mount_dir ]]; then
      mkdir "$c_installed_os_mount_dir"
    fi

    mount "${v_temp_volume_device}p2" "$c_installed_os_mount_dir"
  fi

  rm -f "$c_installed_os_mount_dir"/swap.img
}

function custom_install_operating_system {
  sudo "$ZFS_OS_INSTALLATION_SCRIPT"
}

function create_pools_and_datasets {
  # POOL OPTIONS #######################

  local encryption_options=()

  set +x
  if [[ -n $v_passphrase ]]; then
    encryption_options=(-O "encryption=aes-256-gcm" -O "keylocation=prompt" -O "keyformat=passphrase")
  fi
  set -x

  # ROOT POOL CREATION #################

  # In this script, the boot pool doesn't have a root dataset; since its creation will mount /boot,
  # it needs to be done after the root pool root dataset is created.

  set +x
  echo -n "$v_passphrase" > "$c_passphrase_named_pipe" &
  set -x

  mapfile -d' ' -t rpool_create_vdev_options < <(compose_pool_create_vdev_options rpool)

  # `-R` creates an "Alternate Root Point", which is lost on unmount; it's just a convenience for a temporary mountpoint;
  # `-f` force overwrite partitions is existing - in some cases, even after wipefs, a filesystem is mistakenly recognized;
  #      it also forces vdevs with different replication levels;
  # `-O` set filesystem properties on a pool (pools and filesystems are distincted entities, however, a pool includes an FS by default).
  #
  # Stdin is ignored if the encryption is not set (and set via prompt).
  #
  zpool create \
    "${encryption_options[@]}" \
    "${v_rpool_create_options[@]}" \
    -O mountpoint=/ -O canmount=off -R "$c_zfs_mount_dir" -f \
    "$v_rpool_name" "${rpool_create_vdev_options[@]}" \
    < "$c_passphrase_named_pipe"

  # RPOOL DATASETS CREATION ############

  local interpolated_dataset_create_options
  interpolated_dataset_create_options=$(eval echo \""$v_dataset_create_options"\")

  echo "Interpolated dataset create options:"
  echo "$interpolated_dataset_create_options"
  echo

  while read -r dataset_metadata_line || [[ -n $dataset_metadata_line ]]; do
    if [[ $dataset_metadata_line =~ [^[:space:]] ]]; then
      local dataset_metadata_entries
      # shellcheck disable=2206 # cheating for simplicity (alternative: sed and mapfile).
      dataset_metadata_entries=($dataset_metadata_line)

      local dataset=$v_rpool_name/${dataset_metadata_entries[0]}
      local options=("${dataset_metadata_entries[@]:1}")

      # Prepend the `-o`.
      #
      # shellcheck disable=2068 # cheating for simplicity (otherwise each `-o $option` will be a single
      # string).
      zfs create ${options[@]/#/-o } "$dataset"
    fi
  done < <(echo "$interpolated_dataset_create_options")

  # Here, the original procedure sets the permissions for /root (700) and /tmp (1777), however, in this
  # script we don't need to do it, since we sync the O/S installer result, which is already configured.
  # In case of changes, don't forget that the destination layout may be empty, at this point, due to
  # the user's ZFS filesystems configuration!

  # BOOT POOL/DATASETS CREATION ########

  mapfile -d' ' -t bpool_create_vdev_options < <(compose_pool_create_vdev_options bpool)

  # Creating the datasets is not necessary, however, it avoids the annoying GRUB warning when updating
  # (`cannot open 'bpool/BOOT/ROOT': dataset does not exist`).

  zpool create \
    -o cachefile=/etc/zfs/zpool.cache \
    "${v_bpool_create_options[@]}" \
    -O mountpoint=/boot -O canmount=off -R "$c_zfs_mount_dir" -f \
    "$c_bpool_name" "${bpool_create_vdev_options[@]}"

  zfs create -o canmount=off "$c_bpool_name/BOOT"
  zfs create -o mountpoint=/boot "$c_bpool_name/BOOT/ROOT"
}

function create_swap_volume {
  if [[ $v_swap_size -gt 0 ]]; then
    zfs create \
      -V "${v_swap_size}G" -b "$(getconf PAGESIZE)" \
      -o compression=zle -o logbias=throughput -o sync=always -o primarycache=metadata -o secondarycache=none -o com.sun:auto-snapshot=false \
      "$v_rpool_name/swap"

    mkswap -f "/dev/zvol/$v_rpool_name/swap"
  fi
}

function copy_zpool_cache {
  mkdir -p "$c_zfs_mount_dir/etc/zfs"
  cp /etc/zfs/zpool.cache "$c_zfs_mount_dir/etc/zfs/"
}

function sync_os_temp_installation_dir_to_rpool {
  # On Ubuntu Server, `/boot/efi` and `/cdrom` (!!!) are mounted, but they're not needed.
  #
  local mount_dir_submounts
  mount_dir_submounts=$(mount | MOUNT_DIR="${c_installed_os_mount_dir%/}" perl -lane 'print $F[2] if $F[2] =~ /$ENV{MOUNT_DIR}\//')

  for mount_dir in $mount_dir_submounts; do
    umount "$mount_dir"
  done

  # Extended attributes are not used on a standard Ubuntu installation, however, this needs to be generic.
  # There isn't an exact way to filter out filenames in the rsync output, so we just use a good enough heuristic.
  # ❤️ Perl ❤️
  #
  # `/run` is not needed (with an exception), and in Ubuntu Server it's actually a nuisance, since
  # some files vanish while syncing. Debian is well-behaved, and `/run` is empty.
  #
  rsync -avX --exclude=/run --info=progress2 --no-inc-recursive --human-readable "$c_installed_os_mount_dir/" "$c_zfs_mount_dir" |
    perl -lane 'BEGIN { $/ = "\r"; $|++ } $F[1] =~ /(\d+)%$/ && print $1' |
    whiptail --gauge "Syncing the installed O/S to the root pool FS..." 30 100 0

  # Ubiquity used to leave `/target/run`, which included the file symlinked by `/etc/resolv.conf`. At
  # some point, it started cleaning it after installation, leaving the symlink broken, which caused
  # the jail preparation to fail. For this reason, we now create the dir/file manually.
  # As of Jun/2021, it's not clear if there is any O/S leaving the dir/file, but for simplicity, we
  # always create them if not existing.
  #
  mkdir -p "$c_installed_os_mount_dir/run/systemd/resolve"
  touch "$c_installed_os_mount_dir/run/systemd/resolve/stub-resolv.conf"

  mkdir "$c_zfs_mount_dir/run"
  rsync -av --relative "$c_installed_os_mount_dir/run/./systemd/resolve" "$c_zfs_mount_dir/run"

  umount "$c_installed_os_mount_dir"
}

function remove_temp_partition_and_expand_rpool {
  if (( v_free_tail_space < c_temporary_volume_size )); then
    if [[ $v_free_tail_space -eq 0 ]]; then
      local resize_reference=100%
    else
      local resize_reference=-${v_free_tail_space}G
    fi

    zpool export -a

    for selected_disk in "${v_selected_disks[@]}"; do
      parted -s "$selected_disk" rm 4
      parted -s "$selected_disk" unit s resizepart 3 -- "$resize_reference"
    done

    set +x
    echo -n "$v_passphrase" > "$c_passphrase_named_pipe" &
    set -x

    # For unencrypted pools, `-l` doesn't interfere.
    #
    zpool import -l -R "$c_zfs_mount_dir" "$v_rpool_name" < "$c_passphrase_named_pipe"
    zpool import -l -R "$c_zfs_mount_dir" "$c_bpool_name"

    for selected_disk in "${v_selected_disks[@]}"; do
      zpool online -e "$v_rpool_name" "$selected_disk-part3"
    done
  else
    for selected_disk in "${v_selected_disks[@]}"; do
      wipefs --all "$selected_disk-part4"
    done
  fi
}

function prepare_jail {
  for virtual_fs_dir in proc sys dev; do
    mount --rbind "/$virtual_fs_dir" "$c_zfs_mount_dir/$virtual_fs_dir"
  done

  chroot_execute "echo 'nameserver $c_dns' >> /etc/resolv.conf"
}

# Same principle as install_host_base_packages().
#
function install_jail_base_packages {
  chroot_execute "apt install --yes rsync grub-efi-amd64-signed shim-signed software-properties-common"
}

# See install_host_zfs_packages() for some comments.
#
function install_jail_zfs_packages {
  if [[ $v_use_ppa == "1" ]]; then
    checked_add_apt_repository "$c_ppa" --chroot

    chroot_execute "apt update"

    chroot_execute 'echo "zfs-dkms zfs-dkms/note-incompatible-licenses note true" | debconf-set-selections'

    chroot_execute "apt install --yes libelf-dev zfs-initramfs zfs-dkms"
  else
    # Oddly, on a 20.04 Ubuntu Desktop live session, the zfs tools are installed, but they are not
    # associated to a package:
    #
    # - `dpkg -S $(which zpool)` -> nothing
    # - `aptitude search ~izfs | awk '{print $2}' | xargs echo` -> libzfs2linux zfs-initramfs zfs-zed zfsutils-linux
    #
    # The packages are not installed by default, so we install them.
    #
    chroot_execute "apt install --yes zfs-initramfs zfs-zed zfsutils-linux"
  fi
}

function install_jail_zfs_packages_Debian {
  chroot_execute 'echo "deb http://deb.debian.org/debian buster main contrib"     >> /etc/apt/sources.list'
  chroot_execute 'echo "deb-src http://deb.debian.org/debian buster main contrib" >> /etc/apt/sources.list'

  chroot_execute 'echo "deb http://deb.debian.org/debian buster-backports main contrib"     >> /etc/apt/sources.list.d/buster-backports.list'
  chroot_execute 'echo "deb-src http://deb.debian.org/debian buster-backports main contrib" >> /etc/apt/sources.list.d/buster-backports.list'

  chroot_execute 'cat > /etc/apt/preferences.d/90_zfs <<APT
Package: libnvpair1linux libuutil1linux libzfs2linux libzpool2linux zfs-dkms zfs-initramfs zfs-test zfsutils-linux zfsutils-linux-dev zfs-zed
Pin: release n=buster-backports
Pin-Priority: 990
APT'

  chroot_execute "apt update"

  chroot_execute 'echo "zfs-dkms zfs-dkms/note-incompatible-licenses note true" | debconf-set-selections'
  chroot_execute "apt install --yes zfs-initramfs zfs-dkms"
}

function install_jail_zfs_packages_UbuntuServer {
  if [[ $v_use_ppa != "1" ]]; then
    chroot_execute "apt install --yes zfsutils-linux zfs-initramfs"
  else
    install_jail_zfs_packages
  fi
}

function prepare_fstab {
  chroot_execute "true > /etc/fstab"

  for ((i = 0; i < ${#v_selected_disks[@]}; i++)); do
    if (( i == 0 )); then
      local mountpoint=/boot/efi
    else
      local mountpoint=/boot/efi$((i + 1))
    fi

    # Wait for /boot to be mounted before mounting the EFI partitions; we use the services as dependency
    # rather than a mount (`requires-mounts-for`) because the `/boot` path may exist but still not mounted.
    # It's important to give a long enough timeout time; on relatively slow machines (e.g. virtual machines),
    # a timeout of 1 will fail.
    #
    chroot_execute "echo /dev/disk/by-uuid/$(blkid -s UUID -o value "${v_selected_disks[i]}"-part1) $mountpoint vfat nofail,x-systemd.requires=zfs-mount.service,x-systemd.device-timeout=10 0 0 >> /etc/fstab"
  done

  if (( v_swap_size > 0 )); then
    chroot_execute "echo /dev/zvol/$v_rpool_name/swap none swap discard 0 0 >> /etc/fstab"
  fi
}

function prepare_efi_partition {
  chroot_execute "mkdir -p /boot/efi"
  chroot_execute "mount /boot/efi"

  chroot_execute "grub-install"
}

function configure_and_update_grub {
  chroot_execute "perl -i -pe 's/GRUB_CMDLINE_LINUX_DEFAULT=\"\K/init_on_alloc=0 /'        /etc/default/grub"

  # Silence warning during the grub probe (source: https://git.io/JenXF).
  #
  chroot_execute "echo 'GRUB_DISABLE_OS_PROBER=true'                                    >> /etc/default/grub"

  # Simplify debugging, but most importantly, disable the boot graphical interface: text mode is
  # required for the passphrase to be asked, otherwise, the boot stops with a confusing error
  # "filesystem [...] can't be mounted: Permission Denied".
  #
  chroot_execute "perl -i -pe 's/(GRUB_TIMEOUT_STYLE=hidden)/#\$1/'                        /etc/default/grub"
  chroot_execute "perl -i -pe 's/^(GRUB_HIDDEN_.*)/#\$1/'                                  /etc/default/grub"
  chroot_execute "perl -i -pe 's/GRUB_TIMEOUT=\K0/5/'                                      /etc/default/grub"
  chroot_execute "perl -i -pe 's/GRUB_CMDLINE_LINUX_DEFAULT=.*\Kquiet//'                   /etc/default/grub"
  chroot_execute "perl -i -pe 's/GRUB_CMDLINE_LINUX_DEFAULT=.*\Ksplash//'                  /etc/default/grub"
  chroot_execute "perl -i -pe 's/#(GRUB_TERMINAL=console)/\$1/'                            /etc/default/grub"
  chroot_execute 'echo "GRUB_RECORDFAIL_TIMEOUT=5"                                      >> /etc/default/grub'

  # A gist on GitHub (https://git.io/JenXF) manipulates `/etc/grub.d/10_linux` in order to allow
  # GRUB support encrypted ZFS partitions. This hasn't been a requirement in all the tests
  # performed on 18.04, but it's better to keep this reference just in case.

  chroot_execute "update-grub"
}

function configure_and_update_grub_Debian {
  zfs_root_fs=$(chroot_execute 'zfs list /     | awk "NR==2 {print \$1}"')
  zfs_boot_fs=$(chroot_execute 'zfs list /boot | awk "NR==2 {print \$1}"')

  chroot_execute "perl -i -pe 's|GRUB_CMDLINE_LINUX=\"\K|root=ZFS=$zfs_root_fs bootfs=$zfs_boot_fs |' /etc/default/grub"

  configure_and_update_grub
}

function sync_efi_partitions {
  for ((i = 1; i < ${#v_selected_disks[@]}; i++)); do
    local synced_efi_partition_path="/boot/efi$((i + 1))"

    chroot_execute "mkdir -p $synced_efi_partition_path"
    chroot_execute "mount $synced_efi_partition_path"

    chroot_execute "rsync --archive --delete --verbose /boot/efi/ $synced_efi_partition_path"

    efibootmgr --create --disk "${v_selected_disks[i]}" --label "ubuntu-$((i + 1))" --loader '\EFI\ubuntu\grubx64.efi'

    chroot_execute "umount $synced_efi_partition_path"
  done

  chroot_execute "umount /boot/efi"
}

# This step is important in cases where the keyboard layout is not the standard one.
# See issue https://github.com/64kramsystem/zfs-installer/issues/110.
#
function update_initramfs {
  chroot_execute "update-initramfs -u"
}

function fix_filesystem_mount_ordering {
  chroot_execute "mkdir /etc/zfs/zfs-list.cache"
  chroot_execute "touch /etc/zfs/zfs-list.cache/$c_bpool_name /etc/zfs/zfs-list.cache/$v_rpool_name"

  # On Debian, this file may exist already.
  #
  chroot_execute "if [[ ! -f /etc/zfs/zed.d/history_event-zfs-list-cacher.sh ]]; then ln -s /usr/lib/zfs-linux/zed.d/history_event-zfs-list-cacher.sh /etc/zfs/zed.d/; fi"

  # Assumed to be present by the zedlet above on Debian, but missing.
  # Filed issue: https://github.com/zfsonlinux/zfs/issues/9945.
  #
  chroot_execute "mkdir /run/lock"

  # It's not clear (based on the help) why it's explicitly run in foreground (`-F`), but backgrounded.
  #
  chroot_execute "zed -F &"

  # We could pool the events via `zpool events -v`, but it's much simpler to just check on the file.
  #
  local success=

  if [[ ! -s $c_zfs_mount_dir/etc/zfs/zfs-list.cache/$c_bpool_name || ! -s $c_zfs_mount_dir/etc/zfs/zfs-list.cache/$v_rpool_name ]]; then
    local zfs_root_fs zfs_boot_fs

    zfs_root_fs=$(chroot_execute 'zfs list /     | awk "NR==2 {print \$1}"')
    zfs_boot_fs=$(chroot_execute 'zfs list /boot | awk "NR==2 {print \$1}"')

    # For the rpool only, it takes around half second on a test VM.
    #
    chroot_execute "zfs set canmount=on $zfs_boot_fs"
    chroot_execute "zfs set canmount=on $zfs_root_fs"

    SECONDS=0

    while [[ $SECONDS -lt 5 ]]; do
      if [[ ! -s $c_zfs_mount_dir/etc/zfs/zfs-list.cache/$c_bpool_name || ! -s $c_zfs_mount_dir/etc/zfs/zfs-list.cache/$v_rpool_name ]]; then
        success=1
        break
      else
        sleep 0.25
      fi
    done
  else
    success=1
  fi

  chroot_execute "pkill zed"

  if [[ $success -ne 1 ]]; then
    echo "Error: The ZFS cache hasn't been updated by ZED!"
    exit 1
  fi

  chroot_execute "sed -Ei 's|$c_zfs_mount_dir/?|/|' /etc/zfs/zfs-list.cache/*"
}

function configure_remaining_settings {
  # The swap volume, if specified, is set in the prepare_fstab() step.

  chroot_execute "echo RESUME=none > /etc/initramfs-tools/conf.d/resume"
}

function prepare_for_system_exit {
  for virtual_fs_dir in dev sys proc; do
    umount --recursive --force --lazy "$c_zfs_mount_dir/$virtual_fs_dir"
  done

  # In one case, a second unmount was required. In this contenxt, bind mounts are not safe, so,
  # expecting unclean behaviors, we perform a second unmount if the mounts are still present.
  #
  local max_unmount_wait=5
  echo -n "Waiting for virtual filesystems to unmount "

  SECONDS=0

  for virtual_fs_dir in dev sys proc; do
    while mountpoint -q "$c_zfs_mount_dir/$virtual_fs_dir" && [[ $SECONDS -lt $max_unmount_wait ]]; do
      sleep 0.5
      echo -n .
    done
  done

  echo

  for virtual_fs_dir in dev sys proc; do
    if mountpoint -q "$c_zfs_mount_dir/$virtual_fs_dir"; then
      echo "Re-issuing umount for $c_zfs_mount_dir/$virtual_fs_dir"
      umount --recursive --force --lazy "$c_zfs_mount_dir/$virtual_fs_dir"
    fi
  done

  zpool export -a
}

function display_exit_banner {
  local dialog_message="The system has been successfully prepared and installed.

You now need to perform a hard reset, then enjoy your ZFS system :-)"

  if [[ -z ${ZFS_NO_INFO_MESSAGES:-} ]]; then
    whiptail --msgbox "$dialog_message" 30 100
  fi
}

# MAIN #########################################################################

if [[ $# -ne 0 ]]; then
  display_help_and_exit
fi

invoke "activate_debug"
invoke "set_distribution_data"
invoke "store_os_distro_information"
invoke "store_running_processes"
invoke "check_prerequisites"
invoke "display_intro_banner"
invoke "check_system_memory"
invoke "save_disks_log"
invoke "find_suitable_disks"
invoke "register_exit_hook"
invoke "create_passphrase_named_pipe"
invoke "prepare_standard_repositories"
invoke "update_apt_index"
invoke "set_use_zfs_ppa"
invoke "install_host_base_packages"

invoke "select_disks"
invoke "select_vdev_configs"
invoke "ask_root_password" --optional
invoke "ask_encryption"
invoke "ask_boot_partition_size"
invoke "ask_swap_size"
invoke "ask_free_tail_space"
invoke "ask_rpool_name"
invoke "ask_pool_create_options"
invoke "ask_dataset_create_options"

invoke "install_host_zfs_packages"
invoke "setup_partitions"

if [[ -z ${ZFS_OS_INSTALLATION_SCRIPT:-} ]]; then
  # Includes the O/S extra configuration, if necessary (network, root pwd, etc.)
  invoke "install_operating_system"

  invoke "create_pools_and_datasets"
  invoke "create_swap_volume"
  invoke "copy_zpool_cache"
  invoke "sync_os_temp_installation_dir_to_rpool"
  invoke "remove_temp_partition_and_expand_rpool"
else
  invoke "create_pools_and_datasets"
  invoke "create_swap_volume"
  invoke "copy_zpool_cache"
  invoke "remove_temp_partition_and_expand_rpool"

  invoke "custom_install_operating_system"
fi

invoke "prepare_jail"
invoke "install_jail_base_packages"
invoke "install_jail_zfs_packages"
invoke "prepare_fstab"
invoke "prepare_efi_partition"
invoke "configure_and_update_grub"
invoke "sync_efi_partitions"
invoke "update_initramfs"
invoke "fix_filesystem_mount_ordering"
invoke "configure_remaining_settings"

invoke "prepare_for_system_exit"
invoke "display_exit_banner"
