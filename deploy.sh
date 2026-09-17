#!/usr/bin/env bash
# tx-node 部署与运维脚本
#
# 交互模式（进运维面板，推荐）:
#   bash deploy.sh
#   或装好后随时: txnode        （软链到 /usr/local/bin/txnode）
#
# 非交互模式（保持向后兼容，可用于自动化）:
#   bash deploy.sh install            安装 / 重装
#   bash deploy.sh upgrade            升级
#   bash deploy.sh status             查看状态
#   bash deploy.sh start|stop|restart 启动 / 停止 / 重启
#   bash deploy.sh logs               查看日志
#   bash deploy.sh reconfigure        重新配置
#   bash deploy.sh uninstall          卸载（保留配置）
#   bash deploy.sh purge              彻底清除（含配置与镜像）
#   bash deploy.sh help
#
# 一键在线执行:
#   bash <(curl -fsSL https://raw.githubusercontent.com/PaiMonCai/TX-Node/main/deploy.sh)
set -euo pipefail

# ════════════════════════════════════════════════════════════════════
#  常量
# ════════════════════════════════════════════════════════════════════
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'
BLUE='\033[0;34m'; MAGENTA='\033[0;35m'; BOLD='\033[1m'; DIM='\033[2m'; NC='\033[0m'

APP_NAME="${APP_NAME:-tx-node}"
# 安装目录与关键路径允许用环境变量覆盖（便于自定义布局 / 多实例 / 测试）
INSTALL_DIR="${INSTALL_DIR:-/etc/xboard-node}"
COMPOSE_FILE="$INSTALL_DIR/docker-compose.yml"
CONFIG_FILE="$INSTALL_DIR/config.yml"
BACKUP_DIR="$INSTALL_DIR/backups"
IMAGE="${IMAGE:-ghcr.io/paimoncai/tx-node:latest}"
CLI_LINK="${CLI_LINK:-/usr/local/bin/txnode}"
# 自身路径：优先用 BASH_SOURCE 推导，取不到就退化为当前目录下的文件名。
# 不用 $(dirname ...)：某些精简环境（容器 / busybox）没有 dirname，会导致 set -e 直接中止。
SELF_PATH=""
if [ -n "${BASH_SOURCE[0]:-}" ]; then
  _self_dir="${BASH_SOURCE[0]%/*}"
  [ "$_self_dir" = "${BASH_SOURCE[0]}" ] && _self_dir="."
  SELF_PATH="$(cd "$_self_dir" 2>/dev/null && pwd)/${BASH_SOURCE[0]##*/}"
fi
[ -z "$SELF_PATH" ] && SELF_PATH="$0"
unset _self_dir

# systemd 模式（install.sh 装的非 docker 部署）的探测路径
SERVICE_NAME="xboard-node.service"
SERVICE_PATH="/etc/systemd/system/${SERVICE_NAME}"
SB_BINARY="/usr/local/bin/xboard-node"
XBCTL_PATH="/usr/local/bin/xbctl"

# 运行模式：docker | systemd | none，由 detect_deploy_mode 填充
DEPLOY_MODE=""

# ════════════════════════════════════════════════════════════════════
#  输出helpers
# ════════════════════════════════════════════════════════════════════
info()  { echo -e "${CYAN}[*]${NC} $*"; }
ok()    { echo -e "${GREEN}[✓]${NC} $*"; }
warn()  { echo -e "${YELLOW}[!]${NC} $*"; }
fail()  { echo -e "${RED}[✗]${NC} $*" >&2; exit 1; }
hint()  { echo -e "${DIM}    $*${NC}"; }

hr() { echo -e "${DIM}────────────────────────────────────────────────────${NC}"; }

title() {
  echo
  echo -e "${BOLD}${BLUE}  $*${NC}"
  hr
}

# 暂停等回车（用于让用户看清日志）
pause() {
  echo
  read -r -p "$(echo -e "${DIM}按回车返回菜单...${NC}")" _ || true
}

confirm() { # confirm <prompt> <default Y|n>
  local prompt="$1" default="${2:-Y}" reply
  if [ "$default" = "Y" ]; then prompt="$prompt [Y/n] "; else prompt="$prompt [y/N] "; fi
  read -r -p "$prompt" reply || true
  reply="${reply:-$default}"
  [[ "$reply" =~ ^[Yy]$ ]]
}

# 危险操作：要求用户手动输入指定单词，避免手滑回车
confirm_typed() { # confirm_typed <提示> <需输入的单词>
  local prompt="$1" word="$2" reply
  echo -e "${RED}${BOLD}  此操作不可逆！${NC}"
  read -r -p "  请输入 ${BOLD}${word}${NC} 确认，其他任意输入取消: " reply || true
  [ "$reply" = "$word" ]
}

# ════════════════════════════════════════════════════════════════════
#  部署模式探测
# ════════════════════════════════════════════════════════════════════
docker_available() {
  command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1
}

detect_deploy_mode() {
  # docker 优先：compose 文件存在，或容器存在
  if command -v docker >/dev/null 2>&1; then
    if [ -f "$COMPOSE_FILE" ] || docker ps -a --format '{{.Names}}' 2>/dev/null | grep -qx "$APP_NAME"; then
      DEPLOY_MODE="docker"
      return
    fi
  fi
  # systemd 模式
  if [ -f "$SERVICE_PATH" ] || [ -x "$SB_BINARY" ]; then
    DEPLOY_MODE="systemd"
    return
  fi
  DEPLOY_MODE="none"
}

is_installed() { [ "$DEPLOY_MODE" != "none" ]; }

# ════════════════════════════════════════════════════════════════════
#  docker 侧封装
# ════════════════════════════════════════════════════════════════════
dc() { docker compose -f "$COMPOSE_FILE" "$@"; }

container_state() { # 输出 running | exited | created | absent
  if ! command -v docker >/dev/null 2>&1; then echo "absent"; return; fi
  local st
  st=$(docker inspect -f '{{.State.Status}}' "$APP_NAME" 2>/dev/null || echo "absent")
  echo "${st:-absent}"
}

# ════════════════════════════════════════════════════════════════════
#  systemd 侧封装
# ════════════════════════════════════════════════════════════════════
svc_state() { # 输出 active | inactive | failed | absent
  if [ ! -f "$SERVICE_PATH" ]; then echo "absent"; return; fi
  systemctl is-active "$SERVICE_NAME" 2>/dev/null || echo "inactive"
}

svc_ctrl() { # svc_ctrl start|stop|restart|enable|disable
  local action="$1"
  if [ ! -f "$SERVICE_PATH" ]; then
    fail "未找到 systemd 服务 ${SERVICE_NAME}"
  fi
  case "$action" in
    start)   systemctl start   "$SERVICE_NAME" ;;
    stop)    systemctl stop    "$SERVICE_NAME" ;;
    restart) systemctl restart "$SERVICE_NAME" ;;
    enable)  systemctl enable  "$SERVICE_NAME" ;;
    disable) systemctl disable "$SERVICE_NAME" ;;
  esac
}

# 统一的日志查看（自动分派 docker / systemd）
show_logs() { # show_logs <tail行数|空=跟随>
  local n="${1:-}"
  # 自行探测：允许单独调用（例如 `deploy.sh logs` 已在 main 里探测，但函数内再保险一次）
  [ -n "$DEPLOY_MODE" ] || detect_deploy_mode
  case "$DEPLOY_MODE" in
    docker)
      if [ -n "$n" ]; then
        docker logs --tail "$n" "$APP_NAME" 2>&1 || true
      else
        info "实时日志（Ctrl+C 退出）"
        docker logs -f "$APP_NAME" 2>&1 || true
      fi
      ;;
    systemd)
      if [ -n "$n" ]; then
        journalctl -u "$SERVICE_NAME" -n "$n" --no-pager 2>&1 || true
      else
        info "实时日志（Ctrl+C 退出）"
        journalctl -u "$SERVICE_NAME" -f --no-pager 2>&1 || true
      fi
      ;;
    *) warn "未检测到部署，无法查看日志" ;;
  esac
}

# ════════════════════════════════════════════════════════════════════
#  配置解析（不依赖 yq：用 grep 提取顶层简单字段）
# ════════════════════════════════════════════════════════════════════
cfg_get() { # cfg_get <key> —— 返回配置里第一个匹配的 key 值（去引号）
  local key="$1"
  [ -f "$CONFIG_FILE" ] || return 1
  local val
  val=$(grep -m1 -E "^[[:space:]]*${key}:" "$CONFIG_FILE" 2>/dev/null \
        | sed -E "s/^[[:space:]]*${key}:[[:space:]]*//; s/^[\"']//; s/[\"'][[:space:]]*$//; s/[[:space:]]*#.*$//" \
        | tr -d '\r')
  [ -n "$val" ] && echo "$val"
}

