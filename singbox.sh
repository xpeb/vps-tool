#!/usr/bin/env bash
# singbox.sh — sing-box 服务端面板 (Debian系 / Alpine)
# 协议: Shadowsocks · VLESS · VMess · Hysteria2 · AnyTLS · Snell v6
# ShadowTLS 作为 Shadowsocks 插件，不是独立协议
set -u
set -o pipefail
export LANG=C.UTF-8 LC_ALL=C.UTF-8
umask 077

SINGBOX_BIN="/usr/local/bin/sing-box"
SINGBOX_SELF="/usr/local/bin/singbox"
CONF_DIR="/etc/sing-box"
CONF="$CONF_DIR/config.json"
META="$CONF_DIR/meta.json"
KEYS="$CONF_DIR/keys.json"
CERT_DIR="$CONF_DIR/cert"
LOCK_FILE="$CONF_DIR/.lock"
LOG_FILE="/var/log/sing-box.log"
SVC_USER="sing-box"
MIN_SNELL="1.14.0"
MIN_ANYTLS="1.12.0"
GH_REPO="SagerNet/sing-box"
STABLE_FALLBACK="v1.14.1"
# 服务定义版本。改 init 脚本或 /etc/conf.d/sing-box 时 +1，
# 面板据此刷新旧服务，避免升级后旧脚本与新逻辑互相打架。
SVC_FILES_V=2
SVC_GRP=""
# 仪表盘缓存（必须在当前 shell 赋值；命令替换中的赋值不会保留）
CACHE_SBVER=""; CACHE_SBVER_MT=""; CACHE_NC=""; CACHE_NC_MT=""; CACHE_CPU=""; IP_LINE=""
# 编辑事务进行中（供 EXIT trap 判断是否需要回滚）
EDIT_ACTIVE=""
# 含密钥/证书的临时目录；退出时统一清理，避免中断残留
TMP_CLEANUP=()
# 管道安装时从该地址回源；export SINGBOX_URL 可覆盖（不走镜像前缀）
SINGBOX_SRC_URL="https://raw.githubusercontent.com/1x2345/proxy/refs/heads/main/shell/singbox.sh"
# 空前缀为直连，其后为 GitHub 镜像
GH_MIRROR_PREFIXES=("" "https://ghfast.top/" "https://ghproxy.net/")

if [[ -t 1 && "${NO_COLOR:-}" != "1" ]]; then
  C0='\033[0m'; CB='\033[1m'; CD='\033[2m'
  CR='\033[31m'; CG='\033[32m'; CC='\033[36m'
  CBC='\033[96m'
else
  C0=''; CB=''; CD=''; CR=''; CG=''; CC=''; CBC=''
fi

die()  { printf "${CR}[错误] %s${C0}\n" "$*" >&2; exit 1; }
ok()   { printf "${CG}[正确] %s${C0}\n" "$*"; }
err()  { printf "${CR}[错误] %s${C0}\n" "$*" >&2; }
note() { printf "${CC}[信息] %s${C0}\n" "$*" >&2; }
hold() { sleep 0.25; }

# ---------- 基础工具 ----------

listen_addr() {
  if [[ -n "${LISTEN_ADDR:-}" ]]; then
    printf '%s' "$LISTEN_ADDR"
    return
  fi
  local v
  v=$(cat /proc/sys/net/ipv6/conf/all/disable_ipv6 2>/dev/null || printf '1')
  LISTEN_ADDR=$([[ "$v" == 0 ]] && printf '::' || printf '0.0.0.0')
  printf '%s' "$LISTEN_ADDR"
}

# IPv6 主机在 URI 里必须带方括号
hp() {
  local h=$1 p=$2
  if [[ "$h" == *:* && "$h" != \[* ]]; then
    printf '[%s]:%s' "$h" "$p"
  else
    printf '%s:%s' "$h" "$p"
  fi
}

yaml_host() {
  local h=$1
  if [[ "$h" == *:* ]]; then printf '"%s"' "$h"; else printf '%s' "$h"; fi
}

# 双引号 YAML 标量，避免 name/密码破坏结构
yaml_str() {
  jq -nr --arg s "$1" '"\"" + ($s | gsub("\\\\";"\\\\") | gsub("\"";"\\\"") | gsub("\n";"\\n")) + "\""'
}

# 布尔字面量（YAML / JSON）
yaml_bool() { [[ "${1-}" == 1 || "${1-}" == true ]] && printf true || printf false; }
curl_secure() { curl --proto '=https' --tlsv1.2 "$@"; }

# 服务用户主组（Alpine 可能不是同名组）
svc_group() {
  if id "$SVC_USER" >/dev/null 2>&1; then
    id -gn "$SVC_USER" 2>/dev/null || printf '%s' "$SVC_USER"
  else
    printf '%s' "$SVC_USER"
  fi
}

chown_svc() {
  id "$SVC_USER" >/dev/null 2>&1 || return 0
  local g
  g=$(svc_group)
  chown -R "$SVC_USER:$g" "$@" 2>/dev/null || true
}

cache_bust() {
  # 只清与配置/内核相关的缓存；公网 IP 与配置无关，保留缓存，
  # 免得每次改配置都重新发起外网查询（无外网时每次数秒卡顿）。
  CACHE_SBVER="" CACHE_SBVER_MT=""
  CACHE_NC="" CACHE_NC_MT=""
}

jq_write() {
  local file=$1 tmp
  shift
  # 临时文件必须与目标同目录：跨文件系统 mv 会退化为复制+删除，
  # 复制途中被打断会留下截断的 config.json。
  tmp=$(mktemp "$file.tmp.XXXXXX" 2>/dev/null) || return 1
  if jq "$@" "$file" > "$tmp" && [[ -s "$tmp" ]] && mv -f "$tmp" "$file"; then
    chmod 600 "$file" 2>/dev/null || true
    chown root:root "$file" 2>/dev/null || true
    harden_perms
    cache_bust
    return 0
  fi
  rm -f "$tmp"
  return 1
}

need_root() { [[ $(id -u) -eq 0 ]] || die "请用 root 运行：sudo bash $0"; }

disp_w() {
  local s=${1-} i c w=0 n
  n=${#s}
  for ((i=0;i<n;i++)); do
    c="${s:i:1}"
    if [[ "$c" = [[:ascii:]] ]]; then
      ((w++)) || true
    else
      ((w+=2)) || true
    fi
  done
  printf '%s' "$w"
}

pad_r() {
  local s=$1 w=$2 dw pad
  dw=$(disp_w "$s")
  pad=$(( w - dw ))
  (( pad < 0 )) && pad=0
  printf '%s%*s' "$s" "$pad" ''
}

hline() {
  local n=${1:-0}
  (( n < 1 )) && return
  printf '%*s' "$n" '' | tr ' ' '-'
}

term_cols() {
  local w=""
  if [[ -t 1 ]]; then
    w=$(stty size 2>/dev/null | awk '{print $2}')
  fi
  [[ -z "$w" || "$w" -lt 1 ]] && w=${COLUMNS:-0}
  [[ -z "$w" || "$w" -lt 1 ]] && w=$(tput cols 2>/dev/null || true)
  [[ -z "$w" || "$w" -lt 1 ]] && w=80
  printf '%s' "$w"
}

trunc_disp() {
  local s=${1-} max=${2-0} i c cw w=0 out="" n
  n=${#s}
  (( max < 1 )) && { printf ''; return; }
  for ((i=0;i<n;i++)); do
    c="${s:i:1}"
    if [[ "$c" = [[:ascii:]] ]]; then cw=1; else cw=2; fi
    if (( w + cw > max )); then
      (( w < max )) && out+="~"
      printf '%s' "$out"
      return
    fi
    out+=$c
    ((w+=cw)) || true
  done
  printf '%s' "$out"
}

UI_IK=(); UI_IV=(); UI_MK=(); UI_ML=()
UI_PROMPT_R=0
col_w=()

ui_reset() { UI_IK=(); UI_IV=(); UI_MK=(); UI_ML=(); }

ui_info() { UI_IK+=("$1"); UI_IV+=("$2"); }

ui_menu() { UI_MK+=("$1"); UI_ML+=("$2"); }

svc_label() {
  case "$(svc_state)" in
    running) printf '运行中' ;;
    stopped) printf '已停止' ;;
    failed) printf '失败' ;;
    starting) printf '启动中' ;;
    stopping) printf '停止中' ;;
    *) printf '未安装' ;;
  esac
}

ui_fill_info() {
  [[ -n "${CACHE_HOST:-}" ]] || CACHE_HOST=$(hostname)
  cap_lines
  # 直接调用（而非 $( )）：让缓存留在当前 shell；各 *_refresh 自带新鲜度判断
  cpu_line_refresh
  sb_version_refresh
  node_count_refresh
  ip_line_refresh
  ui_info "主机名" "$CACHE_HOST"
  ui_info "系统" "$OS_PRETTY"
  ui_info "CPU" "$CACHE_CPU"
  ui_info "内存" "$CAP_MEM"
  ui_info "磁盘" "$CAP_DISK"
  ui_info "内核" "$CACHE_SBVER"
  ui_info "服务" "$(svc_label)"
  ui_info "节点" "$CACHE_NC"
  ui_info "IP" "$IP_LINE"
}

ui_sep() {
  printf "${CD}+%s+%s+${C0}\033[K\n" "$(hline "$1")" "$(hline "$2")"
}

ui_menu_widths() {
  local cols=$1 n=${#UI_MK[@]} c i dwm gap=2
  col_w=()
  MENU_DW=4
  for ((c=0;c<cols;c++)); do col_w[c]=0; done
  for ((i=0;i<n;i++)); do
    c=$((i % cols))
    dwm=$(disp_w "${UI_MK[i]} ${UI_ML[i]}")
    (( dwm > col_w[c] )) && col_w[c]=$dwm
  done
  for ((c=0;c<cols;c++)); do
    (( c < cols - 1 )) && (( col_w[c] += gap ))
    (( col_w[c] < 1 )) && col_w[c]=1
    MENU_DW=$((MENU_DW + col_w[c]))
  done
}

ui_render() {
  local cols=${1:-4} i n m w1=4 w2=4
  local BOX r c idx text rows maxw val line=1 cw rowtxt content hw1 hw2 dw need_box
  n=${#UI_IK[@]}
  m=${#UI_MK[@]}
  maxw=$(term_cols)
  (( maxw < 36 )) && maxw=36

  for ((i=0;i<n;i++)); do
    dw=$(disp_w "${UI_IK[i]}")
    (( dw > w1 )) && w1=$dw
    dw=$(disp_w "${UI_IV[i]}")
    (( dw > w2 )) && w2=$dw
  done
  (( w1 < 4 )) && w1=4
  (( w2 < 4 )) && w2=4
  need_box=$((7 + w1 + w2))

  BOX=$need_box
  (( BOX < 37 )) && BOX=37
  if (( m > 0 )); then
    ui_menu_widths "$cols"
    if (( MENU_DW > maxw && cols > 2 )); then
      cols=2
      ui_menu_widths "$cols"
    fi
    (( MENU_DW > BOX )) && BOX=$MENU_DW
  fi
  if (( BOX < 37 && cols > 2 )); then
    cols=2
    (( m > 0 )) && ui_menu_widths "$cols"
  fi
  if (( BOX > maxw )); then
    if (( need_box <= maxw )); then
      BOX=$maxw
    elif (( need_box <= maxw + 24 )); then
      BOX=$need_box
    else
      BOX=$maxw
      w2=$(( BOX - 7 - w1 ))
      (( w2 < 4 )) && w2=4
    fi
  fi
  if (( BOX - 7 - w1 > w2 )); then
    w2=$(( BOX - 7 - w1 ))
  fi
  hw1=$((w1 + 2))
  hw2=$((w2 + 2))
  line=1

  ui_sep "$hw1" "$hw2"
  ((line++)) || true
  printf "${CD}|${C0} ${CB}%s${C0} ${CD}|${C0} ${CB}%s${C0} ${CD}|${C0}\033[K\n" \
    "$(pad_r "项目" "$w1")" "$(pad_r "配置" "$w2")"
  ((line++)) || true
  ui_sep "$hw1" "$hw2"
  ((line++)) || true
  for ((i=0;i<n;i++)); do
    val=$(trunc_disp "${UI_IV[i]}" "$w2")
    printf "${CD}|${C0} %s ${CD}|${C0} ${CBC}%s${C0} ${CD}|${C0}\033[K\n" \
      "$(pad_r "$(trunc_disp "${UI_IK[i]}" "$w1")" "$w1")" "$(pad_r "$val" "$w2")"
    ((line++)) || true
  done
  ui_sep "$hw1" "$hw2"
  ((line++)) || true
  if (( m > 0 )); then
    rows=$(( (m + cols - 1) / cols ))
    content=$((BOX - 4))
    for ((r=0;r<rows;r++)); do
      rowtxt=""
      for ((c=0;c<cols;c++)); do
        idx=$((r * cols + c))
        cw=${col_w[c]:-8}
        if (( idx < m )); then
          text=$(trunc_disp "${UI_MK[idx]} ${UI_ML[idx]}" "$cw")
          rowtxt+="$(pad_r "$text" "$cw")"
        else
          rowtxt+="$(printf '%*s' "$cw" '')"
        fi
      done
      printf "${CD}|${C0} %s ${CD}|${C0}\033[K\n" "$(pad_r "$rowtxt" "$content")"
      ((line++)) || true
    done
    ui_sep "$hw1" "$hw2"
    ((line++)) || true
  fi
  UI_PROMPT_R=$line
}

wait_back() {
  local x
  while :; do
    x=$(prompt "选择" "" "q返回") || { printf '\n' >&2; return 0; }
    [[ "$x" == q || "$x" == Q ]] && return 0
  done
}

ui_paint() {
  local cols=${1:-4}
  printf '\033[?25l\033[2J\033[H'
  ui_render "$cols"
  printf '\033[J\033[?25h'
}

ui_redraw() {
  dashboard
  ui_paint 4
}

# stdin 结束(EOF)时返回 1：调用方必须处理，否则菜单会无限空转。
prompt() {
  local msg=$1 def=${2-} hint=${3-} ans
  if [[ -n "$def" ]]; then
    printf "${CC}%s${C0} ${CD}[%s]${C0}: " "$msg" "$def" >&2
  elif [[ -n "$hint" ]]; then
    printf "${CC}%s${C0} ${CD}[%s]${C0}: " "$msg" "$hint" >&2
  else
    printf "${CC}%s${C0}: " "$msg" >&2
  fi
  if ! IFS= read -r ans; then
    printf '\n' >&2
    return 1
  fi
  printf '%s' "${ans:-$def}"
}

# EOF 时采用默认值（返回其布尔结果），避免交互中断导致死循环
ask_yn() {
  local msg=$1 def=${2:-n} ans hint="y/N"
  [[ "$def" == [yY] ]] && hint="Y/n"
  printf "${CC}%s${C0} ${CD}[%s]${C0}: " "$msg" "$hint" >&2
  if IFS= read -r ans; then
    ans=${ans:-$def}
  else
    printf '\n' >&2
    ans=$def
  fi
  [[ "$ans" == [yY] ]]
}

# ---------- 系统 / 依赖 ----------

OS_ID=""; OS_PRETTY=""; OS_KIND=""

detect_os() {
  [[ -f /etc/os-release ]] || die "找不到 /etc/os-release"
  # shellcheck disable=SC1091
  . /etc/os-release
  OS_ID="${ID:-}"
  OS_PRETTY="${PRETTY_NAME:-$OS_ID}"
  local like=" ${ID_LIKE:-} "
  case "$OS_ID" in
    debian|ubuntu|raspbian|linuxmint|pop|neon|elementary|zorin|kali|devuan)
      OS_KIND=debian
      ;;
    alpine)
      OS_KIND=alpine
      ;;
    *)
      if [[ "$like" == *" debian "* || "$like" == *" ubuntu "* ]]; then
        OS_KIND=debian
      else
        die "只支持 Debian 系和 Alpine，当前是：${OS_PRETTY}（ID=$OS_ID）"
      fi
      ;;
  esac
}

pkg_install() {
  case "$OS_KIND" in
    debian)
      export DEBIAN_FRONTEND=noninteractive
      apt-get update -qq >/dev/null || { err "apt-get update 失败"; return 1; }
      apt-get install -y -qq --no-install-recommends "$@" >/dev/null || {
        err "apt-get install 失败: $*"
        return 1
      }
      ;;
    alpine)
      apk add --no-cache --quiet "$@" >/dev/null || { err "apk add 失败: $*"; return 1; }
      ;;
  esac
}

