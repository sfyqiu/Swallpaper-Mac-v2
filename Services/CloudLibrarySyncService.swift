import Foundation
import AppKit

// MARK: - 云盘同步库核心服务

/// 管理云盘同步库的创建、读写、扫描。
/// 不接入任何云盘 API，只操作本机已同步的云盘目录。
/// 使用 security-scoped bookmark 保存目录访问权限。
@MainActor
final class CloudLibrarySyncService: ObservableObject {
    static let shared = CloudLibrarySyncService()

    private let fm = FileManager.default
    private let workQueue = DispatchQueue(label: "com.swallpaper.cloudsync", qos: .utility)

    // MARK: - UserDefaults Keys
    private let bookmarkDataKey = "cloud_sync_bookmark_data"
    private let providerKey = "cloud_sync_provider"
    private let enabledKey = "cloud_sync_enabled"
    private let libraryURLBookmarkKey = "cloud_sync_library_url_bookmark"
    private let syncModeKey = "cloud_sync_mode"

    // MARK: - Published State
    @Published var isEnabled: Bool = false
    @Published var selectedProvider: CloudProvider?
    @Published var libraryURL: URL?
    @Published var status: CloudLibrarySyncStatus = .disabled
    @Published var manifest: CloudLibraryManifest?
    @Published var syncMode: CloudSyncMode = .auto {
        didSet { UserDefaults.standard.set(syncMode.rawValue, forKey: syncModeKey) }
    }

    // MARK: - Internal State
    private var cachedAccessURL: URL?

    // MARK: - Init
    private init() {
        isEnabled = false
        status = .disabled
    }

    /// 延迟恢复状态（AppDelegate 中调用）
    func restoreState() {
        let defaults = UserDefaults.standard
        isEnabled = defaults.bool(forKey: enabledKey)
        if let raw = defaults.string(forKey: providerKey),
           let provider = CloudProvider(rawValue: raw) {
            selectedProvider = provider
        }
        if let modeRaw = defaults.string(forKey: syncModeKey),
           let mode = CloudSyncMode(rawValue: modeRaw) {
            syncMode = mode
        }
        if isEnabled, let bookmarkData = defaults.data(forKey: libraryURLBookmarkKey) {
            do {
                let (url, _) = try resolveBookmark(bookmarkData)
                libraryURL = url
                cachedAccessURL = url
                manifest = try? loadManifest()
                status = .ready
            } catch {
                status = .error("目录权限失效，请重新选择同步目录")
            }
        }
    }

    // MARK: - Enable / Disable

    /// 启用云盘同步库
    func enable(provider: CloudProvider, rootURL: URL) throws {
        let libURL = try createOrUseLibrary(at: rootURL, provider: provider)
        try ensureDirectoryStructure(at: libURL)
        libraryURL = libURL
        cachedAccessURL = libURL

        let newManifest = CloudLibraryManifest.create(provider: provider)
        try saveManifest(newManifest)

        let bookmarkData = try createBookmark(for: libURL)
        UserDefaults.standard.set(bookmarkData, forKey: libraryURLBookmarkKey)
        UserDefaults.standard.set(true, forKey: enabledKey)
        UserDefaults.standard.set(provider.rawValue, forKey: providerKey)

        selectedProvider = provider
        manifest = newManifest
        isEnabled = true
        status = .ready
    }

    /// 关闭云盘同步库（不删除云端文件）
    func disable() {
        libraryURL = nil
        cachedAccessURL = nil
        selectedProvider = nil
        manifest = nil
        isEnabled = false
        status = .disabled

        UserDefaults.standard.set(false, forKey: enabledKey)
    }

    /// 让用户手动选择目录（OpenPanel）
    func chooseCustomFolder() async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            let panel = NSOpenPanel()
            panel.canChooseDirectories = true
            panel.canChooseFiles = false
            panel.canCreateDirectories = true
            panel.prompt = "选择云盘目录"
            panel.message = "选择一个已同步的云盘文件夹，Swallpaper 将在其中创建 Swallpaper Library"

