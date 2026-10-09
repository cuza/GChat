import AppKit

/// Public images (profile photos, space icons), fetched over https with no cookies or credentials,
/// as Google Chat does. Chat media goes through `ChatBackend.attachmentData`.
@MainActor enum RemoteImage {
    private static let cache: NSCache<NSURL, NSImage> = { let cache = NSCache<NSURL, NSImage>(); cache.countLimit = 300; return cache }()
    private static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieStorage = nil
        config.httpShouldSetCookies = false
        config.urlCredentialStorage = nil
        config.timeoutIntervalForRequest = 30
        return URLSession(configuration: config)
    }()

    /// FIFE hosts take a size suffix: `=s<px>-c` (square crop) replaces any existing `=…` options. Other hosts are unchanged.
    nonisolated static func sized(_ url: URL, px: Int) -> URL {
        guard let host = url.host(), host.hasSuffix(".googleusercontent.com") || host.hasSuffix(".ggpht.com"),
              var parts = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return url }
        var path = parts.percentEncodedPath
        if let options = path.lastIndex(of: "="), !path[options...].contains("/") { path = String(path[..<options]) }
        parts.percentEncodedPath = path + "=s\(px)-c"
        return parts.url ?? url
    }

    /// Pictures that are drawn, not fetched (the demo workspace's app icons).
    static func preload(_ images: [(URL, NSImage)]) { for (url, image) in images { cache.setObject(image, forKey: url as NSURL) } }
    /// The sized rendition, or the original URL if that fails (the suffix is unverified live on every URL shape).
    // ponytail: concurrent requests for one URL each fetch; the session's in-memory URLCache absorbs most repeats.
    static func image(_ url: URL, px: Int) async -> NSImage? {
        let key = sized(url, px: px)
        if let hit = cache.object(forKey: key as NSURL) { return hit }
        for candidate in key == url ? [url] : [key, url] where candidate.scheme == "https" && !Task.isCancelled {
            guard let (data, response) = try? await session.data(from: candidate),
                  (response as? HTTPURLResponse)?.statusCode == 200, let image = NSImage(data: data) else { continue }
            cache.setObject(image, forKey: key as NSURL)
            return image
        }
        return nil
    }
}
