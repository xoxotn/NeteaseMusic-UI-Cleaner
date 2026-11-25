# 网易云UI美化 (NeteaseMusic-UI-Cleaner)

轻量、零外部依赖的网易云音乐 iOS 界面精简美化模块（适配 `v9.4.80`，同时兼容 **未越狱 iOS 17+ 个人证书自签** 与 **iOS 15/16 Rootless 越狱环境**）。

## ✨ 功能亮点

- **零第三方依赖 & 零越狱痕迹**：基于苹果原生 `<objc/runtime.h>`（`generator=internal`）构建，仅链接官方系统框架（`UIKit` / `Foundation` / `QuartzCore`），不依赖 `CydiaSubstrate`、不需要 JIT 权限，独立版 `.dylib` 已彻底剥离所有 `/var/jb` 路径记录。
- **全方位界面净化**：
  - **顶部导航栏**：仅保留「推荐」并自动左对齐，抹除 心动 / 音乐 / 播客 / 听书 / 免费听。
  - **底部导航栏**：穿透双层容器彻底抹除「关注 / 漫游 / 发现 / 动态」，剩余按钮（首页、我的）自动对称居中。
  - **「我的」页面**：仅保留「音乐」并自动水平居中，彻底抹除播客 / 笔记，并封死左右侧滑切页。
  - **左侧边栏抽屉**：抹除 我的云贝 / 装扮中心 / 创作者中心 / 商城 / 云村有票 / 云推歌，并自动向上收拢间距消除留白。
  - **「推荐」信息流**：抹除 推荐歌单、排行榜、有声书/播客节目、城市热门歌曲、艺人新歌/热门金曲/猜你喜欢、直播/视频/演出，并动态压缩卡片高度消除空白。
- **内置原生设置面板 &「🎯 指哪打哪」可视化瞄准器**：
  - **长按底部导航栏 0.5 秒**（或三指轻点屏幕）随时呼出 iOS 原生分组细则开关面板；
  - 内置可视化红框瞄准器，支持任意多余板块一键点选隐藏、外扩/内缩容器层级及一键复制控件层级报告。

## 📦 下载与安装（可直接前往 Releases 下载）

| 产物文件 | 适用设备与系统 | 使用方式 |
| :--- | :--- | :--- |
| **`UICleaner.dylib`** | **未越狱设备**（如 iPhone 15 Pro Max `iOS 17.4.1`） | 使用个人证书签名工具（Feather / Sideloadly 等）在“添加动态库”中选入 `UICleaner.dylib` 签名安装（无需勾选注入 CydiaSubstrate） |
| **`com.local.uicleaner_0.4.3_iphoneos-arm64.deb`** | **Rootless 越狱设备**（如 iPhone 13 Pro `iOS 16.5` Dopamine） | 通过 Sileo 打开直接安装 |

## 🛠️ 自动与本地构建

- **GitHub Actions 云端自动编译**：每次推送代码，[`.github/workflows/build.yml`](.github/workflows/build.yml) 会自动在云端 `macos-latest` 编译最新 `.dylib` 与 `.deb` 产物。
- **Windows + WSL2 本地一键构建**：
  ```powershell
  powershell -ExecutionPolicy Bypass -File .\build.ps1
  ```