            panel.begin { response in
                if response == .OK, let url = panel.url {
                    continuation.resume(returning: url)
                } else {
                    continuation.resume(throwing: CloudSyncError.userCancelled)
                }
            }
        }
    }

    // MARK: - Directory Management

    /// 库目录名称
    static let libraryFolderName = "Swallpaper Library"

    func createOrUseLibrary(at rootURL: URL, provider: CloudProvider) throws -> URL {
        // 如果选中的目录名已经是 "Swallpaper Library"，直接使用
        if rootURL.lastPathComponent == Self.libraryFolderName {
            return rootURL
        }
        // 否则在目录中创建 Swallpaper Library
        let libURL = rootURL.appendingPathComponent(Self.libraryFolderName, isDirectory: true)
        if !fm.fileExists(atPath: libURL.path) {
            try fm.createDirectory(at: libURL, withIntermediateDirectories: true, attributes: nil)
        }
        return libURL
    }

    func ensureDirectoryStructure(at libraryURL: URL) throws {
        let dirs = [
            "metadata",
            "files/wallpapers",
            "files/videos",
            "files/live",
            "thumbnails",
            "cache",
            "logs"
        ]
        for dir in dirs {
            let url = libraryURL.appendingPathComponent(dir, isDirectory: true)
            if !fm.fileExists(atPath: url.path) {
                try fm.createDirectory(at: url, withIntermediateDirectories: true, attributes: nil)
            }
        }
    }

    // MARK: - Manifest

    func loadManifest() throws -> CloudLibraryManifest {
        guard let libURL = libraryURL else {
            throw CloudSyncError.notEnabled
        }
        let url = CloudLibraryManifest.manifestURL(in: libURL)
        guard fm.fileExists(atPath: url.path) else {
            throw CloudSyncError.manifestMissing
        }
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(CloudLibraryManifest.self, from: data)
    }

    func saveManifest(_ manifest: CloudLibraryManifest) throws {
        guard let libURL = libraryURL else {
            throw CloudSyncError.notEnabled
        }
        var updated = manifest
        updated.updatedAt = Date()
        let url = CloudLibraryManifest.manifestURL(in: libURL)
        try atomicWriteJSON(updated, to: url)
        self.manifest = updated
    }

    // MARK: - Scan

    func scanLibrary() async throws -> CloudLibraryScanResult {
        guard let libURL = libraryURL else {
            throw CloudSyncError.notEnabled
        }
        status = .scanning
        defer { status = .ready }

        let mf: CloudLibraryManifest
        do {
            mf = try loadManifest()
        } catch {
            throw CloudSyncError.manifestCorrupted
        }

        var records: [CloudLibraryRecord] = []
        let metadataDir = libURL.appendingPathComponent("metadata", isDirectory: true)
        let metadataFiles = ["wallpapers.json", "media.json", "favorites.json", "downloads.json"]

        for file in metadataFiles {
            let url = metadataDir.appendingPathComponent(file, isDirectory: false)
            if fm.fileExists(atPath: url.path) {
                if let fileRecords: [CloudLibraryRecord] = try? readRecords(from: url) {
                    for var record in fileRecords {
                        // 检查文件是否存在于本地
                        let absURL = absoluteURL(for: record.relativeFilePath)
                        if fm.fileExists(atPath: absURL.path) {
                            record.status = .available
                        } else {
                            record.status = .missing
                        }
                        records.append(record)
                    }
                }
            }
        }

        let available = records.filter { $0.status == .available }.count
        let missing = records.filter { $0.status == .missing }.count

        // 更新 manifest 计数
        var updatedMF = mf
        updatedMF.records = CloudLibraryRecordCounts(
            wallpapers: records.filter { $0.kind == .staticWallpaper }.count,
            media: records.filter { $0.kind == .videoWallpaper }.count,
            favorites: 0,
            downloads: records.count
        )
        try? saveManifest(updatedMF)

        return CloudLibraryScanResult(
            totalRecords: records.count,
            availableCount: available,
            missingCount: missing,
            needsDownloadCount: 0,
            records: records,
            manifest: updatedMF
        )
    }

    // MARK: - Record Management

    /// 记录一次下载到云盘元数据
    func recordDownload(id: String, kind: CloudLibraryItemKind, source: String, title: String?,
                        remoteURL: String?, fileURL: URL, thumbnailPath: String? = nil,
                        fileSize: Int64? = nil) throws {
        guard isEnabled, let _ = libraryURL else { return }
        let relPath = try relativePath(for: fileURL)
        let record = CloudLibraryRecord(
            id: id, kind: kind, source: source, title: title,
            remoteURL: remoteURL, relativeFilePath: relPath,
            thumbnailPath: thumbnailPath, createdAt: Date(), updatedAt: Date(),
            fileSize: fileSize, sha256: nil, status: .available
        )
        // 追加到 wallpapers.json 或 media.json
        let metadataFile: String
        switch kind {
        case .staticWallpaper: metadataFile = "wallpapers.json"
        case .videoWallpaper, .liveWallpaper: metadataFile = "media.json"
        case .thumbnail: return
        }
        var records = (try? readRecords(from: metadataURL(metadataFile))) ?? []
        records.removeAll { $0.id == id }
        records.append(record)
        try writeRecords(records, to: metadataFile)
        // 更新 manifest
        if var mf = manifest {
            switch kind {
            case .staticWallpaper: mf.records.wallpapers += 1
            case .videoWallpaper: mf.records.media += 1
            case .liveWallpaper: mf.records.media += 1
            case .thumbnail: break
            }
            mf.records.downloads += 1
            try saveManifest(mf)
        }
    }

    private func metadataURL(_ name: String) -> URL {
        libraryURL!.appendingPathComponent("metadata/\(name)", isDirectory: false)
    }

    // MARK: - Migration

    /// 迁移当前本地库到云盘（不删除原文件）
    func migrateCurrentLibrary() async throws {
        guard isEnabled, let libURL = libraryURL else { throw CloudSyncError.notEnabled }
        status = .migrating
        defer { status = .ready }
        try ensureDirectoryStructure(at: libURL)
        let mf = CloudLibraryManifest.create(provider: selectedProvider ?? .custom)
        try saveManifest(mf)

        let dpManager = DownloadPathManager.shared
        var wallpaperRecords: [CloudLibraryRecord] = []
        var mediaRecords: [CloudLibraryRecord] = []

        // 扫描原始本地下载目录（wallpapersFolderURL，不受云盘重定向影响）
        let wallpaperDir = dpManager.wallpapersFolderURL
        if FileManager.default.fileExists(atPath: wallpaperDir.path) {
            let files = (try? FileManager.default.contentsOfDirectory(at: wallpaperDir, includingPropertiesForKeys: [.fileSizeKey])) ?? []
            for file in files where !file.lastPathComponent.hasPrefix(".") {
                let destDir = libURL.appendingPathComponent("files/wallpapers", isDirectory: true)
                try? FileManager.default.createDirectory(at: destDir, withIntermediateDirectories: true)
                let dest = destDir.appendingPathComponent(file.lastPathComponent)
                if !FileManager.default.fileExists(atPath: dest.path) {
                    try? FileManager.default.copyItem(at: file, to: dest)
                }
                let relPath = try? relativePath(for: dest)
                let fileSize = (try? file.resourceValues(forKeys: [.fileSizeKey]))?.fileSize.flatMap(Int64.init)
                let id = file.deletingPathExtension().lastPathComponent
                let record = CloudLibraryRecord(
                    id: id, kind: .staticWallpaper, source: "wallhaven", title: nil,
                    remoteURL: nil, relativeFilePath: relPath ?? "", thumbnailPath: nil,
                    createdAt: Date(), updatedAt: Date(), fileSize: fileSize,
                    sha256: nil, status: .available
                )
                wallpaperRecords.append(record)
            }
        }

        let mediaDir = dpManager.mediaFolderURL
        if FileManager.default.fileExists(atPath: mediaDir.path) {
            let files = (try? FileManager.default.contentsOfDirectory(at: mediaDir, includingPropertiesForKeys: [.fileSizeKey])) ?? []
            for file in files where !file.lastPathComponent.hasPrefix(".") {
                let destDir = libURL.appendingPathComponent("files/videos", isDirectory: true)
                try? FileManager.default.createDirectory(at: destDir, withIntermediateDirectories: true)
                let dest = destDir.appendingPathComponent(file.lastPathComponent)
                if !FileManager.default.fileExists(atPath: dest.path) {
                    try? FileManager.default.copyItem(at: file, to: dest)
                }
                let relPath = try? relativePath(for: dest)
                let fileSize = (try? file.resourceValues(forKeys: [.fileSizeKey]))?.fileSize.flatMap(Int64.init)
                let id = file.deletingPathExtension().lastPathComponent
                let record = CloudLibraryRecord(
                    id: id, kind: .videoWallpaper, source: "local", title: nil,
                    remoteURL: nil, relativeFilePath: relPath ?? "", thumbnailPath: nil,
                    createdAt: Date(), updatedAt: Date(), fileSize: fileSize,
                    sha256: nil, status: .available
                )
                mediaRecords.append(record)
            }
        }

        if !wallpaperRecords.isEmpty {
            try writeRecords(wallpaperRecords, to: "wallpapers.json")
        }
        if !mediaRecords.isEmpty {
            try writeRecords(mediaRecords, to: "media.json")
        }

        var updatedMF = mf
        updatedMF.records.wallpapers = wallpaperRecords.count
        updatedMF.records.media = mediaRecords.count
        updatedMF.records.downloads = wallpaperRecords.count + mediaRecords.count
        try saveManifest(updatedMF)
    }

    // MARK: - Path Helpers

    func destinationURL(for recordID: String, kind: CloudLibraryItemKind, suggestedFilename: String) throws -> URL {
        guard let libURL = libraryURL else {
            throw CloudSyncError.notEnabled
        }
        let subdir: String
        switch kind {
        case .staticWallpaper: subdir = "files/wallpapers"
        case .videoWallpaper: subdir = "files/videos"
        case .liveWallpaper: subdir = "files/live"
        case .thumbnail: subdir = "thumbnails"
        }
        let dir = libURL.appendingPathComponent(subdir, isDirectory: true)
        if !fm.fileExists(atPath: dir.path) {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true, attributes: nil)
        }
        return dir.appendingPathComponent(suggestedFilename, isDirectory: false)
    }

    func relativePath(for fileURL: URL) throws -> String {
        guard let libURL = libraryURL else {
            throw CloudSyncError.notEnabled
        }
        let libPath = libURL.path.hasSuffix("/") ? libURL.path : libURL.path + "/"
        let filePath = fileURL.path
        guard filePath.hasPrefix(libPath) else {
            throw CloudSyncError.notInLibrary
        }
        return String(filePath.dropFirst(libPath.count))
    }

    func absoluteURL(for relativePath: String) -> URL {
        guard let libURL = libraryURL else {
            return URL(fileURLWithPath: relativePath)
        }
        return libURL.appendingPathComponent(relativePath, isDirectory: false)
    }

    // MARK: - Metadata

    func writeRecords(_ records: [CloudLibraryRecord], to fileName: String) throws {
        guard let libURL = libraryURL else {
            throw CloudSyncError.notEnabled
        }
        let url = libURL.appendingPathComponent("metadata/\(fileName)", isDirectory: false)
        try atomicWriteJSON(records, to: url)
    }

    func readRecords(from url: URL) throws -> [CloudLibraryRecord] {
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode([CloudLibraryRecord].self, from: data)
    }

    // MARK: - Atomic JSON Write

    private let jsonEncoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    private let jsonDecoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    func atomicWriteJSON<T: Encodable & Decodable>(_ value: T, to url: URL) throws {
        let tmpURL = url.appendingPathExtension("tmp")
        let data = try jsonEncoder.encode(value)

        // 1. 写入 .tmp
        try data.write(to: tmpURL, options: .atomic)

        // 2. 重新读取校验
        let verifyData = try Data(contentsOf: tmpURL)
        let _ = try jsonDecoder.decode(T.self, from: verifyData)

        // 3. 替换正式文件
        if fm.fileExists(atPath: url.path) {
            try fm.removeItem(at: url)
        }
        try fm.moveItem(at: tmpURL, to: url)
    }

    // MARK: - Security-Scoped Bookmark

    private func createBookmark(for url: URL) throws -> Data {
        try url.bookmarkData(
            options: .withSecurityScope,
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
    }

    private func resolveBookmark(_ data: Data) throws -> (URL, Bool) {
        var isStale = false
        let url = try URL(
            resolvingBookmarkData: data,
            options: .withSecurityScope,
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        )
        return (url, isStale)
    }
}

// MARK: - Errors

enum CloudSyncError: Error, LocalizedError {
    case notEnabled
    case userCancelled
    case manifestMissing
    case manifestCorrupted
    case notInLibrary
    case directoryNotAccessible
    case bookmarkExpired

    var errorDescription: String? {
        switch self {
        case .notEnabled: return "云盘同步库未启用"
        case .userCancelled: return "用户取消"
        case .manifestMissing: return "manifest.json 缺失"
        case .manifestCorrupted: return "manifest.json 已损坏"
        case .notInLibrary: return "文件不在同步库中"
        case .directoryNotAccessible: return "无法访问目录"
        case .bookmarkExpired: return "目录权限已失效，请重新选择"
        }
    }
}
