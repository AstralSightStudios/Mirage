#if canImport(CryptoKit)
import CryptoKit
#endif
import Foundation

/// AstralSightStudios/MiWearFirmwareArchives on GitHub: every official
/// firmware, one release per product version, full and incremental OTA
/// packages as assets.
public struct ArchiveRelease: Codable, Identifiable, Hashable, Sendable {
    public var id: Int
    public var tag: String
    public var title: String
    public var product: String
    public var version: String
    public var publishedAt: Date
    public var notes: String
    public var url: URL
    public var assets: [ArchiveAsset]

    public var fullPackage: ArchiveAsset? { assets.first { $0.kind == "full" } }
    public var marketingName: String { ProductCatalog.name(of: product) }
    public var model: String { ProductCatalog.model(of: product) }
    public var vendor: String { product.split(separator: ".").first.map(String.init) ?? "" }
}

public struct ArchiveAsset: Codable, Identifiable, Hashable, Sendable {
    public var id: Int
    public var name: String
    public var size: Int64
    public var downloadURL: URL
    public var sha256: String?
    public var downloads: Int
    /// "full" or "from_v<version>_incremental"
    public var kind: String
    /// Package base name (the firmware ID after import).
    public var packageName: String { (name as NSString).deletingPathExtension }
}

public final class FirmwareArchiveClient: @unchecked Sendable {
    public static let repository = "AstralSightStudios/MiWearFirmwareArchives"
    public static let tokenKey = "GitHubToken"

    let library: MirageLibrary
    let session: URLSession

    public init(library: MirageLibrary, session: URLSession = .shared) {
        self.library = library
        self.session = session
    }

    struct Cache: Codable {
        var fetchedAt: Date
        var etags: [String]
        var releases: [ArchiveRelease]
    }

    public var token: String? {
        let t = MirageLibrary.defaults.string(forKey: Self.tokenKey)
        return (t?.isEmpty ?? true) ? ProcessInfo.processInfo.environment["GITHUB_TOKEN"] : t
    }

    /// Releases from the local cache (nil when never fetched).
    public func cached() -> (releases: [ArchiveRelease], fetchedAt: Date)? {
        guard let d = try? Data(contentsOf: library.archiveCacheURL),
              let c = try? MirageLibrary.decoder.decode(Cache.self, from: d) else { return nil }
        return (c.releases, c.fetchedAt)
    }

    /// All releases, newest first. The first page is requested with the
    /// cached ETag: new releases land on page one, so a 304 there means the
    /// cache is current and costs no rate limit.
    public func fetch() async throws -> [ArchiveRelease] {
        let old = (try? Data(contentsOf: library.archiveCacheURL)).flatMap { try? MirageLibrary.decoder.decode(Cache.self, from: $0) }
        var all: [ArchiveRelease] = []
        var etags: [String] = []
        var page = 1
        while true {
            var req = URLRequest(url: URL(string: "https://api.github.com/repos/\(Self.repository)/releases?per_page=100&page=\(page)")!)
            req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
            req.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
            req.setValue("Mirage", forHTTPHeaderField: "User-Agent")
            if let token { req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
            if page == 1, let tag = old?.etags.first, !tag.isEmpty { req.setValue(tag, forHTTPHeaderField: "If-None-Match") }
            let (data, response) = try await session.data(for: req)
            guard let http = response as? HTTPURLResponse else { throw MirageError.io("No HTTP response") }
            if http.statusCode == 304, page == 1, var old {
                old.fetchedAt = Date()
                try? MirageLibrary.encoder.encode(old).write(to: library.archiveCacheURL, options: .atomic)
                return old.releases
            }
            guard http.statusCode == 200 else {
                if http.statusCode == 403 || http.statusCode == 429 {
                    let reset = http.value(forHTTPHeaderField: "x-ratelimit-reset").flatMap(Double.init).map { Date(timeIntervalSince1970: $0) }
                    let when = reset.map { " until \(DateFormatter.localizedString(from: $0, dateStyle: .none, timeStyle: .short))" } ?? ""
                    throw MirageError.io("GitHub API rate limit reached\(when). Add a GitHub token in Settings to raise it.")
                }
                throw MirageError.io("GitHub API returned HTTP \(http.statusCode)")
            }
            etags.append(http.value(forHTTPHeaderField: "ETag") ?? "")
            all.append(contentsOf: try Self.parse(data))
            let link = http.value(forHTTPHeaderField: "Link") ?? ""
            if !link.contains("rel=\"next\"") { break }
            page += 1
        }
        all.sort { $0.publishedAt > $1.publishedAt }
        let cache = Cache(fetchedAt: Date(), etags: etags, releases: all)
        try? MirageLibrary.encoder.encode(cache).write(to: library.archiveCacheURL, options: .atomic)
        return all
    }

    static func parse(_ data: Data) throws -> [ArchiveRelease] {
        guard let arr = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            throw MirageError.protocolError("Unexpected GitHub API response")
        }
        let iso = ISO8601DateFormatter()
        return arr.compactMap { r in
            guard let id = r["id"] as? Int, let tag = r["tag_name"] as? String,
                  r["draft"] as? Bool != true else { return nil }
            // firmware-<product>-v<version>-<hash>
            let comps = tag.components(separatedBy: "-")
            guard comps.count >= 4, comps[0] == "firmware" else { return nil }
            let product = comps[1]
            let version = comps[2].hasPrefix("v") ? String(comps[2].dropFirst()) : comps[2]
            let assets: [ArchiveAsset] = (r["assets"] as? [[String: Any]] ?? []).compactMap { a in
                guard let aid = a["id"] as? Int, let name = a["name"] as? String,
                      let urlS = a["browser_download_url"] as? String, let url = URL(string: urlS) else { return nil }
                let parsed = ProductCatalog.parsePackageName(name)
                let digest = (a["digest"] as? String).flatMap { $0.hasPrefix("sha256:") ? String($0.dropFirst(7)) : nil }
                return ArchiveAsset(id: aid, name: name, size: (a["size"] as? NSNumber)?.int64Value ?? 0,
                                    downloadURL: url, sha256: digest, downloads: a["download_count"] as? Int ?? 0,
                                    kind: parsed?.kind ?? "unknown")
            }
            return ArchiveRelease(id: id, tag: tag, title: r["name"] as? String ?? tag, product: product,
                                  version: version,
                                  publishedAt: (r["published_at"] as? String).flatMap { iso.date(from: $0) } ?? .distantPast,
                                  notes: r["body"] as? String ?? "",
                                  url: URL(string: r["html_url"] as? String ?? "") ?? URL(string: "https://github.com/\(repository)")!,
                                  assets: assets)
        }
    }
}

