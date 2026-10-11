# Mirage

**Mirage** 是专为 **qemu-miwear** 设计的一站式原生 macOS 模拟器管理器与调试工作台。

参考 Apple Xcode **Devices & Simulators** / **Device Hub** 的交互范式构建，深度融合 QEMU 模拟核心与 AstroBox 设备管理能力，让固件导入、镜像构建、模拟运行、外设交互、应用安装与 NSH 调试无缝汇聚在单一的原生界面中。

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

## 许可证

Mirage 项目遵循 AGPL-v3 许可证。引用的 QEMU 与 LittleFS 遵循各自的开源许可证（GPL-2.0 / BSD-3-Clause）。
