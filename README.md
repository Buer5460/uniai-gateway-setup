# UniAI Gateway — 安装入口

这一页是 UniAI Gateway 的安装与打开入口。

- **已安装**：网页上的「打开 UniAI」按钮通过 `uniai://console` 协议唤起本机 `UniAI.exe`，
  由它后台启动网关、用本机登录态取得管理凭据、按这台机器的账号生成模型目录，然后打开控制台。
  用户不需要复制任何 Token。
- **未安装**：复制一行 PowerShell 命令，下载安装包 → 静默安装 → 装完自动打开控制台。
  目标机器不需要预装 Python / Node / Git，也不需要管理员权限。
- **想要安装包**：从 GitHub Releases 下载 `UniAI-Setup-<version>-windows-x64.exe` 双击运行。

安装命令的用法说明见 `UNINSTALL.md`。

## 发布内容说明

本仓库只发布「安装产物」和「安装网站」：

- `index.html` — 安装 / 打开入口网页
- `README.md`
- Releases 里的 `UniAI-Setup-<version>-windows-x64.exe` — Windows x64 安装程序

不包含服务端私有源码、不包含任何密钥、不包含用户数据。
安装包内部是打包好的运行时（PyInstaller py312 单目录 bundle，含 Tcl/Tk），
模型目录在目标机器上按本机账号现场生成，不携带开发机的固定清单。
