# Swallpaper-Mac-v2 调试指南

## 环境信息

- **仓库**: https://github.com/sfyqiu/Swallpaper-Mac-v2
- **本地路径**: `~/Desktop/Claude code项目/Swallpaper-Mac-v2-fresh/`
- **当前版本**: v1.3.22
- **分支**: main
- **编译方式**: GitHub Actions → Build DMG workflow (push main 自动触发)
- **平台**: macOS 14.0+, Swift 6.2
- **构建**: GitHub Actions (macos-15, xcodegen → xcodebuild → DMG → Release)

## 项目架构概览

```
Swallpaper-Mac-v2-fresh/
├── App/SwallpaperApp.swift          # 应用入口 + AppDelegate (窗口管理)
├── Services/
│   ├── NetworkService.swift         # 网络请求层 (actor, 重试, 代理, quickConnect)
│   ├── WallpaperSourceManager.swift # 壁纸源切换管理 (启动源选择)
│   ├── CloudLibrarySyncService.swift # 云盘同步库
│   ├── PexelsService.swift          # Pexels 照片+视频
│   ├── NASAService.swift            # NASA APOD
│   ├── CoverrService.swift          # Coverr 免费视频
│   ├── UnsplashService.swift        # Unsplash 照片
│   └── ...                          # 其他50+服务文件
├── ViewModels/
│   ├── SettingsViewModel.swift      # 设置页逻辑
│   └── ...
├── Views/
│   ├── SettingsView.swift           # 设置页 (侧边栏+内容区)
│   ├── ContentView.swift            # 主界面容器
│   └── ...
├── Models/Wallpaper.swift
├── VERSION                          # 版本号文件
└── .github/workflows/ci.yml        # CI (push main 自动触发)
```

---

## 一、设置窗口自动消失 (v1.3.22)

### 症状
打开设置界面，切换到其他应用（如 TextEdit）再回到 Swallpaper，设置窗口不见了，需要重新打开。

### 根因
**文件**: [App/SwallpaperApp.swift](App/SwallpaperApp.swift)

`AppDelegate.applicationShouldHandleReopen`（Dock 图标点击时触发）中无条件调用 `showMainWindow()`。
该方法内部执行 `window.makeKeyAndOrderFront(nil)`，强制把**主窗口**提到最前面并设为 key window，
把先前可见的设置窗口覆盖在了主窗口之下。

### 修复 (line 388)
```swift
@MainActor func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
    // 有可见窗口（如设置窗口）时不调 showMainWindow()，让 macOS 自行处理窗口排序
    if !flag {
        showMainWindow()
    }
    return true
}
```
- `hasVisibleWindows = true`（设置窗口可见）：跳过 `showMainWindow()`，macOS 自然把设置窗口置前
- `hasVisibleWindows = false`（无可见窗口）：正常显示主窗口

### 设置窗口架构
- 独立 NSWindow（非 sheet/popover），通过 `settingsWindowController`（NSWindowController）管理
- `isReleasedWhenClosed = false`（关闭只是隐藏，不释放窗口对象）
- 系统红绿灯关闭按钮隐藏，改用 SettingsView 内的自定义 X 按钮
- **没有设置 delegate**（`windowShouldClose` 只绑定到主窗口）
- 创造位置: `createAndShowSettingsWindow()` 第 708 行
- 关闭按钮回调: `(NSApp.keyWindow ?? NSApp.mainWindow)?.performClose(nil)`
- 窗口复用: `showSettingsWindow()` 先检查 `settingsWindowController?.window` 是否存在

### 调试要点
- 设置窗口关闭→只是隐藏，控制器和窗口对象仍存活
- `hideMainWindow()` 和 `releaseForegroundMemoryNow()` 都会检查设置窗口是否可见（可见则不隐藏 Dock 图标）
- 如果设置窗口可见但用户看不到，优先检查 `applicationShouldHandleReopen` 逻辑

---

## 二、API 连通性 + 启动慢 (v1.3.20)

### 症状
- 换新电脑后 API 测试全红、壁纸一直加载中
- 所有壁纸源"同时"加载慢

### 根因
1. `URLSession.configuration` 默认 `waitsForConnectivity = true`，GFW 下某些域名 TCP 被 RST/丢包，
   系统等待 30-60s 才超时，导致界面挂起
2. 启动源选择逻辑：检测到 VPN（utun 接口）就认为 Wallhaven 可达，
   但**分隧道 VPN** 只代理浏览器流量，不代理非浏览器请求

### 修复
1. **新增 `NetworkService.quickConnect()`** — [Services/NetworkService.swift](Services/NetworkService.swift)
   - 使用独立临时 URLSession，`waitsForConnectivity = false`，默认 8s 超时
   - 继承当前 session 的代理配置
   - 各 API 源的 `testConnection()` 全部改用 quickConnect
   - ⚠️ 临时 session 记得用 `invalidateAndCancel()` 释放（不是 `invalidate()`）

2. **启动源选择改进** — [Services/WallpaperSourceManager.swift](Services/WallpaperSourceManager.swift)
   - VPN 检测后不再直接认定 Wallhaven 可达
   - 改为实际调用 `quickConnect()` 验证 Wallhaven 是否通
   - 不通则回退到 4K Wallpapers（无需 API Key）

