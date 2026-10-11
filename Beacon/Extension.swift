import Foundation

nonisolated struct ExtensionIcon: Codable, Hashable, Sendable {
    /// Bundle identifier of an application whose icon is shown.
    var app: String?
    /// Path of a file or folder whose Finder icon is shown.
    var file: String?
    /// Name of an SF Symbol.
    var symbol: String?
}

nonisolated struct ExtensionManifest: Codable, Hashable, Sendable {
    struct Command: Codable, Hashable, Sendable {
        let id: String
        let title: String
        var subtitle: String?
        var placeholder: String?
    }

    let id: String
    let name: String
    let description: String
    let version: String
    var author: String?
    var icon: ExtensionIcon?
    let main: String
    let commands: [Command]

    func validate() throws {
        guard Self.isValidIdentifier(id) else {
            throw ExtensionError.invalidManifest("“\(id)” is not a valid extension identifier.")
        }
        guard !main.isEmpty,
              !main.hasPrefix("."),
              !main.contains("/"),
              main.hasSuffix(".js") else {
            throw ExtensionError.invalidManifest("“\(main)” is not a valid script file name.")
        }
        guard !commands.isEmpty else {
            throw ExtensionError.invalidManifest("The extension does not declare any commands.")
        }
        for command in commands where !Self.isValidIdentifier(command.id) {
            throw ExtensionError.invalidManifest("“\(command.id)” is not a valid command identifier.")
        }
    }

    static func isValidIdentifier(_ value: String) -> Bool {
        guard let first = value.unicodeScalars.first, first != "-" else { return false }
        return value.unicodeScalars.allSatisfy { scalar in
            ("a"..."z").contains(scalar) || ("0"..."9").contains(scalar) || scalar == "-"
        }
    }
}

nonisolated struct ExtensionCatalog: Decodable, Sendable {
    struct Entry: Decodable, Hashable, Identifiable, Sendable {
        let id: String
        let name: String
        let description: String
        let version: String
        var icon: ExtensionIcon?
    }

    let extensions: [Entry]
}

nonisolated struct InstalledExtension: Hashable, Identifiable, Sendable {
    let manifest: ExtensionManifest
    let directory: URL

    var id: String { manifest.id }
    var scriptURL: URL { directory.appending(path: manifest.main) }
}

nonisolated enum ExtensionAction: Decodable, Hashable, Sendable {
    case open(target: String, application: String?)

    private enum CodingKeys: String, CodingKey {
        case type
        case target
        case application
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(String.self, forKey: .type)
        switch type {
        case "open":
            self = .open(
                target: try container.decode(String.self, forKey: .target),
                application: try container.decodeIfPresent(String.self, forKey: .application)
            )
        default:
            throw DecodingError.dataCorruptedError(
                forKey: .type,
                in: container,
                debugDescription: "Unsupported action type “\(type)”."
            )
        }
    }

    /// Resolves an action target to a URL. Paths may start with `/` or `~`; anything else must be a URL with a scheme.
    static func url(forTarget target: String) -> URL? {
        if target.hasPrefix("/") || target.hasPrefix("~") {
            return URL(filePath: (target as NSString).expandingTildeInPath)
        }
        guard let url = URL(string: target), url.scheme?.isEmpty == false else { return nil }
        return url
    }
}

nonisolated struct ExtensionItem: Decodable, Hashable, Sendable {
    let title: String
    var subtitle: String?
    var icon: ExtensionIcon?
    let action: ExtensionAction
}

nonisolated enum ExtensionError: LocalizedError, Equatable {
    case invalidManifest(String)
    case download(String)
    case commandNotFound(String)
    case script(String)
    case invalidResult(String)

    var errorDescription: String? {
        switch self {
        case .invalidManifest(let message):
            return "Invalid extension: \(message)"
        case .download(let message):
            return "Download failed: \(message)"
        case .commandNotFound(let command):
            return "The extension does not implement the “\(command)” command."
        case .script(let message):
            return "The extension failed: \(message)"
        case .invalidResult(let message):
            return "The extension returned invalid results: \(message)"
        }
    }
}

extension String {
    /// Compares dotted version strings numerically, so `1.10.0` is newer than `1.9.0`.
    nonisolated func isNewerVersion(than other: String) -> Bool {
        compare(other, options: .numeric) == .orderedDescending
    }
}
