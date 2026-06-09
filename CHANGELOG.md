# Changelog

## v1.5.1

### 修复
- `die` 函数移除手动 `_cleanup` 调用，避免批量升级子 shell 失败时误杀主进程的 sudo keep-alive；清理统一由 `EXIT trap` 负责

---

## v1.5

### 新增
- **菜单选项 9**：恢复升级失败留下的备份，展示备份版本、对应路径和当前状态，支持恢复或删除
- 启动时自动扫描 `/Applications/*.app.backup` 残留，发现时提示通过选项 9 处理

### 改进
- **`rollback_upgrade` 提到顶层**：从 `create_or_replace_multi` 内部移出为独立顶层函数，消除嵌套函数污染全局命名空间的风险
- **`check_bundle_id_conflict` dry-run 模式**：发现冲突时跳过交互，只展示冲突信息，dry-run 全程零交互零修改
- 升级遇到残留 `.backup` 时改为弹出三选一菜单（删除继续 / 恢复备份 / 取消），不再静默清理

---

## v1.4

### 新增
- **事务式升级**：升级前将旧副本改名为 `.backup`，所有步骤成功后再删除；任意步骤失败自动还原旧副本，彻底消除"旧的没了新的没建好"的风险

### 改进
- Bundle ID 冲突检测从查询 JSON 改为直接扫描 `/Applications/*.app`，即使托管记录被删除也能全局检测

---

## v1.3

### 修复
- marker 文件写入前增加 `mkdir -p`，防止 `Contents/Resources` 目录不存在时写入失败

### 改进
- Bundle ID 冲突检测升级为全局扫描所有已安装 App，不再依赖 JSON 记录

---

## v1.2

### 新增
- **Marker 文件机制**：创建副本时写入 `Contents/Resources/.wechat_multi_managed`，扫描识别增加第四重来源（名称 / Bundle ID / JSON / marker），即使用户删除 JSON、改名、改 Bundle ID 仍能识别

### 改进
- `spctl` 验证结果增加说明文字，`rejected` 附带"ad-hoc 签名的正常现象"说明
- 废纸篓删除新增 `osascript` fallback，`sudo mv` 权限异常时通过 Finder 移入废纸篓

---

## v1.1

### 新增
- **日志系统**：每次运行自动保存至 `~/Library/Logs/WeChatMultiManager/`
- **托管记录**：`managed_apps.json` 记录所有副本，含 Bundle ID 和创建时间
- **JSON 损坏保护**：`.bak` 备份 + 原子写入（tmp → replace），损坏时自动恢复
- **Dry Run 模式**：`--dry-run` 参数，演练所有操作不实际修改文件
- **签名修复**：菜单选项 4，只重签不重建，适合"已损坏"提示场景
- **更新状态检查**：菜单选项 6，一眼看出哪些副本需要升级
- **导出配置**：详细信息页输出 JSON，便于换电脑后参考恢复
- **删除移废纸篓**：不再 `rm -rf`，移入 `~/.Trash` 可恢复

### 改进
- 微信进程检测增加 `WeChatAppEx`、`WeChat Helper` 等辅助进程
- 轮询改用 `pgrep -af "[Ww]e[Cc]hat"` 全面检测
- `sudo` 鉴权只执行一次，增加 keep-alive 防止长时操作超时
- 环境检测增加 python3、codesign、PlistBuddy 可用性检查

---

## v1.0

- 初版发布
- 支持新建、升级、批量升级、删除多开副本
- 自动识别 `WeChat.app` / `微信.app`
- Bundle ID 冲突检测
- 环境检测（macOS 版本、codesign、PlistBuddy）
- PlistBuddy 写后校验 + 失败回滚
- 微信进程关闭等待（轮询 + 超时确认）
- `sudo` keep-alive
