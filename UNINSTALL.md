# 卸载

三种方式，任选其一：

1. Windows 设置 → 应用 → 已安装的应用 → 搜索 **UniAI Gateway** → 卸载
2. 开始菜单 → **UniAI Gateway** → 卸载入口
3. 命令行（PowerShell）：

```powershell
& "$env:LOCALAPPDATA\UniAI Gateway\uninstall.exe" --uninstall
```

参数：

| 参数 | 作用 |
| --- | --- |
| `--uninstall` | 执行卸载 |
| `--yes` | 不弹确认框 |
| `--purge-data` | 连同本机数据（密钥、用量、模型目录）一并删除；不带此参数默认保留，便于重装后直接继续用 |

卸载会移除：程序文件、桌面 / 开始菜单 / 开机自启入口、`uniai://` 协议注册、卸载注册表项。
卸载程序会自行收尾删除最后一个文件，偶尔会残留一个 `uninstall.exe`，手动删除即可。
