#!/bin/zsh
# WeChat Multi Manager — 一键下载安装
# 用法：curl -fsSL https://raw.githubusercontent.com/jeahrnk/WeChat-Multi-Manager/main/install.sh | zsh
#
# 可选：指定安装目录
#   INSTALL_DIR=~/Desktop/WeChat-Multi-Manager curl -fsSL ... | zsh

set -u

readonly REPO="jeahrnk/WeChat-Multi-Manager"
readonly BRANCH="main"
readonly BASE_URL="https://raw.githubusercontent.com/${REPO}/${BRANCH}"

install_dir="${INSTALL_DIR:-$HOME/Applications/WeChat-Multi-Manager}"

echo ""
echo "======================================"
echo " WeChat Multi Manager"
echo "======================================"
echo ""

# 环境检查
if ! command -v curl >/dev/null 2>&1; then
  echo "✗ 需要 curl，请先安装 Xcode Command Line Tools：" >&2
  echo "  xcode-select --install" >&2
  exit 1
fi

local_macos="$(sw_vers -productVersion 2>/dev/null || echo "unknown")"
echo "系统：macOS ${local_macos}"
echo "安装目录：${install_dir}"
echo ""

mkdir -p "$install_dir" || {
  echo "✗ 无法创建目录：$install_dir" >&2
  exit 1
}

download() {
  local name="$1"
  local dest="$install_dir/$name"
  echo "下载 $name ..."
  if curl -fsSL "${BASE_URL}/${name}" -o "$dest"; then
    chmod +x "$dest"
    echo "  ✓ $dest"
  else
    echo "  ✗ 下载失败：$name" >&2
    echo "    请检查网络，或手动从 GitHub 下载：" >&2
    echo "    https://github.com/${REPO}" >&2
    return 1
  fi
}

verify_script() {
  local name="$1"
  local dest="$install_dir/$name"
  if zsh -n "$dest" 2>/dev/null; then
    echo "  ✓ 语法检查通过：$name"
  else
    echo "  ⚠ 语法检查未通过：$name（文件已下载，请反馈 Issue）" >&2
  fi
}

download "wechat-multi.sh"        || exit 1
download "WeChat-Multi-Manager.command" || exit 1

echo ""
echo "校验脚本..."
verify_script "wechat-multi.sh"
verify_script "WeChat-Multi-Manager.command"

echo ""
echo "安装完成。"
echo ""
echo "运行方式："
echo "  终端：  $install_dir/wechat-multi.sh"
echo "  双击：  在访达中打开 $install_dir/WeChat-Multi-Manager.command"
echo ""
echo "首次双击若提示无法打开，在终端执行："
echo "  xattr -cr \"$install_dir/WeChat-Multi-Manager.command\""
echo "  chmod +x \"$install_dir/WeChat-Multi-Manager.command\""
echo ""
echo "更新记录：https://github.com/${REPO}/releases"
echo ""
