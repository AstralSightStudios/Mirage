# Mirage 幻影

**Mirage** 是专为 **qemu-miwear**（小米澎湃 OS / HyperOS 手表与手环模拟器）设计的一站式原生 macOS 模拟器管理器与调试工作台。

参考 Apple Xcode **Devices & Simulators** / **Device Hub** 的交互范式构建，深度融合 QEMU 模拟核心与 AstroBox 设备管理能力，让固件导入、镜像构建、模拟运行、外设交互、应用安装与 NSH 调试无缝汇聚在单一的原生界面中。

---

## 🌟 核心特性

### 1. 模拟器工作台 (Device Hub)
- **多设备管理**：支持多个虚拟设备共存，随时启动、暂停、关机与快照重置。
- **设备外框与真机按键 (Device Chrome)**：
  - 针对不同形态（圆形表盘、方形手环）渲染高保真金属表身与表带。
  - **交互式物理按键**：表冠（Crown）、上键、下键可直接在界面上点击或长按，自动通过 QMP / NSH 向模拟器发送按键事件；亦支持键盘快捷键（Home / PgUp / PgDn）。
- **内置低延迟画面 (Live Screen)**：
  - 通过内置 VNC 协议将模拟器 Framebuffer 实时渲染至表盘内。
  - 支持直接鼠标点击/拖拽模拟触控，以及触控板双指滑动模拟手环滑动手势。

### 2. Device Profile 设备配置体系
- 内置针对主力芯片与机型的预设 Profile：
  - **Xiaomi Watch S5** (`xiaomi-s5`, BES2700 / Cortex-M33, 466×466 圆屏, 双按键+旋转表冠, 128MB NAND + eMMC)
  - **Xiaomi Watch S4** (`xiaomi-s4`)
  - **Xiaomi Watch S3** (`xiaomi-s3`)
  - **Xiaomi Smart Band 9 Pro** (`xiaomi-band-9-pro`, 336×480 方屏)
  - **Xiaomi Smart Band 8 Pro** (`xiaomi-band-8-pro`)
- 支持自定义 Profile，灵活配置屏幕分辨率、圆角、芯片架构、按键映射与闪存分区布局。

### 3. 官方固件一键导入与分区镜像自动构建
- **全格式支持**：直接拖入或选择官方 OTA 全量包（`.zip`、`.bin`、解包目录），自动解析 `payload.bin`、`vela_ap.bin`、DSP/NPU 固件等。
- **存储镜像自动生成 (ImageBuilder)**：
  - 内置原生 C 级 `LittleFS`（`CLittleFS`）文件系统构建引擎，纯内存/流式生成合法 LittleFS 分区镜像。
  - 自动构建 Sparse NAND、eMMC 镜像与 GPT 分区表，免除手动配置驱动与挂载步骤。

### 4. AuthKey 与绑定态持久化
- 原生支持工厂分区（Factory Partition）属性写入：
  - `persist.miwear_token_key` (AuthKey)
  - `persist.miwear_bound` (绑定状态)
  - `persist.miwear_user_id` / `beacon_key` / `ir_key`
- 支持一键生成全新 AuthKey 或与真机同步密钥，无需进入开机配对向导即可让模拟器直接跳入主表盘，重启数据持久保留。

### 5. AstroBox Core 深度集成 (无需手机即可管理设备与安装应用)
- 内置 AstroBox Core Rust 原生库（`AstroBoxBridge` / `libmirage_astrobox.a`）。
- 通过模拟器内建的虚拟蓝牙 SPP 端口直接与澎湃 OS 系统服务建联：
  - **表盘管理**：安装第三方表盘（`.bin`, `.mwz`），查看已安装表盘列表，一键设为当前表盘或卸载。
  - **快应用管理 (Quick App)**：拖入 `.rpk` 快应用安装包直接安装至模拟器内部，支持一键在手表上拉起运行或卸载。
  - **设备信息读取**：实时读取模拟器内固件版本、SN 序列号、电量状态。