# 区段感知取值：_sec_get <段名> <键名> —— 只在指定顶层段内查找该键。
# 比全局 cfg_get 精确，能区分 panel.token 与 machine.token、machine.machine_id 与 nodes[].node_id。
# 支持：内联注释、单双引号、CRLF、段内多级缩进。
_sec_get() {
  local sec="$1" key="$2"
  [ -f "$CONFIG_FILE" ] || return 1
  local val
  val=$(awk -v sec="$sec" -v key="$key" '
    BEGIN { insec = 0 }
    /^[^[:space:]#]/ {
      # 顶层键：形如 "name:" 或 "name: value"；只认完全匹配的段名
      if ($0 ~ ("^" sec "[[:space:]]*:")) { insec = 1; next }
      insec = 0
    }
    insec && $0 ~ ("^[[:space:]]+" key "[[:space:]]*:") {
      sub("^[[:space:]]+" key "[[:space:]]*:[[:space:]]*", "")
      sub(/[[:space:]]*#.*$/, "")
      gsub(/^["'"'"']|["'"'"'][[:space:]]*$/, "")
      print
      exit
    }
  ' "$CONFIG_FILE" 2>/dev/null | tr -d '\r')
  [ -n "$val" ] && echo "$val"
}

# 读出所有顶层段名（每行一个），用于判断配置里到底配了什么
_top_sections() {
  [ -f "$CONFIG_FILE" ] || return 0
  awk '/^[^[:space:]#]/ { sub(/[[:space:]]*:.*$/, ""); if ($0 != "") print }' "$CONFIG_FILE" 2>/dev/null | tr -d '\r'
}

# 判断配置里是否存在某个顶层段
_has_section() {
  _top_sections | grep -qx "$1" 2>/dev/null
}

# 备份现有配置
backup_config() {
  [ -f "$CONFIG_FILE" ] || return 0
  mkdir -p "$BACKUP_DIR"
  local dest="$BACKUP_DIR/config.yml.$(date +%Y%m%d-%H%M%S)"
  cp -a "$CONFIG_FILE" "$dest"
  chmod 600 "$dest" 2>/dev/null || true
  ok "旧配置已备份 → $dest"
}

ensure_docker() {
  if docker_available; then
    ok "Docker 环境就绪: $(docker --version 2>/dev/null | head -1)"
    return
  fi
  warn "未检测到可用的 docker / docker compose 插件"
  if confirm "自动安装 Docker（get.docker.com 官方脚本）？" "Y"; then
    info "安装 Docker..."
    curl -fsSL https://get.docker.com | bash
    systemctl enable --now docker 2>/dev/null || true
    docker compose version >/dev/null 2>&1 || fail "docker compose 插件不可用，请手动安装后重跑"
    ok "Docker 安装完成"
  else
    fail "请先手动安装 Docker + compose 插件后重跑本脚本"
  fi
}

# ════════════════════════════════════════════════════════════════════
#  配置向导（写 config.yml + docker-compose.yml）
# ════════════════════════════════════════════════════════════════════
read_panel_credentials() {
  echo
  info "配置向导（面板信息可在 Xboard 后台查到）"
  hint "面板地址示例：https://panel.example.com"

  # 向导中途 Ctrl+D / stdin 关闭 → 干净退出，不要留半截配置
  read -r -p "面板地址: " PANEL_URL || fail "输入中断，已取消"
  PANEL_URL="${PANEL_URL%/}"
  [[ "$PANEL_URL" =~ ^https?:// ]] || fail "面板地址必须以 http:// 或 https:// 开头"

  echo
  echo "运行模式:"
  echo "  1) node    —— 单节点（面板里这台就是一个节点）"
  echo "  2) machine —— 整机模式（接管面板上绑定到这台机器的所有节点）"
  read -r -p "选择 [1/2] (默认 1): " MODE || fail "输入中断，已取消"
  MODE="${MODE:-1}"

  MACHINE_ID=""; NODE_ID=""; MACHINE_TOKEN=""; NODE_TOKEN=""
  if [ "$MODE" = "2" ]; then
    read -r -p "machine_id（面板 → 机器管理里的 ID）: " MACHINE_ID || fail "输入中断，已取消"
    [[ "$MACHINE_ID" =~ ^[0-9]+$ ]] && [ "$MACHINE_ID" -gt 0 ] || fail "machine_id 必须是正整数"
    read -r -s -p "machine token（机器令牌，输入不回显）: " MACHINE_TOKEN || fail "输入中断，已取消"; echo
    [ -n "$MACHINE_TOKEN" ] || fail "machine token 不能为空"
    MODE_STR="machine"
  else
    read -r -p "node_id（面板 → 节点列表里的 ID）: " NODE_ID || fail "输入中断，已取消"
    [[ "$NODE_ID" =~ ^[0-9]+$ ]] && [ "$NODE_ID" -gt 0 ] || fail "node_id 必须是正整数"
    read -r -s -p "server_token（节点通讯密钥，输入不回显）: " NODE_TOKEN || fail "输入中断，已取消"; echo
    [ -n "$NODE_TOKEN" ] || fail "server_token 不能为空"
    MODE_STR="node"
  fi

  read -r -p "内核类型 [singbox/xray] (默认 singbox): " KERNEL || fail "输入中断，已取消"
  KERNEL="${KERNEL:-singbox}"
  [[ "$KERNEL" =~ ^(singbox|xray)$ ]] || fail "内核只支持 singbox 或 xray"

  AUDIT_ENABLED="false"
  if [ "$KERNEL" = "singbox" ]; then
    if confirm "启用访问审计（需面板已安装 AccessAudit 插件 v2.1+）？" "Y"; then
      AUDIT_ENABLED="true"
    fi
  else
    warn "xray 内核不支持内嵌审计；如需审计请用 AccessAudit 插件自带的 audit-agent.py（旁路 tail access log）"
  fi

  read -r -p "日志级别 [info/debug/warn/error] (默认 info): " LOG_LEVEL
  LOG_LEVEL="${LOG_LEVEL:-info}"

  # 审计全量上报（只在启用审计时询问）
  REPORT_ALL="false"
  if [ "$AUDIT_ENABLED" = "true" ]; then
    echo
    hint "report_all=false 时只上报「命中规则」的连接；面板上没有启用规则 = 一条都不会上报。"
    hint "需要面板看到全部连接日志则选 y。"
    if confirm "全量上报所有连接（report_all）？" "n"; then
      REPORT_ALL="true"
    fi
  fi
}

write_config_files() {
  mkdir -p "$INSTALL_DIR"

  if [ "$MODE_STR" = "machine" ]; then
    PANEL_BLOCK=$(cat <<EOF
panel:
  url: "$PANEL_URL"
machine:
  machine_id: $MACHINE_ID
  token: "$MACHINE_TOKEN"
EOF
)
  else
    PANEL_BLOCK=$(cat <<EOF
panel:
  url: "$PANEL_URL"
  token: "$NODE_TOKEN"
  node_id: $NODE_ID
EOF
)
  fi

  cat > "$CONFIG_FILE" <<EOF
# Generated by tx-node deploy.sh ($(date '+%Y-%m-%d %H:%M:%S'))
# 重新生成请执行: txnode  → 选择「重新配置」
$PANEL_BLOCK

kernel:
  type: "$KERNEL"

log:
  level: "$LOG_LEVEL"

# tx-node 访问审计（sing-box 内核）。删除本段或 enabled: false 即关闭。
audit:
  enabled: $AUDIT_ENABLED
  report_all: $REPORT_ALL
EOF
  chmod 600 "$CONFIG_FILE"
  ok "配置已写入 $CONFIG_FILE（权限 600）"

  cat > "$COMPOSE_FILE" <<EOF
services:
  tx-node:
    image: $IMAGE
    container_name: $APP_NAME
    restart: always
    network_mode: host
    volumes:
      - $CONFIG_FILE:/etc/xboard-node/config.yml:ro
EOF
  ok "compose 文件已写入 $COMPOSE_FILE"
}

# ════════════════════════════════════════════════════════════════════
#  动作：安装 / 重装
# ════════════════════════════════════════════════════════════════════
do_install() {
  ensure_docker
  read_panel_credentials
  backup_config
  write_config_files

  info "拉取镜像（首次较慢）..."
  dc pull || fail "镜像拉取失败。若是私有包未授权，请先 docker login ghcr.io；网络问题可配置镜像加速后重跑"

  info "启动..."
  dc up -d

  sleep 5
  if ! docker ps --format '{{.Names}} {{.Status}}' 2>/dev/null | grep -q "$APP_NAME.*Up"; then
    warn "容器未正常运行，最近日志："
    show_logs 20
    fail "启动失败，请根据上方日志排查"
  fi
  ok "容器运行中"

  if [ "$AUDIT_ENABLED" = "true" ]; then
    sleep 5
    if docker logs "$APP_NAME" 2>&1 | grep -q "audit reporter enabled"; then
      ok "审计模块已启用并连接面板"
      if [ "$REPORT_ALL" = "false" ]; then
        warn "当前 report_all=false —— 需要在面板配置启用规则，否则不会上报任何数据"
      fi
    else
      warn "未在日志中看到 'audit reporter enabled'，请检查日志"
    fi
  fi

  install_cli_link

  echo
  echo -e "${BOLD}== 部署完成 ==${NC}"
  hint "随时执行 ${BOLD}txnode${NC} 进入运维面板"
}

# 把本脚本软链为 txnode 命令，方便后续进面板
install_cli_link() {
  if [ -n "$SELF_PATH" ] && [ -f "$SELF_PATH" ]; then
    chmod +x "$SELF_PATH" 2>/dev/null || true
    ln -sf "$SELF_PATH" "$CLI_LINK" 2>/dev/null && \
      ok "已安装快捷命令: ${BOLD}txnode${NC}" || \
      hint "软链失败，可继续用: bash $SELF_PATH"
    # 顺便把脚本副本放进安装目录，避免用户删了源码目录后命令失效
    cp -f "$SELF_PATH" "$INSTALL_DIR/deploy.sh" 2>/dev/null || true
    chmod +x "$INSTALL_DIR/deploy.sh" 2>/dev/null || true
  fi
}

# ════════════════════════════════════════════════════════════════════
#  动作：状态
# ════════════════════════════════════════════════════════════════════
do_status() {
  detect_deploy_mode
  title "tx-node 运行状态"

  if ! is_installed; then
    warn "未检测到已部署的 tx-node"
    hint "执行本脚本选择「安装」开始部署"
    return 0
  fi

  echo -e "  部署模式: ${BOLD}${DEPLOY_MODE}${NC}"

  case "$DEPLOY_MODE" in
    docker)
      local st; st=$(container_state)
      local st_c
      case "$st" in
        running) st_c="${GREEN}运行中${NC}" ;;
        exited)  st_c="${RED}已停止${NC}" ;;
        *)       st_c="${YELLOW}${st}${NC}" ;;
      esac
      echo -e "  容器状态: ${st_c}"
      # 镜像与启动时间
      local img started
      img=$(docker inspect -f '{{.Config.Image}}' "$APP_NAME" 2>/dev/null || echo "-")
      started=$(docker inspect -f '{{.State.StartedAt}}' "$APP_NAME" 2>/dev/null | cut -d. -f1 || echo "-")
      echo "  镜像:     $img"
      echo "  启动于:   $started"
      # 容器内版本
      local ver
      ver=$(docker exec "$APP_NAME" /usr/local/bin/xboard-node -v 2>/dev/null || echo "unknown")
      echo "  版本:     $ver"
      ;;
    systemd)
      local sst; sst=$(svc_state)
      local sst_c
      case "$sst" in
        active)   sst_c="${GREEN}运行中${NC}" ;;
        failed)   sst_c="${RED}失败${NC}" ;;
        inactive) sst_c="${YELLOW}已停止${NC}" ;;
        *)        sst_c="${YELLOW}${sst}${NC}" ;;
      esac
      echo -e "  服务状态: ${sst_c}"
      local sver="unknown"
      if [ -x "$SB_BINARY" ]; then
        sver=$("$SB_BINARY" -v 2>/dev/null || echo "unknown")
      fi
      echo "  二进制:   $SB_BINARY"
      echo "  版本:     $sver"
      ;;
  esac

  # 配置摘要
  if [ -f "$CONFIG_FILE" ]; then
    echo
    echo -e "  ${BOLD}配置摘要${NC} ($CONFIG_FILE)"
    local url mid nid kern aud rpt hlvl
    url=$(_sec_get panel url || true)
    nid=$(_sec_get panel node_id || true)
    mid=$(_sec_get machine machine_id || true)
    kern=$(_sec_get kernel type || true)
    aud=$(_sec_get audit enabled || true)
    rpt=$(_sec_get audit report_all || true)
    hlvl=$(_sec_get log level || true)

    [ -n "$url" ]  && echo "    面板地址:   $url"
    [ -n "$nid" ]  && echo "    node_id:    $nid"
    [ -n "$mid" ]  && echo "    machine_id: $mid"
    [ -n "$kern" ] && echo "    内核:       $kern"
    [ -n "$hlvl" ] && echo "    日志级别:   $hlvl"
    if [ -n "$aud" ]; then
      if [ "$aud" = "true" ]; then
        echo -e "    访问审计:   ${GREEN}已启用${NC} (report_all=${rpt:-false})"
        if [ "${rpt:-false}" = "false" ]; then
          hint "report_all=false：需在面板配置启用规则，否则不会上报"
        fi
      else
        echo "    访问审计:   未启用"
      fi
    fi
    # 多节点模式提示
    if grep -qE '^nodes:' "$CONFIG_FILE" 2>/dev/null; then
      local ncount
      ncount=$(grep -cE '^[[:space:]]*-[[:space:]]*node_id:' "$CONFIG_FILE" 2>/dev/null || echo 0)
      echo -e "    多节点:     ${BOLD}${ncount}${NC} 个（nodes 段）"
    fi
    if grep -qE '^machine:' "$CONFIG_FILE" 2>/dev/null; then
      echo -e "    机器模式:   ${BOLD}是${NC}（接管该机器绑定的所有节点）"
    fi
  else
    warn "配置文件不存在: $CONFIG_FILE"
  fi

  # 健康检查
  echo
  local hport
  hport=$(grep -m1 -E '^health_port:' "$CONFIG_FILE" 2>/dev/null | sed -E 's/.*health_port:[[:space:]]*//' | tr -cd '0-9' || true)
  hport="${hport:-65530}"
  if [ "$hport" -gt 0 ] 2>/dev/null; then
    if curl -fsS "http://127.0.0.1:${hport}/healthz" >/dev/null 2>&1; then
      echo -e "  健康检查: ${GREEN}正常${NC} (127.0.0.1:${hport})"
    else
      echo -e "  健康检查: ${YELLOW}无响应${NC} (127.0.0.1:${hport})"
      hint "端口未监听可能是因为配置里未开启 health_port"
    fi
  fi
}

