#!/usr/bin/env bash
#==============================================================================
# VPS 综合管理工具
# 系统优化 + SSH 密钥管理 + Fail2Ban + SSH 安全配置
# 支持：Debian、Alpine
#==============================================================================


RED="\033[31m"; GREEN="\033[32m"; YELLOW="\033[33m"
BLUE="\033[34m"; PURPLE="\033[35m"; CYAN="\033[36m"
GRAY="\033[90m"; BOLD="\033[1m"; RESET="\033[0m"

INFO="${GREEN}[INFO]${RESET}"; WARN="${YELLOW}[WARN]${RESET}"; ERROR="${RED}[ERROR]${RESET}"

if [ "$EUID" -ne 0 ]; then
    echo -e "${ERROR} 请使用 root 用户运行此脚本。"
    exit 1
fi
HOME=/root
export HOME
umask 077

JAIL_CONF="/etc/fail2ban/jail.local"
LOG_FILE="/var/log/fail2ban.log"
TARGET_JAIL="sshd"

SSHD_MAIN="/etc/ssh/sshd_config"
SSHD_CONF_DIR="/etc/ssh/sshd_config.d"

SUDO=""

PKG_MGR=""; INIT_SYS=""; SSH_LOG=""; OS_NAME=""; OS_ID=""; OS_VER=""; OS_SHORT=""
DOCKER_VER=""; COMPOSE_VER=""
SSH_BACKUP_DIR=""
AUTH_BACKUP_FILE=""
AUTH_BACKUP_MISSING=0
AUTH_RESTORE_FAILED=0
F2B_BACKUP_DIR=""
F2B_RESTORE_FAILED=0
SELINUX_SSH_PORT=""
SELINUX_SSH_PORT_ADDED=0

cleanup_runtime() {
    if [ -n "${SSH_BACKUP_DIR:-}" ]; then
        if restore_ssh_config >/dev/null 2>&1 && restart_sshd >/dev/null 2>&1; then
            rm -rf "$SSH_BACKUP_DIR"
            SSH_BACKUP_DIR=""
        else
            echo -e "${ERROR} SSH 配置自动恢复失败，备份仍保留在：${SSH_BACKUP_DIR}" >&2
        fi
    fi
    if [ -n "${AUTH_BACKUP_FILE:-}" ]; then
        if ! restore_authorized_keys >/dev/null 2>&1; then
            echo -e "${ERROR} authorized_keys 自动恢复失败，备份仍保留在：${AUTH_BACKUP_FILE}" >&2
        fi
    fi
    if [ -n "${F2B_BACKUP_DIR:-}" ]; then
        if restore_f2b_config >/dev/null 2>&1 && svc_restart fail2ban >/dev/null 2>&1; then
            rm -rf "$F2B_BACKUP_DIR"
            F2B_BACKUP_DIR=""
        else
            echo -e "${ERROR} Fail2Ban 配置自动恢复失败，备份仍保留在：${F2B_BACKUP_DIR}" >&2
        fi
    fi
    if [ "${SELINUX_SSH_PORT_ADDED:-0}" -eq 1 ] && command -v semanage &>/dev/null; then
        semanage port -d -t ssh_port_t -p tcp "$SELINUX_SSH_PORT" >/dev/null 2>&1 || true
        SELINUX_SSH_PORT_ADDED=0
    fi
}
trap 'cleanup_runtime' EXIT
trap 'exit 130' INT TERM

if command -v flock &>/dev/null; then
    LOCK_FILE="/run/lock/vps.sh.lock"
    mkdir -p /run/lock 2>/dev/null || true
    exec 9>"$LOCK_FILE" || {
        echo -e "${ERROR} 无法创建运行锁：$LOCK_FILE"
        exit 1
    }
    if ! flock -n 9; then
        echo -e "${ERROR} 已有另一个 vps.sh 实例正在运行。"
        exit 1
    fi
fi

# ============ 能力检测 ============
detect_os() {
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        OS_NAME="${NAME:-Unknown}"; OS_ID="${ID:-unknown}"; OS_VER="${VERSION_ID:-}"
    else
        OS_NAME=$(uname -s); OS_VER=$(uname -r); OS_ID="unknown"
    fi
    case "$OS_ID" in
        debian) OS_SHORT="Debian" ;;
        alpine) OS_SHORT="Alpine" ;;
        *) OS_SHORT="$OS_NAME" ;;
    esac
}

detect_pkg_mgr() {
    case "$OS_ID" in
        debian) command -v apt-get &>/dev/null && PKG_MGR="apt" ;;
        alpine) command -v apk &>/dev/null && PKG_MGR="apk" ;;
    esac
    [ -n "$PKG_MGR" ] || PKG_MGR="unknown"
}

detect_init() {
    if [ -d /run/systemd/system ]; then INIT_SYS="systemd"
    elif [ -d /run/openrc ]; then INIT_SYS="openrc"
    elif [ -x /sbin/init ]; then INIT_SYS="sysvinit"
    else INIT_SYS="unknown"; fi
}

detect_ssh_log() {
    case "$OS_ID" in
        debian) SSH_LOG="/var/log/auth.log" ;;
        alpine) SSH_LOG="/var/log/messages" ;;
    esac
}

# ============ 服务管理抽象 ============
svc_action() {
    local action="$1" service="$2"
    case "$INIT_SYS" in
        systemd) systemctl "$action" "$service" 2>/dev/null ;;
        openrc) rc-service "$service" "$action" 2>/dev/null ;;
        sysvinit) service "$service" "$action" 2>/dev/null ;;
        *) return 1 ;;
    esac
}
svc_start()   { svc_action start "$1"; }
svc_stop()    { svc_action stop "$1"; }
svc_restart() { svc_action restart "$1"; }
svc_enable() {
    case "$INIT_SYS" in
        systemd) systemctl enable "$1" 2>/dev/null ;;
        openrc) rc-update add "$1" default 2>/dev/null ;;
        sysvinit) update-rc.d "$1" defaults 2>/dev/null || chkconfig "$1" on 2>/dev/null ;;
        *) return 1 ;;
    esac
}
svc_disable() {
    case "$INIT_SYS" in
        systemd) systemctl disable "$1" 2>/dev/null ;;
        openrc) rc-update del "$1" default 2>/dev/null ;;
        sysvinit) update-rc.d -f "$1" remove 2>/dev/null || chkconfig "$1" off 2>/dev/null ;;
        *) return 1 ;;
    esac
}

# ============ 包管理抽象 ============
pkg_install() {
    case "$PKG_MGR" in
        apt) apt-get update -qq && DEBIAN_FRONTEND=noninteractive apt-get install -y "$@" ;;
        apk) apk add --no-cache "$@" ;;
        *) echo -e "${ERROR} 未知包管理器"; return 1 ;;
    esac
}
pkg_remove() {
    case "$PKG_MGR" in
        apt) apt-get remove --purge -y "$@" && apt-get autoremove -y ;;
        apk) apk del "$@" ;;
        *) return 1 ;;
    esac
}
pkg_reinstall() {
    case "$PKG_MGR" in
        apt) DEBIAN_FRONTEND=noninteractive apt-get install --reinstall -y "$@" ;;
        apk) apk add --no-cache "$@" ;;
        *) return 1 ;;
    esac
}

# 检测 EOL 系统（仅用于提示，不自动修改配置）
check_eol_system() {
    case "$OS_ID" in
        debian)
            case "$OS_VER" in
                8|9|10|11)
                    echo -e "\n${YELLOW}${BOLD}[提示] 检测到 Debian ${OS_VER}，该系统已停止官方支持。${RESET}"
                    echo -e "${YELLOW}apt 源可能已失效，导致无法正常安装软件。${RESET}"
                    echo -e "${YELLOW}如果安装失败，可将 /etc/apt/sources.list 改为 archive 源：${RESET}\n"
                    local codename=""
                    case "$OS_VER" in
                        8) codename="jessie" ;;
                        9) codename="stretch" ;;
                        10) codename="buster" ;;
                        11) codename="bullseye" ;;
                    esac
                    if [ -n "$codename" ]; then
                        echo -e "${CYAN}示例：${RESET}"
                        echo -e "  deb http://archive.debian.org/debian ${codename} main contrib non-free"
                        echo -e "  deb http://archive.debian.org/debian ${codename}-updates main contrib non-free"
                        echo -e "\n${CYAN}修改后执行：sudo apt update${RESET}"
                    fi
                    echo ""
                    ;;
            esac
            ;;
    esac
}

# ============ SSH 配置管理 ============
backup_ssh_config() {
    [ -z "$SSH_BACKUP_DIR" ] || return 0
    SSH_BACKUP_DIR=$(mktemp -d "/run/vps-ssh-backup-$(date +%Y%m%d%H%M%S)-XXXXXX") || return 1
    if [ -f "$SSHD_MAIN" ] && ! cp -a "$SSHD_MAIN" "$SSH_BACKUP_DIR/sshd_config"; then
        rm -rf "$SSH_BACKUP_DIR"
        SSH_BACKUP_DIR=""
        return 1
    elif [ ! -f "$SSHD_MAIN" ]; then
        touch "$SSH_BACKUP_DIR/sshd_config-absent" || { rm -rf "$SSH_BACKUP_DIR"; SSH_BACKUP_DIR=""; return 1; }
    fi
    if [ -d "$SSHD_CONF_DIR" ]; then
        touch "$SSH_BACKUP_DIR/confdir-existed"
        if ! cp -a "$SSHD_CONF_DIR" "$SSH_BACKUP_DIR/sshd_config.d"; then
            rm -rf "$SSH_BACKUP_DIR"
            SSH_BACKUP_DIR=""
            return 1
        fi
    fi
    return 0
}

restore_ssh_config() {
    [ -n "$SSH_BACKUP_DIR" ] || return 0
    local tmp_main tmp_dir old_dir

    if [ -f "$SSH_BACKUP_DIR/sshd_config" ]; then
        tmp_main=$(mktemp "${SSHD_MAIN}.restore.XXXXXX") || return 1
        if ! cp -a "$SSH_BACKUP_DIR/sshd_config" "$tmp_main" || ! mv -f "$tmp_main" "$SSHD_MAIN"; then
            rm -f "$tmp_main"
            return 1
        fi
    elif [ -f "$SSH_BACKUP_DIR/sshd_config-absent" ]; then
        rm -f "$SSHD_MAIN" || return 1
    fi

    if [ -f "$SSH_BACKUP_DIR/confdir-existed" ]; then
        tmp_dir=$(mktemp -d "${SSHD_CONF_DIR}.restore.XXXXXX") || return 1
        if ! cp -a "$SSH_BACKUP_DIR/sshd_config.d/." "$tmp_dir/"; then
            rm -rf "$tmp_dir"
            return 1
        fi
        old_dir="${SSHD_CONF_DIR}.failed-restore.$$"
        if [ -e "$SSHD_CONF_DIR" ] && ! mv "$SSHD_CONF_DIR" "$old_dir"; then
            rm -rf "$tmp_dir"
            return 1
        fi
        if ! mv "$tmp_dir" "$SSHD_CONF_DIR"; then
            [ -e "$old_dir" ] && mv "$old_dir" "$SSHD_CONF_DIR"
            rm -rf "$tmp_dir"
            return 1
        fi
        rm -rf "$old_dir"
    else
        rm -rf "$SSHD_CONF_DIR" || return 1
    fi
    return 0
}

commit_ssh_config() {
    [ -n "$SSH_BACKUP_DIR" ] && rm -rf "$SSH_BACKUP_DIR"
    SSH_BACKUP_DIR=""
}

rollback_ssh_config() {
    if restore_ssh_config && restart_sshd >/dev/null 2>&1; then
        rm -rf "$SSH_BACKUP_DIR"
        SSH_BACKUP_DIR=""
    else
        echo -e "${ERROR} SSH 配置恢复或重启失败，备份仍保留在：${SSH_BACKUP_DIR}"
    fi
}

backup_authorized_keys() {
    local auth_file="${HOME}/.ssh/authorized_keys"
    [ -n "$AUTH_BACKUP_FILE" ] && rm -f "$AUTH_BACKUP_FILE"
    AUTH_BACKUP_FILE=$(mktemp /run/vps-authorized-keys.XXXXXX) || return 1
    AUTH_BACKUP_MISSING=0
    AUTH_RESTORE_FAILED=0
    if [ -f "$auth_file" ]; then
        cp -a "$auth_file" "$AUTH_BACKUP_FILE" || { rm -f "$AUTH_BACKUP_FILE"; AUTH_BACKUP_FILE=""; return 1; }
    else
        AUTH_BACKUP_MISSING=1
    fi
}

restore_authorized_keys() {
    local auth_file="${HOME}/.ssh/authorized_keys"
    [ -n "$AUTH_BACKUP_FILE" ] || return 0
    if [ "$AUTH_BACKUP_MISSING" -eq 1 ]; then
        if ! rm -f "$auth_file"; then AUTH_RESTORE_FAILED=1; return 1; fi
    else
        if ! cp -a "$AUTH_BACKUP_FILE" "$auth_file" || ! chmod 600 "$auth_file"; then
            AUTH_RESTORE_FAILED=1
            return 1
        fi
    fi
    rm -f "$AUTH_BACKUP_FILE" || { AUTH_RESTORE_FAILED=1; return 1; }
    AUTH_BACKUP_FILE=""
    AUTH_BACKUP_MISSING=0
    AUTH_RESTORE_FAILED=0
}

commit_authorized_keys() {
    if [ "$AUTH_RESTORE_FAILED" -eq 1 ]; then
        echo -e "${ERROR} authorized_keys 恢复失败，备份仍保留在：${AUTH_BACKUP_FILE}" >&2
        return 1
    fi
    [ -n "$AUTH_BACKUP_FILE" ] && rm -f "$AUTH_BACKUP_FILE"
    AUTH_BACKUP_FILE=""
    AUTH_BACKUP_MISSING=0
}

backup_f2b_config() {
    [ -z "$F2B_BACKUP_DIR" ] || return 0
    F2B_BACKUP_DIR=$(mktemp -d "/run/vps-f2b-config-$(date +%Y%m%d%H%M%S)-XXXXXX") || return 1
    F2B_RESTORE_FAILED=0
    if [ -f "$JAIL_CONF" ]; then
        cp -a "$JAIL_CONF" "$F2B_BACKUP_DIR/jail.local" || { rm -rf "$F2B_BACKUP_DIR"; F2B_BACKUP_DIR=""; return 1; }
    else
        touch "$F2B_BACKUP_DIR/jail.local-absent" || { rm -rf "$F2B_BACKUP_DIR"; F2B_BACKUP_DIR=""; return 1; }
    fi
}

