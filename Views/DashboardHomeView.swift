import SwiftUI

// MARK: - 仪表盘首页

struct DashboardHomeView: View {
    @ObservedObject var viewModel: WallpaperViewModel
    @ObservedObject var mediaViewModel: MediaExploreViewModel
    @Binding var selectedWallpaper: Wallpaper?
    @Binding var selectedMedia: MediaItem?
    var isTabActive: Bool = true
    @ObservedObject private var arcSettings = ArcBackgroundSettings.shared
    @StateObject private var atmosphereController = HomeAtmosphereController()

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 24) {
                sourcePicker.padding(.top, 20)
                currentWallpaperPreview
                quickActions
                statsRow
                recentDownloadsSection
            }
            .padding(.horizontal, 28)
            .padding(.bottom, 40)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            Group {
                if arcSettings.compactMode {
                    arcSettings.compactBackground.ignoresSafeArea()
                } else {
                    dashboardBackground.ignoresSafeArea()
                }
            }
        )
        .onAppear {
            if isTabActive {
                Task {
                    await viewModel.initialLoad()
                    await mediaViewModel.initialLoadIfNeeded()
                }
            }
        }
    }

    // MARK: - 源切换
    private var sourcePicker: some View {
        HStack(spacing: 10) {
            Image(systemName: "photo.stack")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.secondary)
            Menu {
                ForEach(WallpaperSourceManager.SourceType.allCases, id: \.self) { source in
                    Button(source.displayName) {
                        WallpaperSourceManager.shared.switchTo(source)
                        Task { await viewModel.initialLoad() }
                    }
                }
            } label: {
                Text(WallpaperSourceManager.shared.activeSource.displayName)
                    .font(.system(size: 14, weight: .semibold))
                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .bold))
            }
            .menuStyle(.borderlessButton)

            Spacer()

            // 一键切换
            Button {
                let sources = WallpaperSourceManager.SourceType.allCases
                if let idx = sources.firstIndex(of: WallpaperSourceManager.shared.activeSource) {
                    let next = sources[(idx + 1) % sources.count]
                    WallpaperSourceManager.shared.switchTo(next)
                    Task { await viewModel.initialLoad() }
                }
            } label: {
                Image(systemName: "arrow.triangle.2.circlepath")
                    .font(.system(size: 13, weight: .semibold))
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: - 当前壁纸预览
    @ViewBuilder
    private var currentWallpaperPreview: some View {
        if let wallpaper = viewModel.items.first {
            VStack(spacing: 0) {
                AsyncImage(url: URL(string: wallpaper.thumbs.large)) { image in
                    image.resizable().aspectRatio(contentMode: .fill)
                } placeholder: {
                    Rectangle().fill(Color.white.opacity(0.05))
                }
                .frame(height: 320)
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                .overlay(
                    // 底部渐变文字
                    VStack {
                        Spacer()
                        LinearGradient(
                            colors: [.clear, .black.opacity(0.7)],
                            startPoint: .top, endPoint: .bottom
                        )
                        .frame(height: 80)
                        .overlay(alignment: .bottomLeading) {
                            HStack {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(wallpaper.resolution ?? "")
                                        .font(.system(size: 11, weight: .medium))
                                        .foregroundStyle(.white.opacity(0.8))
                                    Text(wallpaper.source.uppercased())
                                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                                        .foregroundStyle(.white.opacity(0.5))
                                }
                                Spacer()
                                Button("设为桌面") {
                                    selectedWallpaper = wallpaper
                                }
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 14).padding(.vertical, 6)
                                .background(Capsule(style: .continuous).fill(.white.opacity(0.2)))
                                .buttonStyle(.plain)
                            }
                            .padding(.horizontal, 16).padding(.bottom, 12)
                        }
                    }
                )
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            }
        } else {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color.white.opacity(0.05))
                .frame(height: 320)
                .overlay(
                    VStack(spacing: 8) {
                        Image(systemName: "photo.on.rectangle.angled")
                            .font(.system(size: 32))
                            .foregroundStyle(.secondary.opacity(0.5))
                        Text("暂无壁纸")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(.secondary)
                    }
                )
        }
    }

    // MARK: - 快捷操作
    private var quickActions: some View {
        HStack(spacing: 12) {
            dashboardButton(icon: "dice", title: "随机一张") {
                if let wp = viewModel.items.randomElement() {
                    selectedWallpaper = wp
                }
            }
            dashboardButton(icon: "arrow.clockwise", title: "刷新") {
                Task { await viewModel.refresh() }
            }
            dashboardButton(icon: "clock", title: "调度器") {
                // 打开设置
                if let appDelegate = NSApp.delegate as? AppDelegate {
                    appDelegate.openSettings()
                }
            }
        }
    }

    private func dashboardButton(icon: String, title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 18, weight: .medium))
                Text(title)
                    .font(.system(size: 11, weight: .semibold))
            }
            .foregroundStyle(.primary.opacity(0.85))
            .frame(maxWidth: .infinity)
            .frame(height: 72)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(.regularMaterial)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(.white.opacity(0.08), lineWidth: 0.5)
            )
        }
        .buttonStyle(.plain)
    }

    // MARK: - 统计
    private var statsRow: some View {
        HStack(spacing: 12) {
            statCard(title: "壁纸", count: viewModel.items.count, icon: "photo", color: .blue)
            statCard(title: "视频", count: mediaViewModel.items.count, icon: "film", color: .purple)
            statCard(title: "收藏", count: viewModel.favorites.count, icon: "heart", color: .pink)
            statCard(title: "下载", count: viewModel.downloadedWallpapers.count, icon: "arrow.down.circle", color: .green)
        }
    }

    private func statCard(title: String, count: Int, icon: String, color: Color) -> some View {
        VStack(spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(color)
            Text("\(count)")
                .font(.system(size: 20, weight: .bold, design: .rounded))
            Text(title)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .frame(height: 88)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(.regularMaterial)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(.white.opacity(0.08), lineWidth: 0.5)
        )
    }

    // MARK: - 最近下载
    @ViewBuilder
    private var recentDownloadsSection: some View {
        let downloaded = viewModel.downloadedWallpapers.prefix(8)
        if !downloaded.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("最近下载")
                        .font(.system(size: 15, weight: .semibold))
                    Spacer()
                    Text("\(viewModel.downloadedWallpapers.count) 项")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                }

                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 4), spacing: 8) {
                    ForEach(Array(downloaded), id: \.id) { record in
                        AsyncImage(url: URL(string: record.wallpaper.thumbs.small)) { image in
                            image.resizable().aspectRatio(contentMode: .fill)
                        } placeholder: {
                            Rectangle().fill(Color.white.opacity(0.05))
                        }
                        .frame(height: 80)
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                        .onTapGesture { selectedWallpaper = record.wallpaper }
                    }
                }
            }
        }
    }

    // MARK: - Background
    private var dashboardBackground: some View {
        let tint = ExploreAtmosphereTint.fromSampledTriplet(
            atmosphereController.primary,
            atmosphereController.secondary,
            atmosphereController.tertiary
        )
        return ExploreDynamicAtmosphereBackground(
            tint: tint,
            referenceImage: atmosphereController.referenceImage,
            lightweightBackdrop: false
        )
        .ignoresSafeArea()
    }
}
