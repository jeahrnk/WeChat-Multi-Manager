#!/bin/zsh
# =============================================================================
#  WeChat Multi Manager  v1.5.1
#  支持 macOS 13+，Apple Silicon / Intel 均可
#
#  功能：新建 / 升级 / 修复签名 / 删除 多开微信副本
#  用法：chmod +x wechat-multi.sh && ./wechat-multi.sh [--dry-run]
#
#  GitHub / 小红书分享版
# =============================================================================

set -u

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
readonly VERSION="1.5.1"

readonly CONFIG_DIR="$HOME/.config/wechat-multi"
readonly MANAGED_JSON="$CONFIG_DIR/managed_apps.json"
readonly MANAGED_JSON_BAK="$CONFIG_DIR/managed_apps.json.bak"

readonly LOG_DIR="$HOME/Library/Logs/WeChatMultiManager"
readonly LOG_FILE="$LOG_DIR/$(date +%Y-%m-%d_%H%M%S).log"

# ──────────────────────────────────────────────
# 全局状态
# ──────────────────────────────────────────────
MULTI_APPS=()
PICKED_APP=""
SUDO_KEEPALIVE_PID=""
SOURCE_APP=""
SOURCE_VERSION=""
SOURCE_BUNDLE_ID=""
_sudo_acquired=0

# ──────────────────────────────────────────────
# 日志：所有输出同时写终端和日志文件
# ──────────────────────────────────────────────
mkdir -p "$LOG_DIR"
exec > >(tee -a "$LOG_FILE") 2>&1

# ──────────────────────────────────────────────
# UI 工具
# ──────────────────────────────────────────────
clear
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

pause() {
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
  "$PLISTBUDDY" -c "Print :CFBundleShortVersionString" \
    "$1/Contents/Info.plist" 2>/dev/null || echo "unknown"
}

get_bundle_id() {
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
  sudo -v || die "sudo 鉴权失败。"

  ( while true; do sudo -n true 2>/dev/null; sleep 60; done ) &
  SUDO_KEEPALIVE_PID=$!
  _sudo_acquired=1
}

# ──────────────────────────────────────────────
# 微信进程管理
# ──────────────────────────────────────────────
wait_wechat_exit() {
  step "正在关闭所有微信相关进程..."

  if [ "$DRY_RUN" -eq 1 ]; then
    info "[dry-run] 跳过关闭微信进程"
    return
  fi

  # 关闭主进程和常见辅助进程
  pkill -x "WeChat"       2>/dev/null || true
  pkill -x "微信"          2>/dev/null || true
  pkill -f "WeChatAppEx"  2>/dev/null || true
  pkill -f "WeChat Helper" 2>/dev/null || true

  for i in {1..15}; do
    # 用 pgrep -af 检测所有包含 WeChat / 微信 的进程
    if ! pgrep -af "[Ww]e[Cc]hat" >/dev/null 2>&1 && \
       ! pgrep -af "微信"          >/dev/null 2>&1; then
      success "微信已退出。"
      return
    fi
    sleep 1
  done

  warn "微信相关进程似乎仍未完全退出（等待超时）。"
  info "残留进程："
  pgrep -af "[Ww]e[Cc]hat" 2>/dev/null || true
  echo ""
  read "force_close?是否强制继续？[y/N]："
  [[ "$force_close" =~ ^[Yy]$ ]] || die "已取消。"
}

