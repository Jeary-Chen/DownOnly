#!/bin/bash

# DownOnly 自动安装脚本 · https://github.com/EchoPing07/DownOnly
#
# 包内文件名不固定，统一解包后落地为 ${APP_DIR}/downonly；
# 下载/校验/解包/落地与菜单「更新」共用生成的管理脚本（--install-binary）。
# 可选环境变量（默认值即线上行为，仅供测试/自定义）：
#   DOWNONLY_INSTALL_DIR DOWNONLY_MANAGER_PATH DOWNONLY_SYSTEMD_DIR DOWNONLY_LOGROTATE_DIR
#   DOWNONLY_REPO DOWNONLY_API_URL DOWNONLY_DL_BASE ALLOW_SKIP_CHECKSUM

set -e
set -o pipefail

# ===== 配置 =====
REPO="${DOWNONLY_REPO:-EchoPing07/DownOnly}"
APP_DIR="${DOWNONLY_INSTALL_DIR:-/root/downonly}"
MANAGER_PATH="${DOWNONLY_MANAGER_PATH:-/usr/local/bin/downonly}"
SYSTEMD_DIR="${DOWNONLY_SYSTEMD_DIR:-/etc/systemd/system}"
LOGROTATE_DIR="${DOWNONLY_LOGROTATE_DIR:-/etc/logrotate.d}"
API_URL="${DOWNONLY_API_URL:-https://api.github.com/repos/${REPO}/releases/latest}"
DL_BASE="${DOWNONLY_DL_BASE:-https://github.com/${REPO}/releases/download}"
SERVICE="downonly"
PORT=8080
GO_VERSION="1.22.5"
VERSION_FILE="${APP_DIR}/.downonly_version"

# ===== 颜色 / 输出 =====
G='\033[0;32m'
R='\033[0;31m'
Y='\033[0;33m'
B='\033[1;34m'
W='\033[0m'

ok()   { echo -e "${G}      $*${W}"; }
warn() { echo -e "${Y}      $*${W}"; }
err()  { echo -e "${R}      $*${W}" >&2; }
die()  { err "$*"; exit 1; }
have() { command -v "$1" >/dev/null 2>&1; }

# ===== 临时工作区（退出时清理并提示） =====
WORK=$(mktemp -d "${TMPDIR:-/tmp}/downonly-install.XXXXXX")
on_exit() {
    local rc=$?
    rm -rf "$WORK" 2>/dev/null || true
    if [ "$rc" -ne 0 ]; then
        echo ""
        warn "安装未完成（退出码 ${rc}）。目录 ${APP_DIR} 当前内容："
        ls -la "$APP_DIR" 2>/dev/null || true
        warn "可直接重跑本脚本继续安装；若反复失败，请把以上输出贴到 issue"
    fi
}
trap on_exit EXIT

# ===== 依赖 =====
install_pkgs() {
    if have apt-get; then apt-get update -qq && apt-get install -y "$@" >/dev/null 2>&1
    elif have apt; then apt update -qq && apt install -y "$@" >/dev/null 2>&1
    elif have dnf; then dnf install -y "$@" >/dev/null 2>&1
    elif have yum; then yum install -y "$@" >/dev/null 2>&1
    elif have apk; then apk add --no-cache "$@" >/dev/null 2>&1
    else return 1
    fi
}

ensure_deps() {
    local missing="" c
    for c in tar mktemp sha256sum; do have "$c" || missing="$missing $c"; done
    if [ -n "$missing" ]; then
        warn "缺少依赖:${missing}，尝试自动安装..."
        install_pkgs $missing || die "自动安装依赖失败，请手动安装:${missing}"
    fi
    for c in tar mktemp sha256sum; do have "$c" || die "依赖仍缺失: $c"; done
    if ! have curl && ! have wget; then
        warn "缺少 curl / wget，尝试自动安装 curl..."
        install_pkgs curl || die "请先手动安装 curl 或 wget"
    fi
}

http_get() {   # $1=url $2=输出文件
    if have wget; then
        wget -q -O "$2" "$1"
    else
        curl -fsSL --connect-timeout 10 --retry 2 -o "$2" "$1"
    fi
}