restore_f2b_config() {
    [ -n "$F2B_BACKUP_DIR" ] || return 0
    if [ -f "$F2B_BACKUP_DIR/jail.local" ]; then
        if ! cp -a "$F2B_BACKUP_DIR/jail.local" "$JAIL_CONF"; then
            F2B_RESTORE_FAILED=1
            return 1
        fi
    elif [ -f "$F2B_BACKUP_DIR/jail.local-absent" ]; then
        if ! rm -f "$JAIL_CONF"; then
            F2B_RESTORE_FAILED=1
            return 1
        fi
    fi
    F2B_RESTORE_FAILED=0
    return 0
}

commit_f2b_config() {
    if [ "$F2B_RESTORE_FAILED" -eq 1 ]; then
        echo -e "${ERROR} Fail2Ban 配置恢复失败，备份仍保留在：${F2B_BACKUP_DIR}" >&2
        return 1
    fi
    [ -n "$F2B_BACKUP_DIR" ] && rm -rf "$F2B_BACKUP_DIR"
    F2B_BACKUP_DIR=""
}

# 使用 OpenSSH 自身解析最终生效配置，避免手工模拟 Include/Match/First Match 规则。
get_sshd_config_val() {
    local key="$1" default_val="$2" val=""
    if command -v sshd &>/dev/null; then
        val=$(sshd -T 2>/dev/null | awk -v key="${key,,}" 'tolower($1) == key {print $2; exit}')
    fi
    printf '%s\n' "${val:-$default_val}"
}

# 只修改主配置文件，并放在 Include/Match 之前，避免改写发行版或云厂商的 .d 文件。
set_sshd_config() {
    local param="$1" value="$2" tmpf
    [ -f "$SSHD_MAIN" ] || touch "$SSHD_MAIN" || return 1
    tmpf=$(mktemp "${SSHD_MAIN}.tmp.XXXXXX") || return 1
    if ! awk -v p="$param" -v v="$value" '
        BEGIN { target=tolower(p); inserted=0 }
        {
            line=$0
            sub(/^[[:space:]]*#[[:space:]]*/, "", line)
            key=line
            sub(/^[[:space:]]*/, "", key)
            sub(/[[:space:]=].*$/, "", key)
            if (tolower(key) == target) next
            if (!inserted && tolower($0) ~ /^[[:space:]]*(include|match)[[:space:]]/) {
                print p " " v
                inserted=1
            }
            print
        }
        END { if (!inserted) print p " " v }
    ' "$SSHD_MAIN" > "$tmpf"; then
        rm -f "$tmpf"
        return 1
    fi
    if ! cp "$tmpf" "$SSHD_MAIN"; then
        rm -f "$tmpf"
        return 1
    fi
    rm -f "$tmpf"
}

restart_sshd() {
    echo -e "${INFO} 正在检测 SSH 配置文件语法..."
    if command -v sshd &>/dev/null; then
        if ! $SUDO sshd -t; then
            echo -e "${ERROR} SSH 配置文件测试失败！检测到语法错误，已取消重启以防止断连锁死！"
            return 1
        fi
    fi

    echo -e "${INFO} 正在重启 SSH 服务..."
    local restart_ok=1
    if [ "$INIT_SYS" = "systemd" ]; then
        $SUDO systemctl daemon-reload &>/dev/null || true
        local ssh_unit=""
        if systemctl list-unit-files 2>/dev/null | grep -q '^ssh\.service'; then
            ssh_unit="ssh.service"
        elif systemctl list-unit-files 2>/dev/null | grep -q '^sshd\.service'; then
            ssh_unit="sshd.service"
        elif systemctl list-unit-files 2>/dev/null | grep -q '^ssh\.socket'; then
            ssh_unit="ssh.socket"
        fi
        if [ -n "$ssh_unit" ]; then
            if svc_restart "$ssh_unit" && systemctl is-active --quiet "$ssh_unit"; then
                restart_ok=0
            fi
        else
            echo -e "${ERROR} 未找到 ssh.service 或 sshd.service！"
        fi
    elif [ "$INIT_SYS" = "openrc" ]; then
        svc_restart sshd && restart_ok=0
    else
        svc_restart sshd 2>/dev/null && restart_ok=0
        if [ "$restart_ok" -ne 0 ]; then
            svc_restart ssh 2>/dev/null && restart_ok=0
        fi
    fi

    if [ "$restart_ok" -eq 0 ]; then
        echo -e "${INFO} ${GREEN}SSH 服务重启成功！${RESET}"
        return 0
    else
        echo -e "${ERROR} SSH 服务重启失败，请检查配置文件！"
        return 1
    fi
}

# ============ 依赖安装 ============
check_dependencies() {
    local pkgs=()
    command -v curl &>/dev/null || pkgs+=(curl)
    if ! command -v ssh-keygen &>/dev/null; then
        if [ "$OS_ID" = "alpine" ]; then
            pkgs+=(openssh-keygen)
        else
            pkgs+=(openssh-client)
        fi
    fi
    if [ "${#pkgs[@]}" -gt 0 ]; then
        echo -e "${WARN} 需要安装依赖: ${pkgs[*]}"
        read -rp "现在安装这些依赖吗？(Y/n): " install_confirm
        if [[ "$install_confirm" =~ ^[Nn]$ ]]; then
            echo -e "${ERROR} 未安装依赖，退出管理工具。"
            return 1
        fi
        if ! pkg_install "${pkgs[@]}"; then
            echo -e "${ERROR} 依赖安装失败，无法启动管理菜单。"
            return 1
        fi
    fi
    if ! command -v curl &>/dev/null || ! command -v ssh-keygen &>/dev/null; then
        echo -e "${ERROR} 缺少必要依赖 curl 或 ssh-keygen。"
        return 1
    fi
    return 0
}

init_ssh_dir() {
    mkdir -p "${HOME}/.ssh" || return 1
    touch "${HOME}/.ssh/authorized_keys" || return 1
    chmod 700 "${HOME}/.ssh" || return 1
    chmod 600 "${HOME}/.ssh/authorized_keys" || return 1
    chown root:root "${HOME}/.ssh" "${HOME}/.ssh/authorized_keys" 2>/dev/null || true
}

extract_core_key() {
    awk '{
        for(i=1;i<=NF;i++){
            if($i ~ /^(ssh-|ecdsa-|sk-)/){
                for(j=1;j<=i+1 && j<=NF;j++) printf "%s%s", $j, (j<i+1?" ":"")
                print ""
                exit
            }
        }
    }'
}

extract_key_options() {
    awk '{
        for(i=1;i<=NF;i++) {
            if($i ~ /^(ssh-|ecdsa-|sk-)/) {
                if(i > 1) {
                    for(j=1;j<i;j++) printf "%s%s", $j, (j<i-1 ? " " : "")
                    print ""
                }
                exit
            }
        }
    }'
}

is_valid_core_key() {
    local core_key="$1" key_material
    key_material=$(printf '%s\n' "$core_key" | awk '{print $(NF-1), $NF}')
    [ -n "$core_key" ] && ssh-keygen -lf <(printf '%s\n' "$key_material") >/dev/null 2>&1
}

# 追加公钥
# - 保留选项前缀（如 from="1.2.3.4",command="..."）
# - 丢弃尾部注释（避免污染元数据标签）
# - 用完整「密钥类型 + Base64 主体」做去重
append_key_with_meta() {
    local pub_content="$1" source_tag="$2" auth_file="${HOME}/.ssh/authorized_keys"
    local ts; ts=$(date "+%Y-%m-%d %H:%M:%S")
    local added=0 invalid=0
    init_ssh_dir || return 1
    while IFS= read -r line; do
        [ -z "$line" ] && continue
        line=$(printf '%s\n' "$line" | sed -e 's/[[:space:]]*$//')
        local core_key; core_key=$(printf '%s\n' "$line" | extract_core_key)
        if ! is_valid_core_key "$core_key"; then
            invalid=$((invalid + 1))
            continue
        fi
        local key_base64 key_options auth_entry
        key_base64=$(printf '%s\n' "$core_key" | awk '{print $NF}')
        if awk -v k="$key_base64" '$0 !~ /^[[:space:]]*#/ { for (i=1; i<NF; i++) if ($i ~ /^(ssh-|ecdsa-|sk-)/ && $(i+1) == k) found=1 } END{exit !found}' "$auth_file"; then
            echo -e "${WARN} 该公钥已经存在于 authorized_keys 中，已跳过重复追加。"
            continue
        fi
        key_options=$(printf '%s\n' "$line" | extract_key_options)
        if [ -n "$key_options" ]; then
            auth_entry="${key_options} ${core_key}"
        else
            auth_entry="$core_key"
        fi
        if ! printf '%s\n' "${auth_entry} [${ts}|${source_tag}]" >> "$auth_file"; then
            echo -e "${ERROR} 无法写入 authorized_keys。"
            return 1
        fi
        echo -e "${INFO} ${GREEN}已成功追加公钥 (${source_tag})${RESET}"
        added=$((added + 1))
    done <<< "$pub_content"
    if ! chmod 600 "$auth_file"; then
        echo -e "${ERROR} 无法设置 authorized_keys 权限。"
        return 1
    fi
    if [ "$added" -eq 0 ]; then
        [ "$invalid" -gt 0 ] && echo -e "${ERROR} 未找到有效 SSH 公钥，未写入任何内容。"
        return 1
    fi
    return 0
}