# ════════════════════════════════════════════════════════════════════
#  动作：启停 / 重启
# ════════════════════════════════════════════════════════════════════
do_start() {
  detect_deploy_mode
  ! is_installed && fail "未检测到已部署的 tx-node"
  info "启动..."
  case "$DEPLOY_MODE" in
    docker)  dc up -d ;;
    systemd) svc_ctrl start ;;
  esac
  sleep 3
  ok "已启动"; do_status
}

do_stop() {
  detect_deploy_mode
  ! is_installed && fail "未检测到已部署的 tx-node"
  if ! confirm "确认停止 tx-node？（节点将下线，面板会显示离线）" "n"; then
    info "已取消"; return 0
  fi
  info "停止..."
  case "$DEPLOY_MODE" in
    docker)  dc stop ;;
    systemd) svc_ctrl stop ;;
  esac
  ok "已停止"
}

do_restart() {
  detect_deploy_mode
  ! is_installed && fail "未检测到已部署的 tx-node"
  info "重启..."
  case "$DEPLOY_MODE" in
    docker)  dc restart ;;
    systemd) svc_ctrl restart ;;
  esac
  sleep 3
  ok "已重启"; do_status
}

# 暂停 = 停止 + 禁止开机自启（区别于单纯停止）
do_pause() {
  detect_deploy_mode
  ! is_installed && fail "未检测到已部署的 tx-node"
  echo
  info "「暂停」= 停止服务 且 取消开机自启"
  hint "「停止」只是本次停掉，重启机器后仍会自动拉起。"
  if ! confirm "确认暂停 tx-node？" "n"; then
    info "已取消"; return 0
  fi
  case "$DEPLOY_MODE" in
    docker)
      dc stop
      # compose 里 restart: always 会让 docker 恢复时自动启动；改文件最稳妥。
      # 要同时兼容 restart: always / "always" / 'always' 三种写法。
      if grep -qE 'restart:[[:space:]]*["'"'"']?always["'"'"']?' "$COMPOSE_FILE" 2>/dev/null; then
        sed -i -E 's/restart:[[:space:]]*["'"'"']?always["'"'"']?/restart: "no"/' "$COMPOSE_FILE"
        ok "已将 compose 的 restart 策略改为 \"no\"（随系统自动启动已关闭）"
      else
        hint "compose 里未发现 restart: always，跳过自启策略改写"
      fi
      ;;
    systemd)
      svc_ctrl stop
      svc_ctrl disable
      ok "服务已停止并取消开机自启"
      ;;
  esac
  ok "已暂停"
  hint "恢复请用菜单里的「启动」（会自动恢复自启策略）"
}

