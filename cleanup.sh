#!/usr/bin/env bash
# Clean-up script for Ubuntu 22.04 & AlmaLinux 8/9 (VPS optimized)
# Actions:
#  - Minimize locales (ONLY en)
#  - Trim systemd-journald logs (1MB, 1 day) & cut /var/log
#  - Purge common dev tools
#  - Clean system/user caches
#  - Disable & remove swap
#  - Remove ALL Snap packages + snapd (Ubuntu only)
#  - (VPS) Remove cloud-init completely
#  - OPTIONAL: system update & upgrade
#  - Purge old kernels safely (keep only current by default; optional 1 backup)
# Version: 2025-12-13

set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

# ================================
# Distro Detection
# ================================
DISTRO=""
DISTRO_VERSION=""
PKG_MGR=""

detect_distro() {
  if [ -f /etc/os-release ]; then
    . /etc/os-release
    DISTRO="${ID,,}"
    DISTRO_VERSION="${VERSION_ID}"
  elif [ -f /etc/redhat-release ]; then
    if grep -qi "almalinux" /etc/redhat-release; then
      DISTRO="almalinux"
    elif grep -qi "centos" /etc/redhat-release; then
      DISTRO="centos"
    elif grep -qi "rocky" /etc/redhat-release; then
      DISTRO="rocky"
    else
      DISTRO="rhel"
    fi
    DISTRO_VERSION=$(grep -oE '[0-9]+\.[0-9]+' /etc/redhat-release | head -1)
  else
    err "Không thể xác định distro."
    exit 1
  fi

  case "$DISTRO" in
    ubuntu|debian)
      PKG_MGR="apt"
      ;;
    almalinux|centos|rocky|rhel|fedora)
      if command -v dnf &>/dev/null; then
        PKG_MGR="dnf"
      else
        PKG_MGR="yum"
      fi
      ;;
    *)
      err "Distro không được hỗ trợ:  $DISTRO"
      exit 1
      ;;
  esac

  info "Phát hiện:  $DISTRO $DISTRO_VERSION (Package manager: $PKG_MGR)"
}

# ================================
# Config
# ================================
KEEP_LOCALES=("en" "en_US")
REMOVE_CLOUD_INIT=true
DO_SYSTEM_UPDATE=true
KEEP_ONE_BACKUP=false

# Dev tools - Ubuntu/Debian
DEV_PKGS_APT=(
  build-essential gcc g++ make cmake ninja-build
  git git-lfs subversion mercurial
  pkg-config autoconf automake libtool
  clang llvm lldb lld
  gdb strace ltrace valgrind
  dkms manpages-dev man-db
  python3-dev python3-venv
  nodejs npm yarn
  golang-go cargo rustc ruby-dev gem
)

# Dev tools - RHEL/AlmaLinux
DEV_PKGS_DNF=(
  gcc gcc-c++ make cmake ninja-build
  git git-lfs subversion mercurial
  pkgconfig autoconf automake libtool
  clang llvm lldb lld
  gdb strace ltrace valgrind
  dkms man-db man-pages
  python3-devel python3-virtualenv
  nodejs npm
  golang cargo rust ruby-devel rubygems
  kernel-devel kernel-headers
)

# Journald limits
JOURNAL_MAX_AGE="1day"
JOURNAL_MAX_SIZE="1M"
JOURNAL_MAX_FILE="1M"

# Xoá dữ liệu user cache cũ hơn X ngày
USER_CACHE_DAYS=1

# ================================
# Colors
# ================================
if [ -t 1 ]; then
  RED="\033[1;31m"
  GREEN="\033[1;32m"
  YEL="\033[1;33m"
  BLU="\033[1;34m"
  MAG="\033[1;35m"
  CYN="\033[1;36m"
  GRY="\033[0;90m"
  CLR="\033[0m"
else
  RED=""; GREEN=""; YEL=""; BLU=""; MAG=""; CYN=""; GRY=""; CLR=""
fi

info()  { echo -e "${CYN}[*]${CLR} $*"; }
ok()    { echo -e "${GREEN}[✓]${CLR} $*"; }
warn()  { echo -e "${YEL}[!]${CLR} $*"; }
err()   { echo -e "${RED}[x]${CLR} $*" >&2; }
step()  { echo -e "${MAG}==>${CLR} $*"; }

DRY_RUN=false

run() {
  if $DRY_RUN; then
    echo -e "${GRY}DRY-RUN: ${CLR} $*"
  else
    eval "$@"
  fi
}

require_root() {
  if [ "$(id -u)" -ne 0 ]; then
    err "Vui lòng chạy với sudo/root."
    exit 1
  fi
}