# 统计 authorized_keys 中有效公钥数量
count_authorized_keys() {
    local auth_file="${HOME}/.ssh/authorized_keys" count=0 line core_key
    [ -f "$auth_file" ] || { echo 0; return; }
    while IFS= read -r line || [ -n "$line" ]; do
        [[ -z "$line" || "$line" =~ ^[[:space:]]*# ]] && continue
        core_key=$(printf '%s\n' "$line" | extract_core_key)
        is_valid_core_key "$core_key" && count=$((count + 1))
    done < "$auth_file"
    echo "$count"
}

# 判断 authorized_keys 是否有有效公钥
has_valid_pubkey() {
    [ "$(count_authorized_keys)" -gt 0 ]
}

# ============ Fail2Ban ============
# 参数读取：优先读 [sshd] 段 → 读不到再读 [DEFAULT] 段
# 递增参数（bantime.increment/factor/maxtime）只应在 [DEFAULT] 段生效
get_f2b_conf() {
    local key=$1
    [ -f "$JAIL_CONF" ] || return
    # 1. 先读 [sshd] 段
    local result
    result=$(awk -v t="$TARGET_JAIL" -v k="$key" '
        BEGIN { in_block=0; result="" }
        $0 ~ "^\\[" t "\\][[:space:]]*$" { in_block=1; next }
        /^[[:space:]]*\[/ { in_block=0 }
        in_block && $0 ~ "^[[:space:]]*" k "[[:space:]]*=" {
            value=$0
            sub(/^[[:space:]]*[^=]+=[[:space:]]*/, "", value)
            sub(/[[:space:]]+$/, "", value)
            result = value
        }
        END { if (result != "") print result }
    ' "$JAIL_CONF")
    # 2. [sshd] 段没有 → 从 [DEFAULT] 段取
    if [ -z "$result" ]; then
        result=$(awk -v k="$key" '
            BEGIN { in_block=0; result="" }
            /^\[DEFAULT\][[:space:]]*$/ { in_block=1; next }
            /^[[:space:]]*\[/ { in_block=0 }
            in_block && $0 ~ "^[[:space:]]*" k "[[:space:]]*=" {
                value=$0
                sub(/^[[:space:]]*[^=]+=[[:space:]]*/, "", value)
                sub(/[[:space:]]+$/, "", value)
                result = value
            }
            END { if (result != "") print result }
        ' "$JAIL_CONF")
    fi
    echo "$result"
}

# 参数写入：
# - bantime.increment / bantime.factor / bantime.maxtime / dbfile / dbpurgeage 属于 [DEFAULT] 段
# - 其余参数写入 [sshd] 段
set_f2b_conf() {
    local key="$1" val="$2" target_section="$TARGET_JAIL"
    local backup_file existed=0 tmpf exists
    case "$key" in
        bantime.increment|bantime.factor|bantime.maxtime|dbfile|dbpurgeage)
            target_section="DEFAULT"
            ;;
    esac

    backup_file=$(mktemp /run/vps-f2b.XXXXXX) || return 1
    if [ -f "$JAIL_CONF" ]; then
        existed=1
        cp -a "$JAIL_CONF" "$backup_file" || { rm -f "$backup_file"; return 1; }
    fi

    if [ ! -f "$JAIL_CONF" ]; then
        {
            echo "[DEFAULT]"
            echo "[$TARGET_JAIL]"
        } > "$JAIL_CONF" || { rm -f "$backup_file"; return 1; }
    fi
    if ! grep -q "^\[${target_section}\]" "$JAIL_CONF"; then
        printf '\n[%s]\n' "$target_section" >> "$JAIL_CONF" || { rm -f "$backup_file"; return 1; }
    fi

    exists=$(awk -v t="$target_section" -v k="$key" '
        BEGIN { in_block=0; found=0 }
        $0 ~ "^\\[" t "\\][[:space:]]*$" { in_block=1; next }
        /^[[:space:]]*\[/ { in_block=0 }
        in_block && $0 ~ "^[[:space:]]*" k "[[:space:]]*=" { found=1 }
        END { print found }
    ' "$JAIL_CONF")

    if [ "$exists" = "1" ]; then
        tmpf=$(mktemp) || { rm -f "$backup_file"; return 1; }
        if ! awk -v t="$target_section" -v k="$key" -v v="$val" '
            BEGIN { in_block=0; done=0 }
            $0 ~ "^\\[" t "\\][[:space:]]*$" { in_block=1; print; next }
            /^[[:space:]]*\[/ { in_block=0 }
            in_block && !done && $0 ~ "^[[:space:]]*" k "[[:space:]]*=" {
                print k " = " v
                done=1
                next
            }
            { print }
        ' "$JAIL_CONF" > "$tmpf" && cp "$tmpf" "$JAIL_CONF"; then
            rm -f "$tmpf" "$backup_file"
            return 1
        fi
        rm -f "$tmpf"
    else
        if ! sed -i "/^\[${target_section}\]/a ${key} = ${val}" "$JAIL_CONF"; then
            rm -f "$backup_file"
            return 1
        fi
    fi

    if command -v fail2ban-client &>/dev/null && ! fail2ban-client -t >/dev/null 2>&1; then
        if [ "$existed" -eq 1 ]; then cp -a "$backup_file" "$JAIL_CONF"; else rm -f "$JAIL_CONF"; fi
        rm -f "$backup_file"
        echo -e "${ERROR} Fail2Ban 配置测试失败，已恢复原配置。"
        return 1
    fi
    rm -f "$backup_file"
    return 0
}

restart_f2b() {
    echo -e "${INFO} 正在重载 Fail2Ban 配置..."
    if command -v fail2ban-client &>/dev/null && ! fail2ban-client -t >/dev/null 2>&1; then
        echo -e "${ERROR} Fail2Ban 配置测试失败。"
        return 1
    fi
    if ! svc_restart fail2ban; then
        echo -e "${ERROR} Fail2Ban 服务重启命令失败。"
        return 1
    fi
    for i in {1..5}; do
        if fail2ban-client ping >/dev/null 2>&1; then
            echo -e "${INFO} ${GREEN}成功！配置已加载。${RESET}"
            return 0
        fi
        sleep 1
    done
    echo -e "${ERROR} Fail2Ban 重启超时或失败。"
    echo -e "${YELLOW}请手动运行 'journalctl -u fail2ban -n 50' 排查错误。${RESET}"
    return 1
}

get_fail2ban_status() {
    # 清命令缓存，否则 bash 会记住已被卸载的旧路径，
    # 导致 apt remove 后 command -v 仍返回旧路径、状态显示"已安装"。
    hash -r 2>/dev/null
    if command -v fail2ban-client >/dev/null 2>&1 && fail2ban-client ping >/dev/null 2>&1; then
        local count
        count=$(fail2ban-client status "$TARGET_JAIL" 2>/dev/null | grep -i "Currently banned" | awk '{print $NF}')
        echo -e "${GREEN}防护中 (已封禁${count:-0} IP)${RESET}"
    elif command -v fail2ban-client >/dev/null 2>&1; then
        echo -e "${YELLOW}已安装 / 已停止${RESET}"
    else
        echo -e "${YELLOW}未安装${RESET}"
    fi
}

fmt_f2b_unit() {
    local val=$1 type=$2
    if [[ "$val" =~ ^[0-9]+$ ]]; then
        [ "$type" == "time" ] && echo "${val}秒" || { [ "$type" == "factor" ] && echo "${val}倍" || echo "$val"; }
    else echo "$val"; fi
}

validate_time() { [[ "$1" =~ ^[1-9][0-9]*[smhdw]?$ ]]; }
validate_int() { [[ "$1" =~ ^[1-9][0-9]*(\.[0-9]+)?$ ]]; }

f2b_ssh_filter() {
    if [ "$OS_ID" = "alpine" ] && [ -f /etc/fail2ban/filter.d/alpine-sshd.conf ]; then
        printf '%s\n' alpine-sshd
    else
        printf '%s\n' sshd
    fi
}

# systemd 环境默认走 journal，不写死 logpath（避免 WARN）
# port 动态读取当前 SSH 端口，避免装 F2B 前已改端口时防护失效
# 递增参数 + 数据库配置写入 [DEFAULT] 段（Fail2Ban 官方要求）
generate_default_jail_conf() {
    local backend="auto"
    local logpath_line="logpath = ${SSH_LOG}"
    if [ "$INIT_SYS" = "systemd" ]; then
        backend="systemd"
        logpath_line=""
    fi
    local ssh_filter
    ssh_filter=$(f2b_ssh_filter)
    local banaction="iptables-multiport"
    if ! command -v iptables &>/dev/null && command -v nft &>/dev/null; then
        banaction="nftables-multiport"
    fi
    local current_port
    current_port=$(get_sshd_config_val "Port" "22")
    [ -z "$current_port" ] && current_port="22"
    cat <<EOF2
[DEFAULT]
backend = ${backend}
dbfile = /var/lib/fail2ban/fail2ban.sqlite3
dbpurgeage = 648000
bantime.increment = true
bantime.factor = 2
bantime.maxtime = 7d

[${TARGET_JAIL}]
enabled = true
port = ${current_port}
filter = ${ssh_filter}
${logpath_line}
maxretry = 5
bantime = 600
findtime = 3600
banaction = ${banaction}
ignoreip = 127.0.0.1/8
EOF2
}

# 迁移：老配置里 [sshd] 段的递增参数挪到 [DEFAULT] 段
# 老版本脚本把 bantime.increment/factor/maxtime 错误地写在了 [sshd] 段
# Fail2Ban 只认 [DEFAULT]，导致"指数递增"完全不生效
# 同时确保 dbfile 和 dbpurgeage 存在（递增功能必需数据库支持）
migrate_f2b_increment() {
    [ -f "$JAIL_CONF" ] || return
    local k
    # 1. 删除 [sshd] 段内的递增参数
    for k in bantime.increment bantime.factor bantime.maxtime; do
        local sshd_has
        sshd_has=$(awk -v t="$TARGET_JAIL" -v kk="$k" '
            BEGIN { in_block=0; found=0 }
            $0 ~ "^\\[" t "\\][[:space:]]*$" { in_block=1; next }
            /^[[:space:]]*\[/ { in_block=0 }
            in_block && $0 ~ "^[[:space:]]*" kk "[[:space:]]*=" { found=1 }
            END { print found }
        ' "$JAIL_CONF")
        if [ "$sshd_has" = "1" ]; then
            $SUDO sed -i "/^\[${TARGET_JAIL}\]/,/^\[/ {/^${k}[[:space:]]*=/d}" "$JAIL_CONF"
        fi
    done

    # 2. 检查 [DEFAULT] 段是否所有必需参数齐全（递增三参数 + 数据库两参数）
    local need_fix=0
    for k in bantime.increment bantime.factor bantime.maxtime dbfile dbpurgeage; do
        local v
        v=$(awk -v kk="$k" '
            BEGIN { in_block=0; result="" }
            /^\[DEFAULT\][[:space:]]*$/ { in_block=1; next }
            /^[[:space:]]*\[/ { in_block=0 }
            in_block && $0 ~ "^[[:space:]]*" kk "[[:space:]]*=" {
                value=$0
                sub(/^[[:space:]]*[^=]+=[[:space:]]*/, "", value)
                sub(/[[:space:]]+$/, "", value)
                result = value
            }
            END { if (result != "") print result }
        ' "$JAIL_CONF")
        [ -z "$v" ] && need_fix=1
    done

    # 3. 缺失则重写 [DEFAULT] 段的全部五行配置
    if [ "$need_fix" = "1" ]; then
        # 先清理可能存在的旧配置
        for k in bantime.increment bantime.factor bantime.maxtime dbfile dbpurgeage; do
            $SUDO sed -i "/^\[DEFAULT\]/,/^\[/ {/^${k}[[:space:]]*=/d}" "$JAIL_CONF"
        done
        # 批量插入完整配置（注意顺序：数据库配置在前，递增配置在后）
        $SUDO sed -i '/^\[DEFAULT\]/a dbfile = /var/lib/fail2ban/fail2ban.sqlite3\ndbpurgeage = 648000\nbantime.increment = true\nbantime.factor = 2\nbantime.maxtime = 7d' "$JAIL_CONF"
    fi

    # 4. 确保数据库目录存在且权限正确
    if [ ! -d "/var/lib/fail2ban" ]; then
        $SUDO mkdir -p /var/lib/fail2ban
        $SUDO chmod 755 /var/lib/fail2ban
    fi
}

check_f2b_install() {
    hash -r 2>/dev/null
    if ! command -v fail2ban-client >/dev/null 2>&1; then
        echo -e "${WARN} 未检测到 Fail2Ban 服务。"
        read -rp "是否立即安装 Fail2Ban？(y/N): " install_confirm
        [[ ! "$install_confirm" =~ ^[Yy]$ ]] && { echo -e "${WARN} 已取消安装。"; return 1; }

        echo -e "${INFO} 正在安装 Fail2Ban 及相关依赖..."
        local f2b_pkgs=()
        case "$PKG_MGR" in
            apt)
                f2b_pkgs=("fail2ban" "python3-systemd")
                [ "$INIT_SYS" != "systemd" ] && f2b_pkgs+=("rsyslog")
                ;;
            apk) f2b_pkgs=("fail2ban");;
        esac

        if ! pkg_install "${f2b_pkgs[@]}"; then
            echo -e "${ERROR} Fail2Ban 及其依赖安装失败。"
            return 1
        fi

        if ! command -v fail2ban-client >/dev/null 2>&1; then
            echo -e "\n${ERROR} Fail2Ban 安装失败！${RESET}"
            check_eol_system
            echo -e "${YELLOW}请先解决软件源问题，然后重新运行本脚本。${RESET}"
            read -rp "按回车键返回..."
            return 1
        fi

        if [ ! -d "/etc/fail2ban" ]; then
            echo -e "\n${ERROR} /etc/fail2ban 目录不存在，安装可能不完整。${RESET}"
            echo -e "${YELLOW}请检查 Fail2Ban 是否安装成功：dpkg -l | grep fail2ban${RESET}"
            read -rp "按回车键返回..."
            return 1
        fi

        if [ "$INIT_SYS" != "systemd" ]; then
            if [ "$OS_ID" = "alpine" ]; then
                svc_enable syslog
                svc_start syslog
            elif [ ! -f "$SSH_LOG" ]; then
                svc_enable rsyslog
                svc_start rsyslog
            fi
        fi

        # 先生成配置文件（含递增参数 + 数据库配置），保证后续 restart 能读到完整配置
        [ ! -f "$JAIL_CONF" ] && generate_default_jail_conf | $SUDO tee "$JAIL_CONF" > /dev/null

        # 确保数据库目录存在（指数递增依赖数据库持久化 IP 历史封禁次数）
        [ ! -d "/var/lib/fail2ban" ] && { $SUDO mkdir -p /var/lib/fail2ban; $SUDO chmod 755 /var/lib/fail2ban; }

        svc_enable fail2ban
        # 关键修复：包管理器安装时可能已经自动启动 fail2ban（读的是默认 jail.conf），
        # 此时若用 svc_start 就是空操作，导致刚写入的 jail.local 不被加载。
        # 必须用 svc_restart 强制重读配置，否则指数递增不生效，直到 reboot 才行。
        if ! svc_restart fail2ban; then
            echo -e "${ERROR} Fail2Ban 服务启动失败，请检查服务日志。"
            return 1
        fi

        # 轮询确认服务真正就绪（首次启动可能稍慢）
        local f2b_up=0
        for i in {1..5}; do
            if fail2ban-client ping >/dev/null 2>&1; then f2b_up=1; break; fi
            sleep 1
        done
        if [ "$f2b_up" -eq 1 ]; then
            echo -e "${INFO} ${GREEN}Fail2Ban 安装并启动完成！${RESET}"
        else
            echo -e "${WARN} Fail2Ban 已安装，但服务尚未就绪，请稍后手动检查。"
        fi
        sleep 1; return 0
    fi

    # 已安装 fail2ban-client，但 /etc/fail2ban 目录缺失 = 残缺安装
    if [ ! -d "/etc/fail2ban" ]; then
        echo -e "\n${ERROR} Fail2Ban 处于残缺状态：命令存在但 /etc/fail2ban 目录缺失。${RESET}"
        echo -e "${YELLOW}可能是之前的卸载操作没有清理干净。${RESET}\n"
        echo -e "  ${GREEN}1.${RESET} 尝试修复（重新安装 Fail2Ban 以重建配置目录）"
        echo -e "  ${GREEN}2.${RESET} 强制卸载 Fail2Ban 残留"
        echo -e "  ${GREEN}0.${RESET} 返回"
        read -rp "请选择 [0-2]: " f2b_fix_opt
        case "$f2b_fix_opt" in
            1)
                echo -e "${INFO} 正在重新安装 Fail2Ban..."
                local f2b_pkgs=()
                case "$PKG_MGR" in
                    apt)
                        f2b_pkgs=("fail2ban" "python3-systemd")
                        [ "$INIT_SYS" != "systemd" ] && f2b_pkgs+=("rsyslog")
                        ;;
                    apk) f2b_pkgs=("fail2ban");;
                esac
                if ! pkg_reinstall "${f2b_pkgs[@]}"; then
                    echo -e "${ERROR} Fail2Ban 修复安装失败。"
                    return 1
                fi
                if [ -d "/etc/fail2ban" ]; then
                    echo -e "${INFO} ${GREEN}修复成功！${RESET}"
                    sleep 1
                else
                    echo -e "${ERROR} 修复失败，请手动处理：dpkg -l | grep fail2ban${RESET}"
                    read -rp "按回车键返回..."
                    return 1
                fi
                ;;
            2)
                echo -e "${WARN} 正在强制卸载 Fail2Ban..."
                svc_stop fail2ban 2>/dev/null
                svc_disable fail2ban 2>/dev/null
                pkg_remove fail2ban
                # 兜底：apt 失败时直接用 dpkg 清（dpkg 数据库损坏场景）
                hash -r 2>/dev/null
                if command -v fail2ban-client &>/dev/null; then
                    echo -e "${WARN} 检测到残留，尝试 dpkg 强制清除..."
                    $SUDO dpkg --purge --force-all fail2ban 2>/dev/null || true
                    $SUDO rm -rf /var/lib/dpkg/info/fail2ban.* 2>/dev/null
                    hash -r 2>/dev/null
                fi
                $SUDO rm -rf /etc/fail2ban
                $SUDO rm -f /usr/bin/fail2ban-client /usr/bin/fail2ban-server /usr/local/bin/fail2ban-* 2>/dev/null
                echo -e "${INFO} ${GREEN}Fail2Ban 已强制卸载。${RESET}"
                read -rp "按回车键返回..."
                return 1
                ;;
            *)
                return 1
                ;;
        esac
    fi

    if ! backup_f2b_config; then
        echo -e "${ERROR} 无法备份 Fail2Ban 配置，操作已取消。"
        return 1
    fi

    # 记录配置修改前的哈希（md5sum 更高效，避免大文件全文对比）
    local conf_hash_before=""
    [ -f "$JAIL_CONF" ] && conf_hash_before=$(md5sum "$JAIL_CONF" 2>/dev/null | awk '{print $1}')

    if [ ! -f "$JAIL_CONF" ]; then
        generate_default_jail_conf | $SUDO tee "$JAIL_CONF" > /dev/null
    else
        if ! grep -q "^\[DEFAULT\]" "$JAIL_CONF"; then
            local be="auto"; [ "$INIT_SYS" = "systemd" ] && be="systemd"
            $SUDO sed -i "1i [DEFAULT]\nbackend = ${be}" "$JAIL_CONF"
        fi
        # 迁移老配置：把 [sshd] 段错放的递增参数挪到 [DEFAULT] + 确保数据库配置存在
        migrate_f2b_increment
        if ! grep -q "^\[${TARGET_JAIL}\]" "$JAIL_CONF"; then
            generate_default_jail_conf | grep -A99 "^\[${TARGET_JAIL}\]" | $SUDO tee -a "$JAIL_CONF" > /dev/null
        else
            # 保证 [sshd] 段基本参数齐全（不含递增参数，那些归 [DEFAULT]）
            local current_port
            current_port=$(get_sshd_config_val "Port" "22")
            [ -z "$current_port" ] && current_port="22"
            local defaults=(
                "enabled=true" "port=${current_port}" "filter=$(f2b_ssh_filter)" "maxretry=5"
                "bantime=600" "findtime=3600"
            )
            for item in "${defaults[@]}"; do
                local k="${item%%=*}" v="${item#*=}"
                [ -n "$(get_f2b_conf "$k")" ] || set_f2b_conf "$k" "$v"
            done
        fi
    fi

    # 关键修复：上面可能有迁移/补全动作改动了 jail.local，
    # 用哈希对比判断配置是否真变化，避免每次进菜单都触发 Restore Ban 刷屏。
    local conf_hash_after=""
    [ -f "$JAIL_CONF" ] && conf_hash_after=$(md5sum "$JAIL_CONF" 2>/dev/null | awk '{print $1}')

    if [ "$conf_hash_before" != "$conf_hash_after" ]; then
        # 配置有变化：重载或启动服务让新配置生效
        if fail2ban-client ping >/dev/null 2>&1; then
            restart_f2b
        else
            echo -e "${INFO} 检测到配置变更，正在启动 Fail2Ban..."
            svc_start fail2ban
            local f2b_up=0
            for i in {1..5}; do
                if fail2ban-client ping >/dev/null 2>&1; then f2b_up=1; break; fi
                sleep 1
            done
            if [ "$f2b_up" -eq 1 ]; then
                echo -e "${INFO} ${GREEN}Fail2Ban 已启动并加载新配置。${RESET}"
            else
                echo -e "${ERROR} Fail2Ban 启动超时或失败。"
                echo -e "${YELLOW}请手动运行 'journalctl -u fail2ban -n 50' 排查错误。${RESET}"
            fi
        fi
    else
        # 配置未变化：仅做服务状态兜底，避免每次进菜单重启导致 Restore Ban 刷屏
        if ! fail2ban-client ping >/dev/null 2>&1; then
            echo -e "${WARN} Fail2Ban 服务未运行，正在尝试启动..."
            svc_start fail2ban
            local f2b_up=0
            for i in {1..5}; do
                if fail2ban-client ping >/dev/null 2>&1; then f2b_up=1; break; fi
                sleep 1
            done
            if [ "$f2b_up" -eq 1 ]; then
                echo -e "${INFO} ${GREEN}Fail2Ban 已启动。${RESET}"
            else
                echo -e "${ERROR} Fail2Ban 启动超时或失败。"
                echo -e "${YELLOW}请手动运行 'journalctl -u fail2ban -n 50' 排查错误。${RESET}"
            fi
        fi
    fi

    if command -v fail2ban-client &>/dev/null && ! fail2ban-client -t >/dev/null 2>&1; then
        echo -e "${ERROR} Fail2Ban 配置测试失败，正在恢复原配置。"
        restore_f2b_config
        svc_restart fail2ban >/dev/null 2>&1 || true
        commit_f2b_config
        return 1
    fi
    commit_f2b_config
    return 0
}

uninstall_f2b() {
    echo -e "\n${RED}${BOLD}警告：即将卸载 Fail2Ban 及其配置！${RESET}"
    read -rp "确认卸载吗？(y/N): " confirm
    [[ ! "$confirm" =~ ^[Yy]$ ]] && { echo -e "${INFO} 已取消卸载。"; read -rp "按回车键继续..."; return 1; }
    svc_stop fail2ban; svc_disable fail2ban
    pkg_remove fail2ban
    # 清 bash 命令缓存：否则 command -v 仍返回已删除的旧路径，
    # 导致卸载后状态仍显示"已安装 / 已停止"。
    hash -r 2>/dev/null
    # 兜底：apt 卸载失败时用 dpkg 强制清除（dpkg 数据库损坏 / 静默失败场景）
    if command -v fail2ban-client &>/dev/null; then
        echo -e "${WARN} 检测到残留，尝试 dpkg 强制清除..."
        $SUDO dpkg --purge --force-all fail2ban 2>/dev/null || true
        $SUDO rm -rf /var/lib/dpkg/info/fail2ban.* 2>/dev/null
    fi
    # 再兜底：物理删除可能的二进制残留
    $SUDO rm -f /usr/bin/fail2ban-client /usr/bin/fail2ban-server /usr/local/bin/fail2ban-* 2>/dev/null
    hash -r 2>/dev/null
    read -rp "是否同时删除配置目录 /etc/fail2ban ？(y/N): " del_conf
    [[ "$del_conf" =~ ^[Yy]$ ]] && { $SUDO rm -rf /etc/fail2ban; echo -e "${INFO} 已删除 /etc/fail2ban"; }
    echo -e "${INFO} ${GREEN}Fail2Ban 卸载完成。${RESET}"; read -rp "按回车键继续..."
    return 0
}

change_f2b_param() {
    local name=$1 key=$2 type=$3
    local current; current=$(get_f2b_conf "$key")
    echo -e "\n${INFO} 正在修改: ${CYAN}${name}${RESET}"
    echo -e "当前值: ${GREEN}$(fmt_f2b_unit "$current" "$type")${RESET}"
    [ "$type" == "time" ] && echo -e "${GRAY}(支持后缀: s=秒, m=分, h=小时, d=天)${RESET}"
    while true; do
        read -rp "请输入新值 (留空取消): " new_val
        [ -z "$new_val" ] && return
        if [ "$type" == "time" ] && validate_time "$new_val"; then break; fi
        if [ "$type" == "int" ] && validate_int "$new_val"; then break; fi
        if [ "$type" == "factor" ] && validate_int "$new_val"; then break; fi
        echo -e "${ERROR} 格式错误，请重试。"
    done
    if ! backup_f2b_config; then
        echo -e "${ERROR} 无法备份 Fail2Ban 配置，操作已取消。"
        read -rp "按回车键继续..."
        return 1
    fi
    if ! set_f2b_conf "$key" "$new_val"; then
        echo -e "${ERROR} Fail2Ban 配置未修改。"
        restore_f2b_config
        commit_f2b_config
        read -rp "按回车键继续..."
        return 1
    fi
    if ! restart_f2b; then
        echo -e "${ERROR} Fail2Ban 重启失败，正在恢复原配置。"
        restore_f2b_config
        restart_f2b >/dev/null 2>&1 || true
        commit_f2b_config
        read -rp "按回车键继续..."
        return 1
    fi
    commit_f2b_config
}

toggle_f2b_service() {
    echo -e "\n${CYAN}------------------- 服务开关 -------------------${RESET}"
    if fail2ban-client ping >/dev/null 2>&1; then
        read -rp "是否停止并禁用 Fail2Ban? (y/N): " confirm
        [[ "$confirm" =~ ^[Yy]$ ]] && { svc_stop fail2ban; svc_disable fail2ban; echo -e "${WARN} 服务已停止。${RESET}"; }
    else
        read -rp "是否启用并启动 Fail2Ban? (y/N): " confirm
        if [[ "$confirm" =~ ^[Yy]$ ]]; then
            svc_enable fail2ban; svc_start fail2ban
            for i in {1..5}; do
                if fail2ban-client ping >/dev/null 2>&1; then echo -e "${INFO} ${GREEN}服务已成功启动。${RESET}"; read -rp "按回车键继续..."; return; fi; sleep 1
            done
            echo -e "${ERROR} 启动失败或超时。"
        fi
    fi
    read -rp "按回车键继续..."
}

unban_f2b_ip() {
    echo -e "\n${CYAN}------------------ 手动解封 IP ------------------${RESET}"
    local banned_list
    banned_list=$(fail2ban-client status "$TARGET_JAIL" 2>/dev/null | grep "Banned IP list" | awk -F':' '{print $2}' | sed 's/^[ \t]*//')
    [ -z "$banned_list" ] && banned_list="无"
    echo -e "当前被封禁列表: ${YELLOW}${banned_list}${RESET}"
    read -rp "输入要解封的 IP (留空取消): " target_ip; [ -z "$target_ip" ] && return
    if ! validate_ip_or_cidr "$target_ip"; then
        echo -e "${ERROR} IP 或 CIDR 格式不正确。"
        read -rp "按回车键继续..."
        return 1
    fi
    $SUDO fail2ban-client set "$TARGET_JAIL" unbanip "$target_ip"
    [ $? -eq 0 ] && echo -e "${INFO} ${GREEN}解封成功: $target_ip${RESET}" || echo -e "${ERROR} 操作失败。"
    read -rp "按回车键继续..."
}

validate_ip_or_cidr() {
    local value="$1" address prefix octet
    [[ "$value" != *[!0-9A-Fa-f:./]* ]] || return 1
    address="$value"; prefix=""
    if [[ "$value" == */* ]]; then
        address="${value%%/*}"; prefix="${value##*/}"
        [[ "$prefix" =~ ^[0-9]+$ ]] || return 1
    fi
    if [[ "$address" == *:* ]]; then
        [[ "$address" =~ ^[0-9A-Fa-f:]+$ ]] || return 1
        [[ "$address" != *:::* ]] || return 1
        local left right group_count=0 groups=()
        if [[ "$address" == *::* ]]; then
            left="${address%%::*}"; right="${address#*::}"
            [ -n "$left" ] && IFS=: read -r -a groups <<< "$left" && group_count=$((group_count + ${#groups[@]}))
            groups=()
            [ -n "$right" ] && IFS=: read -r -a groups <<< "$right" && group_count=$((group_count + ${#groups[@]}))
            [ "$group_count" -le 7 ] || return 1
        else
            IFS=: read -r -a groups <<< "$address"
            [ "${#groups[@]}" -eq 8 ] || return 1
        fi
        for octet in "${groups[@]}"; do
            [ "${#octet}" -le 4 ] || return 1
        done
        [ -z "$prefix" ] || [ "$prefix" -le 128 ]
        return
    fi
    IFS=. read -r -a octets <<< "$address"
    [ "${#octets[@]}" -eq 4 ] || return 1
    for octet in "${octets[@]}"; do
        [[ "$octet" =~ ^[0-9]+$ ]] || return 1
        [ "$octet" -le 255 ] || return 1
    done
    [ -z "$prefix" ] || [ "$prefix" -le 32 ]
}

add_f2b_whitelist() {
    echo -e "\n${CYAN}------------------ 白名单管理 ------------------${RESET}"
    local current_list; current_list=$(get_f2b_conf "ignoreip")
    echo -e "当前白名单: ${YELLOW}${current_list:-继承全局或无}${RESET}"
    local current_ip; current_ip=$(echo "${SSH_CLIENT:-}" | awk '{print $1}')
    read -rp "输入要放行的 IP (回车默认当前连接 IP: ${current_ip:-无}): " input_ip
    [ -z "$input_ip" ] && input_ip="$current_ip"
    [ -z "$input_ip" ] && echo -e "${ERROR} 无法获取 IP。" && return
    if ! validate_ip_or_cidr "$input_ip"; then
        echo -e "${ERROR} IP 或 CIDR 格式不正确。"
        read -rp "按回车键继续..."
        return
    fi
    if printf '%s\n' "$current_list" | awk -v ip="$input_ip" '{for (i = 1; i <= NF; i++) if ($i == ip) found=1} END {exit !found}'; then
        echo -e "${WARN} 该 IP 已在白名单中。"
    else
        if ! backup_f2b_config; then
            echo -e "${ERROR} 无法备份 Fail2Ban 配置，操作已取消。"
        elif { [ -z "$current_list" ] && set_f2b_conf "ignoreip" "$input_ip"; } || \
             { [ -n "$current_list" ] && set_f2b_conf "ignoreip" "$current_list $input_ip"; }; then
            if restart_f2b; then
                commit_f2b_config
            else
                echo -e "${ERROR} Fail2Ban 重启失败，正在恢复白名单配置。"
                restore_f2b_config
                restart_f2b >/dev/null 2>&1 || true
                commit_f2b_config
            fi
        else
            echo -e "${ERROR} Fail2Ban 配置未修改。"
            restore_f2b_config
            commit_f2b_config
        fi
    fi
    read -rp "按回车键继续..."
}

view_f2b_logs() {
    clear
    echo -e "${CYAN}============================================================${RESET}"
    echo -e "${BOLD}${PURPLE}                 Fail2Ban 审计日志 (最近 20 条)${RESET}"
    echo -e "${CYAN}============================================================${RESET}"
    local out=""
    if [ "$INIT_SYS" = "systemd" ] && command -v journalctl &>/dev/null; then
        out=$(journalctl -u fail2ban --no-pager -n 200 2>/dev/null | grep -E '(Ban|Unban)' | tail -n 20)
    elif [ -f "$LOG_FILE" ]; then
        out=$(grep -E '(Ban|Unban)' "$LOG_FILE" 2>/dev/null | tail -n 20)
    else
        echo -e "${WARN} 日志文件不存在: $LOG_FILE"
    fi
    if [ -z "$out" ]; then
        echo -e "${WARN} 暂无封禁/解封记录${RESET}"
    else
        printf '%s\n' "$out" | awk '{
            gsub(/Unban/, "\033[32m&\033[0m");
            gsub(/Ban/, "\033[31m&\033[0m");
            print
        }'
    fi
    echo -e "${CYAN}============================================================${RESET}"
    read -rp "按回车键返回..."
}

menu_f2b_exponential() {
    while true; do
        clear
        local inc fac max
        inc=$(get_f2b_conf "bantime.increment")
        fac=$(get_f2b_conf "bantime.factor")
        max=$(get_f2b_conf "bantime.maxtime")
        local S_INC; [ "$inc" == "true" ] && S_INC="${GREEN}启用${RESET}" || S_INC="${YELLOW}禁用${RESET}"
        echo -e "${CYAN}============================================================${RESET}"
        echo -e "${BOLD}${PURPLE}            高级: 指数封禁设置 (针对 sshd)${RESET}"
        echo -e "${CYAN}============================================================${RESET}"
        echo -e " 说明: 对重复犯错的恶意 IP，封禁时间按设定系数成倍递增"
        echo -e "${CYAN}------------------------------------------------------------${RESET}"
        echo -e "  ${GREEN}1.${RESET} 递增模式开关   [${S_INC}]"
        echo -e "  ${GREEN}2.${RESET} 增长系数       [${YELLOW}${fac:-未设置}${RESET}]$(fmt_f2b_unit "$fac" "factor")"
        echo -e "  ${GREEN}3.${RESET} 封禁上限       [${YELLOW}${max:-未设置}${RESET}]$(fmt_f2b_unit "$max" "time")"
        echo -e "${CYAN}------------------------------------------------------------${RESET}"
        echo -e "  ${GREEN}0.${RESET} 返回上级"
        echo -e "${CYAN}============================================================${RESET}"
        echo -e "${GRAY}提示: 输入对应序号后可自定义该参数${RESET}"
        read -rp "请选择 [0-3]: " sc
        case "$sc" in
            1)
                local ns
                [ "$inc" == "true" ] && ns="false" || ns="true"
                if ! backup_f2b_config; then
                    echo -e "${ERROR} 无法备份 Fail2Ban 配置。"
                elif ! set_f2b_conf "bantime.increment" "$ns"; then
                    echo -e "${ERROR} Fail2Ban 配置未修改。"
                    restore_f2b_config
                    commit_f2b_config
                elif restart_f2b; then
                    commit_f2b_config
                else
                    echo -e "${ERROR} Fail2Ban 重启失败，正在恢复原配置。"
                    restore_f2b_config
                    restart_f2b >/dev/null 2>&1 || true
                    commit_f2b_config
                fi
                ;;
            2) change_f2b_param "增长系数 (倍数)" "bantime.factor" "factor" ;;
            3) change_f2b_param "封禁上限 (时间)" "bantime.maxtime" "time" ;;
            0) return ;;
            *) echo -e "${ERROR} 无效选项！"; sleep 1 ;;
        esac
    done
}

manage_fail2ban_menu() {
    if ! check_f2b_install; then read -rp "按回车键返回主菜单..."; return; fi
    while true; do
        clear
        VAL_MAX=$(get_f2b_conf "maxretry"); VAL_BAN=$(get_f2b_conf "bantime"); VAL_FIND=$(get_f2b_conf "findtime")
        echo -e "${CYAN}============================================================${RESET}"
        echo -e "${BOLD}${PURPLE}                     Fail2Ban 防护管理${RESET}"
        echo -e "${CYAN}============================================================${RESET}"
        echo -e "  服务状态: $(get_fail2ban_status)"
        echo -e "${CYAN}------------------------------------------------------------${RESET}"
        echo -e "  ${GREEN}1.${RESET} 最大重试次数     [${YELLOW}${VAL_MAX:-默认}${RESET}]"
        echo -e "  ${GREEN}2.${RESET} 初始封禁时长     [${YELLOW}${VAL_BAN:-默认}${RESET}]$(fmt_f2b_unit "$VAL_BAN" "time")"
        echo -e "  ${GREEN}3.${RESET} 监测时间窗口     [${YELLOW}${VAL_FIND:-默认}${RESET}]$(fmt_f2b_unit "$VAL_FIND" "time")"
        echo -e "${CYAN}------------------------------------------------------------${RESET}"
        echo -e "  ${GREEN}4.${RESET} 手动解封 IP"
        echo -e "  ${GREEN}5.${RESET} 添加 IP 白名单"
        echo -e "  ${GREEN}6.${RESET} 查看封禁日志 (最近20条)"
        echo -e "  ${GREEN}7.${RESET} 指数递增封禁设置 ->"
        echo -e "${CYAN}------------------------------------------------------------${RESET}"
        echo -e "  ${GREEN}8.${RESET} 启用 / 停止 服务"
        echo -e "  ${GREEN}9.${RESET} 卸载 Fail2Ban"
        echo -e "  ${GREEN}0.${RESET} 返回主菜单"
        echo -e "${CYAN}============================================================${RESET}"
        read -rp "请选择 [0-9]: " choice
        case "$choice" in
            1) change_f2b_param "最大重试次数" "maxretry" "int" ;;
            2) change_f2b_param "初始封禁时长" "bantime" "time" ;;
            3) change_f2b_param "监测时间窗口" "findtime" "time" ;;
            4) unban_f2b_ip ;;
            5) add_f2b_whitelist ;;
            6) view_f2b_logs ;;
            7) menu_f2b_exponential ;;
            8) toggle_f2b_service ;;
            9) # 卸载后根据返回值决定是否返回主菜单：
               #   uninstall_f2b 返回 0 = 卸载完成 → 返回主菜单
               #   uninstall_f2b 返回 1 = 用户取消 → 留在本菜单
               if uninstall_f2b; then
                   return
               fi
               ;;
            0) return ;;
            *) echo -e "${ERROR} 无效选项！"; sleep 1 ;;
        esac
    done
}

