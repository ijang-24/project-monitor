#!/usr/bin/env bash
# NEONPULSE — monitor sistem Linux berbasis Bash, tanpa hak root.
# Cadangan asli yang terpotong tetap tersedia di monitor-backup.sh.

export LC_ALL=C.UTF-8
export TZ="${TZ:-:/etc/localtime}"

SCRIPT_DIR=''
LOG_FILE=''
REFRESH=${NEONPULSE_REFRESH:-2}
LOG_INTERVAL=${NEONPULSE_LOG_INTERVAL:-10}
LOG_MAX_BYTES=${NEONPULSE_LOG_MAX_BYTES:-1048576}
LOG_KEEP=${NEONPULSE_LOG_KEEP:-3}
WARN=${NEONPULSE_WARN:-70}
CRIT=${NEONPULSE_CRIT:-90}
ASCII=${NEONPULSE_ASCII:-0}
MODE=interactive
COLOR=1
page=all
disk_page=0
prev_total=0
prev_idle=0
cpu_tenths=0
cpu_pct=0
cpu_ok=0
mem_ok=0
disk_ok=0
proc_ok=0
terminal_active=0
resize_pending=1
notice='Sistem siap. Tekan H untuk bantuan.'
sample_number=0
rows=0
cols=0
width=0
inner=0
bar_width=20
log_error=''
declare -a disks=() processes=() cpu_history=() ram_history=()

usage() {
  printf '%s\n' \
    'NEONPULSE // Cyberpunk Linux System Monitor' \
    'Penggunaan: ./monitor.sh [--once | --snapshot | --help] [--no-color] [--ascii]' \
    '  tanpa opsi   dashboard interaktif (terminal minimal 76 kolom x 30 baris)' \
    '  --once       tampilkan satu snapshot teks; tidak menulis log' \
    '  --snapshot   tampilkan snapshot sekaligus append ke logs/monitor.log' \
    '  --no-color   nonaktifkan warna; NO_COLOR juga didukung' \
    '  --ascii      gunakan karakter ASCII untuk garis dan meter' \
    'Konfigurasi: NEONPULSE_REFRESH, NEONPULSE_LOG_INTERVAL, NEONPULSE_WARN,' \
    'NEONPULSE_CRIT, NEONPULSE_LOG_MAX_BYTES, NEONPULSE_LOG_KEEP (lihat README.md).'
}

parse_args() {
  while (($#)); do
    case "$1" in
      --once) MODE=once ;;
      --snapshot) MODE=snapshot ;;
      --no-color) COLOR=0 ;;
      --ascii) ASCII=1 ;;
      --help|-h) usage; exit 0 ;;
      *) printf 'Opsi tidak dikenal: %s\n' "$1" >&2; usage >&2; exit 2 ;;
    esac
    shift
  done
  [[ -v NO_COLOR ]] && COLOR=0
  return 0
}

