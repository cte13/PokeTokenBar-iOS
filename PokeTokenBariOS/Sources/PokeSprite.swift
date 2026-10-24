import SwiftUI
import ImageIO
import UniformTypeIdentifiers
import PokeTokenBarShared

/// Sprite image backed by `SpriteCache` — renders from cache immediately (no spinner on
/// revisits) and only downloads on a miss. `key` is the cache file name.
struct CachedSprite<Placeholder: View>: View {
    let url: URL?
    let key: String
    @ViewBuilder let placeholder: () -> Placeholder

    @State private var image: UIImage?

    init(url: URL?, key: String, @ViewBuilder placeholder: @escaping () -> Placeholder) {
        self.url = url
        self.key = key
        self.placeholder = placeholder
        _image = State(initialValue: SpriteCache.shared.cachedImage(key: key))
    }

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image).resizable().interpolation(.none)
            } else {
                placeholder()
            }
        }
        // Always resolve the current key: SwiftUI keeps this view's @State across a key change
        // (e.g. the companion evolving), so an `if image == nil` guard would keep the old sprite.
        .task(id: key) {
            // Keep the placeholder while a temporary failure recovers; a cancelled task (key change,
            // view gone) stops retrying and must not clear a newer key's image.
            let loaded = await SpriteRetry.load { await SpriteCache.shared.fetchImage(for: url, key: key) }
            if !Task.isCancelled { image = loaded }
        }
    }
}

/// Species sprite (pixelated) — companion card, dex cells, empty states.
struct SpeciesSprite: View {
    let speciesID: Int
    let shiny: Bool
    let size: CGFloat
    var form: PhoneSpriteForm? = nil

    var body: some View {
        CachedSprite(url: PokeSpriteURL.species(id: speciesID, shiny: shiny, form: form),
                     key: PokeSpriteURL.speciesKey(id: speciesID, shiny: shiny, form: form)) {
            ProgressView()
        }
        .frame(width: size, height: size)
    }
}

/// Item icon — PokéAPI item sprite with emoji fallback. Shared by bag/shop cards.
struct ItemIconView: View {
    let iconName: String?
    let fallbackEmoji: String
    let size: CGFloat

    var body: some View {
        Group {
            if let iconName {
                CachedSprite(url: PokeSpriteURL.item(name: iconName),
                             key: PokeSpriteURL.itemKey(name: iconName)) {
                    Text(fallbackEmoji).font(.system(size: size * 0.6))
                }
            } else {
                Text(fallbackEmoji).font(.system(size: size * 0.6))
            }
        }
        .frame(width: size, height: size)
    }
}

/// Animated companion sprite, like the Mac's header: the Gen-V GIF when the species has one,
/// otherwise the static sprite. Decoded once per key via ImageIO and cached on disk.
struct AnimatedSpeciesSprite: View {
    let speciesID: Int
    let shiny: Bool
    let size: CGFloat
    var form: PhoneSpriteForm? = nil

    @State private var animated: UIImage?

    var body: some View {
        Group {
            if let animated {
                AnimatedImageView(image: animated)
            } else {
                SpeciesSprite(speciesID: speciesID, shiny: shiny, size: size, form: form)
            }
        }
        .frame(width: size, height: size)
        .task(id: PokeSpriteURL.animatedSpeciesKey(id: speciesID, shiny: shiny, form: form)) {
            animated = nil
            guard PokeSpriteURL.hasAnimatedSprite(id: speciesID) else { return }
            let key = PokeSpriteURL.animatedSpeciesKey(id: speciesID, shiny: shiny, form: form)
            let url = PokeSpriteURL.animatedSpecies(id: speciesID, shiny: shiny, form: form)
            // The static sprite shows while a temporary GIF failure recovers (upstream #447).
            let frames = await SpriteRetry.load { () -> SpriteFetchResult<UIImage> in
                switch await SpriteCache.shared.fetchData(for: url, key: key) {
                case .loaded(let data):
                    return GIFDecoder.animatedImage(from: data).map { .loaded($0) } ?? .notFound
                case .notFound: return .notFound
                case .failed: return .failed
                }
            }
            if !Task.isCancelled { animated = frames }
        }
    }
}

/// UIImageView host — SwiftUI's Image does not play UIImage.animatedImage frames.
private struct AnimatedImageView: UIViewRepresentable {
    let image: UIImage

    func makeUIView(context: Context) -> UIImageView {
        let view = UIImageView()
        view.contentMode = .scaleAspectFit
        view.layer.magnificationFilter = .nearest   // keep the pixel-art crisp when scaled up
        view.setContentHuggingPriority(.defaultLow, for: .horizontal)
        view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        view.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        return view
    }

    func updateUIView(_ view: UIImageView, context: Context) {
        guard view.image !== image else { return }
        view.image = image
        view.startAnimating()
    }
}

enum GIFDecoder {
    /// All frames with their summed delay as one animated UIImage. nil for non-GIF / single-frame data.
    static func animatedImage(from data: Data) -> UIImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let count = CGImageSourceGetCount(source)
        guard count > 1 else { return nil }
        var frames: [UIImage] = []
        var duration: TimeInterval = 0
        for i in 0..<count {
            guard let cg = CGImageSourceCreateImageAtIndex(source, i, nil) else { continue }
            frames.append(UIImage(cgImage: cg))
            duration += frameDelay(source, i)
        }
        guard frames.count > 1 else { return nil }
        return UIImage.animatedImage(with: frames, duration: duration)
    }

    private static func frameDelay(_ source: CGImageSource, _ index: Int) -> TimeInterval {
        guard let props = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any],
              let gif = props[kCGImagePropertyGIFDictionary] as? [CFString: Any] else { return 0.1 }
        let unclamped = gif[kCGImagePropertyGIFUnclampedDelayTime] as? Double
        let clamped = gif[kCGImagePropertyGIFDelayTime] as? Double
        let delay = (unclamped ?? clamped) ?? 0.1
        return delay < 0.02 ? 0.1 : delay
    }
}
