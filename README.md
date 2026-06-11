# WeChat Multi Manager

<p align="center">
  <strong>macOS 微信多开管理工具</strong><br>
  新建 · 升级 · 修复签名 · 导入旧副本 · 安全删除 —— 一个脚本统一管理
</p>

<p align="center">
  支持 macOS 13+ · Apple Silicon / Intel · 当前版本 v1.5.5
</p>

---

## 这是什么

WeChat Multi Manager 通过**复制并重新签名**微信副本，让 macOS 将每个副本识别为独立 App，从而实现**多账号同时登录**。

- 不修改原版微信，仅管理副本
- 每个副本独立 Bundle ID，数据互相隔离
- 升级采用事务式备份，失败可自动回滚
- 全程菜单交互，无需记忆命令

> 本工具为开源脚本，与腾讯微信官方无关联。

---

## 快速开始（3 分钟）

### 你需要准备

- macOS 13 或更高版本
- 已安装原版微信（`/Applications/WeChat.app` 或 `/Applications/微信.app`）
- 知道 Mac 登录密码（部分操作需要管理员权限）

### 第一步：下载

**推荐：双击运行版**（不熟悉终端的用户）

```bash
curl -O https://raw.githubusercontent.com/jeahrnk/WeChat-Multi-Manager/main/WeChat-Multi-Manager.command
chmod +x WeChat-Multi-Manager.command
```

将文件放到桌面或任意目录，**双击**即可打开菜单。

**可选：终端版**

```bash
curl -O https://raw.githubusercontent.com/jeahrnk/WeChat-Multi-Manager/main/wechat-multi.sh
chmod +x wechat-multi.sh
./wechat-multi.sh
```

### 第二步：首次运行

若双击提示「无法打开」或「来自 unidentified developer」，在终端进入文件所在目录执行：

```bash
xattr -cr WeChat-Multi-Manager.command
chmod +x WeChat-Multi-Manager.command
```

若终端运行提示 `permission denied`，执行：

```bash
chmod +x wechat-multi.sh
```

### 第三步：按场景选择菜单项

| 你想做什么 | 选菜单 |
|-----------|--------|
| 第一次多开一个账号 | `1` 新建 |
| 已有旧的多开（如 WeChat-Work.app） | `10` 导入 |
| 微信官方更新后，同步多开版本 | `3` 升级全部 |
| 打开提示「已损坏」 | `4` 修复签名 |
| 先看看、不改动 | `6` 或 `8` |
| 退出 | `0` |

新建完成后，在启动台或 `/Applications/` 中找到 `WeChat-Multi-<名称>.app`，像普通 App 一样打开登录即可。

---

## 常见使用场景

### 场景 A：第一次创建一个多开微信

1. 运行脚本，选 `1) 新建一个多开微信`
2. 输入名称，例如 `work` 或 `personal`（仅英文、数字、下划线、短横线）
3. 按提示输入 Mac 登录密码（sudo）
4. 等待复制与签名完成
5. 打开 `/Applications/WeChat-Multi-work.app` 扫码登录

### 场景 B：已有手动多开，纳入管理

若你之前手动复制过 `WeChat-Work.app` 等副本：

1. 选 `10) 导入已有多开微信`
2. 选择要导入的 App，确认
3. 导入后列表显示 `[托管]`，可像新建副本一样升级、修复、删除

> 导入只写入托管记录和 marker，不会重建 App。若签名异常，导入后选 `4) 修复签名`。

### 场景 C：微信官方发布新版本

**必须先更新原版微信，再升级多开副本。**

```text
① 在 App Store 或微信内更新原版 WeChat.app
② 运行本脚本，选 6) 检查更新状态 —— 确认哪些副本需要升级
③ 选 3) 升级全部（或多个时选 2) 升级某一个）
④ 输入密码，等待完成
⑤ 分别打开原版与多开，确认可正常登录
```

脚本会从**当前最新原版微信**复制重建副本，保留各副本原有 Bundle ID，聊天记录通常不受影响。

### 场景 D：第一次使用，想先「彩排」

```bash
./wechat-multi.sh --dry-run
```

演练模式下所有写操作只打印 `[dry-run]` 预览，不实际修改文件，不请求 sudo，适合第一次熟悉流程。

---

## 菜单说明

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
10)  导入已有多开微信
 0)  退出