# ================================
# Package Manager Wrappers
# ================================
pkg_install() {
  case "$PKG_MGR" in
    apt)
      run "apt-get install -y $*"
      ;;
    dnf|yum)
      run "$PKG_MGR install -y $*"
      ;;
  esac
}

pkg_remove() {
  case "$PKG_MGR" in
    apt)
      run "apt-get purge -y $* 2>/dev/null || true"
      ;;
    dnf|yum)
      run "$PKG_MGR remove -y $* 2>/dev/null || true"
      ;;
  esac
}

pkg_autoremove() {
  case "$PKG_MGR" in
    apt)
      run "apt-get autoremove -y --purge"
      ;;
    dnf|yum)
      run "$PKG_MGR autoremove -y"
      ;;
  esac
}

pkg_clean() {
  case "$PKG_MGR" in
    apt)
      run "apt-get clean"
      run "rm -rf /var/cache/apt/archives/* /var/lib/apt/lists/*"
      run "mkdir -p /var/lib/apt/lists/partial /var/cache/apt/archives/partial || true"
      ;;
    dnf|yum)
      run "$PKG_MGR clean all"
      run "rm -rf /var/cache/dnf/* /var/cache/yum/* 2>/dev/null || true"
      ;;
  esac
}

pkg_update() {
  case "$PKG_MGR" in
    apt)
      run "apt-get update -y"
      ;;
    dnf|yum)
      run "$PKG_MGR makecache"
      ;;
  esac
}

pkg_upgrade() {
  case "$PKG_MGR" in
    apt)
      run "apt-get -y full-upgrade"
      ;;
    dnf)
      run "dnf -y upgrade"
      ;;
    yum)
      run "yum -y update"
      ;;
  esac
}

pkg_is_installed() {
  local pkg="$1"
  case "$PKG_MGR" in
    apt)
      dpkg -l "$pkg" &>/dev/null
      ;;
    dnf|yum)
      rpm -q "$pkg" &>/dev/null
      ;;
  esac
}

pkg_list_installed() {
  local pattern="$1"
  case "$PKG_MGR" in
    apt)
      dpkg -l "$pattern" 2>/dev/null | awk '/^ii/{print $2}'
      ;;
    dnf|yum)
      rpm -qa "$pattern" 2>/dev/null
      ;;
  esac
}

# ================================
# Disk Report
# ================================
disk_report() {
  step "BÁO CÁO DUNG LƯỢNG"
  df -hT /
  du -sh /usr/lib/modules 2>/dev/null || true
  du -sh /usr/src 2>/dev/null || true
  du -sh /var/log 2>/dev/null || true
  du -sh /var/cache 2>/dev/null || true
}

# ================================
# System Update
# ================================
system_update() {
  step "CẬP NHẬT HỆ THỐNG"
  pkg_update
  pkg_upgrade
  pkg_autoremove
  ok "Hệ thống đã cập nhật."
}

