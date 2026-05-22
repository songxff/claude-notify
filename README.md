# Claude Code 桌面通知系统

给 [Claude Code](https://claude.com/claude-code) 命令行版加一个 **Windows 桌面通知**功能:当 Claude 在后台运行(终端窗口不在最前)时,在关键时刻弹系统通知提醒你,**点通知即可一键切回终端**。

终端正在最前、你正盯着它时,**不打扰、不弹通知**。

---

## ✨ 功能

- **三类提醒**
  - ✅ 回复完成
  - ⌛ 空闲等待你输入
  - 🔐 需要你授权某个操作
- **点击跳转** —— 点通知横幅或「切换到终端」按钮,自动把终端窗口切回最前
- **前台静默** —— 终端在最前时一律不弹,绝不打扰
- **同类去重** —— 同类通知只保留最新一条,不在操作中心堆积
- **远程推送(可选)** —— 可转发到手机:Bark / ntfy / 钉钉 / 自定义 webhook
- **无闪烁** —— 点击跳转由无控制台的 `winexe` 处理,不会黑窗一闪
- 纯 `HKCU` + 用户目录,**不需要管理员权限**

## 💻 环境要求

- Windows 10 / 11
- 已安装 Claude Code 命令行版,使用默认的 `用户目录\.claude` 配置
- 任意终端(Windows Terminal / Warp / pwsh 等均可)

## 🚀 安装

### 方式一:下载安装包(推荐)

1. 到 [Releases](https://github.com/songxff/claude-notify/releases) 下载 `claude-notify-installer.zip`;
2. **完整解压**到任意文件夹;
3. 双击 `安装.bat`;
4. 看到绿色「安装完成」并弹出测试通知即成功,重启 Claude Code 生效。

### 方式二:克隆仓库

```powershell
git clone https://github.com/songxff/claude-notify.git
cd claude-notify
powershell -NoProfile -ExecutionPolicy Bypass -File install.ps1
```

安装器是**幂等**的,可重复运行用于升级 / 修复。它会:

- 复制 hook 文件到 `用户目录\.claude\hooks\`;
- **智能合并** `settings.json` —— 只加 4 个通知 hook,不动你已有的其它 hook,原文件自动备份;
- 注册 `claude-jump:` 协议与通知应用身份(均 `HKCU`);
- 尽量用本机 .NET 重新编译 `claude-activator.exe`。

## 🗑️ 卸载

双击 `卸载.bat`,或运行 `uninstall.ps1`,会移除全部改动(hook 条目 / 注册表 / 文件)。

## ⚙️ 远程推送配置

安装后编辑 `用户目录\.claude\hooks\notify-config.json`,把 `enabled` 改为 `true` 并填好地址即可把通知转发到手机。支持 `bark` / `ntfy` / `dingtalk` / `custom`,字段说明见 [`hooks/通知系统.md`](hooks/通知系统.md) 第七章。

## 🔧 工作原理

```
Claude Code 触发 hook
   └─> claude-notify.ps1        入口:定位终端窗口、派生后台 worker
         └─> claude-notify-worker.ps1   组装内容、弹 WinRT Toast、可选推 webhook
               └─> 用户点击 -> claude-jump: 协议
                     └─> claude-activator.exe   把终端窗口切回前台
```

关键设计:点击跳转用 **`claude-jump:` 自定义协议**拉起一个一次性新进程。该进程因"由前台进程启动"而持有真正的 `SetForegroundWindow` 授权,能做真正的窗口激活;且编译为无控制台的 `winexe`,点击无闪烁。

完整技术文档见 [`hooks/通知系统.md`](hooks/通知系统.md)。

## 📂 目录结构

```
claude-notify/
├─ 安装.bat / 卸载.bat       双击入口
├─ install.ps1 / uninstall.ps1   安装 / 卸载逻辑
├─ README.txt               随包离线说明
└─ hooks/                    被安装到 ~/.claude/hooks/ 的文件
   ├─ claude-notify.ps1          hook 入口脚本
   ├─ claude-notify-worker.ps1   后台 worker
   ├─ claude-activator.cs        点击跳转处理器源码
   ├─ claude-activator.exe       上面的预编译产物(winexe)
   ├─ notify-config.json         远程推送配置
   └─ 通知系统.md                完整技术文档
```
