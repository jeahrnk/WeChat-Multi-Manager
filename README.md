# WeChat Multi Manager

在 macOS 上管理多个微信账号——新建、升级、修复签名、删除，一个脚本搞定。

通过复制并重新签名微信副本，实现稳定的多账号登录。支持 **macOS 13+**，**Apple Silicon / Intel** 均可。

## 功能

| 功能 | 说明 |
|------|------|
| 新建多开副本 | 自动隔离 Bundle ID，支持自定义名称 |
| 升级副本 | 单个或批量升级到原版微信当前版本 |
| 修复签名 | 打开提示「已损坏」时无需重建，一步修复 |
| 删除副本 | 移入废纸篓，不会 `rm -rf`，可恢复 |
| 检查更新状态 | 一眼看出哪些副本需要升级 |
| 事务式升级 | 升级前自动备份，失败自动还原 |
| 托管记录 | JSON + marker 文件四重识别，改名也能找回 |
| Bundle ID 冲突检测 | 全局扫描，避免两个副本互相干扰 |
| 日志系统 | 每次运行自动保存，报错直接发日志排查 |
| Dry Run | 先演练，看清楚会改什么再实际执行 |
| 恢复备份 | 升级中断后可通过菜单恢复旧副本 |
| 导入已有副本 | 将 `WeChat-Work.app` 等旧式多开纳入托管管理 |

## 使用方法

### 下载

```bash
curl -O https://raw.githubusercontent.com/jeahrnk/WeChat-Multi-Manager/main/wechat-multi.sh
chmod +x wechat-multi.sh
```

### 运行

```bash
./wechat-multi.sh
```

启动后按菜单操作：

```
1)  新建一个多开微信
2)  升级某一个多开微信
3)  升级全部多开微信
4)  修复某一个多开微信签名
5)  删除某一个多开微信
6)  检查更新状态
7)  查看详细信息
8)  只查看列表，不操作
9)  恢复升级失败留下的备份
10) 导入已有多开微信
0)  退出
```

脚本采用循环菜单，执行完一项后自动返回菜单；只有选择 `0` 退出时才会结束。

复制、删除、签名等操作需要 **管理员权限**（sudo），脚本会在需要时提示输入密码。

### Dry Run（演练模式）

```bash
./wechat-multi.sh --dry-run
```

不会实际修改任何文件，只展示将要执行的操作。第一次使用建议先跑一遍。

### 双击运行：`WeChat-Multi-Manager.command`（推荐不熟悉终端的用户）

`WeChat-Multi-Manager.command` 与 `wechat-multi.sh` **内容完全相同**，只是 macOS 会把它当作「终端快捷方式」——双击即可在终端中打开交互菜单。

#### 下载

```bash
curl -O https://raw.githubusercontent.com/jeahrnk/WeChat-Multi-Manager/main/WeChat-Multi-Manager.command
chmod +x WeChat-Multi-Manager.command
```

也可以两个文件一起下载（终端用 `.sh`，双击用 `.command`）：

```bash
curl -O https://raw.githubusercontent.com/jeahrnk/WeChat-Multi-Manager/main/wechat-multi.sh
curl -O https://raw.githubusercontent.com/jeahrnk/WeChat-Multi-Manager/main/WeChat-Multi-Manager.command
chmod +x wechat-multi.sh WeChat-Multi-Manager.command
```

#### 使用步骤

1. 将 `WeChat-Multi-Manager.command` 放到任意目录（桌面、`~/Scripts` 等均可）
2. 首次运行前确认已赋权：`chmod +x WeChat-Multi-Manager.command`
3. **双击文件**，终端会自动打开并显示菜单
4. 按菜单提示输入数字操作；选 `0` 退出
5. 退出时会提示「按回车键退出」，防止终端窗口立刻关闭（仅 `.command` 双击运行有此提示）

#### 与 `wechat-multi.sh` 的区别

| | `wechat-multi.sh` | `WeChat-Multi-Manager.command` |
|--|-------------------|-------------------------------|
| 启动方式 | 终端执行 `./wechat-multi.sh` | 访达双击 |
| 退出行为 | 选 `0` 后直接结束 | 选 `0` 后提示按回车再关闭窗口 |
| 适用场景 | 习惯命令行的用户 | 希望像 App 一样点开就用 |

#### 首次双击提示「无法打开」？

在终端中对文件所在目录执行：

```bash
xattr -cr WeChat-Multi-Manager.command
chmod +x WeChat-Multi-Manager.command
```

然后重新双击即可。

## 工作原理

脚本将原版微信复制一份到 `/Applications/WeChat-Multi-<名称>.app`，修改 Bundle ID 使 macOS 将其视为独立 App，然后重新签名（ad-hoc）。每个副本使用独立的 Bundle ID，数据目录互相隔离。

> **注意**：此方法依赖 ad-hoc 本地签名，微信大版本升级后副本需要重新构建（使用升级功能）。

## 仓库文件

| 文件 | 说明 |
|------|------|
| `wechat-multi.sh` | 主脚本，适合在终端中运行 |
| `WeChat-Multi-Manager.command` | 与主脚本内容相同，可双击运行 |

## 运行时数据

| 路径 | 说明 |
|------|------|
| `~/.config/wechat-multi/managed_apps.json` | 托管副本记录，含 Bundle ID 和创建时间 |
| `~/.config/wechat-multi/managed_apps.json.bak` | JSON 自动备份，损坏时自动恢复 |
| `~/Library/Logs/WeChatMultiManager/` | 运行日志，每次运行生成一个文件 |

多开副本默认安装在 `/Applications/` 目录，命名格式为 `WeChat-Multi-*`。

## 常见问题

**打开提示「已损坏，无法打开」**

选择菜单 `4) 修复某一个多开微信签名`，通常可以解决。如果不行，再用 `2) 升级` 重建。

**微信官方升级后副本无法使用**

选择菜单 `3) 升级全部多开微信` 重建所有副本。

**删错了怎么办**

副本删除时会移入废纸篓，在访达 → 废纸篓里可以找回。

**升级中途失败，旧副本没了怎么办**

脚本会自动尝试还原。如果还原失败，旧副本会以 `.backup` 形式保留在 `/Applications/`，可通过菜单 `9) 恢复升级失败留下的备份` 手动恢复。

**spctl 显示 rejected**

正常现象。ad-hoc 签名的 App 会被 spctl 标记为 rejected，但本地运行不受影响。

## 系统要求

- macOS 13 Ventura 或更高版本
- 已安装微信（`/Applications/WeChat.app` 或 `/Applications/微信.app`）
- Python 3（macOS 自带，用于托管记录）
- 系统自带 `codesign`、`PlistBuddy`
- 管理员权限（运行时会提示输入密码）

## 其他说明

- 升级前会自动关闭正在运行的微信进程
- 本工具仅管理微信副本，不修改原版微信
- 当前版本：**v1.5.5**
- 版本更新记录见 [CHANGELOG.md](CHANGELOG.md)（含 v1.5.2 ~ v1.5.5 循环菜单、导入旧副本、输出修复等）

## License

MIT