port_busy() {
    local out="" n=""
    if have ss; then
        out=$(ss -tln 2>/dev/null || true)
    elif have netstat; then
        out=$(netstat -tln 2>/dev/null || true)
    fi
    if [ -n "$out" ]; then
        n=$(printf '%s\n' "$out" | grep -cE "[:.]${PORT}([[:space:]]|$)" || true)
        [ "${n:-0}" -gt 0 ] && return 0
        return 1
    fi
    if [ -r /proc/net/tcp ]; then
        # 8080 = 0x1F90
        grep -qiE ":1F90( |$)" /proc/net/tcp && return 0
    fi
    return 1
}

primary_ip() {
    local ip=""
    ip=$(hostname -I 2>/dev/null | awk '{print $1}') || true
    if [ -z "$ip" ] && have ip; then
        ip=$(ip route get 1.1.1.1 2>/dev/null | awk '{for (i=1;i<=NF;i++) if ($i=="src") {print $(i+1); exit}}') || true
    fi
    [ -n "$ip" ] || ip="<设备IP>"
    printf '%s' "$ip"
}

# ===== 欢迎信息 =====
if [ -t 1 ] && have clear; then clear; fi
echo -e "${B}"
cat <<'BANNER'
 ______   _______  _     _  __    _  _______  __    _  ___      __   __
|      | |       || | _ | ||  |  | ||       ||  |  | ||   |    |  | |  |
|  _    ||   _   || || || ||   |_| ||   _   ||   |_| ||   |    |  |_|  |
| | |   ||  | |  ||       ||       ||  | |  ||       ||   |    |       |
| |_|   ||  |_|  ||       ||  _    ||  |_|  ||  _    ||   |___ |_     _|
|       ||       ||   _   || | |   ||       || | |   ||       |  |   |
|______| |_______||__| |__||_|  |__||_______||_|  |__||_______|  |___|
BANNER
echo -e "${W}"
echo -e "${Y} DownOnly 自动安装程序${W}"
echo ""

# ===== [1/7] 环境检查 =====
echo -e "${B}[1/7]${W} 环境检查..."
[ "$EUID" -eq 0 ] || { err "错误: 请使用 root 权限运行"; exit 1; }
ensure_deps
have systemctl || die "未检测到 systemd。可改用 Docker 部署（见 README），或手动运行 ${APP_DIR}/downonly"
ok "权限与依赖检查通过"

# ===== [2/7] 检测系统架构 =====
echo -e "${B}[2/7]${W} 检测系统架构..."
ARCH_RAW=$(uname -m)
case "$ARCH_RAW" in
    x86_64|amd64)      GOARCH="amd64" ;;
    aarch64|arm64)     GOARCH="arm64" ;;
    armv7l)            GOARCH="armv7" ;;
    armv8l)            GOARCH="armv7"; warn "armv8l 按 32 位 armv7 处理" ;;
    armv6l|armv5tel)   GOARCH="armv6" ;;
    arm)               GOARCH="armv6"; warn "uname -m=arm，按 armv6 处理" ;;
    i386|i486|i586|i686|x86)
        die "暂未提供 32 位 x86 预编译包（架构: ${ARCH_RAW}），请改用 Docker 或源码编译" ;;
    *)
        die "不支持的架构: ${ARCH_RAW}" ;;
esac
# 本地编译时 Go 工具链的下载名（armv7/armv6 共用 armv6l）
case "$GOARCH" in
    armv7) GOARM="7"; GO_DL_ARCH="armv6l" ;;
    armv6) GOARM="6"; GO_DL_ARCH="armv6l" ;;
    *)     GOARM="";  GO_DL_ARCH="$GOARCH" ;;
esac
ok "架构: ${GOARCH}${GOARM:+ (GOARM=${GOARM})}"

# ===== [3/7] 安装管理脚本 =====
# 先装管理器：下载/校验/解包/落地都由它的 --install-binary 完成
echo -e "${B}[3/7]${W} 安装管理脚本..."
mkdir -p "$(dirname "$MANAGER_PATH")"
cat > "$MANAGER_PATH" << 'MANAGER_SCRIPT'
#!/bin/bash
# DownOnly 管理脚本（由 install.sh 生成，重跑 install.sh 即更新）
# 子命令：--latest | --installed | --install-binary <tag> <arch> | --help
# 可选环境变量（默认值即线上行为）：DOWNONLY_DIR DOWNONLY_SERVICE DOWNONLY_REPO
#   DOWNONLY_API_URL DOWNONLY_DL_BASE DOWNONLY_SYSTEMD_DIR DOWNONLY_PORT ALLOW_SKIP_CHECKSUM

