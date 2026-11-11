  local pct=${1:-0} width=${2:-24} count i
  (( pct < 0 )) && pct=0
  (( pct > 100 )) && pct=100
  count=$((pct * width / 100))
  printf '%s' "$CYAN"
  for ((i=0; i<count; i++)); do printf '█'; done
  printf '%s' "$DIM"
  for ((i=count; i<width; i++)); do printf '░'; done
  printf '%s' "$RESET"
}

cpu_sample() {
  local label user nice sys idle iowait irq softirq steal guest guest_nice
  local total idle_all delta_total delta_idle
  read -r label user nice sys idle iowait irq softirq steal guest guest_nice < /proc/stat
  total=$((user + nice + sys + idle + iowait + irq + softirq + steal))
  idle_all=$((idle + iowait))
  if ((prev_total > 0)); then
    delta_total=$((total - prev_total))
    delta_idle=$((idle_all - prev_idle))
    if ((delta_total > 0)); then
      cpu_pct=$((100 * (delta_total - delta_idle) / delta_total))
    fi
  fi
  prev_total=$total
  prev_idle=$idle_all
}

mem_values() {
  read -r mem_total mem_used mem_free < <(free -m | awk '$1=="Mem:" {print $2, $3, $7}')
  mem_total=${mem_total:-0}
  mem_used=${mem_used:-0}
  mem_free=${mem_free:-0}  # available, not the raw free column
  if ((mem_total > 0)); then ram_pct=$((100 * mem_used / mem_total)); else ram_pct=0; fi
}

root_values() {
  read -r disk_total disk_used disk_avail disk_pct < <(df -hP / | awk 'NR==2 {print $2, $3, $4, $5}')
  disk_total=${disk_total:-N/A}
  disk_used=${disk_used:-N/A}
  disk_avail=${disk_avail:-N/A}
  disk_pct=${disk_pct%%%}
  disk_pct=${disk_pct:-0}
}

heading() {
  printf '%s%s╔══════════════════════════════════════════════════════════════╗%s\n' "$PINK" "$BOLD" "$RESET"
  printf '%s%s║  N E O N P U L S E    //    SYSTEM SURVEILLANCE             ║%s\n' "$CYAN" "$BOLD" "$RESET"
  printf '%s╚══════════════════════════════════════════════════════════════╝%s\n' "$PINK" "$RESET"
  printf '%sHOST:%s %-22s %sTIME:%s %s\n' "$PURPLE" "$RESET" "$(hostname)" "$PURPLE" "$RESET" "$(date '+%Y-%m-%d %H:%M:%S')"
  printf '%sKERNEL:%s %-20s %sUPTIME:%s %s\n' "$PURPLE" "$RESET" "$(uname -r)" "$PURPLE" "$RESET" "$(uptime -p)"
  printf '%s────────────────────────────────────────────────────────────────%s\n' "$DIM" "$RESET"
}

cpu_view() {
  printf '\n%s[ 01 // CPU CORE ]%s\n' "$PINK" "$RESET"
  printf 'Usage  %3d%%  ' "$cpu_pct"; bar "$cpu_pct" 30; printf '\n'
  printf '%sLoad:%s %s    %sProcesses:%s %s\n' "$DIM" "$RESET" "$(cut -d' ' -f1-3 /proc/loadavg)" "$DIM" "$RESET" "$(ps -e --no-headers | wc -l | tr -d ' ')"
}

ram_view() {
  printf '\n%s[ 02 // MEMORY BANK ]%s\n' "$PINK" "$RESET"
  printf 'Usage  %3d%%  ' "$ram_pct"; bar "$ram_pct" 30; printf '\n'
  printf '%sUsed:%s %s MiB  %sTotal:%s %s MiB  %sAvailable:%s %s MiB\n' "$DIM" "$RESET" "$mem_used" "$DIM" "$RESET" "$mem_total" "$DIM" "$RESET" "$mem_free"
}

disk_view() {
  printf '\n%s[ 03 // DISK ARRAY ]%s\n' "$PINK" "$RESET"
  printf 'Root   %3d%%  ' "$disk_pct"; bar "$disk_pct" 30; printf '\n'
  printf '%sRoot filesystem:%s %s used / %s total (%s available)\n' "$DIM" "$RESET" "$disk_used" "$disk_total" "$disk_avail"
  printf '\n%sAll filesystems:%s\n' "$PURPLE" "$RESET"
  df -hP | awk 'NR==1 {printf "%-20.20s %7s %7s %6s  %s\n",$1,$2,$3,$5,$6; next} {printf "%-20.20s %7s %7s %6s  %s\n",$1,$2,$3,$5,$6}' | head -n 14
}

proc_view() {
  printf '\n%s[ 04 // ACTIVE PROCESSES - TOP 5 CPU ]%s\n' "$PINK" "$RESET"
  ps -eo pid,comm,%cpu,%mem --sort=-%cpu | head -n 6
}

write_log() {
  {
    printf '\n=== NEONPULSE SNAPSHOT %s ===\n' "$(date '+%Y-%m-%d %H:%M:%S %z')"
    printf 'Hostname: %s | Kernel: %s | Uptime: %s\n' "$(hostname)" "$(uname -r)" "$(uptime -p)"
    printf 'CPU: %s%% | RAM: %s/%s MiB (%s%%) | Root disk: %s%%\n' "$cpu_pct" "$mem_used" "$mem_total" "$ram_pct" "$disk_pct"
    printf 'Process count: %s\n' "$(ps -e --no-headers | wc -l | tr -d ' ')"
    printf 'All filesystem usage:\n'
    df -hP
    printf 'Top 5 CPU processes:\n'
    ps -eo pid,comm,%cpu,%mem --sort=-%cpu | head -n 6
  } >> "$LOG_FILE"
}

if [[ ! -t 0 || ! -t 1 ]]; then
  printf 'Run this program inside an interactive terminal.\n' >&2
  exit 1
fi
printf '\033[?25l'
cpu_sample
sleep 0.15
cpu_sample
while true; do
  cpu_sample
  mem_values
  root_values
  if (( SECONDS - last_log >= 10 )); then
    write_log
    last_log=$SECONDS
  fi
  printf '\033[2J\033[H'
  heading
  case "$page" in
    all) cpu_view; ram_view; disk_view; proc_view ;;
    cpu) cpu_view; proc_view ;;
    ram) ram_view ;;
    disk) disk_view ;;
    proc) proc_view ;;
  esac
  printf '\n%s────────────────────────────────────────────────────────────────%s\n' "$DIM" "$RESET"
  printf '%s[0]%s All  %s[1]%s CPU  %s[2]%s RAM  %s[3]%s Disk  %s[4]%s Process  %s[L]%s Log  %s[Q]%s Quit\n' "$CYAN" "$RESET" "$CYAN" "$RESET" "$CYAN" "$RESET" "$CYAN" "$RESET" "$CYAN" "$RESET" "$CYAN" "$RESET" "$CYAN" "$RESET"
  printf '%sAuto refresh 2s | Log every 10s | %s%s\n' "$DIM" "$LOG_FILE" "$RESET"
  key=''
  IFS= read -rsn1 -t 2 key || true
  case "$key" in
    0) page=all ;;
    1) page=cpu ;;
    2) page=ram ;;
    3) page=disk ;;
    4) page=proc ;;
    l|L) write_log; last_log=$SECONDS ;;
    q|Q) exit 0 ;;
  esac
done
