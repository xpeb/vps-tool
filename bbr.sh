#!/usr/bin/env bash
# bbr.sh — Debian / Alpine 网络/内核调优（drop-in 写入）
# 动态项按内存计算，只增不减；当前值已超上限时保留当前值。
# 运行方式：bash bbr.sh（需 root）
# 回滚：bash /var/lib/bbr/rollback.sh
# 回滚恢复配置和 qdisc；已加载模块及 conntrack buckets 可能需重启后完全恢复。
SYSCTL_FILE=/etc/sysctl.d/99-tuning.conf
LIMITS_FILE=/etc/security/limits.d/99-tuning.conf
MODULES_FILE=/etc/modules-load.d/99-tuning.conf
MODPROBE_FILE=/etc/modprobe.d/99-tuning.conf
JOURNAL_FILE=/etc/systemd/journald.conf.d/99-tuning.conf
SYSTEMD_NOFILE_FILE=/etc/systemd/system.conf.d/99-tuning.conf
PROFILE_FILE=/etc/profile.d/99-tuning.sh
STATE_DIR=/var/lib/bbr
ORIG_DIR=/var/lib/bbr/original
PREV_FILE=/var/lib/bbr/previous.conf
QDISC_FILE=/var/lib/bbr/qdisc.previous
ROLLBACK_SH=/var/lib/bbr/rollback.sh
RC_BEGIN="# --- bbr.sh begin ---"
RC_END="# --- bbr.sh end ---"
OS_KIND=""
# compute_tuning 与 plan 阶段产出的全局量（供 render_sysctl / show_plan / apply 使用）
fs_file_max=0 conntrack_max=0 rmem_max=0 wmem_max=0 backlog=0 somaxconn=0 tw_buckets=0
nofile=0 rmem_def=0 wmem_def=0 ct_buckets=0
memory_mb=0 mem_show="" cc=cubic qdisc="" CT_NOTE="" CT_SYSCTL_WRITABLE=0
BBR_MISSING=0
DRY_RUN=0 ASSUME_YES=0
LOADED_MODULES=()
if [ -z "${BASH_VERSION:-}" ]; then echo "[ERROR] 请用 bash 运行: bash $0" >&2; exit 1; fi
set -euo pipefail

die() { echo "[ERROR] $*" >&2; exit 1; }

sysctl_get() { sysctl -n "$1" 2>/dev/null || echo 0; }