APP_DIR="${DOWNONLY_DIR:-/root/downonly}"
SERVICE="${DOWNONLY_SERVICE:-downonly}"
REPO="${DOWNONLY_REPO:-EchoPing07/DownOnly}"
API_URL="${DOWNONLY_API_URL:-https://api.github.com/repos/${REPO}/releases/latest}"
DL_BASE="${DOWNONLY_DL_BASE:-https://github.com/${REPO}/releases/download}"
SYSTEMD_DIR="${DOWNONLY_SYSTEMD_DIR:-/etc/systemd/system}"
PORT="${DOWNONLY_PORT:-8080}"
ALLOW_SKIP_CHECKSUM="${ALLOW_SKIP_CHECKSUM:-0}"
VERSION_FILE="${APP_DIR}/.downonly_version"

G='\033[0;32m'
R='\033[0;31m'
W='\033[0m'
B='\033[1;34m'
Y='\033[0;33m'

have() { command -v "$1" >/dev/null 2>&1; }
log_info() { echo -e " $*"; }
log_ok()   { echo -e "${G} $*${W}"; }
log_warn() { echo -e "${Y} $*${W}"; }
log_err()  { echo -e "${R} $*${W}"; }

[ "$EUID" -eq 0 ] || { echo -e "${R} 错误: 请使用 root 权限${W}"; exit 1; }

# --- 基础信息 ---
get_arch() {
    case $(uname -m) in
        x86_64|amd64)        echo "amd64" ;;
        aarch64|arm64)       echo "arm64" ;;
        armv7l|armv8l)       echo "armv7" ;;
        armv6l|armv5tel|arm) echo "armv6" ;;
        *) echo "unknown" ;;
    esac
}

installed_version() {
    [ -f "$VERSION_FILE" ] && cat "$VERSION_FILE" 2>/dev/null || true
}

get_status() {
    if systemctl is-active "$SERVICE" >/dev/null 2>&1; then
        echo -e "${G}运行中${W}"
    else
        echo -e "${R}已停止${W}"
    fi
}

health_check() {
    have curl || return 0
    curl -fsS --max-time 5 "http://127.0.0.1:${PORT}/api/status" >/dev/null 2>&1
}

# --- HTTP ---
http_download() {   # $1=url $2=输出文件
    if have wget; then
        wget -q -O "$2" "$1" 2>/dev/null
    elif have curl; then
        curl -fsSL --connect-timeout 10 --retry 2 -o "$2" "$1"
    else
        return 127
    fi
}

# wget 8 / curl 22 = HTTP 错误（资产不存在 → 404）
is_http_error_rc() {
    case "$1" in
        8|22) return 0 ;;
        *) return 1 ;;
    esac
}

get_latest_tag() {
    local body="" tag="" loc=""
    if have curl; then
        body=$(curl -fsSL --connect-timeout 10 --max-time 20 "$API_URL" 2>/dev/null || true)
        tag=$(printf '%s' "$body" | grep -m1 '"tag_name"' | sed -E 's/.*"tag_name"[[:space:]]*:[[:space:]]*"([^"]+)".*/\1/' || true)
        if [ -z "$tag" ]; then
            # API 限流时用 releases/latest 跳转兜底
            loc=$(curl -sI -o /dev/null -w '%{redirect_url}' --connect-timeout 10 --max-time 20 \
                  "https://github.com/${REPO}/releases/latest" 2>/dev/null || true)
            tag="${loc##*/tag/}"
            [ "$tag" = "$loc" ] && tag=""
        fi
    elif have wget; then
        body=$(wget -qO- "$API_URL" 2>/dev/null || true)
        tag=$(printf '%s' "$body" | grep -m1 '"tag_name"' | sed -E 's/.*"tag_name"[[:space:]]*:[[:space:]]*"([^"]+)".*/\1/' || true)
    fi
    printf '%s' "$tag"
}

