import AppKit
import CryptoKit
import Foundation
import RackoonCore
import SwiftUI

/// Favicons of bookmarked services, fetched from the Mac (so Tailscale-only addresses work when the Mac is on the tailnet),
/// cached as small PNGs under Application Support/Rackoon/favicons and shown in Bookmarks and on the Docker overview.
///
/// One icon per site (its origin), found from the page's `<link rel="icon">` tags and then `/favicon.ico`. A site with no
/// icon is remembered for a day so it isn't asked again on every launch; clicking an icon fetches a fresh one at once.
/// Only a GET with no credentials is sent, so certificate errors (self-signed home servers) are tolerated for this fetch.
@MainActor @Observable
final class FaviconStore {
    static let shared = FaviconStore()

    /// Origin -> icon. Loaded from disk when the app starts, so reading it from a view never mutates anything.
    private(set) var images: [String: NSImage] = [:]
    /// Origins being fetched right now.
    private(set) var fetching: Set<String> = []

    private struct Entry: Codable {
        var file: String?
        var attemptedAt: Date
    }

    @ObservationIgnored private var index: [String: Entry] = [:]
    @ObservationIgnored private let directory: URL
    @ObservationIgnored private var queue: [(origin: String, href: String)] = []
    @ObservationIgnored private var worker: Task<Void, Never>?
    /// How long a site without an icon is left alone before the next automatic try.
    private static let retryAfter: TimeInterval = 24 * 3600

    init(directory: URL? = nil) {
        self.directory = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Rackoon/favicons", isDirectory: true)
        try? FileManager.default.createDirectory(at: self.directory, withIntermediateDirectories: true)
        if let data = try? Data(contentsOf: self.directory.appendingPathComponent("index.json")),
           let loaded = try? JSONDecoder().decode([String: Entry].self, from: data) {
            index = loaded
            for (origin, entry) in loaded {
                if let file = entry.file, let image = NSImage(contentsOf: self.directory.appendingPathComponent(file)) { images[origin] = image }
            }
        }
    }

    // MARK: reading

    func image(for href: String) -> NSImage? { FaviconLinks.origin(of: href).flatMap { images[$0] } }
    func isFetching(_ href: String) -> Bool { FaviconLinks.origin(of: href).map { fetching.contains($0) } ?? false }

    // MARK: fetching

    /// Fetches icons that are missing: sites never tried, and sites without an icon last tried over a day ago.
    func ensure(_ hrefs: [String]) {
        for href in hrefs {
            guard let origin = FaviconLinks.origin(of: href), !fetching.contains(origin), !queue.contains(where: { $0.origin == origin }) else { continue }
            if let entry = index[origin], entry.file != nil || Date().timeIntervalSince(entry.attemptedAt) < Self.retryAfter { continue }
            enqueue(origin, href)
        }
    }

    /// The user clicked the icon: try again now, whatever was cached.
    func refresh(_ href: String) {
        guard let origin = FaviconLinks.origin(of: href), !fetching.contains(origin) else { return }
        enqueue(origin, href)
    }

    private func enqueue(_ origin: String, _ href: String) {
        queue.append((origin, href))
        fetching.insert(origin)
        guard worker == nil else { return }
        worker = Task { [weak self] in
            // One at a time, so a long bookmark list doesn't open dozens of connections at once.
            while let job = self?.queue.first {
                self?.queue.removeFirst()
                let png = await Self.fetchIcon(origin: job.origin, href: job.href)
                self?.finish(origin: job.origin, png: png)
            }
            self?.worker = nil
        }
    }

    private func finish(origin: String, png: Data?) {
        fetching.remove(origin)
        if let png, let image = NSImage(data: png) {
            let name = Self.fileName(for: origin)
            try? png.write(to: directory.appendingPathComponent(name), options: .atomic)
            images[origin] = image
            index[origin] = Entry(file: name, attemptedAt: Date())
        } else if index[origin]?.file == nil {
            // Nothing found, and nothing kept from before: remember the attempt. (A failed refresh keeps the old icon.)
            index[origin] = Entry(file: nil, attemptedAt: Date())
        }
        if let data = try? JSONEncoder().encode(index) { try? data.write(to: directory.appendingPathComponent("index.json"), options: .atomic) }
    }

    nonisolated private static func fileName(for origin: String) -> String {
        SHA256.hash(data: Data(origin.utf8)).prefix(10).map { String(format: "%02x", $0) }.joined() + ".png"
    }

    // MARK: the network part (off the main actor)