# 比较和快照用：制表符与连续空白收成单空格。
# sysctl -n 对 tcp_rmem 等多值键常用制表符，写入用空格，直接比会误报变化。
normalize_ws() {
    local v=$1
    v=${v//$'\t'/ }
    while [ "$v" != "${v//  / }" ]; do
        v=${v//  / }
    done
    v=${v# }
    v=${v% }
    printf '%s\n' "$v"
}

usage() {
    cat <<'USAGE'
用法: bash bbr.sh [选项]

  无参数        计算并显示将要做的变更，确认后执行
  --dry-run, -n 只显示"当前值 -> 计划值"，不做任何修改
  --yes, -y     跳过确认，直接执行（用于无人值守）
  --help, -h    显示本帮助
  rollback      回滚到首次运行前的配置与 qdisc

回滚: bash /var/lib/bbr/rollback.sh
说明: 动态项只增不减，脚本不会把已调高的值调低。
USAGE
}

# 向上取整到 2 的幂。conntrack 哈希表大小必须是 2 的幂，内核否则拒绝。
round_pow2_up() {
    local v=${1:-1} p=1
    case "$v" in ''|*[!0-9]*) printf '1\n'; return 0 ;; esac
    [ "$v" -gt 0 ] || { printf '1\n'; return 0; }
    while [ "$p" -lt "$v" ]; do p=$((p * 2)); done
    printf '%s\n' "$p"
}

# 探测 nf_conntrack 的哈希表参数名。
# 实测（Debian 6.12-cloud / Alpine 6.18-virt）：modinfo 只列出 expect_hashsize，
# 但内核实际生效的是 hashsize；expect_hashsize 被接受却仍用默认值 8192。
# 因此以 hashsize 为主，expect_hashsize 作为兜底（供其它内核使用）。
ct_param_name() {
    local p
    p=$(modinfo -F parm nf_conntrack 2>/dev/null \
        | sed -n 's/^\([A-Za-z_][A-Za-z0-9_]*\):.*/\1/p')
    if printf '%s\n' "$p" | grep -qx hashsize; then
        printf 'hashsize\n'
        return 0
    fi
    if printf '%s\n' "$p" | grep -qx expect_hashsize; then
        printf 'expect_hashsize\n'
        return 0
    fi
    # modinfo 不可用时，从已加载模块的 sysfs 参数目录再确认一次
    if [ -d /sys/module/nf_conntrack/parameters ]; then
        for p in hashsize expect_hashsize; do
            if [ -e "/sys/module/nf_conntrack/parameters/$p" ]; then
                printf '%s\n' "$p"
                return 0
            fi
        done
    fi
    # 都查不到时仍优先尝试 hashsize（老内核通用，且部分内核 modinfo 不列出它）
    printf 'hashsize\n'
}

check_deps() {
    local c missing=0
    for c in sysctl awk; do
        if ! command -v "$c" >/dev/null 2>&1; then
            echo "[ERROR] 缺少必要命令: $c" >&2
            missing=1
        fi
    done
    [ "$missing" -eq 0 ] || die "请先安装依赖后重试"
    command -v tc >/dev/null 2>&1 || \
        echo "[WARN] 无 tc，现有网卡 qdisc 不会被改动（仅新网卡生效）" >&2
}

# 只读探测：内核是否支持 BBR / fq
# 未加载的模块也要算"可用"——modinfo 能查到就说明加载后即可用（探测阶段不加载）
bbr_available() {
    grep -qw bbr /proc/sys/net/ipv4/tcp_available_congestion_control 2>/dev/null && return 0
    modinfo tcp_bbr >/dev/null 2>&1 || [ -d /sys/module/tcp_bbr ]
}
fq_available() {
    grep -qw fq /proc/sys/net/core/default_qdisc 2>/dev/null && return 0
    modinfo sch_fq >/dev/null 2>&1 || [ -d /sys/module/sch_fq ]
}

# tune <当前值> <计算值> <下限> <上限>
# 先取较大值，再夹进区间；当前值已超上限时保留当前值。
tune() {
    local cur=$1 calc=$2 min=$3 max=$4 v
    v=$calc
    [ "$cur" -gt "$v" ] && v=$cur
    [ "$v" -lt "$min" ] && v=$min
    if [ "$v" -gt "$max" ]; then
        if [ "$cur" -gt "$max" ]; then
            v=$cur
        else
            v=$max
        fi
    fi
    printf '%s\n' "$v"
}

# compute_tuning <mem_mb> <file> <conntrack> <rmem> <wmem> <backlog> <somaxconn> <tw>
# 只根据传入的当前值计算，不读 sysctl。结果写入上方声明的全局量。
compute_tuning() {
    local mem=$1
    fs_file_max=$(tune "$2" $((mem * 512)) 524288 4194304)
    conntrack_max=$(tune "$3" $((mem * 128)) 65536 2097152)
    rmem_max=$(tune "$4" $((mem * 8192)) 4194304 134217728)
    wmem_max=$(tune "$5" $((mem * 8192)) 4194304 134217728)
    backlog=$(tune "$6" $((mem * 256)) 32768 524288)
    somaxconn=$(tune "$7" $((mem * 32)) 1024 65535)
    tw_buckets=$(tune "$8" $((mem * 32)) 16384 1048576)
    nofile=$fs_file_max
    [ "$nofile" -gt 1048576 ] && nofile=1048576
    # TCP 自动调优的"默认"值保持保守：只取 max/32，并夹在 128K~2M。
    # 默认值过大会让每条连接一开始就占住大块内存，连接数一多容易 OOM；
    # 上限仍保留大值，交给内核按需 autotuning 往上走。
    rmem_def=$((rmem_max / 32))
    wmem_def=$((wmem_max / 32))
    [ "$rmem_def" -lt 131072 ] && rmem_def=131072
    [ "$wmem_def" -lt 131072 ] && wmem_def=131072
    [ "$rmem_def" -gt 2097152 ] && rmem_def=2097152
    [ "$wmem_def" -gt 2097152 ] && wmem_def=2097152
    ct_buckets=$((conntrack_max / 4))
}

# 配置文件用 "key = value"；sysctl -w 要 "key=value"，值内空格保留。
sysctl_line_set() {
    local line=$1 key val
    key=${line%%=*}
    val=${line#*=}
    key=${key// /}
    val=${val# }
    printf '%s=%s\n' "$key" "$val"
}

sysctl_keys() {
    printf '%s\n' \
        vm.swappiness \
        fs.file-max \
        net.core.rmem_max \
        net.core.wmem_max \
        net.core.netdev_max_backlog \
        net.core.somaxconn \
        net.core.default_qdisc \
        net.ipv4.ip_forward \
        net.ipv4.ip_local_port_range \
        net.ipv4.tcp_syncookies \
        net.ipv4.tcp_tw_reuse \
        net.ipv4.tcp_fin_timeout \
        net.ipv4.tcp_keepalive_time \
        net.ipv4.tcp_keepalive_intvl \
        net.ipv4.tcp_keepalive_probes \
        net.ipv4.tcp_max_syn_backlog \
        net.ipv4.tcp_slow_start_after_idle \
        net.ipv4.tcp_max_tw_buckets \
        net.ipv4.tcp_fastopen \
        net.ipv4.tcp_mtu_probing \
        net.ipv4.tcp_rmem \
        net.ipv4.tcp_wmem \
        net.ipv4.tcp_notsent_lowat \
        net.ipv4.tcp_no_metrics_save \
        net.ipv4.tcp_congestion_control \
        net.netfilter.nf_conntrack_max \
        net.netfilter.nf_conntrack_buckets \
        net.netfilter.nf_conntrack_tcp_timeout_established \
        net.netfilter.nf_conntrack_tcp_timeout_time_wait \
        net.netfilter.nf_conntrack_udp_timeout \
        net.netfilter.nf_conntrack_udp_timeout_stream \
        net.ipv6.conf.all.forwarding \
        net.ipv6.conf.default.forwarding \
        net.ipv6.conf.all.accept_ra \
        net.ipv6.conf.default.accept_ra
}

# 按 "key = value" 的键名精确匹配。键名含点，不能丢进正则。
sysctl_snapshot_has() {
    local key=$1
    [ -f "$PREV_FILE" ] || return 1
    awk -F ' = ' -v k="$key" '$1 == k { found=1 } END { exit found ? 0 : 1 }' "$PREV_FILE"
}

# 已有快照不覆盖，只补上当时还不存在的键。
snapshot_sysctl() {
    local key val
    mkdir -p "$STATE_DIR"
    [ -f "$PREV_FILE" ] || : > "$PREV_FILE"
    while IFS= read -r key; do
        [ -n "$key" ] || continue
        if sysctl_snapshot_has "$key"; then
            continue
        fi
        val=$(sysctl -n "$key" 2>/dev/null) || continue
        val=$(normalize_ws "$val")
        printf '%s = %s\n' "$key" "$val" >> "$PREV_FILE"
    done < <(sysctl_keys)
}

# 记录第一次运行前的文件状态，以便回滚时原样恢复原有配置。
snapshot_files() {
    local f dst
    mkdir -p "$STATE_DIR" "$ORIG_DIR"
    [ -f "$STATE_DIR/files.manifest" ] && return 0
    : > "$STATE_DIR/files.manifest"
    for f in "$SYSCTL_FILE" "$LIMITS_FILE" "$MODULES_FILE" "$MODPROBE_FILE" \
             "$JOURNAL_FILE" "$SYSTEMD_NOFILE_FILE" "$PROFILE_FILE" /etc/rc.conf; do
        if [ -e "$f" ]; then
            printf 'present\t%s\n' "$f" >> "$STATE_DIR/files.manifest"
            dst="$ORIG_DIR$f"
            mkdir -p "$(dirname "$dst")"
            cp -a "$f" "$dst"
        else
            printf 'absent\t%s\n' "$f" >> "$STATE_DIR/files.manifest"
        fi
    done
}

render_sysctl() {
    cat <<EOF
# 由 bbr.sh 生成（请勿手工编辑，回滚见 /var/lib/bbr/rollback.sh）
vm.swappiness = 1
fs.file-max = $fs_file_max

net.core.rmem_max = $rmem_max
net.core.wmem_max = $wmem_max
net.core.netdev_max_backlog = $backlog
net.core.somaxconn = $somaxconn
EOF
    if [ -n "${qdisc:-}" ]; then
        printf '%s\n' "$qdisc"
    fi
    cat <<EOF
net.ipv4.ip_forward = 1
net.ipv4.ip_local_port_range = 10240 65535
net.ipv4.tcp_syncookies = 1
net.ipv4.tcp_tw_reuse = 1
net.ipv4.tcp_fin_timeout = 15
net.ipv4.tcp_keepalive_time = 600
net.ipv4.tcp_keepalive_intvl = 30
net.ipv4.tcp_keepalive_probes = 5
net.ipv4.tcp_max_syn_backlog = $somaxconn
net.ipv4.tcp_slow_start_after_idle = 0
net.ipv4.tcp_max_tw_buckets = $tw_buckets
net.ipv4.tcp_fastopen = 3
net.ipv4.tcp_mtu_probing = 1
net.ipv4.tcp_rmem = 4096 $rmem_def $rmem_max
net.ipv4.tcp_wmem = 4096 $wmem_def $wmem_max
net.ipv4.tcp_notsent_lowat = 131072
net.ipv4.tcp_no_metrics_save = 1
net.ipv4.tcp_congestion_control = $cc

net.netfilter.nf_conntrack_max = $conntrack_max
EOF
    # 现代内核的 buckets sysctl 可写时写进 drop-in，跨重启保持；
    # 只读内核才交给 modprobe.d 的模块参数。
    if [ "${CT_SYSCTL_WRITABLE:-0}" -eq 1 ]; then
        printf 'net.netfilter.nf_conntrack_buckets = %s\n' "$ct_buckets"
    fi
    cat <<EOF
net.netfilter.nf_conntrack_tcp_timeout_established = 600
net.netfilter.nf_conntrack_tcp_timeout_time_wait = 30
net.netfilter.nf_conntrack_udp_timeout = 10
net.netfilter.nf_conntrack_udp_timeout_stream = 60

net.ipv6.conf.all.forwarding = 1
net.ipv6.conf.default.forwarding = 1
# forwarding=1 会停收 RA，SLAAC 机器需 accept_ra=2 才不丢 IPv6
net.ipv6.conf.all.accept_ra = 2
net.ipv6.conf.default.accept_ra = 2
EOF
}

mem_mb() {
    local kb
    kb=$(awk '/MemTotal/{print $2}' /proc/meminfo) || die "无法读取内存"
    [ -n "${kb:-}" ] || die "无法读取内存"
    memory_mb=$((kb / 1024))
    [ "$memory_mb" -ge 1 ] || die "无法读取内存"
    if [ "$memory_mb" -ge 1024 ]; then
        mem_show="$((memory_mb / 1024))G"
    else
        mem_show="${memory_mb}M"
    fi
}

apply_sysctl_file() {
    local line set
    while IFS= read -r line; do
        case "$line" in ''|\#*) continue ;; esac
        set=$(sysctl_line_set "$line")
        sysctl -w "$set" >/dev/null 2>&1 || echo "[WARN] 跳过: $line" >&2
    done < "$SYSCTL_FILE"
}

detect_os() {
    [ -f /etc/os-release ] || die "找不到 /etc/os-release"
    # shellcheck disable=SC1091
    . /etc/os-release
    case "${ID:-}" in
        debian) OS_KIND=debian ;;
        alpine) OS_KIND=alpine ;;
        *) die "仅支持 Debian 和 Alpine，当前为: ${ID:-unknown}" ;;
    esac
}

# 加载 tcp_bbr / sch_fq。nf_conntrack 由 apply_conntrack_buckets 负责：
# 它必须先写好模块参数再加载，否则模块会按内核默认值建表。
# 开机加载列表在 conntrack 处理完后由 persist_modules 一次性写入。
load_tuning_modules() {
    local m
    LOADED_MODULES=()
    for m in tcp_bbr sch_fq; do
        if modprobe "$m" 2>/dev/null; then
            LOADED_MODULES+=("$m")
        fi
    done
}

# 登记开机自动加载。nf_conntrack 只有已经出现在 /sys/module 时才写入，
# 避免模块不存在时开机 modprobe 失败。sysctl 服务在模块加载之后套用 drop-in。
persist_modules() {
    local lines=() m
    if [ "${#LOADED_MODULES[@]}" -gt 0 ]; then
        for m in "${LOADED_MODULES[@]}"; do
            lines+=("$m")
        done
    fi
    if [ -d /sys/module/nf_conntrack ]; then
        lines+=("nf_conntrack")
    fi
    if [ "${#lines[@]}" -eq 0 ]; then
        rm -f "$MODULES_FILE"
        return 0
    fi
    mkdir -p /etc/modules-load.d
    printf '%s\n' "${lines[@]}" > "$MODULES_FILE"
}

# nf_conntrack 哈希表大小（buckets）。
# 现代内核的 nf_conntrack_buckets sysctl 可写，优先走它：立即生效且不依赖模块参数名。
# 不可写时才回退到模块参数（需下次加载模块/重启生效），并按内核实际支持的参数名写入。
apply_conntrack_buckets() {
    local target=$1 current was_loaded=0 chosen="" param
    [ -d /sys/module/nf_conntrack ] && was_loaded=1

    # 路径一：buckets sysctl 可写 —— 直接写，最可靠，立即生效
    if [ "${CT_SYSCTL_WRITABLE:-0}" -eq 1 ]; then
        modprobe nf_conntrack 2>/dev/null || true
        current=$(sysctl_get net.netfilter.nf_conntrack_buckets)
        if [ "$current" != "$target" ]; then
            sysctl -w "net.netfilter.nf_conntrack_buckets=$target" >/dev/null 2>&1 || true
            current=$(sysctl_get net.netfilter.nf_conntrack_buckets)
        fi
        rm -f "$MODPROBE_FILE"
        if [ "$current" = "$target" ]; then
            CT_NOTE="buckets=$target（sysctl 已即时生效）"
        else
            CT_NOTE="buckets=$current（sysctl 写入未生效，请检查权限）"
            echo "[WARN] 无法把 nf_conntrack_buckets 调整为 $target，当前 $current" >&2
        fi
        return 0
    fi

    # 路径二：sysctl 不可写 —— 只能靠模块参数。
    # 必须在加载模块**之前**写好，否则模块会按内核默认值建表。
    for param in hashsize expect_hashsize; do
        mkdir -p /etc/modprobe.d
        printf 'options nf_conntrack %s=%s\n' "$param" "$target" > "$MODPROBE_FILE"
        if [ "$was_loaded" -eq 1 ]; then
            # 模块已在使用中：卸载会打断现有连接，只持久化给下次加载/重启
            chosen=$param
            break
        fi
        modprobe -r nf_conntrack >/dev/null 2>&1 || true
        if modprobe nf_conntrack 2>/dev/null; then
            current=$(sysctl_get net.netfilter.nf_conntrack_buckets)
            if [ "$current" = "$target" ]; then
                chosen=$param
                break
            fi
        fi
    done

    current=$(sysctl_get net.netfilter.nf_conntrack_buckets)
    if [ "$current" = "$target" ]; then
        CT_NOTE="buckets=$target（模块参数 $chosen 已即时生效）"
    elif [ -n "$chosen" ]; then
        CT_NOTE="buckets=$current（已写入模块参数 $chosen=$target，下次加载模块/重启后生效）"
        echo "[WARN] nf_conntrack_buckets 当前为 $current，模块参数将在下次加载时生效" >&2
    else
        # 两个候选都未生效：保留 hashsize 供下次启动尝试，并如实告知
        printf 'options nf_conntrack hashsize=%s\n' "$target" > "$MODPROBE_FILE"
        CT_NOTE="buckets=$current（候选参数均未生效，仅按 max/4 记录）"
        echo "[WARN] hashsize / expect_hashsize 均未生效（当前 $current），仅设置 nf_conntrack_max" >&2
    fi
    return 0
}

qdisc_info() {
    tc qdisc show dev "$1" 2>/dev/null | awk '$1=="qdisc" && $4=="root" { print $2, $3; exit }'
}

# default_qdisc 只影响新网卡。把已有物理接口也换成 fq，并记下原来的 qdisc/handle。
# 虚拟/容器网卡（docker、veth、bridge、隧道等）默认跳过，避免影响容器网络。
apply_fq_now() {
    local dev kind handle info
    command -v tc >/dev/null 2>&1 || {
        echo "[WARN] 无 tc，未改现有网卡 qdisc" >&2
        return 0
    }
    mkdir -p "$STATE_DIR"
    for dev in /sys/class/net/*; do
        dev=$(basename "$dev")
        [ "$dev" = lo ] && continue
        # 没有 device 链接 = 虚拟网卡/桥/隧道，不碰
        if [ ! -e "/sys/class/net/$dev/device" ]; then
            continue
        fi
        info=$(qdisc_info "$dev")
        [ -n "$info" ] || continue
        read -r kind handle <<< "$info"
        if [ ! -f "$QDISC_FILE" ] || ! grep -q "^${dev} " "$QDISC_FILE" 2>/dev/null; then
            printf '%s %s %s\n' "$dev" "$kind" "$handle" >> "$QDISC_FILE"
        fi
        [ "$kind" = fq ] && continue
        tc qdisc replace dev "$dev" root fq >/dev/null 2>&1 || \
            echo "[WARN] 跳过网卡 $dev 的 qdisc" >&2
    done
}

write_limits() {
    mkdir -p /etc/security/limits.d
    printf '%s\n' \
        "* soft nofile $nofile" "* hard nofile $nofile" \
        "root soft nofile $nofile" "root hard nofile $nofile" \
        > "$LIMITS_FILE"
    # Alpine 默认无 PAM，limits.d 不生效；登录 shell 用 profile.d。
    if [ "$OS_KIND" = alpine ]; then
        mkdir -p /etc/profile.d
        printf '%s\n' '# 由 bbr.sh 生成，登录 shell 提高 nofile' \
            "ulimit -n $nofile 2>/dev/null || true" > "$PROFILE_FILE"
    fi
}

# OpenRC 在启动服务时应用 rc_ulimit。ulimit 失败只记错误，不阻止启动。
write_rc_ulimit() {
    local tmp
    [ "$OS_KIND" = alpine ] || return 0
    [ -f /etc/rc.conf ] || return 0
    tmp=$(mktemp) || return 1
    # 标记行按"去首尾空白后相等"匹配，容忍用户手改产生的空格差异，避免块重复累积
    awk -v b="$RC_BEGIN" -v e="$RC_END" '
        function trim(s) { gsub(/^[ \t]+|[ \t\r]+$/, "", s); return s }
        trim($0) == b { skip=1; next }
        trim($0) == e { skip=0; next }
        !skip { print }
    ' /etc/rc.conf > "$tmp"
    printf '%s\n' "$RC_BEGIN" "rc_ulimit=\"\${rc_ulimit:-\${RC_ULIMIT:-}} -n $nofile\"" "$RC_END" >> "$tmp"
    mv "$tmp" /etc/rc.conf
}

write_journald() {
    [ "$OS_KIND" = debian ] || return 0
    mkdir -p /etc/systemd/journald.conf.d
    # 只限制日志体积，不改转发策略：ForwardToSyslog 交由系统原有配置决定，
    # 避免在依赖 syslog 转发的环境里悄悄断掉日志链路。
    local want
    want=$(printf '[Journal]\nSystemMaxUse=384M\nSystemMaxFileSize=128M\n')
    if [ -f "$JOURNAL_FILE" ] && [ "$(cat "$JOURNAL_FILE")" = "$want" ]; then
        return 0
    fi
    printf '%s' "$want" > "$JOURNAL_FILE"
    systemctl try-restart systemd-journald >/dev/null 2>&1 || true
    return 0
}

# DefaultLimitNOFILE 由 PID 1 在启动时读取。不执行 daemon-reexec。
write_systemd_nofile() {
    local want
    [ "$OS_KIND" = debian ] || return 0
    mkdir -p /etc/systemd/system.conf.d
    want=$(printf '[Manager]\nDefaultLimitNOFILE=%s\n' "$nofile")
    if [ -f "$SYSTEMD_NOFILE_FILE" ] && [ "$(cat "$SYSTEMD_NOFILE_FILE")" = "$want" ]; then
        return 0
    fi
    printf '%s' "$want" > "$SYSTEMD_NOFILE_FILE"
    return 0
}

write_rollback_script() {
    mkdir -p "$STATE_DIR"
    cat > "$ROLLBACK_SH" <<'SH'
#!/bin/sh
if [ "$(id -u)" -ne 0 ]; then
    echo "[ERROR] 请以 root 运行" >&2
    exit 1
fi
sysctl -p /var/lib/bbr/previous.conf >/dev/null 2>&1 || true
if [ -f /var/lib/bbr/qdisc.previous ]; then
    while read -r dev kind handle _; do
        [ -n "$dev" ] || continue
        [ -e "/sys/class/net/$dev" ] || continue
        # 先删掉现在的 root，再按原来的 handle 精确重建；
        # handle 为 0: 表示原 qdisc 是内核默认生成的，删掉后由 default_qdisc 接管。
        tc qdisc del dev "$dev" root >/dev/null 2>&1 || true
        if [ "$handle" = "0:" ]; then
            current=$(tc qdisc show dev "$dev" 2>/dev/null | awk '$1=="qdisc" && $4=="root" { print $2; exit }')
            if [ "$current" != "$kind" ]; then
                tc qdisc replace dev "$dev" root "$kind" >/dev/null 2>&1 \
                    || echo "[WARN] 无法恢复 $dev qdisc" >&2
            fi
        else
            tc qdisc add dev "$dev" root handle "$handle" "$kind" >/dev/null 2>&1 \
                || tc qdisc replace dev "$dev" root "$kind" >/dev/null 2>&1 \
                || echo "[WARN] 无法恢复 $dev qdisc" >&2
        fi
    done < /var/lib/bbr/qdisc.previous
fi
while IFS="$(printf '\t')" read -r state path; do
    [ -n "$path" ] || continue
    case "$state" in
        present)
            src="/var/lib/bbr/original$path"
            mkdir -p "$(dirname "$path")"
            cp -a "$src" "$path"
            ;;
        absent) rm -f "$path" ;;
    esac
done < /var/lib/bbr/files.manifest
if command -v systemctl >/dev/null 2>&1; then
    systemctl try-restart systemd-journald >/dev/null 2>&1 || true
fi
rm -rf /var/lib/bbr
echo "[INFO] 已回滚配置和 qdisc；已加载模块及 conntrack buckets 可能需重启后完全恢复"
SH
    chmod 755 "$ROLLBACK_SH"
}

do_rollback() {
    [ "$(id -u)" -eq 0 ] || die "请以 root 运行"
    [ -f "$ROLLBACK_SH" ] || die "没有可回滚的记录"
    sh "$ROLLBACK_SH"
}

main() {
    [ "$(id -u)" -eq 0 ] || die "请以 root 运行"
    detect_os
    check_deps
    mem_mb
    compute_tuning "$memory_mb" \
        "$(sysctl_get fs.file-max)" \
        "$(sysctl_get net.netfilter.nf_conntrack_max)" \
        "$(sysctl_get net.core.rmem_max)" \
        "$(sysctl_get net.core.wmem_max)" \
        "$(sysctl_get net.core.netdev_max_backlog)" \
        "$(sysctl_get net.core.somaxconn)" \
        "$(sysctl_get net.ipv4.tcp_max_tw_buckets)"

    # conntrack 哈希表必须是 2 的幂；当前已更大则保留当前值
    ct_buckets=$(round_pow2_up $((conntrack_max / 4)))
    current_buckets=$(sysctl_get net.netfilter.nf_conntrack_buckets)
    if [[ "$current_buckets" =~ ^[0-9]+$ ]] && [ "$current_buckets" -gt "$ct_buckets" ]; then
        ct_buckets=$current_buckets
    fi

    # buckets sysctl 是否可写：直接看 /proc/sys 下该文件的权限（只读探测，不写内核）。
    # 可写则立即生效并写进 drop-in；只读则退回 modprobe.d 的模块参数。
    CT_SYSCTL_WRITABLE=0
    if [ -w /proc/sys/net/netfilter/nf_conntrack_buckets ]; then
        CT_SYSCTL_WRITABLE=1
    fi

    # 只读探测，不写内核
    cc=cubic
    qdisc=""
    BBR_MISSING=0
    CT_NOTE="未检查（dry-run）"
    if bbr_available; then
        cc=bbr
        if fq_available; then
            qdisc="net.core.default_qdisc = fq"
        fi
    else
        BBR_MISSING=1
    fi

    show_plan
    if [ "$DRY_RUN" -eq 1 ]; then
        echo "[DRY-RUN] 以上仅为预览，未修改任何文件或内核参数"
        return 0
    fi
    confirm_or_exit

    ct_was_loaded=0
    [ -d /sys/module/nf_conntrack ] && ct_was_loaded=1
    snapshot_sysctl
    snapshot_files
    write_rollback_script
    load_tuning_modules
    apply_conntrack_buckets "$ct_buckets"
    persist_modules
    snapshot_sysctl
    # 刚加载的模块参数不是改前值，不能记进 sysctl 回滚快照。
    if [ "$ct_was_loaded" -eq 0 ] && [ -f "$PREV_FILE" ]; then
        awk -F ' = ' '$1 != "net.netfilter.nf_conntrack_buckets"' "$PREV_FILE" > "$PREV_FILE.tmp" || true
        mv "$PREV_FILE.tmp" "$PREV_FILE"
    fi

    # 实际应用拥塞控制与默认 qdisc（探测阶段不写，这里才写）
    if [ "$cc" = bbr ]; then
        if ! sysctl -w net.ipv4.tcp_congestion_control=bbr >/dev/null 2>&1; then
            echo "[WARN] 设置 BBR 失败，回退为 cubic" >&2
            cc=cubic
            qdisc=""
        elif [ -n "$qdisc" ]; then
            sysctl -w net.core.default_qdisc=fq >/dev/null 2>&1 || qdisc=""
        fi
    fi
    if [ -n "$qdisc" ]; then
        apply_fq_now
    fi

    render_sysctl > "$SYSCTL_FILE"
    apply_sysctl_file
    write_limits
    write_rc_ulimit
    write_journald
    write_systemd_nofile

    echo "[INFO] 完成 ✔ 内存: $mem_show | BBR: $cc | conntrack: $conntrack_max | $CT_NOTE"
    if [ "$BBR_MISSING" -eq 1 ]; then
        echo "[INFO] 内核未提供 tcp_bbr，拥塞控制保持 cubic"
    fi
    if [ "$OS_KIND" = alpine ]; then
        echo "[INFO] OpenRC 服务需重启后使用新 nofile"
    fi
    if [ "$OS_KIND" = debian ]; then
        echo "[INFO] systemd 服务的 nofile 在重启后生效；已在跑的服务需各自重启"
    fi
    echo "[INFO] 回滚: sh $ROLLBACK_SH"
}

# 预览：逐项对比当前值与计划值，不做任何修改
show_plan() {
    local line key val cur tmp changed
    tmp=$(mktemp) || return 0
    render_sysctl > "$tmp"
    echo "[PLAN] 系统: $OS_KIND | 内存: $mem_show | 拥塞控制: $cc$( [ -n "$qdisc" ] && echo ' + fq')"
    echo "[PLAN] nofile: $nofile | conntrack_max: $conntrack_max | buckets 目标: $ct_buckets"
    echo "[POLICY] 将打开 IPv4/IPv6 转发，并把 accept_ra 设为 2"
    echo "[POLICY] conntrack：TCP established 超时 600 秒，UDP stream 超时 60 秒"
    echo "[POLICY] swappiness 将设为 1"
    if [ "$BBR_MISSING" -eq 1 ]; then
        echo "[POLICY] 内核未提供 tcp_bbr，拥塞控制将保持 cubic"
    elif [ -z "$qdisc" ]; then
        echo "[POLICY] 有 BBR，但没有 sch_fq，不做 fq pacing"
    elif command -v tc >/dev/null 2>&1; then
        echo "[POLICY] 物理网卡的 root qdisc 将替换为 fq"
    else
        echo "[POLICY] 将设置 default_qdisc=fq；无 tc，现有网卡 qdisc 不会被改动"
    fi
    if [ "$memory_mb" -lt 1024 ]; then
        echo "[WARN] 内存低于 1G，动态项会落在下限，且 swappiness=1，连接数上来时更容易 OOM"
    fi
    echo "[PLAN] nf_conntrack 若能加载，将写入开机模块列表，供重启后 sysctl 套用"
    echo "[PLAN] 以下 sysctl 将发生变化:"
    changed=0
    while IFS= read -r line; do
        case "$line" in ''|\#*) continue ;; esac
        key=${line%%=*}; key=${key// /}
        val=${line#*=}; val=${val# }
        cur=$(normalize_ws "$(sysctl_get "$key")")
        val=$(normalize_ws "$val")
        if [ "$cur" != "$val" ]; then
            printf '  %-56s %s -> %s\n' "$key" "$cur" "$val"
            changed=$((changed + 1))
        fi
    done < "$tmp"
    [ "$changed" -eq 0 ] && echo "  （无变化）"
    rm -f "$tmp"
    echo "[PLAN] 将写入: $SYSCTL_FILE, $LIMITS_FILE, $MODULES_FILE"
    if [ "${CT_SYSCTL_WRITABLE:-0}" -eq 0 ]; then
        echo "[PLAN] 将写入: $MODPROBE_FILE"
    elif [ -f "$MODPROBE_FILE" ]; then
        echo "[PLAN] 将删除: $MODPROBE_FILE（buckets 改由 sysctl 持久化）"
    fi
    if [ "$OS_KIND" = debian ]; then
        echo "[PLAN] 将写入: $JOURNAL_FILE, $SYSTEMD_NOFILE_FILE"
    else
        echo "[PLAN] 将写入: $PROFILE_FILE, /etc/rc.conf（rc_ulimit）"
    fi
}

confirm_or_exit() {
    local a
    if [ "$ASSUME_YES" -eq 1 ]; then
        return 0
    fi
    printf '确认应用以上调优? [y/N] ' >&2
    if ! IFS= read -r a; then
        a=n
    fi
    case "$a" in
        [yY]*) return 0 ;;
        *) echo "[INFO] 已取消，未做任何修改" >&2; exit 0 ;;
    esac
}

# 直接执行、管道或进程替换时调优；被 source 时仅加载函数
if [[ "${BASH_SOURCE[0]:-$0}" == "$0" \
   || "${BASH_SOURCE[0]:-}" == /dev/fd/* \
   || "${BASH_SOURCE[0]:-}" == /proc/self/fd/* \
   || "${BASH_SOURCE[0]:-}" == /proc/*/fd/* ]]; then
    DRY_RUN=0
    ASSUME_YES=0
    case "${1:-}" in
        rollback) do_rollback ;;
        "") main ;;
        -h|--help) usage ;;
        -n|--dry-run) DRY_RUN=1; main ;;
        -y|--yes) ASSUME_YES=1; main ;;
        *) echo "[ERROR] 未知参数: $1" >&2; usage >&2; exit 2 ;;
    esac
fi