# --- 校验 / 解包 ---
verify_checksum() {   # $1=文件 $2=版本；0 通过 / 2 失败
    local file="$1" ver="$2" name url sums expected actual i=1
    name=$(basename "$file")
    url="${DL_BASE}/${ver}/checksums_${ver}.txt"
    sums="$(dirname "$file")/checksums.txt"
    rm -f "$sums"
    while [ "$i" -le 3 ]; do
        if http_download "$url" "$sums" && [ -s "$sums" ]; then break; fi
        i=$((i + 1))
        sleep 1
    done
    if [ ! -s "$sums" ]; then
        if [ "$ALLOW_SKIP_CHECKSUM" = "1" ]; then
            log_warn "未取到 checksums 文件（${url}），按 ALLOW_SKIP_CHECKSUM=1 跳过校验"
            return 0
        fi
        log_err "无法获取校验文件: ${url}（网络异常时可临时用 ALLOW_SKIP_CHECKSUM=1 放行）"
        return 2
    fi
    # 兼容 sha256sum 的二进制模式输出（<hash> *<file>）
    expected=$(awk -v f="$name" '{ n=$NF; sub(/^\*/, "", n); if (n==f) { print $1; exit } }' "$sums")
    actual=$(sha256sum "$file" | awk '{print $1}')
    if [ -n "$expected" ] && [ "$expected" = "$actual" ]; then
        return 0
    fi
    log_err "SHA256 校验失败，文件可能被篡改或下载不完整"
    return 2
}

is_elf() {
    have od || return 1
    [ "$(od -An -tx1 -N4 "$1" 2>/dev/null | tr -d ' \n')" = "7f454c46" ]
}

# pick_binary <目录>：打印包内应安装的可执行文件路径
# 择优：唯一文件（可含一层子目录）→ downonly → downonly*（排除归档/文档）→ 唯一 ELF；都不满足即失败
pick_binary() {
    local dir="$1" f
    local files=() elves=()
    shopt -s nullglob
    for f in "$dir"/* "$dir"/*/*; do
        [ -f "$f" ] && files+=("$f")
    done
    shopt -u nullglob
    [ "${#files[@]}" -gt 0 ] || return 1
    if [ "${#files[@]}" -eq 1 ]; then printf '%s\n' "${files[0]}"; return 0; fi
    for f in "${files[@]}"; do
        if [ "$(basename "$f")" = "downonly" ]; then printf '%s\n' "$f"; return 0; fi
    done
    for f in "${files[@]}"; do
        case "$(basename "$f")" in
            downonly*)
                case "$f" in
                    *.tar.gz|*.tgz|*.txt|*.md|*.sha256|*.json) ;;
                    *) printf '%s\n' "$f"; return 0 ;;
                esac
                ;;
        esac
    done
    for f in "${files[@]}"; do
        is_elf "$f" && elves+=("$f")
    done
    if [ "${#elves[@]}" -eq 1 ]; then printf '%s\n' "${elves[0]}"; return 0; fi
    return 1
}

# install_binary_from_tarball <tarball> <版本> <工作目录>
install_binary_from_tarball() {
    local tarball="$1" ver="$2" work="$3"
    local src="" dest="${APP_DIR}/downonly"
    mkdir -p "${APP_DIR}/data" || { log_err "无法创建目录 ${APP_DIR}"; return 3; }
    rm -rf "${work}/extract"
    mkdir -p "${work}/extract" || return 3
    tar -tzf "$tarball" >/dev/null 2>&1 || { log_err "文件不是合法的 tar.gz: $(basename "$tarball")"; return 3; }
    # 老 BusyBox tar 不支持 --no-same-owner，失败则退回普通解包
    if ! tar -xzf "$tarball" -C "${work}/extract" --no-same-owner 2>/dev/null; then
        if ! tar -xzf "$tarball" -C "${work}/extract"; then
            log_err "解包失败: $(basename "$tarball")"
            return 3
        fi
    fi
    if ! src=$(pick_binary "${work}/extract"); then
        log_err "包内没有找到可用的可执行文件，包内清单："
        tar -tzf "$tarball" 2>/dev/null | sed 's/^/    /'
        return 3
    fi
    if have od && ! is_elf "$src"; then
        log_err "包内文件不是 ELF 可执行文件: $(basename "$src")"
        return 3
    fi
    [ -f "$dest" ] && cp -f "$dest" "${APP_DIR}/downonly.bak" 2>/dev/null
    [ -f "$VERSION_FILE" ] && cp -f "$VERSION_FILE" "${VERSION_FILE}.bak" 2>/dev/null
    if ! install -m 0755 "$src" "${APP_DIR}/downonly.new" 2>/dev/null; then
        if ! cp -f "$src" "${APP_DIR}/downonly.new"; then
            log_err "写入 ${APP_DIR} 失败（磁盘空间 / 权限？）"
            return 3
        fi
        chmod 0755 "${APP_DIR}/downonly.new"
    fi
    if ! mv -f "${APP_DIR}/downonly.new" "$dest"; then
        log_err "替换 ${dest} 失败"
        return 3
    fi
    printf '%s\n' "$ver" > "$VERSION_FILE" 2>/dev/null || true
    # 清理旧版残留的错名文件
    rm -f "${APP_DIR}"/downonly_linux_*.tar.gz "${APP_DIR}"/downonly_linux_* 2>/dev/null || true
    log_ok "已安装 ${dest}（包内文件: $(basename "$src")）"
    return 0
}