    /// The page's own icon links first, then `/favicon.ico`; the first thing that decodes as an image wins.
    nonisolated private static func fetchIcon(origin: String, href: String) async -> Data? {
        let session = URLSession(configuration: {
            let c = URLSessionConfiguration.ephemeral
            c.timeoutIntervalForRequest = 6
            c.timeoutIntervalForResource = 20
            c.httpCookieStorage = nil
            c.requestCachePolicy = .reloadIgnoringLocalCacheData
            return c
        }(), delegate: TrustingDelegate(), delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }

        var tried = Set<URL>()
        var urls: [URL] = []
        if let pageURL = URL(string: href), let page = await get(pageURL, limit: 256 * 1024, session: session),
           let html = String(data: page.data, encoding: .utf8) ?? String(data: page.data, encoding: .isoLatin1) {
            urls += FaviconLinks.candidates(in: html, base: page.finalURL).map(\.url)
        }
        if let fallback = FaviconLinks.defaultIcon(for: origin) { urls.append(fallback) }
        for url in urls where tried.insert(url).inserted {
            if let response = await get(url, limit: 1024 * 1024, session: session), let png = renderPNG(response.data) { return png }
        }
        return nil
    }

    private struct Response { var data: Data; var finalURL: URL }

    /// A GET with a size cap: 2xx only, http(s) only (a redirect to anything else is refused).
    nonisolated private static func get(_ url: URL, limit: Int, session: URLSession) async -> Response? {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else { return nil }
        var request = URLRequest(url: url)
        request.setValue("Rackoon/1.0 (favicon fetch)", forHTTPHeaderField: "User-Agent")
        request.setValue("text/html,image/*;q=0.9,*/*;q=0.5", forHTTPHeaderField: "Accept")
        guard let (bytes, response) = try? await session.bytes(for: request), let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode), let final = http.url,
              let finalScheme = final.scheme?.lowercased(), finalScheme == "http" || finalScheme == "https" else { return nil }
        var data = Data()
        do {
            for try await byte in bytes {
                data.append(byte)
                if data.count >= limit { break }   // an icon or a page head is small; stop reading anything bigger
            }
        } catch { return data.isEmpty ? nil : Response(data: data, finalURL: final) }
        return data.isEmpty ? nil : Response(data: data, finalURL: final)
    }

    /// Decodes whatever image format arrived (PNG, ICO, JPEG, GIF, WebP, SVG...) and re-draws it as a 128 px PNG.
    nonisolated static func renderPNG(_ data: Data) -> Data? {
        guard let source = NSImage(data: data), source.size.width >= 1, source.size.height >= 1 else { return nil }
        let side = 128
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: side, pixelsHigh: side, bitsPerSample: 8, samplesPerPixel: 4,
                                         hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
              let context = NSGraphicsContext(bitmapImageRep: rep) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        context.imageInterpolation = .high
        let scale = min(CGFloat(side) / source.size.width, CGFloat(side) / source.size.height)
        let w = source.size.width * scale, h = source.size.height * scale
        source.draw(in: NSRect(x: (CGFloat(side) - w) / 2, y: (CGFloat(side) - h) / 2, width: w, height: h),
                    from: .zero, operation: .sourceOver, fraction: 1)
        NSGraphicsContext.restoreGraphicsState()
        return rep.representation(using: .png, properties: [:])
    }
}

/// Accepts any server certificate for the favicon fetch only: no credentials or cookies are sent, and home servers often
/// use self-signed certificates. The worst a network attacker could do is substitute the picture.
private final class TrustingDelegate: NSObject, URLSessionDelegate {
    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        if challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust, let trust = challenge.protectionSpace.serverTrust {
            completionHandler(.useCredential, URLCredential(trust: trust))
        } else {
            completionHandler(.performDefaultHandling, nil)
        }
    }
}

/// A bookmark's icon: its favicon when we have one, else a bookmark glyph. Clicking fetches a fresh favicon.
struct FaviconView: View {
    let href: String
    var size: CGFloat = 22
    var placeholder = "bookmark.fill"
    /// Hide the placeholder (used where the icon is only worth showing when it exists).
    var hideWhenMissing = false

    var body: some View {
        let store = FaviconStore.shared
        let image = store.image(for: href)
        if !(hideWhenMissing && image == nil) {
            Button { store.refresh(href) } label: {
                ZStack {
                    if store.isFetching(href) {
                        ProgressView().controlSize(.small)
                    } else if let image {
                        Image(nsImage: image).resizable().interpolation(.high).scaledToFit()
                            .clipShape(RoundedRectangle(cornerRadius: size * 0.22))
                    } else {
                        Image(systemName: placeholder).font(.system(size: size * 0.65)).foregroundStyle(Theme.accent)
                    }
                }
                .frame(width: size, height: size).contentShape(Rectangle())
            }
            .buttonStyle(.pointer)
            .help(image == nil ? "Click to fetch this site's icon" : "Click to fetch a new icon")
            .accessibilityLabel("Site icon")
        }
    }
}