# Batasi input konfigurasi sebelum digunakan dalam ekspansi aritmetika Bash.
validate_integer() {
  local name=$1 value=$2 minimum=$3 maximum=$4
  if [[ ! $value =~ ^[0-9]{1,10}$ ]]; then
    printf 'Konfigurasi %s harus berupa bilangan bulat.\n' "$name" >&2
    return 1
  fi
  value=$((10#$value))
  if ((value < minimum || value > maximum)); then
    printf 'Konfigurasi %s harus antara %s dan %s.\n' "$name" "$minimum" "$maximum" >&2
    return 1
  fi
  printf -v "$name" '%d' "$value"
}

check_environment() {
  local cmd missing=0
  ((BASH_VERSINFO[0] >= 4)) || { printf 'Bash >= 4 diperlukan.\n' >&2; return 1; }
  for cmd in ps df awk hostname uname date sleep mkdir mv wc flock; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
      printf 'Perintah wajib tidak tersedia: %s\n' "$cmd" >&2
      missing=1
    fi
  done
  ((missing == 0)) || return 1
  [[ -r /proc/stat && -r /proc/meminfo && -r /proc/uptime && -r /proc/loadavg ]] || {
    printf 'Antarmuka /proc Linux tidak tersedia atau tidak dapat dibaca.\n' >&2; return 1;
  }
  validate_integer REFRESH "$REFRESH" 1 10 &&
    validate_integer LOG_INTERVAL "$LOG_INTERVAL" 1 86400 &&
    validate_integer LOG_MAX_BYTES "$LOG_MAX_BYTES" 4096 1073741824 &&
    validate_integer LOG_KEEP "$LOG_KEEP" 1 10 &&
    validate_integer WARN "$WARN" 1 99 &&
    validate_integer CRIT "$CRIT" 2 100 &&
    validate_integer ASCII "$ASCII" 0 1 || return 1
  ((WARN < CRIT)) || { printf 'NEONPULSE_WARN harus lebih kecil dari NEONPULSE_CRIT.\n' >&2; return 1; }
  if [[ $MODE == interactive ]]; then
    command -v stty >/dev/null 2>&1 || { printf 'Perintah stty diperlukan.\n' >&2; return 1; }
    [[ -t 0 && -t 1 && ${TERM:-dumb} != dumb ]] || {
      printf 'Gunakan terminal interaktif, atau jalankan ./monitor.sh --once.\n' >&2; return 1;
    }
  fi
}

setup_style() {
  RESET='' BOLD='' DIM='' CYAN='' PINK='' PURPLE='' YELLOW='' RED='' WHITE=''
  if ((COLOR)); then
    RESET=$'\e[0m'; BOLD=$'\e[1m'; DIM=$'\e[38;2;150;160;180m'
    CYAN=$'\e[38;2;34;211;238m'; PINK=$'\e[38;2;232;121;249m'
    PURPLE=$'\e[38;2;167;139;250m'; YELLOW=$'\e[38;2;250;204;21m'
    RED=$'\e[38;2;251;113;133m'; WHITE=$'\e[38;2;226;232;240m'
  fi
  TL='╭' TR='╮' BL='╰' BR='╯' V='│' H='─' ML='├' MR='┤' FULL='━' EMPTY='┄'
  if ((ASCII)); then
    TL='+' TR='+' BL='+' BR='+' V='|' H='-' ML='+' MR='+' FULL='#' EMPTY='-'
  fi
}

# Ubah data eksternal menjadi ASCII aman: cegah escape terminal dan lebar ambigu.
# Hasil dikembalikan lewat REPLY agar tidak perlu fork per sel tabel.
safe_text() {
  local LC_ALL=C text=${1:-} limit=${2:-200}
  text=${text//[! -~]/?}
  if ((${#text} > limit)); then text=${text:0:limit-1}'~'; fi
  REPLY=$text
}

system_info() {
  local key value
  host=$(hostname 2>/dev/null) || host=unknown
  kernel=$(uname -sr 2>/dev/null) || kernel=unknown
  arch=$(uname -m 2>/dev/null) || arch=unknown
  os='Linux (OS tidak diketahui)'
  if [[ -r /etc/os-release ]]; then
    while IFS='=' read -r key value; do
      if [[ $key == PRETTY_NAME ]]; then
        value=${value#\"}; value=${value%\"}; os=$value; break
      fi
    done < /etc/os-release
  fi
  safe_text "$host"; host=$REPLY
  safe_text "$kernel"; kernel=$REPLY
  safe_text "$os"; os=$REPLY
  cores=0; cpu_model='Linux processor'
  if [[ -r /proc/cpuinfo ]]; then
    while IFS=':' read -r key value; do
      case "$key" in
        processor*) ((cores+=1)) ;;
        'model name'*) cpu_model=${value# } ;;
      esac
    done < /proc/cpuinfo
  fi
  ((cores > 0)) || cores=1
  safe_text "$cpu_model"; cpu_model=$REPLY
}

# guest/guest_nice sudah termasuk dalam user/nice: jangan dihitung dua kali.
cpu_sample() {
  local label user nice sys idle iowait irq softirq steal rest
  local total idle_all delta_total delta_idle
  cpu_ok=0
  read -r label user nice sys idle iowait irq softirq steal rest < /proc/stat || return 1
  [[ $label == cpu && $user =~ ^[0-9]+$ && $idle =~ ^[0-9]+$ ]] || return 1
  total=$((user + nice + sys + idle + iowait + irq + softirq + steal))
  idle_all=$((idle + iowait))
  if ((prev_total > 0)); then
    delta_total=$((total - prev_total)); delta_idle=$((idle_all - prev_idle))
    if ((delta_total > 0 && delta_idle >= 0)); then
      cpu_tenths=$((1000 * (delta_total - delta_idle) / delta_total))
      ((cpu_tenths < 0)) && cpu_tenths=0
      ((cpu_tenths > 1000)) && cpu_tenths=1000
      cpu_pct=$((cpu_tenths / 10)); cpu_ok=1
    fi
  fi
  prev_total=$total; prev_idle=$idle_all
  printf -v cpu_display '%d.%d' "$((cpu_tenths / 10))" "$((cpu_tenths % 10))"
  return 0
}

mem_values() {
  local key value unit free=0 buffers=0 cached=0 reclaimable=0 shmem=0 available=-1
  mem_total=0; swap_total=0; swap_free=0; mem_ok=0
  while read -r key value unit; do
    case "$key" in
      MemTotal:) mem_total=$value ;; MemAvailable:) available=$value ;;
      MemFree:) free=$value ;; Buffers:) buffers=$value ;; Cached:) cached=$value ;;
      SReclaimable:) reclaimable=$value ;; Shmem:) shmem=$value ;;
      SwapTotal:) swap_total=$value ;; SwapFree:) swap_free=$value ;;
    esac
  done < /proc/meminfo
  ((available >= 0)) || available=$((free + buffers + cached + reclaimable - shmem))
  ((available < 0)) && available=0
  ((available > mem_total)) && available=$mem_total
  mem_avail=$available; mem_used=$((mem_total - mem_avail))
  ram_pct=0; ram_tenths=0
  if ((mem_total > 0)); then
    ram_tenths=$((1000 * mem_used / mem_total)); ram_pct=$((ram_tenths / 10)); mem_ok=1
  fi
  swap_used=$((swap_total - swap_free)); swap_pct=0
  ((swap_total > 0)) && swap_pct=$((100 * swap_used / swap_total))
  printf -v ram_display '%d.%d' "$((ram_tenths / 10))" "$((ram_tenths % 10))"
  mem_total_mib=$((mem_total / 1024)); mem_used_mib=$((mem_used / 1024)); mem_avail_mib=$((mem_avail / 1024))
  return 0
}