# fetch_and_install <版本> <架构> <工作目录>
# 返回 0 成功 / 1 该版本无对应架构预编译包 / 2 校验失败 / 3 其他错误
fetch_and_install() {
    local ver="$1" arch="$2" work="$3" tarball url rc=0
    case "$arch" in
        amd64|arm64|armv7|armv6) ;;
        *) log_err "不支持的架构: $arch"; return 3 ;;
    esac
    [ -n "$ver" ] || { log_err "缺少版本号"; return 3; }
    mkdir -p "$work" || return 3
    tarball="${work}/downonly_linux_${arch}_${ver}.tar.gz"
    url="${DL_BASE}/${ver}/downonly_linux_${arch}_${ver}.tar.gz"
    rm -f "$tarball"
    log_info "下载: ${url}"
    http_download "$url" "$tarball"
    rc=$?
    if [ "$rc" -ne 0 ]; then
        rm -f "$tarball"
        if is_http_error_rc "$rc"; then
            log_warn "该版本没有 ${arch} 的预编译包"
            return 1
        fi
        log_err "下载失败（退出码 ${rc}），请检查网络后重试"
        return 3
    fi
    [ -s "$tarball" ] || { log_err "下载文件为空"; rm -f "$tarball"; return 3; }
    if ! verify_checksum "$tarball" "$ver"; then
        rm -f "$tarball"
        return 2
    fi
    log_ok "SHA256 校验通过"
    if ! install_binary_from_tarball "$tarball" "$ver" "$work"; then
        rm -f "$tarball"
        return 3
    fi
    rm -f "$tarball"
    return 0
}

# --- 菜单 ---
show_menu() {
    clear
    echo -e "${B}"
    echo " ______   _______  _     _  __    _  _______  __    _  ___      __   __ "
    echo "|      | |       || | _ | ||  |  | ||       ||  |  | ||   |    |  | |  |"
    echo "|  _    ||   _   || || || ||   |_| ||   _   ||   |_| ||   |    |  |_|  |"
    echo "| | |   ||  | |  ||       ||       ||  | |  ||       ||   |    |       |"
    echo "| |_|   ||  |_|  ||       ||  _    ||  |_|  ||  _    ||   |___ |_     _|"
    echo "|       ||       ||   _   || | |   ||       || | |   ||       |  |   |  "
    echo "|______| |_______||__| |__||_|  |__||_______||_|  |__||_______|  |___|  "
    echo -e "${W}"
    echo -e " 状态: $(get_status)    版本: $(installed_version | sed 's/^$/未知/')"
    echo ""
    echo " ┌─────────────────────────────────────────────────┐"
    echo " │  1. 启动   2. 停用   3. 重启   4. 日志          │"
    echo " │                                                 │"
    echo " │  5. 更新   6. 卸载   0. 退出                    │"
    echo " └─────────────────────────────────────────────────┘"
    echo ""
}

show_logs() {
    local f="${APP_DIR}/data/sys_out.log"
    if [ -f "$f" ]; then
        tail -n 100 -f "$f"
    elif have journalctl; then
        log_warn "未启用文件日志，显示 journal（Ctrl+C 返回菜单）"
        journalctl -u "$SERVICE" -n 100 -f
    else
        log_warn "未找到日志文件: ${f}"
        sleep 2
    fi
}