# 启动时恢复被 do_pause 改掉的策略
restore_autostart() {
  # 自行探测：不依赖调用方是否已经填过 DEPLOY_MODE
  detect_deploy_mode
  case "$DEPLOY_MODE" in
    docker)
      if grep -qE 'restart:[[:space:]]*["'"'"']?no["'"'"']?' "$COMPOSE_FILE" 2>/dev/null; then
        sed -i -E 's/restart:[[:space:]]*["'"'"']?no["'"'"']?/restart: always/' "$COMPOSE_FILE"
        info "已恢复 compose 的 restart: always"
        dc up -d >/dev/null 2>&1 || true
      fi
      ;;
    systemd)
      svc_ctrl enable >/dev/null 2>&1 || true
      ;;
  esac
}

# ════════════════════════════════════════════════════════════════════
#  动作：升级
# ════════════════════════════════════════════════════════════════════
do_upgrade() {
  detect_deploy_mode
  ! is_installed && fail "未检测到已部署的 tx-node，请先安装"

  case "$DEPLOY_MODE" in
    docker)
      info "当前镜像: $(docker inspect -f '{{.Config.Image}}' "$APP_NAME" 2>/dev/null || echo '-')"
      info "拉取最新镜像..."
      dc pull || fail "镜像拉取失败"
      info "重建容器..."
      dc up -d
      sleep 5
      if docker ps --format '{{.Names}} {{.Status}}' 2>/dev/null | grep -q "$APP_NAME.*Up"; then
        ok "升级完成，容器运行中"
      else
        warn "容器未正常运行，最近日志："
        show_logs 20
        fail "升级后启动失败"
      fi
      ;;
    systemd)
      if [ -x "$XBCTL_PATH" ]; then
        info "调用 xbctl upgrade ..."
        "$XBCTL_PATH" upgrade || fail "xbctl upgrade 失败"
        ok "升级完成"
      else
        fail "未找到 $XBCTL_PATH，无法升级 systemd 部署"
      fi
      ;;
  esac

  # 回收旧镜像（dangling）
  if [ "$DEPLOY_MODE" = "docker" ]; then
    local reclaimed
    reclaimed=$(docker image prune -f 2>/dev/null | tail -1 || true)
    [ -n "$reclaimed" ] && hint "镜像清理: $reclaimed"
  fi
}

# ════════════════════════════════════════════════════════════════════
#  动作：改配置
# ════════════════════════════════════════════════════════════════════
do_reconfigure() {
  detect_deploy_mode
  if [ "$DEPLOY_MODE" = "systemd" ]; then
    warn "当前是 systemd 部署，本脚本的配置向导只写 docker 布局"
    hint "请用: ${BOLD}xbctl bind add-node${NC} / ${BOLD}xbctl bind add-machine${NC} 增删节点"
    hint "或直接编辑 $CONFIG_FILE 后 systemctl restart $SERVICE_NAME"
    return 0
  fi

  echo
  echo "  1) 用向导重新生成配置（覆盖 config.yml）"
  echo "  2) 手动编辑 config.yml（$EDITOR）"
  echo "  3) 仅修改日志级别"
  echo "  4) 开关访问审计 / report_all"
  echo "  5) 返回"
  read -r -p "选择 [1-5]: " c || return 0
  case "$c" in
    1)
      backup_config
      read_panel_credentials
      local prev_mode="$DEPLOY_MODE"
      write_config_files
      DEPLOY_MODE="$prev_mode"
      do_restart
      ;;
    2)
      local ed="${EDITOR:-vi}"
      command -v "$ed" >/dev/null 2>&1 || ed="vi"
      "$ed" "$CONFIG_FILE"
      if confirm "配置已保存，现在重启生效？" "Y"; then do_restart; fi
      ;;
    3)
      local nl
      read -r -p "新日志级别 [info/debug/warn/error]: " nl
      [[ "$nl" =~ ^(info|debug|warn|error)$ ]] || fail "日志级别只支持 info/debug/warn/error"
      backup_config
      # 只替换顶层 log.level，不动其它
      if grep -qE '^[[:space:]]*level:' "$CONFIG_FILE"; then
        sed -i -E "0,/^[[:space:]]*level:/s//  level: \"$nl\"/" "$CONFIG_FILE"
      else
        printf '\nlog:\n  level: "%s"\n' "$nl" >> "$CONFIG_FILE"
      fi
      ok "日志级别已改为 $nl"
      confirm "立即重启生效？" "Y" && do_restart || hint "稍后重启生效"
      ;;
    4)
      toggle_audit
      ;;
    *) return 0 ;;
  esac
}