/// Downloads an archive asset with progress and verifies its SHA-256.
public final class ArchiveDownload: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    public let asset: ArchiveAsset
    let destination: URL
    private var continuation: CheckedContinuation<URL, Error>?
    private var progress: (@Sendable (Int64, Int64) -> Void)?
    private var task: URLSessionDownloadTask?
    private lazy var session = URLSession(configuration: .default, delegate: self, delegateQueue: nil)
    private var resumeDataURL: URL { destination.appendingPathExtension("resume") }

    public init(asset: ArchiveAsset, into directory: URL) {
        self.asset = asset
        self.destination = directory.appendingPathComponent(asset.name)
    }

    public func start(progress: @escaping @Sendable (Int64, Int64) -> Void) async throws -> URL {
        if FileManager.default.fileExists(atPath: destination.path), try verify(destination) {
            return destination
        }
        self.progress = progress
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { cont in
                self.continuation = cont
                if let resume = try? Data(contentsOf: resumeDataURL) {
                    task = session.downloadTask(withResumeData: resume)
                } else {
                    task = session.downloadTask(with: asset.downloadURL)
                }
                task?.resume()
            }
        } onCancel: {
            self.cancel()
        }
    }

    public func cancel() {
        task?.cancel { [resumeDataURL] data in
            if let data { try? data.write(to: resumeDataURL) }
        }
    }

    public func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData _: Int64,
                           totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        progress?(totalBytesWritten, totalBytesExpectedToWrite > 0 ? totalBytesExpectedToWrite : asset.size)
    }

    public func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        do {
            if FileManager.default.fileExists(atPath: destination.path) {
                try FileManager.default.removeItem(at: destination)
            }
            try FileManager.default.moveItem(at: location, to: destination)
            try? FileManager.default.removeItem(at: resumeDataURL)
            guard try verify(destination) else {
                try? FileManager.default.removeItem(at: destination)
                throw MirageError.io("\(asset.name): SHA-256 does not match the archive")
            }
            continuation?.resume(returning: destination)
        } catch {
            continuation?.resume(throwing: error)
        }
        continuation = nil
        session.finishTasksAndInvalidate()
    }

    public func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let error else { return }
        if let data = (error as NSError).userInfo[NSURLSessionDownloadTaskResumeData] as? Data {
            try? data.write(to: resumeDataURL)
        }
        let cancelled = (error as NSError).code == NSURLErrorCancelled
        continuation?.resume(throwing: cancelled ? MirageError.cancelled : error)
        continuation = nil
        session.finishTasksAndInvalidate()
    }

    func verify(_ url: URL) throws -> Bool {
        guard let expected = asset.sha256 else {
            let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64) ?? -1
            return size == asset.size
        }
        let fh = try FileHandle(forReadingFrom: url)
        defer { try? fh.close() }
        var hasher = SHA256()
        while let chunk = try fh.read(upToCount: 8 << 20), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        let hex = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        return hex == expected.lowercased()
    }
}