do_update() {
    log_info "正在检查最新版本..."
    local latest="" cur="" arch="" work="" rc=0
    latest=$(get_latest_tag)
    if [ -z "$latest" ]; then
        log_err "无法获取版本信息，请检查网络"
        sleep 2
        return 1
    fi
    cur=$(installed_version)
    if [ -n "$cur" ] && [ "$cur" = "$latest" ]; then
        log_ok "当前已是最新版本: ${latest}"
        sleep 2
        return 0
    fi
    log_info "当前版本: ${cur:-未知}    最新版本: ${latest}"
    read -r -p " 是否更新? (y/n): " confirm || return 0
    [ "$confirm" = "y" ] || return 0

    arch=$(get_arch)
    if [ "$arch" = "unknown" ]; then
        log_err "不支持的架构"
        sleep 2
        return 1
    fi

    systemctl stop "$SERVICE" >/dev/null 2>&1 || true
    work=$(mktemp -d "${TMPDIR:-/tmp}/downonly-update.XXXXXX") || return 1
    fetch_and_install "$latest" "$arch" "$work"
    rc=$?
    rm -rf "$work"

    if [ "$rc" -ne 0 ]; then
        case "$rc" in
            1) log_err "该版本没有 ${arch} 的预编译包，无法自动更新" ;;
            2) log_err "SHA256 校验失败，已放弃更新" ;;
            *) log_err "更新失败（退出码 ${rc}）" ;;
        esac
        systemctl start "$SERVICE" >/dev/null 2>&1 || true
        sleep 3
        return 1
    fi

    systemctl start "$SERVICE" >/dev/null 2>&1 || true
    sleep 3
    if systemctl is-active "$SERVICE" >/dev/null 2>&1; then
        log_ok "更新成功: ${latest}"
        health_check || log_warn "服务已启动，但 Web 端口未响应，请查看日志（菜单 4）"
        sleep 2
        return 0
    fi

    log_err "新版本启动失败，尝试回滚..."
    if [ -f "${APP_DIR}/downonly.bak" ]; then
        mv -f "${APP_DIR}/downonly.bak" "${APP_DIR}/downonly"
        [ -f "${VERSION_FILE}.bak" ] && mv -f "${VERSION_FILE}.bak" "$VERSION_FILE"
        systemctl start "$SERVICE" >/dev/null 2>&1 || true
        sleep 2
        log_warn "已回滚到上一个版本，请用菜单 4 查看日志定位问题"
    else
        log_err "没有可回滚的备份，请手动处理"
    fi
    sleep 2
    return 1
}

do_uninstall() {
    echo ""
    read -r -p " 是否保留数据? (y保留/n全删): " keep || exit 0
    systemctl stop "$SERVICE" >/dev/null 2>&1 || true
    systemctl disable "$SERVICE" >/dev/null 2>&1 || true
    rm -f "${SYSTEMD_DIR}/${SERVICE}.service"
    systemctl daemon-reload >/dev/null 2>&1 || true
    if [ "$keep" = "y" ]; then
        rm -f "${APP_DIR}/downonly" "${APP_DIR}/downonly.bak" "$VERSION_FILE" "${VERSION_FILE}.bak"
        log_ok "已卸载，数据已保留"
    else
        rm -rf "$APP_DIR"
        log_ok "已卸载并清除所有数据"
    fi
    rm -f "$0"
    exit 0
}

usage() {
    cat <<USAGE
用法:
  downonly                          进入交互菜单
  downonly --latest                 打印最新版本号
  downonly --installed              打印当前已安装版本号
  downonly --install-binary <tag> <arch>
                                    下载并安装指定版本（arch: amd64|arm64|armv7|armv6）
  downonly -h | --help              显示本帮助
USAGE
}

# --- 非交互子命令（安装脚本调用） ---
case "${1:-}" in
    --latest)
        get_latest_tag
        exit 0
        ;;
    --installed)
        installed_version
        exit 0
        ;;
    --install-binary)
        shift
        WORKDIR=$(mktemp -d "${TMPDIR:-/tmp}/downonly-fetch.XXXXXX") || exit 3
        fetch_and_install "${1:-}" "${2:-}" "$WORKDIR"
        rc=$?
        rm -rf "$WORKDIR"
        exit $rc
        ;;
    -h|--help)
        usage
        exit 0
        ;;