toggle_audit() {
  local aud rpt new_aud new_rpt
  aud=$(grep -A1 -E '^audit:' "$CONFIG_FILE" 2>/dev/null | grep -m1 -E 'enabled:' | sed -E 's/.*enabled:[[:space:]]*//' | tr -d '\r' || echo "false")
  rpt=$(grep -m1 -E '^[[:space:]]*report_all:' "$CONFIG_FILE" 2>/dev/null | sed -E 's/.*report_all:[[:space:]]*//' | tr -d '\r' || echo "false")
  echo
  echo "  当前访问审计: enabled=${aud:-false}  report_all=${rpt:-false}"
  echo "  1) 开启审计 (enabled=true)"
  echo "  2) 关闭审计 (enabled=false)"
  echo "  3) 切换 report_all（全量/仅命中）"
  echo "  4) 返回"
  read -r -p "选择 [1-4]: " c || return 0
  case "$c" in
    1) new_aud="true" ;;
    2) new_aud="false" ;;
    3)
      if [ "${rpt:-false}" = "true" ]; then new_rpt="false"; else new_rpt="true"; fi
      ;;
    *) return 0 ;;
  esac

  backup_config
  if [ -n "${new_aud:-}" ]; then
    if grep -qE '^audit:' "$CONFIG_FILE"; then
      sed -i -E "0,/^[[:space:]]*enabled:/s//  enabled: $new_aud/" "/dev/null" 2>/dev/null || true
      # 精确替换 audit 段内的 enabled（用 awk 限定范围，避免误改 panel 段的字段）
      awk -v v="$new_aud" '
        /^audit:/ {inaudit=1}
        inaudit && /^[[:space:]]*enabled:/ && !done {sub(/enabled:.*/, "enabled: " v); done=1}
        /^[^[:space:]#]/ && !/^audit:/ {inaudit=0}
        {print}
      ' "$CONFIG_FILE" > "$CONFIG_FILE.tmp" && mv "$CONFIG_FILE.tmp" "$CONFIG_FILE"
      ok "audit.enabled → $new_aud"
    else
      printf '\naudit:\n  enabled: %s\n  report_all: false\n' "$new_aud" >> "$CONFIG_FILE"
      ok "已追加 audit 段 (enabled=$new_aud)"
    fi
  fi
  if [ -n "${new_rpt:-}" ]; then
    if grep -qE '^[[:space:]]*report_all:' "$CONFIG_FILE"; then
      awk -v v="$new_rpt" '
        /^audit:/ {inaudit=1}
        inaudit && /^[[:space:]]*report_all:/ && !done {sub(/report_all:.*/, "report_all: " v); done=1}
        /^[^[:space:]#]/ && !/^audit:/ {inaudit=0}
        {print}
      ' "$CONFIG_FILE" > "$CONFIG_FILE.tmp" && mv "$CONFIG_FILE.tmp" "$CONFIG_FILE"
    else
      awk -v v="$new_rpt" '
        /^audit:/ {inaudit=1}
        inaudit && /^[[:space:]]*enabled:/ && !done {print; print "  report_all: " v; done=1; next}
        {print}
      ' "$CONFIG_FILE" > "$CONFIG_FILE.tmp" && mv "$CONFIG_FILE.tmp" "$CONFIG_FILE"
    fi
    chmod 600 "$CONFIG_FILE" 2>/dev/null || true
    ok "audit.report_all → $new_rpt"
    [ "$new_rpt" = "false" ] && hint "report_all=false 时需在面板配置启用规则，否则不上报任何数据"
  fi
  confirm "立即重启生效？" "Y" && do_restart || hint "稍后重启生效"
}

# 配置校验：语法层面（YAML 缩进/引号）与必填字段
do_validate() {
  title "配置校验"
  if [ ! -f "$CONFIG_FILE" ]; then
    warn "配置文件不存在: $CONFIG_FILE"
    return 0
  fi
  local errs=0

  # 1) 区段感知取值，避免 panel / machine / nodes 之间串味
  local url ptok mtok nid mid
  url=$(_sec_get panel url || true)
  ptok=$(_sec_get panel token || true)
  mtok=$(_sec_get machine token || true)
  nid=$(_sec_get panel node_id || true)
  mid=$(_sec_get machine machine_id || true)
  # token 也可能写在 token_env 里（不落盘明文）
  local ptenv mtenv
  ptenv=$(_sec_get panel token_env || true)
  mtenv=$(_sec_get machine token_env || true)

  local is_machine=no
  _has_section machine && is_machine=yes

  # 2) panel.url 必填（machine 模式同样需要 url）
  [ -n "$url" ] || { warn "缺少 panel.url"; errs=$((errs+1)); }

  # 3) token：至少一处（明文或 token_env）
  if [ -z "$ptok" ] && [ -z "$mtok" ] && [ -z "$ptenv" ] && [ -z "$mtenv" ]; then
    warn "缺少 token（panel.token / machine.token / *_env 至少要有一个）"; errs=$((errs+1))
  fi
  # 明文与 token_env 同时给属于歧义
  if [ -n "$ptok" ] && [ -n "$ptenv" ]; then
    warn "panel.token 与 panel.token_env 同时存在，配置有歧义（token_env 优先）"; errs=$((errs+1))
  fi
  if [ -n "$mtok" ] && [ -n "$mtenv" ]; then
    warn "machine.token 与 machine.token_env 同时存在，配置有歧义（token_env 优先）"; errs=$((errs+1))
  fi

  # 4) 节点与机器：二选一（machine 段存在 = 机器模式，由节点动态发现，无需 node_id）
  if [ "$is_machine" = "yes" ]; then
    [ -n "$mid" ] || { warn "machine 段存在但缺少 machine_id"; errs=$((errs+1)); }
    [ -n "$nid" ] && warn "机器模式下 panel.node_id 会被忽略（节点由面板动态下发）"
  else
    if [ -z "$nid" ]; then
      warn "缺少 panel.node_id（单节点模式必填；多节点请改用 machine 段）"; errs=$((errs+1))
    fi
  fi

  # 5) URL 形状
  if [ -n "$url" ] && ! [[ "$url" =~ ^https?:// ]]; then
    warn "panel.url 必须以 http:// 或 https:// 开头（当前: $url）"; errs=$((errs+1))
  fi

  # 6) 内核取值：Go 侧枚举是 singbox / xray，"sing-box" 是官方产品名不是配置值
  local kern
  kern=$(_sec_get kernel type || true)
  if [ -n "$kern" ]; then
    case "$kern" in
      singbox|xray) ;;
      sing-box) warn "kernel.type 应写 singbox（当前: sing-box）；sing-box 是产品名，配置值不带连字符"; errs=$((errs+1)) ;;
      *) warn "kernel.type 只支持 singbox / xray（当前: $kern）"; errs=$((errs+1)) ;;
    esac
  else
    warn "缺少 kernel.type（默认按 singbox 处理，建议显式写出）"
  fi

  # 7) TAB 字符（YAML 不允许缩进用 TAB）
  if grep -qP '^\t' "$CONFIG_FILE" 2>/dev/null; then
    warn "配置中存在 TAB 缩进，YAML 要求使用空格"; errs=$((errs+1))
  fi

  # 8) audit 段一致性（内嵌审计只在 singbox 内核下生效）
  local aud rpt
  aud=$(_sec_get audit enabled || true)
  rpt=$(_sec_get audit report_all || true)
  if [ "$aud" = "true" ]; then
    if [ -n "$kern" ] && [ "$kern" != "singbox" ]; then
      warn "audit.enabled=true 但内核是 $kern —— 内嵌审计仅在 singbox 内核下工作"
      hint "xray 请用 AccessAudit 插件自带的 audit-agent.py 旁路"
      errs=$((errs+1))
    fi
    if [ "${rpt:-false}" != "true" ]; then
      warn "audit.enabled=true 且 report_all=false —— 只上报命中规则的连接"
      hint "面板上若没有启用规则，将不会上报任何数据（这是最常见的「开了没数据」原因）"
      hint "要全量日志请把 report_all 改为 true"
    fi
    if [ -z "$aud" ] || [ -z "$kern" ]; then
      hint "audit 段存在但取值读不全，请检查缩进是否规范"
    fi
  fi

  echo
  if [ "$errs" -eq 0 ]; then
    ok "校验通过，未发现问题"
  else
    warn "发现 $errs 个问题，请修正后重启"
  fi

  # 6) 额外：如果容器在跑，检查日志里有无明显错误
  detect_deploy_mode
  if [ "$DEPLOY_MODE" = "docker" ] && [ "$(container_state)" = "running" ]; then
    echo
    info "最近日志中的告警/错误（最多 10 条）："
    docker logs --tail 200 "$APP_NAME" 2>&1 \
      | grep -iE 'error|warn|failed|refused' | tail -10 || hint "（无）"
  fi
}

# ════════════════════════════════════════════════════════════════════
#  动作：备份 / 恢复
# ════════════════════════════════════════════════════════════════════
do_backup() {
  if [ ! -f "$CONFIG_FILE" ]; then
    warn "没有可备份的配置"
    return 0
  fi
  mkdir -p "$BACKUP_DIR"
  local stamp dest
  stamp=$(date +%Y%m%d-%H%M%S)
  dest="$BACKUP_DIR/backup-$stamp.tar.gz"
  tar -czf "$dest" -C "$INSTALL_DIR" config.yml docker-compose.yml 2>/dev/null \
    || tar -czf "$dest" -C "$INSTALL_DIR" config.yml
  chmod 600 "$dest"
  ok "备份完成 → $dest"
  list_backups
}

list_backups() {
  [ -d "$BACKUP_DIR" ] || return 0
  local files
  files=$(ls -1t "$BACKUP_DIR" 2>/dev/null || true)
  [ -z "$files" ] && { hint "（暂无备份）"; return 0; }
  echo
  echo "  现有备份："
  local i=0
  while IFS= read -r f; do
    [ -z "$f" ] && continue
    i=$((i+1))
    printf "    %2d) %s\n" "$i" "$f"
  done <<< "$files"
}

