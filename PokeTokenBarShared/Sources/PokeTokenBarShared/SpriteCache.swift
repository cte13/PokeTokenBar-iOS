import Foundation

/// Single source for PokéAPI sprite URLs (companion, dex, items) shared by app and widget.
public enum PokeSpriteURL {
    private static let base = "https://raw.githubusercontent.com/PokeAPI/sprites/master/sprites"

    /// Static PNG. A form uses the Mac's resolved file name (`10006` for Sky Shaymin, `412-sandy`).
    public static func species(id: Int, shiny: Bool, form: PhoneSpriteForm? = nil) -> URL? {
        URL(string: "\(base)/pokemon/\(shiny ? "shiny/" : "")\(form?.staticAsset ?? "\(id)").png")
    }

    /// Gen-V animated GIF — only species 1…649 have one (same rule as the Mac's PokemonAssets).
    public static func hasAnimatedSprite(id: Int) -> Bool { (1...649).contains(id) }

    public static func animatedSpecies(id: Int, shiny: Bool, form: PhoneSpriteForm? = nil) -> URL? {
        guard hasAnimatedSprite(id: id) else { return nil }
        let name = form?.animatedAsset ?? "\(id)"
        return URL(string: "\(base)/pokemon/versions/generation-v/black-white/animated/\(shiny ? "shiny/" : "")\(name).gif")
    }

    /// Default forms keep the plain keys, so sprites cached before forms existed stay valid.
    public static func animatedSpeciesKey(id: Int, shiny: Bool, form: PhoneSpriteForm? = nil) -> String {
        if let form, !form.isDefault { return "\(id)_\(form.form)_\(shiny)_anim.gif" }
        return "\(id)_\(shiny)_anim.gif"
    }

    public static func item(name: String) -> URL? {
        URL(string: "\(base)/items/\(name).png")
    }

    /// Stable on-disk file name for a species sprite — the same key the widget has always used.
    public static func speciesKey(id: Int, shiny: Bool, form: PhoneSpriteForm? = nil) -> String {
        if let form, !form.isDefault { return "\(id)_\(form.form)_\(shiny).png" }
        return "\(id)_\(shiny).png"
    }
    public static func itemKey(name: String) -> String { "item_\(name).png" }
}

/// Outcome of one sprite fetch. Only a temporary failure is worth retrying: a 404 means the
/// sprite doesn't exist (e.g. no animated GIF for that form) and retrying it would never succeed.
public enum SpriteFetchResult<Value> {
    case loaded(Value)
    case notFound
    case failed
}

/// Retries a sprite fetch after temporary failures (upstream #447): 2 s, doubling to a 30 s cap,
/// with no attempt limit. The caller owns the await, so cancelling its view task (the view
/// disappearing or its key changing) also stops the backoff.
public enum SpriteRetry {
    public static let initialDelay = Duration.seconds(2)
    public static let maximumDelay = Duration.seconds(30)

    /// Runs on the caller's actor (`isolation`), so a SwiftUI view task can pass its closure.
    public static func load<Value>(
        isolation: isolated (any Actor)? = #isolation,
        waitBeforeRetry: (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
        _ attempt: () async -> SpriteFetchResult<Value>
    ) async -> Value? {
        var delay = initialDelay
        while !Task.isCancelled {
            switch await attempt() {
            case .loaded(let value): return value
            case .notFound: return nil
            case .failed: break
            }
            guard !Task.isCancelled else { return nil }
            do { try await waitBeforeRetry(delay) } catch { return nil }
            delay = min(delay * 2, maximumDelay)
        }
        return nil
    }
}

#if canImport(UIKit)
import UIKit

/// Sprite cache shared by the iOS app and the widget extension: memory (NSCache) in front of the
/// app-group `WidgetSprites` directory. The widget cannot load over the network reliably, so the app
/// warms the disk layer whenever a payload arrives; both read through `cachedImage`.
public final class SpriteCache: @unchecked Sendable {
    public static let shared = SpriteCache()

    public static let appGroup = "group.io.github.chattymin.poketokenbar"

    private let memory = NSCache<NSString, UIImage>()
    private let directory: URL?
    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
        directory = FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: Self.appGroup)?
            .appendingPathComponent("WidgetSprites", isDirectory: true)
        if let directory {
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
    }

    /// Synchronous lookup: memory, then disk. Never touches the network.
    public func cachedImage(key: String) -> UIImage? {
        if let hit = memory.object(forKey: key as NSString) { return hit }
        guard let file = directory?.appendingPathComponent(key),
              let data = try? Data(contentsOf: file),
              let image = UIImage(data: data) else { return nil }
        memory.setObject(image, forKey: key as NSString)
        return image
    }

    /// Cached image or a network fetch that populates both layers. nil on any failure.
    public func image(for url: URL?, key: String) async -> UIImage? {
        if case .loaded(let image) = await fetchImage(for: url, key: key) { return image }
        return nil
    }

    /// Like `image(for:key:)`, but says whether a failure is worth retrying.
    public func fetchImage(for url: URL?, key: String) async -> SpriteFetchResult<UIImage> {
        if let hit = cachedImage(key: key) { return .loaded(hit) }
        switch await fetchData(for: url, key: key) {
        case .loaded(let data):
            // Undecodable bytes won't decode on a retry either.
            guard let image = UIImage(data: data) else { return .notFound }
            memory.setObject(image, forKey: key as NSString)
            return .loaded(image)
        case .notFound: return .notFound
        case .failed: return .failed
        }
    }

    /// Raw bytes (e.g. an animated GIF) from disk, else fetched and written to disk. nil on failure.
    public func data(for url: URL?, key: String) async -> Data? {
        if case .loaded(let data) = await fetchData(for: url, key: key) { return data }
        return nil
    }

    /// Like `data(for:key:)`, but says whether a failure is worth retrying.
    public func fetchData(for url: URL?, key: String) async -> SpriteFetchResult<Data> {
        if let file = directory?.appendingPathComponent(key), let data = try? Data(contentsOf: file) {
            return .loaded(data)
        }
        guard let url else { return .notFound }
        guard let (data, response) = try? await session.data(from: url) else { return .failed }
        let status = (response as? HTTPURLResponse)?.statusCode
        guard status == 200, !data.isEmpty else {
            // 404/410: the sprite doesn't exist. Rate limits, 5xx and empty bodies can recover.
            return status == 404 || status == 410 ? .notFound : .failed
        }
        if let file = directory?.appendingPathComponent(key) {
            try? data.write(to: file, options: .atomic)
        }
        return .loaded(data)
    }

    /// Warm the disk layer for what the widget will need (current + representative sprite).
    public func prefetchSpecies(_ sprites: [(id: Int, shiny: Bool, form: PhoneSpriteForm?)]) async {
        for sprite in sprites {
            _ = await image(for: PokeSpriteURL.species(id: sprite.id, shiny: sprite.shiny, form: sprite.form),
                            key: PokeSpriteURL.speciesKey(id: sprite.id, shiny: sprite.shiny, form: sprite.form))
        }
    }

    /// Warm the disk layer for items in the bag and shop.
    public func prefetchItems(_ itemNames: [String]) async {
        for name in itemNames {
            _ = await image(for: PokeSpriteURL.item(name: name),
                            key: PokeSpriteURL.itemKey(name: name))
        }
    }
}
#endif
