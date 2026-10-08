# 卸载与回滚（1.0.0-rc4）

唯一安装根目录：`%LOCALAPPDATA%\UniAI Gateway`
（安装器用 `scripts/uniai_home.py` 自动识别：有 `install.json` / `data/uniai.db`
的那个目录。它不会在旁边新建第二个安装，也不会动 `data`。）

| 目录 | 内容 | 升级时 | 卸载时 |
| --- | --- | --- | --- |
| `app` | 程序文件 | 整体替换（先备份到 `app.previous`） | 删除 |
| `data` | 数据库、密钥、Vault、日志 | **永不删除** | 默认保留，需你明确选择才删 |
| `runtime` | Python / Node / Qoder CLI | 保留复用 | 删除 |
| `legacy-program-backup-<时间>` | 被替换掉的旧版程序（0.8.0 的 exe / `_internal`） | 升级成功后才归档，可随时删 | 删除 |

## 一、卸载 UniAI Gateway

安装位置：`%LOCALAPPDATA%\UniAI Gateway`

1. 停止服务：在任务管理器结束 `python.exe`（命令行含 `runtime.child`），
   或在安装目录执行：

   ```powershell
   & "$env:LOCALAPPDATA\UniAI Gateway\runtime\python\python.exe" -m runtime.service stop
   ```

2. 删除程序目录（数据不动）：

   ```powershell
   Remove-Item "$env:LOCALAPPDATA\UniAI Gateway\app" -Recurse -Force
   ```

3. （可选）删除本机数据目录（密钥、用量、日志）：

   ```powershell
   Remove-Item "$env:LOCALAPPDATA\UniAI Gateway\data" -Recurse -Force
   ```

4. （可选）若安装器曾为本机补充 Node，会从用户 PATH 中移除：
   设置 → 系统 → 高级系统设置 → 环境变量 → 用户变量 `Path`
   → 删除含 `UniAI Gateway\runtime\node` 的条目。

5. （可选）删除本机入口 `uniai://console`：

   ```powershell
   & "$env:LOCALAPPDATA\UniAI Gateway\app\scripts\register_protocol.py" --unregister
   ```

卸载不会改动你的 Qoder 账号、Qoder 登录态，也不会删除你的项目文件。

## 二、回滚 ZCode 配置（把 ZCode 恢复成接入前的样子）

自动配置 ZCode 前，UniAI 会把原配置复制为：

```
%USERPROFILE%\.zcode\v2\provider_config.json.uniai-backup-<年月日-时分秒>
```

恢复方法：删掉当前的 `provider_config.json`，把备份文件改回原名即可：

```powershell
cd "$env:USERPROFILE\.zcode\v2"
$backup = Get-ChildItem provider_config.json.uniai-backup-* | Sort-Object Name | Select-Object -Last 1
Remove-Item provider_config.json
Copy-Item $backup.FullName provider_config.json
```

## 三、回滚版本

| 目标 | 做法 |
| --- | --- |
| 回到 rc3 安装包 | 下载 https://github.com/Buer5460/uniai-gateway-setup/releases/tag/v1.0.0-rc3 后重新执行 `install.ps1` |
| 回到 rc2 安装包 | 下载 https://github.com/Buer5460/uniai-gateway-setup/releases/tag/v1.0.0-rc2 后重新执行 `install.ps1` |
| 回到 rc1 安装包 | 下载 https://github.com/Buer5460/uniai-gateway-setup/releases/tag/v1.0.0-rc1 后重新执行 `install.ps1` |
| 回到 V1 功能收口版本 | `git checkout uniai-entitlement-v1-pass`（commit `b8a271b`） |
| 回到 Qoder 冻结版本 | `git checkout uniai-qoder-entitlement-pass`（commit `d5d88ae`） |
| 只是关掉额外付费 | 控制台首页「禁止额外付费」开关保持开启即可，无需换版本 |

安装失败自动回滚：升级前程序目录会先备份为 `app.previous`，任一阶段失败自动还原并再次验证旧版本能提供服务（安装窗口会显示 `ROLLBACK_RESTORED` / `ROLLBACK_HEALTH_OK`）。
旧版 0.8.0 的程序（`UniAI.exe` / `uniai-agent.exe` / `_internal`）只有在**新版已经回答 /health 之后**才会被归档到 `legacy-program-backup-<时间>`，所以失败时随时可以把它放回原处启动。

## 四、回滚后如何确认

- UniAI 控制台「我的 AI 权益」中，Qoder 显示已连接且余额可读；
- ZCode 能正常对话；
- 「禁止额外付费」开关为开启状态（此时 `paid_enabled=false`）。
