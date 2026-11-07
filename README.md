# Mirage

**Mirage** 是专为 **qemu-miwear** 设计的一站式原生 macOS 模拟器管理器与调试工作台。

参考 Apple Xcode **Devices & Simulators** / **Device Hub** 的交互范式构建，深度融合 QEMU 模拟核心与伴侣端（companion core）的设备管理能力，让固件导入、镜像构建、模拟运行、外设交互、应用安装与 NSH 调试无缝汇聚在单一的原生界面中。

---

### 设备 Profile
- 内置的预设 Profile：
  - **Xiaomi Watch S5**
  - **Xiaomi Smart Band 9**
  - **Xiaomi Smart Band 10**
  - **Xiaomi Smart Band 11**
  - **Xiaomi Smart Band 9 Pro**
  - **Xiaomi Smart Band 10 Pro**
- 支持自定义 Profile，灵活配置屏幕分辨率、圆角、芯片架构、按键映射与闪存分区布局。

## 编译与运行

### 环境要求
- macOS 14.0+ (推荐 macOS 15+)
- Xcode 16+
- Rust 1.80+ (`cargo`)
- Homebrew 工具：`brew install xcodegen glib pixman meson ninja pkgconf`

### 快速开始
1. **初始化并拉取 Git 子模块**：
   ```bash
   git submodule update --init --recursive
   ```

2. **编译 QEMU 模拟核心**：
   ```bash
   make qemu
   ```
   `Mirage.app` 的构建阶段会把 `qemu-system-arm` 及其动态库打包进应用。

3. **生成 Xcode 工程并编译**：
   ```bash
   xcodegen generate
   xcodebuild -project Mirage.xcodeproj -scheme Mirage -configuration Debug build
   ```

4. **运行**：
   直接在 Xcode 打开 `Mirage.xcodeproj` 运行，或运行构建产物：
   ```bash
   open .build-xcode/Build/Products/Debug/Mirage.app
   ```

5. **CLI 工具**：
   也可以使用随附的命令行工具 `miragectl`：
   ```bash
   swift run --package-path Packages/MirageKit miragectl --help
   ```

### Windows

需要 Swift 6.3、MSVC Build Tools、Windows SDK 和 Rust。在 VS Developer PowerShell 中构建：

```powershell
.\Scripts\build-companion-core.ps1
.\Scripts\build-windows.ps1 -c release
```

companion core 使用同级 `AstroBox-NG` 的组件源码，路径见 `AstroBoxBridge/Cargo.toml`。

Windows 构建脚本自动应用 `Scripts/Patches/` 中的 WinUI 补丁，修复主线程初始化、窗口与对话框
生命周期、文件夹选择及 Win10 缺少 Win11 包依赖 API 时的加载问题。补丁可重复应用，不影响
macOS/Linux 构建。运行需安装 Windows App Runtime 1.5；Win10 实机验证仍待完成。

---

## 许可证

Mirage 项目遵循 AGPL-v3 许可证。引用的 QEMU 与 LittleFS 遵循各自的开源许可证（GPL-2.0 / BSD-3-Clause）。
