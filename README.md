# Ghost Downloader iOS（遥控端）

给 [Ghost-Downloader-3](https://github.com/XiaoYouChR/Ghost-Downloader-3) 做的 iOS 遥控客户端。

**它不是一个能在手机上跑下载的 App。** 下载、分片、BT、M3U8 合并全部发生在你电脑上的
Ghost Downloader 里，这个 App 只负责三件事：提交链接、看进度、暂停/取消任务。

配合 GitHub Actions，这个仓库可以直接产出可侧载安装的 IPA。

---

## 为什么不直接把 Ghost-Downloader-3 打包成 IPA

结论：**做不到**，而且不是 CI 的问题。原因按从硬到软排列：

| 层面 | 问题 |
| --- | --- |
| 依赖 | PySide6 从 Qt 6.12 起才支持 iOS，且**只支持纯 Python 包**，带 C 扩展的一律不行。GD3 依赖 `libtorrent`（C++）、`wreq`（Rust）、`uvloop`/`winloop`、Pillow，全部是原生扩展 |
| 外部程序 | GD3 依赖 FFmpeg、N_m3u8DL-RE、hpatchz 等外部可执行文件；iOS 沙箱禁止 fork/exec 子进程 |
| 平台 API | 入口 `Ghost-Downloader-3.py` 用了系统托盘、Dock、单实例应用、剪贴板监听、URL scheme、desktop-notifier，以及两个常驻监听端口的服务；iOS 不允许后台常驻监听 |
| 商店规则 | Feature Packs 会**运行时下载并加载代码**，自更新会替换自身二进制 —— 都属于可执行代码分发，直接违规 |
| 许可证 | 项目是 GPL-3.0，与 App Store 条款不兼容（VLC 当年因此下架）；即便做出来也只能侧载 |

所以这里换了个方向：**复用 GD3 已有的对外协议，写一个原生 iOS 壳**。

## 通信协议

GD3 其实对外暴露了两套本地服务：

| 服务 | 默认端口 | 能力 | 本仓库用了吗 |
| --- | --- | --- | --- |
| Aria2 兼容 RPC | 16800 | 只有 `getVersion` / `getGlobalOption` / `addUri` 三个方法，`addUri` 返回的还是随机串而不是 GID，**无法查询任务** | 否 |
| **Browser Service** | **14370** | WebSocket + JSON，协议 v2：配对、任务快照订阅、创建任务、任务操作 | **是** |

本 App 走的是 Browser Service —— 就是浏览器扩展用的那套，能力完整得多：

| 方向 | 消息 |
| --- | --- |
| 客户端 → 桌面端 | `pair_request` / `hello` / `subscribe_tasks` / `create_task` / `task_action` |
| 桌面端 → 客户端 | `pair_result` / `hello_ack` / `task_snapshot` / `create_task_result` / `task_action_result` / `error` |

`task_action` 支持 `toggle_pause`、`cancel`（连文件删）、`remove`（只删记录）、
`redownload`、`open_file`、`open_folder`。

## 必须先解决的一个问题：端口只绑回环

GD3 的两个服务都**只监听 `127.0.0.1` / `::1`**（见 `app/services/port_listener.py`）。
手机即使和电脑在同一个 Wi-Fi 下，也连不上。

所以仓库里带了一个纯标准库的 TCP 转发脚本 `tools/gd-relay.py`，
在别的地址上监听、把流量原样转给回环 —— WebSocket 本质就是 TCP，转发对上层完全透明。

```
iPhone ──ws://192.168.x.x:14371──> gd-relay.py ──127.0.0.1:14370──> Ghost Downloader
```

## 快速开始

### 1. 电脑端：确认端口

打开 Ghost Downloader → 设置 → 找到 Browser Service 的端口（默认 `14370`），确认已启用。

### 2. 电脑端：启动转发

**Windows：直接双击仓库根目录的 `启动转发.bat`。** 脚本会自动探测局域网 IP，
并把「手机上该填什么」直接打印出来，不用自己去查 IP：

```
[gd-relay] 监听 0.0.0.0:14371  ->  127.0.0.1:14370
[gd-relay] >>> 手机 App 的「电脑端地址」填：192.168.0.106:14371
[gd-relay] 上游 127.0.0.1:14370 可以连接
```

最后一行是在启动时就确认 Ghost Downloader 开没开 —— 没开的话会直接告诉你，
省得手机连上来才发现。

其他平台，或想自己控制参数：

```bash
python tools/gd-relay.py
```

输出会告诉你监听地址。只想在加密网络上暴露的话（推荐）：

```bash
# 只绑 Tailscale / WireGuard 接口，不暴露给整个局域网
python tools/gd-relay.py --listen-host 100.64.0.1
```

### 3. 手机端：装 App

用下面的构建方式产出 IPA，再用 SideStore / AltStore / Sideloadly 安装。

### 4. 手机端：先放行「本地网络」

**这一步最容易漏，而且漏了极难自己发现。**

> 设置 → 隐私与安全性 → **本地网络** → 找到本 App → 打开

iOS 在拒绝这个权限时会**静默丢弃所有局域网连接**，从电脑这一侧完全看不出异常 ——
转发脚本不会有任何接入记录，App 侧只会显示「电脑端没有响应」。
我们就是在这一步卡住的。如果这个列表里找不到本 App，
先在 App 里点一次连接，它就会出现。

### 5. 配对

打开 App → 右上角齿轮 → 填电脑地址（例如 `192.168.1.10:14371`）→ 点 **自动配对**。
电脑端会弹出确认框，点同意，令牌会自动填入并连接。

配对不顺利时可以直接手动填令牌，完全绕开弹窗：把电脑端设置里的
**浏览器扩展配对令牌**粘到 App 的「配对令牌」栏，填完会自动连接。

## 连不上时按这个顺序排查

按「**先确认包有没有到电脑**」的顺序来，别一上来就怀疑协议。

**第 0 步：包到电脑了吗？** 看转发窗口的日志。

| 转发窗口里出现 | 含义 |
| --- | --- |
| `客户端接入 192.168.x.x:xxxxx` | 包到了，问题在配对或协议 |
| `客户端接入 127.0.0.1:xxxxx` | 这是电脑本机的东西，不是手机 |
| 一直没有 | **包根本没出去**，继续往下查 |

**第 1 步：iOS「本地网络」权限** —— 见上面第 4 步，被拒时静默丢包。

**第 2 步：确认同一网段** —— 设置 → 无线局域网 → ⓘ → IP 必须是 `192.168.x.x`，
且和电脑在同一网段。

**第 3 步：地址写法** —— `192.168.0.106:14371`，冒号必须是**半角 `:`**
（中文输入法的 `：` 会让地址解析失败）。端口填转发的 `14371`，
**不是** GD3 自己的 `14370`。

**第 4 步：路由器的 AP 隔离** —— 就是那个「同 Wi-Fi 下设备互不可见」的开关，
常见于路由器管理页的「AP 隔离 / 客户端隔离」。

**第 5 步：Windows 防火墙** —— 启动转发时如果弹过询问框，要选「允许」。
确认端口在监听：

```powershell
Get-NetTCPConnection -LocalPort 14371 -State Listen
```

**第 6 步：看 GD3 自己的日志** —— 请求到了桌面端但处理失败时，原因在这里：

```
%LOCALAPPDATA%\GhostDownloader\GhostDownloader.log
```

例如 `create_task` 失败，会看到 `http_pack` 里 `probe` 那一层的异常
（目标站点返回 `403` 之类）—— 那是**链接本身**的问题，不是客户端的问题。

### 一个不经过 App 的纯网络测试

在手机浏览器里打开 `http://<电脑IP>:14371`。这一步完全不涉及 App 和协议，
只看转发窗口会不会打印 `客户端接入` —— 能干净地区分「网络不通」和「App 有问题」。
（页面本身报错是正常的，GD3 不会回应非 WebSocket 请求。）

## 构建

### 方式 A：GitHub Actions（推荐）

推送到 GitHub 后，Actions → **Build unsigned IPA** → Run workflow。

产出物是一个**未签名**的 IPA。它不能直接拖进 iPhone，需要用你自己的 Apple ID 重新签名：

| 工具 | 说明 |
| --- | --- |
| [SideStore](https://sidestore.io/) | 需要电脑配合一次，之后可无线续签，体验最好 |
| [AltStore](https://altstore.io/) | 老牌方案，同样需要一台电脑 |
| [Sideloadly](https://sideloadly.io/) | 插线直接装，最简单 |

签名有效期取决于 Apple ID：免费账号 7 天，付费开发者账号（$99/年）1 年。

> CI 里没有 Apple 证书，也不需要 —— 所以走的是 `CODE_SIGNING_ALLOWED=NO` 无签名构建。
> 想要一个「拿来就能装」的 IPA，就必须在 CI 里配置你自己的
> `.p12` + provisioning profile（存成 Secrets），那属于另外一条路。

### 方式 B：本地 macOS

```bash
brew install xcodegen
xcodegen generate
open GhostDownloader.xcodeproj
```

选自己的设备直接 Run 即可（需要登录 Apple ID 配置签名）。

## 已知限制

- **令牌存在 `UserDefaults` 里**，不是 Keychain。iOS 沙箱下风险可控，但如果你在意，可以换成 Keychain。
- **`ws://` 是明文**，配对令牌会明文经过网络。请只在可信局域网使用，或绑到 Tailscale 等加密接口。
- 桌面端看到的对端地址会变成 `127.0.0.1`（转发造成的），配对弹窗里显示的就是这个，正常。
- 没有本地通知；App 在后台时 WebSocket 会被系统挂起，回到前台会自动重连并重新订阅。
- `open_file` / `open_folder` 是在**电脑上**打开，不是手机上。
- App 图标的「下载箭头」是脚本生成的占位设计，见 `tools/make-icon.py`。

## 目录结构

```
.
├── 启动转发.bat                     # Windows 一键启动转发（本身纯 ASCII，中文输出交给 Python）
├── project.yml                     # XcodeGen 工程描述（.xcodeproj 由它生成，不入库）
├── Resources/Info.plist            # 含局域网用途声明与 ATS 例外
├── Sources/
│   ├── GhostDownloaderApp.swift
│   ├── GDModels.swift              # 协议数据模型 + 状态机
│   ├── GDClient.swift              # WebSocket 协议客户端（握手/订阅/重连/保活）
│   ├── Support.swift               # 格式化与设置键
│   ├── Views/                      # SwiftUI 界面
│   └── Assets.xcassets/            # App 图标
├── tools/
│   ├── gd-relay.py                 # 回环服务 → 局域网转发（必需）
│   │                               #   会打印接入日志、探测本机 IP、检查上游
│   └── make-icon.py                # 生成 1024x1024 图标
└── .github/workflows/build-unsigned-ipa.yml
```

## 协议版本

客户端声明 `protocolVersion: 2`，与 GD3 当前 `PROTOCOL_VERSION` 一致。
版本不匹配时桌面端会回 `protocol_mismatch` 并断开，App 会把这条信息显示在界面上。