# ──────────────────────────────────────────────
# 扫描 / 展示
# ──────────────────────────────────────────────
scan_multi_apps() {
  MULTI_APPS=()

  for app in /Applications/*.app; do
    [ -d "$app" ] || continue
    [[ "$app" == "$SOURCE_APP" ]] && continue

    local name bid
    name="$(basename "$app")"
    bid="$(get_bundle_id "$app")"

    local by_name=0 by_bid=0 by_json=0 by_marker=0
    [[ "$name" == ${MULTI_NAME_PREFIX}* ]]                              && by_name=1
    [[ "$bid"  == ${MULTI_BUNDLE_PREFIX}* ]]                            && by_bid=1
    json_is_managed "$app" 2>/dev/null                                  && by_json=1
    [ -f "$app/Contents/Resources/${MARKER_FILENAME}" ]                 && by_marker=1

    if [ "$by_name" -eq 1 ] || [ "$by_bid" -eq 1 ] || \
       [ "$by_json" -eq 1 ] || [ "$by_marker" -eq 1 ]; then
      MULTI_APPS+=("$app")
    fi
  done
}

print_multi_apps() {
  scan_multi_apps

  if [ ${#MULTI_APPS[@]} -eq 0 ]; then
    info "未发现已有多开微信。"
    return
  fi

  echo "发现以下多开微信："
  echo ""

  local i=1
  for app in "${MULTI_APPS[@]}"; do
    local name version bid icon status managed_mark
    name="$(basename "$app")"
    version="$(get_version "$app")"
    bid="$(get_bundle_id "$app")"
    managed_mark=""
    json_is_managed "$app" 2>/dev/null && managed_mark=" [托管]"

    if [ "$version" = "$SOURCE_VERSION" ]; then
      icon="✅"; status="版本一致"
    else
      icon="⚠️ "; status="需要升级  (当前 $version → 原版 $SOURCE_VERSION)"
    fi

    echo "$icon $i) $name$managed_mark"
    echo "      路径：$app"
    echo "      Bundle ID：$bid"
    echo "      状态：$status"
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

  [[ "$num" =~ ^[0-9]+$ ]] || die "请输入有效数字。"

  PICKED_APP="${MULTI_APPS[$num]:-}"
  if [ -z "$PICKED_APP" ] || [ ! -d "$PICKED_APP" ]; then
    die "序号无效或路径不存在。"
  fi
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

  if [ -d "$backup_path" ] && [ ! -d "$target_app" ]; then
    warn "正在还原旧副本..."
    sudo mv "$backup_path" "$target_app" 2>/dev/null && \
      info "已还原：$(basename "$target_app")" || \
      warn "还原失败，旧副本保留在：$backup_path"
  elif [ -d "$target_app" ]; then
    # 新副本建了一半，清理掉
    sudo rm -rf "$target_app" 2>/dev/null || true
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
          1) sudo rm -rf "$backup_path" || die "删除残留备份失败。" ;;
          2)
            warn "正在恢复备份..."
            [ -d "$target_app" ] && sudo rm -rf "$target_app"
            sudo mv "$backup_path" "$target_app" || die "恢复备份失败。"
            success "已恢复：$app_name"
            return 0
            ;;
          *) die "已取消。" ;;
        esac
      fi
      sudo mv "$target_app" "$backup_path" || die "备份旧副本失败，已中止。"
    else
      info "[dry-run] mv $target_app → $backup_path"
    fi
  fi

  step "复制原版微信（可能需要十几秒）..."
  if [ "$DRY_RUN" -eq 0 ]; then
    sudo cp -R "$SOURCE_APP" "$target_app" || {
      rollback_upgrade "$target_app" "$backup_path"
      die "复制微信失败，已回滚。"
    }
  else
    info "[dry-run] cp -R $SOURCE_APP $target_app"
  fi

  step "修改 Bundle ID..."
  if [ "$DRY_RUN" -eq 0 ]; then
    sudo "$PLISTBUDDY" \
      -c "Set :CFBundleIdentifier $bundle_id" \
      "$target_app/Contents/Info.plist" || {
        rollback_upgrade "$target_app" "$backup_path"
        die "Bundle ID 修改失败，已回滚。"
      }

    # 写后校验
    local after_bid
    after_bid="$(get_bundle_id "$target_app")"
    if [ "$after_bid" != "$bundle_id" ]; then
      rollback_upgrade "$target_app" "$backup_path"
      die "Bundle ID 校验失败（期望 $bundle_id，实际 $after_bid），已回滚。"
    fi
  else
    info "[dry-run] PlistBuddy Set :CFBundleIdentifier $bundle_id"
  fi

  step "写入托管标记..."
  if [ "$DRY_RUN" -eq 0 ]; then
    sudo mkdir -p "$target_app/Contents/Resources" && \
    sudo sh -c "echo 'WeChat Multi Manager v${VERSION}' > \
      '$target_app/Contents/Resources/${MARKER_FILENAME}'" || \
      warn "写入托管标记失败（不影响使用）。"
  else
    info "[dry-run] 写入 $target_app/Contents/Resources/${MARKER_FILENAME}"
  fi

  step "清除扩展属性..."
  if [ "$DRY_RUN" -eq 0 ]; then
    sudo xattr -cr "$target_app" || {
      rollback_upgrade "$target_app" "$backup_path"
      die "清除扩展属性失败，已回滚。"
    }
  else
    run_cmd sudo xattr -cr "$target_app"
  fi

  step "重新签名..."
  if [ "$DRY_RUN" -eq 0 ]; then
    sudo codesign --force --deep --sign - "$target_app" || {
      rollback_upgrade "$target_app" "$backup_path"
      die "签名失败，已回滚。"
    }
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
  run_cmd sudo xattr -cr "$target_app" || die "清除扩展属性失败。"

  step "重新签名..."
  if [ "$DRY_RUN" -eq 0 ]; then
    sudo codesign --force --deep --sign - "$target_app" || die "签名失败。"
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
    [[ "$confirm_unmanaged" =~ ^[Yy]$ ]] || die "已取消。"
  fi

  read "confirm_delete?确认删除 $app_name？将移入废纸篓（可恢复）。[y/N]："
  [[ "$confirm_delete" =~ ^[Yy]$ ]] || die "已取消。"

  need_sudo
  wait_wechat_exit

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
      osascript -e \
        "tell application \"Finder\" to delete POSIX file \"$target_app\"" \
        >/dev/null 2>&1 || die "移入废纸篓失败，请手动删除：$target_app"
    fi

    json_unregister "$target_app" 2>/dev/null || true
    success "已移入废纸篓：$app_name"
    info "如需彻底删除，请在访达中清空废纸篓。"
  else
    info "[dry-run] mv $target_app ~/.Trash/"
  fi
}

# ──────────────────────────────────────────────
# 更新状态检测
# ──────────────────────────────────────────────
check_updates() {
  scan_multi_apps

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

  local needs_upgrade=0
  for app in "${MULTI_APPS[@]}"; do
    local name version bid
    name="$(basename "$app")"
    version="$(get_version "$app")"
    bid="$(get_bundle_id "$app")"

    if [ "$version" = "$SOURCE_VERSION" ]; then
      echo "✅ $name"
      info "版本 $version — 已是最新"
    else
      echo "⚠️  $name"
      info "版本 $version → 需要升级到 $SOURCE_VERSION"
      needs_upgrade=$((needs_upgrade+1))
    fi
    echo ""
  done

  if [ "$needs_upgrade" -gt 0 ]; then
    warn "共 $needs_upgrade 个副本需要升级，请使用菜单选项 2 或 3 升级。"
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

  scan_multi_apps

  if [ ${#MULTI_APPS[@]} -eq 0 ]; then
    info "暂无多开副本。"
  else
    echo "多开副本"
    echo ""
    local i=1
    for app in "${MULTI_APPS[@]}"; do
      local name version bid sig managed_mark created_at
      name="$(basename "$app")"
      version="$(get_version "$app")"
      bid="$(get_bundle_id "$app")"
      sig="$(codesign --verify --strict "$app" >/dev/null 2>&1 && echo "正常" || echo "异常⚠️")"
      managed_mark="否"
      created_at="-"

      if json_is_managed "$app" 2>/dev/null; then
        managed_mark="是"
        created_at="$(json_created_at "$app" 2>/dev/null || echo "-")"
      fi

      info "$i) $name"
      info "   路径：       $app"
      info "   Bundle ID：  $bid"
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

  for app in "${MULTI_APPS[@]}"; do
    local BID app_name cur_ver
    BID="$(get_bundle_id "$app")"
    app_name="$(basename "$app")"

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
}

# ──────────────────────────────────────────────
# Bundle ID 冲突检测（直接扫描 /Applications，不依赖 JSON）
# ──────────────────────────────────────────────
check_bundle_id_conflict() {
  local bundle_id="$1"
  local conflicts=()

  for app in /Applications/*.app; do
    [ -d "$app" ] || continue
    [[ "$app" == "$SOURCE_APP" ]] && continue
    local bid
    bid="$(get_bundle_id "$app")"
    if [ "$bid" = "$bundle_id" ]; then
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
      [[ "$confirm_conflict" =~ ^[Yy]$ ]] || die "已取消，请换一个编号。"
    fi
  fi
}

# ══════════════════════════════════════════════
# 启动
# ══════════════════════════════════════════════
check_env

echo ""
json_cleanup_orphans

# 启动时检测残留 backup，提示但不打断
STALE_COUNT=0
for bak in /Applications/*.app.backup; do
  [ -d "$bak" ] && STALE_COUNT=$((STALE_COUNT+1))
done
[ "$STALE_COUNT" -gt 0 ] && \
  warn "发现 $STALE_COUNT 个残留升级备份，可通过菜单选项 9 处理。"
echo ""

print_multi_apps

echo "────────────────────────────────────"
echo "请选择操作："
echo "  1) 新建一个多开微信"
echo "  2) 升级某一个多开微信"
echo "  3) 升级全部多开微信"
echo "  4) 修复某一个多开微信签名"
echo "  5) 删除某一个多开微信"
echo "  6) 检查更新状态"
echo "  7) 查看详细信息"
echo "  8) 只查看列表，不操作"
echo "  9) 恢复升级失败留下的备份"
echo "────────────────────────────────────"
echo ""

read "choice?输入数字："

case "$choice" in

  # ── 1 新建 ──────────────────────────────────
  1)
    read "suffix?请输入多开编号/名称（如 01 / work / personal）："

    [ -z "$suffix" ] && die "编号不能为空。"
    [[ "$suffix" =~ ^[A-Za-z0-9_-]+$ ]] || \
      die "编号只能包含英文、数字、下划线或短横线。"

    TARGET_APP="/Applications/${MULTI_NAME_PREFIX}-${suffix}.app"
    BUNDLE_ID="${MULTI_BUNDLE_PREFIX}.${suffix}"

    # Bundle ID 冲突检测
    check_bundle_id_conflict "$BUNDLE_ID"

    if [ -d "$TARGET_APP" ]; then
      warn "$TARGET_APP 已存在。"
      read "confirm?继续会删除并重建，确认继续？[y/N]："
      [[ "$confirm" =~ ^[Yy]$ ]] || die "已取消。"
    fi

    need_sudo
    wait_wechat_exit
    create_or_replace_multi "$TARGET_APP" "$BUNDLE_ID"
    ;;

  # ── 2 升级单个 ──────────────────────────────
  2)
    print_multi_apps
    [ ${#MULTI_APPS[@]} -eq 0 ] && die "没有可升级的多开微信。"

    pick_app_by_num "请输入要升级的序号："
    TARGET_APP="$PICKED_APP"

    BUNDLE_ID="$(get_bundle_id "$TARGET_APP")"
    if [[ "$BUNDLE_ID" == "unknown" ]] || [[ "$BUNDLE_ID" == "$SOURCE_BUNDLE_ID" ]]; then
      read "BUNDLE_ID?当前 Bundle ID 异常，请手动输入（如 ${MULTI_BUNDLE_PREFIX}.work）："
      [ -z "$BUNDLE_ID" ] && die "Bundle ID 不能为空。"
    fi

    need_sudo
    wait_wechat_exit
    create_or_replace_multi "$TARGET_APP" "$BUNDLE_ID"
    ;;

  # ── 3 升级全部 ──────────────────────────────
  3)
    print_multi_apps
    [ ${#MULTI_APPS[@]} -eq 0 ] && die "没有可升级的多开微信。"

    read "confirm_all?确认升级全部 ${#MULTI_APPS[@]} 个？[y/N]："
    [[ "$confirm_all" =~ ^[Yy]$ ]] || die "已取消。"

    need_sudo
    wait_wechat_exit
    _upgrade_all
    ;;

  # ── 4 修复签名 ──────────────────────────────
  4)
    print_multi_apps
    [ ${#MULTI_APPS[@]} -eq 0 ] && die "没有可修复的多开微信。"

    echo ""
    info "修复签名：只重新签名，不重建 App 文件。"
    info "适用于：打开提示「已损坏」但文件本身完整的情况。"
    info "如需完整重建，请使用「升级」功能。"
    echo ""

    pick_app_by_num "请输入要修复签名的序号："
    TARGET_APP="$PICKED_APP"

    need_sudo
    fix_signature "$TARGET_APP"
    ;;

  # ── 5 删除 ──────────────────────────────────
  5)
    print_multi_apps
    [ ${#MULTI_APPS[@]} -eq 0 ] && die "没有可删除的多开微信。"

    pick_app_by_num "请输入要删除的序号："
    TARGET_APP="$PICKED_APP"

    delete_multi_app "$TARGET_APP"
    ;;

  # ── 6 检查更新状态 ───────────────────────────
  6)
    check_updates
    ;;

  # ── 7 详细信息 ──────────────────────────────
  7)
    show_detail
    ;;

  # ── 8 只查看 ────────────────────────────────
  8)
    info "未执行任何修改。"
    ;;

  # ── 9 恢复备份 ──────────────────────────────
  9)
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
        [[ "$bak_num" =~ ^[0-9]+$ ]] || die "请输入有效数字。"
        PICKED_BAK="${STALE_BACKUPS[$bak_num]:-}"
        [ -z "$PICKED_BAK" ] || [ ! -d "$PICKED_BAK" ] && die "序号无效。"

        ORIG_APP="${PICKED_BAK%.backup}"
        echo ""
        echo "  1) 恢复备份（替换或还原到 $(basename "$ORIG_APP")）"
        echo "  2) 删除备份（保留当前状态）"
        echo "  3) 取消"
        echo ""
        read "bak_action?请选择 [1/2/3]："
        need_sudo
        case "$bak_action" in
          1)
            [ -d "$ORIG_APP" ] && sudo rm -rf "$ORIG_APP"
            sudo mv "$PICKED_BAK" "$ORIG_APP" || die "恢复失败。"
            success "已恢复：$(basename "$ORIG_APP")"
            ;;
          2)
            sudo rm -rf "$PICKED_BAK" || die "删除备份失败。"
            success "已删除备份：$(basename "$PICKED_BAK")"
            ;;
          *)
            info "已取消。"
            ;;
        esac
      fi
    fi
    ;;

  *)
    die "无效选择。"
    ;;
esac

echo ""
echo "======================================"
echo "完成。日志已保存至："
echo "$LOG_FILE"
echo "======================================"

pause