# ============ 状态面板 ============
show_status() {
    local port; port=$(get_sshd_config_val "Port" "22")
    local pwd_auth; pwd_auth=$(get_sshd_config_val "PasswordAuthentication" "yes")
    local pubkey_auth; pubkey_auth=$(get_sshd_config_val "PubkeyAuthentication" "yes")
    local f2b_stat; f2b_stat=$(get_fail2ban_status)
    local key_count; key_count=$(count_authorized_keys)

    echo -e "${CYAN}============================================================${RESET}"
    echo -e "${BOLD}${PURPLE}                     SSH 安全配置工具${RESET}"
    echo -e "${CYAN}============================================================${RESET}"
    echo -e " 系统架构 : ${GREEN}${OS_SHORT} ${OS_VER}${RESET}"
    if [[ "${pubkey_auth,,}" == "yes" ]]; then
        if [ "$key_count" -gt 0 ]; then
            echo -e " 密钥登录 : ${GREEN}已启用 (${key_count} 把公钥)${RESET}"
        else
            echo -e " 密钥登录 : ${YELLOW}已启用 (但无公钥，无法密钥登录)${RESET}"
        fi
    else
        echo -e " 密钥登录 : ${YELLOW}已禁用${RESET}"
    fi
    if [[ "${pwd_auth,,}" == "no" ]]; then
        echo -e " 密码登录 : ${GREEN}已禁用 (PasswordAuthentication no)${RESET}"
    else
        echo -e " 密码登录 : ${YELLOW}已启用 (推荐配置密钥后禁用)${RESET}"
    fi
    echo -e " Fail2Ban : ${f2b_stat}"
    echo -e " SSH 端口 : ${CYAN}${port}${RESET}"
    echo -e "${CYAN}============================================================${RESET}"
}