### 区分 VPN 慢 vs API 慢
- 所有源同时慢 → VPN 出口带宽瓶颈
- 关 VPN 后无需 Key 的源（4K、MotionBG）变快 → VPN 速度问题
- 个别源慢 → 该源 API/服务器问题

---

## 三、SwallpaperApp 生命周期关键方法

| 方法 | 触发时机 | 作用 |
|---|---|---|
| `applicationShouldHandleReopen` | 点击 Dock 图标 | 恢复窗口显示 |
| `showMainWindow()` | 主动调用 | 创建/显示主窗口，取消延迟释放 |
| `hideMainWindow()` | 点击关闭按钮 | orderOut 主窗口 |
| `releaseForegroundMemoryNow()` | 状态栏菜单释放内存 | 立即释放前台资源 |
| `releaseForegroundResourcesForHiddenWindow()` | hideMainWindow 内部 | post 通知、清缓存、`contentView = nil` |

### 窗口生命周期
- **主窗口隐藏**: `orderOut` → 150ms 延迟 → post `appDidHideWindow` → 再 150ms 延迟 → `contentView = nil`
- **主窗口恢复**: `showMainWindow()` 检测 `window?.contentView == nil` 时重新挂载 ContentView
- **延迟释放**: `delayedReleaseTask`（Task），可被 `showMainWindow()` 取消，避免隐藏/恢复竞争

### 通知
- `appDidHideWindow` — 主窗口隐藏后发出，观察者清理轻量级状态
- `appShouldReleaseForegroundMemory` — 释放前台内存前发出，各 View 监听后清缓存

---

## 四、调试流程

### 设置窗口不见了
1. 查 `applicationShouldHandleReopen` → `showMainWindow()` 是否无条件调用
2. 查 `hideMainWindow()` 的 `delayedReleaseTask` 是否意外影响设置窗口
3. 查 `releaseForegroundMemoryNow()` 是否被误触发

### API 不通 / 壁纸加载卡死
1. 打开设置 → API 连通性测试，看哪些源慢
2. 查对应 Service 的 `testConnection()` 是否用了 `quickConnect()`（不是原始 URLSession）
3. 查 GFW 环境 + VPN 分隧道策略
4. 查 `NetworkService` 的 `waitsForConnectivity` 设置

### 换新电脑首次启动
1. 查 `WallpaperSourceManager.performStartupSourceSelection()` 的 VPN 检测逻辑
2. 查 `quickCheckWallhaven()` 是否执行
3. 查 `pingGoogle()` 是否改用 `quickConnect()`

### 编译 / CI 失败
1. 查自家 Swift 版本是否匹配（Swift 6.2 / Xcode 26.4）
2. 查 `URLSession` API 变更（没有 `invalidate()`，用 `invalidateAndCancel()`）
3. CI 跳过 Build：检查 tag 是否已存在，需要 bump 版本或删 tag

---

## 五、关键文件速查

| 文件 | 主要职责 | 关键方法/属性 |
|---|---|---|
| [App/SwallpaperApp.swift](App/SwallpaperApp.swift) | AppDelegate、窗口管理 | `showMainWindow()`, `hideMainWindow()`, `showSettingsWindow()`, `applicationShouldHandleReopen`, `releaseForegroundMemoryNow()` |
| [Services/NetworkService.swift](Services/NetworkService.swift) | 网络请求（actor） | `quickConnect()`, `fetchData()`, `executeWithRetry()`, `updateProxyConfiguration()` |
| [Services/WallpaperSourceManager.swift](Services/WallpaperSourceManager.swift) | 壁纸源管理 | `performStartupSourceSelection()`, `quickCheckWallhaven()`, `pingGoogle()` |
| [Views/SettingsView.swift](Views/SettingsView.swift) | 设置界面 | `SettingsTab`, 各设置 Tab 子视图 |
| [ViewModels/SettingsViewModel.swift](ViewModels/SettingsViewModel.swift) | 设置逻辑 | `testAllAPIs()`, API key 存取 |
| [Views/ContentView.swift](Views/ContentView.swift) | 主界面容器 | `releaseForegroundMemory()`, `openSettingsWindow()`, `hideMainWindow()` |
| [project.yml](project.yml) | XcodeGen 配置 | 依赖、Bundle ID、部署目标 |
| [VERSION](VERSION) | 版本号 | CI 自动读此文件打 tag |

---

## 六、版本迭代规则

每次修改代码后:
1. 递增 [VERSION](VERSION) 文件中的版本号
2. `git add` + `git commit` + `git push`
3. CI 自动触发构建，生成 DMG Release
4. tag 已存在时 CI 跳过 Build，需 bump 版本或删旧 tag

## 回退指南
- **稳定版本 tag**: `v1.3.16-stable`
- **回退命令**: `git checkout v1.3.16-stable` 然后 bump 版本号 push
- 也可以直接 revert 到 commit `618c50a`

## 重要约束
- `SettingsViewModel` init 中不能读 `UserDefaults`（macOS 26 崩溃）
- 所有仓库引用必须指向 `sfyqiu/Swallpaper-Mac-v2`
- `UpdateChecker` 的 repo 和 apiURL 必须用 v2