```

脚本采用**循环菜单**：执行完一项自动返回菜单，选 `0` 退出。需要复制、签名、删除时会提示输入 Mac 登录密码。

---

## 两种运行方式

| | `WeChat-Multi-Manager.command` | `wechat-multi.sh` |
|--|-------------------------------|-------------------|
| **启动** | 访达双击 | 终端 `./wechat-multi.sh` |
| **适合** | 日常用户 | 开发者 / 习惯终端的用户 |
| **退出** | 选 `0` 后提示按回车关闭窗口 | 选 `0` 后直接结束 |
| **Dry Run** | 终端执行 `zsh WeChat-Multi-Manager.command --dry-run` | `./wechat-multi.sh --dry-run` |

两个文件功能完全相同，任选其一即可。

---

## 功能一览

| 功能 | 你能得到什么 |
|------|-------------|
| 新建多开 | 一键生成独立副本，自定义名称 |
| 升级副本 | 跟随原版微信版本，单个或批量更新 |
| 修复签名 | 解决「已损坏，无法打开」，无需重建 |
| 删除副本 | 移入废纸篓，可恢复，不直接永久删除 |
| 检查更新 | 哪些副本落后一目了然 |
| 导入旧副本 | 手动多开（如 WeChat-Work）纳入统一管理 |
| 事务式升级 | 升级前自动备份，失败自动还原 |
| 恢复备份 | 升级中断时找回 `.backup` 残留 |
| 托管记录 | 改名、改 ID 后仍能识别副本 |
| 日志系统 | 每次运行自动保存，便于排查问题 |
| Dry Run | 零风险预演全部操作 |

<details>
<summary>技术细节（开发者 / 进阶用户）</summary>

- 四重识别：App 名称前缀 · Bundle ID 前缀 · JSON 托管记录 · marker 文件
- Bundle ID 冲突：全局扫描 `/Applications`，不依赖 JSON
- 签名方式：ad-hoc 本地签名（`codesign --force --deep --sign -`）
- JSON 存储：`managed_apps.json` + 原子写入 + `.bak` 损坏恢复

</details>

---

## 工作原理

```text
原版 WeChat.app
    │
    ├─ 复制 → /Applications/WeChat-Multi-<名称>.app
    ├─ 修改 Bundle ID → com.tencent.xinWeChat.multi.<名称>
    ├─ 清除扩展属性 → xattr -cr
    └─ ad-hoc 重新签名 → codesign
```

每个副本被 macOS 视为独立 App，微信数据按 Bundle ID 隔离存储。**原版微信不会被修改。**

> 微信大版本更新后，副本程序文件需跟随重建（使用升级功能）。聊天数据通常在用户目录，不在 `.app` 内。

---

## 文件与数据

### 仓库文件

| 文件 | 说明 |
|------|------|
| `wechat-multi.sh` | 主脚本，终端运行 |
| `WeChat-Multi-Manager.command` | 同上，支持双击运行 |
| `CHANGELOG.md` | 版本更新记录 |

### 运行时数据

| 路径 | 说明 |
|------|------|
| `/Applications/WeChat-Multi-*.app` | 脚本创建的多开副本 |
| `~/.config/wechat-multi/managed_apps.json` | 托管副本记录 |
| `~/.config/wechat-multi/managed_apps.json.bak` | JSON 自动备份 |
| `~/Library/Logs/WeChatMultiManager/` | 运行日志（每次一个文件） |

---

## 常见问题

<details open>
<summary><strong>打开提示「已损坏，无法打开」</strong></summary>

选菜单 `4) 修复某一个多开微信签名`。若仍不行，再用 `2) 升级` 完整重建。
</details>

<details>
<summary><strong>微信官方升级后，多开打不开了</strong></summary>

先在 App Store / 微信内更新原版，再运行脚本选 `3) 升级全部多开微信`。
</details>

<details>
<summary><strong>提示输入 Password 是什么？</strong></summary>

这是你 **Mac 的登录密码**（sudo 管理员权限）。脚本需要复制、签名 `/Applications` 里的 App，不会上传或保存密码。
</details>

<details>
<summary><strong>permission denied: ./wechat-multi.sh</strong></summary>

脚本没有执行权限，运行：`chmod +x wechat-multi.sh`
</details>

<details>
<summary><strong>删错了多开副本怎么办</strong></summary>

删除时移入废纸篓，可在访达 → 废纸篓中恢复。
</details>

<details>
<summary><strong>升级中途失败，旧副本没了</strong></summary>

脚本会自动尝试回滚。若失败，旧副本可能以 `.app.backup` 保留在 `/Applications/`，选菜单 `9) 恢复升级失败留下的备份`。
</details>

<details>
<summary><strong>导入后的 [托管] 副本能正常升级和删除吗</strong></summary>

可以。导入后与新建副本享有相同管理能力（升级、修复、删除、检查更新）。
</details>

<details>
<summary><strong>spctl 显示 rejected</strong></summary>

正常现象。ad-hoc 签名会被 Gatekeeper 标记为 rejected，**不影响本地运行**。
</details>

<details>
<summary><strong>会丢失聊天记录吗</strong></summary>

新建、升级、修复签名通常不影响聊天记录。删除副本只移走 App 文件；若需保留数据，请勿清空对应微信账号数据目录。
</details>

---

## 系统要求

| 项目 | 要求 |
|------|------|
| 系统 | macOS 13 Ventura 或更高 |
| 原版微信 | 已安装于 `/Applications/WeChat.app` 或 `/Applications/微信.app` |
| 运行环境 | 系统自带 zsh、python3、codesign、PlistBuddy |
| 权限 | 部分操作需要管理员密码 |

---

## 版本与更新

- 当前版本：**v1.5.5**
- 完整更新记录：[CHANGELOG.md](CHANGELOG.md)

---

## 免责声明

本工具仅供学习与个人使用。请遵守微信用户协议及当地法律法规。使用本工具产生的任何后果由使用者自行承担。

---

## License

MIT
