#!/usr/bin/env bash
# ======================================================================
# VPS Clean Fusion - 修复版
# 修复: 1) 卸载参数识别 2) 容器环境只读文件系统兼容
# ======================================================================

set -Eeuo pipefail
IFS=$'\n\t'

# ====== 配置 ======
C0="\033[0m"; B="\033[1m"; BLU="\033[38;5;33m"; GRN="\033[38;5;40m"; YEL="\033[38;5;178m"; RED="\033[38;5;196m"; CYA="\033[36m"; GY="\033[90m"
SCRIPT_PATH="/root/vps-clean-fusion.sh"
LOG_FILE="/var/log/vps-clean-fusion.log"

hr(){ printf "${GY}%s${C0}\n" "────────────────────────────────────────────────────────"; }
title(){ printf "\n${B}${BLU}[%s]${C0} %s\n" "$1" "$2"; hr; }
ok(){ printf "${GRN}✔${C0} %s\n" "$*"; }
warn(){ printf "${YEL}⚠${C0} %s\n" "$*"; }
err(){ printf "${RED}✘${C0} %s\n" "$*"; }
log(){ printf "${CYA}•${C0} %s\n" "$*"; }
trap 'err "出错：行 $LINENO"; exit 1' ERR

# ====== 保护路径 ======
EXCLUDES=(
  "/www/server/panel" "/www/wwwlogs" "/www/wwwroot"
  "/www/server/nginx" "/www/server/apache" "/www/server/openresty"
  "/www/server/mysql" "/var/lib/mysql" "/var/lib/mariadb" "/var/lib/postgresql"
  "/www/server/php" "/etc/php" "/var/lib/php/sessions"
  "/etc/ssh" "/root/.ssh"
)
is_excluded(){ local p="$1"; for e in "${EXCLUDES[@]}"; do [[ "$p" == "$e"* ]] && return 0; done; return 1; }

# ====== 环境检测 ======
PKG="unknown"
if command -v apt-get >/dev/null 2>&1; then PKG="apt"; 
elif command -v dnf >/dev/null 2>&1; then PKG="dnf";
elif command -v yum >/dev/null 2>&1; then PKG="yum"; fi

# 检测是否为容器（只读文件系统）
is_container(){
  [[ -f /.dockerenv ]] || [[ -f /run/.containerenv ]] || grep -q 'container' /proc/1/cgroup 2>/dev/null || return 1
  return 0
}

# 自动安装 bc
check_and_install_bc(){
  if ! command -v bc >/dev/null 2>&1; then
    log "检测到 bc 未安装，正在自动安装..."
    case "$PKG" in
      apt) apt-get update -qq >/dev/null 2>&1 && apt-get install -y bc >/dev/null 2>&1 || warn "bc 安装失败" ;;
      dnf|yum) (dnf install -y bc >/dev/null 2>&1 || yum install -y bc >/dev/null 2>&1) || warn "bc 安装失败" ;;
    esac
  fi
}

is_vm(){ command -v systemd-detect-virt >/dev/null 2>&1 && systemd-detect-virt --quiet; }
NI(){ nice -n 19 ionice -c3 bash -c "$*"; }

# 安全卸载
dpkg_has(){ dpkg -s "$1" >/dev/null 2>&1; }
rpm_has(){ rpm -q "$1" >/dev/null 2>&1; }
pkg_purge(){
  for p in "$@"; do
    case "$PKG" in
      apt) dpkg_has "$p" && apt-get -y purge "$p" >/dev/null 2>&1 || true ;;
      dnf|yum) rpm_has "$p" && (dnf -y remove "$p" >/dev/null 2>&1 || yum -y remove "$p" >/dev/null 2>&1) || true ;;
    esac
  done
}