# ============ 密钥生成 ============
generate_vps_keypair() {
    echo -e "\n${INFO} 准备在 VPS 上生成新的 ED25519 密钥..."
    local key_file="${HOME}/.ssh/PrivateKey.pem"
    local pub_file="${HOME}/.ssh/PublicKey.pub"
    local work_dir backup_dir=""

    if [ -f "$key_file" ] || [ -f "$pub_file" ] || [ -f "${key_file}.pub" ]; then
        echo -e "${WARN} 检测到已有同名密钥。覆盖前请确认旧私钥已备份。"
        read -rp "确认覆盖现有 VPS 密钥文件吗？(y/N): " overwrite_confirm
        [[ "$overwrite_confirm" =~ ^[Yy]$ ]] || return 1
    fi
    init_ssh_dir || { echo -e "${ERROR} 无法初始化 SSH 目录。"; return 1; }
    work_dir=$(mktemp -d "${HOME}/.ssh/.vps-key.XXXXXX") || { echo -e "${ERROR} 无法创建临时密钥目录。"; return 1; }
    chmod 700 "$work_dir"

    # 先在临时目录生成，成功后再替换旧文件，避免生成失败导致旧私钥丢失。
    if ! ssh-keygen -t ed25519 -C "" -f "$work_dir/PrivateKey.pem" -N "" -q; then
        rm -rf "$work_dir"
        echo -e "${ERROR} 密钥生成失败，旧密钥未被修改。"
        read -rp "按回车键返回..."
        return 1
    fi
    if [ ! -f "$work_dir/PrivateKey.pem.pub" ]; then
        rm -rf "$work_dir"
        echo -e "${ERROR} 密钥生成失败，旧密钥未被修改。"
        read -rp "按回车键返回..."
        return 1
    fi

    if [ -f "$key_file" ] || [ -f "$pub_file" ]; then
        backup_dir=$(mktemp -d "${HOME}/.ssh/.vps-key-backup.XXXXXX") || { rm -rf "$work_dir"; return 1; }
        if [ -f "$key_file" ] && ! cp -a "$key_file" "$backup_dir/PrivateKey.pem"; then
            rm -rf "$work_dir" "$backup_dir"
            echo -e "${ERROR} 无法备份旧私钥，操作已取消。"
            return 1
        fi
        if [ -f "$pub_file" ] && ! cp -a "$pub_file" "$backup_dir/PublicKey.pub"; then
            rm -rf "$work_dir" "$backup_dir"
            echo -e "${ERROR} 无法备份旧公钥，操作已取消。"
            return 1
        fi
    fi
    if ! mv "$work_dir/PrivateKey.pem" "$key_file" || ! mv "$work_dir/PrivateKey.pem.pub" "$pub_file"; then
        rm -f "$key_file" "$pub_file"
        [ -f "$backup_dir/PrivateKey.pem" ] && mv "$backup_dir/PrivateKey.pem" "$key_file"
        [ -f "$backup_dir/PublicKey.pub" ] && mv "$backup_dir/PublicKey.pub" "$pub_file"
        rm -rf "$work_dir" "$backup_dir"
        echo -e "${ERROR} 替换密钥文件失败，已尝试恢复旧密钥。"
        return 1
    fi
    rm -rf "$work_dir"
    if ! chmod 600 "$key_file" || ! chmod 644 "$pub_file"; then
        rm -f "$key_file" "$pub_file"
        [ -f "$backup_dir/PrivateKey.pem" ] && mv "$backup_dir/PrivateKey.pem" "$key_file"
        [ -f "$backup_dir/PublicKey.pub" ] && mv "$backup_dir/PublicKey.pub" "$pub_file"
        rm -rf "$backup_dir"
        echo -e "${ERROR} 新密钥权限设置失败，已尝试恢复旧密钥。"
        return 1
    fi

    local pub_content
    pub_content=$(cat "$pub_file")

    if ! append_key_with_meta "$pub_content" "VPS本地生成"; then
        rm -f "$key_file" "$pub_file"
        [ -f "$backup_dir/PrivateKey.pem" ] && mv "$backup_dir/PrivateKey.pem" "$key_file"
        [ -f "$backup_dir/PublicKey.pub" ] && mv "$backup_dir/PublicKey.pub" "$pub_file"
        rm -rf "$backup_dir"
        echo -e "${ERROR} 新公钥写入 authorized_keys 失败，已尝试恢复旧密钥。"
        return 1
    fi
    rm -rf "$backup_dir"

    echo -e "\n${GREEN}====================== 密钥生成成功 ======================${RESET}"
    echo -e " VPS 上的私钥路径 : ${CYAN}${key_file}${RESET}"
    echo -e " VPS 上的公钥路径 : ${CYAN}${pub_file}${RESET}"
    echo -e " 授权目标文件     : 已将公钥写入 ${CYAN}${HOME}/.ssh/authorized_keys${RESET}"
    echo -e "${CYAN}------------------------------------------------------------${RESET}"
    echo -e "${YELLOW}${BOLD}私钥不会显示在终端中，避免被终端记录或旁观者获取。${RESET}"
    echo -e "请使用受信任的 SFTP 客户端，从 ${CYAN}${HOME}/.ssh/PrivateKey.pem${RESET} 安全下载私钥。"
    echo -e "${CYAN}------------------------------------------------------------${RESET}"
    echo -e "${GREEN}${BOLD}[公钥文本 (PublicKey.pub)] - 用于上传至 GitHub：${RESET}"
    echo -e "${GREEN}${pub_content}${RESET}"
    echo -e "${CYAN}------------------------------------------------------------${RESET}"

    echo -e "${BOLD}${PURPLE}[💡 新手一劳永逸指南]${RESET}"
    echo -e " ${BOLD}一、保存私钥到本地电脑：${RESET}"
    echo -e "   使用 SSH 客户端的 ${CYAN}SFTP / 文件传输${RESET} 功能，将 ${CYAN}${key_file}${RESET} 安全下载到本地，并妥善保管。"
    echo -e "   不要通过聊天、邮件或不受信任的终端记录传输私钥。"
    echo -e "   ${GREEN}公钥内容如下，可上传至 GitHub：${RESET}"
    echo -e "   1. 打开 ${CYAN}https://github.com/settings/keys${RESET} ，点击 \"New SSH key\"；"
    echo -e "   2. 将 ${CYAN}PublicKey.pub${RESET} 里的公钥粘贴并保存。"
    echo -e "   3. ${GREEN}其他 VPS 可选择【选项 1】输入 GitHub 用户名获取此公钥。${RESET}\n"

    read -rp "确认已保存/下载密钥，是否立即删除 VPS 上的暂存密钥文件？(Y/n): " rm_confirm
    if [[ -z "$rm_confirm" || "$rm_confirm" =~ ^[Yy]$ ]]; then
        rm -f "$key_file" "$pub_file"
        echo -e "${INFO} ${GREEN}已成功删除 VPS 上的暂存密钥文件。${RESET}"
    else
        echo -e "${WARN} 密钥文件仍保留在: ${key_file} 和 ${pub_file} (请务必防范私钥泄露)"
    fi
}

# ============ 密钥登录开关 ============
toggle_pubkey_login() {
    local current
    current=$(get_sshd_config_val "PubkeyAuthentication" "yes")

    if [[ "${current,,}" == "no" ]]; then
        echo -e "\n当前密钥登录已${GREEN}禁用${RESET}。"
        local key_count; key_count=$(count_authorized_keys)
        if [ "$key_count" -eq 0 ]; then
            echo -e "${YELLOW}[提示] 当前 authorized_keys 中还没有公钥，启用后仍需先添加公钥才能通过密钥登录。${RESET}"
        fi
        read -rp "是否要启用密钥登录？(y/N): " confirm
        if [[ "$confirm" =~ ^[Yy]$ ]]; then
            if ! backup_ssh_config; then
                echo -e "${ERROR} 无法备份 SSH 配置，操作已取消。"
            elif ! set_sshd_config "PubkeyAuthentication" "yes" || ! restart_sshd; then
                echo -e "${ERROR} SSH 重启失败，正在恢复原配置。"
                rollback_ssh_config
            else
                commit_ssh_config
                echo -e "${INFO} ${GREEN}密钥登录已成功启用。${RESET}"
            fi
        fi
    else
        echo -e "\n${YELLOW}${BOLD}[警告] 禁用密钥登录后，如果密码登录也已禁用，你将无法登录 VPS！${RESET}"
        if [ -n "${SSH_CLIENT:-}" ] || [ -n "${SSH_TTY:-}" ]; then
            echo -e "${CYAN}${BOLD}[提示] 检测到您正在使用 SSH 远程会话，修改后切勿关闭当前窗口！${RESET}"
        fi

        local pwd_auth
        pwd_auth=$(get_sshd_config_val "PasswordAuthentication" "yes")
        if [[ "${pwd_auth,,}" == "no" ]]; then
            echo -e "${RED} 检测到密码登录已禁用，禁用密钥登录后你将无法登录此 VPS！${RESET}"
            read -rp "确认仍然要禁用密钥登录吗？(y/N): " confirm_risky
            [[ ! "$confirm_risky" =~ ^[Yy]$ ]] && { echo -e "${INFO} 已取消操作。"; read -rp "按回车键继续..."; return; }
        else
            read -rp "确认禁用密钥登录吗？(y/N): " confirm
            [[ ! "$confirm" =~ ^[Yy]$ ]] && { echo -e "${INFO} 已取消操作。"; read -rp "按回车键继续..."; return; }
        fi

        if ! backup_ssh_config; then
            echo -e "${ERROR} 无法备份 SSH 配置，操作已取消。"
        elif ! set_sshd_config "PubkeyAuthentication" "no" || ! restart_sshd; then
            echo -e "${ERROR} SSH 重启失败，正在恢复原配置。"
            rollback_ssh_config
        else
            commit_ssh_config
            echo -e "${INFO} ${GREEN}密钥登录已禁用，现在只能通过密码登录。${RESET}"
        fi
    fi
    read -rp "按回车键继续..."
}

