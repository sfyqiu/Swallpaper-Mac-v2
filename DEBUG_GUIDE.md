# Swallpaper-Mac-v2 调试指南

## 环境信息

- **仓库**: https://github.com/sfyqiu/Swallpaper-Mac-v2
- **本地路径**: `~/Desktop/Claude code项目/Swallpaper-Mac-v2-fresh/`
- **当前版本**: v1.3.19
- **分支**: main
- **编译方式**: GitHub Actions → Build DMG workflow (手动触发)

## 项目架构概览

```
Swallpaper-Mac-v2-fresh/
├── App/SwallpaperApp.swift          # 应用入口 + AppDelegate
├── Services/
│   ├── NetworkService.swift         # 网络请求层 (URLSession 封装)
│   ├── WallpaperSourceManager.swift # 壁纸源切换管理 (Wallhaven/4K/Pexels/NASA/Unsplash)
│   ├── CloudLibrarySyncService.swift # 云盘同步库 (上传 + 导入)
│   ├── FourKWallpapersParser.swift  # 4K壁纸站 HTML 解析
│   ├── MediaLibraryService.swift    # 媒体库 (含 WallpaperLibraryService)
│   ├── DownloadPathManager.swift    # 下载路径管理
│   └── ...                          # 其他50+服务文件
├── ViewModels/
│   ├── WallpaperViewModel.swift     # 壁纸搜索/浏览核心逻辑
│   ├── SettingsViewModel.swift      # 设置页逻辑 (API key, 云盘, 代理)
│   └── MediaExploreViewModel.swift  # 媒体浏览逻辑
├── Views/
│   ├── ContentView.swift            # 主界面容器
│   ├── HomeContentView.swift        # 首页 (轮播 + 推荐)
│   ├── SettingsView.swift           # 设置页
│   └── WallpaperExploreContentView.swift
├── Models/
│   ├── Wallpaper.swift              # 壁纸模型 + WallpaperDownloadRecord
│   ├── MediaItem.swift              # 媒体模型 + MediaDownloadRecord
│   ├── CloudLibraryRecord.swift     # 云盘记录模型
│   └── WallhavenAPI.swift           # Wallhaven API 端点
├── VERSION                          # 版本号文件
└── .github/workflows/
    ├── build-dmg.yml                # DMG 打包 (workflow_dispatch)
    └── ci.yml                       # CI (push 触发)
```

## 壁纸加载完整链路

```
App启动
  → AppDelegate.applicationDidFinishLaunching()
    → 窗口显示
    → restoreAllDataAsync() [异步分帧恢复]
      → WallpaperSourceManager.performStartupSourceSelection()
        → isVPNEnabled()? → 是: 保留Wallhaven / 否: ping Google
        → Google可达? → 是: Wallhaven / 否: 4K回退
      → ContentView.task 等待 isInitialSourceSelectionComplete
        → WallpaperViewModel.initialLoad()
          → search() [并行] + fetchFeaturedAndUpdate()
            → fetchWallpapers() → sourceManager.activeSource 路由
              → .wallhaven → fetchFromWallhaven()
              → .fourKWallpapers → FourKWallpapersService
              → .pexels → PexelsService
              → .nasa → NASAService
              → .unsplash → UnsplashService
```

## 已完成的修改 (v1.3.16 → v1.3.19)

### Commit 1: API key 输入后自动重载壁纸

**修改文件**:
- `Services/DownloadPathManager.swift` — 新增 `wallpaperAPIKeyDidChange` 通知名
- `ViewModels/SettingsViewModel.swift` — API key setter 中发送通知 + 新增 `testWallhavenConnection()`
- `ViewModels/WallpaperViewModel.swift` — 监听通知，自动调用 `refresh()` 重新加载

**解决的问题**: 首次启动时用户还没输入 API key，`initialLoad()` 已执行完并失败。输入 key 后没有重触发机制，首页一直显示骨架屏。

### Commit 2: 云盘双向同步 (上传 + 导入)

**修改文件**:
- `Services/CloudLibrarySyncService.swift` — 新增 `importMissingFromCloud()` 导入方法
- `ViewModels/SettingsViewModel.swift` — 新增 `importFromCloud()` 手动导入 + 进度状态
- `App/SwallpaperApp.swift` — 启动时自动调用 `autoImportOnStartupIfNeeded()`
- `Views/SettingsView.swift` — 新增「从云盘导入到本地」按钮 + 启用云盘后自动导入

**解决的问题**: 云盘同步只有上传功能，换电脑后无法从云盘恢复壁纸/视频到本地库。

**触发方式**:
1. 启动时自动检测并导入
2. 首次启用云盘时自动导入
3. 设置页手动点击导入按钮

### Commit 3: waitsForConnectivity 回滚

**修改文件**: `Services/NetworkService.swift`
- 回滚 `waitsForConnectivity = false` → `true`
- 原因: false 导致所有 API 连通性测试变红

### Commit 4-5: 编译错误修复 + 版本迭代

- `Int64?` → `Int?` 类型转换 (Wallpaper.fileSize 是 Int?, MediaItem.fileSize 是 Int64?)
- VERSION: 1.3.16 → 1.3.17 → 1.3.18 → 1.3.19

## 调试常用命令

```bash
# 查看当前版本
cat VERSION

# 查看 git 提交历史
git log --oneline -10

# 触发 DMG 编译
curl -X POST \
  -H "Authorization: token <TOKEN>" \
  -H "Accept: application/vnd.github+json" \
  "https://api.github.com/repos/sfyqiu/Swallpaper-Mac-v2/actions/workflows/build-dmg.yml/dispatches" \
  -d '{"ref":"main"}'

# 查看最新 workflow run 状态
curl -s -H "Authorization: token <TOKEN>" \
  "https://api.github.com/repos/sfyqiu/Swallpaper-Mac-v2/actions/runs?event=workflow_dispatch&per_page=1" \
  | python3 -c "import json,sys; r=json.load(sys.stdin)['workflow_runs'][0]; print(r['status'],r['conclusion'],r['html_url'])"

# 获取失败日志中的错误
curl -sL -H "Authorization: token <TOKEN>" \
  "https://api.github.com/repos/sfyqiu/Swallpaper-Mac-v2/actions/jobs/<JOB_ID>/logs" \
  -o /tmp/log.txt && grep "error:" /tmp/log.txt

# 本地验证 Swift 编译 (macOS 需安装 Xcode)
cd Swallpaper-Mac-v2-fresh
xcodegen generate
xcodebuild -scheme Swallpaper -configuration Release build \
  CODE_SIGN_IDENTITY="-" CODE_SIGNING_REQUIRED=NO 2>&1 | grep "error:"
```

## 当前已知问题 & 待办

1. **API 连通性测试不含 Wallhaven** — 已修复 (v1.3.17)
2. **首次启动壁纸加载时序** — 已修复 (v1.3.17)
3. **云盘单向同步** — 已修复 (v1.3.17)
4. **编译错误 Int64?/Int? 类型** — 已修复 (v1.3.19)
5. ⏳ **v1.3.19 DMG 编译中** — 待确认成功

## GitHub Token

需要 GitHub Personal Access Token (classic)，权限勾选 `repo`。
生成地址: https://github.com/settings/tokens
用于 git push + GitHub API 调用。替换下方 `<TOKEN>` 为实际值。

## 版本迭代规则

每次修改代码后必须:
1. 递增 VERSION 文件中的版本号
2. git add + commit + push
3. 触发 DMG build workflow
4. 确认编译成功后才能发布给用户测试