# ====== 清理函数 ======
main_clean(){
  title "🚀 开始深度清理" "预计可释放: ${1}MB"
  
  log "卸载 unzip..."
  pkg_purge unzip
  
  # APT锁处理
  if [[ "$PKG" == "apt" ]]; then
    pkill -9 -f 'apt|apt-get|dpkg|unattended-upgrade' 2>/dev/null || true
    rm -f /var/lib/dpkg/lock* /var/cache/apt/archives/lock || true
    dpkg --configure -a >/dev/null 2>&1 || true
  fi

  # 日志清理
  journalctl --rotate || true
  journalctl --vacuum-time=1d --vacuum-size=64M >/dev/null 2>&1 || true
  NI "find /var/log -type f \( -name '*.log' -o -name '*.old' -o -name '*.gz' \) -not -path '*/panel/logs/*' -not -path '*/wwwlogs/*' -exec truncate -s 0 {} + 2>/dev/null || true"
  : > /var/log/wtmp; : > /var/log/btmp; : > /var/log/lastlog; : > /var/log/faillog

  # 缓存清理
  rm -rf /var/lib/apt/lists/* /var/cache/apt/archives/* /var/cache/apt/archives/partial 2>/dev/null || true
  rm -rf /var/crash/* /var/lib/systemd/coredump/* /var/lib/nginx/tmp/* /var/lib/nginx/body/* /var/lib/nginx/proxy/* 2>/dev/null || true
  NI "find /tmp /var/tmp -xdev -type f -atime +1 -not -name 'sess_*' -delete 2>/dev/null || true"
  NI "find /tmp /var/tmp -xdev -type f -size +20M -not -name 'sess_*' -delete 2>/dev/null || true"
  NI "find /var/cache -xdev -type f -mtime +1 -delete 2>/dev/null || true"

  # 系统瘦身
  rm -rf /usr/share/man/* /usr/share/info/* /usr/share/doc/* 2>/dev/null || true
  [[ -d /usr/share/locale ]] && find /usr/share/locale -mindepth 1 -maxdepth 1 -type d | grep -Ev '(en|zh)' | xargs -r rm -rf 2>/dev/null || true
  [[ -d /usr/lib/locale ]] && ls /usr/lib/locale 2>/dev/null | grep -Ev '^(en|zh)' | xargs -r -I{} rm -rf "/usr/lib/locale/{}" 2>/dev/null || true
  NI "find / -xdev -type d -name '__pycache__' -prune -exec rm -rf {} + 2>/dev/null || true"
  NI "find / -xdev -type f -name '*.pyc' -delete 2>/dev/null || true"
  NI "find /usr/lib /usr/lib64 /lib /lib64 -type f \( -name '*.a' -o -name '*.la' \) -delete 2>/dev/null || true"

  # 包管理清理
  if [[ "$PKG" == "apt" ]]; then
    systemctl stop apt-daily.{service,timer} apt-daily-upgrade.{service,timer} 2>/dev/null || true
    apt-get -y autoremove --purge >/dev/null 2>&1 || true
    apt-get -y autoclean >/dev/null 2>&1 || true
    apt-get -y clean >/dev/null 2>&1 || true
    dpkg -l 2>/dev/null | awk '/^rc/{print $2}' | xargs -r dpkg -P >/dev/null 2>&1 || true
    CURK=$(uname -r)
    dpkg -l | awk '/linux-(headers|modules-extra)-/{print $2}' | grep -v "$CURK" | xargs -r apt-get -y purge >/dev/null 2>&1 || true
  elif [[ "$PKG" == "dnf" || "$PKG" == "yum" ]]; then
    dnf -y autoremove >/dev/null 2>&1 || yum -y autoremove >/dev/null 2>&1 || true
    dnf -y clean all >/dev/null 2>&1 || yum -y clean all >/dev/null 2>&1 || true
    rm -rf /var/cache/dnf/* /var/cache/yum/* 2>/dev/null || true
  fi

  # 组件裁剪
  if [[ "$PKG" == "apt" ]]; then
    pkg_purge snapd cloud-init apport whoopsie popularity-contest landscape-client ubuntu-advantage-tools unattended-upgrades
    pkg_purge cockpit* avahi-daemon cups* modemmanager network-manager* plymouth* fwupd* printer-driver-* xserver-xorg* x11-* wayland*
  elif [[ "$PKG" == "dnf" || "$PKG" == "yum" ]]; then
    pkg_purge cloud-init subscription-manager insights-client cockpit* abrt* sos* avahi* cups* modemmanager NetworkManager* plymouth* fwupd*
    pkg_purge man-db man-pages groff-base texinfo
  fi

  # Snap清理
  if command -v snap >/dev/null 2>&1; then
    snap list 2>/dev/null | sed '1d' | awk '{print $1}' | while read app; do snap remove "$app" >/dev/null 2>&1 || true; done
  fi
  systemctl stop snapd.service snapd.socket 2>/dev/null || true
  umount /snap 2>/dev/null || true
  pkg_purge snapd
  rm -rf /snap /var/snap /var/lib/snapd /var/cache/snapd 2>/dev/null || true

  # 虚机firmware裁剪
  if is_vm; then
    pkg_purge linux-firmware >/dev/null 2>&1 || true
    rm -rf /lib/firmware/* 2>/dev/null || true
  fi

  # 备份清理
  [[ -d /www/server/backup ]] && NI "rm -rf /www/server/backup/* 2>/dev/null || true"
  [[ -d /root/Downloads ]] && NI "rm -rf /root/Downloads/* 2>/dev/null || true"
  for d in /home/*/Downloads; do [[ -d "$d" ]] && NI "rm -rf '$d'/* 2>/dev/null || true"; done
  for base in /root /home/*; do
    [[ -d "$base" ]] || continue
    NI "find '$base' -type f \( -name '*.zip' -o -name '*.tar*' -o -name '*.bak' \) -delete 2>/dev/null || true"
  done

  # 大文件清理
  SAFE_BASES=(/tmp /var/tmp /var/cache /var/backups /root /home)
  for base in "${SAFE_BASES[@]}"; do
    [[ -d "$base" ]] || continue
    while IFS= read -r -d '' f; do
      is_excluded "$f" && continue
      NI "rm -f '$f' 2>/dev/null || true"
    done < <(find "$base" -xdev -type f -size +50M -print0 2>/dev/null)
  done

  # 内核清理
  if [[ "$PKG" == "apt" ]]; then
    CURK=$(uname -r)
    mapfile -t KS < <(dpkg -l | awk '/linux-image-[0-9]/{print $2}' | sort -V)
    KEEP=("linux-image-${CURK}")
    LATEST=$(printf "%s\n" "${KS[@]}" | grep -v "$CURK" | tail -n1 || true)
    [[ -n "${LATEST:-}" ]] && KEEP+=("$LATEST")
    PURGE=(); for k in "${KS[@]}"; do [[ " ${KEEP[*]} " == *" $k "* ]] || PURGE+=("$k"); done
    ((${#PURGE[@]})) && NI "apt-get -y purge ${PURGE[*]} >/dev/null 2>&1 || true"
  elif [[ "$PKG" == "dnf" || "$PKG" == "yum" ]]; then
    CURK_ESC=$(uname -r | sed 's/\./\\./g')
    mapfile -t RMK < <(rpm -q kernel-core kernel | grep -vE "$CURK_ESC" | sort -V | head -n -1 || true)
    ((${#RMK[@]})) && (dnf -y remove "${RMK[@]}" >/dev/null 2>&1 || yum -y remove "${RMK[@]}" >/dev/null 2>&1 || true)
  fi

  # 容器环境跳过 drop_caches
  if ! is_container; then
    LOAD1=$(awk '{print int($1)}' /proc/loadavg)
    MEM_AVAIL_KB=$(awk '/MemAvailable/{print $2}' /proc/meminfo)
    MEM_TOTAL_KB=$(awk '/MemTotal/{print $2}' /proc/meminfo)
    PCT=$(( MEM_AVAIL_KB*100 / MEM_TOTAL_KB ))
    if (( LOAD1 <= 2 && PCT >= 30 )); then
      sync
      echo 3 > /proc/sys/vm/drop_caches 2>/dev/null || echo 1 > /proc/sys/vm/drop_caches 2>/dev/null || true
      [[ -w /proc/sys/vm/compact_memory ]] && echo 1 > /proc/sys/vm/compact_memory || true
      sysctl -w vm.swappiness=10 >/dev/null 2>&1 || true
    fi
  else
    log "检测到容器环境，跳过内存缓存清理"
  fi

  # fstrim
  command -v fstrim >/dev/null 2>&1 && NI "fstrim -av >/dev/null 2>&1 || true"
}

# ====== Swap管理 ======
manage_swap(){
  title "💾 Swap管理" "内存≥2G禁用；<2G保留单一swap"
  calc_target_mib(){ local mem_kb; mem_kb=$(grep -E '^MemTotal:' /proc/meminfo | tr -s ' ' | cut -d' ' -f2); echo $(( (mem_kb/1024/2 < 256) ? 256 : (mem_kb/1024/2 > 2048) ? 2048 : mem_kb/1024/2 )); }
  active_count(){ swapon --show=NAME --noheadings 2>/dev/null | sed '/^$/d' | wc -l | tr -d ' '; }
  normalize_fstab(){ sed -i '\|/swapfile-[0-9]\+|d' /etc/fstab 2>/dev/null || true; sed -i '\|/swapfile |d' /etc/fstab 2>/dev/null || true; sed -i '\|/dev/zram|d' /etc/fstab 2>/dev/null || true; grep -q '^/swapfile ' /etc/fstab 2>/dev/null || echo "/swapfile none swap sw 0 0" >> /etc/fstab; }
  create_swap(){ local target; target=$(calc_target_mib); swapoff /swapfile 2>/dev/null || true; rm -f /swapfile 2>/dev/null || true; [[ "$(stat -f -c %T / 2>/dev/null || echo '')" == "btrfs" ]] && { touch /swapfile; chattr +C /swapfile 2>/dev/null || true; }; fallocate -l ${target}M /swapfile 2>/dev/null || dd if=/dev/zero of=/swapfile bs=1M count=${target} status=none conv=fsync; chmod 600 /swapfile; mkswap /swapfile >/dev/null; swapon /swapfile; }

  MEM_MB=$(awk '/MemTotal/{print int($2/1024)}' /proc/meminfo)
  if [[ "$MEM_MB" -ge 2048 ]]; then
    for dev in $(swapon --show=NAME --noheadings 2>/dev/null | sed '/^$/d'); do swapoff "$dev" 2>/dev/null || true; [[ "$dev" == /dev/* ]] || rm -f "$dev" 2>/dev/null || true; done
    rm -f /swapfile /swapfile-* /swap.emerg 2>/dev/null || true
    sed -i '/swap/d' /etc/fstab 2>/dev/null || true; ok "已禁用Swap（内存${MEM_MB}MiB）"
  else
    CNT=$(active_count)
    if [[ "$CNT" != "1" ]]; then
      for dev in $(swapon --show=NAME --noheadings 2>/dev/null | sed '/^$/d'); do swapoff "$dev" 2>/dev/null || true; [[ "$dev" == /dev/* ]] || rm -f "$dev" 2>/dev/null || true; done
      create_swap; normalize_fstab
    else
      normalize_fstab; ok "Swap配置正确"
    fi
  fi
  log "当前Swap："; swapon --show 2>/dev/null | sed 's/^/  /' || echo "  (无)"
}

# ====== 主流程 ======
main(){
  title "🌟 VPS Clean Fusion 完整版" "智能清理开始"
  check_and_install_bc
  log "平台: ${PKG}, 虚拟化: $(is_vm && echo "VM" || echo "Physical"), 容器: $(is_container && echo "Yes" || echo "No")"
  
  local EST_MB=$(calc_before_clean)
  main_clean "$EST_MB"
  manage_swap
  
  title "📊 清理完成" "系统状态"
  df -h / | sed 's/^/  /'
  free -h | sed 's/^/  /'
  
  log "日志已记录: ${LOG_FILE}"
  echo "$(date '+%Y-%m-%d %H:%M:%S') 清理完成，预估释放: ${EST_MB}MB" >> "$LOG_FILE"
  
  title "✅ 全部完成" "VPS已优化至极简状态"
}

# ====== 安装/卸载处理（修复参数识别）======
case "${1:-}" in
  --install)
    title "🔧 安装模式" "配置每日自动清理"
    chmod +x "$SCRIPT_PATH"
    
    # 清理旧的定时任务并添加新的
    (crontab -u root -l 2>/dev/null | grep -v 'vps-clean-fusion.sh' || true) | crontab -u root -
    echo "0 3 * * * /bin/bash $SCRIPT_PATH >/dev/null 2>&1" | crontab -u root -
    
    ok "安装成功！每天03:00自动运行"
    log "脚本位置: $SCRIPT_PATH"
    log "卸载命令: bash $SCRIPT_PATH --uninstall"
    
    # 立即执行首次清理
    log "正在执行首次清理..."
    sleep 2
    bash "$SCRIPT_PATH"
    ;;
  --uninstall)
    title "🗑️ 卸载模式" "移除所有配置"
    (crontab -u root -l 2>/dev/null | grep -v 'vps-clean-fusion.sh' || true) | crontab -u root -
    rm -f "$SCRIPT_PATH"
    ok "卸载完成！已移除定时任务和脚本"
    ;;
  *)
    main "$@"
    ;;
esac