validate_https_url() {
    local url="$1" authority port
    [[ "$url" =~ ^https://[A-Za-z0-9.-]+(:[0-9]+)?([/?#][^[:space:]]*)?$ ]] || return 1
    authority="${url#https://}"
    authority="${authority%%[/?#]*}"
    if [[ "$authority" == *:* ]]; then
        port="${authority##*:}"
        [[ "$port" =~ ^[0-9]+$ ]] && [ "$port" -ge 1 ] && [ "$port" -le 65535 ] || return 1
    fi
    return 0
}

install_key_menu() {
    while true; do
        clear
        init_ssh_dir

        # 动态统计当前公钥数量
        local key_count
        key_count=$(count_authorized_keys)
        local key_count_label
        if [ "$key_count" -gt 0 ]; then
            key_count_label=" (${GREEN}${key_count} 把公钥${RESET})"
        else
            key_count_label=" (${YELLOW}无公钥${RESET})"
        fi

        # 动态显示当前密钥登录开关状态，避免新人困惑
        local pubkey_status
        pubkey_status=$(get_sshd_config_val "PubkeyAuthentication" "yes")
        local pubkey_label
        if [[ "${pubkey_status,,}" == "yes" ]]; then
            pubkey_label="[${GREEN}已启用${RESET}]"
        else
            pubkey_label="[${YELLOW}已禁用${RESET}]"
        fi

        echo -e "${CYAN}============================================================${RESET}"
        echo -e "${BOLD}${PURPLE}                     SSH 密钥登录管理${RESET}"
        echo -e "${CYAN}============================================================${RESET}"
        echo -e "${BOLD}请选择 SSH 密钥配置方式：${RESET}"
        echo -e "  ${GREEN}1.${RESET} 从 GitHub 获取公钥 (${CYAN}适合：已将公钥上传至 GitHub 的用户${RESET})"
        echo -e "  ${GREEN}2.${RESET} 在 VPS 上全新生成密钥 (${CYAN}适合：本地没有密钥的新手，生成后可传 GitHub${RESET})"
        echo -e "  ${GREEN}3.${RESET} 从自定义 URL 获取公钥 (${CYAN}适合：有公钥直链的用户${RESET})"
        echo -e "  ${GREEN}4.${RESET} 管理已存公钥${key_count_label}"
        echo -e "  ${GREEN}5.${RESET} 密钥登录开关 ${pubkey_label}"
        echo -e "  ${GREEN}0.${RESET} 返回主菜单"
        echo -e "${CYAN}============================================================${RESET}"
        read -rp "请输入选项 [0-5]: " key_opt

        local test_hint=""
        local do_restart=0

        case "$key_opt" in
            1)
                echo -e "\n${YELLOW}${BOLD}[使用前提]${RESET}"
                echo -e "需先将本地公钥上传至 GitHub: ${CYAN}https://github.com/settings/keys${RESET}\n"
                read -rp "请输入您的 GitHub 用户名: " gh_user
                if [[ ! "$gh_user" =~ ^[A-Za-z0-9]([A-Za-z0-9-]{0,37}[A-Za-z0-9])?$ ]]; then
                    echo -e "${ERROR} GitHub 用户名格式不正确。"
                    read -rp "按回车键继续..."
                    continue
                fi
                if ! backup_authorized_keys; then
                    echo -e "${ERROR} 无法备份 authorized_keys，操作已取消。"
                    read -rp "按回车键继续..."
                    continue
                fi
                echo -e "${INFO} 正在从 GitHub 拉取公钥..."
                local pub_key
                pub_key=$(curl --fail --silent --show-error --location \
                    --connect-timeout 5 --max-time 20 --max-filesize 1048576 \
                    --proto '=https' --tlsv1.2 \
                    "https://github.com/${gh_user}.keys")
                if [ -z "$pub_key" ] || [[ "$pub_key" == "Not Found" ]]; then
                    echo -e "\n${ERROR} 获取公钥失败！可能是用户名不正确，或该 GitHub 账号未配置公钥。"
                    echo -e "${CYAN}------------------------------------------------------------${RESET}"
                    read -rp "是否要在 VPS 上全新生成密钥 (选项 2)？(y/N): " switch_opt2
                    if [[ "$switch_opt2" =~ ^[Yy]$ ]]; then
                    if generate_vps_keypair; then
                        test_hint="请将已保存的私钥导入本地 SSH 客户端，新建终端测试连接。"
                        do_restart=1
                    else
                        echo -e "${ERROR} 密钥生成失败，操作已取消。"
                        restore_authorized_keys
                        continue
                    fi
                    else
                        restore_authorized_keys
                        read -rp "按回车键继续..."
                        continue
                    fi
                else
                    if append_key_with_meta "$pub_key" "GitHub: ${gh_user}"; then
                        test_hint="请使用该 GitHub 公钥对应的本地私钥，新建终端测试连接。"
                        do_restart=1
                    else
                        restore_authorized_keys
                        read -rp "按回车键继续..."
                        continue
                    fi
                fi
                ;;
            2)
                if ! backup_authorized_keys; then
                    echo -e "${ERROR} 无法备份 authorized_keys，操作已取消。"
                    read -rp "按回车键继续..."
                    continue
                fi
                if ! generate_vps_keypair; then
                    restore_authorized_keys
                    continue
                fi
                test_hint="请将已保存的私钥导入本地 SSH 客户端，新建终端测试连接。"
                do_restart=1
                ;;
            3)
                read -rp "请输入公钥 URL: " key_url
                if [ -z "$key_url" ]; then
                    echo -e "${ERROR} URL 不能为空！"
                    read -rp "按回车键继续..."
                    continue
                fi
                if ! validate_https_url "$key_url"; then
                    echo -e "${ERROR} URL 格式不正确：必须是 HTTPS 主机地址，可带端口和路径。"
                    read -rp "按回车键继续..."
                    continue
                fi
                local pub_key
                pub_key=$(curl --fail --silent --show-error --location \
                    --connect-timeout 5 --max-time 20 --max-filesize 1048576 \
                    --proto '=https' --tlsv1.2 \
                    "$key_url")
                if [ -z "$pub_key" ]; then
                    echo -e "${ERROR} 从 URL 获取公钥失败！"
                    read -rp "按回车键继续..."
                    continue
                fi
                if ! backup_authorized_keys; then
                    echo -e "${ERROR} 无法备份 authorized_keys，操作已取消。"
                    read -rp "按回车键继续..."
                    continue
                fi
                if append_key_with_meta "$pub_key" "自定义URL"; then
                    test_hint="请使用该公钥对应的本地私钥，新建终端测试连接。"
                    do_restart=1
                else
                    restore_authorized_keys
                    read -rp "按回车键继续..."
                    continue
                fi
                ;;
            4)
                manage_keys_menu
                continue
                ;;
            5)
                toggle_pubkey_login
                continue
                ;;
            0) return ;;
            *)
                echo -e "${ERROR} 无效选项！"
                sleep 1
                continue
                ;;
        esac

        if [ "$do_restart" == "1" ]; then
            if ! backup_ssh_config; then
                echo -e "${ERROR} 无法备份 SSH 配置，正在恢复 authorized_keys。"
                restore_authorized_keys
            elif ! set_sshd_config "PubkeyAuthentication" "yes" || ! restart_sshd; then
                echo -e "${ERROR} SSH 重启失败，正在恢复原 SSH 配置和 authorized_keys。"
                rollback_ssh_config
                restore_authorized_keys
            else
                commit_ssh_config
                commit_authorized_keys
                echo -e "\n${CYAN}------------------------------------------------------------${RESET}"
                echo -e "${YELLOW}${BOLD}[重点测试]${RESET} ${test_hint}"
                echo -e "测试成功后，再返回主菜单【禁用密码登录】！"
                echo -e "${CYAN}------------------------------------------------------------${RESET}"
            fi
            read -rp "按回车键返回密钥管理子菜单..."
        fi
    done
}

