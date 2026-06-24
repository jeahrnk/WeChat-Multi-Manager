#!/bin/zsh
# =============================================================================
#  WeChat Multi Manager  v1.6.2
#  支持 macOS 13+，Apple Silicon / Intel 均可
#
#  功能：新建 / 升级 / 修复 / 导出导入 / 管理多开微信副本
#  用法：chmod +x wechat-multi.sh && ./wechat-multi.sh [--dry-run]
#
# =============================================================================

emulate -L zsh
set -u
setopt NULL_GLOB
unsetopt xtrace verbose 2>/dev/null
set +x 2>/dev/null

# ──────────────────────────────────────────────
# 参数解析
# ──────────────────────────────────────────────
DRY_RUN=0
for arg in "$@"; do
  [[ "$arg" == "--dry-run" ]] && DRY_RUN=1
done

# ──────────────────────────────────────────────
# 常量
# ──────────────────────────────────────────────
readonly MULTI_NAME_PREFIX="WeChat-Multi"
readonly MULTI_BUNDLE_PREFIX="com.tencent.xinWeChat.multi"
readonly PLISTBUDDY="/usr/libexec/PlistBuddy"
readonly MARKER_FILENAME=".wechat_multi_managed"
readonly VERSION="1.6.2"

readonly CONFIG_DIR="$HOME/.config/wechat-multi"
readonly MANAGED_JSON="$CONFIG_DIR/managed_apps.json"
readonly MANAGED_JSON_BAK="$CONFIG_DIR/managed_apps.json.bak"

readonly LOG_DIR="$HOME/Library/Logs/WeChatMultiManager"
readonly LOG_FILE="$LOG_DIR/$(date +%Y-%m-%d_%H%M%S).log"

readonly EXPORT_PREFIX="WeChat-Backup"
readonly EXPORT_MANIFEST="manifest.json"
readonly EXPORT_FORMAT_VERSION=1

# ──────────────────────────────────────────────
# 全局状态
# ──────────────────────────────────────────────
MULTI_APPS=()
IMPORTABLE_APPS=()
PICKED_APP=""
_IS_COMMAND=0
[[ "${(%):-%x}" == *.command ]] && _IS_COMMAND=1
SUDO_KEEPALIVE_PID=""
SOURCE_APP=""
SOURCE_VERSION=""
SOURCE_BUNDLE_ID=""
_sudo_acquired=0
_SCAN_DIRTY=1
EXPORT_FOLDERS=()
GROUP_CONTAINER_DIRS=()
SHARED_GROUP_CONTAINER_DIRS=()

# ──────────────────────────────────────────────
# 日志：所有输出同时写终端和日志文件
# ──────────────────────────────────────────────
mkdir -p "$LOG_DIR"
exec > >(tee -a "$LOG_FILE") 2>&1

# ──────────────────────────────────────────────
# UI 工具
# ──────────────────────────────────────────────
echo "======================================"
echo "  WeChat Multi Manager  v${VERSION}"
if [ "$DRY_RUN" -eq 1 ]; then
  echo "  ⚠️  DRY-RUN 模式：不会实际修改任何文件"
fi
echo "======================================"
echo ""
echo "# 运行时间：$(date '+%Y-%m-%d %H:%M:%S')"
echo "# macOS：$(sw_vers -productVersion)  arch：$(uname -m)"
echo "# dry-run：$DRY_RUN"
echo "# 日志路径：$LOG_FILE"
echo ""

pause_on_exit() {
  [ "$_IS_COMMAND" -eq 1 ] || return 0
  echo ""
  read "dummy?按回车键退出..."
}

die() {
  echo ""
  echo "❌ $1"
  # 不在 die 里手动 _cleanup，避免批量升级的子 Shell 失败时
  # 误杀主进程的 sudo keep-alive。统一交给 EXIT trap 清理。
  exit 1
}

info()    { echo "   $1"; }
success() { echo "✅ $1"; }
warn()    { echo "⚠️  $1"; }
step()    { echo "▶  $1"; }

# dry-run 包装：DRY_RUN=1 时只打印命令，不执行
run_cmd() {
  if [ "$DRY_RUN" -eq 1 ]; then
    echo "   [dry-run] $*"
  else
    "$@"
  fi
}

# ──────────────────────────────────────────────
# 清理
# ──────────────────────────────────────────────
_cleanup() {
  if [ -n "$SUDO_KEEPALIVE_PID" ]; then
    kill "$SUDO_KEEPALIVE_PID" 2>/dev/null || true
    SUDO_KEEPALIVE_PID=""
  fi
}
trap '_cleanup' EXIT

# ──────────────────────────────────────────────
# plist 工具
# ──────────────────────────────────────────────
get_version() {
  [ -f "$1/Contents/Info.plist" ] || { echo "unknown"; return; }
  "$PLISTBUDDY" -c "Print :CFBundleShortVersionString" \
    "$1/Contents/Info.plist" 2>/dev/null || echo "unknown"
}

get_bundle_id() {
  [ -f "$1/Contents/Info.plist" ] || { echo "unknown"; return; }
  "$PLISTBUDDY" -c "Print :CFBundleIdentifier" \
    "$1/Contents/Info.plist" 2>/dev/null || echo "unknown"
}

# ──────────────────────────────────────────────
# 环境检测
# ──────────────────────────────────────────────
check_env() {
  echo "────────────────────────────────────"
  step "系统环境检测..."
  echo ""

  local ok=1

  # macOS 版本
  local macos_ver macos_major
  macos_ver="$(sw_vers -productVersion)"
  macos_major="${macos_ver%%.*}"
  if [ "$macos_major" -ge 13 ]; then
    info "macOS $macos_ver ✓"
  else
    warn "macOS $macos_ver（建议 13+，当前版本可能存在兼容问题）"
  fi

  # 架构
  info "架构：$(uname -m) ✓"

  # codesign
  if [ -x /usr/bin/codesign ]; then
    info "codesign ✓"
  else
    warn "未找到 /usr/bin/codesign"
    ok=0
  fi

  # PlistBuddy
  if [ -x "$PLISTBUDDY" ]; then
    info "PlistBuddy ✓"
  else
    warn "未找到 PlistBuddy：$PLISTBUDDY"
    ok=0
  fi

  # python3（用于 JSON 操作）
  if command -v python3 >/dev/null 2>&1; then
    info "python3 $(python3 --version 2>&1 | awk '{print $2}') ✓"
  else
    warn "未找到 python3，托管记录功能将不可用"
    # 不阻断，JSON 功能会静默跳过
  fi

  # /Applications 写权限（通常需要 sudo，这里只做提示）
  info "/Applications 写入需要 sudo（正常）✓"

  # 自动检测微信路径
  local candidates=(
    "/Applications/WeChat.app"
    "/Applications/微信.app"
  )
  SOURCE_APP=""
  for c in "${candidates[@]}"; do
    if [ -d "$c" ]; then
      SOURCE_APP="$c"
      break
    fi
  done

  if [ -z "$SOURCE_APP" ]; then
    echo ""
    die "未找到原版微信，请确认微信已安装在 /Applications 目录下。"
  fi

  # 原版微信完整性
  if [ ! -f "$SOURCE_APP/Contents/Info.plist" ]; then
    die "原版微信 Info.plist 缺失，App 可能已损坏：$SOURCE_APP"
  fi

  SOURCE_VERSION="$(get_version "$SOURCE_APP")"
  SOURCE_BUNDLE_ID="$(get_bundle_id "$SOURCE_APP")"

  if [ "$SOURCE_VERSION" = "unknown" ] || [ "$SOURCE_BUNDLE_ID" = "unknown" ]; then
    die "无法读取原版微信版本或 Bundle ID，App 可能已损坏。"
  fi

  echo ""
  info "原版微信路径：  $SOURCE_APP"
  info "原版版本：      $SOURCE_VERSION"
  info "原版 Bundle ID：$SOURCE_BUNDLE_ID"

  [ "$ok" -eq 0 ] && die "环境检测未通过，请解决上述问题后重试。"

  echo ""
  success "环境检测通过。"
  echo "────────────────────────────────────"
  echo ""
}

# ──────────────────────────────────────────────
# managed_apps.json 工具
# ──────────────────────────────────────────────

# 所有 JSON 操作都经过这个 python3 入口，内置损坏保护
_run_json_op() {
  command -v python3 >/dev/null 2>&1 || return 0

  python3 - "$MANAGED_JSON" "$MANAGED_JSON_BAK" "$@" << 'PY'
import sys, json, os, shutil, datetime

json_path = sys.argv[1]
bak_path  = sys.argv[2]
op        = sys.argv[3]
args      = sys.argv[4:]

def load_json(path, bak):
    """加载 JSON，损坏时自动从备份恢复，备份也损坏则返回空结构"""
    for src in [path, bak]:
        if not os.path.exists(src):
            continue
        try:
            with open(src) as f:
                return json.load(f)
        except Exception:
            pass
    return {"managed": []}

def save_json(data, path, bak):
    """先写临时文件再原子替换，同时保留 .bak"""
    tmp = path + ".tmp"
    with open(tmp, "w") as f:
        json.dump(data, f, ensure_ascii=False, indent=2)
    if os.path.exists(path):
        shutil.copy2(path, bak)
    os.replace(tmp, path)

os.makedirs(os.path.dirname(json_path), exist_ok=True)
data = load_json(json_path, bak_path)

now = datetime.datetime.now().isoformat()

if op == "register":
    app_path, bundle_id = args[0], args[1]
    for e in data["managed"]:
        if e["path"] == app_path:
            e["bundle_id"]  = bundle_id
            e["updated_at"] = now
            break
    else:
        data["managed"].append({
            "path":       app_path,
            "bundle_id":  bundle_id,
            "created_at": now,
            "updated_at": now,
        })
    save_json(data, json_path, bak_path)

elif op == "unregister":
    app_path = args[0]
    data["managed"] = [e for e in data["managed"] if e["path"] != app_path]
    save_json(data, json_path, bak_path)

elif op == "is_managed":
    app_path = args[0]
    sys.exit(0 if any(e["path"] == app_path for e in data["managed"]) else 1)

elif op == "cleanup_orphans":
    orphans = [e for e in data["managed"] if not os.path.isdir(e["path"])]
    if orphans:
        print(f"发现 {len(orphans)} 个已记录但路径不存在的副本（可能被手动删除）：")
        for e in orphans:
            print(f"   {e['path']}")
        data["managed"] = [e for e in data["managed"] if os.path.isdir(e["path"])]
        save_json(data, json_path, bak_path)
        print("已自动从记录中移除。")

elif op == "created_at":
    app_path = args[0]
    for e in data["managed"]:
        if e["path"] == app_path:
            print(e.get("created_at", "-")[:19].replace("T", " "))
            break

elif op == "export":
    result = []
    for e in data["managed"]:
        if os.path.isdir(e["path"]):
            result.append({
                "name":       os.path.basename(e["path"]).replace(".app",""),
                "path":       e["path"],
                "bundle_id":  e.get("bundle_id",""),
                "created_at": e.get("created_at","")[:19].replace("T"," "),
            })
    print(json.dumps(result, ensure_ascii=False, indent=2))

PY
}

