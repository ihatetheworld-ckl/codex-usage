<p align="center"><img src="Assets/AppIcon.png" width="96" alt="Codex Usage logo" /></p>
<h1 align="center">Codex Usage</h1>
<p align="center">把 5h 与周剩余用量，放在随时看得见的地方。</p>
<p align="center">
  <a href="https://github.com/ihatetheworld-ckl/codex-usage/releases"><img alt="Release" src="https://img.shields.io/github/v/release/ihatetheworld-ckl/codex-usage" /></a>
  <a href="https://github.com/ihatetheworld-ckl/codex-usage/actions/workflows/release.yml"><img alt="Build" src="https://github.com/ihatetheworld-ckl/codex-usage/actions/workflows/release.yml/badge.svg" /></a>
  <a href="LICENSE"><img alt="Apache 2.0" src="https://img.shields.io/badge/license-Apache--2.0-1AA694" /></a>
</p>
<p align="center">简体中文 · <a href="README.en.md">English</a></p>

![界面示意，数值为示例](docs/images/preview.svg)

**Codex Usage** 是 macOS 和 Windows 的独立桌面小工具，通过本机 Codex CLI 读取账户用量。它不是 OpenAI 官方插件，也不向 Codex 原生侧边栏注入代码。

## 下载

从 **[GitHub Releases](https://github.com/ihatetheworld-ckl/codex-usage/releases/latest)** 下载；同一 Release 同时提供两个平台的安装包。

| 下载文件 | 适用平台 | 使用方式 |
| --- | --- | --- |
| `CodexUsage-macOS-universal.zip` | macOS 13+，Apple Silicon / Intel | 解压，把 `Codex Usage.app` 拖到“应用程序”，双击打开 |
| `CodexUsage-Windows-x64.zip` | Windows x64，推荐 Windows 11 | 解压整个目录，双击 `CodexUsage.exe`，不要只复制 EXE |
| `SHA256SUMS.txt` | 两个平台 | 核对下载文件的 SHA-256 |

Windows 便携包自带 .NET 运行时，无需另装 .NET。两个包都需要本机 Codex CLI 及其登录态。安装包尚未进行 Apple 公证或 Windows Authenticode 签名，系统可能提示无法验证开发者；请确认下载来源并核对校验和。

## 开始使用

1. 安装 [Codex CLI](https://learn.chatgpt.com/docs/cli)，在本机终端运行 `codex login` 完成登录。已有可用 CLI 登录态时可直接复用。
2. 打开 Codex Usage。macOS 菜单栏或 Windows 系统托盘会出现 CU 图标。
3. 打开 Codex / ChatGPT 桌面主窗口，小胶囊默认贴在左下角窄栏内。

若使用 npm 安装 CLI，可运行：

```sh
npm install -g @openai/codex
codex login
```

Windows 请在原生 PowerShell / 终端中安装并登录。**WSL 的登录状态与 Windows 桌面登录状态并不自动共享**。桌面版能够聊天也不一定代表当前 CLI 已登录，出现登录提示时请先确认 `codex` 可在本机终端正常使用。

CLI 安装在特殊目录时，可通过 `CODEX_USAGE_CLI` 指定可执行文件绝对路径。Windows 支持 `codex.exe`，也支持常规 npm 安装的 `codex.cmd`（通过 Node.js 直接运行对应入口，不经过命令字符串拼接）。

## 功能与交互

- **剩余用量**：5 小时、周窗口的数字与进度条统一显示剩余百分比，每 30 秒查询一次。
- **小型常驻**：48 × 84 点，只显示两个额度；点击或右键查看进度、重置倒计时和设置。
- **贴合模式**：随 Codex 窗口显示。按住拖动时可临时移开，松手立即回到左下角；Codex 切到后台或最小化时隐藏。
- **240ms 展开**：切回主窗口时，胶囊从固定中心的小点展开，数字随后淡入；快速切走、点击或拖动会中止动画，并遵循系统的减少动态效果设置。
- **macOS 窗口恢复**：等台前调度的主窗口展开稳定后再显示，避免胶囊采用动画中的临时坐标、随后跳回左下角。
- **macOS 文件弹窗**：保持绑定主窗口；打开添加文件等系统弹窗时暂时隐藏胶囊，关闭后自动回到主窗口左下角。
- **自由悬浮**：拖到任意位置，松手停留并保存位置；切换模式或重启后恢复。
- **仅菜单栏／托盘**：隐藏小窗，保留快速查看和刷新入口。
- **异常状态**：读取失败保留上次读数并标记；90 秒没有新数据视为过期。未知额度显示 `—`，不会伪装成 0%。认证失效会清除旧账户读数。

| 外观 | macOS | Windows |
| --- | --- | --- |
| 常驻小窗 | 原生 AppKit | 原生 WPF |
| 透明材质 | macOS 26+ 清透液态玻璃；旧系统磨砂 | 半透明圆角卡片，与 macOS 的玻璃效果不同 |
| 快速入口 | 菜单栏显示两项剩余百分比 | 系统托盘图标、悬停提示与详情菜单 |
| 权限 | 无需辅助功能或屏幕录制 | 无需管理员权限 |

更新时先退出工具，再替换应用或整个 Windows 便携目录。工具不自动设置开机启动；退出可通过菜单完成。

## 隐私与数据来源

工具通过官方 [Codex App Server](https://learn.chatgpt.com/docs/app-server) 的 `account/rateLimits/read` 接口读取用量，使用本机 CLI 管理的已有登录态。

- 不读取、复制或记录登录令牌，不附带任何账户凭据。
- 不调用模型、不创建聊天、不上传代码或对话，不需要 OpenAI API Key。
- 不修改 Codex 安装包或安全设置，不启动对外监听的 Web 服务。
- 只读取窗口坐标来定位浮窗；不截屏，也不读取聊天正文。
- 只保存显示模式与浮窗位置。CLI 自身仍会按正常行为连接 OpenAI 服务、刷新登录态和写本机日志。

优先读取 `rateLimitsByLimitId.codex`，按 `300` / `10080` 分钟识别两个窗口。服务端读数可能有延迟；查询间隔不是逐 token 的实时计费。

## 从源码构建

### macOS

需要 macOS、Xcode 26+ / 对应命令行工具，以及 Python 3。

```sh
git clone https://github.com/ihatetheworld-ckl/codex-usage.git
cd codex-usage
bash scripts/build.sh                    # 当前架构
bash scripts/package-macos.sh            # Universal 2 发布包
bash scripts/test.sh
bash scripts/test-ui.sh                  # 会短暂显示测试菜单和窗口
```

开发安装到用户应用目录：

```sh
bash scripts/install.sh                  # 首次安装
bash scripts/update.sh                   # 更新，自动备份旧包并重启
```

### Windows

需要 [.NET 10 SDK](https://dotnet.microsoft.com/download/dotnet/10.0)。在 PowerShell 中运行：

```powershell
git clone https://github.com/ihatetheworld-ckl/codex-usage.git
cd codex-usage
dotnet run --project windows/CodexUsage.Tests -c Release
./scripts/package-windows.ps1
```

发布包位于 `dist/`。WPF 项目也可在 macOS 上交叉编译，但只能在 Windows 上运行：

```sh
dotnet build windows/CodexUsage.Windows -c Release -p:EnableWindowsTargeting=true
```

## 验证与已知边界

发布流水线要求两个平台构建和检查全部通过，再同时公开下载。详细测试方法见 **[docs/TESTING.md](docs/TESTING.md)**。

- macOS 已验证真实用量读取、原生菜单与拖动。CI 的 macOS UI 测试运行于 Apple Silicon，Intel 切片通过交叉编译和架构校验。
- Windows CI 使用实际 WPF 窗口及模拟用量做启动、拖动、回位、详情和透明角检查；**尚未在用户 Windows 真机的真实账户下完成验收**。
- macOS 贴合模式保持绑定启动时的主窗口，直到该窗口关闭，避免误跟随文件弹窗；Windows 按前台窗口定位。无法区分 ChatGPT 主窗口内当前是 Codex 页面还是其他页面。
- 默认停靠适配左侧 56 点窄栏。桌面应用改版、窄栏隐藏、混合 DPI 多显示器或特殊商店安装路径可能需要适配；可先改用自由悬浮或仅托盘。
- 不支持远程主机账户选择、自动更新或内置 CLI 登录流程。没有取得数据时不会显示虚构的剩余额度。

macOS 偏好保存在 `local.codex-usage-sidebar` 域；Windows 偏好位于 `%LOCALAPPDATA%\CodexUsage\settings.json`。卸载时退出并删除应用即可；可按需删除工具自己的偏好文件。

## 许可证

代码及原创 CU Logo 采用 **[Apache License 2.0](LICENSE)**。第三方运行时与商标说明见 [NOTICE](NOTICE) 和 [THIRD-PARTY-NOTICES.md](THIRD-PARTY-NOTICES.md)。
