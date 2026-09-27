# Codex Meter

一个原生 macOS 桌面侧栏，显示当前 ChatGPT/Codex 账号的用量。它可以在完整面板和迷你窄条之间切换，同时保留菜单栏入口。

## 功能

- 5 小时额度：已用、剩余比例和重置时间
- 每周额度：已用、剩余比例和重置时间
- 今日 token：优先使用账号日统计，并用本机 session 数据补齐实时延迟
- 每 5 分钟自动刷新，也可手动刷新
- 默认贴在桌面右侧居中，可自由拖到左侧或其他位置；普通应用窗口会显示在它上方
- 点击标题栏箭头可在完整侧栏与紧凑窄条之间切换，尺寸状态会自动记住
- 点击菜单栏仪表图标可以显示或隐藏桌面小组件

数据通过本机 ChatGPT/Codex 自带的 `app-server` 只读接口获取，不保存登录令牌。

## 系统要求

- macOS 13 或更高版本
- 已安装并登录 ChatGPT/Codex 桌面应用，或已安装 Codex CLI
- Apple Command Line Tools（用于从源码构建）

小组件会自动查找 ChatGPT 应用内置的 Codex 程序（包括新版和旧版安装位置），也支持 Homebrew 安装的 Codex CLI。

## 构建

```zsh
chmod +x build.sh
./build.sh
```

实际构建结果位于 `build/Codex Meter.app`。双击即可运行，也可以复制到 `~/Applications`。

如果本机 Swift 编译器与默认 SDK 不匹配，可以指定兼容 SDK：

```zsh
SDKROOT=/path/to/MacOSX.sdk ./build.sh
```

## 数据与隐私

- 额度百分比与每日账户统计来自 Codex 本机服务的只读接口。
- 今日数字会用 `~/.codex/sessions` 中的本机 token 记录补齐服务端统计延迟。
- 应用不会上传、缓存或输出登录令牌。
- 仓库不包含任何账号、会话、日志或个人用量数据。

## 说明

这是一个个人实用工具，使用 Codex 当前提供的实验性本机 `app-server` 协议。Codex 更新后，该协议可能发生变化。
