# UniAI Gateway — 安装与打开

安装网页：https://buer5460.github.io/uniai-gateway-setup/

## 使用修复版，不再使用旧安装入口

当前发行：`v0.8.0-installer-fix.2`。

修复了原 0.8.0 安装器双击直接退出、安装向导初始化顺序、中文/空格路径快捷方式，以及浏览器登录后已有桌面启动器会话缓存失效的问题。网关的模型和协议实现未改动。

下载：https://github.com/Buer5460/uniai-gateway-setup/releases/download/v0.8.0-installer-fix.2/UniAI-Setup-0.8.0-installer-fix.2-windows-x64.exe

SHA-256：`8209f31d7e7f312f20922d124a7f97c818874c5b330c84f462060ae73c5ee586`

大小：59,626,978 字节。

## 一行安装（Windows PowerShell）

按 Win+R，输入 powershell，回车后粘贴下面整行。

```powershell
$ErrorActionPreference='Stop'; [Net.ServicePointManager]::SecurityProtocol=[Net.SecurityProtocolType]::Tls12; & ([scriptblock]::Create((Invoke-WebRequest -UseBasicParsing -TimeoutSec 60 -Uri 'https://raw.githubusercontent.com/Buer5460/uniai-gateway-setup/5c100abdc21734206286e2d31c67ba7644c7bdd4/install.ps1').Content))
```

必要运行库随安装包一起安装，不要求用户手工准备 Python、Node 或 Git。本版本运行不需要 Node。下载需要能访问 GitHub，脚本显示五个阶段并校验安装包哈希、程序文件、网关身份和控制台资源。目标为 Windows x64，遇到 ARM/32位/无法写入目录等情况明确停止，不绕过系统安全策略。

当前用户安装目录为 `%LOCALAPPDATA%\UniAI Gateway`。脚本不会覆盖没有有效安装记录的非空目录；发现既有安装时优先复用，不是无条件升级器。登录自启动默认不启用，可显式选择。不会自动安装系统服务或停止其他软件的进程。

## 已安装时打开

从桌面 UniAI Gateway 图标打开，或在安装网页点击 `uniai://console` 按钮。控制台凭据由本机合法启动流程处理，不要求用户复制 Token。

## 实际验证，而非所有系统保证

修复产物在独立 Windows Server 2022 GitHub runner 上执行验证：隔离中文/空格用户配置与目录、清除开发环境变量、将 PATH 限定为系统路径。安装阶段不能调用 Python、Node、Git 命令。验证了原问题复现、实际安装向导、安装、后台启动、控制台资源、重复执行、卸载，以及两个全新 Edge 浏览器会话中的控制台渲染与授权负向测试。

证据：https://github.com/Buer5460/uniai-gateway-setup/actions/runs/35840299530

这不是裸装 Windows 10/11 物理机测试，也不等于已验证所有标准权限账户、企业策略和安全软件。修复版暂未代码签名；哈希是完整性验证，不是发布者签名。遇到拦截不要关闭安全防护。

## 模型账号

空白电脑没有模型来源时，控制台可以打开，但真实模型调用仍需要用户自己的账号授权或 API Key。安装包不附带开发者的账号、模型额度、数据库或用户凭据。

## 本仓库内容

本仓库包含安装网站、安装引导脚本、公开的修复构建工具及验证工作流。模型网关完整私有源码、用户密钥、原电脑数据库、备份和浏览器配置不在此仓库中。构建工具只接受原安装器固定 SHA-256，修复版作为独立预发布版本发布，不覆盖原输入产物。

卸载说明见 UNINSTALL.md。