do_restore() {
  [ -d "$BACKUP_DIR" ] || { warn "没有备份目录"; return 0; }
  local files
  mapfile -t files < <(ls -1t "$BACKUP_DIR" 2>/dev/null || true)
  if [ ${#files[@]} -eq 0 ]; then
    warn "没有可用备份"; return 0
  fi
  title "从备份恢复"
  local i=1
  for f in "${files[@]}"; do
    echo "    $i) $f"
    i=$((i+1))
  done
  read -r -p "  选择要恢复的备份编号 [1-${#files[@]}]: " sel
  [[ "$sel" =~ ^[0-9]+$ ]] && [ "$sel" -ge 1 ] && [ "$sel" -le ${#files[@]} ] || fail "无效编号"
  local chosen="${files[$((sel-1))]}"
  if ! confirm "确认用 $chosen 覆盖当前配置？" "n"; then
    info "已取消"; return 0
  fi
  backup_config
  if [[ "$chosen" == *.tar.gz ]]; then
    tar -xzf "$BACKUP_DIR/$chosen" -C "$INSTALL_DIR"
  else
    cp -a "$BACKUP_DIR/$chosen" "$CONFIG_FILE"
  fi
  chmod 600 "$CONFIG_FILE" 2>/dev/null || true
  ok "已恢复 $chosen"
  detect_deploy_mode
  if is_installed; then
    confirm "立即重启生效？" "Y" && do_restart || hint "稍后重启生效"
  fi
}

# ════════════════════════════════════════════════════════════════════
#  动作：多节点 / 多机器（基于 nodes 段）
# ════════════════════════════════════════════════════════════════════
# 读取 config 里 nodes: 段的现状
nodes_summary() {
  [ -f "$CONFIG_FILE" ] || return 0
  if ! grep -qE '^nodes:' "$CONFIG_FILE" 2>/dev/null; then
    hint "（当前是单节点/machine 模式，未使用 nodes 段）"
    return 0
  fi
  echo "  当前 nodes 段内容："
  awk '/^nodes:/{f=1} f&&/^[^[:space:]#]/&&!/^nodes:/{f=0} f{print "    "$0}' "$CONFIG_FILE"
}

do_add_node() {
  detect_deploy_mode
  if [ "$DEPLOY_MODE" = "systemd" ] && [ -x "$XBCTL_PATH" ]; then
    info "systemd 部署：调用 xbctl bind add-node"
    local url tok nid ntype
    read -r -p "面板地址: " url
    read -r -s -p "server token（不回显）: " tok; echo
    read -r -p "node_id: " nid
    [[ "$nid" =~ ^[0-9]+$ ]] || fail "node_id 必须是正整数"
    read -r -p "内核 [singbox/xray] (默认 singbox): " ntype
    ntype="${ntype:-singbox}"
    "$XBCTL_PATH" bind add-node --panel-url "$url" --token "$tok" --node-id "$nid" --kernel "$ntype" \
      || fail "xbctl bind add-node 失败"
    ok "已添加节点 $nid"
    return 0
  fi

  # docker 模式：往 config.yml 的 nodes 段追加
  [ -f "$CONFIG_FILE" ] || fail "配置文件不存在，请先安装"
  title "添加节点（多节点模式）"
  warn "加入 nodes 段后，panel.node_id 将被忽略，本进程会同时服务 nodes 段里的全部节点"
  hint "前提：这些节点与当前配置的 panel.url / token 相同"

  local nid ntype
  read -r -p "node_id（要新增的节点 ID）: " nid
  [[ "$nid" =~ ^[0-9]+$ ]] && [ "$nid" -gt 0 ] || fail "node_id 必须是正整数"

  # 去重
  if grep -qE "^[[:space:]]*-[[:space:]]*node_id:[[:space:]]*${nid}([[:space:]]|$)" "$CONFIG_FILE" 2>/dev/null; then
    warn "node_id ${nid} 已存在于 nodes 段"; return 0
  fi

  read -r -p "node_type（可留空，面板可自动识别）: " ntype

  backup_config
  # 确保存在 nodes: 段
  if ! grep -qE '^nodes:' "$CONFIG_FILE" 2>/dev/null; then
    printf '\n# 多节点：本进程同时服务以下节点（panel.node_id 被忽略）\nnodes:\n' >> "$CONFIG_FILE"
  fi
  {
    echo "  - node_id: $nid"
    [ -n "$ntype" ] && echo "    node_type: \"$ntype\""
  } >> "$CONFIG_FILE"
  chmod 600 "$CONFIG_FILE" 2>/dev/null || true
  ok "已添加 node_id=$nid 到 nodes 段"
  nodes_summary
  confirm "立即重启生效？" "Y" && do_restart || hint "稍后重启生效"
}

do_remove_node() {
  detect_deploy_mode
  [ -f "$CONFIG_FILE" ] || fail "配置文件不存在"
  if ! grep -qE '^nodes:' "$CONFIG_FILE" 2>/dev/null; then
    warn "当前没有 nodes 段（单节点模式）"
    hint "要改单节点的 node_id，请用「重新配置」"
    return 0
  fi
  title "移除节点"
  nodes_summary
  local nid
  read -r -p "  要移除的 node_id: " nid
  [[ "$nid" =~ ^[0-9]+$ ]] || fail "node_id 必须是正整数"
  if ! grep -qE "^[[:space:]]*-[[:space:]]*node_id:[[:space:]]*${nid}([[:space:]]|$)" "$CONFIG_FILE" 2>/dev/null; then
    warn "nodes 段中没有 node_id=$nid"; return 0
  fi
  if ! confirm "确认移除 node_id=$nid？" "n"; then info "已取消"; return 0; fi

  backup_config
  # 删除该 node 条目（含紧随其后的缩进子字段，直到下一个 - node_id 或段结束）
  awk -v target="$nid" '
    function is_entry(l) { return l ~ /^[[:space:]]*-[[:space:]]*node_id:/ }
    function is_top(l)   { return l ~ /^[^[:space:]#]/ }
    {
      if (is_entry($0)) {
        if (in_skip) in_skip=0
        n=$0; sub(/.*node_id:[[:space:]]*/, "", n); sub(/[^0-9].*$/, "", n)
        if (n == target) { in_skip=1; next }
      } else if (in_skip && is_top($0)) {
        in_skip=0
      }
      if (!in_skip) print
    }
  ' "$CONFIG_FILE" > "$CONFIG_FILE.tmp" && mv "$CONFIG_FILE.tmp" "$CONFIG_FILE"
  chmod 600 "$CONFIG_FILE" 2>/dev/null || true
  ok "已移除 node_id=$nid"
  nodes_summary
  confirm "立即重启生效？" "Y" && do_restart || hint "稍后重启生效"
}

do_machine_mode() {
  detect_deploy_mode
  title "机器模式设置"
  echo "  机器模式下，本进程通过 machine token 接管面板上绑定到该机器的【全部】节点。"
  echo "  优点：面板上加节点无需改本机配置。"
  echo
  echo "  1) 切换到机器模式（用 machine_id + 令牌重配）"
  echo "  2) 切回单节点模式"
  echo "  3) 返回"
  read -r -p "选择 [1-3]: " c
  case "$c" in
    1)
      [ "$DEPLOY_MODE" = "systemd" ] && {
        warn "systemd 部署请用: xbctl bind add-machine --panel-url URL --token TOKEN --machine-id ID"
        return 0
      }
      local url mid tok
      read -r -p "面板地址: " url
      url="${url%/}"
      [[ "$url" =~ ^https?:// ]] || fail "面板地址必须以 http:// 或 https:// 开头"
      read -r -p "machine_id: " mid
      [[ "$mid" =~ ^[0-9]+$ ]] && [ "$mid" -gt 0 ] || fail "machine_id 必须是正整数"
      read -r -s -p "machine token（不回显）: " tok; echo
      [ -n "$tok" ] || fail "machine token 不能为空"
      backup_config
      cat > "$CONFIG_FILE" <<EOF
# Generated by tx-node deploy.sh ($(date '+%Y-%m-%d %H:%M:%S'))
panel:
  url: "$url"
machine:
  machine_id: $mid
  token: "$tok"

kernel:
  type: "singbox"

log:
  level: "info"

audit:
  enabled: true
  report_all: false
EOF
      chmod 600 "$CONFIG_FILE"
      ok "已切换为机器模式 (machine_id=$mid)"
      confirm "立即重启生效？" "Y" && do_restart || hint "稍后重启生效"
      ;;
    2)
      if ! grep -qE '^machine:' "$CONFIG_FILE" 2>/dev/null; then
        warn "当前不是机器模式"; return 0
      fi
      info "切回单节点模式需要 node_id 与 server token，将走完整配置向导"
      do_reconfigure
      ;;
    *) return 0 ;;
  esac
}

# ════════════════════════════════════════════════════════════════════
#  动作：卸载 / 彻底清除
# ════════════════════════════════════════════════════════════════════
do_uninstall() {
  detect_deploy_mode
  ! is_installed && fail "未检测到已部署的 tx-node"

  title "卸载 tx-node（保留配置）"
  hint "容器/服务与命令会被移除，配置保留在 $INSTALL_DIR"
  hint "如需连配置一起删除，请用「彻底清除」"

  if ! confirm "确认卸载？" "n"; then info "已取消"; return 0; fi

  case "$DEPLOY_MODE" in
    docker)
      dc down 2>/dev/null || docker rm -f "$APP_NAME" 2>/dev/null || true
      # 停用 compose 但保留文件（重装时可直接复用）
      [ -f "$COMPOSE_FILE" ] && mv "$COMPOSE_FILE" "$COMPOSE_FILE.uninstalled" 2>/dev/null || true
      ;;
    systemd)
      svc_ctrl stop 2>/dev/null || true
      svc_ctrl disable 2>/dev/null || true
      rm -f "$SERVICE_PATH"
      systemctl daemon-reload || true
      rm -f "$SB_BINARY"
      ;;
  esac

  rm -f "$CLI_LINK" 2>/dev/null || true
  ok "已卸载，配置保留在 $INSTALL_DIR"
  hint "重新安装: bash $SELF_PATH install"
}

do_purge() {
  detect_deploy_mode
  title "彻底清除 tx-node"
  echo -e "${RED}  将删除以下内容：${NC}"
  echo "    - 容器 / systemd 服务"
  echo "    - 二进制 / compose / 配置 / 备份（$INSTALL_DIR）"
  echo "    - 拉取的镜像 $IMAGE"
  echo "    - 快捷命令 $CLI_LINK"
  if [ "$DEPLOY_MODE" = "none" ]; then
    warn "未检测到部署，但仍会清理残留文件与镜像"
  fi

  if ! confirm_typed " " "PURGE"; then
    info "已取消（输入不匹配）"; return 0
  fi

  case "$DEPLOY_MODE" in
    docker)
      dc down -v 2>/dev/null || docker rm -f "$APP_NAME" 2>/dev/null || true
      ;;
    systemd)
      svc_ctrl stop 2>/dev/null || true
      svc_ctrl disable 2>/dev/null || true
      rm -f "$SERVICE_PATH" "$SB_BINARY" "$XBCTL_PATH" /usr/bin/xbctl 2>/dev/null || true
      systemctl daemon-reload || true
      systemctl reset-failed "$SERVICE_NAME" 2>/dev/null || true
      ;;
  esac

  rm -f "$CLI_LINK" 2>/dev/null || true
  rm -rf "$INSTALL_DIR"
  ok "已删除 $INSTALL_DIR"

  # 删镜像（先确认没有其他容器在用）
  if command -v docker >/dev/null 2>&1; then
    if docker images -q "$IMAGE" >/dev/null 2>&1 && [ -n "$(docker images -q "$IMAGE" 2>/dev/null)" ]; then
      docker rmi "$IMAGE" >/dev/null 2>&1 && ok "已删除镜像 $IMAGE" \
        || warn "镜像删除失败（可能仍被其他容器引用）"
    fi
    # 清理同名旧镜像的悬空层
    docker image prune -f >/dev/null 2>&1 || true
  fi

  echo
  ok "彻底清除完成，系统已恢复干净状态"
  hint "如需重新部署: bash <(curl -fsSL https://raw.githubusercontent.com/PaiMonCai/TX-Node/main/deploy.sh)"
}

# ════════════════════════════════════════════════════════════════════
#  动作：健康检查 / 诊断
# ════════════════════════════════════════════════════════════════════
do_doctor() {
  detect_deploy_mode
  title "诊断"
  echo -e "  1) 部署模式: ${BOLD}${DEPLOY_MODE}${NC}"

  # Docker 环境
  if command -v docker >/dev/null 2>&1; then
    echo "  Docker: $(docker --version 2>/dev/null | head -1)"
    if docker compose version >/dev/null 2>&1; then
      echo "  compose: 可用"
    else
      warn "compose 插件不可用"
    fi
  else
    warn "未安装 docker"
  fi

  # 系统资源
  echo
  echo -e "  ${BOLD}系统${NC}"
  echo "    CPU 核数: $(nproc 2>/dev/null || echo '?')"
  if [ -r /proc/meminfo ]; then
    local mt ma
    mt=$(awk '/^MemTotal:/{print int($2/1024)}' /proc/meminfo 2>/dev/null)
    # 老内核没有 MemAvailable，退化用 MemFree
    ma=$(awk '/^MemAvailable:/{print int($2/1024)}' /proc/meminfo 2>/dev/null)
    [ -n "$ma" ] || ma=$(awk '/^MemFree:/{print int($2/1024)}' /proc/meminfo 2>/dev/null)
    if [ -n "$mt" ] && [ -n "$ma" ]; then
      echo "    内存: ${ma}MB 可用 / ${mt}MB 总计"
    elif [ -n "$mt" ]; then
      echo "    内存: ${mt}MB 总计"
    fi
  fi
  echo "    磁盘 ${INSTALL_DIR}: $(df -h "$INSTALL_DIR" 2>/dev/null | awk 'NR==2{print $4" 可用 / "$2" 总计 ("$5" 已用)"}' || echo '?')"

  # 端口占用（节点需要监听面板下发配置里的端口，这里只做提示）
  echo
  echo -e "  ${BOLD}网络${NC}"
  local panel_url
  panel_url=$(_sec_get panel url || true)
  if [ -n "$panel_url" ]; then
    echo "    面板地址: $panel_url"
    if curl -fsS -o /dev/null -m 8 "$panel_url" 2>/dev/null; then
      ok "    面板可达"
    else
      warn "    面板不可达（检查网络 / 域名解析 / 防火墙）"
    fi
  fi

  # 容器细节
  if [ "$DEPLOY_MODE" = "docker" ]; then
    echo
    echo -e "  ${BOLD}容器${NC}"
    echo "    状态: $(container_state)"
    local restarts
    restarts=$(docker inspect -f '{{.RestartCount}}' "$APP_NAME" 2>/dev/null || echo "?")
    echo "    重启次数: $restarts"
    [ "$restarts" != "0" ] && [ "$restarts" != "?" ] && warn "重启次数偏高，可能有崩溃循环，请查看日志"
  fi

  # 审计状态检查
  if [ "$DEPLOY_MODE" = "docker" ] && [ "$(container_state)" = "running" ]; then
    echo
    echo -e "  ${BOLD}审计模块${NC}"
    if docker logs "$APP_NAME" 2>&1 | grep -q "audit reporter enabled"; then
      ok "    已启用并连接面板"
      # 检查空规则告警（这个坑很常见）
      if docker logs "$APP_NAME" 2>&1 | grep -q "report_all=false"; then
        warn "    日志提示 report_all=false —— 若面板无启用规则则不会上报任何数据"
        hint "    详见 README「最常见的坑」一节"
      fi
      local rep
      rep=$(docker logs "$APP_NAME" 2>&1 | grep -c "audit: reported" || true)
      [ "${rep:-0}" -gt 0 ] && echo "    已成功上报批次: $rep" || hint "    尚未观察到成功上报"
    else
      hint "    未启用（或日志已滚动）"
    fi
  fi

  echo
  ok "诊断完成"
}

# ════════════════════════════════════════════════════════════════════
#  交互式主菜单
# ════════════════════════════════════════════════════════════════════
banner() {
  clear 2>/dev/null || true
  detect_deploy_mode
  echo -e "${BOLD}${CYAN}"
  cat <<'ASCII'
   ████████ ██   ██       ███    ██  ██████  ██████  ███████
      ██     ██ ██        ████   ██ ██    ██ ██   ██ ██
      ██      ███         ██ ██  ██ ██    ██ ██   ██ █████
      ██     ██ ██        ██  ██ ██ ██    ██ ██   ██ ██
      ██    ██   ██       ██   ████  ██████  ██████  ███████
ASCII
  echo -e "${NC}"
  local state_txt state_color
  case "$DEPLOY_MODE" in
    docker)
      local cst; cst=$(container_state)
      case "$cst" in
        running) state_color="$GREEN"; state_txt="运行中" ;;
        *)       state_color="$YELLOW"; state_txt="$cst" ;;
      esac
      echo -e "   状态: ${state_color}● ${state_txt}${NC}  ${DIM}(docker · $APP_NAME)${NC}"
      ;;
    systemd)
      local sst; sst=$(svc_state)
      case "$sst" in
        active) state_color="$GREEN"; state_txt="运行中" ;;
        *)      state_color="$YELLOW"; state_txt="$sst" ;;
      esac
      echo -e "   状态: ${state_color}● ${state_txt}${NC}  ${DIM}(systemd · $SERVICE_NAME)${NC}"
      ;;
    *)
      echo -e "   状态: ${YELLOW}● 未部署${NC}"
      ;;
  esac
  hr
}

