# WeChat Multi Manager

macOS 微信多开管理工具，通过复制并重新签名微信副本，实现稳定的多账号登录。

支持 **macOS 13+**，**Apple Silicon / Intel** 均可。

## 功能

- **新建**多开微信副本（独立 Bundle ID，可与原版微信同时运行）
- **升级**单个或全部副本（跟随原版微信版本更新）
- **修复签名**（解决「应用已损坏」提示，无需重建 App）
- **删除**副本（移入废纸篓，可恢复）
- **检查更新状态**、查看详细信息
- **恢复备份**（处理升级失败留下的 `.backup` 文件）

## 系统要求

- macOS 13 或更高版本
- 已安装原版微信（`/Applications/WeChat.app` 或 `/Applications/微信.app`）
- 系统自带 `codesign`、`PlistBuddy`
- 建议安装 `python3`（用于托管记录，缺失时不影响核心功能）

## 快速开始

### 方式一：双击运行（推荐）

下载 `WeChat-Multi-Manager-v1.5.1.command`，在终端中执行：

```bash
chmod +x WeChat-Multi-Manager-v1.5.1.command
```

然后双击该文件即可打开交互式菜单。

### 方式二：命令行运行

```bash
chmod +x wechat-multi-v1.5.1.sh
./wechat-multi-v1.5.1.sh
```

### 预览模式（不实际修改文件）

```bash
./wechat-multi-v1.5.1.sh --dry-run
```

## 使用说明

运行后会自动检测系统环境和原版微信，随后进入主菜单：

| 选项 | 说明 |
|------|------|
| 1 | 新建一个多开微信 |
| 2 | 升级某一个多开微信 |
| 3 | 升级全部多开微信 |
| 4 | 修复某一个多开微信签名 |
| 5 | 删除某一个多开微信 |
| 6 | 检查更新状态 |
| 7 | 查看详细信息 |
| 8 | 只查看，不执行任何操作 |
| 9 | 恢复升级失败留下的备份 |

复制、删除、签名等操作需要 **管理员权限**（sudo），脚本会在需要时提示输入密码。

## 文件说明

| 文件 | 说明 |
|------|------|
| `wechat-multi-v1.5.1.sh` | 主脚本，适合在终端中运行 |
| `WeChat-Multi-Manager-v1.5.1.command` | 与主脚本内容相同，可双击运行 |

## 数据与日志

- **托管记录**：`~/.config/wechat-multi/managed_apps.json`
- **运行日志**：`~/Library/Logs/WeChatMultiManager/`

多开副本默认安装在 `/Applications/` 目录，命名格式为 `WeChat-Multi-*`。

## 注意事项

- 升级前会自动关闭正在运行的微信进程
- 升级采用事务式备份（`.backup`），失败时可从菜单选项 9 恢复
- 删除操作将副本移入废纸篓，不会立即永久删除
- 本工具仅管理微信副本，不修改原版微信

## 版本

当前版本：**v1.5.1**

## License

MIT