json_register()        { _run_json_op "register"       "$@"; }
json_unregister()      { _run_json_op "unregister"     "$@"; }
json_is_managed()      { _run_json_op "is_managed"     "$@"; }
json_cleanup_orphans() { _run_json_op "cleanup_orphans";     }
json_created_at()      { _run_json_op "created_at"     "$@"; }
json_export()          { _run_json_op "export";              }

# ──────────────────────────────────────────────
# sudo 管理
# ──────────────────────────────────────────────
need_sudo() {
  [ "$_sudo_acquired" -eq 1 ] && return
  [ "$DRY_RUN" -eq 1 ] && { _sudo_acquired=1; return; }

  echo "需要管理员权限，用于复制、删除、签名 /Applications 里的微信副本。"
  if ! sudo -v; then
    warn "sudo 鉴权失败。"
    return 1
  fi

  ( while true; do sudo -n true 2>/dev/null; sleep 60; done ) &
  SUDO_KEEPALIVE_PID=$!
  _sudo_acquired=1
}

# ──────────────────────────────────────────────
# 微信进程管理
# ──────────────────────────────────────────────
_is_manager_process_line() {
  local line="$1"
  [[ "$line" == *"WeChat-Multi-Manager"* ]] && return 0
  [[ "$line" == *"wechat-multi"* ]]        && return 0
  [[ "$line" == *"WeChatMultiManager"* ]]  && return 0
  [[ "$line" == *"Cursor Helper"* ]]      && return 0
  [[ "$line" == *"extension-host"* ]]     && return 0
  return 1
}

# 收集真实微信相关 PID（必须匹配 .app/Contents/MacOS，避免误匹配 Cursor/本工具目录）
_collect_wechat_pids() {
  local pid
  WECHAT_PIDS=()

  local patterns=(
    '/Applications/WeChat\.app/Contents/MacOS'
    '/Applications/微信\.app/Contents/MacOS'
    '/Applications/WeChat[^/]*\.app/Contents/MacOS'
    'WeChatAppEx'
    'WeChat Helper'
    'wxplayer'
    'wxutility'
  )

  for pattern in "${patterns[@]}"; do
    while IFS= read -r pid; do
      [ -n "$pid" ] || continue
      WECHAT_PIDS+=("$pid")
    done < <(pgrep -if "$pattern" 2>/dev/null)
  done

  # 进程名恰好为 WeChat / 微信（兜底，不含 Cursor 等）
  while IFS= read -r pid; do
    [ -n "$pid" ] || continue
    WECHAT_PIDS+=("$pid")
  done < <(pgrep -ix WeChat 2>/dev/null; pgrep -ix 微信 2>/dev/null)

  WECHAT_PIDS=(${(u)WECHAT_PIDS[@]})
}

_format_pid_line() {
  local pid="$1" ps_line
  ps_line="$(ps -p "$pid" -o pid=,command= 2>/dev/null | sed 's/^[[:space:]]*//')"
  [ -n "$ps_line" ] || ps_line="$pid"
  _is_manager_process_line "$ps_line" && return 1
  echo "$ps_line"
}

_list_wechat_process_lines() {
  _collect_wechat_pids
  local pid line
  for pid in "${WECHAT_PIDS[@]}"; do
    line="$(_format_pid_line "$pid")" || continue
    echo "$line"
  done
}

_has_wechat_processes() {
  local lines
  lines="$(_list_wechat_process_lines)"
  [ -n "$lines" ]
}

_kill_wechat_processes() {
  pkill -x "WeChat"  2>/dev/null || true
  pkill -x "微信"     2>/dev/null || true
  pkill -if '/Applications/WeChat\.app/Contents/MacOS'        2>/dev/null || true
  pkill -if '/Applications/微信\.app/Contents/MacOS'           2>/dev/null || true
  pkill -if '/Applications/WeChat[^/]*\.app/Contents/MacOS'   2>/dev/null || true
  pkill -if "WeChatAppEx"    2>/dev/null || true
  pkill -if "WeChat Helper"  2>/dev/null || true
  pkill -if "wxplayer"       2>/dev/null || true
  pkill -if "wxutility"      2>/dev/null || true
}

wait_wechat_exit() {
  step "正在关闭所有微信相关进程..."

  if [ "$DRY_RUN" -eq 1 ]; then
    info "[dry-run] 跳过关闭微信进程"
    return
  fi

  _kill_wechat_processes

  local i
  for i in {1..15}; do
    if ! _has_wechat_processes; then
      success "微信已退出。"
      return
    fi
    sleep 1
  done

  warn "微信相关进程似乎仍未完全退出（等待超时）。"
  info "残留进程："
  _list_wechat_process_lines | while IFS= read -r line; do
    info "  $line"
  done
  echo ""
  info "请先在 Dock 中右键每个微信图标 → 退出，或打开「活动监视器」结束 WeChat 相关进程。"
  info "若确认已全部退出，可选 y 强制继续。"
  read "force_close?是否强制继续？[y/N]："
  if ! [[ "$force_close" =~ ^[Yy]$ ]]; then
    info "已取消。"
    return 1
  fi
}

# ──────────────────────────────────────────────
# 扫描 / 展示
# ──────────────────────────────────────────────
invalidate_multi_scan() {
  _SCAN_DIRTY=1
}

ensure_multi_apps_scanned() {
  [ "$_SCAN_DIRTY" -eq 1 ] && scan_multi_apps
}