esac

# --- 交互菜单 ---
while true; do
    show_menu
    read -r -p " 输入选项: " opt || exit 0
    case $opt in
        1) systemctl start "$SERVICE" && echo -e " 已启动" && sleep 1 ;;
        2) systemctl stop "$SERVICE" && echo -e " 已停止" && sleep 1 ;;
        3) systemctl restart "$SERVICE" && echo -e " 已重启" && sleep 1.5 ;;
        4) clear && echo -e "${Y} [按 Ctrl+C 返回菜单] ${W}" && echo "" && show_logs ;;
        5) do_update ;;
        6) do_uninstall ;;
        0) exit 0 ;;
        *) echo -e " 无效选项" && sleep 1 ;;
    esac
done
MANAGER_SCRIPT
chmod 0755 "$MANAGER_PATH"
ok "已安装: ${MANAGER_PATH}"

# 管理脚本与安装脚本共用同一套配置
run_manager() {
    DOWNONLY_DIR="$APP_DIR" \
    DOWNONLY_SERVICE="$SERVICE" \
    DOWNONLY_REPO="$REPO" \
    DOWNONLY_API_URL="$API_URL" \
    DOWNONLY_DL_BASE="$DL_BASE" \
    DOWNONLY_SYSTEMD_DIR="$SYSTEMD_DIR" \
    DOWNONLY_PORT="$PORT" \
    ALLOW_SKIP_CHECKSUM="${ALLOW_SKIP_CHECKSUM:-0}" \
        "$MANAGER_PATH" "$@"
}

# ===== [4/7] 安装主程序 =====

# --- 本地编译回退（无预编译包时） ---
compile_from_source() {
    if ! have git; then
        warn "安装 git..."
        install_pkgs git || die "本地编译需要 git"
    fi
    if ! have go; then
        local gofile="go${GO_VERSION}.linux-${GO_DL_ARCH}.tar.gz" url=""
        warn "未检测到 Go，下载 Go ${GO_VERSION} (${GO_DL_ARCH})..."
        for url in "https://golang.google.cn/dl/${gofile}" "https://go.dev/dl/${gofile}"; do
            http_get "$url" "${WORK}/${gofile}" && break
        done
        [ -s "${WORK}/${gofile}" ] || die "Go 工具链下载失败，请手动安装 Go ${GO_VERSION}"
        tar -C /usr/local -xzf "${WORK}/${gofile}"
        export PATH="$PATH:/usr/local/go/bin"
        have go || die "Go 安装后仍不可用"
    fi
    ok "Go 版本: $(go version)"

    warn "开始编译（约 2-3 分钟）..."
    rm -rf "${WORK}/src"
    git clone --depth 1 "https://github.com/${REPO}.git" "${WORK}/src"
    [ -f "${APP_DIR}/downonly" ] && cp -f "${APP_DIR}/downonly" "${APP_DIR}/downonly.bak" || true
    ( cd "${WORK}/src" && GOARM="$GOARM" go build -ldflags="-s -w" -o "${APP_DIR}/downonly.new" . )
    chmod 0755 "${APP_DIR}/downonly.new"
    mv -f "${APP_DIR}/downonly.new" "${APP_DIR}/downonly"
    printf '%s\n' "${LATEST}(源码编译)" > "$VERSION_FILE" 2>/dev/null || true
    ok "编译完成"
}

echo -e "${B}[4/7]${W} 获取版本并安装主程序..."
LATEST=$(run_manager --latest 2>/dev/null || true)
[ -n "$LATEST" ] || die "无法获取最新版本号（GitHub API 可能限流或网络不通），请稍后重试"
ok "最新版本: ${LATEST}"

mkdir -p "${APP_DIR}/data"
if run_manager --install-binary "$LATEST" "$GOARCH"; then
    ok "预编译程序安装完成"
else
    PRC=$?
    if [ "$PRC" -eq 1 ]; then
        warn "该版本没有 ${GOARCH} 的预编译包，改为本地编译..."
        compile_from_source
    else
        die "安装主程序失败（退出码 ${PRC}）"
    fi