# ================================
# Locales
# ================================
minimize_locales() {
  step "TỐI GIẢN LOCALE (giữ:  ${KEEP_LOCALES[*]})"

  case "$PKG_MGR" in
    apt)
      # --- Code cũ cho Ubuntu/Debian giữ nguyên ---
      if pkg_is_installed locales-all; then
        pkg_remove locales-all
      fi

      local supported="/usr/share/i18n/SUPPORTED"
      if [ -f /etc/locale.gen ]; then
        run "cp -a /etc/locale.gen /etc/locale.gen.bak.$(date +%F-%H%M%S)"
      fi

      if [ -f "$supported" ]; then
        local re="^($(IFS='|'; echo "${KEEP_LOCALES[*]}"))([.@]|$)"
        if ! $DRY_RUN; then
          awk -v re="$re" 'NF>=2 && $1 ~ re { print $1" "$2 }' "$supported" > /etc/locale.gen
        else
          info "Sẽ ghi /etc/locale.gen với regex: $re"
        fi
        run "locale-gen"
      fi

      local pkgs
      pkgs=$(dpkg-query -W -f='${Package}\n' 'language-pack-*' 2>/dev/null | grep -Ev "(^language-pack-(en)(-|$))" || true)
      if [ -n "${pkgs:-}" ]; then
        pkg_remove $pkgs
      fi
      ;;

    dnf|yum)
      # --- PHẦN SỬA LỖI CHO RHEL/ALMALINUX ---

      # 1. Đảm bảo gói ngôn ngữ cần thiết đã được cài
      info "Cài đặt langpack en..."
      pkg_install glibc-langpack-en

      # 2. Gỡ bỏ các langpack thừa
      local langpacks
      langpacks=$(rpm -qa 'glibc-langpack-*' 2>/dev/null | grep -Ev 'glibc-langpack-(en)' || true)

      if [ -n "${langpacks:-}" ]; then
        info "Gỡ langpack thừa: $langpacks"
        pkg_remove $langpacks
      fi

      # 3. Rebuild locale an toàn bằng cách reinstall glibc-common
      # KHÔNG dùng build-locale-archive thủ công vì dễ gây Bus Error trên VPS ít RAM
      info "Tối ưu hóa locale archive thông qua reinstall glibc-common..."
      if ! $DRY_RUN; then
        # Cấu hình yum/dnf để không cài lại các langpack đã gỡ (tsflags=nodocs đã có sẵn trong VPS optimized)
        # Lệnh này sẽ kích hoạt trigger post-transaction để build lại locale-archive chuẩn
        run "$PKG_MGR reinstall -y glibc-common"
      fi
      ;;
  esac

  # Dọn dẹp thư mục /usr/share/locale (Chung cho cả 2 distro)
  if [ -d /usr/share/locale ]; then
    info "Dọn dẹp thư mục /usr/share/locale rác..."
    # Tìm và xoá các thư mục locale không nằm trong danh sách giữ lại
    # Lưu ý: Cần giữ locale.alias và các thư mục en
    find /usr/share/locale -mindepth 1 -maxdepth 1 -type d | while read -r d; do
      local bn
      bn=$(basename "$d")
      case "$bn" in
        en|en_*|locale.alias)
          # Giữ lại
          ;;
        *)
          run "rm -rf '$d'"
          ;;
      esac
    done
  fi

  ok "Locale đã tối giản."
}

# ================================
# Journald & logs
# ================================
tune_journald() {
  step "GIỚI HẠN JOURNAL LOG"
  run "mkdir -p /etc/systemd/journald.conf.d"
  local conf="/etc/systemd/journald.conf.d/cleanup.conf"
  if !  $DRY_RUN; then
    cat > "$conf" <<EOF
[Journal]
SystemMaxUse=${JOURNAL_MAX_SIZE}
SystemMaxFileSize=${JOURNAL_MAX_FILE}
MaxRetentionSec=${JOURNAL_MAX_AGE}
EOF
  else
    info "Sẽ tạo $conf với giới hạn ${JOURNAL_MAX_SIZE}/${JOURNAL_MAX_FILE}, tuổi ${JOURNAL_MAX_AGE}"
  fi
  run "systemctl restart systemd-journald || true"
  run "journalctl --vacuum-time='${JOURNAL_MAX_AGE}' || true"
  run "journalctl --vacuum-size='${JOURNAL_MAX_SIZE}' || true"
  ok "Đã cấu hình journald."
}

