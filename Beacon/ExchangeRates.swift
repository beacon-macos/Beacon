import Foundation

@MainActor
final class ExchangeRates {
    nonisolated struct Snapshot: Codable, Equatable, Sendable {
        let date: String
        let downloadDate: Date
        /// Units of each currency per US dollar.
        let rates: [String: Double]
    }

    /// The second URL is the fallback mirror the feed's documentation recommends.
    nonisolated static let sourceURLs = [
        URL(string: "https://cdn.jsdelivr.net/npm/@fawazahmed0/currency-api@latest/v1/currencies/usd.min.json")!,
        URL(string: "https://latest.currency-api.pages.dev/v1/currencies/usd.min.json")!
    ]

    nonisolated static var defaultCacheURL: URL {
        URL.cachesDirectory.appending(path: "Beacon/ExchangeRates.json")
    }

    private static let maximumAge: TimeInterval = 6 * 60 * 60
    private static let retryDelay: TimeInterval = 60

    private(set) var snapshot: Snapshot?
    private(set) var isLoading = false

    var onChange: (() -> Void)?

    private let sourceURLs: [URL]
    private let cacheURL: URL
    private let session: URLSession
    private var hasReadCache = false
    private var lastFailureDate: Date?

    init(
        sourceURLs: [URL] = ExchangeRates.sourceURLs,
        cacheURL: URL = ExchangeRates.defaultCacheURL,
        session: URLSession = .shared
    ) {
        self.sourceURLs = sourceURLs
        self.cacheURL = cacheURL
        self.session = session
    }

    func rate(from source: String, to target: String) -> Double? {
        guard let sourceRate = snapshot?.rates[source], let targetRate = snapshot?.rates[target], sourceRate > 0 else {
            return nil
        }
        return targetRate / sourceRate
    }

    /// Waits a minute after a failed download, because every keystroke of a conversion asks for rates.
    func refreshIfNeeded() {
        if let snapshot, Date.now.timeIntervalSince(snapshot.downloadDate) < Self.maximumAge { return }
        if let lastFailureDate, Date.now.timeIntervalSince(lastFailureDate) < Self.retryDelay { return }
        refresh()
    }

    func refresh() {
        guard !isLoading else { return }
        isLoading = true
        Task {
            await load()
            isLoading = false
            onChange?()
        }
    }

    private func load() async {
        if !hasReadCache {
            hasReadCache = true
            let cacheURL = cacheURL
            let cachedSnapshot = await Task.detached(priority: .userInitiated) {
                try? JSONDecoder().decode(Snapshot.self, from: Data(contentsOf: cacheURL))
            }.value
            if let cachedSnapshot {
                snapshot = cachedSnapshot
                if Date.now.timeIntervalSince(cachedSnapshot.downloadDate) < Self.maximumAge { return }
            }
        }
        do {
            let snapshot = try await download()
            self.snapshot = snapshot
            lastFailureDate = nil
            let cacheURL = cacheURL
            await Task.detached(priority: .utility) {
                try? FileManager.default.createDirectory(
                    at: cacheURL.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                try? JSONEncoder().encode(snapshot).write(to: cacheURL, options: .atomic)
            }.value
        } catch {
            lastFailureDate = .now
        }
    }

    private func download() async throws -> Snapshot {
        var lastError: Error = URLError(.badURL)
        for url in sourceURLs {
            do {
                let request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 10)
                let (data, response) = try await session.data(for: request)
                if let response = response as? HTTPURLResponse, response.statusCode != 200 {
                    throw URLError(.badServerResponse)
                }
                let feed = try JSONDecoder().decode(Feed.self, from: data)
                let rates = Dictionary(
                    feed.usd.compactMap { code, rate in rate.map { (code.uppercased(), $0) } },
                    uniquingKeysWith: { first, _ in first }
                )
                guard !rates.isEmpty else { throw URLError(.cannotParseResponse) }
                return Snapshot(date: feed.date, downloadDate: .now, rates: rates)
            } catch {
                lastError = error
            }
        }
        throw lastError
    }

    private nonisolated struct Feed: Decodable {
        let date: String
        let usd: [String: Double?]
    }
}