ensure_deps() {
  local need=() p
  for p in curl jq tar openssl bash; do
    command -v "$p" >/dev/null 2>&1 || need+=("$p")
  done
  command -v ss >/dev/null 2>&1 || need+=(iproute2)
  command -v flock >/dev/null 2>&1 || need+=(util-linux)
  # nodejs 只在“恢复”功能里用到（归档安全校验），按需再装，避免拖慢每次启动
  if ((${#need[@]})); then
    pkg_install "${need[@]}" ca-certificates || { err "依赖安装失败"; return 1; }
  fi
}

# 二进制容量（1024 进制）
_fmt_bytes_bin() {
  awk -v b="${1:-0}" 'BEGIN {
    if (b + 0 < 0) b = 0
    split("B KiB MiB GiB TiB PiB", u, " ")
    x = b + 0; i = 1
    while (x >= 1024 && i < 6) { x /= 1024; i++ }
    if (i == 1) {
      printf "%d%s", int(x + 0.5), u[i]
      exit
    }
    r = int(x * 10 + 0.5) / 10
    if (r >= 1024 && i < 6) { r /= 1024; i++ }
    printf "%.1f%s", r, u[i]
  }'
}

mem_nums() {
  local line t u a
  line=$(free -b 2>/dev/null | awk '/^Mem:/{
    t=$2; u=$3; a=(NF>=7?$7:$4)
    if (a+0<=0) a=$4
    printf "%.0f %.0f %.0f", t, u, a
  }')
  if [[ -z "$line" ]]; then
    line=$(awk '
      /^MemTotal:/{t=$2*1024}
      /^MemAvailable:/{a=$2*1024}
      /^MemFree:/{f=$2*1024}
      END{
        if (a+0<=0) a=f
        printf "%.0f %.0f %.0f", t, t-a, a
      }' /proc/meminfo)
  fi
  read -r t u a <<< "$line"
  printf '%s %s %s' "$(_fmt_bytes_bin "$t")" "$(_fmt_bytes_bin "$u")" "$(_fmt_bytes_bin "$a")"
}

disk_nums() {
  local line t u a
  line=$(df -B1 -P / 2>/dev/null | awk 'NR==2 && $2+0>0 {print $2,$3,$4}')
  if [[ -z "$line" ]]; then
    line=$(df -kP / 2>/dev/null | awk 'NR==2{printf "%.0f %.0f %.0f", $2*1024, $3*1024, $4*1024}')
  fi
  [[ -z "$line" ]] && line=$(df -k / 2>/dev/null | awk 'NR==2{printf "%.0f %.0f %.0f", $2*1024, $3*1024, $4*1024}')
  read -r t u a <<< "$line"
  printf '%s %s %s' "$(_fmt_bytes_bin "$t")" "$(_fmt_bytes_bin "$u")" "$(_fmt_bytes_bin "$a")"
}

cap_lines() {
  local mt mu ma dt du da wt wu d
  read -r mt mu ma <<< "$(mem_nums)"
  read -r dt du da <<< "$(disk_nums)"
  wt=$(disp_w "$mt"); d=$(disp_w "$dt"); (( d > wt )) && wt=$d
  wu=$(disp_w "$mu"); d=$(disp_w "$du"); (( d > wu )) && wu=$d
  (( wt < 4 )) && wt=4
  (( wu < 4 )) && wu=4
  CAP_MEM="总$(pad_r "$mt" "$wt")  已$(pad_r "$mu" "$wu")  剩${ma}"
  CAP_DISK="总$(pad_r "$dt" "$wt")  已$(pad_r "$du" "$wu")  剩${da}"
}

cpu_line_refresh() {
  [[ -n "${CACHE_CPU:-}" ]] && return 0
  CACHE_CPU="$(nproc 2>/dev/null || grep -c ^processor /proc/cpuinfo) 核"
  [[ -n "$CACHE_CPU" ]] || CACHE_CPU="未知"
  return 0
}

# 解析 sing-box 版本并缓存；配置未变时不重复执行二进制。
# 执行失败/格式异常时记为"未知"，避免 require_ver 误报成"版本过低，当前 。"
sb_version_refresh() {
  local mt v
  if [[ ! -x "$SINGBOX_BIN" ]]; then
    CACHE_SBVER="未安装"
    CACHE_SBVER_MT=""
    return 0
  fi
  mt=$(stat -c %Y "$SINGBOX_BIN" 2>/dev/null || printf '0')
  [[ -n "${CACHE_SBVER:-}" && "${CACHE_SBVER_MT:-}" == "$mt" ]] && return 0
  v=$("$SINGBOX_BIN" version 2>/dev/null | awk 'NR==1{print $3; exit}')
  if [[ -z "$v" || "$v" == "-"* ]]; then
    v=$("$SINGBOX_BIN" version 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i ~ /^v?[0-9]+\.[0-9]+(\.[0-9]+)?/){print $i; exit}}')
  fi
  [[ -n "$v" ]] || v="未知"
  CACHE_SBVER=$v
  CACHE_SBVER_MT=$mt
  return 0
}

sb_version() {
  sb_version_refresh
  printf '%s' "$CACHE_SBVER"
}

svc_state() {
  local s pid load
  if [[ "$OS_KIND" == debian ]]; then
    # 用 LoadState 判断单元是否存在，兼容 /usr/lib/systemd/system 等非默认路径
    command -v systemctl >/dev/null 2>&1 || { printf 'absent'; return; }
    load=$(systemctl show -p LoadState --value sing-box 2>/dev/null || printf 'not-found')
    [[ -n "$load" && "$load" != "not-found" && "$load" != "bad-setting" ]] || { printf 'absent'; return; }
    s=$(systemctl show -p ActiveState --value sing-box 2>/dev/null || printf 'unknown')
    case "$s" in
      active)
        pid=$(systemctl show -p MainPID --value sing-box 2>/dev/null || printf '0')
        if [[ "$pid" != 0 && -d "/proc/$pid" ]]; then
          printf 'running'
        else
          printf 'stopped'
        fi
        ;;
      failed) printf 'failed' ;;
      activating) printf 'starting' ;;
      deactivating) printf 'stopping' ;;
      *) printf 'stopped' ;;
    esac
  else
    [[ -f /etc/init.d/sing-box ]] || { printf 'absent'; return; }
    if rc-service sing-box status >/dev/null 2>&1; then
      printf 'running'
    elif grep -qiE 'crashed|failed' <(rc-service sing-box status 2>&1 || true); then
      printf 'failed'
    else
      printf 'stopped'
    fi
  fi
}

node_count_refresh() {
  local mt
  if [[ ! -f "$CONF" ]]; then
    CACHE_NC=0
    CACHE_NC_MT=""
    return 0
  fi
  mt=$(stat -c %Y "$CONF" 2>/dev/null || printf '0')
  [[ -n "${CACHE_NC:-}" && "${CACHE_NC_MT:-}" == "$mt" ]] && return 0
  if ! command -v jq >/dev/null 2>&1; then
    CACHE_NC=0
  else
    CACHE_NC=$(jq '[.inbounds[]? | select((.tag // "") | startswith("ss-inner-") | not)] | length' "$CONF" 2>/dev/null || printf '0')
  fi
  CACHE_NC_MT=$mt
  return 0
}

is_ip4() {
  local ip=${1-} a b c d
  [[ "$ip" =~ ^([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})$ ]] || return 1
  a=${BASH_REMATCH[1]}; b=${BASH_REMATCH[2]}; c=${BASH_REMATCH[3]}; d=${BASH_REMATCH[4]}
  (( a <= 255 && b <= 255 && c <= 255 && d <= 255 ))
}

is_ip6() {
  local ip=${1-} compressed=0 left right part count=0
  local parts=() side=()
  [[ "$ip" == *:* && "$ip" != *[[:space:]]* && "$ip" != *.* ]] || return 1
  [[ "$ip" != *[!0-9A-Fa-f:]* ]] || return 1

  if [[ "$ip" == *::* ]]; then
    compressed=1
    left=${ip%%::*}
    right=${ip#*::}
    [[ "$right" != *::* ]] || return 1
    if [[ -n "$left" ]]; then
      IFS=: read -r -a side <<< "$left"
      parts+=("${side[@]}")
    fi
    if [[ -n "$right" ]]; then
      IFS=: read -r -a side <<< "$right"
      parts+=("${side[@]}")
    fi
  else
    [[ "$ip" != :* && "$ip" != *: ]] || return 1
    IFS=: read -r -a parts <<< "$ip"
  fi

  for part in "${parts[@]}"; do
    [[ "$part" =~ ^[0-9A-Fa-f]{1,4}$ ]] || return 1
    ((count++)) || true
  done
  if (( compressed )); then
    (( count < 8 ))
  else
    (( count == 8 ))
  fi
}

is_domain() {
  local d=${1-}
  # 单标签（localhost）或多级域名
  [[ "$d" =~ ^[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?(\.[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?)*$ ]] \
    && [[ "$d" == *.* || "$d" == localhost ]]
}

is_share_host() { is_domain "$1" || is_ip4 "$1" || is_ip6 "$1"; }

is_email() {
  [[ "${1-}" =~ ^[A-Za-z0-9._%+-]+@[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?(\.[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?)+$ ]]
}

cert_slug() {
  local s=${1-} out="" i c
  for ((i=0; i<${#s}; i++)); do
    c="${s:i:1}"
    if [[ "$c" =~ [A-Za-z0-9._-] ]]; then
      out+="$c"
    else
      out+=$(printf '_%02x' "'$c")
    fi
  done
  [[ -n "$out" ]] || out="sni"
  printf '%s' "${out:0:180}"
}

curl_ip() {
  local fam=$1 ip
  if [[ "$fam" == 6 ]]; then
    ip=$(curl_secure -6 -fsS --connect-timeout 1 --max-time 2 https://api64.ipify.org 2>/dev/null \
      || curl_secure -6 -fsS --connect-timeout 1 --max-time 2 https://ifconfig.me 2>/dev/null \
      || curl_secure -6 -fsS --connect-timeout 1 --max-time 2 https://icanhazip.com 2>/dev/null \
      || true)
  else
    ip=$(curl_secure -4 -fsS --connect-timeout 1 --max-time 2 https://api.ip.sb/ip 2>/dev/null \
      || curl_secure -4 -fsS --connect-timeout 1 --max-time 2 https://ifconfig.me 2>/dev/null \
      || curl_secure -4 -fsS --connect-timeout 1 --max-time 2 https://icanhazip.com 2>/dev/null \
      || true)
  fi
  ip=$(printf '%s' "$ip" | tr -d ' \r\n')
  if [[ "$fam" == 6 ]]; then is_ip6 "$ip" && printf '%s' "$ip"
  else is_ip4 "$ip" && printf '%s' "$ip"
  fi
}

iface_ip4() {
  ip -4 -o addr show scope global 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | head -n1
}

iface_ip6() {
  ip -6 -o addr show scope global 2>/dev/null | awk '{print $4}' | cut -d/ -f1 \
    | grep -vE '^(fc|fd)' | head -n1
}

meta_get() {
  [[ -f "$META" ]] || { printf ''; return 0; }
  jq -r --arg k "$1" '.[$k] // empty' "$META" 2>/dev/null || true
}

meta_set_kv() {
  [[ -f "$META" ]] || ensure_conf
  jq_write "$META" --arg k "$1" --arg v "$2" '.[$k]=$v'
}

share_host() {
  local h=""
  h=$(meta_get default_host)
  if [[ -n "$h" ]]; then
    printf '%s' "$h"
    return
  fi
  h=$(curl_ip 4)
  [[ -z "$h" ]] && h=$(curl_ip 6)
  [[ -z "$h" ]] && h=$(iface_ip4)
  [[ -z "$h" ]] && h=$(iface_ip6)
  printf '%s' "$h"
}

remember_share_host() {
  local h=$1
  [[ -n "$h" ]] || return 0
  meta_set_kv default_host "$h" || true
}

# 只在当前 shell 赋值，供仪表盘跨次刷新复用；
# 放进 $( ) 调用会导致 IP_LINE 随子 shell 消失，每次重绘都重新外网查询。
ip_line_refresh() {
  local v4="" v6="" f4 f6
  [[ -n "${IP_LINE:-}" ]] && return 0
  if ! command -v curl >/dev/null 2>&1; then IP_LINE='-'; return 0; fi
  f4=$(mktemp) || { IP_LINE='-'; return 0; }
  f6=$(mktemp) || { rm -f "$f4"; IP_LINE='-'; return 0; }
  (curl_ip 4 >"$f4" || true) &
  (curl_ip 6 >"$f6" || true) &
  wait
  v4=$(tr -d ' \t\r\n' <"$f4")
  v6=$(tr -d ' \t\r\n' <"$f6")
  rm -f "$f4" "$f6"
  is_ip4 "$v4" || v4=""
  is_ip6 "$v6" || v6=""
  if [[ -n "$v4" && -n "$v6" ]]; then IP_LINE="$v4 $v6"
  elif [[ -n "$v4" ]]; then IP_LINE="$v4"
  elif [[ -n "$v6" ]]; then IP_LINE="$v6"
  else IP_LINE="-"
  fi
  return 0
}

# openssl base64 输出按 64 字符换行，原实现不剔除换行且可能返回不足长度的串，
# 换行会被写进 ShadowTLS/Hy2/AnyTLS/Snell 密钥。
rand_str() {
  local gen=${1:-18} want=${2:-$1} s
  s=$(openssl rand -base64 "$((gen * 4))" 2>/dev/null | tr -d '\r\n/+=' | head -c "$want")
  if [[ ${#s} -ne "$want" ]]; then
    s=$(openssl rand -hex "$(( (want + 1) / 2 ))" 2>/dev/null | tr -d '\r\n' | head -c "$want")
  fi
  [[ ${#s} -eq "$want" ]] || return 1
  printf '%s' "$s"
}

# 随机端口 10000-65535
rand_port() {
  local p i used hex
  used=$(port_set)
  for i in $(seq 1 64); do
    hex=$(openssl rand -hex 2 2>/dev/null || true)
    [[ -n "$hex" ]] || hex=$(printf '%04x' $((RANDOM * RANDOM % 65536)))
    p=$((0x$hex))
      p=$((10000 + (p % 55536)))
    printf '%s\n' "$used" | grep -qx "$p" && continue
    if port_bindable "$p"; then
      printf '%s' "$p"
      return 0
    fi
  done
  err "找不到空闲端口"
  return 1
}

port_bindable() {
  local p=$1
  if command -v python3 >/dev/null 2>&1; then
    python3 - "$p" <<'PY' >/dev/null 2>&1
import socket, sys
p=int(sys.argv[1])
ok=False
for fam, addr in ((socket.AF_INET6,"::"),(socket.AF_INET,"0.0.0.0")):
    try:
        s=socket.socket(fam, socket.SOCK_STREAM)
        try:
            if fam==socket.AF_INET6:
                s.setsockopt(socket.IPPROTO_IPV6, socket.IPV6_V6ONLY, 0)
        except Exception:
            pass
        s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        s.bind((addr, p))
        s.close()
        ok=True
        break
    except Exception:
        try: s.close()
        except Exception: pass
sys.exit(0 if ok else 1)
PY
    return $?
  fi
  ! port_used "$p"
}

port_set() {
  local skip=${1-}
  {
    if [[ -f "$CONF" ]]; then
      if [[ -n "$skip" ]]; then
        jq -r --arg s "$skip" '.inbounds[]? | select(.tag != $s) | .listen_port // empty' "$CONF" 2>/dev/null
      else
        jq -r '.inbounds[]? | .listen_port // empty' "$CONF" 2>/dev/null
      fi
    fi
    ss -lntu 2>/dev/null | awk 'NR>1{n=$5; sub(/.*:/,"",n); if(n ~ /^[0-9]+$/) print n}'
  } | awk 'NF && $1+0==$1'
}

port_used() {
  local p=$1 skip=${2-}
  printf '%s\n' "$(port_set "$skip")" | grep -qx "$p"
}

assert_tags_free() {
  local t
  for t in "$@"; do
    [[ -n "$t" ]] || continue
    if [[ -n "$(ib_get "$t" '.tag')" ]]; then
      err "目标 tag 已存在: $t"
      return 1
    fi
  done
}

# 无参数：随机默认端口，占用后重新随机。
# 传入当前端口和 skip tag：原端口直接接受，换端口才检查占用与可绑定。
ask_port() {
  local cur=${1-} skip=${2-} def p tries=0
  def=$cur
  if [[ -z "$cur" ]]; then
    def=$(rand_port) || return 1
  fi
  while :; do
    ((tries++)) || true
    if (( tries > 20 )); then
      err "多次无法获得可用端口"
      return 1
    fi
    p=$(prompt "端口" "$def") || { err "输入已结束"; return 2; }
    [[ "$p" =~ ^[0-9]+$ ]] || { err "端口必须是 1-65535"; continue; }
    p=$((10#$p))   # 否则 08 会被当成八进制并报 "value too great for base"
    if (( p < 1 || p > 65535 )); then
      err "端口必须是 1-65535"
      continue
    fi
    if [[ -n "$cur" && "$p" == "$cur" ]]; then
      printf '%s' "$p"
      return 0
    fi
    if port_used "$p" "$skip" || ! port_bindable "$p"; then
      err "端口 $p 不可用"
      if [[ -z "$cur" ]]; then
        def=$(rand_port) || return 1
      fi
      continue
    fi
    printf '%s' "$p"
    return 0
  done
}

# 密钥类字段：回车保持；输入 . 重新生成
ask_secret_edit() {
  local msg=$1 cur=$2 gen=${3:-18} ans
  ans=$(prompt "${msg}（. 重新生成）" "$cur") || return 2
  if [[ "$ans" == . ]]; then
    rand_str "$gen" "$gen" || { err "密钥生成失败"; return 1; }
  else
    printf '%s' "$ans"
  fi
}

ask_sni() {
  local def=${1:-www.apple.com} sni tries=0
  while :; do
    ((tries++)) || true
    if (( tries > 10 )); then
      err "SNI 输入无效次数过多"
      return 1
    fi
    sni=$(prompt "SNI/域名" "$def") || return 2
    sni=$(printf '%s' "$sni" | tr -d '\r' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
    if is_domain "$sni" || is_ip4 "$sni"; then
      printf '%s' "$sni"
      return 0
    fi
    err "请输入合法域名（或 IPv4）"
  done
}

uri_enc() { jq -nr --arg s "$1" '$s|@uri'; }

ver_ge() {
  local a=${1#v} b=${2#v}
  a=${a%%-*}
  b=${b%%-*}
  awk -v a="$a" -v b="$b" 'BEGIN{
    n=split(a,A,"."); m=split(b,B,".");
    l=n; if(m>l) l=m;
    for(i=1;i<=l;i++){
      x=(i in A)?A[i]+0:0;
      y=(i in B)?B[i]+0:0;
      if(x>y) exit 0;
      if(x<y) exit 1;
    }
    exit 0
  }'
}

# ---------- 配置 / 锁 / 权限 ----------

# 权限模型：
#   root:sing-box 750/640 —— 服务需要读取的（配置目录、config.json、证书）
#   root:root 600/700      —— 服务完全不需要的（meta.json、keys.json、锁文件）
#   sing-box:sing-box      —— 服务需要写入的（ACME 数据目录、日志）
# 服务不再拥有配置文件本身，避免被攻陷后自行改写 config.json 并在下次重启生效。
# 放宽权限以 chown 是否成功为准：组不存在时退回仅 root 可读，
# 避免留下"以为服务可读、实际读不到"的错配。
# perm_set <ro|rodir|root|rw> <路径...>
perm_set() {
  local mode=$1 p owner grp_ok
  shift
  case "$mode" in
    ro|rodir|root) owner=root ;;
    rw)             owner=$SVC_USER ;;
    *) return 1 ;;
  esac
  for p in "$@"; do
    [[ -e "$p" ]] || continue
    if [[ "$mode" == root ]]; then
      # 仅 root 可读写的文件不涉及服务，组保持 root
      chown root:root "$p" 2>/dev/null || true
      chmod 600 "$p" 2>/dev/null || true
      continue
    fi
    if [[ -n "$SVC_GRP" ]] && chown "$owner:$SVC_GRP" "$p" 2>/dev/null; then
      grp_ok=1
    else
      chown "$owner:root" "$p" 2>/dev/null || true
      grp_ok=0
    fi
    case "$mode:$grp_ok" in
      ro:1)              chmod 640 "$p" 2>/dev/null || true ;;
      rodir:1)           chmod 750 "$p" 2>/dev/null || true ;;
      root:1|root:0)     chmod 600 "$p" 2>/dev/null || true ;;
      rw:1)              chmod 700 "$p" 2>/dev/null || true ;;
      ro:0)              chmod 600 "$p" 2>/dev/null || true ;;
      rodir:0)           chmod 700 "$p" 2>/dev/null || true ;;
      rw:0)              chmod 600 "$p" 2>/dev/null || true ;;
    esac
  done
  return 0
}

harden_perms() {
  local d
  SVC_GRP=$(svc_group)
  mkdir -p "$CONF_DIR" "$CERT_DIR"
  perm_set rodir "$CONF_DIR" "$CERT_DIR"
  perm_set ro "$CONF"        # 服务需读
  perm_set root "$META" "$KEYS" "$LOCK_FILE"   # 服务不需要（含私钥派生信息）
  if [[ -d "$CERT_DIR" ]]; then
    while IFS= read -r d; do
      case "$d" in
        "$CERT_DIR/acme"|"$CERT_DIR/acme/"*) perm_set rw "$d" ;;   # ACME 需服务写入
        *) perm_set rodir "$d" ;;
      esac
    done < <(find "$CERT_DIR" -type d 2>/dev/null)
    while IFS= read -r d; do
      case "$d" in
        "$CERT_DIR/acme/"*) perm_set rw "$d" ;;
        *) perm_set ro "$d" ;;
      esac
    done < <(find "$CERT_DIR" -type f 2>/dev/null)
  fi
}

# /proc/PID/stat 的 starttime 是第 22 字段。comm 可含空格和括号，不能按空白切整行。
proc_starttime() {
  local stat rest
  [[ -r "/proc/${1}/stat" ]] || return 1
  IFS= read -r stat <"/proc/${1}/stat" || return 1
  rest=${stat##*) }
  [[ -n "$rest" ]] || return 1
  awk '{print $20}' <<<"$rest"
}

lock_acquire() {
  mkdir -p "$CONF_DIR"
  SVC_GRP=$(svc_group)
  if [[ -n "$SVC_GRP" ]] && chown root:"$SVC_GRP" "$CONF_DIR" 2>/dev/null; then
    chmod 750 "$CONF_DIR" 2>/dev/null || true
  else
    chmod 700 "$CONF_DIR" 2>/dev/null || true
  fi
  if ! command -v flock >/dev/null 2>&1; then
    note "无 flock，跳过配置锁（建议安装 util-linux）"
    return 0
  fi
  # 锁 fd 不能留在本进程：OpenRC supervise-daemon 会继承它，面板退出后锁仍被占着。
  # 持有者对照本进程 starttime 放锁。不能改用管道写端，写端一样会被服务继承。
  # disown：仪表盘刷新里的 wait 会等所有未脱离的后台子进程。
  local parent_pid parent_start stat_dir stat_file holder_pid status="" start_s
  parent_pid=$BASHPID
  parent_start=$(proc_starttime "$parent_pid") || { err "无法打开配置锁"; return 1; }
  stat_dir=$(mktemp -d) || { err "无法打开配置锁"; return 1; }
  chmod 700 "$stat_dir" || true
  stat_file=$stat_dir/status
  TMP_CLEANUP+=("$stat_dir")
  (
    trap - EXIT INT TERM
    fd=""
    i=0
    exec {fd}>>"$LOCK_FILE" || { printf 'open_fail\n' >"$stat_file"; exit 1; }
    if flock --help 2>&1 | grep -q -- "-w"; then
      if ! flock -w 30 "$fd"; then
        printf 'timeout\n' >"$stat_file"
        exit 1
      fi
    else
      while (( i < 30 )); do
        if flock -n "$fd"; then
          break
        fi
        sleep 1
        ((i++)) || true
      done
      if (( i >= 30 )); then
        printf 'timeout\n' >"$stat_file"
        exit 1
      fi
    fi
    printf 'ok\n' >"$stat_file" || exit 1
    exec 0</dev/null 1>/dev/null 2>/dev/null
    while [[ -d "/proc/${parent_pid}" ]]; do
      now=$(proc_starttime "$parent_pid" 2>/dev/null || true)
      [[ "$now" == "$parent_start" ]] || break
      sleep 0.2
    done
    exit 0
  ) &
  holder_pid=$!
  if ! disown "$holder_pid" 2>/dev/null; then
    kill "$holder_pid" 2>/dev/null || true
    wait "$holder_pid" 2>/dev/null || true
    rm -rf "$stat_dir"
    err "无法打开配置锁"
    return 1
  fi
  start_s=$SECONDS
  while (( SECONDS - start_s < 35 )); do
    if [[ -s "$stat_file" ]]; then
      IFS= read -r status <"$stat_file" || status=""
      break
    fi
    if ! kill -0 "$holder_pid" 2>/dev/null; then
      [[ -s "$stat_file" ]] && IFS= read -r status <"$stat_file" || status=""
      break
    fi
    sleep 0.1
  done
  rm -rf "$stat_dir"
  case "$status" in
    ok) return 0 ;;
    open_fail)
      wait "$holder_pid" 2>/dev/null || true
      err "无法打开配置锁"
      return 1
      ;;
    *)
      kill "$holder_pid" 2>/dev/null || true
      wait "$holder_pid" 2>/dev/null || true
      err "配置锁超时：是否有另一个 singbox 实例在运行？"
      return 1
      ;;
  esac
}

ensure_conf() {
  mkdir -p "$CONF_DIR" "$CERT_DIR"
  if [[ ! -f "$KEYS" ]]; then
    printf '{}\n' > "$KEYS"
  fi
  if [[ ! -f "$CONF" ]]; then
    cat > "$CONF" <<'JSON'
{
  "log": {
    "disabled": false,
    "level": "warn",
    "timestamp": true
  },
  "inbounds": [],
  "outbounds": [
    {
      "type": "direct",
      "tag": "direct"
    }
  ],
  "route": {
    "rules": [
      {
        "action": "sniff"
      }
    ],
    "final": "direct"
  }
}
JSON
  fi
  if [[ ! -f "$META" ]]; then
    cat > "$META" <<'JSON'
{
  "version": 1,
  "nodes": {}
}
JSON
  fi
  meta_drop_legacy_name || true
  harden_perms
}

meta_put_node() {
  jq_write "$META" --arg t "$1" --argjson n "$2" '.nodes[$t] = $n'
}

meta_del_node() {
  jq_write "$META" --arg t "$1" 'del(.nodes[$t])'
}

# 旧版本把可改的"名称"存进 meta.nodes[].name；该功能已移除，
# 启动与恢复时清掉历史残留（无残留时不做任何写入）。
meta_drop_legacy_name() {
  [[ -f "$META" ]] || return 0
  jq -e 'any(.nodes[]?; has("name"))' "$META" >/dev/null 2>&1 || return 0
  jq_write "$META" '.nodes = ((.nodes // {}) | map_values(del(.name)))' || return 1
  note "已清理旧版节点名称字段"
}

keys_put() {
  [[ -f "$KEYS" ]] || printf '{}\n' > "$KEYS"
  jq_write "$KEYS" --arg t "$1" --argjson n "$2" '.[$t] = $n'
}

keys_del() {
  [[ -f "$KEYS" ]] || return 0
  jq_write "$KEYS" --arg t "$1" 'del(.[$t])'
}

keys_get() {
  [[ -f "$KEYS" ]] || { printf ''; return 0; }
  jq -r --arg t "$1" --arg f "$2" '.[$t][$f] // empty' "$KEYS" 2>/dev/null || true
}

ib_get() {
  jq -r --arg t "$1" ".inbounds[]? | select(.tag==\$t) | ($2) // empty" "$CONF" 2>/dev/null
}

conf_add_inbound() {
  jq_write "$CONF" --argjson o "$1" '
    if ($o.tls._acme_provider? != null) then
      .certificate_providers = (
        ((.certificate_providers // [])
          | map(select(.tag != $o.tls._acme_provider.tag)))
        + [$o.tls._acme_provider]
      )
      | .inbounds += [($o | del(.tls._acme_provider))]
    else
      .inbounds += [$o]
    end
    | if (.certificate_providers? != null) then .certificate_providers |= unique_by(.tag) else . end
  '
}

# provider 回收尾段：$gone 里的 tag 若已无任何 inbound 引用则删除。
# conf_put_inbound / conf_del_tag 共用，避免两份拷贝各自漂移。
JQ_PROVIDER_GC='
    | . as $root
    | if ($gone | length) > 0 then
        .certificate_providers = [
          $root.certificate_providers[]? as $p
          | select((($gone | index($p.tag)) == null)
              or any($root.inbounds[]?; .tls.certificate_provider == $p.tag)) | $p
        ]
      else . end
    | if (.certificate_providers? != null) then .certificate_providers |= unique_by(.tag) else . end
  '

conf_put_inbound() {
  local tag=$1 obj=$2
  jq_write "$CONF" --arg t "$tag" --argjson o "$obj" "
    [ .inbounds[]? | select(.tag == \$t) | .tls.certificate_provider // empty ] as \$gone
    | .inbounds |= map(if .tag == \$t then (\$o | del(.tls._acme_provider)) else . end)
    | if (\$o.tls._acme_provider? != null) then
        .certificate_providers = (
          ((.certificate_providers // [])
            | map(select(.tag != \$o.tls._acme_provider.tag)))
          + [\$o.tls._acme_provider]
        )
      else . end
    $JQ_PROVIDER_GC
  "
}

conf_del_tag() {
  jq_write "$CONF" --arg t "$1" "
    [ .inbounds[]? | select(.tag == \$t) | .tls.certificate_provider // empty ] as \$gone
    | .inbounds |= map(select(.tag != \$t))
    $JQ_PROVIDER_GC
  "
}

ib_json() {
  jq -c --arg t "$1" '.inbounds[]? | select(.tag == $t)' "$CONF" 2>/dev/null
}

# 按现有 inbound 的 TLS 形态重建（自签 / ACME）
# 1.14 把 ACME 放在顶层 certificate_providers，不再读已废弃的 tls.acme
rebuild_tls_json() {
  local tag=$1 sni=$2 alpn_json=${3-}
  local email="" mode=self provider
  provider=$(ib_get "$tag" '.tls.certificate_provider')
  if [[ -n "$provider" && "$provider" != null ]]; then
    mode=acme
    email=$(jq -r --arg p "$provider" \
      '.certificate_providers[]? | select(.tag==$p) | .email // empty' "$CONF" 2>/dev/null || true)
    [[ -n "$email" && "$email" != null ]] || email="admin@${sni}"
  fi
  build_tls_json "$sni" "$mode" "$email" "$alpn_json"
}

# SS2022（aes-128）密码：须为 16 字节密钥的 base64
ss2022_pass_new() {
  local p
  p=$(openssl rand -base64 16 2>/dev/null | tr -d '\r\n')
  ss2022_pass_ok "$p" || return 1
  printf '%s' "$p"
}

ss2022_pass_ok() {
  local p=$1 n
  [[ -n "$p" ]] || return 1
  n=$(printf '%s' "$p" | openssl base64 -d -A 2>/dev/null | wc -c)
  n=${n//[[:space:]]/}
  [[ "$n" == 16 ]]
}

ask_ss2022_pass() {
  local cur=$1 ans
  while :; do
    ans=$(prompt "密码（. 重新生成）" "$cur") || return 2
    if [[ "$ans" == . ]]; then
      ss2022_pass_new || { err "SS2022 密码生成失败"; return 1; }
      return 0
    fi
    [[ -n "$ans" ]] || { err "密码不能为空"; continue; }
    if ss2022_pass_ok "$ans"; then
      printf '%s' "$ans"
      return 0
    fi
    err "SS2022 密码须为 16 字节密钥的 base64（输入 . 可重新生成）"
  done
}

# 协议 -> 默认 tag 前缀
tag_for() {
  local kind=$1 port=$2
  case "$kind" in
    shadowsocks|shadowtls|ss|st) printf 'ss-%s' "$port" ;;
    vless)   printf 'vless-%s' "$port" ;;
    vmess)   printf 'vmess-%s' "$port" ;;
    hysteria2|hy2) printf 'hy2-%s' "$port" ;;
    anytls)  printf 'anytls-%s' "$port" ;;
    snell)   printf 'snell-%s' "$port" ;;
    *) printf '%s-%s' "$kind" "$port" ;;
  esac
}