# ============ 已存公钥管理 ============
manage_keys_menu() {
    init_ssh_dir
    local auth_file="${HOME}/.ssh/authorized_keys"

    while true; do
        clear
        echo -e "${CYAN}============================================================${RESET}"
        echo -e "${BOLD}${PURPLE}                     SSH 已存公钥管理${RESET}"
        echo -e "${CYAN}============================================================${RESET}"

        local key_lines=()
        local key_contents=()
        local line_num=0 core_key

        if [ -f "$auth_file" ]; then
            while IFS= read -r line || [ -n "$line" ]; do
                ((line_num++))
                if [[ -z "$line" || "$line" =~ ^[[:space:]]*# ]]; then
                    continue
                fi
                core_key=$(printf '%s\n' "$line" | extract_core_key)
                is_valid_core_key "$core_key" || continue
                key_lines+=("$line_num")
                key_contents+=("$line")
            done < "$auth_file"
        fi

        if [ ${#key_contents[@]} -eq 0 ]; then
            echo -e "\n${WARN} 当前 ${auth_file} 中没有找到任何有效公钥！"
            echo -e "${CYAN}============================================================${RESET}"
            read -rp "按回车键返回..."
            return
        fi

        printf " %-4s | %-19s | %-8s | %-16s\n" "序号" "      添加时间" "公钥类型" "    备注来源"
        echo -e "${CYAN}------------------------------------------------------------${RESET}"

        local idx=1
        for key in "${key_contents[@]}"; do
            local add_time="历史存量/未标记"
            local key_tag="未知/手动导入"

            if [[ "$key" =~ \[([0-9]{4}-[0-9]{2}-[0-9]{2}\ [0-9]{2}:[0-9]{2}:[0-9]{2})\|([^\]]+)\] ]]; then
                add_time="${BASH_REMATCH[1]}"
                key_tag="${BASH_REMATCH[2]}"
            fi

            # 修正：带选项前缀的公钥也能正确显示密钥类型
            local key_type
            key_type=$(echo "$key" | awk '{
                for(i=1;i<=NF;i++){
                    if($i ~ /^(ssh-|ecdsa-|sk-)/){ print $i; exit }
                }
                print "未知"
            }')

            printf " ${GREEN}[%2d]${RESET} | ${YELLOW}%19s${RESET} | ${CYAN}%-8s${RESET} | ${PURPLE}%-16s${RESET}\n" "$idx" "$add_time" "$key_type" "$key_tag"
            ((idx++))
        done

        echo -e "${CYAN}============================================================${RESET}"
        echo -e " 输入 ${RED}[序号]${RESET} : 删除指定公钥"
        echo -e " 输入 ${RED}[all]${RESET}  : 清空全部公钥"
        echo -e " 输入 ${GREEN}[0]${RESET}    : 返回上级菜单"
        echo -e "${CYAN}============================================================${RESET}"
        read -rp "请输入操作指令: " key_action

        if [ "$key_action" == "0" ]; then
            return
        elif [ "$key_action" == "all" ]; then
            # 危险检查：密码登录已禁用时清空全部公钥会锁死
            if [[ "$(get_sshd_config_val "PasswordAuthentication" "yes")" == "no" ]]; then
                echo -e "${RED}${BOLD}[危险] 密码登录已禁用，清空全部公钥后你将无法登录此 VPS！${RESET}"
                read -rp "确认仍然要清空吗？(y/N): " risky_all
                [[ ! "$risky_all" =~ ^[Yy]$ ]] && continue
            fi
            read -rp "确认要清空所有公钥吗？(y/N): " confirm_all
            if [[ "$confirm_all" =~ ^[Yy]$ ]]; then
                if ! backup_authorized_keys || ! : > "$auth_file"; then
                    restore_authorized_keys
                    echo -e "${ERROR} 清空公钥失败，已尝试恢复原文件。"
                else
                    commit_authorized_keys
                    chmod 600 "$auth_file"
                    echo -e "${INFO} 已清空所有公钥！"
                fi
                sleep 1
                continue
            fi
        elif [[ "$key_action" =~ ^[0-9]+$ ]] && [ "$key_action" -ge 1 ] && [ "$key_action" -le "${#key_contents[@]}" ]; then
            local target_idx=$((key_action - 1))
            local target_line_num="${key_lines[$target_idx]}"

            # 危险检查：密码登录已禁用 + 只剩最后一个公钥时删除会锁死
            if [[ "$(get_sshd_config_val "PasswordAuthentication" "yes")" == "no" ]] && [ "${#key_contents[@]}" -eq 1 ]; then
                echo -e "${RED}${BOLD}[危险] 密码登录已禁用，删除最后一个公钥后你将无法登录此 VPS！${RESET}"
                read -rp "确认仍然要删除吗？(y/N): " risky_del
                [[ ! "$risky_del" =~ ^[Yy]$ ]] && continue
            fi

            read -rp "确认删除序号 [${key_action}] 的公钥吗？(y/N): " confirm_del
            if [[ "$confirm_del" =~ ^[Yy]$ ]]; then
                if ! backup_authorized_keys || ! sed -i "${target_line_num}d" "$auth_file"; then
                    restore_authorized_keys
                    echo -e "${ERROR} 删除公钥失败，已尝试恢复原文件。"
                else
                    commit_authorized_keys
                    chmod 600 "$auth_file"
                    echo -e "${INFO} ${GREEN}序号 [${key_action}] 的公钥已成功删除！${RESET}"
                fi
                sleep 1
                continue
            fi
        else
            echo -e "${ERROR} 输入无效，请重新输入！"
            sleep 1
            continue
        fi
    done
}

# ============ 密码登录开关 ============
toggle_password_login() {
    local current
    current=$(get_sshd_config_val "PasswordAuthentication" "yes")

    if [[ "${current,,}" == "no" ]]; then
        echo -e "\n当前密码登录已${GREEN}禁用${RESET}。"
        read -rp "是否要启用密码登录？(y/N): " confirm
        if [[ "$confirm" =~ ^[Yy]$ ]]; then
            if ! backup_ssh_config; then
                echo -e "${ERROR} 无法备份 SSH 配置，操作已取消。"
            elif ! set_sshd_config "PasswordAuthentication" "yes" || ! restart_sshd; then
                echo -e "${ERROR} SSH 重启失败，正在恢复原配置。"
                rollback_ssh_config
            else
                commit_ssh_config
                echo -e "${INFO} 已成功启用密码登录。"

                read -rp "是否需要为当前用户 ($(whoami)) 设置新密码？(y/N): " pwd_confirm
                if [[ "$pwd_confirm" =~ ^[Yy]$ ]]; then
                    passwd "$(whoami)"
                fi
            fi
        fi
    else
        echo -e "\n${YELLOW}${BOLD}[警告] 禁用密码登录前，请务必确认密钥登录能够成功！${RESET}"
        # 危险检查：密钥登录不可用时禁用密码登录会锁死
        local pubkey_auth; pubkey_auth=$(get_sshd_config_val "PubkeyAuthentication" "yes")
        local pubkey_ok=0
        if [[ "${pubkey_auth,,}" == "yes" ]] && has_valid_pubkey; then
            pubkey_ok=1
        fi
        if [ "$pubkey_ok" -eq 0 ]; then
            if [[ "${pubkey_auth,,}" != "yes" ]]; then
                echo -e "${RED}${BOLD}[危险] 密钥登录已禁用，禁用密码登录后你将无法登录此 VPS！${RESET}"
            else
                echo -e "${RED}${BOLD}[危险] authorized_keys 中没有任何公钥，禁用密码登录后你将无法登录此 VPS！${RESET}"
            fi
            read -rp "确认仍然要禁用吗？(y/N): " risky_confirm
            [[ ! "$risky_confirm" =~ ^[Yy]$ ]] && { echo -e "${INFO} 已取消操作。"; read -rp "按回车键继续..."; return; }
        fi
        if [ -n "${SSH_CLIENT:-}" ] || [ -n "${SSH_TTY:-}" ]; then
            echo -e "${CYAN}${BOLD}[提示] 检测到您正在使用 SSH 远程会话，修改后切勿关闭当前窗口，请先新建终端测试连接！${RESET}"
        fi
        read -rp "确认彻底禁用密码登录吗？(y/N): " confirm
        if [[ "$confirm" =~ ^[Yy]$ ]]; then
            if ! backup_ssh_config; then
                echo -e "${ERROR} 无法备份 SSH 配置，操作已取消。"
            elif ! set_sshd_config "PasswordAuthentication" "no" || \
                 ! set_sshd_config "ChallengeResponseAuthentication" "no" || \
                 ! set_sshd_config "KbdInteractiveAuthentication" "no" || \
                 ! restart_sshd; then
                echo -e "${ERROR} SSH 重启失败，正在恢复原配置。"
                rollback_ssh_config
            else
                commit_ssh_config
                echo -e "${INFO} ${GREEN}密码登录已成功禁用！现在只能通过密钥登录。${RESET}"
            fi
        fi
    fi
    read -rp "按回车键返回主菜单..."
}

selinux_prepare_ssh_port() {
    local new_port="$1" allowed_ports
    SELINUX_SSH_PORT=""
    SELINUX_SSH_PORT_ADDED=0
    if ! command -v getenforce &>/dev/null || [ "$(getenforce 2>/dev/null)" != "Enforcing" ]; then
        return 0
    fi
    if ! command -v semanage &>/dev/null; then
        echo -e "${ERROR} SELinux 处于 Enforcing 状态，但未找到 semanage，无法安全放行 SSH 端口。"
        return 1
    fi
    allowed_ports=$(semanage port -l 2>/dev/null | awk '$1 == "ssh_port_t" && $2 == "tcp" {print $3}' | tr ',' ' ')
    if printf '%s\n' "$allowed_ports" | grep -Eq "(^|[[:space:]])${new_port}([[:space:]]|$)"; then
        return 0
    fi
    if ! semanage port -a -t ssh_port_t -p tcp "$new_port" >/dev/null 2>&1; then
        echo -e "${ERROR} SELinux 无法将 ${new_port}/tcp 标记为 ssh_port_t。"
        return 1
    fi
    SELINUX_SSH_PORT="$new_port"
    SELINUX_SSH_PORT_ADDED=1
}

selinux_commit_ssh_port() {
    SELINUX_SSH_PORT=""
    SELINUX_SSH_PORT_ADDED=0
}

selinux_rollback_ssh_port() {
    if [ "${SELINUX_SSH_PORT_ADDED:-0}" -eq 1 ] && command -v semanage &>/dev/null; then
        semanage port -d -t ssh_port_t -p tcp "$SELINUX_SSH_PORT" >/dev/null 2>&1 || true
    fi
    SELINUX_SSH_PORT=""
    SELINUX_SSH_PORT_ADDED=0
}

ssh_port_listening() {
    local port="$1"
    if command -v ss &>/dev/null; then
        ss -ltnH 2>/dev/null | awk '{print $4}' | grep -Eq "(^|:)${port}$"
    elif command -v netstat &>/dev/null; then
        netstat -ltn 2>/dev/null | awk 'NR > 2 {print $4}' | grep -Eq "(^|:)${port}$"
    else
        local port_hex
        printf -v port_hex '%04X' "$port"
        awk -v p=":${port_hex}" '$2 ~ p "$" && $4 == "0A" {found=1} END {exit !found}' /proc/net/tcp /proc/net/tcp6 2>/dev/null
    fi
}

rollback_ssh_port_change() {
    local new_port="$1" firewall_backend="$2"
    rollback_ssh_config
    if [ "$firewall_backend" = "ufw" ]; then
        ufw delete allow "$new_port"/tcp >/dev/null 2>&1 || true
    elif [ "$firewall_backend" = "firewalld" ]; then
        firewall-cmd --permanent --remove-port="${new_port}/tcp" >/dev/null 2>&1 || true
        firewall-cmd --reload >/dev/null 2>&1 || true
    fi
    selinux_rollback_ssh_port
}

# ============ 修改 SSH 端口 ============
change_ssh_port() {
    local current_port firewall_backend=""
    current_port=$(get_sshd_config_val "Port" "22")
    echo -e "\n当前 SSH 端口为: ${CYAN}${current_port}${RESET}"
    if [ -n "${SSH_CLIENT:-}" ] || [ -n "${SSH_TTY:-}" ]; then
        echo -e "${YELLOW}${BOLD}[提示] 检测到您正在使用 SSH 远程会话，修改端口后请勿关闭当前窗口，请先新建终端验证！${RESET}"
    fi
    read -rp "请输入新的 SSH 端口 (1024-65535): " new_port

    if [[ ! "$new_port" =~ ^[0-9]+$ ]] || [ "$new_port" -lt 1024 ] || [ "$new_port" -gt 65535 ]; then
        echo -e "${ERROR} 端口格式不正确，必须为 1024-65535。"
        read -rp "按回车键返回主菜单..."
        return
    fi
    if [ "$new_port" = "$current_port" ]; then
        echo -e "${INFO} 新端口与当前端口相同，无需修改。"
        read -rp "按回车键返回主菜单..."
        return
    fi
    if ! backup_ssh_config; then
        echo -e "${ERROR} 无法备份 SSH 配置，操作已取消。"
        read -rp "按回车键返回主菜单..."
        return 1
    fi

    if ! selinux_prepare_ssh_port "$new_port"; then
        rollback_ssh_config
        read -rp "按回车键返回主菜单..."
        return 1
    fi

    if command -v ufw &>/dev/null && ufw status | grep -q "active"; then
        echo -e "${INFO} 正在向 ufw 防火墙放行端口 ${new_port}/tcp..."
        if ufw allow "$new_port"/tcp >/dev/null; then
            firewall_backend="ufw"
        else
            echo -e "${ERROR} ufw 放行端口失败，已取消 SSH 端口切换。"
            rollback_ssh_port_change "$new_port" "$firewall_backend"
            read -rp "按回车键返回主菜单..."
            return 1
        fi
    elif command -v firewall-cmd &>/dev/null && systemctl is-active --quiet firewalld; then
        echo -e "${INFO} 正在向 firewalld 防火墙放行端口 ${new_port}/tcp..."
        if firewall-cmd --permanent --add-port="${new_port}/tcp" >/dev/null; then
            firewall_backend="firewalld"
            if ! firewall-cmd --reload >/dev/null; then
                echo -e "${ERROR} firewalld 重载失败，已取消 SSH 端口切换。"
                rollback_ssh_port_change "$new_port" "$firewall_backend"
                read -rp "按回车键返回主菜单..."
                return 1
            fi
        else
            echo -e "${ERROR} firewalld 放行端口失败，已取消 SSH 端口切换。"
            rollback_ssh_port_change "$new_port" "$firewall_backend"
            read -rp "按回车键返回主菜单..."
            return 1
        fi
    fi

    if ! set_sshd_config "Port" "$new_port" || ! restart_sshd; then
        echo -e "${ERROR} SSH 端口修改失败，正在恢复原配置。"
        rollback_ssh_port_change "$new_port" "$firewall_backend"
        read -rp "按回车键返回主菜单..."
        return 1
    fi
    sleep 1
    if ! ssh_port_listening "$new_port"; then
        echo -e "${ERROR} SSH 服务未监听新端口 ${new_port}，正在恢复原配置。"
        rollback_ssh_port_change "$new_port" "$firewall_backend"
        read -rp "按回车键返回主菜单..."
        return 1
    fi
    selinux_commit_ssh_port
    commit_ssh_config
    echo -e "${INFO} ${GREEN}SSH 端口已顺利修改为 ${new_port}${RESET}"

    if [ -f "$JAIL_CONF" ] && grep -q "^\[${TARGET_JAIL}\]" "$JAIL_CONF"; then
        echo -e "${INFO} 正在同步更新 Fail2Ban 防护端口..."
        if ! backup_f2b_config; then
            echo -e "${WARN} 无法备份 Fail2Ban 配置，端口同步已跳过。"
        elif ! set_f2b_conf "port" "$new_port"; then
            echo -e "${WARN} Fail2Ban 端口配置未修改。"
            restore_f2b_config
            commit_f2b_config
        elif command -v fail2ban-client &>/dev/null && fail2ban-client ping >/dev/null 2>&1; then
            if restart_f2b; then
                commit_f2b_config
            else
                echo -e "${WARN} Fail2Ban 重启失败，正在恢复原端口配置。"
                restore_f2b_config
                restart_f2b >/dev/null 2>&1 || true
                commit_f2b_config
            fi
        else
            commit_f2b_config
        fi
    fi

    if command -v ss &>/dev/null; then
        echo -e "${INFO} 系统实际监听服务端口状态："
        ss -tulpn | grep ssh || true
    fi
    echo -e "${WARN} 注意：如使用的是云服务器，请务必在安全组中开放 TCP ${new_port} 端口。"
    read -rp "按回车键返回主菜单..."
}

# ============ 系统优化模块 ============
sysctl_set() {
    local key="$1" value="$2"
    if grep -qE "^${key}[[:space:]]*=" /etc/sysctl.conf 2>/dev/null; then
        sed -i -E "s|^${key}[[:space:]]*=.*|${key}=${value}|" /etc/sysctl.conf
    else
        printf '%s=%s\n' "$key" "$value" >> /etc/sysctl.conf
    fi
}

fix_dpkg() {
    if command -v pgrep &>/dev/null; then
        for proc in apt apt-get dpkg unattended-upgrade; do
            if pgrep -x "$proc" >/dev/null 2>&1; then
                echo -e "${ERROR} 检测到正在运行的 ${proc}，为避免损坏包管理数据库，已取消清理。"
                return 1
            fi
        done
    fi
    DEBIAN_FRONTEND=noninteractive dpkg --configure -a --force-confold 2>/dev/null
}

run_system_cleanup() {
    echo -e "${INFO} 正在执行系统清理..."
    if [ "$PKG_MGR" = "apt" ]; then
        if ! fix_dpkg; then
            return 1
        fi
        if ! apt-get autoremove --purge -y || ! apt-get clean || ! apt-get autoclean; then
            echo -e "${ERROR} apt 清理失败。"
            return 1
        fi
        if command -v journalctl &>/dev/null; then
            journalctl --rotate
            journalctl --vacuum-time=30d --vacuum-size=200M
        fi
    elif [ "$PKG_MGR" = "apk" ]; then
        find /var/log -mindepth 1 \
            -path "/var/log/cdt" -prune -o \
            -type f -name '*.gz' -mtime +30 -delete 2>/dev/null
        apk cache clean
    fi
    # 只清理超过 7 天的临时文件，避免递归删除仍在使用的目录。
    find /tmp -xdev -mindepth 1 -maxdepth 1 -type f -mtime +7 -delete 2>/dev/null || true
    find /tmp -xdev -mindepth 1 -maxdepth 1 -type l -mtime +7 -delete 2>/dev/null || true
    if command -v docker &>/dev/null; then
        echo -e "${YELLOW}Docker 镜像清理将删除所有未使用镜像（包括未被容器使用的旧版本）。${RESET}"
        read -rp "请输入 DELETE 确认清理 Docker 镜像：" docker_cleanup_confirm
        if [ "$docker_cleanup_confirm" = "DELETE" ]; then
            if ! docker image prune -a -f >/dev/null 2>&1; then
                echo -e "${WARN} Docker 镜像清理失败或 daemon 未运行。"
            fi
            find /var/lib/docker/containers/ -name "*.log" -exec truncate -s 0 {} \; 2>/dev/null
        else
            echo -e "${INFO} 已跳过 Docker 镜像清理。"
        fi
    fi
    echo -e "${INFO} ${GREEN}系统清理完成。${RESET}"
}

current_timezone() {
    local tz=""
    [ -f /etc/timezone ] && tz=$(cat /etc/timezone 2>/dev/null)
    [ -z "$tz" ] && command -v timedatectl &>/dev/null && tz=$(timedatectl show -p Timezone --value 2>/dev/null)
    [ -z "$tz" ] && tz=$(readlink /etc/localtime 2>/dev/null | sed 's|.*/zoneinfo/||')
    [ -z "$tz" ] && tz="未知"
    printf '%s\n' "$tz"
}

show_vps_status() {
    local bbr_status fq_status tz docker_status zram_status
    bbr_status=$(cat /proc/sys/net/ipv4/tcp_congestion_control 2>/dev/null || true)
    fq_status=$(cat /proc/sys/net/core/default_qdisc 2>/dev/null || true)
    tz=$(current_timezone)

    if [ "$bbr_status" = "bbr" ] && [ "$fq_status" = "fq" ]; then
        bbr_status="${GREEN}BBR + FQ 已启用${RESET}"
    elif [ "$bbr_status" = "bbr" ]; then
        bbr_status="${YELLOW}BBR 已启用，FQ=${fq_status:-未知}${RESET}"
    else
        bbr_status="${YELLOW}未启用${RESET}"
    fi

    if grep -q '^/dev/zram' /proc/swaps 2>/dev/null; then
        zram_status="${GREEN}已启用${RESET}"
    else
        zram_status="${YELLOW}未启用${RESET}"
    fi

    if command -v docker &>/dev/null; then
        if docker info >/dev/null 2>&1; then
            docker_status="${GREEN}$(docker -v 2>/dev/null | awk '{print $3}' | tr -d ',')，daemon 运行中${RESET}"
        else
            docker_status="${YELLOW}已安装，daemon 未运行${RESET}"
        fi
    else
        docker_status="${YELLOW}未安装${RESET}"
    fi

    echo -e "${CYAN}------------------- 系统优化状态 -------------------${RESET}"
    echo -e "系统环境 : ${GREEN}${OS_SHORT} ${OS_VER}${RESET}"
    echo -e "网络算法 : ${bbr_status}"
    echo -e "zRAM     : ${zram_status}"
    echo -e "Docker   : ${docker_status}"
    echo -e "系统时区 : ${tz}"
}

manage_bbr() {
    local current_cc current_qdisc
    current_cc=$(cat /proc/sys/net/ipv4/tcp_congestion_control 2>/dev/null || true)
    current_qdisc=$(cat /proc/sys/net/core/default_qdisc 2>/dev/null || true)
    echo -e "当前状态：拥塞控制=${current_cc:-未知}，队列调度=${current_qdisc:-未知}"
    read -rp "是否配置 BBR + FQ？(y/N): " confirm
    if [[ "$confirm" =~ ^[Yy]$ ]]; then
        sysctl_set "net.core.default_qdisc" "fq"
        sysctl_set "net.ipv4.tcp_congestion_control" "bbr"
        sysctl -p >/dev/null 2>&1 || true
        current_cc=$(cat /proc/sys/net/ipv4/tcp_congestion_control 2>/dev/null || true)
        current_qdisc=$(cat /proc/sys/net/core/default_qdisc 2>/dev/null || true)
        if [ "$current_cc" = "bbr" ] && [ "$current_qdisc" = "fq" ]; then
            echo -e "${INFO} ${GREEN}BBR + FQ 已配置并生效。${RESET}"
        else
            echo -e "${WARN} 配置已写入，当前未完全生效，可能需要重启。"
        fi
    fi
    read -rp "按回车键返回..."
}

manage_zram() {
    local total_mem zram_size phys_swap swap_p install_rc=0
    if grep -q '^/dev/zram' /proc/swaps 2>/dev/null; then
        echo -e "${GREEN}检测到 zRAM swap 已启用。${RESET}"
    fi
    read -rp "是否部署或覆盖 zRAM？(y/N): " confirm
    [[ "$confirm" =~ ^[Yy]$ ]] || { read -rp "按回车键返回..."; return; }

    if ! command -v free &>/dev/null; then
        echo -e "${ERROR} 未找到 free，无法读取内存大小。"
        read -rp "按回车键返回..."
        return 1
    fi
    total_mem=$(free -m | awk '/^Mem:/{print $2}')
    if ! [[ "$total_mem" =~ ^[0-9]+$ ]] || [ "$total_mem" -le 0 ]; then
        echo -e "${ERROR} 无法读取有效的内存大小。"
        read -rp "按回车键返回..."
        return 1
    fi
    if [ "$total_mem" -le 1024 ]; then zram_size="$total_mem"; else zram_size=$((total_mem * 60 / 100)); fi

    phys_swap=$(awk 'NR>1 && $1 !~ /^\/dev\/zram/ {s+=$3} END{printf "%d", s/1024}' /proc/swaps 2>/dev/null)
    phys_swap=${phys_swap:-0}
    if [ "$phys_swap" -gt 0 ]; then swap_p=60; elif [ "$total_mem" -le 1024 ]; then swap_p=80; else swap_p=60; fi

    if ! sysctl_set "vm.swappiness" "$swap_p" || ! sysctl -p >/dev/null 2>&1; then
        echo -e "${ERROR} swappiness 配置失败。"
        read -rp "按回车键返回..."
        return 1
    fi
    if [ "$OS_ID" = "alpine" ]; then
        if ! apk add --no-cache zram-init >/dev/null 2>&1; then
            install_rc=1
        elif ! printf 'load_modules="yes"\nnum_devices="1"\ntype0="swap"\nsize0="%s"\nalgo0="lz4"\n' "$zram_size" > /etc/conf.d/zram-init; then
            install_rc=1
        else
            rc-update add zram-init default >/dev/null 2>&1 || true
            svc_restart zram-init || svc_start zram-init || install_rc=1
        fi
    else
        if ! DEBIAN_FRONTEND=noninteractive apt-get install -y -qq zram-tools >/dev/null 2>&1; then
            install_rc=1
        elif ! printf 'ALGO=lz4\nSIZE=%s\nPRIORITY=100\n' "$zram_size" > /etc/default/zramswap; then
            install_rc=1
        else
            svc_restart zramswap || install_rc=1
        fi
    fi
    if [ "$install_rc" -eq 0 ] && grep -q '^/dev/zram' /proc/swaps 2>/dev/null; then
        echo -e "${INFO} ${GREEN}zRAM 已配置 (${zram_size}MB，swappiness=${swap_p})。${RESET}"
    else
        echo -e "${ERROR} zRAM 配置或启动失败，请检查内核模块和服务日志。"
        return 1
    fi
    read -rp "按回车键返回..."
}

check_docker_latest() {
    LATEST_DOCKER=$(curl -fsSL --connect-timeout 3 --max-time 5 "https://api.github.com/repos/moby/moby/releases/latest" 2>/dev/null | grep '"tag_name"' | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' || true)
    LATEST_COMPOSE=$(curl -fsSL --connect-timeout 3 --max-time 5 "https://api.github.com/repos/docker/compose/releases/latest" 2>/dev/null | grep '"tag_name"' | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' || true)
}

remove_docker() {
    local rc=0 packages=()
    if [ "$OS_ID" = "alpine" ]; then
        svc_stop docker || true
        svc_disable docker || true
        if apk info -e docker >/dev/null 2>&1; then packages+=(docker); fi
        if apk info -e docker-cli-compose >/dev/null 2>&1; then packages+=(docker-cli-compose); fi
        if [ "${#packages[@]}" -gt 0 ] && ! apk del "${packages[@]}" >/dev/null 2>&1; then
            rc=1
        fi
    else
        svc_stop docker || true
        for pkg in docker-ce docker-ce-cli containerd.io docker-compose-plugin docker-buildx-plugin docker.io docker-compose docker-compose-v2; do
            if dpkg-query -W -f='${Status}' "$pkg" 2>/dev/null | grep -q 'install ok installed'; then
                packages+=("$pkg")
            fi
        done
        if [ "${#packages[@]}" -gt 0 ] && ! apt-get purge -y "${packages[@]}" >/dev/null 2>&1; then
            rc=1
        fi
        [ "$rc" -eq 0 ] && apt-get autoremove -y >/dev/null 2>&1 || true
    fi
    if [ "$rc" -ne 0 ]; then
        echo -e "${ERROR} Docker 软件包卸载失败，未删除 Docker 数据。"
        return 1
    fi
    rm -rf /var/lib/docker /var/lib/containerd
    return 0
}

manage_docker() {
    local action confirm install_rc=0
    if command -v docker &>/dev/null; then
        DOCKER_VER=$(docker -v 2>/dev/null | awk '{print $3}' | tr -d ',')
        COMPOSE_VER=$(docker compose version 2>/dev/null | awk '{print $NF}' | tr -d 'v')
        echo -e "当前 Docker：${GREEN}${DOCKER_VER:-未知}${RESET}，Compose：${GREEN}${COMPOSE_VER:-未安装}${RESET}"
        check_docker_latest
        echo -e "可用最新版本：Docker ${LATEST_DOCKER:-查询失败}，Compose ${LATEST_COMPOSE:-查询失败}"
        echo -e "  ${GREEN}1.${RESET} 更新 Docker/Compose"
        echo -e "  ${GREEN}2.${RESET} 卸载 Docker/Compose"
        echo -e "  ${GREEN}0.${RESET} 返回"
        read -rp "请选择 [0-2]: " action
        case "$action" in 1) action=update ;; 2) action=remove ;; *) return ;; esac
    else
        echo -e "${YELLOW}当前未安装 Docker。${RESET}"
        read -rp "是否安装 Docker/Compose？(y/N): " confirm
        [[ "$confirm" =~ ^[Yy]$ ]] || return
        action=install
    fi

    if [ "$action" = "remove" ]; then
        echo -e "${RED}${BOLD}此操作将删除 Docker 容器、镜像、卷和 /var/lib/containerd 数据。${RESET}"
        read -rp "请输入 DELETE 确认卸载并删除全部 Docker 数据：" confirm
        [ "$confirm" = "DELETE" ] || { echo -e "${INFO} 已取消。"; return; }
        remove_docker
        install_rc=$?
        hash -r 2>/dev/null
        if [ "$install_rc" -ne 0 ] || command -v docker &>/dev/null; then
            echo -e "${ERROR} Docker 卸载未完整成功。"
        else
            echo -e "${INFO} ${GREEN}Docker、容器和相关数据已卸载。${RESET}"
        fi
        return
    fi

    echo -e "${YELLOW}Docker 安装/更新将使用系统软件包管理器，不执行远程 root 安装脚本。${RESET}"
    read -rp "确认继续？(y/N): " confirm
    [[ "$confirm" =~ ^[Yy]$ ]] || { echo -e "${INFO} 已取消 Docker 安装/更新。"; return; }
    echo -e "${INFO} 正在安装/更新 Docker & Compose，请稍候..."
    if [ "$OS_ID" = "alpine" ]; then
        if ! apk add --no-cache docker docker-cli-compose >/dev/null 2>&1; then
            install_rc=1
        else
            svc_enable docker || true
            svc_start docker || true
        fi
    else
        if ! pkg_install docker.io >/dev/null 2>&1; then
            install_rc=1
        elif ! pkg_install docker-compose-v2 >/dev/null 2>&1 && \
             ! pkg_install docker-compose >/dev/null 2>&1; then
            install_rc=1
        fi
        svc_enable docker || true
        svc_start docker || true
    fi
    hash -r 2>/dev/null
    if [ "$install_rc" -eq 0 ] && command -v docker &>/dev/null && docker info >/dev/null 2>&1 && docker compose version >/dev/null 2>&1; then
        DOCKER_VER=$(docker -v 2>/dev/null | awk '{print $3}' | tr -d ',')
        COMPOSE_VER=$(docker compose version 2>/dev/null | awk '{print $NF}' | tr -d 'v')
        echo -e "${INFO} ${GREEN}Docker ${DOCKER_VER:-未知} / Compose ${COMPOSE_VER:-未知} 已就绪。${RESET}"
    else
        echo -e "${ERROR} Docker 或 Compose 安装失败，或 Docker daemon 未运行。"
    fi
}


manage_timezone() {
    local tz
    tz=$(current_timezone)
    echo -e "当前时区：${CYAN}${tz}${RESET}"
    read -rp "是否设置为 Asia/Shanghai？(y/N): " confirm
    [[ "$confirm" =~ ^[Yy]$ ]] || { read -rp "按回车键返回..."; return; }
    local zoneinfo="/usr/share/zoneinfo/Asia/Shanghai"
    if [ "$OS_ID" = "alpine" ] && [ ! -f "$zoneinfo" ]; then
        apk add --no-cache tzdata >/dev/null 2>&1 || { echo -e "${ERROR} tzdata 安装失败。"; read -rp "按回车键返回..."; return 1; }
    fi
    if [ ! -f "$zoneinfo" ] && [ "$PKG_MGR" = "apt" ]; then
        DEBIAN_FRONTEND=noninteractive apt-get install -y tzdata >/dev/null 2>&1 || true
    fi
    if [ ! -f "$zoneinfo" ]; then
        echo -e "${ERROR} 未找到 Asia/Shanghai 时区数据。"
        read -rp "按回车键返回..."
        return 1
    fi
    if ! ln -sf "$zoneinfo" /etc/localtime || ! printf 'Asia/Shanghai\n' > /etc/timezone; then
        echo -e "${ERROR} 时区写入失败。"
        read -rp "按回车键返回..."
        return 1
    fi
    if [ "$(current_timezone)" != "Asia/Shanghai" ]; then
        echo -e "${ERROR} 时区设置后验证失败。"
        read -rp "按回车键返回..."
        return 1
    fi
    echo -e "${INFO} ${GREEN}时区已设置为 Asia/Shanghai。${RESET}"
    read -rp "按回车键返回..."
}

manage_system_optimization() {
    while true; do
        clear
        echo -e "${CYAN}============================================================${RESET}"
        echo -e "${BOLD}${PURPLE}                     系统优化管理${RESET}"
        echo -e "${CYAN}============================================================${RESET}"
        show_vps_status
        echo -e "${CYAN}------------------------------------------------------------${RESET}"
        echo -e "  ${GREEN}1.${RESET} BBR + FQ 管理"
        echo -e "  ${GREEN}2.${RESET} zRAM 管理"
        echo -e "  ${GREEN}3.${RESET} Docker 管理"
        echo -e "  ${GREEN}4.${RESET} 时区管理"
        echo -e "  ${GREEN}5.${RESET} 立即执行系统清理"
        echo -e "  ${GREEN}0.${RESET} 返回主菜单"
        echo -e "${CYAN}============================================================${RESET}"
        read -rp "请选择 [0-5]: " choice
        case "$choice" in
            1) manage_bbr ;;
            2) manage_zram ;;
            3) manage_docker ;;
            4) manage_timezone ;;
            5)
                echo -e "${YELLOW}${BOLD}系统清理将执行 apt autoremove、删除临时文件、清理日志并删除未使用的 Docker 镜像。${RESET}"
                read -rp "确认继续？(y/N): " cleanup_confirm
                if [[ "$cleanup_confirm" =~ ^[Yy]$ ]]; then
                    run_system_cleanup || echo -e "${ERROR} 系统清理未完整成功。"
                else
                    echo -e "${INFO} 已取消系统清理。"
                fi
                read -rp "按回车键返回..."
                ;;
            0) return ;;
            *) echo -e "${ERROR} 无效选项！"; sleep 1 ;;
        esac
    done
}