### 6. 内置 MiWear 固件库下载器 (Archive Browser)
- 内置独立窗口，直接对接 [MiWearFirmwareArchives Releases](https://github.com/AstralSightStudios/MiWearFirmwareArchives/releases) GitHub API。
- 智能过滤支持模拟的固件版本，显示版本日志、发布时间与包体大小。
- 支持一键 **Download** 与 **Download & Create Device**，从云端拉取固件到创建并引导虚拟设备全自动完成。

### 7. 强大且易用的 NSH 终端控制台
- 基于 **SwiftTerm** 实现专业级 VT100 / ANSI 交互式终端，直连 NuttX NSH Shell。
- **智能命令栏**：支持历史记录回溯（↑ / ↓）、Tab 自动补全。
- **内置常用命令快捷面板**：一键执行 `ps`（任务列表）、`free`（内存占用）、`df -h`（文件系统）、`uptime`、`dmesg` 等。
- **实时日志追踪**：Console Log 与 QEMU Log 实时流式输出，支持跟踪滚动与 Finder 一键定位。

---

## 🛠️ 项目架构

```
Mirage/
├── App/                             # SwiftUI 界面层 (macOS 原生)
│   ├── Model/                       # AppModel, ArchiveModel, AstroBoxService
│   ├── Views/
│   │   ├── HubView.swift            # 核心三栏/双栏 Device Hub 视图
│   │   ├── Device/                  # DeviceChrome, DeviceStage, ScreenView (VNC)
│   │   ├── Console/                 # ConsolePane (SwiftTerm + NSH 控制台)
│   │   ├── Inspector/               # BindingTab (AuthKey), AppsTab (AstroBox), 存储配置
│   │   ├── Archive/                 # ArchiveWindow (固件库下载器)
│   │   └── Profiles/                # ProfilesWindow (设备 Profile 管理)
│   └── Resources/
├── Packages/
│   └── MirageKit/                   # 核心 Swift 框架
│       ├── Sources/MirageKit/
│       │   ├── Models/              # DeviceProfile, Firmware, VirtualDevice
│       │   ├── Storage/             # ImageBuilder (LittleFS / NAND / eMMC / GPT)
│       │   ├── Runtime/             # DeviceSession, QMPClient, VNCClient, NSHInjector
│       │   ├── Library/             # FirmwareImporter, DeviceFactory, MirageLibrary
│       │   └── Archive/             # FirmwareArchive (GitHub API + 断点续传)
│       ├── Sources/CLittleFS/        # LittleFS 原生 C 绑定
│       └── Sources/miragectl/       # 命令行管理工具
├── AstroBoxBridge/                  # Rust 桥接层 (编译为 libmirage_astrobox.a)
│   ├── include/mirage_astrobox.h   # C ABI 头文件
│   └── src/                         # 桥接 AstroBox 蓝牙 SPP、RPC 与文件安装协议
├── External/
│   ├── qemu-miwear/                 # QEMU 模拟器核心 submodule (dp-1700-exp)
│   └── AstroBox/                    # AstroBox 核心库 submodules
├── Scripts/
│   ├── build-qemu.sh                # 自动化编译轻量化 QEMU
│   ├── bundle-qemu.sh               # 将 QEMU 与依赖 dylib 封装进 App Bundle
│   └── build-astrobox.sh            # 自动化编译 AstroBoxBridge
└── project.yml                      # XcodeGen 描述文件
```

---

## 🚀 编译与运行

### 环境要求
- macOS 14.0+ (推荐 macOS 15+)
- Xcode 16+
- Rust 1.80+ (`cargo`)
- Homebrew 工具：`brew install xcodegen`

### 快速开始
1. **初始化并拉取 Git 子模块**：
   ```bash
   git submodule update --init --recursive
   ```

2. **生成 Xcode 工程并编译**：
   ```bash
   xcodegen generate
   xcodebuild -project Mirage.xcodeproj -scheme Mirage -configuration Debug build
   ```

3. **运行**：
   直接在 Xcode 打开 `Mirage.xcodeproj` 运行，或运行构建产物：
   ```bash
   open .build-xcode/Build/Products/Debug/Mirage.app
   ```

4. **CLI 工具**：
   也可以使用随附的命令行工具 `miragectl`：
   ```bash
   swift run --package-path Packages/MirageKit miragectl --help
   ```

---

## 📄 许可证

Mirage 项目遵循 AGPL-v3 许可证。引用的 QEMU 与 LittleFS 遵循各自的开源许可证（GPL-2.0 / BSD-3-Clause）。