# Satu df per snapshot, semua entri (termasuk tmpfs); tidak dibatasi head.
root_values() {
  local output line source size used avail pct mount rest
  disks=(); disk_ok=0; disk_pct=0; disk_total='N/A'; disk_used='N/A'; disk_avail='N/A'
  if output=$(df -hP 2>/dev/null); then disk_ok=1; fi
  while IFS= read -r line; do
    [[ $line == Filesystem* || -z $line ]] && continue
    read -r source size used avail pct mount <<< "$line"
    [[ $pct =~ ^[0-9]+%$ ]] || continue
    safe_text "$line" 4096; disks+=("$REPLY")
    if [[ $mount == / ]]; then
      disk_pct=${pct%%%}; disk_total=$size; disk_used=$used; disk_avail=$avail
    fi
  done <<< "$output"
  ((${#disks[@]} > 0)) || disk_ok=0
  return 0
}

process_values() {
  local output pid state cpu mem name
  processes=(); process_count=0; running_count=0; proc_ok=0
  if ! output=$(ps -eo pid=,stat=,pcpu=,pmem=,comm= --sort=-pcpu 2>/dev/null); then return 1; fi
  while read -r pid state cpu mem name; do
    [[ $pid =~ ^[0-9]+$ ]] || continue
    ((process_count+=1))
    [[ $state == R* ]] && ((running_count+=1))
    if ((${#processes[@]} < 5)); then
      safe_text "$name" 200
      processes+=("$pid $state $cpu $mem $REPLY")
    fi
  done <<< "$output"
  proc_ok=1
}

collect_metrics() {
  local up unused l1 l5 l15
  cpu_sample || true
  mem_values
  root_values
  process_values || true
  read -r up unused < /proc/uptime
  up=${up%%.*}
  printf -v uptime_text '%dd %02d:%02d:%02d' "$((up / 86400))" "$((up / 3600 % 24))" "$((up / 60 % 60))" "$((up % 60))"
  read -r l1 l5 l15 unused < /proc/loadavg
  load_text="$l1 / $l5 / $l15"
  printf -v timestamp '%(%Y-%m-%d %H:%M:%S %z)T' -1
  ((sample_number+=1))
  cpu_history+=("$cpu_pct"); ram_history+=("$ram_pct")
  ((${#cpu_history[@]} <= 120)) || cpu_history=("${cpu_history[@]: -120}")
  ((${#ram_history[@]} <= 120)) || ram_history=("${ram_history[@]: -120}")
}

snapshot_text() {
  local item pid state cpu mem name
  printf '\n=== NEONPULSE SNAPSHOT %s ===\n' "$timestamp"
  printf 'Hostname: %s\nOS: %s\nKernel: %s | Architecture: %s\n' "$host" "$os" "$kernel" "$arch"
  printf 'Uptime: %s | Load average (1/5/15m): %s\n' "$uptime_text" "$load_text"
  printf 'CPU: %s%% | Logical CPUs: %s | Valid sample: %s\n' "$cpu_display" "$cores" "$cpu_ok"
  printf 'RAM: %s/%s MiB (%s%%) | Available: %s MiB | Valid sample: %s\n' "$mem_used_mib" "$mem_total_mib" "$ram_display" "$mem_avail_mib" "$mem_ok"
  printf 'Swap: %s/%s MiB\n' "$((swap_used / 1024))" "$((swap_total / 1024))"
  printf 'Root disk: %s%% (%s/%s) | Valid df: %s\n' "$disk_pct" "$disk_used" "$disk_total" "$disk_ok"
  printf 'Process count (all): %s | Running (R): %s | Valid ps: %s\n' "$process_count" "$running_count" "$proc_ok"
  printf 'All filesystems (%s):\n' "${#disks[@]}"
  printf 'Filesystem Size Used Available Use%% Mounted on\n'
  for item in "${disks[@]}"; do printf '%s\n' "$item"; done
  printf 'Top 5 CPU processes (ps %%CPU: lifetime average, not interval):\n'
  printf '%8s %-24s %8s %8s %s\n' PID PROCESS CPU% MEM% STATE
  for item in "${processes[@]}"; do
    read -r pid state cpu mem name <<< "$item"
    printf '%8s %-24s %8s %8s %s\n' "$pid" "$name" "$cpu" "$mem" "$state"
  done
  printf '=== END SNAPSHOT ===\n'
}

# flock melindungi append dan rotasi antar-instance. Batas diterapkan sebelum append.
# Jika satu snapshot lebih besar dari batas, simpan utuh dan rotasi pada append berikutnya.
write_log() {
  local payload bytes current=0 i lock_fd result=0
  log_error=''
  payload=$(snapshot_text)
  bytes=$(LC_ALL=C printf '%s\n' "$payload" | wc -c)
  if ! mkdir -p -- "$SCRIPT_DIR/logs"; then log_error='Direktori log tidak dapat dibuat'; return 1; fi
  if ! { exec {lock_fd}>>"$SCRIPT_DIR/logs/.monitor.lock"; }; then
    log_error='Lock log tidak dapat dibuka'; return 1
  fi
  if ! flock -w 2 "$lock_fd"; then
    exec {lock_fd}>&-; log_error='Log sibuk (lock timeout)'; return 1
  fi
  if [[ -f $LOG_FILE ]]; then
    current=$(wc -c < "$LOG_FILE") || result=1
  fi
  if ((result == 0 && current > 0 && current + bytes > LOG_MAX_BYTES)); then
    for ((i=LOG_KEEP-1; i>=1; i--)); do
      if [[ -e $LOG_FILE.$i ]]; then
        mv -f -- "$LOG_FILE.$i" "$LOG_FILE.$((i+1))" || { result=1; break; }
      fi
    done
    if ((result == 0)); then mv -f -- "$LOG_FILE" "$LOG_FILE.1" || result=1; fi
  fi
  if ((result == 0)); then
    printf '%s\n' "$payload" >> "$LOG_FILE" || result=1
  fi
  flock -u "$lock_fd" || true
  exec {lock_fd}>&-
  if ((result)); then log_error='Gagal menulis atau merotasi log'; return 1; fi
  return 0
}

# Renderer dua kolom: setiap sel membawa lebar eksplisit, bukan panjang ANSI.
# Riwayat hanya berisi sampel aktual; ruang kosong bukan nilai monitoring palsu.
history_line() {
  local kind=$1 length=$2 value index char result='' i start
  local -a values=() levels=('▁' '▂' '▃' '▄' '▅' '▆' '▇' '█')
  [[ $kind == cpu ]] && values=("${cpu_history[@]}") || values=("${ram_history[@]}")
  ((ASCII)) && levels=('.' ':' '-' '=' '+' '*' '#' '@')
  start=$((${#values[@]} - length)); ((start >= 0)) || start=0
  for ((i=start; i<${#values[@]}; i++)); do
    value=${values[i]}; index=$((value * 7 / 100)); result+=${levels[index]}
  done
  printf -v REPLY '%*s%s' "$((length - ${#result}))" '' "$result"
}

panel_edge() {
  local size=$1 title=$2 color=$3 bottom=${4:-0} line left=$TL right=$TR
  if ((bottom)); then left=$BL; right=$BR; title=''; fi
  ((size > 0)) || return
  if [[ -n $title ]]; then
    safe_text " $title " "$((size-4))"; title=$REPLY
    repeat_char "$H" "$((size - 3 - ${#title}))"; line=$REPLY
    printf '%s%s%s%s%s%s%s%s' "$color" "$left" "$H" "$BOLD" "$title" "$RESET$color" "$line" "$right"
  else
    repeat_char "$H" "$((size-2))"
    printf '%s%s%s%s' "$color" "$left" "$REPLY" "$right"
  fi
  printf '%s' "$RESET"
}

panel_cell() {
  local size=$1 text=$2 accent=$3 ink=${4:-$WHITE} raw=${5:-0}
  if ((raw == 0)); then safe_text "$text" "$((size-4))"; text=$REPLY; fi
  printf '%s%s%s %s%-*s%s %s%s%s' "$accent" "$V" "$RESET" "$ink" "$((size-4))" "$text" "$RESET" "$accent" "$V" "$RESET"
}

pair_text() {
  panel_cell "$left_width" "$1" "$CYAN" "${3:-$WHITE}" "${5:-0}"
  printf ' '
  panel_cell "$right_width" "$2" "$PINK" "${4:-$WHITE}" "${5:-0}"
  printf '\n'
}

pair_edge() {
  panel_edge "$left_width" "$1" "$CYAN" "${3:-0}"
  printf ' '
  panel_edge "$right_width" "$2" "$PINK" "${3:-0}"
  printf '\n'
}

panel_meter() {
  local size=$1 label=$2 pct=$3 number=$4 accent=$5 valid=$6 length
  status_style "$pct" "$accent" "$valid"
  ((valid)) || number='N/A'
  length=$((size - 24))
  printf '%s%s%s %s%-4s %6s%% ' "$accent" "$V" "$RESET" "$WHITE" "$label" "$number"
  bar "$pct" "$length" "$BAR_COLOR"
  printf ' %s%5s%s %s%s%s' "$WHITE" "$([[ $STATUS == OK ]] && printf OK || { ((valid)) && printf ALERT || printf N/A; })" "$RESET" "$accent" "$V" "$RESET"
}

navigation() {
  local target label total=0 token pad selected=$page
  printf '%s%s%s ' "$PURPLE" "$V" "$RESET"
  for target in all cpu ram disk proc help; do
    case "$target" in
      all) label='0 HOME' ;; cpu) label='1 CPU' ;; ram) label='2 RAM' ;;
      disk) label='3 DISK' ;; proc) label='4 PROC' ;; help) label='H HELP' ;;
    esac
    token=" $label "
    if [[ $target == "$selected" ]]; then
      printf '%s%s%s%s' "$BOLD" "$CYAN" "$token" "$RESET"
    else printf '%s%s%s' "$DIM" "$token" "$RESET"; fi
    total=$((total + ${#token}))
  done
  token=' L LOG  Q QUIT'; printf '%s%s%s' "$WHITE" "$token" "$RESET"
  total=$((total + ${#token})); pad=$((inner-total))
  printf '%*s %s%s%s\n' "$pad" '' "$PURPLE" "$V" "$RESET"
}

wide_dashboard() {
  local left_width=$(((width-1)/2)) right_width=$((width-1-(width-1)/2))
  local left right i item source size used avail pct mount pid state cpu mem name
  local capacity=5 pages=$(((${#disks[@]}+4)/5)) start lhist rhist
  ((pages > 0)) || pages=1
  start=$((disk_page*capacity))
  pair_edge '01 CPU // CORE MONITOR' '02 RAM // MEMORY BANK'
  panel_meter "$left_width" CPU "$cpu_pct" "$cpu_display" "$CYAN" "$cpu_ok"
  printf ' '
  panel_meter "$right_width" RAM "$ram_pct" "$ram_display" "$PINK" "$mem_ok"
  printf '\n'
  pair_text "Load: $load_text" "Used: $mem_used_mib / $mem_total_mib MiB"
  pair_text "CPU logis: $cores | $STATUS" "Available: $mem_avail_mib MiB"
  pair_text 'HISTORY // 0 - 100% / oldest -> newest' 'HISTORY // 0 - 100% / oldest -> newest' "$DIM" "$DIM"
  history_line cpu "$((left_width-4))"; lhist=$REPLY
  history_line ram "$((right_width-4))"; rhist=$REPLY
  pair_text "$lhist" "$rhist" "$CYAN" "$PINK" 1
  pair_text "$cpu_model" "Swap: $((swap_used/1024)) / $((swap_total/1024)) MiB" "$DIM" "$DIM"
  pair_edge '' '' 1
  pair_edge '03 DISK ARRAY / FILESYSTEMS' '04 PROCESS GRID / TOP CPU'
  pair_text "ROOT $disk_pct% | $disk_used / $disk_total" "TOTAL $process_count | RUNNING $running_count"
  pair_text "Mount               Used/Size   Use%" '    PID PROCESS            CPU%   MEM%' "$DIM" "$DIM"
  for ((i=0; i<5; i++)); do
    left=''; right=''
    if ((start+i < ${#disks[@]})); then
      item=${disks[start+i]}; read -r source size used avail pct mount <<< "$item"
      safe_text "$mount" "$((left_width-27))"; mount=$REPLY
      printf -v left '%-*s %5s/%-5s %4s' "$((left_width-27))" "$mount" "$used" "$size" "$pct"
    fi
    if ((i < ${#processes[@]})); then
      read -r pid state cpu mem name <<< "${processes[i]}"
      safe_text "$name" "$((right_width-29))"; name=$REPLY
      printf -v right '%7s %-*s %6s %6s' "$pid" "$((right_width-29))" "$name" "$cpu" "$mem"
    fi
    pair_text "$left" "$right" "$WHITE" "$WHITE"
  done
  pair_text "[$((disk_page+1))/$pages] [ / ] halaman disk | 3 detail" 'CPU% ps = rata-rata umur proses' "$DIM" "$DIM"
  pair_edge '' '' 1
}

# Utilitas UI: setiap baris mempunyai lebar terlihat yang dibatasi.
repeat_char() {
  local char=$1 count=$2 out
  printf -v out '%*s' "$count" ''
  REPLY=${out// /$char}
}

border() {
  local left=$1 right=$2
  repeat_char "$H" "$((width - 2))"
  printf '%s%s%s%s%s' "$PURPLE" "$left" "$REPLY" "$right" "$RESET"
  [[ ${3:-newline} == newline ]] && printf '\n'
  return 0
}

row() {
  local text=$1 style=${2:-$WHITE}
  safe_text "$text" "$inner"; text=$REPLY
  printf '%s%s%s %s%-*s%s %s%s%s\n' "$PURPLE" "$V" "$RESET" "$style" "$inner" "$text" "$RESET" "$PURPLE" "$V" "$RESET"
}

section() {
  border "$ML" "$MR"
  row "$1" "$BOLD$WHITE"
}

status_style() {
  local pct=$1 normal=$2 valid=${3:-1}
  STATUS='OK'; BAR_COLOR=$normal
  if ((valid == 0)); then STATUS='N/A'; BAR_COLOR=$DIM
  elif ((pct >= CRIT)); then STATUS='!! KRITIS'; BAR_COLOR=$RED
  elif ((pct >= WARN)); then STATUS='! WASPADA'; BAR_COLOR=$YELLOW
  fi
}

bar() {
  local pct=${1:-0} length=${2:-20} color=${3:-$CYAN} count filled empty
  ((pct < 0)) && pct=0
  ((pct > 100)) && pct=100
  count=$((pct * length / 100))
  repeat_char "$FULL" "$count"; filled=$REPLY
  repeat_char "$EMPTY" "$((length - count))"; empty=$REPLY
  printf '%s%s%s%s%s' "$color" "$filled" "$DIM" "$empty" "$RESET"
}

meter_row() {
  local label=$1 pct=$2 number=$3 normal=$4 valid=$5 prefix suffix used
  status_style "$pct" "$normal" "$valid"
  ((valid)) || number='N/A'
  printf -v prefix ' %-7s %6s%%  ' "$label" "$number"
  printf -v suffix '  %-10s' "$STATUS"
  used=$((${#prefix} + bar_width + ${#suffix}))
  printf '%s%s%s %s%s' "$PURPLE" "$V" "$RESET" "$WHITE" "$prefix"
  bar "$pct" "$bar_width" "$BAR_COLOR"
  printf '%s%s%*s %s%s%s\n' "$WHITE" "$suffix" "$((inner - used))" '' "$PURPLE" "$V" "$RESET"
}

cpu_view() {
  row '01 // CPU CORE MONITOR' "$BOLD$WHITE"
  meter_row CPU "$cpu_pct" "$cpu_display" "$CYAN" "$cpu_ok"
  row "Load 1/5/15m: $load_text | CPU logis: $cores"
}

ram_view() {
  row '02 // MEMORY BANK' "$BOLD$WHITE"
  meter_row RAM "$ram_pct" "$ram_display" "$PINK" "$mem_ok"
  row "Used $mem_used_mib / $mem_total_mib MiB | Available $mem_avail_mib MiB"
}

disk_view() {
  local capacity=$1 start end i item source size used avail pct mount pages text
  section '03 // DISK ARRAY / FILESYSTEMS'
  meter_row ROOT "$disk_pct" "$disk_pct" "$CYAN" "$disk_ok"
  pages=$(( (${#disks[@]} + capacity - 1) / capacity )); ((pages > 0)) || pages=1
  ((disk_page < pages)) || disk_page=$((pages - 1))
  ((disk_page >= 0)) || disk_page=0
  start=$((disk_page * capacity)); end=$((start + capacity))
  row "Filesystem             Used/Size    Use%  Mount  [$((disk_page+1))/$pages] [ / ]" "$DIM"
  for ((i=start; i<end; i++)); do
    if ((i < ${#disks[@]})); then
      item=${disks[i]}
      read -r source size used avail pct mount <<< "$item"
      safe_text "$source" 22; source=$REPLY
      printf -v text '%-22s %5s/%-5s %4s  %s' "$source" "$used" "$size" "$pct" "$mount"
      status_style "${pct%%%}" "$WHITE"
      row "$text" "$BAR_COLOR"
    else
      row ''
    fi
  done
}

proc_view() {
  local item pid state cpu mem name text i
  section "04 // PROCESS GRID / TOTAL $process_count | RUNNING $running_count"
  row '     PID  PROCESS                       CPU%    MEM%  STATE' "$DIM"
  for ((i=0; i<5; i++)); do
    if ((i < ${#processes[@]})); then
      item=${processes[i]}; read -r pid state cpu mem name <<< "$item"
      safe_text "$name" 26; name=$REPLY
      printf -v text '%8s  %-26s %7s %7s  %s' "$pid" "$name" "$cpu" "$mem" "$state"
      row "$text"
    else row ''; fi
  done
}

help_view() {
  section 'HELP // OPERATOR MANUAL'
  row '[0] Dashboard   [1] CPU   [2] RAM   [3] Disk   [4] Proses'
  row '[L] Simpan snapshot   [H] Bantuan   [Q] Keluar'
  row '[ atau ] Halaman filesystem sebelumnya / berikutnya'
  row "Refresh ${REFRESH}s | Log otomatis ${LOG_INTERVAL}s (juga saat mulai)"
  row "Status: OK < $WARN% | ! WASPADA >= $WARN% | !! KRITIS >= $CRIT%"
  row 'CPU: selisih /proc/stat; idle termasuk iowait.'
  row 'RAM used = MemTotal - MemAvailable; satuan MiB.'
  row 'Proses: ps %CPU adalah rata-rata sepanjang umur proses.'
  row 'Total = semua proses; RUNNING = state R saat sampling.'
  row 'Disk: df -hP, termasuk tmpfs; tidak ada filter filesystem.'
  row 'Snapshot/log memuat SEMUA filesystem, bukan hanya halaman ini.'
  row "Rotasi log: ${LOG_MAX_BYTES} bytes, ${LOG_KEEP} arsip."
  row 'Q / Ctrl-C memulihkan echo, cursor, dan layar terminal.'
}

terminal_size() {
  local size
  size=$(stty size 2>/dev/null) || size='0 0'
  read -r rows cols <<< "$size"
  [[ $rows =~ ^[0-9]+$ && $cols =~ ^[0-9]+$ ]] || { rows=0; cols=0; }
  width=$((cols - 1)); ((width <= 120)) || width=120
  inner=$((width - 4))
  bar_width=$((inner - 39)); ((bar_width <= 54)) || bar_width=54
}

render_dashboard() {
  local capacity=2
  printf '\033[H'
  if ((cols < 76 || rows < 30)); then
    printf '\033[2J\033[HNEONPULSE\nTerminal terlalu kecil: %sx%s.\nMinimal 76 kolom x 30 baris.\nPerbesar terminal; Q keluar, L simpan log.\n' "$cols" "$rows"
    return
  fi
  border "$TL" "$TR"
  row 'N E O N P U L S E   //   SYSTEM ONLINE' "$BOLD$WHITE"
  row "$timestamp | HOST: $host"
  row "OS: $os | $arch"
  row "KERNEL: $kernel | UP: $uptime_text"
  case "$page" in
    all)
      cpu_view; ram_view; disk_view 2; proc_view
      ;;
    cpu)
      cpu_view
      row "Model: $cpu_model"
      row 'Sampling /proc/stat: (delta total - delta idle) / delta total.' "$DIM"
      proc_view
      ;;
    ram)
      ram_view
      row "Swap: $((swap_used/1024)) / $((swap_total/1024)) MiB ($swap_pct%)"
      row 'MemAvailable mencakup memori yang dapat direklamasi kernel.' "$DIM"
      ;;
    disk)
      capacity=$((rows - 16)); ((capacity > 100)) && capacity=100
      disk_view "$capacity"
      row "Root: $disk_used / $disk_total | Available: $disk_avail"
      ;;
    proc)
      proc_view
      row 'CPU% ps = rata-rata umur proses; dapat >100% pada multicore.' "$DIM"
      ;;
    help) help_view ;;
  esac
  border "$ML" "$MR"
  row '[0] HOME  [1] CPU  [2] RAM  [3] DISK  [4] PROC  [L] LOG' "$WHITE"
  row "[H] HELP  [Q] QUIT  [ / ] DISK PAGE | ${REFRESH}s LIVE / ${LOG_INTERVAL}s LOG" "$DIM"
  if ((cpu_ok == 0 || mem_ok == 0 || disk_ok == 0 || proc_ok == 0)); then
    row '!! Data tidak lengkap: periksa CPU/RAM/df/ps; lihat --once.' "$YELLOW"
  else
    row "$notice" "$DIM"
  fi
  border "$BL" "$BR" no-newline
  printf '\033[J'
}

cleanup() {
  local status=$?
  trap - EXIT
  if ((terminal_active)); then
    stty "$saved_stty" 2>/dev/null || true
    printf '\033[0m\033[?25h\033[?1049l'
    terminal_active=0
  fi
  return "$status"
}

start_terminal() {
  saved_stty=$(stty -g) || return 1
  trap cleanup EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM
  trap 'exit 129' HUP
  trap 'resize_pending=1' WINCH
  terminal_active=1
  stty -echo -icanon min 1 time 0 || return 1
  printf '\033[?1049h\033[?25l\033[2J\033[H'
}

interactive_loop() {
  local key frame next_refresh next_log dirty=1
  start_terminal || return 1
  terminal_size
  next_refresh=$((SECONDS + REFRESH)); next_log=$((SECONDS + LOG_INTERVAL))
  while true; do
    if ((SECONDS >= next_refresh)); then
      collect_metrics
      next_refresh=$((SECONDS + REFRESH)); dirty=1
    fi
    if ((SECONDS >= next_log)); then
      if write_log; then notice="AUTO LOG tersimpan: $timestamp"; else notice="! $log_error"; fi
      next_log=$((SECONDS + LOG_INTERVAL)); dirty=1
    fi
    if ((resize_pending)); then
      terminal_size; resize_pending=0; dirty=1
      printf '\033[2J'
    fi
    if ((dirty)); then
      local capacity=2 pages
      if [[ $page == disk ]]; then
        capacity=$((rows - 16)); ((capacity >= 1)) || capacity=1
        ((capacity <= 100)) || capacity=100
      fi
      pages=$(( (${#disks[@]} + capacity - 1) / capacity )); ((pages > 0)) || pages=1
      ((disk_page < pages)) || disk_page=$((pages - 1))
      ((disk_page >= 0)) || disk_page=0
      frame=$(render_dashboard)
      printf '%s' "$frame"
      dirty=0
    fi
    key=''
    if IFS= read -rsn1 -t 0.15 key; then
      case "$key" in
        0) page=all; dirty=1 ;;
        1) page=cpu; dirty=1 ;;
        2) page=ram; dirty=1 ;;
        3) page=disk; disk_page=0; dirty=1 ;;
        4) page=proc; dirty=1 ;;
        h|H) page=help; dirty=1 ;;
        '[') ((disk_page > 0)) && ((disk_page-=1)); dirty=1 ;;
        ']') ((disk_page+=1)); dirty=1 ;;
        l|L)
          if write_log; then notice="MANUAL LOG tersimpan: $timestamp"; else notice="! $log_error"; fi
          dirty=1 ;;
        q|Q) return 0 ;;
      esac
    else
      # EOF (bukan timeout) berarti terminal input ditutup: hindari busy loop.
      (($? > 128)) || return 0
    fi
  done
}

main() {
  local initial_log_status=0 source_path=${BASH_SOURCE[0]}
  parse_args "$@"
  check_environment || return 1
  [[ $source_path == */* ]] && source_path=${source_path%/*} || source_path=.
  SCRIPT_DIR=$(cd -- "$source_path" && pwd -P) || return 1
  LOG_FILE="$SCRIPT_DIR/logs/monitor.log"
  setup_style
  system_info
  cpu_sample
  sleep 0.2
  collect_metrics
  if [[ $MODE == once ]]; then snapshot_text; return 0; fi
  if write_log; then
    notice="Log awal tersimpan: $timestamp"
  else
    initial_log_status=1; notice="! $log_error"
    printf '%s\n' "$notice" >&2
  fi
  if [[ $MODE == snapshot ]]; then snapshot_text; return "$initial_log_status"; fi
  interactive_loop
}

# Guard memungkinkan fungsi diuji menggunakan source tanpa menjalankan dashboard.
if [[ ${BASH_SOURCE[0]} == "$0" ]]; then main "$@"; fi