menu() {
  while true; do
    banner
    echo
    echo -e "  ${BOLD}运维面板${NC}"
    echo
    if is_installed; then
      echo -e "   ${BOLD}1${NC}) 查看状态            ${DIM}运行状态 / 配置摘要 / 健康检查${NC}"
      echo -e "   ${BOLD}2${NC}) 查看日志            ${DIM}实时跟踪${NC}"
      echo -e "   ${BOLD}3${NC}) 重启                ${DIM}改完配置后用这个${NC}"
      echo -e "   ${BOLD}4${NC}) 启动 / 停止         ${DIM}子菜单${NC}"
      echo -e "   ${BOLD}5${NC}) 升级                ${DIM}拉取最新镜像并重建${NC}"
      echo -e "   ${BOLD}6${NC}) 修改配置            ${DIM}向导 / 手编 / 日志级别 / 审计开关${NC}"
      echo -e "   ${BOLD}7${NC}) 配置校验与诊断      ${DIM}排错用${NC}"
      echo -e "   ${BOLD}8${NC}) 节点与机器管理      ${DIM}多节点 / 机器模式${NC}"
      echo -e "   ${BOLD}9${NC}) 备份 / 恢复         ${DIM}配置备份与回滚${NC}"
      echo -e "  ${BOLD}10${NC}) 卸载                ${DIM}保留配置${NC}"
      echo -e "  ${BOLD}11${NC}) 彻底清除            ${RED}${DIM}删除全部数据（不可逆）${NC}"
    else
      echo -e "   ${BOLD}1${NC}) 安装 / 部署         ${DIM}交互式向导${NC}"
      echo -e "   ${BOLD}2${NC}) 从备份恢复         ${DIM}复用已有配置${NC}"
      echo -e "   ${BOLD}3${NC}) 诊断                ${DIM}检查环境${NC}"
    fi
    echo -e "   ${BOLD}0${NC}) 退出"
    echo
    # EOF（Ctrl+D / stdin 被关闭）时 read 返回非 0；不处理会变成死循环刷屏
    if ! read -r -p "  请选择: " opt; then
      echo; info "输入结束，退出"; exit 0
    fi
    opt="${opt//[[:space:]]/}"   # 容忍误输入的空格

    if ! is_installed; then
      case "$opt" in
        1) do_install; pause ;;
        2) do_restore; pause ;;
        3) do_doctor; pause ;;
        0) echo; info "再见"; exit 0 ;;
        *) warn "无效选项"; sleep 1 ;;
      esac
      continue
    fi

    case "$opt" in
      1) do_status; pause ;;
      2) show_logs "" ;;
      3) do_restart; pause ;;
      4) menu_power ;;
      5) do_upgrade; pause ;;
      6) do_reconfigure; pause ;;
      7) do_validate; pause ;;
      8) menu_nodes ;;
      9) menu_backup ;;
      10) do_uninstall; pause ;;
      11) do_purge; pause ;;
      0) echo; info "再见"; exit 0 ;;
      *) warn "无效选项"; sleep 1 ;;
    esac
  done
}