fi

# ===== [5/7] 配置系统服务 =====
echo -e "${B}[5/7]${W} 配置系统服务..."
SYSTEMD_VER=$(systemctl --version 2>/dev/null | awk 'NR==1{print $2}' || true)
LOG_MODE="append"
if [ -n "$SYSTEMD_VER" ] && [ "$SYSTEMD_VER" -ge 240 ] 2>/dev/null; then
    LOG_MODE="append"
else
    # systemd < 240 不支持 append:，退回 journal
    LOG_MODE="journal"
    warn "systemd 版本较旧（${SYSTEMD_VER:-未知}），日志改用 journal（菜单 4 会自动切换）"
fi

if [ "$LOG_MODE" = "append" ]; then
    mkdir -p "$SYSTEMD_DIR"
    cat > "${SYSTEMD_DIR}/${SERVICE}.service" << SERVICE_FILE
[Unit]
Description=DownOnly Traffic Guard
After=network.target

[Service]
WorkingDirectory=${APP_DIR}
ExecStart=${APP_DIR}/downonly
Restart=always
RestartSec=5
StandardOutput=append:${APP_DIR}/data/sys_out.log
StandardError=append:${APP_DIR}/data/sys_err.log

[Install]
WantedBy=multi-user.target
SERVICE_FILE
else
    mkdir -p "$SYSTEMD_DIR"
    cat > "${SYSTEMD_DIR}/${SERVICE}.service" << SERVICE_FILE
[Unit]
Description=DownOnly Traffic Guard
After=network.target

[Service]
WorkingDirectory=${APP_DIR}
ExecStart=${APP_DIR}/downonly
Restart=always
RestartSec=5
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
SERVICE_FILE
fi

systemctl daemon-reload
systemctl enable "$SERVICE" >/dev/null 2>&1
ok "服务单元已就绪: ${SYSTEMD_DIR}/${SERVICE}.service"

# ===== [6/7] 配置日志轮转 =====
echo -e "${B}[6/7]${W} 配置日志轮转..."
if [ "$LOG_MODE" = "append" ]; then
    mkdir -p "$LOGROTATE_DIR"
    cat > "${LOGROTATE_DIR}/${SERVICE}" << LOGROTATE
${APP_DIR}/data/sys_out.log
${APP_DIR}/data/sys_err.log
{
    daily
    rotate 7
    compress
    delaycompress
    missingok
    notifempty
    copytruncate
    maxsize 50M
}
LOGROTATE
    ok "已写入: ${LOGROTATE_DIR}/${SERVICE}"
else
    warn "跳过（日志走 journal，由 journald 自行管理）"
fi

# ===== [7/7] 启动并自检 =====
echo -e "${B}[7/7]${W} 启动服务并自检..."
if systemctl is-active --quiet "$SERVICE"; then
    warn "服务已在运行，跳过端口占用检查"
elif port_busy; then
    warn "端口 ${PORT} 已被占用，服务可能无法监听。可用 ss -tlnp | grep ${PORT} 查看占用进程"
fi
systemctl restart "$SERVICE"
sleep 3
if systemctl is-active --quiet "$SERVICE"; then
    ok "服务运行中"
    if have curl; then
        if curl -fsS --max-time 5 "http://127.0.0.1:${PORT}/api/status" >/dev/null 2>&1; then
            ok "Web 端口 ${PORT} 响应正常"
        else
            warn "Web 端口 ${PORT} 暂无响应，请查看日志：tail -n 50 ${APP_DIR}/data/sys_out.log"
        fi
    fi
else
    warn "服务未处于运行状态，排查命令："
    warn "  systemctl status ${SERVICE} --no-pager -l"
    warn "  journalctl -u ${SERVICE} -n 50 --no-pager"
fi

# ===== 完成 =====
echo ""
echo -e "${B}[完成]${W} DownOnly ${LATEST:-} 安装结束"
echo ""
echo -e "${G}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${W}"
echo -e " 访问地址: ${Y}http://$(primary_ip):${PORT}${W}"
echo -e " 管理命令: ${Y}downonly${W}"
echo -e " 安装目录: ${Y}${APP_DIR}${W}（数据在 data/ 子目录）"
echo -e "${G}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${W}"
echo ""