show_combined_status() {
    show_status
    show_vps_status
}

# ============ 主逻辑 ============
detect_os
detect_pkg_mgr
detect_init
detect_ssh_log

case "$OS_ID" in
    debian|alpine) ;;
    *)
        echo -e "${ERROR} 不支持的系统：${OS_NAME} (${OS_ID})"
        echo -e "${YELLOW}当前合并版仅支持 Debian 和 Alpine。${RESET}"
        exit 1
        ;;
esac

check_dependencies || exit 1
while true; do
    clear
    echo -e "${CYAN}============================================================${RESET}"
    echo -e "${BOLD}${PURPLE}                    VPS 综合管理工具${RESET}"
    echo -e "${CYAN}============================================================${RESET}"
    echo -e "系统环境：${GREEN}${OS_SHORT} ${OS_VER}${RESET}"
    echo -e "------------------------------------------------------------"
    echo -e "  ${GREEN}1.${RESET} 系统优化管理"
    echo -e "  ${GREEN}2.${RESET} SSH 密钥管理"
    echo -e "  ${GREEN}3.${RESET} 密码登录开关"
    echo -e "  ${GREEN}4.${RESET} Fail2Ban 防护管理"
    echo -e "  ${GREEN}5.${RESET} SSH 端口管理"
    echo -e "  ${GREEN}6.${RESET} 查看完整系统状态"
    echo -e "  ${GREEN}0.${RESET} 退出"
    echo -e "${CYAN}============================================================${RESET}"
    read -rp "请选择 [0-6]: " choice
    case "$choice" in
        1) manage_system_optimization ;;
        2) install_key_menu ;;
        3) toggle_password_login ;;
        4) manage_fail2ban_menu ;;
        5) change_ssh_port ;;
        6) clear; show_combined_status; read -rp "按回车键返回主菜单..." ;;
        0) echo -e "\n感谢使用！"; exit 0 ;;
        *) echo -e "${ERROR} 无效选项，请重新选择！"; sleep 1 ;;
    esac
done