menu_power() {
  while true; do
    banner
    echo
    echo -e "  ${BOLD}启动 / 停止${NC}"
    echo
    echo -e "   1) 启动                    ${DIM}并恢复开机自启${NC}"
    echo -e "   2) 停止                    ${DIM}本次停掉，重启机器后仍会自启${NC}"
    echo -e "   3) 重启                    ${DIM}配置改动生效${NC}"
    echo -e "   4) 暂停                    ${DIM}停止 + 取消开机自启（长期下线）${NC}"
    echo -e "   0) 返回"
    echo
    read -r -p "  请选择: " c || return 0
    case "$c" in
      1) do_start; pause ;;
      2) do_stop; pause ;;
      3) do_restart; pause ;;
      4) do_pause; pause ;;
      0) return ;;
      *) warn "无效选项"; sleep 1 ;;
    esac
  done
}

menu_nodes() {
  while true; do
    banner
    echo
    echo -e "  ${BOLD}节点与机器管理${NC}"
    echo
    nodes_summary
    echo
    echo -e "   1) 添加节点              ${DIM}向 nodes 段追加一个 node_id${NC}"
    echo -e "   2) 移除节点              ${DIM}从 nodes 段删除${NC}"
    echo -e "   3) 机器模式设置          ${DIM}接管整机上绑定的所有节点${NC}"
    echo -e "   4) 查看当前配置摘要      ${DIM}含 nodes / machine 展开${NC}"
    echo -e "   0) 返回"
    echo
    read -r -p "  请选择: " c
    case "$c" in
      1) do_add_node; pause ;;
      2) do_remove_node; pause ;;
      3) do_machine_mode; pause ;;
      4) do_status; pause ;;
      0) return ;;
      *) warn "无效选项"; sleep 1 ;;
    esac
  done
}

menu_backup() {
  while true; do
    banner
    echo
    echo -e "  ${BOLD}备份 / 恢复${NC}"
    echo
    list_backups
    echo
    echo -e "   1) 立即备份              ${DIM}打包 config.yml + compose${NC}"
    echo -e "   2) 从备份恢复            ${DIM}覆盖当前配置${NC}"
    echo -e "   3) 查看备份列表 / 路径   ${DIM}$BACKUP_DIR${NC}"
    echo -e "   4) 清理旧备份            ${DIM}保留最近 10 份${NC}"
    echo -e "   0) 返回"
    echo
    read -r -p "  请选择: " c
    case "$c" in
      1) do_backup; pause ;;
      2) do_restore; pause ;;
      3) title "备份列表"; list_backups; pause ;;
      4) prune_backups; pause ;;
      0) return ;;
      *) warn "无效选项"; sleep 1 ;;
    esac
  done
}

prune_backups() {
  [ -d "$BACKUP_DIR" ] || { warn "没有备份目录"; return 0; }
  local files count
  mapfile -t files < <(ls -1t "$BACKUP_DIR" 2>/dev/null || true)
  count=${#files[@]}
  if [ "$count" -le 10 ]; then
    hint "备份数量 $count ≤ 10，无需清理"
    return 0
  fi
  info "共 $count 份备份，将保留最近 10 份"
  local i=10
  while [ "$i" -lt "$count" ]; do
    rm -f "$BACKUP_DIR/${files[$i]}" 2>/dev/null || true
    i=$((i+1))
  done
  ok "已清理 $((count-10)) 份旧备份"
}

# ════════════════════════════════════════════════════════════════════
#  非交互 CLI 入口
# ════════════════════════════════════════════════════════════════════
usage() {
  cat <<'HELP'

  tx-node 部署与运维脚本

  用法:
    bash deploy.sh              进入交互式运维面板（推荐）
    bash deploy.sh <命令>       非交互执行单个命令

  命令:
    install        安装 / 重新部署（交互式向导）
    upgrade        升级到最新镜像并重建
    status         查看运行状态与配置摘要
    start          启动
    stop           停止
    restart        重启
    pause          暂停（停止 + 取消开机自启）
    logs           查看实时日志
    reconfigure    修改配置
    validate       配置校验
    doctor         环境与运行诊断
    backup         备份当前配置
    restore        从备份恢复
    uninstall      卸载（保留配置）
    purge          彻底清除（删除配置、镜像，不可逆）
    help           显示本帮助

  示例:
    bash deploy.sh                       # 进面板
    bash deploy.sh install               # 直接安装
    bash deploy.sh upgrade               # 直接升级
    bash deploy.sh uninstall             # 卸载

  装好后可直接用快捷命令:
    txnode                               # 进运维面板

HELP
}

main() {
  local action="${1:-}"

  if [ -z "$action" ]; then
    # 无参数 → 交互面板
    [ "$(id -u)" -eq 0 ] || fail "请用 root 运行（或 sudo bash $0）"
    [ -d /etc ] || fail "仅支持 Linux"
    menu
    exit 0
  fi

  case "$action" in
    help|-h|--help) usage; exit 0 ;;
  esac

  shift || true

  # status/doctor 只读，但仍需 root 才能读配置与 systemd
  [ "$(id -u)" -eq 0 ] || fail "请用 root 运行（或 sudo bash $0 $action）"
  [ -d /etc ] || fail "仅支持 Linux"

  case "$action" in
    install)     do_install ;;
    upgrade)     do_upgrade ;;
    status)      do_status ;;
    start)       do_start ;;
    stop)        do_stop ;;
    restart)     do_restart ;;
    pause)       do_pause ;;
    logs|log)    detect_deploy_mode; show_logs "" ;;
    reconfigure) do_reconfigure ;;
    validate)    do_validate ;;
    doctor)      do_doctor ;;
    backup)      do_backup ;;
    restore)     do_restore ;;
    uninstall)   do_uninstall ;;
    purge)       do_purge ;;
    *)
      warn "未知命令: $action"
      usage
      exit 1
      ;;
  esac
}

# 仅在被直接执行时运行 main；被 source 时只加载函数定义（便于测试与复用）
if [ "${BASH_SOURCE[0]:-$0}" = "$0" ]; then
  main "$@"
fi