trim_var_logs() {
  step "CẮT GỌN /var/log"
  while IFS= read -r -d '' f; do
    [[ "$f" == /var/log/journal/* ]] && continue
    local sz
    sz=$(stat -c%s "$f" 2>/dev/null || echo 0)
    if (( sz > 1048576 )); then
      info "Cắt còn 1MB: $f"
      if ! $DRY_RUN; then
        local tmpf
        tmpf="$(mktemp)"
        tail -c 1048576 "$f" > "$tmpf" 2>/dev/null || true
        cat "$tmpf" > "$f" || true
        rm -f "$tmpf"
      fi
    fi
  done < <(find /var/log -type f !  -name '*.gz' ! -name '*.xz' ! -name '*.zst' -print0 2>/dev/null)

  run "find /var/log -type f -name '*.gz' -mtime +1 -delete 2>/dev/null || true"
  run "find /var/log -type f -name '*.old' -delete 2>/dev/null || true"
  run "find /var/log -type f -name '*-???????? ' -delete 2>/dev/null || true"
  ok "Đã cắt gọn /var/log."
}

# ================================
# Dev tools removal
# ================================
purge_dev_tools() {
  step "GỠ DEV TOOLS"
  local installed=()
  local p
  local dev_pkgs=()

  case "$PKG_MGR" in
    apt)
      dev_pkgs=("${DEV_PKGS_APT[@]}")
      # Thêm linux-headers dynamic
      dev_pkgs+=("linux-headers-$(uname -r)")
      ;;
    dnf|yum)
      dev_pkgs=("${DEV_PKGS_DNF[@]}")
      ;;
  esac

  for p in "${dev_pkgs[@]}"; do
    if pkg_is_installed "$p"; then
      installed+=("$p")
    fi
  done

  if [ ${#installed[@]} -gt 0 ]; then
    info "Sẽ gỡ:  ${installed[*]}"
    pkg_remove "${installed[@]}"
    pkg_autoremove
  else
    info "Không phát hiện dev tools trong danh sách."
  fi

  # RHEL/AlmaLinux:  Gỡ Development Tools group nếu có
  if [[ "$PKG_MGR" == "dnf" || "$PKG_MGR" == "yum" ]]; then
    if $PKG_MGR group list installed 2>/dev/null | grep -qi "Development Tools"; then
      info "Gỡ group 'Development Tools'..."
      run "$PKG_MGR groupremove -y 'Development Tools' || true"
    fi
  fi

  ok "Đã gỡ dev tools."
}

# ================================
# Caches
# ================================
clean_caches() {
  step "XOÁ CACHE"
  pkg_clean

  local d
  for d in /root /home/*; do
    [ -d "$d" ] || continue
    run "rm -rf \"$d/.cache/pip\" \"$d/.cache/pip-tools\" 2>/dev/null || true"
    run "rm -rf \"$d/.npm\" \"$d/.cache/yarn\" \"$d/.yarn\" 2>/dev/null || true"
    run "rm -rf \"$d/.cargo/registry\" \"$d/.cargo/git\" 2>/dev/null || true"
    run "rm -rf \"$d/go/pkg/mod\" \"$d/.cache/go-build\" 2>/dev/null || true"
    run "rm -rf \"$d/.gem\" 2>/dev/null || true"
    run "find \"$d/.cache\" -type f -mtime +${USER_CACHE_DAYS} -delete 2>/dev/null || true"
    run "find \"$d/.cache/thumbnails\" -type f -delete 2>/dev/null || true"
    run "rm -rf \"$d/.config/Code/Cache\" \"$d/.config/Code/CachedData\" \"$d/.config/Code/Service Worker/CacheStorage\" 2>/dev/null || true"
  done
  ok "Đã xoá caches."
}

# ================================
# Swap
# ================================
disable_and_remove_swap() {
  step "TẮT & XOÁ SWAP"
  run "swapoff -a || true"
  if [ -f /swapfile ]; then
    info "Xoá /swapfile"
    run "chattr -i /swapfile 2>/dev/null || true"
    run "rm -f /swapfile"
  fi
  if [ -f /etc/fstab ]; then
    if ! $DRY_RUN; then
      cp -a /etc/fstab "/etc/fstab.bak.$(date +%F-%H%M%S)"
      sed -ri 's|^([^#].*\s+swap\s+.*)$|# \1|g' /etc/fstab
    else
      info "Sẽ comment mọi dòng swap trong /etc/fstab"
    fi
  fi
  warn "Nếu có phân vùng swap riêng, script chỉ vô hiệu hoá. Xoá phân vùng thủ công nếu cần."
  ok "Đã vô hiệu hoá swap."
}

# ================================
# SNAP removal (Ubuntu only)
# ================================
_snap_refresh_hold() {
  local hold
  hold="$(date -u -d '+7 days' --iso-8601=minutes 2>/dev/null || true)"
  if [ -z "${hold}" ]; then
    hold="$(date -u -d 'now + 7 days' +%Y-%m-%dT%H:%M:%S%z 2>/dev/null || true)"
  fi
  [ -n "$hold" ] && run "snap set system refresh.hold='${hold}' || true"
}

_snap_abort_conflicts() {
  local ids
  ids=$(snap changes 2>/dev/null | awk 'NR>1 && ($5=="Doing" || $5=="Pending"){print $1}' || true)
  if [ -n "${ids:-}" ]; then
    local id
    for id in $ids; do
      run "snap abort $id || true"
    done
  fi
}

_snap_wait_clear() {
  local t=0
  while : ; do
    local busy
    busy=$(snap changes 2>/dev/null | awk 'NR>1 && ($5=="Doing" || $5=="Pending"){print $1}' | wc -l)
    if [ "$busy" -eq 0 ]; then
      break
    fi
    info "Đang đợi snap hoàn tất change..."
    sleep 5
    t=$((t+5))
    if [ $t -ge 60 ]; then
      break
    fi
  done
}

_unmount_snap_mounts() {
  local mps
  mps=$(mount | awk '/\/snap\/.* type squashfs/ {print $3}' || true)
  if [ -n "${mps:-}" ]; then
    local mp
    while read -r mp; do
      [ -n "$mp" ] && run "umount -l \"$mp\" || true"
    done <<< "$mps"
  fi
  local lxdm
  lxdm=$(mount | awk '/\/var\/snap\/lxd\/common/ {print $3}' || true)
  if [ -n "${lxdm:-}" ]; then
    local mp
    while read -r mp; do
      [ -n "$mp" ] && run "umount -l \"$mp\" || true"
    done <<< "$lxdm"
  fi
}

_stop_snap_services() {
  run "systemctl stop snapd.service snapd.socket snapd.seeded.service snapd.snap-repair.service 2>/dev/null || true"
  run "systemctl stop snap.lxd.daemon 2>/dev/null || true"
}

_disable_snap_services() {
  run "systemctl disable snapd.service snapd.socket snapd.seeded.service snapd.snap-repair.service 2>/dev/null || true"
  run "systemctl disable snap.lxd.daemon 2>/dev/null || true"
  run "systemctl mask snapd.service snapd.socket 2>/dev/null || true"
}

remove_snap() {
  # Chỉ chạy trên Ubuntu/Debian
  if [[ "$PKG_MGR" != "apt" ]]; then
    info "Snap không có trên $DISTRO, bỏ qua."
    return 0
  fi

  step "GỠ TOÀN BỘ SNAP (robust)"
  if ! command -v snap >/dev/null 2>&1; then
    info "Không có snap trên hệ thống."
    return 0
  fi

  _snap_refresh_hold
  _snap_abort_conflicts
  _snap_wait_clear
  _stop_snap_services

  # Gỡ lxd trước
  if snap list 2>/dev/null | awk 'NR>1{print $1}' | grep -qx "lxd"; then
    info "Phát hiện snap lxd — dừng & gỡ trước"
    run "systemctl stop snap.lxd.daemon 2>/dev/null || true"
    if command -v lxc >/dev/null 2>&1; then
      run "lxc stop -f --all || true"
    fi
    _snap_abort_conflicts
    _snap_wait_clear
    run "snap remove --purge lxd || true"
  fi

  # Gỡ tất cả snaps (trừ core/coreXX/snapd)
  local nonbases
  nonbases=$(snap list 2>/dev/null | awk 'NR>1 {print $1}' | grep -Ev '^(core|core[0-9]+|snapd)$' || true)
  if [ -n "${nonbases:-}" ]; then
    local s
    for s in $nonbases; do
      _snap_abort_conflicts
      _snap_wait_clear
      run "snap remove --purge \"$s\" || true"
    done
  fi

  # Gỡ core/coreXX
  local bases
  bases=$(snap list 2>/dev/null | awk 'NR>1 {print $1}' | grep -E '^(core|core[0-9]+)$' | sort -Vr || true)
  if [ -n "${bases:-}" ]; then
    local b
    for b in $bases; do
      _snap_abort_conflicts
      _snap_wait_clear
      run "snap remove --purge \"$b\" || true"
    done
  fi

  _unmount_snap_mounts
  _snap_abort_conflicts
  _snap_wait_clear

  # Gỡ lại cái còn sót
  local leftovers
  leftovers=$(snap list 2>/dev/null | awk 'NR>1 {print $1}' || true)
  if [ -n "${leftovers:-}" ]; then
    local s
    for s in $leftovers; do
      run "snap remove --purge \"$s\" || true"
    done
  fi

  _disable_snap_services
  _stop_snap_services
  _unmount_snap_mounts
  _snap_abort_conflicts
  _snap_wait_clear

  pkg_remove snapd
  run "rm -rf /snap /var/snap /var/lib/snapd /var/cache/snapd"
  ok "Snap đã gỡ xong."
}

# ================================
# Purge old kernels
# ================================
purge_old_kernels() {
  step "XOÁ KERNEL CŨ (giữ chỉ kernel đang chạy + 1 bản dự phòng})"

  local cur
  cur="$(uname -r)"
  info "Kernel hiện tại: ${cur}"

  case "$PKG_MGR" in
    apt)
      _purge_old_kernels_apt
      ;;
    dnf|yum)
      _purge_old_kernels_dnf
      ;;
  esac

  # Xoá thư mục mồ côi trong /usr/lib/modules
  if [ -d /usr/lib/modules ]; then
    step "DỌN /usr/lib/modules (mồ côi)"
    local d
    for d in /usr/lib/modules/*; do
      [ -d "$d" ] || continue
      local bn
      bn=$(basename "$d")
      if [ "$bn" = "$cur" ]; then
        continue
      fi
      case "$PKG_MGR" in
        apt)
          if dpkg -S "$d" >/dev/null 2>&1; then
            info "Giữ $d (thuộc package)."
          else
            info "Xoá mồ côi: $d"
            run "rm -rf \"$d\""
          fi
          ;;
        dnf|yum)
          if rpm -qf "$d" >/dev/null 2>&1; then
            info "Giữ $d (thuộc package)."
          else
            info "Xoá mồ côi: $d"
            run "rm -rf \"$d\""
          fi
          ;;
      esac
    done
  fi

  # Xoá headers mồ côi trong /usr/src
  if [ -d /usr/src ]; then
    step "DỌN /usr/src (headers mồ côi)"
    local s
    for s in /usr/src/linux-headers-* /usr/src/kernels/*; do
      [ -e "$s" ] || continue
      case "$PKG_MGR" in
        apt)
          if dpkg -S "$s" >/dev/null 2>&1; then
            info "Giữ $s (thuộc package)."
          else
            info "Xoá mồ côi: $s"
            run "rm -rf \"$s\""
          fi
          ;;
        dnf|yum)
          if rpm -qf "$s" >/dev/null 2>&1; then
            info "Giữ $s (thuộc package)."
          else
            info "Xoá mồ côi: $s"
            run "rm -rf \"$s\""
          fi
          ;;
      esac
    done
  fi

  ok "Kernel cũ đã purge & thư mục mồ côi đã dọn."
}

_purge_old_kernels_apt() {
  local cur
  cur="$(uname -r)"
  local cur_pkg="linux-image-${cur}"
  info "Kernel package hiện tại: ${cur_pkg}"

  local imgs
  imgs=$(dpkg -l 'linux-image-*' 2>/dev/null | awk '/^ii/{print $2}' | grep -E 'linux-image-[0-9]' || true)
  if [ -z "${imgs}" ]; then
    info "Không tìm thấy kernel image cũ để gỡ."
    return 0
  fi

  local keep_pkgs="linux-image-generic|linux-image-virtual|linux-image-aws|linux-image-kvm|linux-virtual|linux-generic|linux-aws|grub-"
  local candidates
  candidates=$(echo "$imgs" | grep -Ev "$keep_pkgs" | grep -v "^${cur_pkg}$" || true)

  if $KEEP_ONE_BACKUP && [ -n "${candidates:-}" ]; then
    local newest_ver backup_pkg
    newest_ver=$(echo "$candidates" | sed 's/^linux-image-//' | sort -Vr | head -n1 || true)
    if [ -n "${newest_ver:-}" ]; then
      backup_pkg="linux-image-${newest_ver}"
      info "Giữ dự phòng: ${backup_pkg}"
      candidates=$(echo "$candidates" | grep -vx "$backup_pkg" || true)
    fi
  fi

  if [ -z "${candidates:-}" ]; then
    info "Không còn kernel cũ để gỡ."
    return 0
  fi

  local to_purge=()
  while read -r img; do
    [ -z "$img" ] && continue
    local ver
    ver="${img#linux-image-}"
    to_purge+=("$img")
    pkg_is_installed "linux-image-unsigned-${ver}" && to_purge+=("linux-image-unsigned-${ver}")
    pkg_is_installed "linux-modules-${ver}" && to_purge+=("linux-modules-${ver}")
    pkg_is_installed "linux-modules-extra-${ver}" && to_purge+=("linux-modules-extra-${ver}")
    pkg_is_installed "linux-headers-${ver}" && to_purge+=("linux-headers-${ver}")
    local base_v
    base_v="${ver%-generic}"; base_v="${base_v%-aws}"; base_v="${base_v%-virtual}"; base_v="${base_v%-kvm}"
    pkg_is_installed "linux-headers-${base_v}" && to_purge+=("linux-headers-${base_v}")
  done < <(echo "$candidates")

  if [ ${#to_purge[@]} -gt 0 ]; then
    mapfile -t to_purge < <(printf "%s\n" "${to_purge[@]}" | sort -u)
    info "Purge các gói kernel:  ${to_purge[*]}"
    pkg_remove "${to_purge[@]}"
    pkg_autoremove
    run "update-grub || update-grub2 || true"
  fi

  # Purge residual config (rc)
  local rc
  rc=$(dpkg -l | awk '/^rc/{print $2}' || true)
  if [ -n "${rc:-}" ]; then
    pkg_remove $rc
  fi
}

_purge_old_kernels_dnf() {
  local cur
  cur="$(uname -r)"
  info "Kernel hiện tại: ${cur}"

  # Lấy danh sách kernel packages
  local kernels
  kernels=$(rpm -qa 'kernel-*' 2>/dev/null | grep -E '^kernel-(core|modules|devel|headers)-[0-9]' | sort -V || true)

  if [ -z "${kernels}" ]; then
    # Thử với format khác
    kernels=$(rpm -qa 'kernel-[0-9]*' 2>/dev/null | sort -V || true)
  fi

  if [ -z "${kernels}" ]; then
    info "Không tìm thấy kernel cũ để gỡ."
    return 0
  fi

  # Tìm các kernel version (không phải package name)
  local all_versions
  all_versions=$(rpm -qa 'kernel-core-*' 2>/dev/null | sed 's/^kernel-core-//' | sort -V || true)
  if [ -z "${all_versions}" ]; then
    all_versions=$(rpm -qa 'kernel-[0-9]*' 2>/dev/null | sed 's/^kernel-//' | sort -V || true)
  fi

  if [ -z "${all_versions}" ]; then
    info "Không tìm thấy kernel version để xử lý."
    return 0
  fi

  local to_remove=()
  while read -r ver; do
    [ -z "$ver" ] && continue
    # Bỏ qua kernel đang chạy
    if [[ "$cur" == *"$ver"* ]] || [[ "$ver" == *"$cur"* ]] || [[ "$cur" == "$ver" ]]; then
      info "Giữ kernel hiện tại: $ver"
      continue
    fi
    to_remove+=("$ver")
  done < <(echo "$all_versions")

  # Nếu giữ 1 backup, bỏ version mới nhất trong danh sách remove
  if $KEEP_ONE_BACKUP && [ ${#to_remove[@]} -gt 0 ]; then
    local newest="${to_remove[-1]}"
    info "Giữ dự phòng: $newest"
    unset 'to_remove[-1]'
  fi

  if [ ${#to_remove[@]} -eq 0 ]; then
    info "Không còn kernel cũ để gỡ."
    return 0
  fi

  # Gỡ từng version
  for ver in "${to_remove[@]}"; do
    info "Gỡ kernel version: $ver"
    local pkgs_to_rm=""
    for prefix in kernel kernel-core kernel-modules kernel-modules-extra kernel-devel kernel-headers; do
      local pkg="${prefix}-${ver}"
      if rpm -q "$pkg" &>/dev/null; then
        pkgs_to_rm+=" $pkg"
      fi
    done
    if [ -n "$pkgs_to_rm" ]; then
      pkg_remove $pkgs_to_rm
    fi
  done

  pkg_autoremove

  # Update GRUB
  if [ -f /boot/grub2/grub.cfg ]; then
    run "grub2-mkconfig -o /boot/grub2/grub.cfg 2>/dev/null || true"
  elif [ -f /boot/efi/EFI/almalinux/grub.cfg ]; then
    run "grub2-mkconfig -o /boot/efi/EFI/almalinux/grub.cfg 2>/dev/null || true"
  elif [ -f /boot/efi/EFI/centos/grub.cfg ]; then
    run "grub2-mkconfig -o /boot/efi/EFI/centos/grub.cfg 2>/dev/null || true"
  elif [ -f /boot/efi/EFI/rocky/grub.cfg ]; then
    run "grub2-mkconfig -o /boot/efi/EFI/rocky/grub.cfg 2>/dev/null || true"
  elif [ -f /boot/efi/EFI/redhat/grub.cfg ]; then
    run "grub2-mkconfig -o /boot/efi/EFI/redhat/grub.cfg 2>/dev/null || true"
  fi
}

# ================================
# Cloud-init (VPS)
# ================================
remove_cloud_init() {
  step "GỠ CLOUD-INIT (VPS)"
  run "systemctl stop cloud-init cloud-config cloud-final cloud-init-local 2>/dev/null || true"
  run "cloud-init clean --logs 2>/dev/null || true"

  case "$PKG_MGR" in
    apt)
      if [ -f /etc/netplan/50-cloud-init.yaml ]; then
        run "cp -a /etc/netplan/50-cloud-init.yaml /etc/netplan/50-cloud-init.yaml.bak.$(date +%F-%H%M%S)"
      fi
      pkg_remove cloud-init cloud-initramfs-copymods cloud-initramfs-dyn-netconf
      ;;
    dnf|yum)
      # Backup network config nếu có
      if [ -f /etc/sysconfig/network-scripts/ifcfg-eth0 ]; then
        run "cp -a /etc/sysconfig/network-scripts/ifcfg-eth0 /etc/sysconfig/network-scripts/ifcfg-eth0.bak.$(date +%F-%H%M%S)"
      fi
      pkg_remove cloud-init cloud-utils-growpart
      ;;
  esac

  run "rm -rf /var/lib/cloud /var/log/cloud-init.log /var/log/cloud-init-output.log /etc/cloud"
  run "systemctl disable cloud-init cloud-config cloud-final cloud-init-local 2>/dev/null || true"
  ok "Đã gỡ cloud-init."
}

# ================================
# Extra cleanup for RHEL-based
# ================================
cleanup_rhel_extras() {
  if [[ "$PKG_MGR" != "dnf" && "$PKG_MGR" != "yum" ]]; then
    return 0
  fi

  step "DỌN DẸP BỔ SUNG CHO RHEL/ALMALINUX"

  # Xoá orphan packages
  local orphans
  orphans=$($PKG_MGR repoquery --extras 2>/dev/null || true)
  if [ -n "${orphans:-}" ]; then
    info "Phát hiện orphan packages..."
    warn "Orphan packages (kiểm tra thủ công): $orphans"
  fi

  # Xoá rescue kernel nếu có
  local rescue_pkgs
  rescue_pkgs=$(rpm -qa 'kernel*rescue*' 2>/dev/null || true)
  if [ -n "${rescue_pkgs:-}" ]; then
    info "Gỡ rescue kernel:  $rescue_pkgs"
    pkg_remove $rescue_pkgs
  fi

  # Xoá dnf cache metadata
  run "$PKG_MGR clean dbcache metadata expire-cache 2>/dev/null || true"

  # Xoá package download cache
  run "rm -rf /var/cache/dnf/*/packages/* 2>/dev/null || true"
  run "rm -rf /var/cache/yum/*/packages/* 2>/dev/null || true"

  ok "Đã dọn dẹp bổ sung cho RHEL/AlmaLinux."
}

# ================================
# Final sweep
# ================================
final_sweep() {
  step "QUÉT LẦN CUỐI"
  run "journalctl --vacuum-time='${JOURNAL_MAX_AGE}' || true"
  run "journalctl --vacuum-size='${JOURNAL_MAX_SIZE}' || true"
  run "rm -rf /tmp/* /var/tmp/* 2>/dev/null || true"

  # Xoá core dumps
  run "rm -rf /var/lib/systemd/coredump/* 2>/dev/null || true"

  # Xoá crash reports
  run "rm -rf /var/crash/* 2>/dev/null || true"

  ok "Xong."
}

# ================================
# Usage
# ================================
usage() {
  cat <<'USAGE'
Usage: sudo bash cleanup.sh [--dry-run] [--keep-cloud-init] [--no-update] [--keep-one-backup]

  --dry-run           :  Chỉ hiển thị hành động, không thực thi.
  --keep-cloud-init   :  KHÔNG gỡ cloud-init (mặc định gỡ trên VPS).
  --no-update         : Không chạy apt/dnf update trước khi dọn.
  --keep-one-backup   : Giữ thêm 1 kernel dự phòng (ngoài kernel đang chạy).

Hỗ trợ:  Ubuntu 22.04, AlmaLinux 8/9, CentOS 8/9, Rocky Linux 8/9

Mặc định: chỉ giữ kernel đang chạy; xoá sạch kernel cũ + thư mục mồ côi.
USAGE
}

# ================================
# Main
# ================================
main() {
  require_root
  detect_distro

  # Parse args
  local arg
  for arg in "$@"; do
    case "$arg" in
      --dry-run) DRY_RUN=true ;;
      --keep-cloud-init) REMOVE_CLOUD_INIT=false ;;
      --no-update) DO_SYSTEM_UPDATE=false ;;
      --keep-one-backup) KEEP_ONE_BACKUP=true ;;
      -h|--help) usage; exit 0 ;;
      *) warn "Bỏ qua tham số không hỗ trợ: $arg" ;;
    esac
  done

  step "BẮT ĐẦU DỌN DẸP ($DISTRO $DISTRO_VERSION)"
  disk_report

  if $DO_SYSTEM_UPDATE; then
    system_update
  else
    info "Bỏ qua cập nhật hệ thống."
  fi

  minimize_locales
  tune_journald
  trim_var_logs
  purge_dev_tools
  clean_caches
  disable_and_remove_swap
  remove_snap
  
  sudo sed -ri 's/^[[:space:]]*#?[[:space:]]*(precedence[[:space:]]+::ffff:0:0\/96[[:space:]]+100)/\1/' /etc/gai.conf || echo 'precedence ::ffff:0:0/96  100' | sudo tee -a /etc/gai.conf

  if $REMOVE_CLOUD_INIT; then
    remove_cloud_init
  else
    info "Giữ cloud-init theo yêu cầu."
  fi

  purge_old_kernels
  cleanup_rhel_extras
  final_sweep

  ok "HOÀN TẤT!"
  disk_report
}

main "$@"