inner_tag_for() { printf 'ss-inner-%s' "$1"; }

# detour 为空或 null 时回退到 meta.inner_tag。null 收成空串。
inner_of() {
  local inner
  inner=$(ib_get "$1" '.detour')
  if [[ -z "$inner" || "$inner" == null ]]; then
    inner=$(jq -r --arg t "$1" '.nodes[$t].inner_tag // empty' "$META" 2>/dev/null || true)
  fi
  [[ "$inner" == null ]] && inner=""
  printf '%s' "$inner"
}

# 复制 / 恢复 config、meta、keys。证书目录不在这里处理。
snap_conf() {
  local d=$1
  mkdir -p "$d" || return 1
  if [[ -f "$CONF" ]]; then
    cp -a "$CONF" "$d/config.json" || return 1
  fi
  if [[ -f "$META" ]]; then
    cp -a "$META" "$d/meta.json" || return 1
  fi
  if [[ -f "$KEYS" ]]; then
    cp -a "$KEYS" "$d/keys.json" || return 1
  fi
}

restore_conf_snap() {
  local d=$1
  [[ -f "$d/config.json" ]] && cp -a "$d/config.json" "$CONF"
  [[ -f "$d/meta.json" ]] && cp -a "$d/meta.json" "$META"
  [[ -f "$d/keys.json" ]] && cp -a "$d/keys.json" "$KEYS"
  harden_perms
}

# 重命名 inbound tag，并更新 detour / meta / keys
# 允许 conf 已由 conf_put_inbound 写成新 tag（此时 old 不存在、new 已存在）
# 任一步失败都回滚本次调用前的配置，避免 tag 改到一半
node_retag() {
  local old=$1 new=$2 old_inner=${3-} new_inner=${4-}
  local conf_done=0 inner_done=0 snap="" g
  [[ "$old" == "$new" && "${old_inner:-}" == "${new_inner:-}" ]] && return 0

  snap=$(mktemp -d) || return 1
  TMP_CLEANUP+=("$snap")
  snap_conf "$snap" || { rm -rf "$snap"; return 1; }

  _retag_fail() {
    restore_conf_snap "$snap"
    rm -rf "$snap"
    return 1
  }

  # 返回 0=需要改名 1=conf 里已是新 tag(无需再改)
  _retag_guard() {  # <old> <new> <说明>
    [[ -n "$(ib_get "$2" '.tag')" ]] || return 0
    [[ -z "$(ib_get "$1" '.tag')" ]] && return 1
    err "目标 $3 已存在: $2"
    return 2
  }

  if [[ "$old" != "$new" ]]; then
    _retag_guard "$old" "$new" "tag"; g=$?
    (( g == 2 )) && { _retag_fail; return 1; }
    (( g == 1 )) && conf_done=1
  fi
  if [[ -n "$new_inner" && "$old_inner" != "$new_inner" ]]; then
    _retag_guard "$old_inner" "$new_inner" "内层 tag"; g=$?
    (( g == 2 )) && { _retag_fail; return 1; }
    (( g == 1 )) && inner_done=1
  fi

  local need_conf=0
  (( conf_done == 0 )) && need_conf=1
  if [[ -n "${old_inner:-}" && "$old_inner" != "${new_inner:-}" ]] && (( inner_done == 0 )); then
    need_conf=1
  fi
  if (( need_conf )); then
    jq_write "$CONF" \
      --arg o "$old" --arg n "$new" \
      --arg oi "${old_inner:-}" --arg ni "${new_inner:-}" \
      '
      .inbounds |= map(
        if .tag == $o then .tag = $n else . end
        | if ($oi != "" and .tag == $oi) then .tag = $ni else . end
        | if ($oi != "" and .detour == $oi) then .detour = $ni else . end
        | if .detour == $o then .detour = $n else . end
      )
      ' || { _retag_fail; return 1; }
  fi

  if [[ "$old" != "$new" ]]; then
    jq_write "$META" --arg o "$old" --arg n "$new" --arg ni "${new_inner:-}" \
      '
      if .nodes[$o] then
        .nodes[$n] = (.nodes[$o] |
          if ($ni != "") then .inner_tag = $ni else . end)
        | del(.nodes[$o])
      else . end
      ' || { _retag_fail; return 1; }
    if [[ -f "$KEYS" ]]; then
      jq_write "$KEYS" --arg o "$old" --arg n "$new" \
        'if has($o) then .[$n] = .[$o] | del(.[$o]) else . end' || { _retag_fail; return 1; }
    fi
  elif [[ -n "$new_inner" ]]; then
    jq_write "$META" --arg t "$new" --arg ni "$new_inner" \
      'if .nodes[$t] then .nodes[$t].inner_tag = $ni else . end' || { _retag_fail; return 1; }
  fi
  rm -rf "$snap"
}