scan_multi_apps() {
  MULTI_APPS=()
  local app app_name app_bid by_name by_bid by_json by_marker

  for app in /Applications/*.app; do
    [ -d "$app" ] || continue
    [[ "$app" == "$SOURCE_APP" ]] && continue

    app_name=${app:t}
    app_bid="$(get_bundle_id "$app")"

    by_name=0; by_bid=0; by_json=0; by_marker=0
    [[ "$app_name" == ${MULTI_NAME_PREFIX}* ]]                        && by_name=1
    [[ "$app_bid"  == ${MULTI_BUNDLE_PREFIX}* ]]                        && by_bid=1
    json_is_managed "$app" 2>/dev/null                                  && by_json=1
    [ -f "$app/Contents/Resources/${MARKER_FILENAME}" ]                 && by_marker=1

    if [ "$by_name" -eq 1 ] || [ "$by_bid" -eq 1 ] || \
       [ "$by_json" -eq 1 ] || [ "$by_marker" -eq 1 ]; then
      MULTI_APPS+=("$app")
    fi
  done
  _SCAN_DIRTY=0
}

print_multi_apps() {
  ensure_multi_apps_scanned

  if [ ${#MULTI_APPS[@]} -eq 0 ]; then
    info "未发现已有多开微信。"
    return
  fi

  echo "发现以下多开微信："
  echo ""

  local i=1 app_name version app_bid icon ver_status managed_mark
  for app in "${MULTI_APPS[@]}"; do
    app_name=${app:t}
    version="$(get_version "$app")"
    app_bid="$(get_bundle_id "$app")"
    managed_mark=""
    json_is_managed "$app" 2>/dev/null && managed_mark=" [托管]"

    if [ "$version" = "$SOURCE_VERSION" ]; then
      icon="✅"; ver_status="版本一致"
    else
      icon="⚠️ "; ver_status="需要升级  (当前 $version → 原版 $SOURCE_VERSION)"
    fi

    echo "$icon $i) $app_name$managed_mark"
    echo "      路径：$app"
    echo "      Bundle ID：$app_bid"
    echo "      状态：$ver_status"
    echo ""
    i=$((i+1))
  done
}

# ──────────────────────────────────────────────
# 选择序号
# ──────────────────────────────────────────────
pick_app_by_num() {
  local prompt="$1"
  read "num?$prompt"

  if ! [[ "$num" =~ ^[0-9]+$ ]]; then
    warn "请输入有效数字。"
    return 1
  fi

  PICKED_APP="${MULTI_APPS[$num]:-}"
  if [ -z "$PICKED_APP" ] || [ ! -d "$PICKED_APP" ]; then
    warn "序号无效或路径不存在。"
    return 1
  fi
  return 0
}

pick_importable_by_num() {
  local prompt="$1"
  read "num?$prompt"

  if ! [[ "$num" =~ ^[0-9]+$ ]]; then
    warn "请输入有效数字。"
    return 1
  fi

  PICKED_APP="${IMPORTABLE_APPS[$num]:-}"
  if [ -z "$PICKED_APP" ] || [ ! -d "$PICKED_APP" ]; then
    warn "序号无效或路径不存在。"
    return 1
  fi
  return 0
}

is_already_managed() {
  local app="$1" app_name app_bid
  app_name=${app:t}
  app_bid="$(get_bundle_id "$app")"
  [[ "$app_name" == ${MULTI_NAME_PREFIX}* ]] && return 0
  [[ "$app_bid" == ${MULTI_BUNDLE_PREFIX}* ]] && return 0
  json_is_managed "$app" 2>/dev/null && return 0
  [ -f "$app/Contents/Resources/${MARKER_FILENAME}" ] && return 0
  return 1
}

is_importable_wechat_clone() {
  local app="$1" app_name app_bid
  app_name=${app:t}
  app_bid="$(get_bundle_id "$app")"
  [[ "$app_bid" == "$SOURCE_BUNDLE_ID" ]] && return 1
  [[ "$app_bid" == com.tencent.xinWeChat* ]] && return 0
  [[ "$app_name" == WeChat* && "$app_name" != "WeChat.app" ]] && return 0
  [[ "$app_name" == *微信* && "$app_name" != "微信.app" ]] && return 0
  return 1
}

scan_importable_apps() {
  IMPORTABLE_APPS=()

  for app in /Applications/*.app; do
    [ -d "$app" ] || continue
    [[ "$app" == "$SOURCE_APP" ]] && continue
    is_already_managed "$app" && continue
    is_importable_wechat_clone "$app" && IMPORTABLE_APPS+=("$app")
  done
}

print_importable_apps() {
  scan_importable_apps

  if [ ${#IMPORTABLE_APPS[@]} -eq 0 ]; then
    info "未发现可导入的多开微信。"
    return 1
  fi

  echo "发现以下可导入的多开微信："
  echo ""
  echo "（手动创建的旧副本，如 WeChat-Work.app，导入后将纳入托管管理）"
  echo ""

  local i=1 app_name version app_bid
  for app in "${IMPORTABLE_APPS[@]}"; do
    app_name=${app:t}
    version="$(get_version "$app")"
    app_bid="$(get_bundle_id "$app")"
    echo "  $i) $app_name"
    info "   路径：$app"
    info "   Bundle ID：$app_bid"
    info "   版本：$version"
    echo ""
    i=$((i+1))
  done
  return 0
}

write_managed_marker() {
  local target_app="$1"
  if [ "$DRY_RUN" -eq 0 ]; then
    sudo mkdir -p "$target_app/Contents/Resources" && \
    sudo sh -c "echo 'WeChat Multi Manager v${VERSION}' > \
      '$target_app/Contents/Resources/${MARKER_FILENAME}'" || \
      warn "写入托管标记失败（不影响使用）。"
  else
    info "[dry-run] 写入 $target_app/Contents/Resources/${MARKER_FILENAME}"
  fi
}

import_multi_app() {
  local target_app="$1"
  local bundle_id app_name
  app_name="$(basename "$target_app")"
  bundle_id="$(get_bundle_id "$target_app")"

  if [[ "$bundle_id" == "unknown" ]]; then
    warn "无法读取 Bundle ID，导入中止。"
    return 1
  fi
  if [[ "$bundle_id" == "$SOURCE_BUNDLE_ID" ]]; then
    warn "不能导入原版微信。"
    return 1
  fi

  echo ""
  echo "--------------------------------------"
  step "导入：$target_app"
  info "Bundle ID：$bundle_id"
  [ "$DRY_RUN" -eq 1 ] && step "[dry-run 模式，以下操作均不会实际执行]"
  echo "--------------------------------------"

  need_sudo || return 1
  write_managed_marker "$target_app"

  if [ "$DRY_RUN" -eq 0 ]; then
    json_register "$target_app" "$bundle_id" 2>/dev/null || \
      warn "写入托管记录失败（不影响使用）。"
  else
    info "[dry-run] json_register $target_app $bundle_id"
  fi

  success "已导入：$app_name"
  invalidate_multi_scan
}

_run_with_sudo() {
  need_sudo || return 1
  "$@"
}

_run_with_sudo_and_wechat_closed() {
  need_sudo || return 1
  wait_wechat_exit || return 1
  "$@"
}

confirm_target_app_quit() {
  local target_app="$1"
  local app_name="${target_app:t}"
  echo ""
  info "将修复：$app_name"
  info "修复签名不会关闭其他微信，请手动退出这一个副本后再继续。"
  read "confirm_fix?目标副本已退出？[y/N]："
  [[ "$confirm_fix" =~ ^[Yy]$ ]]
}

# 发现与副本关联的 Group Containers（entitlements + metadata + 命名规则）
discover_group_containers() {
  local target_app="$1" app_bid="$2"
  GROUP_CONTAINER_DIRS=()
  SHARED_GROUP_CONTAINER_DIRS=()

  command -v python3 >/dev/null 2>&1 || return 0

  local line gc_path
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    if [[ "$line" == SHARED:* ]]; then
      gc_path="${line#SHARED:}"
      GROUP_CONTAINER_DIRS+=("$gc_path")
      SHARED_GROUP_CONTAINER_DIRS+=("$gc_path")
    else
      GROUP_CONTAINER_DIRS+=("$line")
    fi
  done < <(python3 - "$target_app" "$app_bid" "$HOME" << 'PY'
import os, re, subprocess, plistlib, sys

app_path, bundle_id, home = sys.argv[1:4]
gc_root = os.path.join(home, "Library", "Group Containers")
found = set()
shared = set()

if not os.path.isdir(gc_root):
    sys.exit(0)

xin_names = [n for n in os.listdir(gc_root) if "xinWeChat" in n]

def add(name, is_shared=False):
    path = os.path.join(gc_root, name)
    if os.path.isdir(path):
        found.add(path)
        if is_shared:
            shared.add(path)

# 1) App entitlements → application-groups
try:
    proc = subprocess.run(
        ["codesign", "-d", "--entitlements", ":-", app_path],
        capture_output=True, check=False,
    )
    if proc.stdout:
        ent = plistlib.loads(proc.stdout)
        groups = ent.get("com.apple.security.application-groups", [])
        if isinstance(groups, str):
            groups = [groups]
        for g in groups:
            g_strip = g.replace("group.", "")
            for name in xin_names:
                if g in name or name.endswith(g_strip) or g_strip in name:
                    add(name)
except Exception:
    pass

# 2) Containers metadata → 交叉引用 Group Containers
cm_path = os.path.join(
    home, "Library", "Containers", bundle_id,
    ".com.apple.containermanagerd.metadata.plist",
)
if os.path.isfile(cm_path):
    try:
        with open(cm_path, "rb") as f:
            meta = plistlib.load(f)
        meta_s = str(meta)
        for name in xin_names:
            if name in meta_s:
                add(name)
    except Exception:
        pass

# 3) 各 Group Container metadata → 是否引用该 Bundle ID
for name in xin_names:
    meta_path = os.path.join(
        gc_root, name, ".com.apple.containermanagerd.metadata.plist",
    )
    if not os.path.isfile(meta_path):
        continue
    try:
        with open(meta_path, "rb") as f:
            meta = plistlib.load(f)
        if bundle_id in str(meta):
            add(name)
    except Exception:
        pass

# 4) 目录名匹配：完整 Bundle ID / TEAM.BundleID / 含 Bundle ID
team_bundle = re.compile(r"^[A-Z0-9]{10}\." + re.escape(bundle_id) + r"$")
for name in xin_names:
    if bundle_id in name:
        add(name)
    elif team_bundle.match(name):
        add(name)
    elif "." in name and name.split(".", 1)[1] == bundle_id:
        add(name)

# 5) 原版微信共享目录：TEAM.com.tencent.xinWeChat（仅无更具体匹配时）
if bundle_id in ("com.tencent.xinWeChat", "com.tencent.weixin"):
    for name in xin_names:
        if re.match(r"^[A-Z0-9]{10}\.com\.tencent\.xinWeChat$", name):
            add(name)
elif bundle_id.startswith("com.tencent.xinWeChat"):
    has_specific = any(bundle_id in os.path.basename(p) for p in found)
    if not has_specific:
        for name in xin_names:
            if re.match(r"^[A-Z0-9]{10}\.com\.tencent\.xinWeChat$", name):
                add(name, is_shared=True)

for path in sorted(found):
    prefix = "SHARED:" if path in shared else ""
    print(prefix + path)
PY
)
}

_warn_shared_group_containers() {
  local action="${1:-使用}"
  [ ${#SHARED_GROUP_CONTAINER_DIRS[@]} -gt 0 ] || return 0
  echo ""
  warn "检测到共享 Group Container（可能被多个微信副本共用）："
  local gc
  for gc in "${SHARED_GROUP_CONTAINER_DIRS[@]}"; do
    info "  $(basename "$gc")"
  done
  info "包含该目录会使多个副本的备份体积重复增大。"
  read "confirm_shared?仍要${action}这些共享目录？[y/N]："
  [[ "$confirm_shared" =~ ^[Yy]$ ]]
}

_du_kb() {
  du -sk "$1" 2>/dev/null | awk '{print $1}'
}

_format_kb_human() {
  local kb="$1"
  if [ -z "$kb" ] || [ "$kb" -eq 0 ]; then
    echo "0"
    return
  fi
  if [ "$kb" -ge 1048576 ]; then
    awk "BEGIN {printf \"%.1fGB\", $kb/1048576}"
  elif [ "$kb" -ge 1024 ]; then
    awk "BEGIN {printf \"%.1fMB\", $kb/1024}"
  else
    echo "${kb}KB"
  fi
}

_df_avail_kb() {
  local path="$1"
  df -k "$path" 2>/dev/null | awk 'NR==2 {print $4}'
}

# 导入前磁盘空间预检（含覆盖时 .bak 暂存峰值）
_check_import_disk_space() {
  local export_dir="$1" dest_app="$2" container_src="$3" container_dest="$4"
  local needed_kb=0 avail_kb part_kb gc_name gc_src gc_dest
  local check_paths=("/" "$HOME")

  part_kb="$(_du_kb "$export_dir/app/$MANIFEST_APP_NAME")"
  needed_kb=$(( needed_kb + part_kb ))
  [ -d "$dest_app" ] && needed_kb=$(( needed_kb + $(_du_kb "$dest_app") ))

  if [ -d "$container_src" ]; then
    part_kb="$(_du_kb "$container_src")"
    needed_kb=$(( needed_kb + part_kb ))
    [ -d "$container_dest" ] && needed_kb=$(( needed_kb + $(_du_kb "$container_dest") ))
  fi

  for gc_name in "${MANIFEST_GROUP_CONTAINERS[@]}"; do
    gc_src="$export_dir/Library/Group Containers/$gc_name"
    gc_dest="$HOME/Library/Group Containers/$gc_name"
    [ -d "$gc_src" ] || continue
    needed_kb=$(( needed_kb + $(_du_kb "$gc_src") ))
    [ -d "$gc_dest" ] && needed_kb=$(( needed_kb + $(_du_kb "$gc_dest") ))
  done

  # 预留 5% 余量
  needed_kb=$(( needed_kb + needed_kb / 20 ))

  echo ""
  step "磁盘空间预检"
  info "预计峰值占用：约 $(_format_kb_human "$needed_kb")（含覆盖暂存）"

  local path min_avail_kb="" path_avail
  for path in "${check_paths[@]}"; do
    path_avail="$(_df_avail_kb "$path")"
    [ -z "$path_avail" ] && continue
    info "  $path 可用：$(_format_kb_human "$path_avail")"
    if [ -z "$min_avail_kb" ] || [ "$path_avail" -lt "$min_avail_kb" ]; then
      min_avail_kb="$path_avail"
    fi
  done

  avail_kb="${min_avail_kb:-0}"
  if [ "$needed_kb" -gt "$avail_kb" ]; then
    warn "磁盘空间可能不足（需要约 $(_format_kb_human "$needed_kb")，可用约 $(_format_kb_human "$avail_kb")）。"
    read "confirm_low_disk?空间不足仍要继续导入？[y/N]："
    [[ "$confirm_low_disk" =~ ^[Yy]$ ]] || return 1
  else
    success "磁盘空间充足。"
  fi
  return 0
}

# 导出前磁盘空间预检（目标为桌面备份文件夹）
_check_export_disk_space() {
  local target_app="$1" container_path="$2"
  local needed_kb=0 avail_kb part_kb gc desktop="$HOME/Desktop"

  needed_kb=$(( needed_kb + $(_du_kb "$target_app") ))
  [ -d "$container_path" ] && needed_kb=$(( needed_kb + $(_du_kb "$container_path") ))

  local gc
  for gc in "${GROUP_CONTAINER_DIRS[@]}"; do
    [ -d "$gc" ] || continue
    needed_kb=$(( needed_kb + $(_du_kb "$gc") ))
  done

  needed_kb=$(( needed_kb + needed_kb / 20 ))

  echo ""
  step "磁盘空间预检"
  info "预计导出体积：约 $(_format_kb_human "$needed_kb")"
  avail_kb="$(_df_avail_kb "$desktop")"
  info "  桌面可用：$(_format_kb_human "$avail_kb")"

  if [ -n "$avail_kb" ] && [ "$needed_kb" -gt "$avail_kb" ]; then
    warn "桌面空间可能不足（需要约 $(_format_kb_human "$needed_kb")，可用约 $(_format_kb_human "$avail_kb")）。"
    read "confirm_low_disk?空间不足仍要继续导出？[y/N]："
    [[ "$confirm_low_disk" =~ ^[Yy]$ ]] || return 1
  else
    success "桌面空间充足。"
  fi
  return 0
}

_is_app_running() {
  local bundle_id="$1"
  if command -v lsappinfo >/dev/null 2>&1; then
    lsappinfo find "bundleid=$bundle_id" 2>/dev/null | grep -q .
    return $?
  fi
  osascript -e \
    "tell application \"System Events\" to ((count of (every process whose bundle identifier is \"$bundle_id\")) > 0)" \
    2>/dev/null | grep -q "true"
}

# 创建/升级后启动自检（批量升级时由 SKIP_LAUNCH_VERIFY=1 跳过）
verify_app_launch() {
  local target_app="$1"
  local bundle_id app_name

  [ "${SKIP_LAUNCH_VERIFY:-0}" -eq 1 ] && return 0
  [ "$DRY_RUN" -eq 1 ] && { info "[dry-run] 跳过启动自检"; return 0; }

  bundle_id="$(get_bundle_id "$target_app")"
  app_name="${target_app:t}"

  echo ""
  read "confirm_launch?是否进行启动自检？[Y/n]："
  if [[ "$confirm_launch" =~ ^[Nn]$ ]]; then
    info "已跳过启动自检。"
    return 0
  fi
  info "启动自检会临时打开该副本，检测后不会自动退出。"

  step "启动自检：$app_name"
  info "最多等待 15 秒检测进程（首次启动可能较慢）。"

  if ! open -gj "$target_app" 2>/dev/null; then
    warn "无法启动 $app_name，请稍后手动打开验证。"
    return 1
  fi

  local i
  for i in {1..15}; do
    if _is_app_running "$bundle_id"; then
      success "启动自检通过：$app_name 进程在运行（${i}s）。"
      return 0
    fi
    sleep 1
  done

  warn "启动自检 15 秒内未检测到进程（可能需手动确认安全提示或首次初始化较慢）。"
  info "请手动打开 $app_name；若无法运行，请使用菜单 8 修复签名。"
  return 1
}

# 复制后体积校验（App 包允许更大误差；极小目录跳过）
_verify_copy_size() {
  local src="$1" dst="$2" label="$3"
  local src_kb dst_kb min_pct=98

  src_kb="$(_du_kb "$src")"
  dst_kb="$(_du_kb "$dst")"
  [ -n "$src_kb" ] && [ -n "$dst_kb" ] || return 0
  [ "$src_kb" -eq 0 ] && return 0

  # .app 体积因 APFS / xattr / du 统计时机可能差几个百分点
  [[ "$src" == *.app || "$dst" == *.app ]] && min_pct=95

  if [ "$src_kb" -gt 100 ] && [ "$dst_kb" -lt $(( src_kb * min_pct / 100 )) ]; then
    warn "$label 体积校验失败（源 ${src_kb}KB → 副本 ${dst_kb}KB，要求 ≥${min_pct}%）"
    return 1
  fi
  info "$label 体积校验通过（${dst_kb}KB）"
  return 0
}

# 导入数据目录：先 .bak 备份，复制成功后再删备份
IMPORT_TX_BACKUPS=()

_import_tx_begin() {
  IMPORT_TX_BACKUPS=()
}

_import_tx_stage() {
  local dest="$1" mode="${2:-user}"
  local bak="${dest}.wechat-multi-restore-bak"

  [ -d "$bak" ] && rm -rf "$bak"
  [ -d "$dest" ] || return 0

  if [ "$mode" = "sudo" ]; then
    sudo mv "$dest" "$bak" || return 1
  else
    mv "$dest" "$bak" || return 1
  fi
  IMPORT_TX_BACKUPS+=("${dest}|${bak}|${mode}")
  return 0
}

_import_tx_commit() {
  local entry dest bak mode
  for entry in "${IMPORT_TX_BACKUPS[@]}"; do
    dest="${entry%%|*}"
    bak="${entry#*|}"; bak="${bak%%|*}"
    mode="${entry##*|}"
    if [ "$mode" = "sudo" ]; then
      sudo rm -rf "$bak" 2>/dev/null || true
    else
      rm -rf "$bak" 2>/dev/null || true
    fi
  done
  IMPORT_TX_BACKUPS=()
}

_import_tx_rollback() {
  local i entry dest bak mode
  for (( i=${#IMPORT_TX_BACKUPS[@]}; i>=1; i-- )); do
    entry="${IMPORT_TX_BACKUPS[i]}"
    dest="${entry%%|*}"
    bak="${entry#*|}"; bak="${bak%%|*}"
    mode="${entry##*|}"
    [ -d "$bak" ] || continue
    if [ -d "$dest" ]; then
      if [ "$mode" = "sudo" ]; then
        sudo rm -rf "$dest" 2>/dev/null || true
      else
        rm -rf "$dest" 2>/dev/null || true
      fi
    fi
    if [ "$mode" = "sudo" ]; then
      sudo mv "$bak" "$dest" 2>/dev/null || true
    else
      mv "$bak" "$dest" 2>/dev/null || true
    fi
  done
  IMPORT_TX_BACKUPS=()
}

open_multi_data_dir() {
  ensure_multi_apps_scanned

  echo ""
  echo "======================================"
  echo "打开多开微信数据目录"
  echo "======================================"
  echo ""

  if [ ${#MULTI_APPS[@]} -eq 0 ]; then
    warn "没有多开副本。"
    return 1
  fi

  print_multi_apps
  echo ""

  if ! pick_app_by_num "请输入要打开数据目录的序号："; then
    return 1
  fi

  local target_app app_bid container_path opened=0 gc
  target_app="$PICKED_APP"
  app_bid="$(get_bundle_id "$target_app")"
  container_path="$HOME/Library/Containers/$app_bid"

  info "Bundle ID：$app_bid"
  discover_group_containers "$target_app" "$app_bid"

  if [ -d "$container_path" ]; then
    info "数据目录：$container_path"
    if [ "$DRY_RUN" -eq 1 ]; then
      info "[dry-run] open $container_path"
    else
      open "$container_path"
      success "已在访达中打开 Containers。"
    fi
    opened=1
  else
    warn "未找到：$container_path"
  fi

  if [ ${#GROUP_CONTAINER_DIRS[@]} -gt 0 ]; then
    echo ""
    if [ ${#SHARED_GROUP_CONTAINER_DIRS[@]} -gt 0 ]; then
      warn "以下 Group Container 为共享目录（可能被多个副本共用）："
    else
      info "关联 Group Containers："
    fi
    for gc in "${GROUP_CONTAINER_DIRS[@]}"; do
      local shared_note=""
      [[ " ${SHARED_GROUP_CONTAINER_DIRS[*]} " == *" $gc "* ]] && shared_note=" [共享]"
      info "  $gc$shared_note"
      if [ "$DRY_RUN" -eq 0 ]; then
        open "$gc"
      fi
    done
    [ "$DRY_RUN" -eq 0 ] && success "已打开关联 Group Containers。"
    opened=1
  fi

  if [ "$opened" -eq 0 ]; then
    echo ""
    info "可手动查看 ~/Library/Containers/$app_bid"
  fi
}

check_storage_usage() {
  ensure_multi_apps_scanned

  echo ""
  echo "======================================"
  echo "检查多开微信数据占用"
  echo "======================================"
  echo ""

  if [ ${#MULTI_APPS[@]} -eq 0 ]; then
    warn "没有多开副本。"
    return 1
  fi

  print_multi_apps
  echo ""

  if ! pick_app_by_num "请输入要检查占用的序号："; then
    return 1
  fi

  local target_app app_name app_bid container_path found=0 dir size label
  target_app="$PICKED_APP"
  app_name="${target_app:t}"
  app_bid="$(get_bundle_id "$target_app")"
  container_path="$HOME/Library/Containers/$app_bid"

  info "副本：$app_name"
  info "Bundle ID：$app_bid"
  echo ""

  if [ -d "$container_path" ]; then
    size="$(du -sh "$container_path" 2>/dev/null | awk '{print $1}')"
    echo "📦 Containers"
    info "   大小：$size"
    info "   路径：$container_path"
    echo ""
    found=1
  else
    warn "未找到 Containers：$container_path"
    echo ""
  fi

  discover_group_containers "$target_app" "$app_bid"
  if [ ${#SHARED_GROUP_CONTAINER_DIRS[@]} -gt 0 ]; then
    warn "以下 Group Container 为共享目录（可能被多个副本共用）："
    local sgc
    for sgc in "${SHARED_GROUP_CONTAINER_DIRS[@]}"; do
      info "  $(basename "$sgc")"
    done
    echo ""
  fi
  for dir in "${GROUP_CONTAINER_DIRS[@]}"; do
    [ -d "$dir" ] || continue
    label="$(basename "$dir")"
    size="$(du -sh "$dir" 2>/dev/null | awk '{print $1}')"
    local shared_mark=""
    [[ " ${SHARED_GROUP_CONTAINER_DIRS[*]} " == *" $dir "* ]] && shared_mark=" [共享]"
    echo "📦 Group Containers / $label$shared_mark"
    info "   大小：$size"
    info "   路径：$dir"
    echo ""
    found=1
  done

  if [ "$found" -eq 0 ]; then
    warn "未找到该副本的数据目录。"
    info "若尚未在此副本登录过，可能还没有生成数据。"
  fi
}

# ──────────────────────────────────────────────
# 完整导出 / 导入（App + 聊天记录数据）
# ──────────────────────────────────────────────
_write_bundle_manifest() {
  local export_dir="$1" target_app="$2" app_bid="$3" app_ver="$4"
  shift 4
  local group_names=("$@")
  local manifest_path="$export_dir/$EXPORT_MANIFEST"

  command -v python3 >/dev/null 2>&1 || {
    warn "需要 python3 写入清单。"
    return 1
  }

  if [ "$DRY_RUN" -eq 1 ]; then
    info "[dry-run] 写入 $manifest_path"
    return 0
  fi

  python3 - "$manifest_path" "$EXPORT_FORMAT_VERSION" "$VERSION" \
    "${target_app:t}" "$app_bid" "$app_ver" "${group_names[@]}" << 'PY'
import json, sys, datetime

path, fmt_ver, tool_ver, app_name, bundle_id, app_version = sys.argv[1:7]
group_names = sys.argv[7:]

manifest = {
    "format_version": int(fmt_ver),
    "exported_by": f"WeChat Multi Manager v{tool_ver}",
    "exported_at": datetime.datetime.now().strftime("%Y-%m-%d %H:%M:%S"),
    "app_name": app_name,
    "bundle_id": bundle_id,
    "app_version": app_version,
    "group_containers": group_names,
}
with open(path, "w") as f:
    json.dump(manifest, f, ensure_ascii=False, indent=2)
PY
}

_parse_bundle_manifest() {
  local export_dir="$1"
  local manifest_path="$export_dir/$EXPORT_MANIFEST"

  MANIFEST_APP_NAME=""
  MANIFEST_BUNDLE_ID=""
  MANIFEST_APP_VERSION=""
  MANIFEST_EXPORTED_AT=""
  MANIFEST_GROUP_CONTAINERS=()

  command -v python3 >/dev/null 2>&1 || {
    warn "需要 python3 读取清单。"
    return 1
  }
  [ -f "$manifest_path" ] || {
    warn "未找到清单：$manifest_path"
    return 1
  }

  local parsed
  parsed="$(python3 - "$manifest_path" "$EXPORT_FORMAT_VERSION" << 'PY'
import json, sys

path, expected_fmt = sys.argv[1], int(sys.argv[2])
try:
    with open(path) as f:
        m = json.load(f)
    if m.get("format_version") != expected_fmt:
        raise ValueError("不支持的备份格式版本")
    for key in ("app_name", "bundle_id"):
        if not m.get(key):
            raise ValueError(f"清单缺少字段：{key}")
    app_name = m["app_name"]
    if not app_name.endswith(".app"):
        app_name += ".app"
    gc = m.get("group_containers", [])
    print(f"MANIFEST_APP_NAME={app_name}")
    print(f"MANIFEST_BUNDLE_ID={m['bundle_id']}")
    print(f"MANIFEST_APP_VERSION={m.get('app_version', 'unknown')}")
    print(f"MANIFEST_EXPORTED_AT={m.get('exported_at', '-')}")
    print("MANIFEST_GROUP_CONTAINERS=" + " ".join(gc))
except Exception as e:
    print(f"error:{e}", file=sys.stderr)
    sys.exit(1)
PY
)" || return 1

  eval "$parsed"
  MANIFEST_GROUP_CONTAINERS=(${=MANIFEST_GROUP_CONTAINERS})
  return 0
}

scan_export_folders() {
  EXPORT_FOLDERS=()
  local dir
  for dir in "$HOME/Desktop"/${EXPORT_PREFIX}-*; do
    [ -d "$dir" ] || continue
    [ -f "$dir/$EXPORT_MANIFEST" ] || continue
    [ -d "$dir/app" ]           || continue
    EXPORT_FOLDERS+=("$dir")
  done
}

_print_export_folder() {
  local export_dir="$1" idx="$2"
  _parse_bundle_manifest "$export_dir" || return 1
  echo "  $idx) $(basename "$export_dir")"
  info "   微信：$MANIFEST_APP_NAME"
  info "   Bundle ID：$MANIFEST_BUNDLE_ID"
  info "   版本：$MANIFEST_APP_VERSION"
  info "   导出时间：$MANIFEST_EXPORTED_AT"
  echo ""
}

export_wechat_bundle() {
  ensure_multi_apps_scanned

  echo ""
  echo "======================================"
  echo "导出多开微信到桌面文件夹"
  echo "======================================"
  echo ""
  info "将打包 App 本体 + Containers + Group Containers，便于换电脑恢复。"
  echo ""

  if [ ${#MULTI_APPS[@]} -eq 0 ]; then
    warn "没有多开副本。"
    return 1
  fi

  print_multi_apps
  echo ""

  if ! pick_app_by_num "请输入要导出的序号："; then
    return 1
  fi

  local target_app app_name app_bid app_ver container_path export_dir export_name timestamp
  local gc gc_name group_names=() copied_data=0
  target_app="$PICKED_APP"
  app_name="${target_app:t}"
  app_bid="$(get_bundle_id "$target_app")"
  app_ver="$(get_version "$target_app")"

  if [[ "$app_bid" == "unknown" ]]; then
    warn "无法读取 Bundle ID，导出中止。"
    return 1
  fi

  if ! confirm_target_app_quit "$target_app"; then
    info "已取消。"
    return 1
  fi

  container_path="$HOME/Library/Containers/$app_bid"
  discover_group_containers "$target_app" "$app_bid"
  if ! _check_export_disk_space "$target_app" "$container_path"; then
    info "已取消。"
    return 1
  fi

  timestamp="$(date +%Y%m%d-%H%M%S)"
  export_name="${EXPORT_PREFIX}-${app_name%.app}-${timestamp}"
  export_dir="$HOME/Desktop/$export_name"

  if [ -e "$export_dir" ]; then
    warn "目标文件夹已存在：$export_dir"
    return 1
  fi

  echo ""
  step "创建：$export_dir"
  run_cmd mkdir -p "$export_dir/app"
  run_cmd mkdir -p "$export_dir/Library/Containers"
  run_cmd mkdir -p "$export_dir/Library/Group Containers"

  step "复制 App：$app_name"
  if ! run_cmd ditto "$target_app" "$export_dir/app/$app_name"; then
    warn "复制 App 失败。"
    [ "$DRY_RUN" -eq 0 ] && rm -rf "$export_dir"
    return 1
  fi
  if [ "$DRY_RUN" -eq 0 ]; then
    _verify_copy_size "$target_app" "$export_dir/app/$app_name" "App" || {
      rm -rf "$export_dir"
      return 1
    }
  fi

  if [ -d "$container_path" ]; then
    step "复制 Containers：$app_bid"
    if run_cmd ditto "$container_path" "$export_dir/Library/Containers/$app_bid"; then
      if [ "$DRY_RUN" -eq 0 ]; then
        _verify_copy_size "$container_path" "$export_dir/Library/Containers/$app_bid" "Containers" || {
          rm -rf "$export_dir"
          return 1
        }
      fi
      copied_data=1
    else
      warn "复制 Containers 失败。"
      [ "$DRY_RUN" -eq 0 ] && rm -rf "$export_dir"
      return 1
    fi
  else
    warn "未找到 Containers 数据，将仅导出 App（可能尚未登录过）。"
  fi

  local include_shared=1 gc gc_name sgc is_shared
  if [ ${#SHARED_GROUP_CONTAINER_DIRS[@]} -gt 0 ]; then
    _warn_shared_group_containers "导出" || include_shared=0
  fi
  for gc in "${GROUP_CONTAINER_DIRS[@]}"; do
    [ -d "$gc" ] || continue
    is_shared=0
    for sgc in "${SHARED_GROUP_CONTAINER_DIRS[@]}"; do
      [[ "$gc" == "$sgc" ]] && is_shared=1
    done
    [ "$is_shared" -eq 1 ] && [ "$include_shared" -eq 0 ] && continue
    gc_name="$(basename "$gc")"
    step "复制 Group Containers：$gc_name"
    if run_cmd ditto "$gc" "$export_dir/Library/Group Containers/$gc_name"; then
      if [ "$DRY_RUN" -eq 0 ]; then
        _verify_copy_size "$gc" "$export_dir/Library/Group Containers/$gc_name" "Group/$gc_name" || {
          rm -rf "$export_dir"
          return 1
        }
      fi
      group_names+=("$gc_name")
      copied_data=1
    else
      warn "复制 Group Containers 失败：$gc_name"
      [ "$DRY_RUN" -eq 0 ] && rm -rf "$export_dir"
      return 1
    fi
  done

  if [ ${#GROUP_CONTAINER_DIRS[@]} -eq 0 ] && [ -d "$container_path" ]; then
    info "未发现关联 Group Containers（聊天记录主要在 Containers 中）。"
  fi

  step "写入清单 $EXPORT_MANIFEST"
  if ! _write_bundle_manifest "$export_dir" "$target_app" "$app_bid" "$app_ver" "${group_names[@]}"; then
    [ "$DRY_RUN" -eq 0 ] && rm -rf "$export_dir"
    return 1
  fi

  echo ""
  success "已导出到：$export_dir"
  if [ "$copied_data" -eq 0 ]; then
    warn "本次未包含聊天数据，导入后需重新登录。"
  fi
  if [ "$DRY_RUN" -eq 0 ]; then
    run_cmd open "$export_dir"
  fi
}

import_wechat_bundle() {
  echo ""
  echo "======================================"
  echo "从文件夹导入多开微信"
  echo "======================================"
  echo ""
  info "请选择桌面上的备份文件夹，或直接输入完整路径。"
  echo ""

  scan_export_folders

  local export_dir="" i=1
  if [ ${#EXPORT_FOLDERS[@]} -gt 0 ]; then
    echo "在桌面发现以下备份："
    echo ""
    for export_dir in "${EXPORT_FOLDERS[@]}"; do
      _print_export_folder "$export_dir" "$i" || true
      i=$((i+1))
    done
  else
    info "桌面未发现 ${EXPORT_PREFIX}-* 备份文件夹。"
    echo ""
  fi

  read "import_pick?请输入序号或文件夹路径："
  if [ -z "$import_pick" ]; then
    info "已取消。"
    return 1
  fi

  if [[ "$import_pick" =~ ^[0-9]+$ ]] && [ ${#EXPORT_FOLDERS[@]} -gt 0 ]; then
    export_dir="${EXPORT_FOLDERS[$import_pick]:-}"
    if [ -z "$export_dir" ]; then
      warn "序号无效。"
      return 1
    fi
  else
    export_dir="${import_pick/#\~/$HOME}"
    export_dir="${export_dir%/}"
  fi

  [ -d "$export_dir" ] || { warn "文件夹不存在：$export_dir"; return 1; }
  [ -f "$export_dir/$EXPORT_MANIFEST" ] || { warn "不是有效的备份文件夹（缺少 $EXPORT_MANIFEST）。"; return 1; }

  local app_src dest_app container_src container_dest gc_src gc_dest gc_name
  _parse_bundle_manifest "$export_dir" || return 1

  app_src="$export_dir/app/$MANIFEST_APP_NAME"
  [ -d "$app_src" ] || {
    warn "备份中缺少 App：$app_src"
    return 1
  }

  dest_app="/Applications/$MANIFEST_APP_NAME"
  container_src="$export_dir/Library/Containers/$MANIFEST_BUNDLE_ID"
  container_dest="$HOME/Library/Containers/$MANIFEST_BUNDLE_ID"

  echo ""
  info "将导入：$MANIFEST_APP_NAME"
  info "Bundle ID：$MANIFEST_BUNDLE_ID"
  info "版本：$MANIFEST_APP_VERSION"
  info "导出时间：$MANIFEST_EXPORTED_AT"
  info "备份路径：$export_dir"
  echo ""

  if [ -d "$dest_app" ]; then
    warn "目标 App 已存在：$dest_app"
    read "confirm_app?覆盖现有 App？[y/N]："
    [[ "$confirm_app" =~ ^[Yy]$ ]] || { info "已取消。"; return 1; }
  fi

  if ! check_bundle_id_conflict "$MANIFEST_BUNDLE_ID" "$dest_app"; then
    info "已取消。"
    return 1
  fi

  if [ -d "$container_dest" ]; then
    warn "目标数据目录已存在：$container_dest"
    read "confirm_data?覆盖现有聊天数据？[y/N]："
    [[ "$confirm_data" =~ ^[Yy]$ ]] || { info "已取消。"; return 1; }
  fi

  if ! _check_import_disk_space "$export_dir" "$dest_app" "$container_src" "$container_dest"; then
    info "已取消。"
    return 1
  fi

  read "confirm_import_bundle?确认导入？[y/N]："
  [[ "$confirm_import_bundle" =~ ^[Yy]$ ]] || { info "已取消。"; return 1; }

  need_sudo || return 1
  _import_tx_begin

  echo ""
  step "复制 App 到 /Applications ..."
  if [ "$DRY_RUN" -eq 0 ]; then
    _import_tx_stage "$dest_app" sudo || {
      warn "备份现有 App 失败。"
      return 1
    }
    if ! sudo ditto "$app_src" "$dest_app"; then
      warn "复制 App 失败。"
      sudo rm -rf "$dest_app" 2>/dev/null || true
      _import_tx_rollback
      return 1
    fi
    if ! _verify_copy_size "$app_src" "$dest_app" "App"; then
      sudo rm -rf "$dest_app" 2>/dev/null || true
      _import_tx_rollback
      return 1
    fi
  else
    info "[dry-run] sudo ditto $app_src $dest_app"
  fi

  if [ -d "$container_src" ]; then
    step "恢复 Containers 数据..."
    if [ "$DRY_RUN" -eq 0 ]; then
      _import_tx_stage "$container_dest" user || {
        warn "备份现有 Containers 失败。"
        _import_tx_rollback
        return 1
      }
      if ! ditto "$container_src" "$container_dest"; then
        warn "恢复 Containers 失败。"
        rm -rf "$container_dest" 2>/dev/null || true
        _import_tx_rollback
        return 1
      fi
      if ! _verify_copy_size "$container_src" "$container_dest" "Containers"; then
        _import_tx_rollback
        return 1
      fi
    else
      info "[dry-run] ditto $container_src $container_dest"
    fi
  else
    warn "备份中无 Containers 数据，导入后需重新登录。"
  fi

  for gc_name in "${MANIFEST_GROUP_CONTAINERS[@]}"; do
    gc_src="$export_dir/Library/Group Containers/$gc_name"
    gc_dest="$HOME/Library/Group Containers/$gc_name"
    [ -d "$gc_src" ] || continue
    step "恢复 Group Containers：$gc_name"
    if [ "$DRY_RUN" -eq 0 ]; then
      _import_tx_stage "$gc_dest" user || {
        warn "备份 Group Containers 失败：$gc_name"
        _import_tx_rollback
        return 1
      }
      if ! ditto "$gc_src" "$gc_dest"; then
        warn "恢复 Group Containers 失败：$gc_name"
        rm -rf "$gc_dest" 2>/dev/null || true
        _import_tx_rollback
        return 1
      fi
      if ! _verify_copy_size "$gc_src" "$gc_dest" "Group/$gc_name"; then
        _import_tx_rollback
        return 1
      fi
    else
      info "[dry-run] ditto $gc_src $gc_dest"
    fi
  done

  import_multi_app "$dest_app" || {
    _import_tx_rollback
    return 1
  }

  if [ "$DRY_RUN" -eq 0 ]; then
    fix_signature "$dest_app" || warn "签名修复未完全成功，可稍后使用菜单 8 重试。"
    _import_tx_commit
  else
    info "[dry-run] fix_signature $dest_app"
  fi

  echo ""
  success "导入完成：$MANIFEST_APP_NAME"
  verify_app_launch "$dest_app" || true
  info "可在启动台或 /Applications/ 中打开登录。"
  invalidate_multi_scan
}

show_menu() {
  echo "────────────────────────────────────"
  echo "请选择操作："
  echo ""
  echo "  查看"
  echo "  1)  只查看列表，不操作"
  echo "  2)  检查更新状态"
  echo "  3)  查看详细信息"
  echo ""
  echo "  创建与升级"
  echo "  4)  新建一个多开微信"
  echo "  5)  导入已有多开微信"
  echo "  6)  升级某一个多开微信"
  echo "  7)  升级全部多开微信"
  echo ""
  echo "  维护与数据"
  echo "  8)  修复某一个多开微信签名"
  echo "  9)  打开多开微信数据目录"
  echo "  10) 检查某一个多开微信数据占用"
  echo "  11) 导出某一个多开微信到桌面文件夹"
  echo "  12) 从文件夹导入多开微信"
  echo ""
  echo "  其他"
  echo "  13) 删除某一个多开微信"
  echo "  14) 恢复升级失败留下的备份"
  echo ""
  echo "  0)  退出"
  echo "────────────────────────────────────"
  echo ""
}

# ──────────────────────────────────────────────
# 签名验证（codesign + spctl）
# ──────────────────────────────────────────────
verify_signature() {
  local target_app="$1"

  step "验证签名（codesign）..."
  if codesign --verify --strict "$target_app" >/dev/null 2>&1; then
    info "codesign 验证通过。"
  else
    warn "codesign 验证未完全通过，本地运行通常不受影响。"
  fi

  step "验证签名（spctl）..."
  local spctl_out spctl_note
  spctl_out="$(spctl --assess --type exec "$target_app" 2>&1 || true)"
  # ad-hoc 签名会被 spctl 标记为 rejected，这是预期结果，不影响本地运行
  if echo "$spctl_out" | grep -q "rejected"; then
    spctl_note="rejected（ad-hoc 签名的正常现象，不影响本地运行）"
  elif echo "$spctl_out" | grep -q "accepted"; then
    spctl_note="accepted ✓"
  else
    spctl_note="${spctl_out:-（无输出）}"
  fi
  info "spctl：$spctl_note"
}

# ──────────────────────────────────────────────
# 事务回滚：backup 还原 / 半成品清理
# rollback_upgrade <target_app> <backup_path>
# ──────────────────────────────────────────────
rollback_upgrade() {
  local target_app="$1"
  local backup_path="$2"
  local app_name="${target_app:t}"

  if [ -d "$target_app" ]; then
    sudo rm -rf "$target_app" 2>/dev/null || true
  fi

  if [ -d "$backup_path" ]; then
    warn "正在还原旧副本..."
    if sudo mv "$backup_path" "$target_app"; then
      success "已还原：$app_name"
    else
      warn "还原失败，旧副本保留在：$backup_path"
      warn "请使用菜单 14) 恢复升级失败留下的备份 手动处理。"
    fi
  fi
}

# ──────────────────────────────────────────────
# 核心操作：创建 / 升级副本（事务式）
# ──────────────────────────────────────────────
create_or_replace_multi() {
  local target_app="$1"
  local bundle_id="$2"
  local app_name backup_path
  app_name="$(basename "$target_app")"
  backup_path="${target_app}.backup"

  echo ""
  echo "--------------------------------------"
  step "目标：$target_app"
  step "Bundle ID：$bundle_id"
  [ "$DRY_RUN" -eq 1 ] && step "[dry-run 模式，以下操作均不会实际执行]"
  echo "--------------------------------------"

  # ── 事务式升级：旧副本先改名为 .backup，成功后再删除 ──
  if [ -d "$target_app" ]; then
    step "备份旧副本..."
    if [ "$DRY_RUN" -eq 0 ]; then
      # 检测上次升级残留的 .backup，询问用户如何处理
      if [ -d "$backup_path" ]; then
        echo ""
        warn "检测到残留备份：$backup_path"
        info "这可能是上次升级中途失败留下的。"
        echo ""
        echo "  1) 删除备份，继续本次升级"
        echo "  2) 恢复备份（放弃本次升级）"
        echo "  3) 取消"
        echo ""
        read "backup_choice?请选择 [1/2/3]："
        case "$backup_choice" in
          1)
            if ! sudo rm -rf "$backup_path"; then
              warn "删除残留备份失败。"
              return 1
            fi
            ;;
          2)
            warn "正在恢复备份..."
            [ -d "$target_app" ] && sudo rm -rf "$target_app"
            if sudo mv "$backup_path" "$target_app"; then
              success "已恢复：$app_name"
            else
              warn "恢复备份失败。"
            fi
            return 0
            ;;
          *)
            info "已取消。"
            return 1
            ;;
        esac
      fi
      if ! sudo mv "$target_app" "$backup_path"; then
        warn "备份旧副本失败，已中止。"
        return 1
      fi
    else
      info "[dry-run] mv $target_app → $backup_path"
    fi
  fi

  step "复制原版微信（可能需要十几秒）..."
  if [ "$DRY_RUN" -eq 0 ]; then
    if ! sudo ditto "$SOURCE_APP" "$target_app"; then
      rollback_upgrade "$target_app" "$backup_path"
      warn "复制微信失败，已回滚。"
      return 1
    fi
    _verify_copy_size "$SOURCE_APP" "$target_app" "App" || {
      rollback_upgrade "$target_app" "$backup_path"
      warn "复制体积校验失败，已回滚。"
      return 1
    }
  else
    info "[dry-run] sudo ditto $SOURCE_APP $target_app"
  fi

  step "修改 Bundle ID..."
  if [ "$DRY_RUN" -eq 0 ]; then
    if ! sudo "$PLISTBUDDY" \
      -c "Set :CFBundleIdentifier $bundle_id" \
      "$target_app/Contents/Info.plist"; then
      rollback_upgrade "$target_app" "$backup_path"
      warn "Bundle ID 修改失败，已回滚。"
      return 1
    fi

    # 写后校验
    local after_bid
    after_bid="$(get_bundle_id "$target_app")"
    if [ "$after_bid" != "$bundle_id" ]; then
      rollback_upgrade "$target_app" "$backup_path"
      warn "Bundle ID 校验失败（期望 $bundle_id，实际 $after_bid），已回滚。"
      return 1
    fi
  else
    info "[dry-run] PlistBuddy Set :CFBundleIdentifier $bundle_id"
  fi

  step "写入托管标记..."
  write_managed_marker "$target_app"

  step "清除扩展属性..."
  if [ "$DRY_RUN" -eq 0 ]; then
    if ! sudo xattr -cr "$target_app"; then
      rollback_upgrade "$target_app" "$backup_path"
      warn "清除扩展属性失败，已回滚。"
      return 1
    fi
  else
    run_cmd sudo xattr -cr "$target_app"
  fi

  step "重新签名..."
  if [ "$DRY_RUN" -eq 0 ]; then
    if ! sudo codesign --force --deep --sign - "$target_app"; then
      rollback_upgrade "$target_app" "$backup_path"
      warn "签名失败，已回滚。"
      return 1
    fi
    verify_signature "$target_app"
  else
    run_cmd sudo codesign --force --deep --sign - "$target_app"
  fi

  # ── 一切成功，删除 backup ──
  if [ "$DRY_RUN" -eq 0 ] && [ -d "$backup_path" ]; then
    step "清理旧备份..."
    sudo rm -rf "$backup_path" || warn "旧备份清理失败，可手动删除：$backup_path"
  elif [ "$DRY_RUN" -eq 1 ]; then
    run_cmd sudo rm -rf "$backup_path"
  fi

  # 写入托管记录
  if [ "$DRY_RUN" -eq 0 ]; then
    json_register "$target_app" "$bundle_id" 2>/dev/null || \
      warn "写入托管记录失败（不影响使用）。"
  fi

  success "完成：$app_name"
  verify_app_launch "$target_app" || true
  invalidate_multi_scan
}

# ──────────────────────────────────────────────
# 核心操作：仅修复签名（不重建）
# ──────────────────────────────────────────────
fix_signature() {
  local target_app="$1"
  local app_name
  app_name="$(basename "$target_app")"

  echo ""
  echo "--------------------------------------"
  step "修复签名：$target_app"
  [ "$DRY_RUN" -eq 1 ] && step "[dry-run 模式]"
  echo "--------------------------------------"

  step "清除扩展属性..."
  if ! run_cmd sudo xattr -cr "$target_app"; then
    warn "清除扩展属性失败。"
    return 1
  fi

  step "重新签名..."
  if [ "$DRY_RUN" -eq 0 ]; then
    if ! sudo codesign --force --deep --sign - "$target_app"; then
      warn "签名失败。"
      return 1
    fi
    verify_signature "$target_app"
  else
    run_cmd sudo codesign --force --deep --sign - "$target_app"
  fi

  success "签名修复完成：$app_name"
}

# ──────────────────────────────────────────────
# 核心操作：删除副本（移到废纸篓）
# ──────────────────────────────────────────────
delete_multi_app() {
  local target_app="$1"
  local app_name
  app_name="$(basename "$target_app")"

  echo ""
  warn "准备删除：$target_app"

  # 非托管副本需要二次确认
  if ! json_is_managed "$target_app" 2>/dev/null; then
    warn "此 App 不在托管记录中，可能不是本脚本创建的副本！"
    read "confirm_unmanaged?仍然继续删除？[y/N]："
    [[ "$confirm_unmanaged" =~ ^[Yy]$ ]] || { info "已取消。"; return 1; }
  fi

  read "confirm_delete?确认删除 $app_name？将移入废纸篓（可恢复）。[y/N]："
  [[ "$confirm_delete" =~ ^[Yy]$ ]] || { info "已取消。"; return 1; }

  need_sudo || return 1
  wait_wechat_exit || return 1

  if [ "$DRY_RUN" -eq 0 ]; then
    # 废纸篓里已有同名文件则加时间戳
    local trash_path="$HOME/.Trash/${app_name}"
    if [ -e "$trash_path" ]; then
      trash_path="$HOME/.Trash/${app_name%.app}_$(date +%Y%m%d_%H%M%S).app"
    fi

    # 优先用 sudo mv；失败则 fallback 到 osascript（通过 Finder 移入废纸篓）
    if sudo mv "$target_app" "$trash_path" 2>/dev/null; then
      : # 成功
    else
      warn "sudo mv 失败，尝试通过 Finder 移入废纸篓..."
      if ! osascript -e \
        "tell application \"Finder\" to delete POSIX file \"$target_app\"" \
        >/dev/null 2>&1; then
        warn "移入废纸篓失败，请手动删除：$target_app"
        return 1
      fi
    fi

    json_unregister "$target_app" 2>/dev/null || true
    success "已移入废纸篓：$app_name"
    info "如需彻底删除，请在访达中清空废纸篓。"
    invalidate_multi_scan
  else
    info "[dry-run] mv $target_app ~/.Trash/"
  fi
}

# ──────────────────────────────────────────────
# 更新状态检测
# ──────────────────────────────────────────────
check_updates() {
  ensure_multi_apps_scanned

  echo ""
  echo "======================================"
  echo "更新状态"
  echo "======================================"
  echo ""
  info "原版微信版本：$SOURCE_VERSION"
  echo ""

  if [ ${#MULTI_APPS[@]} -eq 0 ]; then
    info "暂无多开副本。"
    return
  fi

  local needs_upgrade=0 app_name version app_bid
  for app in "${MULTI_APPS[@]}"; do
    app_name=${app:t}
    version="$(get_version "$app")"
    app_bid="$(get_bundle_id "$app")"

    if [ "$version" = "$SOURCE_VERSION" ]; then
      echo "✅ $app_name"
      info "版本 $version — 已是最新"
    else
      echo "⚠️  $app_name"
      info "版本 $version → 需要升级到 $SOURCE_VERSION"
      needs_upgrade=$((needs_upgrade+1))
    fi
    echo ""
  done

  if [ "$needs_upgrade" -gt 0 ]; then
    warn "共 $needs_upgrade 个副本需要升级，请使用菜单选项 6 或 7 升级。"
  else
    success "所有副本均为最新版本。"
  fi
}

# ──────────────────────────────────────────────
# 查看详细信息 + 导出配置
# ──────────────────────────────────────────────
show_detail() {
  echo ""
  echo "======================================"
  echo "详细信息"
  echo "======================================"
  echo ""
  echo "原版微信"
  info "路径：      $SOURCE_APP"
  info "版本：      $SOURCE_VERSION"
  info "Bundle ID： $SOURCE_BUNDLE_ID"
  local src_sig
  src_sig="$(codesign --verify --strict "$SOURCE_APP" >/dev/null 2>&1 && echo "正常" || echo "异常")"
  info "签名状态：  $src_sig"
  echo ""

  ensure_multi_apps_scanned

  if [ ${#MULTI_APPS[@]} -eq 0 ]; then
    info "暂无多开副本。"
  else
    echo "多开副本"
    echo ""
    local i=1 app_name version app_bid sig managed_mark created_at
    for app in "${MULTI_APPS[@]}"; do
      app_name=${app:t}
      version="$(get_version "$app")"
      app_bid="$(get_bundle_id "$app")"
      sig="$(codesign --verify --strict "$app" >/dev/null 2>&1 && echo "正常" || echo "异常⚠️")"
      managed_mark="否"
      created_at="-"

      if json_is_managed "$app" 2>/dev/null; then
        managed_mark="是"
        created_at="$(json_created_at "$app" 2>/dev/null || echo "-")"
      fi

      info "$i) $app_name"
      info "   路径：       $app"
      info "   Bundle ID：  $app_bid"
      info "   版本：       $version"
      info "   签名：       $sig"
      info "   托管记录：   $managed_mark"
      info "   创建时间：   $created_at"
      echo ""
      i=$((i+1))
    done
  fi

  info "配置文件：$MANAGED_JSON"
  info "日志目录：$LOG_DIR"
  echo ""

  # 导出配置（换电脑可参考恢复）
  echo "────────────────────────────────────"
  echo "导出配置（可用于换电脑后参考恢复）："
  echo ""
  json_export 2>/dev/null || info "（无托管记录可导出）"
  echo ""
}

# ──────────────────────────────────────────────
# 批量升级（含失败汇总）
# ──────────────────────────────────────────────
_upgrade_all() {
  local success_list=()
  local fail_list=()
  local skip_list=()

  export SKIP_LAUNCH_VERIFY=1

  local BID app_name cur_ver
  for app in "${MULTI_APPS[@]}"; do
    BID="$(get_bundle_id "$app")"
    app_name=${app:t}

    if [[ "$BID" == "unknown" ]] || [[ "$BID" == "$SOURCE_BUNDLE_ID" ]]; then
      warn "跳过 $app_name：Bundle ID 异常（$BID）"
      skip_list+=("$app_name")
      continue
    fi

    cur_ver="$(get_version "$app")"
    if [ "$cur_ver" = "$SOURCE_VERSION" ] && [ "$DRY_RUN" -eq 0 ]; then
      info "跳过 $app_name：已是最新版本（$cur_ver）"
      skip_list+=("$app_name")
      continue
    fi

    # 在子 shell 里运行，捕获失败而不退出整个脚本
    if ( create_or_replace_multi "$app" "$BID" ); then
      success_list+=("$app_name")
    else
      warn "$app_name 升级失败，继续下一个..."
      fail_list+=("$app_name")
    fi
  done

  echo ""
  echo "────────────────────────────────────"
  echo "批量升级汇总"
  info "成功：${#success_list[@]} 个$([ ${#success_list[@]} -gt 0 ] && echo "  — $(printf '%s  ' "${success_list[@]}")")"
  info "跳过：${#skip_list[@]} 个$([ ${#skip_list[@]} -gt 0 ]  && echo "  — $(printf '%s  ' "${skip_list[@]}")")"
  info "失败：${#fail_list[@]} 个$([ ${#fail_list[@]} -gt 0 ]  && echo "  — $(printf '%s  ' "${fail_list[@]}")")"
  echo "────────────────────────────────────"

  [ ${#fail_list[@]} -gt 0 ] && warn "部分副本升级失败，请查看日志：$LOG_FILE"
  [ ${#success_list[@]} -gt 0 ] && {
    invalidate_multi_scan
    info "批量升级未逐个启动自检，请自行打开各副本验证能否登录。"
  }
  unset SKIP_LAUNCH_VERIFY
}

# ──────────────────────────────────────────────
# Bundle ID 冲突检测（直接扫描 /Applications，不依赖 JSON）
# ──────────────────────────────────────────────
check_bundle_id_conflict() {
  local bundle_id="$1"
  local exclude_app="${2:-}"
  local conflicts=()

  local app app_bid
  for app in /Applications/*.app; do
    [ -d "$app" ] || continue
    [[ "$app" == "$SOURCE_APP" ]] && continue
    [ -n "$exclude_app" ] && [[ "$app" == "$exclude_app" ]] && continue
    app_bid="$(get_bundle_id "$app")"
    if [ "$app_bid" = "$bundle_id" ]; then
      conflicts+=("$app")
    fi
  done

  if [ ${#conflicts[@]} -gt 0 ]; then
    warn "Bundle ID「$bundle_id」已被以下 App 使用："
    for c in "${conflicts[@]}"; do
      info "  $c"
    done
    echo ""
    if [ "$DRY_RUN" -eq 1 ]; then
      info "[dry-run] 如果真实执行，将在此处要求确认是否继续。"
    else
      read "confirm_conflict?Bundle ID 冲突可能导致两个副本互相干扰，确认继续？[y/N]："
      [[ "$confirm_conflict" =~ ^[Yy]$ ]] || return 1
    fi
  fi
  return 0
}

# ══════════════════════════════════════════════
# 启动
# ══════════════════════════════════════════════
check_env

echo ""
json_cleanup_orphans
ensure_multi_apps_scanned

while true; do
  # 每轮刷新：残留 backup 提示 + 多开列表
  STALE_COUNT=0
  for bak in /Applications/*.app.backup; do
    [ -d "$bak" ] && STALE_COUNT=$((STALE_COUNT+1))
  done
  [ "$STALE_COUNT" -gt 0 ] && \
    warn "发现 $STALE_COUNT 个残留升级备份，可通过菜单选项 14 处理。"
  echo ""

  print_multi_apps
  show_menu

  read "choice?输入数字："

  case "$choice" in

  # ── 0 退出 ──────────────────────────────────
  0)
    break
    ;;

  # ── 1 只查看 ────────────────────────────────
  1)
    info "未执行任何修改。"
    ;;

  # ── 2 检查更新状态 ───────────────────────────
  2)
    check_updates
    ;;

  # ── 3 详细信息 ──────────────────────────────
  3)
    show_detail
    ;;

  # ── 4 新建 ──────────────────────────────────
  4)
    read "suffix?请输入多开编号/名称（如 01 / work / personal）："

    if [ -z "$suffix" ]; then
      warn "编号不能为空。"
    elif ! [[ "$suffix" =~ ^[A-Za-z0-9_-]+$ ]]; then
      warn "编号只能包含英文、数字、下划线或短横线。"
    elif ! check_bundle_id_conflict "${MULTI_BUNDLE_PREFIX}.${suffix}"; then
      info "已取消。"
    else
      TARGET_APP="/Applications/${MULTI_NAME_PREFIX}-${suffix}.app"
      BUNDLE_ID="${MULTI_BUNDLE_PREFIX}.${suffix}"

      if [ -d "$TARGET_APP" ]; then
        warn "$TARGET_APP 已存在。"
        read "confirm?继续会删除并重建，确认继续？[y/N]："
        if ! [[ "$confirm" =~ ^[Yy]$ ]]; then
          info "已取消。"
        else
          _run_with_sudo_and_wechat_closed create_or_replace_multi "$TARGET_APP" "$BUNDLE_ID"
        fi
      else
        _run_with_sudo_and_wechat_closed create_or_replace_multi "$TARGET_APP" "$BUNDLE_ID"
      fi
    fi
    ;;

  # ── 5 导入已有多开 ─────────────────────────
  5)
    if print_importable_apps && pick_importable_by_num "请输入要导入的序号："; then
      TARGET_APP="$PICKED_APP"
      BUNDLE_ID="$(get_bundle_id "$TARGET_APP")"
      echo ""
      info "将导入：$(basename "$TARGET_APP")"
      info "Bundle ID：$BUNDLE_ID"
      read "confirm_import?确认导入？[y/N]："
      if [[ "$confirm_import" =~ ^[Yy]$ ]]; then
        import_multi_app "$TARGET_APP"
      else
        info "已取消。"
      fi
    fi
    ;;

  # ── 6 升级单个 ──────────────────────────────
  6)
    print_multi_apps
    if [ ${#MULTI_APPS[@]} -eq 0 ]; then
      warn "没有可升级的多开微信。"
    elif pick_app_by_num "请输入要升级的序号："; then
      TARGET_APP="$PICKED_APP"
      BUNDLE_ID="$(get_bundle_id "$TARGET_APP")"

      if [[ "$BUNDLE_ID" == "unknown" ]] || [[ "$BUNDLE_ID" == "$SOURCE_BUNDLE_ID" ]]; then
        read "BUNDLE_ID?当前 Bundle ID 异常，请手动输入（如 ${MULTI_BUNDLE_PREFIX}.work）："
        if [ -z "$BUNDLE_ID" ]; then
          warn "Bundle ID 不能为空。"
        else
          _run_with_sudo_and_wechat_closed create_or_replace_multi "$TARGET_APP" "$BUNDLE_ID"
        fi
      else
        _run_with_sudo_and_wechat_closed create_or_replace_multi "$TARGET_APP" "$BUNDLE_ID"
      fi
    fi
    ;;

  # ── 7 升级全部 ──────────────────────────────
  7)
    print_multi_apps
    if [ ${#MULTI_APPS[@]} -eq 0 ]; then
      warn "没有可升级的多开微信。"
    else
      read "confirm_all?确认升级全部 ${#MULTI_APPS[@]} 个？[y/N]："
      if [[ "$confirm_all" =~ ^[Yy]$ ]]; then
        _run_with_sudo_and_wechat_closed _upgrade_all
      else
        info "已取消。"
      fi
    fi
    ;;

  # ── 8 修复签名 ──────────────────────────────
  8)
    print_multi_apps
    if [ ${#MULTI_APPS[@]} -eq 0 ]; then
      warn "没有可修复的多开微信。"
    elif pick_app_by_num "请输入要修复签名的序号："; then
      TARGET_APP="$PICKED_APP"
      echo ""
      info "修复签名：只重新签名，不重建 App 文件。"
      info "适用于：打开提示「已损坏」但文件本身完整的情况。"
      info "如需完整重建，请使用「升级」功能。"
      if confirm_target_app_quit "$TARGET_APP"; then
        _run_with_sudo fix_signature "$TARGET_APP"
      else
        info "已取消。"
      fi
    fi
    ;;

  # ── 9 打开数据目录 ─────────────────────────
  9)
    open_multi_data_dir
    ;;

  # ── 10 检查占用 ─────────────────────────────
  10)
    check_storage_usage
    ;;

  # ── 11 导出到桌面 ───────────────────────────
  11)
    export_wechat_bundle
    ;;

  # ── 12 从文件夹导入 ─────────────────────────
  12)
    import_wechat_bundle
    ;;

  # ── 13 删除 ──────────────────────────────────
  13)
    print_multi_apps
    if [ ${#MULTI_APPS[@]} -eq 0 ]; then
      warn "没有可删除的多开微信。"
    elif pick_app_by_num "请输入要删除的序号："; then
      TARGET_APP="$PICKED_APP"
      delete_multi_app "$TARGET_APP"
    fi
    ;;

  # ── 14 恢复备份 ──────────────────────────────
  14)
    echo ""
    step "扫描升级失败留下的备份..."
    STALE_BACKUPS=()
    for bak in /Applications/*.app.backup; do
      [ -d "$bak" ] && STALE_BACKUPS+=("$bak")
    done

    if [ ${#STALE_BACKUPS[@]} -eq 0 ]; then
      info "未发现残留备份。"
    else
      echo ""
      echo "发现以下残留备份："
      echo ""
      i=1
      for bak in "${STALE_BACKUPS[@]}"; do
        orig="${bak%.backup}"
        bak_ver="$(get_version "$bak")"
        echo "  $i) $(basename "$bak")"
        info "   备份版本：$bak_ver"
        info "   对应路径：$orig"
        info "   当前状态：$([ -d "$orig" ] && echo "原路径已存在（新版本已建好）" || echo "原路径不存在（升级中断）")"
        echo ""
        i=$((i+1))
      done

      read "bak_num?请输入要处理的备份序号（直接回车跳过）："
      if [ -n "$bak_num" ]; then
        if ! [[ "$bak_num" =~ ^[0-9]+$ ]]; then
          warn "请输入有效数字。"
        else
          PICKED_BAK="${STALE_BACKUPS[$bak_num]:-}"
          if [ -z "$PICKED_BAK" ] || [ ! -d "$PICKED_BAK" ]; then
            warn "序号无效。"
          else
            ORIG_APP="${PICKED_BAK%.backup}"
            echo ""
            echo "  1) 恢复备份（替换或还原到 $(basename "$ORIG_APP")）"
            echo "  2) 删除备份（保留当前状态）"
            echo "  3) 取消"
            echo ""
            read "bak_action?请选择 [1/2/3]："
            if need_sudo; then
              case "$bak_action" in
                1)
                  [ -d "$ORIG_APP" ] && sudo rm -rf "$ORIG_APP"
                  if sudo mv "$PICKED_BAK" "$ORIG_APP"; then
                    success "已恢复：$(basename "$ORIG_APP")"
                    invalidate_multi_scan
                  else
                    warn "恢复失败。"
                  fi
                  ;;
                2)
                  if sudo rm -rf "$PICKED_BAK"; then
                    success "已删除备份：$(basename "$PICKED_BAK")"
                  else
                    warn "删除备份失败。"
                  fi
                  ;;
                *)
                  info "已取消。"
                  ;;
              esac
            fi
          fi
        fi
      fi
    fi
    ;;

  *)
    warn "无效选择，请输入 0-14。"
    ;;
  esac

  echo ""
done

echo ""
echo "======================================"
echo "已退出。日志已保存至："
echo "$LOG_FILE"
echo "======================================"

pause_on_exit