# 清理未被 inbound 证书或 provider 数据目录引用的证书目录
cert_gc() {
  [[ -d "$CERT_DIR" ]] || return 0
  local used d real base ref keep
  used=$(jq -r '
    [
      .inbounds[]?
      | (.tls.certificate_path // empty), (.tls.key_path // empty)
    ] + [
      .certificate_providers[]? | (.data_directory // empty)
    ]
    | .[] | select(length > 0)
  ' "$CONF" 2>/dev/null | sort -u)
  for d in "$CERT_DIR"/*; do
    [[ -d "$d" ]] || continue
    real=$(cd "$d" 2>/dev/null && pwd -P) || continue
    base=$(basename "$real")
    keep=0
    while IFS= read -r ref; do
      [[ -n "$ref" ]] || continue
      case "$ref" in
        "$d"|"$d"/*|"$real"|"$real"/*) keep=1; break ;;
      esac
    done <<< "$used"
    (( keep )) && continue
    rm -rf "$d"
    note "已清理无用证书目录: $base"
  done
}

# 回收孤儿元数据：meta.nodes / keys 中已无对应 inbound 的条目
# （节点被面板之外删除、或历史版本残留，都会让它们长期堆积）
meta_gc() {
  [[ -f "$CONF" && -f "$META" ]] || return 0
  local live orphans
  # 只在配置结构完整时清理（inbounds 为空数组也视为"确实没有节点"）；
  # 配置残缺/损坏则一律不动，避免误删仅存于 meta/keys 的信息
  jq -e '(.inbounds | type) == "array"' "$CONF" >/dev/null 2>&1 || return 0
  live=$(jq -c '[.inbounds[]? | .tag // empty]' "$CONF" 2>/dev/null) || return 0
  orphans=$(jq -r --argjson live "$live" \
    '[.nodes | keys[] | . as $k | select(($live | index($k)) == null)] | join(" ")' "$META" 2>/dev/null) || return 0
  if [[ -n "$orphans" ]]; then
    note "已清理孤儿元数据: $orphans"
    jq_write "$META" --argjson live "$live" \
      '.nodes |= with_entries(select(.key as $k | ($live | index($k)) != null))' || return 1
  fi
  if [[ -f "$KEYS" ]]; then
    orphans=$(jq -r --argjson live "$live" \
      '[keys[] | . as $k | select(($live | index($k)) == null)] | join(" ")' "$KEYS" 2>/dev/null) || return 0
    if [[ -n "$orphans" ]]; then
      note "已清理孤儿密钥: $orphans"
      jq_write "$KEYS" --argjson live "$live" \
        'with_entries(select(.key as $k | ($live | index($k)) != null))' || return 1
    fi
  fi
  return 0
}

# ---------- 编辑事务（失败回滚） ----------
EDIT_SNAP=""

edit_snapshot() {
  edit_snap_clear
  EDIT_SNAP=$(mktemp -d) || return 1
  snap_conf "$EDIT_SNAP" || { rm -rf "$EDIT_SNAP"; EDIT_SNAP=""; return 1; }
  if [[ -d "$CERT_DIR" ]]; then
    mkdir -p "$EDIT_SNAP/cert"
    cp -a "$CERT_DIR"/. "$EDIT_SNAP/cert"/ 2>/dev/null || true
  fi
  EDIT_ACTIVE=1
  return 0
}

edit_restore() {
  [[ -n "${EDIT_SNAP:-}" && -d "$EDIT_SNAP" ]] || return 0
  restore_conf_snap "$EDIT_SNAP"
  if [[ -d "$EDIT_SNAP/cert" ]]; then
    mkdir -p "$CERT_DIR"
    rm -rf "${CERT_DIR:?}/"*
    cp -a "$EDIT_SNAP/cert"/. "$CERT_DIR"/ 2>/dev/null || true
    harden_perms
  fi
  QUIET=1 svc_restart || true
}

edit_snap_clear() {
  if [[ -n "${EDIT_SNAP:-}" && -d "$EDIT_SNAP" ]]; then
    rm -rf "$EDIT_SNAP"
  fi
  EDIT_SNAP=""
  EDIT_ACTIVE=""
}

# 中断（Ctrl-C / kill）时回滚进行中的编辑，并清理含密钥的临时目录
on_exit() {
  local p
  if [[ -n "${EDIT_ACTIVE:-}" && -n "${EDIT_SNAP:-}" && -d "${EDIT_SNAP}" ]]; then
    printf '\n' >&2
    note "检测到中断，正在恢复编辑前配置…"
    QUIET=1 edit_restore || true
    edit_snap_clear
  fi
  for p in ${TMP_CLEANUP[@]+"${TMP_CLEANUP[@]}"}; do
    [[ -n "$p" && -d "$p" ]] && rm -rf "$p"
  done
  [[ -t 1 ]] && printf '\033[?25h' >&2
  return 0
}

trap on_exit EXIT
trap 'printf "\n" >&2; exit 130' INT
trap 'printf "\n" >&2; exit 143' TERM

edit_abort() {
  local msg=${1-}
  [[ -n "$msg" ]] && err "$msg"
  note "正在恢复编辑前配置…"
  edit_restore
  edit_snap_clear
  return 1
}

drop_node() {
  local tag=$1 inner=""
  inner=$(ib_get "$tag" '.detour')
  conf_del_tag "$tag" || true
  [[ -n "$inner" && "$inner" != null ]] && conf_del_tag "$inner"
  meta_del_node "$tag" || true
  keys_del "$tag" || true
  # 失败路径常在生成证书之后中断，一并回收孤儿目录（可能含真实私钥）
  cert_gc
}

firewall_hint() {
  local port=$1 proto
  shift
  [[ $# -eq 0 ]] && set -- tcp
  for proto in "$@"; do
    note "请放行防火墙/安全组: ${port}/${proto}"
    if command -v ufw >/dev/null 2>&1; then
      local ust
      ust=$(ufw status 2>/dev/null || true)
      [[ "$ust" == *[Aa]ctive* ]] && note "ufw allow ${port}/${proto}"
    elif command -v firewall-cmd >/dev/null 2>&1; then
      note "firewall-cmd --permanent --add-port=${port}/${proto} && firewall-cmd --reload"
    fi
  done
}

apply_conf() {
  local tag=${1-} out
  harden_perms
  if ! out=$("$SINGBOX_BIN" check -c "$CONF" 2>&1); then
    err "配置校验失败"
    printf '%s\n' "$out" >&2
    [[ -n "$tag" ]] && drop_node "$tag"   # drop_node 内部会 cert_gc
    return 1
  fi
  if ! QUIET=1 svc_restart; then
    err "服务启动失败"
    if [[ -n "$tag" ]]; then
      drop_node "$tag"
      QUIET=1 svc_restart || true
    fi
    return 1
  fi
}

make_tls_cert() {
  local sni=$1 slug d
  is_domain "$sni" || is_ip4 "$sni" || { err "SNI 不能作为证书名"; return 1; }
  slug=$(cert_slug "$sni")
  d="$CERT_DIR/$slug"
  mkdir -p "$d" || return 1
  chmod 700 "$d" 2>/dev/null || true
  d=$(cd "$d" && pwd -P) || return 1
  case "$d" in
    "$CERT_DIR"/*) ;;
    *) err "证书目录越界"; return 1 ;;
  esac
  if [[ -f "$d/cert.pem" && -f "$d/key.pem" ]]; then
    printf '%s' "$d"
    return 0
  fi
  if ! openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 \
    -days 825 -nodes \
    -keyout "$d/key.pem" -out "$d/cert.pem" \
    -subj "/CN=$sni" >/dev/null 2>&1; then
    err "证书生成失败"
    return 1
  fi
  # 证书由 root:sing-box 640 持有（服务只读），权限统一由 harden_perms 收敛
  harden_perms
  printf '%s' "$d"
}

# 构建 TLS 对象：自签 或 ACME → stdout JSON；可选第 4 参 alpn JSON 数组
build_tls_json() {
  local sni=$1 mode=$2 email=${3-} certdir alpn_json=${4-} tls
  if [[ "$mode" == acme ]]; then
    [[ -n "$email" ]] || email="admin@${sni}"
    tls=$(jq -n --arg sni "$sni" --arg email "$email" --arg data "$CERT_DIR/acme" --arg provider "acme-${sni}" '{
      enabled: true,
      server_name: $sni,
      certificate_provider: $provider,
      _acme_provider: {
        type: "acme",
        tag: $provider,
        domain: [$sni],
        data_directory: $data,
        default_server_name: $sni,
        email: $email,
        provider: "letsencrypt"
      }
    }') || return 1
  else
    certdir=$(make_tls_cert "$sni") || return 1
    tls=$(jq -n --arg sni "$sni" --arg cert "$certdir/cert.pem" --arg key "$certdir/key.pem" '{
      enabled: true,
      server_name: $sni,
      certificate_path: $cert,
      key_path: $key
    }') || return 1
  fi
  if [[ -n "$alpn_json" ]]; then
    printf '%s' "$tls" | jq --argjson alpn "$alpn_json" '. + {alpn:$alpn}'
  else
    printf '%s' "$tls"
  fi
}

# 设置 TLS_MODE / TLS_EMAIL / TLS_INSECURE（须在当前 shell 调用，不可 $()）
choose_tls() {
  local sni=$1 ans
  TLS_MODE=self
  TLS_EMAIL=""
  TLS_INSECURE=1
  ans=$(prompt "使用 Let's Encrypt 证书（域名需解析到本机，80 端口可临时占用）" "n") || return 2
  if [[ "$ans" == [yY] ]]; then
    if ! is_domain "$sni"; then
      err "ACME 需要合法域名"
      return 1
    fi
    TLS_EMAIL=$(prompt "ACME 邮箱" "admin@${sni}") || return 2
    is_email "$TLS_EMAIL" || { err "ACME 邮箱格式无效"; return 1; }
    TLS_MODE=acme
    TLS_INSECURE=0
    note "将使用 HTTP-01；请确保 80/tcp 可从公网访问"
    if port_used 80; then
      note "检测到 80 端口已被占用，ACME 申请可能失败"
    fi
    firewall_hint 80 tcp
  fi
}

# meta 中 insecure 标记（自签=1 / ACME=0）
meta_insecure() {
  jq -r --arg t "$1" '.nodes[$t].insecure // "1"' "$META" 2>/dev/null || printf '1'
}

ensure_gcompat() {
  [[ "$OS_KIND" == alpine ]] || return 0
  command -v gcompat >/dev/null 2>&1 && return 0
  apk add --no-cache gcompat >/dev/null 2>&1 || true
}

goarch() {
  case "$(uname -m)" in
    x86_64|amd64)  printf 'amd64' ;;
    aarch64|arm64) printf 'arm64' ;;
    armv7l|armv7)  printf 'armv7' ;;
    *) err "不支持的架构: $(uname -m)"; return 1 ;;
  esac
}

stable_tag() {
  local tag="" json
  json=$(curl_secure -fsSL --max-time 12 "https://api.github.com/repos/${GH_REPO}/releases?per_page=30" 2>/dev/null || true)
  if [[ -n "$json" ]]; then
    tag=$(printf '%s' "$json" | jq -r '
      [.[]
        | select(.draft==false and .prerelease==false)
        | select(.tag_name | test("(?i)alpha|beta|rc") | not)
        | .tag_name
      ] | .[0] // empty
    ')
  fi
  if [[ -z "$tag" || "$tag" == null ]]; then
    tag=$(curl_secure -fsSL --max-time 12 "https://api.github.com/repos/${GH_REPO}/releases/latest" 2>/dev/null \
      | jq -r 'if .prerelease==false then .tag_name else empty end')
  fi
  if [[ -z "$tag" || "$tag" == null ]]; then
    note "GitHub API 不可用，回退到 $STABLE_FALLBACK（仍会强制校验 SHA256）"
    tag="$STABLE_FALLBACK"
  fi
  printf '%s' "$tag"
}

fetch_asset_digest() {
  local tag=$1 name=$2 digest
  digest=$(curl_secure -fsSL --max-time 15 "https://api.github.com/repos/${GH_REPO}/releases/tags/${tag}" 2>/dev/null \
    | jq -r --arg n "$name" '.assets[]? | select(.name==$n) | .digest // empty' || true)
  if [[ "$digest" == sha256:* ]]; then
    printf '%s' "$digest"
    return 0
  fi
  return 1
}

download_tarball() {
  local url=$1 dest=$2
  local m
  for m in "${GH_MIRROR_PREFIXES[@]}"; do
    note "下载中…"
    if curl_secure -fL --retry 2 --connect-timeout 12 --max-time 180 --progress-bar -o "$dest" "${m}${url}"; then
      [[ -s "$dest" ]] || continue
      return 0
    fi
    note "换源重试…"
  done
  return 1
}

verify_tarball() {
  local file=$1 digest=$2
  local expect got
  expect="${digest#sha256:}"
  if [[ "$digest" != sha256:* || -z "$expect" ]]; then
    err "无法从 GitHub 获取 SHA256 digest，已中止（拒绝安装未校验二进制）"
    err "请检查网络/API 限流后重试；不会使用无校验的镜像包"
    return 1
  fi
  got=$(sha256sum "$file" 2>/dev/null | awk '{print $1}')
  [[ -z "$got" ]] && got=$(sha256 -q "$file" 2>/dev/null || true)
  if [[ -z "$got" ]]; then
    err "本机缺少 sha256sum，无法校验"
    return 1
  fi
  if [[ "$got" != "$expect" ]]; then
    err "checksum 不匹配（expect=${expect:0:12}… got=${got:0:12}…），拒绝安装"
    return 1
  fi
  ok "SHA256 校验通过"
}

ensure_service_user() {
  if ! getent group "$SVC_USER" >/dev/null 2>&1; then
    if [[ "$OS_KIND" == debian ]]; then
      groupadd --system "$SVC_USER" 2>/dev/null || true
    else
      addgroup -S "$SVC_USER" 2>/dev/null || true
    fi
  fi

  if id "$SVC_USER" >/dev/null 2>&1; then
    local gname; gname=$(id -gn "$SVC_USER" 2>/dev/null || true)
    if [[ "$gname" != "$SVC_USER" ]] && getent group "$SVC_USER" >/dev/null 2>&1; then
      if [[ "$OS_KIND" == debian ]]; then
        usermod -g "$SVC_USER" "$SVC_USER" 2>/dev/null || true
      else
        addgroup "$SVC_USER" "$SVC_USER" 2>/dev/null || true
      fi
    fi
    return 0
  fi

  note "创建服务用户 $SVC_USER …"
  if [[ "$OS_KIND" == debian ]]; then
    useradd -r -s /usr/sbin/nologin -M -d /nonexistent -g "$SVC_USER" "$SVC_USER" 2>/dev/null \
      || useradd -r -s /usr/sbin/nologin -M -g "$SVC_USER" "$SVC_USER" 2>/dev/null \
      || useradd -r -s /usr/sbin/nologin -M "$SVC_USER" || {
        err "创建用户 $SVC_USER 失败"; return 1
      }
  else
    adduser -S -H -D -s /sbin/nologin -G "$SVC_USER" "$SVC_USER" 2>/dev/null \
      || adduser -S -H -D -s /sbin/nologin "$SVC_USER" 2>/dev/null || {
        err "创建用户 $SVC_USER 失败"; return 1
      }
  fi
  id "$SVC_USER" >/dev/null 2>&1 || return 1
}

install_logrotate() {
  local f=/etc/logrotate.d/sing-box
  mkdir -p /etc/logrotate.d 2>/dev/null || true
  cat > "$f" <<'LR'
/var/log/sing-box.log {
    weekly
    rotate 8
    missingok
    notifempty
    compress
    delaycompress
    copytruncate
    su root root
}
LR
  chmod 644 "$f" 2>/dev/null || true
}

install_singbox() {
  local tag ver arch url tmp bin name had stage oldbin="" had_bin=0
  note "检查依赖…"
  ensure_deps || return 1
  ensure_service_user || return 1
  note "获取稳定版号…"
  tag=$(stable_tag)
  ver="${tag#v}"
  arch=$(goarch) || return 1
  name="sing-box-${ver}-linux-${arch}.tar.gz"
  url="https://github.com/${GH_REPO}/releases/download/${tag}/${name}"

  note "预先获取官方 SHA256…"
  local digest
  if ! digest=$(fetch_asset_digest "$tag" "$name"); then
    err "无法获取官方 digest，中止下载（防止安装被篡改的二进制）"
    return 1
  fi

  tmp=$(mktemp -d) || { err "mktemp 失败"; return 1; }
  TMP_CLEANUP+=("$tmp")
  note "下载 ${tag}…"
  if ! download_tarball "$url" "$tmp/sb.tgz"; then
    rm -rf "$tmp"
    err "下载 sing-box ${tag} 失败（GitHub + 镜像都没打通）"
    return 1
  fi
  note "校验…"
  if ! verify_tarball "$tmp/sb.tgz" "$digest"; then
    rm -rf "$tmp"
    return 1
  fi
  note "解压安装…"
  if ! tar -xzf "$tmp/sb.tgz" -C "$tmp"; then
    rm -rf "$tmp"
    err "解压失败"
    return 1
  fi
  bin=$(find "$tmp" -type f -name sing-box | head -n1 || true)
  if [[ -z "$bin" ]]; then
    rm -rf "$tmp"
    err "压缩包里没有 sing-box 二进制"
    return 1
  fi
  ensure_gcompat
  mkdir -p /usr/local/bin
  stage=$(mktemp "${SINGBOX_BIN}.new.XXXXXX") || {
    rm -rf "$tmp"
    err "无法创建临时二进制文件"
    return 1
  }
  if ! install -m 0755 "$bin" "$stage"; then
    rm -f "$stage"
    rm -rf "$tmp"
    err "写入临时二进制失败"
    return 1
  fi
  if ! "$stage" version >/dev/null 2>&1; then
    ensure_gcompat
    if ! "$stage" version >/dev/null 2>&1; then
      rm -f "$stage"
      rm -rf "$tmp"
      err "新的 sing-box 二进制无法执行，旧版本未更改"
      return 1
    fi
  fi
  if [[ -x "$SINGBOX_BIN" ]]; then
    oldbin=$(mktemp "${SINGBOX_BIN}.old.XXXXXX") || {
      rm -f "$stage"
      rm -rf "$tmp"
      err "无法保存现有 sing-box 二进制"
      return 1
    }
    if ! cp -p "$SINGBOX_BIN" "$oldbin"; then
      rm -f "$stage" "$oldbin"
      rm -rf "$tmp"
      err "保存现有 sing-box 二进制失败"
      return 1
    fi
    had_bin=1
  fi
  if ! mv -f "$stage" "$SINGBOX_BIN"; then
    rm -f "$stage" "$oldbin"
    rm -rf "$tmp"
    err "替换 sing-box 二进制失败，旧版本未更改"
    return 1
  fi
  stage=""
  rm -rf "$tmp"
  ensure_conf
  harden_perms
  # 换新二进制后出问题时的统一回滚（装服务失败 / 启动失败共用）
  _bin_rollback() {
    if (( had_bin )) && [[ -f "$oldbin" ]] && mv -f "$oldbin" "$SINGBOX_BIN"; then
      oldbin=""
      QUIET=1 svc_restart || err "旧二进制已恢复，但服务仍未能启动"
      return 0
    fi
    if (( had_bin )); then
      err "旧二进制回滚失败；备份保留在 $oldbin"
    else
      rm -f "$SINGBOX_BIN"
      err "没有可恢复的旧二进制，已移除无法启动的新版本"
    fi
    return 1
  }
  had=$(svc_state)
  if ! install_service; then
    err "服务单元安装失败，正在恢复旧二进制…"
    _bin_rollback
    [[ -n "$stage" ]] && rm -f "$stage"
    return 1
  fi
  if ! install_self; then
    err "面板未能写入 $SINGBOX_SELF（内核已装）"
    note "管道安装需要能访问 ${SINGBOX_URL:-$SINGBOX_SRC_URL}"
    note "可 export SINGBOX_URL=<脚本URL> 后重试，或 bash /path/to/singbox.sh"
  fi
  # 全新安装(absent)也要启动；原先已停止则保持停止（尊重用户意图）
  if [[ "$had" == running || "$had" == failed || "$had" == absent ]]; then
    if ! QUIET=1 svc_restart; then
      err "新版本服务未能启动，正在恢复旧二进制…"
      _bin_rollback
      [[ -n "$stage" ]] && rm -f "$stage"
      return 1
    fi
  else
    # 原先就是停止状态：不擅自启动，但确认新内核能读取现有配置
    if ! "$SINGBOX_BIN" check -c "$CONF" >/dev/null 2>&1; then
      err "新版本 sing-box 无法通过现有配置的校验（服务仍保持停止）"
      err "请修复 /etc/sing-box/config.json 或先启动服务查看日志"
    fi
  fi
  rm -f "$oldbin"
  ok "已安装 sing-box $($SINGBOX_BIN version | awk 'NR==1{print $3}')"
}

fetch_panel() {
  local dest=$1 u m
  u="${SINGBOX_URL:-}"
  if [[ -n "$u" ]]; then
    curl_secure -fsSL --retry 2 --connect-timeout 12 --max-time 60 -o "$dest" "$u" && [[ -s "$dest" ]]
    return
  fi
  for m in "${GH_MIRROR_PREFIXES[@]}"; do
    if curl_secure -fsSL --retry 2 --connect-timeout 12 --max-time 60 -o "$dest" "${m}${SINGBOX_SRC_URL}" \
      && [[ -s "$dest" ]]; then
      return 0
    fi
    rm -f "$dest"
  done
  return 1
}

install_self() {
  local dest="$SINGBOX_SELF" src="" tmp=""
  mkdir -p "$(dirname "$dest")"

  _panel_ok() {
    head -n 5 "$1" 2>/dev/null | grep -q 'singbox\.sh — sing-box'
  }

  _commit_self() {
    local from=$1 staged
    if [[ -e "$dest" && "$from" -ef "$dest" ]]; then
      rm -f /usr/local/bin/sbox
      ok "面板已安装: $dest"
      return 0
    fi
    staged=$(mktemp "${dest}.tmp.XXXXXX") || return 1
    if cat "$from" >"$staged" 2>/dev/null && chmod 0755 "$staged" && _panel_ok "$staged"; then
      if mv -f "$staged" "$dest"; then
        rm -f /usr/local/bin/sbox
        ok "面板已安装: $dest"
        return 0
      fi
    fi
    rm -f "$staged"
    return 1
  }

  # 1) 磁盘上的脚本文件（管道 /dev/fd 不可回读时落到回源）
  src="${BASH_SOURCE[0]:-}"
  if [[ -n "$src" && -f "$src" && -r "$src" ]]; then
    _commit_self "$src" && return 0
  fi
  if [[ -n "${0:-}" && -f "$0" && -r "$0" && "$(basename "$0")" != bash ]]; then
    _commit_self "$0" && return 0
  fi

  # 2) 回源下载。SINGBOX_URL 优先且不加镜像前缀。
  tmp=$(mktemp) || return 1
  if fetch_panel "$tmp" && _commit_self "$tmp"; then
    rm -f "$tmp"
    return 0
  fi
  rm -f "$tmp"

  err "无法安装面板到 $dest"
  note "管道安装需要能访问 ${SINGBOX_URL:-$SINGBOX_SRC_URL}，或 export SINGBOX_URL=<脚本URL>"
  note "也可直接 bash /path/to/singbox.sh"
  return 1
}


install_service() {
  ensure_service_user || return 1
  ensure_conf
  harden_perms
  # Debian 走 journald，日志文件只对 OpenRC 有意义
  if [[ "$OS_KIND" != debian ]]; then
    touch "$LOG_FILE" 2>/dev/null || true
    chown_svc "$LOG_FILE"
    chmod 640 "$LOG_FILE" 2>/dev/null || true
  fi

  if [[ "$OS_KIND" == debian ]]; then
    # 清掉可能存在的 SysV 残留：systemd-sysv-generator 会据 /etc/init.d/sing-box
    # 生成同名单元遮蔽原生单元，并让"是否已安装"的判断失真
    rm -f /etc/init.d/sing-box
    cat > /etc/systemd/system/sing-box.service <<UNIT
# singbox-svc-v: ${SVC_FILES_V}
[Unit]
Description=sing-box service
Documentation=https://sing-box.sagernet.org
After=network-online.target nss-lookup.target
Wants=network-online.target
StartLimitIntervalSec=0

[Service]
Type=simple
User=${SVC_USER}
Group=${SVC_USER}
ExecStart=/usr/local/bin/sing-box run -c /etc/sing-box/config.json
# 不设 ExecReload：sing-box 未处理 SIGHUP，systemctl reload 会直接终止进程
Restart=on-failure
RestartSec=2
UMask=0077

# 绑定特权端口
AmbientCapabilities=CAP_NET_BIND_SERVICE
CapabilityBoundingSet=CAP_NET_BIND_SERVICE
NoNewPrivileges=true

# 沙箱
ProtectSystem=strict
ProtectHome=true
PrivateTmp=true
PrivateDevices=true
ProtectKernelTunables=true
ProtectKernelModules=true
ProtectControlGroups=true
ProtectClock=true
ProtectHostname=true
LockPersonality=true
RestrictSUIDSGID=true
RestrictRealtime=true
RestrictNamespaces=true
SystemCallArchitectures=native
# 配置与证书只读(root:sing-box 640)，仅 ACME 数据目录与日志可写；
# 前缀 - 表示路径不存在时忽略，避免服务起不来
ReadWritePaths=-/etc/sing-box/cert/acme -/var/log/sing-box.log
LimitNOFILE=1048576
LimitNPROC=65535

[Install]
WantedBy=multi-user.target
UNIT
    if ! systemctl daemon-reload; then
      err "systemctl daemon-reload 失败（当前环境可能没有运行 systemd）"
      return 1
    fi
    # 某些系统（SysV 兼容层）下 systemctl enable 会返回非零但实际已生效，
    # 因此以 is-enabled 的结果为准，避免误报
    systemctl enable sing-box >/dev/null 2>&1 || true
    if [[ "$(systemctl is-enabled sing-box 2>/dev/null)" != enabled ]]; then
      note "开机自启未生效（systemctl is-enabled: $(systemctl is-enabled sing-box 2>/dev/null || echo 未知)）"
    fi
  else
    local gname; gname=$(svc_group)
    cat > /etc/init.d/sing-box <<RC
#!/sbin/openrc-run
# singbox-svc-v: ${SVC_FILES_V}
description="sing-box service"
command="/usr/local/bin/sing-box"
command_args="run -c /etc/sing-box/config.json"
command_user="${SVC_USER}:${gname}"
supervisor=supervise-daemon
respawn_delay=2
respawn_max=0
pidfile="/run/sing-box.pid"
output_log="/var/log/sing-box.log"
error_log="/var/log/sing-box.log"

depend() {
    need net
    after firewall
}

start_pre() {
    # /etc/sing-box 的属主与权限由面板 harden_perms 统一收敛，这里不再重复断言：
    # 两处都断言时，升级后的旧脚本会与新策略互相"纠正"，每次启服务都刷 correcting 提示
    checkpath --file --owner ${SVC_USER}:${gname} --mode 0640 /var/log/sing-box.log
}
RC
    chmod +x /etc/init.d/sing-box
    mkdir -p /etc/conf.d
    cat > /etc/conf.d/sing-box <<CONF
# singbox-svc-v: ${SVC_FILES_V}
rc_ulimit="-n 1048576"
CONF
    chmod 644 /etc/conf.d/sing-box
    rc-update add sing-box default >/dev/null 2>&1 || true
    install_logrotate
  fi
}

svc_do() {
  local op=$1
  if [[ "$OS_KIND" == debian ]]; then
    case "$op" in
      start) systemctl start sing-box ;;
      stop) systemctl stop sing-box 2>/dev/null || true ;;
      restart)
        systemctl reset-failed sing-box 2>/dev/null || true
        systemctl restart sing-box
        ;;
      logs) journalctl -u sing-box -n 30 --no-pager 2>/dev/null || true ;;
      purge)
        systemctl disable sing-box >/dev/null 2>&1 || true
        # 同时清掉 SysV 残留，否则生成器会把它"复活"成同名单元
        rm -f /etc/systemd/system/sing-box.service /etc/init.d/sing-box
        systemctl daemon-reload
        ;;
    esac
  else
    case "$op" in
      start) rc-service sing-box start ;;
      stop) rc-service sing-box stop 2>/dev/null || true ;;
      restart) rc-service sing-box restart 2>/dev/null || rc-service sing-box start ;;
      logs) tail -n 30 "$LOG_FILE" 2>/dev/null || true ;;
      purge)
        rc-update del sing-box default >/dev/null 2>&1 || true
        rm -f /etc/init.d/sing-box /etc/conf.d/sing-box
        ;;
    esac
  fi
}

# 服务定义（systemd unit / OpenRC init 脚本）是否与当前面板一致。
# 判据有二：版本标记匹配，且 OpenRC 脚本里没有再对配置目录做 checkpath 断言
# （重复断言会让服务与面板互相"纠正"权限，表现为每次启动刷 correcting 提示）
svc_files_current() {
  local f
  if [[ "$OS_KIND" == debian ]]; then f=/etc/systemd/system/sing-box.service
  else f=/etc/init.d/sing-box; fi
  [[ -f "$f" ]] || return 1
  grep -q "^# singbox-svc-v: ${SVC_FILES_V}$" "$f" || return 1
  if [[ "$OS_KIND" != debian ]] && grep -q 'checkpath --directory' "$f"; then
    return 1
  fi
  return 0
}

# svc_start / svc_restart 公共前置：确认内核、收敛权限、刷新过期的服务定义
svc_ready() {
  need_bin || return 1
  harden_perms
  if [[ "$(svc_state)" == absent ]]; then
    install_service || return 1
  elif ! svc_files_current; then
    note "服务定义已过期，正在更新…"
    install_service || return 1
  fi
  if [[ "$OS_KIND" != debian ]]; then
    touch "$LOG_FILE" 2>/dev/null || true
    chown_svc "$LOG_FILE"
  fi
  return 0
}

svc_start() {
  need_bin || return 1
  ensure_conf
  svc_ready || return 1
  svc_do start
  sleep 0.2
  if [[ "$(svc_state)" != running ]]; then
    err "启动失败"
    svc_do logs
    return 1
  fi
  ok "服务已启动"
}

svc_stop() {
  if [[ ! -x "$SINGBOX_BIN" && "$(svc_state)" == absent ]]; then
    err "未安装"
    return 1
  fi
  [[ "$(svc_state)" == absent ]] && return 0
  svc_do stop
  if [[ "$(svc_state)" == running ]]; then
    err "停止失败"
    return 1
  fi
  ok "服务已停止"
}

svc_restart() {
  need_bin || return 1
  ensure_service_user || true
  svc_ready || return 1
  svc_do restart
  sleep 0.35
  if [[ "$(svc_state)" != running ]]; then
    svc_do start
    sleep 0.35
  fi
  if [[ "$(svc_state)" == running ]]; then
    [[ -n "${QUIET:-}" ]] || ok "服务已启动"
    return 0
  fi
  if [[ -z "${QUIET:-}" ]]; then
    err "服务没起来，最近日志："
    svc_do logs
    ls -la "$CONF_DIR" 2>/dev/null || true
    id "$SVC_USER" 2>/dev/null || true
  fi
  return 1
}

dashboard() {
  ui_reset
  ui_fill_info
  ui_menu 1 安装
  ui_menu 2 添加
  ui_menu 3 编辑
  ui_menu 4 分享
  ui_menu 5 删除
  ui_menu 6 启动
  ui_menu 7 停止
  ui_menu 8 重启
  ui_menu 9 备份
  ui_menu 10 恢复
  ui_menu 11 卸载
}

pick_node_tag() {
  local tags=() tag i=1 c
  while IFS= read -r tag; do
    [[ -n "$tag" ]] && tags+=("$tag")
  done <<EOF
$(jq -r '
    .inbounds[]?
    | select((.tag // "") | startswith("ss-inner-") | not)
    | select(.listen_port != null)
    | .tag
  ' "$CONF" 2>/dev/null)
EOF
  if ((${#tags[@]}==0)); then
    err "没有可操作的节点"
    return 3
  fi
  ((${#UI_IK[@]})) || ui_fill_info
  UI_MK=(); UI_ML=()
  for tag in "${tags[@]}"; do
    ui_menu "$i" "$tag"
    ((i++)) || true
  done
  { ui_paint 3; } >&2
  while :; do
    c=$(prompt "选择" "" "q返回") || return 2
    [[ "$c" == q || "$c" == Q ]] && return 2
    [[ "$c" =~ ^[0-9]+$ ]] || continue
    (( c >= 1 && c <= ${#tags[@]} )) || continue
    printf '%s' "${tags[$((c-1))]}"
    return 0
  done
}

need_bin() {
  if [[ ! -x "$SINGBOX_BIN" ]]; then
    err "先安装"
    return 1
  fi
  ensure_conf
}

require_ver() {
  local min_ver=$1 feat=$2 have
  have=$(sb_version)
  if [[ "$have" == "未安装" ]]; then
    err "未安装 sing-box"
    return 1
  fi
  if [[ -z "$have" || "$have" == "未知" ]]; then
    err "$feat 需要 sing-box >= $min_ver，但无法读取当前版本"
    err "二进制可能损坏，或 Alpine 缺少 gcompat（apk add gcompat）"
    return 1
  fi
  ver_ge "$have" "$min_ver" || { err "$feat 需要 sing-box >= $min_ver，当前 $have。请先更新。"; return 1; }
}

# ---------- inbound 构造器 ----------
# 添加节点与 --self-test 共用同一份 schema 定义：只生成 JSON，不做交互与写盘。
# 约定：<tag> <port|""> … [listen]；port 传空串表示不监听的内层 inbound。

ib_ss() {  # <tag> <port|""> <ss2022_password> [listen]
  jq -n --arg tag "$1" --arg port "$2" --arg pass "$3" --arg listen "${4:-$(listen_addr)}" '
    {type:"shadowsocks", tag:$tag, method:"2022-blake3-aes-128-gcm", password:$pass}
    + (if $port == "" then {}
       else {listen:$listen, listen_port:($port|tonumber), tcp_fast_open:true,
             multiplex:{enabled:true, padding:true}} end)'
}

ib_ss_st() {  # <tag> <port> <shadowtls_password> <handshake_server> <inner_tag> [listen]
  jq -n --arg tag "$1" --argjson port "$2" --arg pass "$3" --arg hs "$4" --arg inner "$5" \
    --arg listen "${6:-$(listen_addr)}" '{
      type:"shadowtls", tag:$tag, listen:$listen, listen_port:$port,
      tcp_fast_open:true, detour:$inner, version:3,
      users:[{name:"default", password:$pass}],
      handshake:{server:$hs, server_port:443},
      strict_mode:true
    }'
}

ib_vless() {  # <tag> <port> <uuid> <sni> <reality_private_key> <short_id> [listen]
  jq -n --arg tag "$1" --argjson port "$2" --arg uuid "$3" --arg sni "$4" \
    --arg priv "$5" --arg sid "$6" --arg listen "${7:-$(listen_addr)}" '{
      type:"vless", tag:$tag, listen:$listen, listen_port:$port, tcp_fast_open:true,
      users:[{name:"default", uuid:$uuid, flow:"xtls-rprx-vision"}],
      tls:{
        enabled:true,
        server_name:$sni,
        reality:{
          enabled:true,
          handshake:{server:$sni, server_port:443},
          private_key:$priv,
          short_id:[$sid]
        }
      }
    }'
}

ib_vmess() {  # <tag> <port> <uuid> [tls_json|""] [listen]
  jq -n --arg tag "$1" --argjson port "$2" --arg uuid "$3" --argjson tls "${4:-null}" \
    --arg listen "${5:-$(listen_addr)}" '{
      type:"vmess", tag:$tag, listen:$listen, listen_port:$port, tcp_fast_open:true,
      users:[{name:"default", uuid:$uuid, alterId:0}]
    } + (if $tls == null then {} else {tls:$tls} end)'
}

ib_hy2() {  # <tag> <port> <password> <obfs_password> <tls_json> [listen]
  jq -n --arg tag "$1" --argjson port "$2" --arg pass "$3" --arg opw "$4" \
    --argjson tls "$5" --arg listen "${6:-$(listen_addr)}" '{
      type:"hysteria2", tag:$tag, listen:$listen, listen_port:$port,
      ignore_client_bandwidth:true,
      obfs:{type:"salamander", password:$opw},
      users:[{name:"default", password:$pass}],
      tls:$tls,
      masquerade:{
        type:"proxy",
        url:"https://www.bing.com",
        rewrite_host:true
      }
    }'
}

ib_anytls() {  # <tag> <port> <password> <tls_json> [listen]
  jq -n --arg tag "$1" --argjson port "$2" --arg pass "$3" --argjson tls "$4" \
    --arg listen "${5:-$(listen_addr)}" '{
      type:"anytls", tag:$tag, listen:$listen, listen_port:$port, tcp_fast_open:true,
      users:[{name:"default", password:$pass}],
      tls:$tls
    }'
}

ib_snell() {  # <tag> <port> <psk> [listen]
  jq -n --arg tag "$1" --argjson port "$2" --arg psk "$3" --arg listen "${4:-$(listen_addr)}" '{
      type:"snell", tag:$tag, listen:$listen, listen_port:$port, tcp_fast_open:true,
      version:6, psk:$psk, mode:"default"
    }'
}

# ---------- 添加节点 ----------

add_menu() {
  need_bin || return 1
  ((${#UI_IK[@]})) || ui_fill_info
  UI_MK=(); UI_ML=()
  ui_menu 1 Shadowsocks
  ui_menu 2 VLESS
  ui_menu 3 VMess
  ui_menu 4 Hysteria2
  ui_menu 5 AnyTLS
  ui_menu 6 Snell
  ui_paint 3
  local c
  while :; do
    c=$(prompt "选择" "" "q返回") || return 2
    case "$c" in
      1) add_ss; return $? ;;
      2) add_vless; return $? ;;
      3) add_vmess; return $? ;;
      4) add_hy2; return $? ;;
      5) add_anytls; return $? ;;
      6) add_snell; return $? ;;
      q|Q) return 2 ;;
    esac
  done
}

add_ss() {
  local port pass tag obj hs pass_st inner st ss
  port=$(ask_port) || return $?
  pass=$(ss2022_pass_new) || { err "SS2022 密码生成失败"; return 1; }
  ss2022_pass_ok "$pass" || { err "SS2022 密码生成失败"; return 1; }
  tag=$(tag_for shadowsocks "$port")
  if ask_yn "ShadowTLS 插件" y; then
    hs=$(ask_sni "www.microsoft.com") || return $?
    pass_st=$(rand_str 18 18) || { err "ShadowTLS 密码生成失败"; return 1; }
    inner=$(inner_tag_for "$port")
    assert_tags_free "$tag" "$inner" || return 1
    st=$(ib_ss_st "$tag" "$port" "$pass_st" "$hs" "$inner")
    ss=$(ib_ss "$inner" "" "$pass")
    conf_add_inbound "$st" || return 1
    conf_add_inbound "$ss" || { drop_node "$tag"; return 1; }
    node_commit "$tag" "ss+st :$port" "$(jq -n \
      --argjson port "$port" --arg inner "$inner" --arg hs "$hs" \
      '{kind:"shadowsocks", plugin:"shadowtls", port:$port, inner_tag:$inner, handshake:$hs}')" \
      || return 1
    firewall_hint "$port" tcp
    return 0
  fi
  assert_tags_free "$tag" || return 1
  conf_add_inbound "$(ib_ss "$tag" "$port" "$pass")" || return 1
  node_commit "$tag" "ss :$port" "$(jq -n --argjson port "$port" \
    '{kind:"shadowsocks", port:$port}')" || return 1
  firewall_hint "$port" tcp
}

add_vless() {
  local port sni uuid pair priv pub sid tag
  port=$(ask_port) || return $?
  sni=$(ask_sni "www.apple.com") || return $?
  uuid=$("$SINGBOX_BIN" generate uuid)
  pair=$("$SINGBOX_BIN" generate reality-keypair)
  priv=$(printf '%s' "$pair" | awk '/PrivateKey/{print $2}')
  pub=$(printf '%s' "$pair" | awk '/PublicKey/{print $2}')
  [[ -n "$priv" && -n "$pub" ]] || { err "reality-keypair 生成失败"; return 1; }
  sid=$(openssl rand -hex 4)
  tag=$(tag_for vless "$port")
  assert_tags_free "$tag" || return 1
  conf_add_inbound "$(ib_vless "$tag" "$port" "$uuid" "$sni" "$priv" "$sid")" || return 1
  node_commit "$tag" "vless :$port" \
    "$(jq -n \
      --argjson port "$port" --arg sni "$sni" \
      --arg pbk "$pub" --arg sid "$sid" --arg uuid "$uuid" \
      '{kind:"vless", port:$port, sni:$sni, public_key:$pbk, short_id:$sid, uuid:$uuid}')" \
    "$(jq -n \
      --arg pbk "$pub" --arg sid "$sid" --arg sni "$sni" --arg uuid "$uuid" \
      '{public_key:$pbk, short_id:$sid, sni:$sni, uuid:$uuid}')" || return
  firewall_hint "$port" tcp
}

add_vmess() {
  local port uuid tag obj sni tlsj insecure=0
  port=$(ask_port) || return $?
  uuid=$("$SINGBOX_BIN" generate uuid)
  tag=$(tag_for vmess "$port")
  assert_tags_free "$tag" || return 1

  note "默认启用 TLS（明文 VMess 极易被探测）"
  if ask_yn "启用 TLS" y; then
    sni=$(ask_sni "www.bing.com") || return $?
    choose_tls "$sni" || return $?
    insecure=$TLS_INSECURE
    tlsj=$(build_tls_json "$sni" "$TLS_MODE" "$TLS_EMAIL") || return 1
    conf_add_inbound "$(ib_vmess "$tag" "$port" "$uuid" "$tlsj")" || { cert_gc; return 1; }
    node_commit "$tag" "vmess-tls :$port" "$(jq -n \
      --argjson port "$port" --arg uuid "$uuid" --arg sni "$sni" \
      --argjson insecure "$insecure" \
      '{kind:"vmess", port:$port, uuid:$uuid, tls:true, sni:$sni, insecure:($insecure|tostring)}')" || return
  else
    err "警告：明文 VMess 不推荐用于公网"
    ask_yn "仍要继续添加明文 VMess" n || return 2
    conf_add_inbound "$(ib_vmess "$tag" "$port" "$uuid")" || return 1
    node_commit "$tag" "vmess :$port" "$(jq -n --argjson port "$port" --arg uuid "$uuid" \
      '{kind:"vmess", port:$port, uuid:$uuid, tls:false}')" || return
  fi
  firewall_hint "$port" tcp
}

add_hy2() {
  local port sni pass obfs_pw tag tlsj insecure
  port=$(ask_port) || return $?
  sni=$(ask_sni "www.bing.com") || return $?
  pass=$(rand_str 18 18) || { err "密码生成失败"; return 1; }
  obfs_pw=$(rand_str 16 16) || { err "混淆密码生成失败"; return 1; }
  tag=$(tag_for hy2 "$port")
  assert_tags_free "$tag" || return 1
  choose_tls "$sni" || return $?
  insecure=$TLS_INSECURE
  tlsj=$(build_tls_json "$sni" "$TLS_MODE" "$TLS_EMAIL" '["h3"]') || return 1
  conf_add_inbound "$(ib_hy2 "$tag" "$port" "$pass" "$obfs_pw" "$tlsj")" || { cert_gc; return 1; }
  node_commit "$tag" "hy2 :$port" "$(jq -n \
    --argjson port "$port" --arg sni "$sni" \
    --argjson insecure "$insecure" \
    '{kind:"hysteria2", port:$port, sni:$sni, insecure:($insecure|tostring)}')" || return
  firewall_hint "$port" udp tcp
}

add_anytls() {
  require_ver "$MIN_ANYTLS" "AnyTLS" || return 1
  local port sni pass tag tlsj insecure
  port=$(ask_port) || return $?
  sni=$(ask_sni "www.microsoft.com") || return $?
  pass=$(rand_str 18 18) || { err "密码生成失败"; return 1; }
  tag=$(tag_for anytls "$port")
  assert_tags_free "$tag" || return 1
  choose_tls "$sni" || return $?
  insecure=$TLS_INSECURE
  tlsj=$(build_tls_json "$sni" "$TLS_MODE" "$TLS_EMAIL" '["h2","http/1.1"]') || return 1
  conf_add_inbound "$(ib_anytls "$tag" "$port" "$pass" "$tlsj")" || { cert_gc; return 1; }
  node_commit "$tag" "anytls :$port" "$(jq -n \
    --argjson port "$port" --arg sni "$sni" \
    --argjson insecure "$insecure" \
    '{kind:"anytls", port:$port, sni:$sni, insecure:($insecure|tostring)}')" || return
  firewall_hint "$port" tcp
}

add_snell() {
  require_ver "$MIN_SNELL" "Snell v6" || return 1
  local port psk tag
  port=$(ask_port) || return $?
  psk=$(rand_str 24 24) || { err "PSK 生成失败"; return 1; }
  tag=$(tag_for snell "$port")
  assert_tags_free "$tag" || return 1
  conf_add_inbound "$(ib_snell "$tag" "$port" "$psk")" || return 1
  node_commit "$tag" "snell :$port" "$(jq -n \
    --argjson port "$port" \
    '{kind:"snell", port:$port, mode:"default"}')" || return
  firewall_hint "$port" tcp
}

del_node() {
  need_bin || return 1
  local tag inner e snap
  tag=$(pick_node_tag); e=$?
  (( e != 0 )) && return "$e"
  ask_yn "确认删除 $tag" n || return 2
  inner=$(inner_of "$tag")
  snap=$(mktemp -d) || return 1
  TMP_CLEANUP+=("$snap")
  [[ -f "$CONF" ]] || { rm -rf "$snap"; return 1; }
  snap_conf "$snap" || { rm -rf "$snap"; return 1; }
  conf_del_tag "$tag" || { restore_conf_snap "$snap"; rm -rf "$snap"; return 1; }
  if [[ -n "$inner" ]]; then
    conf_del_tag "$inner" || { restore_conf_snap "$snap"; rm -rf "$snap"; return 1; }
  fi
  meta_del_node "$tag" || true
  keys_del "$tag" || true
  if apply_conf; then
    rm -rf "$snap"
    cert_gc
    meta_gc
    ok "已删除 $tag"
  else
    restore_conf_snap "$snap"
    QUIET=1 svc_restart || true
    rm -rf "$snap"
    err "删除失败，已恢复"
    return 1
  fi
}

# ---------- 编辑节点 ----------

edit_node() {
  need_bin || return 1
  local tag e typ
  tag=$(pick_node_tag); e=$?
  (( e != 0 )) && return "$e"
  typ=$(ib_get "$tag" '.type')
  note "编辑: $tag ($typ)"
  edit_snapshot || return 1
  case "$typ" in
    shadowsocks) edit_ss "$tag" ;;
    shadowtls)   edit_st "$tag" ;;
    vless)       edit_vless "$tag" ;;
    vmess)       edit_vmess "$tag" ;;
    hysteria2)   edit_hy2 "$tag" ;;
    anytls)      edit_anytls "$tag" ;;
    snell)       edit_snell "$tag" ;;
    *) edit_snap_clear; err "不支持编辑的类型: $typ"; return 1 ;;
  esac
}

# 应用配置；失败则回滚快照。成功后静默分享（不追问地址）
edit_finish() {
  local tag=$1 label=${2:-已更新}
  local port
  if ! apply_conf; then
    edit_abort "应用失败"
    return 1
  fi
  edit_snap_clear
  cert_gc
  meta_gc
  port=$(ib_get "$tag" '.listen_port')
  ok "$label $tag${port:+ :$port}"
  show_share "$tag" quiet
}

# 读新端口。通过全局 EDIT_PORT / EDIT_TAG 返回（不可放进 $()）
edit_common() {
  local tag=$1 kind=$2 port
  port=$(ib_get "$tag" '.listen_port')
  EDIT_PORT=$(ask_port "$port" "$tag") || { edit_abort; return 1; }
  EDIT_TAG=$(tag_for "$kind" "$EDIT_PORT")
}

# 取 inbound 并用 jq 改写；读取或解析失败都会回滚当前编辑事务
edit_patch() {
  local tag=$1 o
  shift
  o=$(ib_json "$tag") || { edit_abort; return 1; }
  printf '%s' "$o" | jq "$@" || { edit_abort; return 1; }
}

# 写入 inbound、改 tag、更新 meta。失败回滚。
edit_put() {
  local old=$1 obj=$2 patch=${3-} old_inner=${4-} new_inner=${5-}
  conf_put_inbound "$old" "$obj" || { edit_abort; return 1; }
  if [[ -n "$old_inner" ]]; then
    node_retag "$old" "$EDIT_TAG" "$old_inner" "$new_inner" || { edit_abort; return 1; }
  else
    node_retag "$old" "$EDIT_TAG" || { edit_abort; return 1; }
  fi
  if [[ -n "$patch" ]]; then
    jq_write "$META" --arg t "$EDIT_TAG" --argjson patch "$patch" \
      'if .nodes[$t] then .nodes[$t] += $patch else . end' || { edit_abort; return 1; }
  fi
}

edit_ss() {
  local tag=$1 pass npass obj
  edit_common "$tag" shadowsocks || return 1
  pass=$(ib_get "$tag" '.password')
  npass=$(ask_ss2022_pass "$pass") || { edit_abort; return 1; }
  obj=$(edit_patch "$tag" --argjson port "$EDIT_PORT" --arg pass "$npass" --arg tag "$EDIT_TAG" \
    '.listen_port=$port | .password=$pass | .tag=$tag') || return 1
  edit_put "$tag" "$obj" "$(jq -n --argjson port "$EDIT_PORT" '{port:$port}')" || return 1
  edit_finish "$EDIT_TAG" "已更新 ss"
}

edit_st() {
  local tag=$1 inner hs st_pass ss_pass nhs nst nss ninner obj_st obj_ss
  inner=$(inner_of "$tag")
  [[ -n "$inner" ]] || { edit_abort "找不到 ShadowTLS 内层"; return 1; }
  edit_common "$tag" shadowtls || return 1
  hs=$(ib_get "$tag" '.handshake.server')
  st_pass=$(ib_get "$tag" '.users[0].password')
  ss_pass=$(ib_get "$inner" '.password')
  nhs=$(ask_sni "$hs") || { edit_abort; return 1; }
  nst=$(ask_secret_edit "ShadowTLS 密码" "$st_pass" 18) || { edit_abort; return 1; }
  nss=$(ask_ss2022_pass "$ss_pass") || { edit_abort; return 1; }
  [[ -n "$nst" ]] || { edit_abort "密码不能为空"; return 1; }
  ninner=$(inner_tag_for "$EDIT_PORT")

  obj_st=$(edit_patch "$tag" \
    --argjson port "$EDIT_PORT" --arg pass "$nst" --arg hs "$nhs" \
    --arg tag "$EDIT_TAG" --arg det "$ninner" \
    '.listen_port=$port
     | .users[0].password=$pass
     | .handshake.server=$hs
     | .tag=$tag
     | .detour=$det') || return 1
  obj_ss=$(edit_patch "$inner" --arg pass "$nss" --arg tag "$ninner" \
    '.password=$pass | .tag=$tag') || return 1
  conf_put_inbound "$inner" "$obj_ss" || { edit_abort; return 1; }
  edit_put "$tag" "$obj_st" "$(jq -n --argjson port "$EDIT_PORT" --arg hs "$nhs" --arg inn "$ninner" '{port:$port, handshake:$hs, inner_tag:$inn}')" "$inner" "$ninner" || return 1
  edit_finish "$EDIT_TAG" "已更新 ss+st"
}

edit_vless() {
  local tag=$1 sni uuid priv pub sid nsni nuuid obj pair npriv npub nsid
  edit_common "$tag" vless || return 1
  sni=$(ib_get "$tag" '.tls.server_name')
  uuid=$(ib_get "$tag" '.users[0].uuid')
  priv=$(ib_get "$tag" '.tls.reality.private_key')
  sid=$(ib_get "$tag" '.tls.reality.short_id[0]')
  pub=$(keys_get "$tag" public_key)
  [[ -z "$pub" ]] && pub=$(jq -r --arg t "$tag" '.nodes[$t].public_key // empty' "$META" 2>/dev/null || true)
  nsni=$(ask_sni "$sni") || { edit_abort; return 1; }
  nuuid=$uuid; npriv=$priv; npub=$pub; nsid=$sid
  if ask_yn "重新生成 UUID" n; then
    nuuid=$("$SINGBOX_BIN" generate uuid)
  fi
  if ask_yn "重新生成 Reality 密钥与 short_id" n; then
    pair=$("$SINGBOX_BIN" generate reality-keypair)
    npriv=$(printf '%s' "$pair" | awk '/PrivateKey/{print $2}')
    npub=$(printf '%s' "$pair" | awk '/PublicKey/{print $2}')
    [[ -n "$npriv" && -n "$npub" ]] || { edit_abort "reality-keypair 生成失败"; return 1; }
    nsid=$(openssl rand -hex 4)
  fi
  obj=$(edit_patch "$tag" \
    --argjson port "$EDIT_PORT" --arg uuid "$nuuid" \
    --arg sni "$nsni" --arg priv "$npriv" --arg sid "$nsid" --arg tag "$EDIT_TAG" \
    '.listen_port=$port
     | .tag=$tag
     | .users[0].uuid=$uuid
     | .tls.server_name=$sni
     | .tls.reality.handshake.server=$sni
     | .tls.reality.private_key=$priv
     | .tls.reality.short_id=[$sid]') || return 1
  edit_put "$tag" "$obj" "$(jq -n --argjson port "$EDIT_PORT" --arg sni "$nsni" \
    --arg pbk "$npub" --arg sid "$nsid" --arg uuid "$nuuid" \
    '{port:$port, sni:$sni, public_key:$pbk, short_id:$sid, uuid:$uuid}')" || return 1
  keys_put "$EDIT_TAG" "$(jq -n \
    --arg pbk "$npub" --arg sid "$nsid" --arg sni "$nsni" --arg uuid "$nuuid" \
    '{public_key:$pbk, short_id:$sid, sni:$sni, uuid:$uuid}')" || { edit_abort; return 1; }
  edit_finish "$EDIT_TAG" "已更新 vless"
}

edit_vmess() {
  local tag=$1 uuid tls_on sni nuuid nsni obj tlsj patch
  edit_common "$tag" vmess || return 1
  uuid=$(ib_get "$tag" '.users[0].uuid')
  tls_on=$(ib_get "$tag" '.tls.enabled')
  sni=$(ib_get "$tag" '.tls.server_name')
  nuuid=$uuid
  if ask_yn "重新生成 UUID" n; then
    nuuid=$("$SINGBOX_BIN" generate uuid)
  fi
  if [[ "$tls_on" == true ]]; then
    nsni=$(ask_sni "${sni:-www.bing.com}") || { edit_abort; return 1; }
    tlsj=$(rebuild_tls_json "$tag" "$nsni") || { edit_abort; return 1; }
    obj=$(edit_patch "$tag" --argjson port "$EDIT_PORT" --arg uuid "$nuuid" \
      --argjson tls "$tlsj" --arg tag "$EDIT_TAG" \
      '.listen_port=$port | .users[0].uuid=$uuid | .tls=$tls | .tag=$tag') || return 1
    patch=$(jq -n --argjson port "$EDIT_PORT" --arg uuid "$nuuid" --arg sni "$nsni" \
      '{port:$port, uuid:$uuid, sni:$sni, tls:true}')
  else
    obj=$(edit_patch "$tag" --argjson port "$EDIT_PORT" --arg uuid "$nuuid" --arg tag "$EDIT_TAG" \
      '.listen_port=$port | .users[0].uuid=$uuid | .tag=$tag') || return 1
    patch=$(jq -n --argjson port "$EDIT_PORT" --arg uuid "$nuuid" '{port:$port, uuid:$uuid}')
  fi
  edit_put "$tag" "$obj" "$patch" || return 1
  edit_finish "$EDIT_TAG" "已更新 vmess"
}

edit_hy2() {
  local tag=$1 pass opw sni npass nopw nsni obj tlsj
  edit_common "$tag" hy2 || return 1
  pass=$(ib_get "$tag" '.users[0].password')
  opw=$(ib_get "$tag" '.obfs.password')
  sni=$(ib_get "$tag" '.tls.server_name')
  nsni=$(ask_sni "$sni") || { edit_abort; return 1; }
  npass=$(ask_secret_edit "密码" "$pass" 18) || { edit_abort; return 1; }
  nopw=$(ask_secret_edit "混淆密码" "$opw" 16) || { edit_abort; return 1; }
  [[ -n "$npass" && -n "$nopw" ]] || { edit_abort "密码不能为空"; return 1; }
  tlsj=$(rebuild_tls_json "$tag" "$nsni" '["h3"]') || { edit_abort; return 1; }
  obj=$(edit_patch "$tag" \
    --argjson port "$EDIT_PORT" --arg pass "$npass" --arg opw "$nopw" \
    --argjson tls "$tlsj" --arg tag "$EDIT_TAG" \
    '.listen_port=$port | .tag=$tag
     | .users[0].password=$pass | .obfs.password=$opw | .tls=$tls') || return 1
  edit_put "$tag" "$obj" "$(jq -n --argjson port "$EDIT_PORT" --arg sni "$nsni" '{port:$port, sni:$sni}')" || return 1
  edit_finish "$EDIT_TAG" "已更新 hy2"
}

edit_anytls() {
  local tag=$1 pass sni npass nsni obj tlsj
  edit_common "$tag" anytls || return 1
  pass=$(ib_get "$tag" '.users[0].password')
  sni=$(ib_get "$tag" '.tls.server_name')
  nsni=$(ask_sni "$sni") || { edit_abort; return 1; }
  npass=$(ask_secret_edit "密码" "$pass" 18) || { edit_abort; return 1; }
  [[ -n "$npass" ]] || { edit_abort "密码不能为空"; return 1; }
  tlsj=$(rebuild_tls_json "$tag" "$nsni" '["h2","http/1.1"]') || { edit_abort; return 1; }
  obj=$(edit_patch "$tag" \
    --argjson port "$EDIT_PORT" --arg pass "$npass" --argjson tls "$tlsj" --arg tag "$EDIT_TAG" \
    '.listen_port=$port | .tag=$tag | .users[0].password=$pass | .tls=$tls') || return 1
  edit_put "$tag" "$obj" "$(jq -n --argjson port "$EDIT_PORT" --arg sni "$nsni" '{port:$port, sni:$sni}')" || return 1
  edit_finish "$EDIT_TAG" "已更新 anytls"
}

edit_snell() {
  local tag=$1 psk npsk obj
  edit_common "$tag" snell || return 1
  psk=$(ib_get "$tag" '.psk')
  npsk=$(ask_secret_edit "PSK" "$psk" 24) || { edit_abort; return 1; }
  [[ -n "$npsk" ]] || { edit_abort "PSK 不能为空"; return 1; }
  obj=$(edit_patch "$tag" --argjson port "$EDIT_PORT" --arg psk "$npsk" --arg tag "$EDIT_TAG" \
    '.listen_port=$port | .psk=$psk | .tag=$tag') || return 1
  edit_put "$tag" "$obj" "$(jq -n --argjson port "$EDIT_PORT" '{port:$port}')" || return 1
  edit_finish "$EDIT_TAG" "已更新 snell"
}

backup_dest_ok() {
  local dest=$1 parent real_parent conf_real
  [[ "$dest" == /* ]] || { err "备份路径必须是绝对路径"; return 1; }
  [[ "$dest" != */ ]] || { err "备份路径不能是目录"; return 1; }
  parent=$(dirname "$dest")
  [[ -d "$parent" && -w "$parent" ]] || { err "备份目录不可写: $parent"; return 1; }
  real_parent=$(cd "$parent" && pwd -P) || return 1
  conf_real=$(cd "$CONF_DIR" 2>/dev/null && pwd -P || printf '%s' "$CONF_DIR")
  case "$real_parent" in
    "$conf_real"|"$conf_real"/*)
      err "不能把备份写进配置目录"
      return 1
      ;;
  esac
  # [[ -e ]] 对悬空符号链接为假，必须先拒绝链接本身
  if [[ -L "$dest" ]]; then
    err "备份目标不能是符号链接"
    return 1
  fi
  if [[ -e "$dest" ]]; then
    [[ -f "$dest" ]] || { err "备份目标已存在且不是普通文件"; return 1; }
  fi
  return 0
}

backup_conf() {
  [[ -d "$CONF_DIR" ]] || { err "没有可备份的配置目录"; return 1; }
  local dest ts
  ts=$(date +%Y%m%d-%H%M%S)
  dest=$(prompt "备份路径" "/root/singbox-backup-${ts}.tar.gz") || return 2
  [[ -n "$dest" ]] || return 1
  backup_dest_ok "$dest" || return 1
  if ! tar -czf "$dest" -C / etc/sing-box 2>/dev/null; then
    rm -f "$dest"   # 避免留下半截的备份文件被误当成可用备份
    err "备份失败"
    return 1
  fi
  chmod 600 "$dest" 2>/dev/null || true
  ok "已备份到 $dest"
}

# 先校验全部成员再写入。BusyBox tar -t 会改写绝对路径和 ..，不能用来做安全判断。
# 退出码：0 成功；2 策略拒绝；3 缺少 node；其它为解压失败。
archive_extract_checked() {
  local src=$1 dest=$2
  command -v node >/dev/null 2>&1 || { err "恢复校验需要 node"; return 3; }
  node - "$src" "$dest" <<'JS'
const fs = require("fs");
const path = require("path");
const zlib = require("zlib");
const src = process.argv[2];
const dest = path.resolve(process.argv[3]);
// 防解压炸弹：先限制压缩包体积，再限制解压后总体积
const MAX_GZ = 64 * 1024 * 1024;
const MAX_RAW = 256 * 1024 * 1024;
try { if (fs.statSync(src).size > MAX_GZ) process.exit(1); }
catch (e) { process.exit(1); }
let buf;
try {
  buf = zlib.gunzipSync(fs.readFileSync(src), { maxOutputLength: MAX_RAW });
}
catch (e) { process.exit(1); }
if (!buf || buf.length > MAX_RAW) process.exit(1);
const root = path.resolve(dest, "etc/sing-box");
const entries = [];
let pos = 0;
let pendingLongName = null;
while (pos + 512 <= buf.length) {
  const name = buf.slice(pos, pos + 100).toString("utf8").replace(/\0.*$/, "");
  if (!name) break;
  const prefix = buf.slice(pos + 345, pos + 500).toString("utf8").replace(/\0.*$/, "");
  const type = String.fromCharCode(buf[pos + 156] || 48);
  const sizeText = buf.slice(pos + 124, pos + 136).toString("utf8").replace(/\0.*$/, "").trim();
  const size = sizeText ? parseInt(sizeText, 8) : 0;
  const dataStart = pos + 512;
  if ((sizeText && !/^[0-7]+$/.test(sizeText)) || !Number.isSafeInteger(size) || size < 0 || dataStart + size > buf.length) process.exit(1);
  pos = dataStart + 512 * Math.ceil(size / 512);
  if (type === "L") {
    if (pendingLongName !== null) process.exit(2);
    pendingLongName = buf.slice(dataStart, dataStart + size).toString("utf8").replace(/\0.*$/s, "");
    if (!pendingLongName) process.exit(2);
    continue;
  }
  const full = pendingLongName !== null ? pendingLongName : (prefix ? prefix + "/" + name : name);
  pendingLongName = null;
  // 按路径段判断 ".."，避免误伤 cert..pem 这类合法文件名
  if (!(full === "etc/sing-box" || full.startsWith("etc/sing-box/")) || full.startsWith("/") || full.split("/").includes("..")) process.exit(2);
  if (type !== "0" && type !== "5" && type !== "\0") process.exit(2);
  const rel = full.slice("etc/sing-box".length).replace(/^\//, "");
  const out = path.resolve(root, rel);
  if (out !== root && !out.startsWith(root + path.sep)) process.exit(2);
  entries.push({ type, out, dataStart, size });
}
if (pendingLongName !== null || !entries.length) process.exit(2);
try {
  for (const e of entries) {
    if (e.type === "5") fs.mkdirSync(e.out, { recursive: true });
    else {
      fs.mkdirSync(path.dirname(e.out), { recursive: true });
      fs.writeFileSync(e.out, buf.slice(e.dataStart, e.dataStart + e.size));
    }
  }
} catch (e) {
  process.exit(1);
}
JS
}

clear_conf_contents() (
  shopt -s dotglob nullglob
  local path
  for path in "$CONF_DIR"/*; do
    [[ "$path" == "$LOCK_FILE" ]] && continue
    rm -rf -- "$path" || exit 1
  done
)

# 复制配置树但跳过 .lock：覆盖活动锁文件会另起 inode，
# 使持有进程的 flock 失效（另一实例就能同时拿到“锁”）。
# 用子 shell 承载 shopt，避免 dotglob 泄漏到全局影响其它 glob
copy_conf_tree() (
  shopt -s dotglob nullglob
  local p
  for p in "$1"/*; do
    [[ "$(basename "$p")" == ".lock" ]] && continue
    cp -a "$p" "$2"/ || exit 1
  done
)

restore_saved_conf() {
  local saved=$1
  clear_conf_contents || return 1
  copy_conf_tree "$saved" "$CONF_DIR"
}

# 恢复流程的统一失败出口：清临时目录 + 报错
restore_fail() {  # <tmp> <saved|""> <消息...>
  local tmp=$1 saved=$2
  shift 2
  rm -rf "$tmp"
  [[ -n "$saved" ]] && rm -rf "$saved"
  err "$*"
  return 1
}

restore_conf() {
  local src tmp srcdir saved="" rc
  src=$(prompt "备份文件路径" "") || return 2
  [[ -f "$src" && ! -L "$src" ]] || { err "文件不存在"; return 1; }
  [[ ! -L "$CONF_DIR" ]] || { err "配置目录是符号链接，拒绝恢复"; return 1; }
  ask_yn "恢复将覆盖 $CONF_DIR，继续？" n || return 2
  if ! command -v node >/dev/null 2>&1; then
    note "恢复校验需要 nodejs，正在安装…"
    pkg_install nodejs ca-certificates || { err "nodejs 安装失败"; return 1; }
  fi
  tmp=$(mktemp -d) || return 1
  TMP_CLEANUP+=("$tmp")
  archive_extract_checked "$src" "$tmp"
  rc=$?
  case "$rc" in
    0) : ;;
    2) restore_fail "$tmp" "" "归档含绝对路径、..、链接或配置目录以外的成员，已拒绝"; return 1 ;;
    3) rm -rf "$tmp"; return 1 ;;
    *) restore_fail "$tmp" "" "解压失败"; return 1 ;;
  esac
  srcdir="$tmp/etc/sing-box"
  [[ -f "$srcdir/config.json" && ! -L "$srcdir/config.json" ]] \
    || { restore_fail "$tmp" "" "备份中没有 config.json"; return 1; }
  jq -e '.inbounds and .outbounds' "$srcdir/config.json" >/dev/null 2>&1 \
    || { restore_fail "$tmp" "" "config.json 不是有效的 sing-box 配置"; return 1; }
  if [[ -d "$CONF_DIR" ]]; then
    saved=$(mktemp -d) || { rm -rf "$tmp"; return 1; }
    TMP_CLEANUP+=("$saved")
    cp -a "$CONF_DIR"/. "$saved"/ 2>/dev/null \
      || { restore_fail "$tmp" "$saved" "无法创建原配置快照，未执行恢复"; return 1; }
  fi
  [[ "$(svc_state)" != absent ]] && svc_stop || true
  mkdir -p "$CONF_DIR" || { restore_fail "$tmp" "$saved" "无法创建配置目录"; return 1; }
  if ! clear_conf_contents || ! copy_conf_tree "$srcdir" "$CONF_DIR"; then
    if [[ -n "$saved" ]] && restore_saved_conf "$saved"; then
      harden_perms
      QUIET=1 svc_restart || true
      restore_fail "$tmp" "$saved" "恢复写入失败，原配置已还原"
    elif [[ -n "$saved" ]]; then
      restore_fail "$tmp" "" "恢复写入失败且回滚失败；原配置快照保留在 $saved"
    else
      restore_fail "$tmp" "" "恢复写入失败；没有可用的原配置快照"
    fi
    return 1
  fi
  rm -rf "$tmp"
  ensure_service_user || true
  harden_perms
  # 备份可能是旧版打包的，恢复后立即清掉已废弃的 name 字段
  meta_drop_legacy_name || true
  if [[ -x "$SINGBOX_BIN" ]]; then
    if ! apply_conf; then
      if [[ -n "$saved" ]] && restore_saved_conf "$saved"; then
        harden_perms
        QUIET=1 svc_restart || true
        restore_fail "$tmp" "" "恢复后配置校验/启动失败，原配置已还原"
      elif [[ -n "$saved" ]]; then
        restore_fail "$tmp" "" "恢复后配置校验/启动失败，且回滚失败；原配置快照保留在 $saved"
      else
        restore_fail "$tmp" "" "恢复后配置校验/启动失败，且没有原配置快照可还原"
      fi
      return 1
    fi
  fi
  [[ -n "$saved" ]] && rm -rf "$saved"
  ok "已恢复"
}

show_block() {
  local title=$1 body=$2
  printf "\n  %s\n" "$title"
  printf '%s\n' "$body" | sed 's/^/  /'
}

show_share_parts() {
  local uri=${1-} yaml=${2-} json=${3-} surge=${4-}
  [[ -n "$uri" ]] && show_block "URI" "$uri"
  [[ -n "$surge" ]] && show_block "Surge" "$surge"
  [[ -n "$yaml" ]] && show_block "Clash" "$yaml"
  [[ -n "$json" ]] && show_block "sing-box" "$json"
}

node_commit() {
  local tag=$1 label=$2 meta_json=$3 keys_json=${4-}
  meta_put_node "$tag" "$meta_json" || { drop_node "$tag"; return 1; }
  if [[ -n "$keys_json" ]]; then
    keys_put "$tag" "$keys_json" || { drop_node "$tag"; return 1; }
  fi
  apply_conf "$tag" || return 1
  ok "$label"
  [[ -n "$(ib_get "$tag" '.listen_port')" ]] || return 0
  show_share "$tag"
}

# ---------- 分享 ----------

# Clash 节点头。字段顺序固定，不能改。
share_head() {
  printf '%s\n' \
    "- name: $(yaml_str "$1")" \
    "  type: $2" \
    "  server: $(yaml_host "$3")" \
    "  port: $4"
}

# 分享上下文字段。须在当前 shell 直接调用（不可放进 $( )）。
# SH_TYPE / SH_PORT 为所有协议共有；SHARE_SNI、SHARE_INSECURE 仅 TLS 类使用。
# 分享链接里的显示名就是节点 tag，各 share_* 直接用形参 $tag。
share_ctx() {
  local tag=$1
  SH_TYPE=$(ib_get "$tag" '.type')
  SH_PORT=$(ib_get "$tag" '.listen_port')
  SHARE_SNI=$(ib_get "$tag" '.tls.server_name')
  SHARE_INSECURE=$(meta_insecure "$tag")
}

share_ss() {
  local tag=$1 host=$2
  local method pass uri yaml json
  method=$(ib_get "$tag" '.method')
  pass=$(ib_get "$tag" '.password')
  # SIP002 要求 userinfo 使用 URL-safe base64：标准字母表的 '/' 不在 URI userinfo 合法字符内
  uri="ss://$(printf '%s' "${method}:${pass}" | openssl base64 -A | tr '+/' '-_' | tr -d '=')@$(hp "$host" "$SH_PORT")#$(uri_enc "$tag")"
  yaml=$(share_head "$tag" ss "$host" "$SH_PORT")
  yaml+=$(printf '\n  cipher: %s\n  password: %s\n  smux:\n    enabled: true' \
    "$method" "$(yaml_str "$pass")")
  json=$(jq -n --arg tag "$tag" --arg host "$host" --argjson port "$SH_PORT" \
    --arg method "$method" --arg pass "$pass" \
    '{type:"shadowsocks", tag:$tag, server:$host, server_port:$port, method:$method, password:$pass, multiplex:{enabled:true, padding:true}}')
  show_share_parts "$uri" "$yaml" "$json"
}

share_st() {
  local tag=$1 host=$2
  local hs st_pass ss_pass inner method yaml json
  hs=$(ib_get "$tag" '.handshake.server')
  st_pass=$(ib_get "$tag" '.users[0].password')
  inner=$(inner_of "$tag")
  if [[ -z "$inner" ]]; then
    err "找不到 ShadowTLS 内层"
    return 1
  fi
  method=$(ib_get "$inner" '.method')
  ss_pass=$(ib_get "$inner" '.password')
  note "ShadowTLS 无通用 URI，仅提供 Clash / sing-box"
  yaml=$(share_head "$tag" ss "$host" "$SH_PORT")
  yaml+=$(printf '\n  cipher: %s\n  password: %s\n  plugin: shadow-tls\n  plugin-opts:\n    host: %s\n    password: %s\n    version: 3' \
    "$method" "$(yaml_str "$ss_pass")" "$(yaml_str "$hs")" "$(yaml_str "$st_pass")")
  json=$(jq -n \
    --arg name "$tag" --arg host "$host" --argjson port "$SH_PORT" \
    --arg method "$method" --arg ssp "$ss_pass" --arg stp "$st_pass" --arg hs "$hs" \
    '[
      {
        type:"shadowsocks", tag:$name, method:$method, password:$ssp,
        detour:($name+"-st")
      },
      {
        type:"shadowtls", tag:($name+"-st"), server:$host, server_port:$port,
        version:3, password:$stp,
        tls:{enabled:true, server_name:$hs, utls:{enabled:true, fingerprint:"chrome"}}
      }
    ]')
  show_share_parts "" "$yaml" "$json"
}

share_vless() {
  local tag=$1 host=$2
  local uuid sni pbk sid uri yaml json
  uuid=$(ib_get "$tag" '.users[0].uuid')
  sni=$(keys_get "$tag" sni)
  [[ -z "$sni" ]] && sni=$(ib_get "$tag" '.tls.server_name')
  pbk=$(keys_get "$tag" public_key)
  [[ -z "$pbk" ]] && pbk=$(jq -r --arg t "$tag" '.nodes[$t].public_key // empty' "$META")
  sid=$(keys_get "$tag" short_id)
  [[ -z "$sid" ]] && sid=$(ib_get "$tag" '.tls.reality.short_id[0]')
  if [[ -z "$pbk" ]]; then
    err "缺少 Reality public_key，无法分享（keys.json / meta 都没有）"
    return 1
  fi
  uri="vless://${uuid}@$(hp "$host" "$SH_PORT")?encryption=none&flow=xtls-rprx-vision&security=reality&sni=$(uri_enc "$sni")&fp=chrome&pbk=$(uri_enc "$pbk")&sid=${sid}&type=tcp#$(uri_enc "$tag")"
  yaml=$(share_head "$tag" vless "$host" "$SH_PORT")
  yaml+=$(printf '\n  uuid: %s\n  network: tcp\n  tls: true\n  udp: true\n  flow: xtls-rprx-vision\n  servername: %s\n  client-fingerprint: chrome\n  reality-opts:\n    public-key: %s\n    short-id: %s' \
    "$uuid" "$(yaml_str "$sni")" "$pbk" "$sid")
  json=$(jq -n --arg tag "$tag" --arg host "$host" --argjson port "$SH_PORT" \
    --arg uuid "$uuid" --arg sni "$sni" --arg pbk "$pbk" --arg sid "$sid" \
    '{
      type:"vless", tag:$tag, server:$host, server_port:$port, uuid:$uuid,
      flow:"xtls-rprx-vision",
      tls:{
        enabled:true, server_name:$sni,
        utls:{enabled:true, fingerprint:"chrome"},
        reality:{enabled:true, public_key:$pbk, short_id:$sid}
      }
    }')
  show_share_parts "$uri" "$yaml" "$json"
}

share_vmess() {
  local tag=$1 host=$2
  local uuid uri yaml json raw b64 tls_on
  uuid=$(ib_get "$tag" '.users[0].uuid')
  tls_on=$(ib_get "$tag" '.tls.enabled')
  yaml=$(share_head "$tag" vmess "$host" "$SH_PORT")
  if [[ "$tls_on" == true ]]; then
    raw=$(jq -nc --arg ps "$tag" --arg add "$host" --arg port "$SH_PORT" --arg id "$uuid" --arg sni "$SHARE_SNI" \
      '{v:"2",ps:$ps,add:$add,port:$port,id:$id,aid:"0",scy:"auto",net:"tcp",type:"none",tls:"tls",sni:$sni}')
    yaml+=$(printf '\n  uuid: %s\n  alterId: 0\n  cipher: auto\n  network: tcp\n  tls: true\n  servername: %s\n  skip-cert-verify: %s\n  udp: true' \
      "$uuid" "$(yaml_str "$SHARE_SNI")" "$(yaml_bool "$SHARE_INSECURE")")
    json=$(jq -n --arg tag "$tag" --arg host "$host" --argjson port "$SH_PORT" --arg uuid "$uuid" \
      --arg sni "$SHARE_SNI" --argjson insecure "$(yaml_bool "$SHARE_INSECURE")" \
      '{
        type:"vmess", tag:$tag, server:$host, server_port:$port, uuid:$uuid, security:"auto", alter_id:0,
        tls:{enabled:true, server_name:$sni, insecure:$insecure}
      }')
  else
    raw=$(jq -nc --arg ps "$tag" --arg add "$host" --arg port "$SH_PORT" --arg id "$uuid" \
      '{v:"2",ps:$ps,add:$add,port:$port,id:$id,aid:"0",scy:"auto",net:"tcp",type:"none",tls:"none"}')
    yaml+=$(printf '\n  uuid: %s\n  alterId: 0\n  cipher: auto\n  network: tcp\n  udp: true' "$uuid")
    json=$(jq -n --arg tag "$tag" --arg host "$host" --argjson port "$SH_PORT" --arg uuid "$uuid" \
      '{type:"vmess", tag:$tag, server:$host, server_port:$port, uuid:$uuid, security:"auto", alter_id:0}')
  fi
  b64=$(printf '%s' "$raw" | openssl base64 -A)
  uri="vmess://${b64}"
  show_share_parts "$uri" "$yaml" "$json"
}

share_hy2() {
  local tag=$1 host=$2
  local pass obfs_pw uri yaml json q
  pass=$(ib_get "$tag" '.users[0].password')
  obfs_pw=$(ib_get "$tag" '.obfs.password')
  q="sni=$(uri_enc "$SHARE_SNI")&insecure=${SHARE_INSECURE}"
  [[ -n "$obfs_pw" && "$obfs_pw" != null ]] && q="${q}&obfs=salamander&obfs-password=$(uri_enc "$obfs_pw")"
  uri="hysteria2://$(uri_enc "$pass")@$(hp "$host" "$SH_PORT")/?${q}#$(uri_enc "$tag")"
  yaml=$(share_head "$tag" hysteria2 "$host" "$SH_PORT")
  yaml+=$(printf '\n  password: %s\n  sni: %s\n  skip-cert-verify: %s' \
    "$(yaml_str "$pass")" "$(yaml_str "$SHARE_SNI")" "$(yaml_bool "$SHARE_INSECURE")")
  if [[ -n "$obfs_pw" && "$obfs_pw" != null ]]; then
    yaml+=$(printf '\n  obfs: salamander\n  obfs-password: %s' "$(yaml_str "$obfs_pw")")
  fi
  json=$(jq -n --arg tag "$tag" --arg host "$host" --argjson port "$SH_PORT" \
    --arg pass "$pass" --arg sni "$SHARE_SNI" --arg opw "${obfs_pw:-}" \
    --argjson insecure "$(yaml_bool "$SHARE_INSECURE")" \
    '{
      type:"hysteria2", tag:$tag, server:$host, server_port:$port, password:$pass,
      tls:{enabled:true, server_name:$sni, insecure:$insecure}
    } + (if ($opw == "" or $opw == "null") then {} else {obfs:{type:"salamander", password:$opw}} end)')
  show_share_parts "$uri" "$yaml" "$json"
}

share_anytls() {
  local tag=$1 host=$2
  local pass uri yaml json
  pass=$(ib_get "$tag" '.users[0].password')
  uri="anytls://$(uri_enc "$pass")@$(hp "$host" "$SH_PORT")?sni=$(uri_enc "$SHARE_SNI")&insecure=${SHARE_INSECURE}#$(uri_enc "$tag")"
  yaml=$(share_head "$tag" anytls "$host" "$SH_PORT")
  yaml+=$(printf '\n  password: %s\n  client-fingerprint: chrome\n  udp: true\n  sni: %s\n  skip-cert-verify: %s' \
    "$(yaml_str "$pass")" "$(yaml_str "$SHARE_SNI")" "$(yaml_bool "$SHARE_INSECURE")")
  json=$(jq -n --arg tag "$tag" --arg host "$host" --argjson port "$SH_PORT" \
    --arg pass "$pass" --arg sni "$SHARE_SNI" \
    --argjson insecure "$(yaml_bool "$SHARE_INSECURE")" \
    '{
      type:"anytls", tag:$tag, server:$host, server_port:$port, password:$pass,
      tls:{enabled:true, server_name:$sni, insecure:$insecure, utls:{enabled:true, fingerprint:"chrome"}}
    }')
  show_share_parts "$uri" "$yaml" "$json"
}

share_snell() {
  local tag=$1 host=$2
  local psk mode surge yaml json surge_host
  psk=$(ib_get "$tag" '.psk')
  mode=$(ib_get "$tag" '.mode // "default"')
  if [[ "$host" == *:* && "$host" != \[* ]]; then
    surge_host="[$host]"
  else
    surge_host="$host"
  fi
  surge="${tag} = snell, ${surge_host}, ${SH_PORT}, psk=${psk}, version=6"
  yaml=$(share_head "$tag" snell "$host" "$SH_PORT")
  yaml+=$(printf '\n  psk: %s\n  version: 6\n  udp: true\n  mode: %s' "$(yaml_str "$psk")" "$mode")
  json=$(jq -n --arg tag "$tag" --arg host "$host" --argjson port "$SH_PORT" \
    --arg psk "$psk" --arg mode "$mode" \
    '{type:"snell", tag:$tag, server:$host, server_port:$port, version:6, psk:$psk, mode:$mode}')
  show_share_parts "" "$yaml" "$json" "$surge"
}

show_share() {
  local tag=${1-} mode=${2-} host ip
  if [[ -z "$tag" ]]; then
    need_bin || return 1
    local pe
    tag=$(pick_node_tag); pe=$?
    (( pe != 0 )) && return "$pe"
  fi
  if [[ ! -t 1 ]]; then
    note "非交互输出：以下内容含明文凭据，请勿写入公共日志"
  fi
  host=$(share_host)
  if [[ -z "$host" ]] || ! is_share_host "$host"; then
    ip=$(prompt "分享地址（域名或 IP）" "") || return 2
    is_share_host "$ip" || { err "分享地址必须是域名、IPv4 或 IPv6"; return 1; }
    host=$ip
  elif [[ "$mode" != quiet ]]; then
    note "当前分享地址: $host"
    if ask_yn "改用其它地址/域名" n; then
      ip=$(prompt "分享地址（域名或 IP）" "$host") || return 2
      is_share_host "$ip" || { err "分享地址必须是域名、IPv4 或 IPv6"; return 1; }
      host=$ip
    fi
  fi
  remember_share_host "$host"
  share_ctx "$tag"     # 提供 SH_TYPE / SH_PORT / SHARE_SNI / SHARE_INSECURE
  case "$SH_TYPE" in
    shadowsocks) share_ss "$tag" "$host" ;;
    shadowtls)   share_st "$tag" "$host" ;;
    vless)       share_vless "$tag" "$host" ;;
    vmess)       share_vmess "$tag" "$host" ;;
    hysteria2)   share_hy2 "$tag" "$host" ;;
    anytls)      share_anytls "$tag" "$host" ;;
    snell)       share_snell "$tag" "$host" ;;
    *) err "未知协议 $SH_TYPE"; return 1 ;;
  esac
}

uninstall_all() {
  if [[ ! -x "$SINGBOX_BIN" && "$(svc_state)" == absent && ! -d "$CONF_DIR" ]]; then
    err "未安装"
    return 1
  fi
  ask_yn "卸载内核、服务和全部配置？" n || return 2
  if ask_yn "卸载前先备份配置" y; then
    backup_conf || note "备份跳过/失败，继续卸载"
  fi
  [[ "$(svc_state)" != absent ]] && svc_stop || true
  svc_do purge || true
  rm -f "$SINGBOX_BIN" "$SINGBOX_SELF" /usr/local/bin/sbox
  # 注意：这里会连 .lock 一起删掉，持有进程的 flock 随之失去意义；
  # 此刻若有另一实例启动，它会新建 .lock 并成功加锁。避免并发运行面板即可。
  rm -rf "$CONF_DIR"
  rm -f /etc/logrotate.d/sing-box /etc/conf.d/sing-box
  if id "$SVC_USER" >/dev/null 2>&1; then
    if ask_yn "删除服务用户 $SVC_USER" y; then
      userdel "$SVC_USER" 2>/dev/null || deluser "$SVC_USER" 2>/dev/null || true
    fi
  fi
  cache_bust
  ok "已卸载"
}

usage() {
  cat <<'USAGE'
用法: singbox.sh [选项]

  无参数          进入管理面板
  --self-test     自检：用当前 sing-box 内核校验面板生成的各协议样例配置
  -h, --help      显示本帮助

自检不修改任何现有配置，仅在临时目录中生成样例并执行 sing-box check。
USAGE
}

# 自检：用面板自身的字段生成各协议样例，交给 sing-box check 校验。
# 用途：确认当前内核真的支持面板宣称的协议/字段（Snell、AnyTLS 的版本门槛）。
self_test() {
  # 不调用 need_bin：自检不应产生任何配置目录副作用
  [[ -x "$SINGBOX_BIN" ]] || { err "先安装 sing-box"; return 1; }
  local tmp rc=0 cert pair priv
  tmp=$(mktemp -d) || return 1
  TMP_CLEANUP+=("$tmp")
  mkdir -p "$tmp/cert"
  if ! openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -days 1 -nodes \
      -keyout "$tmp/cert/key.pem" -out "$tmp/cert/cert.pem" \
      -subj "/CN=www.example.com" >/dev/null 2>&1; then
    err "自检用的临时证书生成失败"
    rm -rf "$tmp"
    return 1
  fi
  cert="$tmp/cert"
  pair=$("$SINGBOX_BIN" generate reality-keypair 2>/dev/null || true)
  priv=$(printf '%s' "$pair" | awk '/PrivateKey/{print $2}')
  if [[ -z "$priv" ]]; then
    err "无法生成 reality 密钥对（内核可能不支持或已损坏）"
    rm -rf "$tmp"
    return 1
  fi

  st_case() {
    local name=$1 ibs=$2 out
    if ! jq -n --argjson ibs "$ibs" '{
        log:{disabled:true}, inbounds:$ibs,
        outbounds:[{type:"direct",tag:"direct"}],
        route:{rules:[{action:"sniff"}],final:"direct"}
      }' > "$tmp/config.json" 2>/dev/null; then
      err "[$name] 样例配置构造失败"
      rc=1
      return 0
    fi
    if out=$("$SINGBOX_BIN" check -c "$tmp/config.json" 2>&1); then
      printf "${CG}[通过]${C0} %s\n" "$name"
    else
      printf "${CR}[不通过]${C0} %s\n" "$name"
      printf '%s\n' "$out" | sed 's/^/    /' >&2
      rc=1
    fi
  }

  # 样例一律走 ib_* 构造器：自检校验的就是"添加节点"实际写出的 schema
  local L=127.0.0.1 UUID=9f1c8b0e-2a3d-4c5b-8e7f-0a1b2c3d4e5f
  local PASS=AAAAAAAAAAAAAAAAAAAAAA==
  local tlsj hy2tls anytls
  tlsj=$(jq -n --arg c "$cert/cert.pem" --arg k "$cert/key.pem" \
    '{enabled:true, server_name:"www.example.com", certificate_path:$c, key_path:$k}')
  hy2tls=$(printf '%s' "$tlsj" | jq '. + {alpn:["h3"]}')
  anytls=$(printf '%s' "$tlsj" | jq '. + {alpn:["h2","http/1.1"]}')

  printf '内核版本: %s\n\n' "$(sb_version)"

  st_case "Shadowsocks (SS2022)" \
    "[$(ib_ss "ss-10000" 10000 "$PASS" "$L")]"

  st_case "Shadowsocks + ShadowTLS v3" \
    "[$(ib_ss_st "ss-10001" 10001 shadowtlspass01 www.microsoft.com ss-inner-10001 "$L"),$(ib_ss "ss-inner-10001" "" "$PASS")]"

  st_case "VLESS + Reality" \
    "[$(ib_vless "vless-10002" 10002 "$UUID" www.apple.com "$priv" a1b2c3d4 "$L")]"

  st_case "VMess + TLS(自签)" \
    "[$(ib_vmess "vmess-10003" 10003 "$UUID" "$tlsj" "$L")]"

  st_case "Hysteria2" \
    "[$(ib_hy2 "hy2-10004" 10004 hy2password12345 obfspassword1234 "$hy2tls" "$L")]"

  st_case "AnyTLS" \
    "[$(ib_anytls "anytls-10005" 10005 anytlspassword1 "$anytls" "$L")]"

  st_case "Snell v6" \
    "[$(ib_snell "snell-10006" 10006 snellpsk1234567890 "$L")]"

  st_case "VMess 明文" \
    "[$(ib_vmess "vmess-10007" 10007 "$UUID" "" "$L")]"

  rm -rf "$tmp"
  if (( rc == 0 )); then
    ok "全部协议样例均通过 sing-box check"
  else
    err "存在未通过的协议样例：请对照上方错误检查内核支持与版本门槛"
  fi
  return "$rc"
}

back_main() {
  [[ "${1-}" == skip ]] || hold
  ui_redraw
}

# 0=成功（可浏览输出） 2=取消 其它=失败后短暂停顿
menu_after() {
  local e=${1-1} view=${2-}
  if (( e == 0 )); then
    [[ -n "$view" ]] && wait_back
    back_main skip
  elif (( e == 2 )); then
    back_main skip
  else
    back_main
  fi
}

main_menu() {
  local c
  ui_redraw
  while :; do
    printf '\033[%d;1H\033[K' "${UI_PROMPT_R:-20}" >&2
    c=$(prompt "选择" "" "q退出") || { printf '\n'; exit 0; }
    case "$c" in
      1) install_singbox; back_main ;;
      2) add_menu; menu_after $? view ;;
      3) edit_node; menu_after $? view ;;
      4) show_share; menu_after $? view ;;
      5) del_node; menu_after $? ;;
      6) svc_start; back_main ;;
      7) svc_stop; back_main ;;
      8) svc_restart; back_main ;;
      9) backup_conf; menu_after $? ;;
      10) restore_conf; menu_after $? ;;
      11) uninstall_all; menu_after $? ;;
      q|Q) printf '\n'; exit 0 ;;
    esac
  done
}

main() {
  local arg
  for arg in "$@"; do
    case "$arg" in
      --self-test|self-test) need_root; detect_os; ensure_deps || die "依赖安装失败"; self_test; exit $? ;;
      -h|--help) usage; exit 0 ;;
    esac
  done
  need_root
  detect_os
  ensure_deps || die "依赖安装失败"
  # 先拿锁再动配置：避免两个实例同时初始化/改权限
  lock_acquire || die "无法获取配置锁"
  ensure_conf
  meta_gc   # 清理历史遗留的孤儿元数据
  main_menu
}
# 直接执行、管道或进程替换时进入主菜单；被 source 时仅加载函数
if [[ "${BASH_SOURCE[0]:-$0}" == "$0" \
   || "${BASH_SOURCE[0]:-}" == /dev/fd/* \
   || "${BASH_SOURCE[0]:-}" == /proc/self/fd/* \
   || "${BASH_SOURCE[0]:-}" == /proc/*/fd/* ]]; then
  main "$@"
fi
