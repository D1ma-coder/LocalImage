import SwiftUI
import UniformTypeIdentifiers

enum ImageCache {
    private static let cache = NSCache<NSURL, NSImage>()

    static func image(_ url: URL) -> NSImage? {
        if let hit = cache.object(forKey: url as NSURL) { return hit }
        guard let image = NSImage(contentsOf: url) else { return nil }
        cache.setObject(image, forKey: url as NSURL)
        return image
    }
}

struct StudioView: View {
    @Environment(Studio.self) private var studio
    @State private var dropTargeted = false

    var body: some View {
        @Bindable var studio = studio
        VStack(spacing: 0) {
            CanvasView()
                .overlay {
                    if dropTargeted {
                        RoundedRectangle(cornerRadius: 20)
                            .strokeBorder(.tint, style: StrokeStyle(lineWidth: 2, dash: [8, 6]))
                            .padding(16)
                            .overlay(Label(studio.maxImages > 1 ? "Прикрепить изображения" : "Прикрепить изображение",
                                           systemImage: "photo.badge.plus").font(.title3))
                    }
                }
                .dropDestination(for: URL.self) { urls, _ in
                    let images = urls.filter { UTType(filenameExtension: $0.pathExtension)?.conforms(to: .image) == true }
                    guard !images.isEmpty, studio.maxImages > 0 else { return false }
                    studio.addImages(images)
                    return true
                } isTargeted: { dropTargeted = $0 && studio.maxImages > 0 }
            StepStrip()
            PromptBar()
                .padding(.horizontal, 18)
                .padding(.bottom, 16)
                .padding(.top, 6)
        }
        .navigationTitle("Студия")
        .toolbar(removing: .title)
        .toolbar {
            ToolbarItem(placement: .navigation) { ModelSwitcher() }
        }
        .sheet(isPresented: $studio.showLog) { LogView(lines: studio.log) }
    }
}

/// Model choice in the toolbar, like the model switcher in modern AI chats.
private struct ModelSwitcher: View {
    @Environment(Studio.self) private var studio
    @Environment(ModelStore.self) private var store
    @Environment(AppModel.self) private var app

    var body: some View {
        Menu {
            if store.readyModels.isEmpty {
                Text("Нет загруженных моделей")
            }
            ForEach(store.readyModels) { model in
                Button {
                    studio.selectModel(model.id)
                } label: {
                    if model.id == studio.selectedModelID {
                        Image(systemName: "checkmark")
                    }
                    Text(model.title)
                    Text(subtitle(for: model))
                }
                .disabled(studio.isRunning)
            }
            Divider()
            Button("Скачать другие модели…") { app.section = .models }
        } label: {
            HStack(spacing: 6) {
                Text(studio.selectedModel?.title ?? String(localized: "Выберите модель"))
                    .font(.headline)
                if let model = studio.selectedModel {
                    Text(model.quantLabel)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Image(systemName: "chevron.down")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 6)
        }
        .menuIndicator(.hidden)
        .fixedSize()
        .help(studio.isRunning ? String(localized: "Модель нельзя сменить во время генерации") : String(localized: "Выбрать модель"))
    }

    private func subtitle(for model: InstalledModel) -> String {
        let peak = MemoryModel.peakGB(model.footprint)
        var parts = [model.quantLabel, "≈ \(Format.gb(peak))", MemoryModel.fit(peak: peak).label.lowercased()]
        if let rate = model.stepSeconds(sequence: 1) { parts.append(String(localized: "\(String(format: "%.1f", rate)) с/шаг")) }
        return parts.joined(separator: " · ")
    }
}

/// Mirror of the system sidebar toggle, used for the parameters panel on the right.
struct InspectorToggle: View {
    @Binding var shown: Bool

    var body: some View {
        Button {
            shown.toggle()   // the inspector column animates itself; an extra SwiftUI animation runs it twice
        } label: {
            Label(shown ? String(localized: "Скрыть параметры") : String(localized: "Показать параметры"), systemImage: "sidebar.right")
        }
        .help(shown ? String(localized: "Скрыть параметры (⌥⌘I)") : String(localized: "Показать параметры (⌥⌘I)"))
    }
}

// MARK: - Canvas

private struct CanvasView: View {
    @Environment(Studio.self) private var studio
    @Environment(AppModel.self) private var app

    /// Generating (and not looking at a finished image): skeleton / live preview under the loader.
    private var showsLive: Bool {
        studio.isRunning && studio.pinnedResult == nil && studio.phase != .finishing
    }

    private var finished: (image: NSImage, url: URL?)? {
        if let pinned = studio.pinnedResult, let image = ImageCache.image(pinned.url) {
            return (image, pinned.url)
        }
        if let result = studio.shownResult, let image = ImageCache.image(result.url) {
            return (image, result.url)
        }
        // Stopped by the user: keep the last thing that was on screen.
        return studio.livePreview.map { ($0, nil) }
    }

    var body: some View {
        ZStack {
            if showsLive {
                LiveCanvas()
                    .transition(.opacity)
            } else if let shown = finished {
                Image(nsImage: shown.image)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .shadow(color: .black.opacity(0.18), radius: 18, y: 8)
                    .padding(28)
                    .contextMenu { if let url = shown.url { ImageActions(url: url) } }
                    .draggable(shown.url ?? URL(fileURLWithPath: "/")) {
                        Image(nsImage: shown.image).resizable().frame(width: 96, height: 96)
                    }
                    .id(shown.url?.path ?? "preview")
                    .transition(.opacity)
            } else if studio.selectedModel == nil {
                EmptyStateView(
                    symbol: "shippingbox",
                    title: "Нет загруженных моделей",
                    message: "Скачайте модель из каталога — для 16 ГБ памяти рекомендуем Z-Image Turbo или FLUX.2 klein 4B.",
                    action: ("Открыть каталог", { app.section = .models }))
            } else {
                EmptyStateView(
                    symbol: "sparkles",
                    title: "Опишите изображение",
                    message: "Напишите промпт внизу и нажмите ⌘↩. Каждый шаг генерации появится здесь сразу, ещё до завершения.")
            }
        }
        // Keep the image clear of the floating status capsule while it is shown.
        .padding(.top, studio.isRunning || studio.lastError != nil ? 44 : 0)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .animation(.easeOut(duration: 0.2), value: showsLive)
        .animation(.easeOut(duration: 0.2), value: studio.isRunning)
        .overlay(alignment: .top) {
            VStack(spacing: 8) {
                if studio.isRunning { ProgressCapsule() }
                if let error = studio.lastError { ErrorCapsule(message: error) }
            }
            .padding(.top, 14)
            .padding(.horizontal, 20)
        }
    }
}

/// The image being generated: a skeleton in the final aspect ratio from the first moment,
/// filled by step previews as they arrive, with the standard loader and percent on top.
private struct LiveCanvas: View {
    @Environment(Studio.self) private var studio

    var body: some View {
        let size = studio.jobSize ?? CGSize(width: 1, height: 1)
        ZStack {
            if let preview = studio.livePreview {
                // Not final yet: softly blurred and veiled (darker in dark mode, lighter in light mode).
                Image(nsImage: preview)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fill)
                    .blur(radius: 4, opaque: true)
                    .overlay(Color(nsColor: .windowBackgroundColor).opacity(0.22))
                    .transition(.opacity)
            } else {
                Skeleton()
            }
            GenerationParticles()
                .allowsHitTesting(false)
        }
        .animation(.easeOut(duration: 0.25), value: studio.livePreview)
        .aspectRatio(size.width / max(1, size.height), contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .shadow(color: .black.opacity(0.18), radius: 18, y: 8)
        .overlay {
            LoaderWithPercent(percent: studio.imagePercent, size: .large)
                .padding(.horizontal, 18)
                .padding(.vertical, 14)
                .glassEffect(in: .rect(cornerRadius: 18))
        }
        .padding(28)
    }
}

/// Sparkles drifting upward and a slow light sweep — shown only while an image is being made.
private struct GenerationParticles: View {
    private struct Particle {
        let x: Double, speed: Double, size: Double, phase: Double, twinkle: Double, drift: Double
    }

    private let particles: [Particle] = {
        var rng = SystemRandomNumberGenerator()
        return (0..<34).map { _ in
            Particle(x: .random(in: 0...1, using: &rng), speed: .random(in: 0.035...0.11, using: &rng),
                     size: .random(in: 2.5...7, using: &rng), phase: .random(in: 0...1, using: &rng),
                     twinkle: .random(in: 1.2...3.2, using: &rng), drift: .random(in: -0.04...0.04, using: &rng))
        }
    }()
    private let start = Date()

    var body: some View {
        TimelineView(.animation) { timeline in
            let t = timeline.date.timeIntervalSince(start)
            Canvas { ctx, size in
                // Diagonal light sweep (top-left → bottom-right) every few seconds.
                ctx.fill(Path(CGRect(origin: .zero, size: size)),
                         with: diagonalSweep(t: t, period: 3.2, size: size, peak: 0.12))
                // Rising sparkles with twinkle.
                for p in particles {
                    let progress = (p.phase + t * p.speed).truncatingRemainder(dividingBy: 1)
                    let y = size.height * (1.05 - progress * 1.1)
                    let x = size.width * (p.x + sin(t * 0.7 + p.phase * 6) * 0.02 + p.drift * progress)
                    let fade = min(1, progress * 5) * min(1, (1 - progress) * 4)
                    let glow = 0.45 + 0.55 * (0.5 + 0.5 * sin(t * p.twinkle + p.phase * 10))
                    let r = p.size * (0.7 + 0.3 * glow)
                    var star = Path()
                    star.move(to: CGPoint(x: x, y: y - r))
                    star.addQuadCurve(to: CGPoint(x: x + r, y: y), control: CGPoint(x: x, y: y))
                    star.addQuadCurve(to: CGPoint(x: x, y: y + r), control: CGPoint(x: x, y: y))
                    star.addQuadCurve(to: CGPoint(x: x - r, y: y), control: CGPoint(x: x, y: y))
                    star.addQuadCurve(to: CGPoint(x: x, y: y - r), control: CGPoint(x: x, y: y))
                    var layer = ctx
                    layer.opacity = fade * glow * 0.9
                    layer.addFilter(.shadow(color: Color.accentColor.opacity(0.8), radius: r * 1.6))
                    layer.fill(star, with: .color(.white))
                }
            }
        }
    }
}

/// Standard system spinner with only the percentage under it.
struct LoaderWithPercent: View {
    let percent: Int
    var size: ControlSize = .regular

    var body: some View {
        VStack(spacing: size == .large ? 8 : 2) {
            ProgressView().controlSize(size)
            Text("\(percent)%")
                .font(size == .large ? .callout.weight(.medium) : .system(size: 9, weight: .semibold))
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .contentTransition(.numericText())
                .animation(.snappy, value: percent)
        }
    }
}

/// A diagonal band of light whose position along the top-left → bottom-right axis moves with time.
func diagonalSweep(t: Double, period: Double, size: CGSize, peak: Double) -> GraphicsContext.Shading {
    let p = (t / period).truncatingRemainder(dividingBy: 1) * 1.6 - 0.3   // -0.3 … 1.3
    let w = 0.16
    func stop(_ x: Double, _ a: Double) -> Gradient.Stop { .init(color: .white.opacity(a), location: min(1, max(0, x))) }
    let stops = [stop(0, 0), stop(p - w, 0), stop(p, peak), stop(p + w, 0), stop(1, 0)]
    return .linearGradient(Gradient(stops: stops), startPoint: .zero, endPoint: CGPoint(x: size.width, y: size.height))
}

/// Placeholder with a soft diagonal sheen.
struct Skeleton: View {
    private let start = Date()

    var body: some View {
        TimelineView(.animation) { timeline in
            Canvas { ctx, size in
                ctx.fill(Path(CGRect(origin: .zero, size: size)),
                         with: diagonalSweep(t: timeline.date.timeIntervalSince(start), period: 1.6, size: size, peak: 0.08))
            }
            .background(.quaternary)
        }
    }
}

private struct ProgressCapsule: View {
    @Environment(Studio.self) private var studio

    var body: some View {
        HStack(spacing: 12) {
            if studio.phase == .denoising {
                Text("Шаг \(studio.runStep) из \(studio.runTotal)").monospacedDigit()
            } else {
                ProgressView().controlSize(.small)
                Text(studio.phase.title)
            }
            if studio.imageCount > 1 {
                Divider().frame(height: 14)
                Text("Изображение \(studio.imageIndex + 1)/\(studio.imageCount)").monospacedDigit()
            }
            if let eta = studio.etaSeconds {
                Divider().frame(height: 14)
                Text(eta < 1.5 ? String(localized: "почти готово") : "≈ \(Format.duration(eta.rounded(.up)))")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .contentTransition(.numericText(countsDown: true))
                    .animation(.snappy, value: Int(eta.rounded(.up)))
                    .help("Оставшееся время: учитывает загрузку модели, текущий шаг, оставшиеся шаги, декодирование и остальные картинки серии")
            }
            Button {
                studio.cancel()
            } label: {
                Image(systemName: "stop.fill")
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("Остановить (⌘.)")
        }
        .font(.callout.weight(.medium))
        .padding(.horizontal, 16)
        .padding(.vertical, 9)
        .glassEffect(in: .capsule)
        .transition(.move(edge: .top).combined(with: .opacity))
    }
}

private struct ErrorCapsule: View {
    @Environment(Studio.self) private var studio
    let message: String

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            Text(message)
                .font(.callout)
                .lineLimit(4)
                .textSelection(.enabled)
            Spacer(minLength: 0)
            if !studio.log.isEmpty {
                Button("Журнал") { studio.showLog = true }.buttonStyle(.link)
            }
            Button { studio.clearError() } label: { Image(systemName: "xmark") }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .frame(maxWidth: 620)
        .glassEffect(in: .rect(cornerRadius: 16))
    }
}

struct ImageActions: View {
    @Environment(Studio.self) private var studio
    let url: URL

    var body: some View {
        Button("Показать в Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
        Button("Открыть") { NSWorkspace.shared.open(url) }
        Button("Скопировать") {
            if let image = ImageCache.image(url) {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.writeObjects([image])
            }
        }
        Divider()
        Button("Прикрепить к запросу") { studio.addImages([url]) }
            .disabled(studio.maxImages == 0)
    }
}

// MARK: - Result strip

/// Finished images of the current job plus one live slot for the image being made.
private struct StepStrip: View {
    @Environment(Studio.self) private var studio

    var body: some View {
        if studio.showsProgressSlot || !studio.results.isEmpty {
            GeometryReader { geometry in
                ScrollViewReader { proxy in
                    ScrollView(.horizontal) {
                        HStack(spacing: 8) {
                            ForEach(studio.results) { item in
                                if let image = ImageCache.image(item.url) {
                                    Thumb(image: image, selected: isSelected(item))
                                        .onTapGesture { open(item) }
                                        .contextMenu { ImageActions(url: item.url) }
                                        .id(item.url.path)
                                        .transition(.scale(scale: 0.8).combined(with: .opacity))
                                }
                            }
                            if studio.showsProgressSlot {
                                // The image being made now: live preview under the loader.
                                ProgressSlot(preview: studio.livePreview, percent: studio.imagePercent,
                                             selected: studio.pinnedResult == nil)
                                    .onTapGesture { studio.pinnedResult = nil }
                                    .id("progress")
                                    .transition(.scale(scale: 0.8).combined(with: .opacity))
                                // The rest of the batch, created up front so the whole series is visible.
                                ForEach(studio.results.count + 1 ..< max(studio.results.count + 1, studio.imageCount), id: \.self) { index in
                                    ProgressSlot(preview: nil, percent: 0, selected: false)
                                        .id("queued-\(index)")
                                        .help("В очереди")
                                        .transition(.scale(scale: 0.8).combined(with: .opacity))
                                }
                            }
                        }
                        .padding(.horizontal, 18)
                        .padding(.vertical, 6)
                        .animation(.snappy(duration: 0.2), value: studio.results.count)
                        .animation(.snappy(duration: 0.2), value: studio.showsProgressSlot)
                        // Centered while it fits; scrolls once it is wider than the canvas.
                        .frame(minWidth: geometry.size.width)
                    }
                    .scrollIndicators(.never)
                    .onChange(of: studio.results.count) {
                        withAnimation { proxy.scrollTo(studio.showsProgressSlot ? "progress" : (studio.results.last?.url.path ?? ""), anchor: .trailing) }
                    }
                }
            }
            .frame(height: 64)
        }
    }

    private func isSelected(_ item: GalleryItem) -> Bool {
        studio.isRunning ? studio.pinnedResult == item : studio.shownResult == item
    }

    private func open(_ item: GalleryItem) {
        if studio.isRunning {
            studio.pinnedResult = studio.pinnedResult == item ? nil : item
        } else {
            studio.pinnedResult = nil
            studio.shownResult = item
        }
    }
}

/// The image being generated: the live preview, softly blurred and veiled, under a loader.
private struct ProgressSlot: View {
    let preview: NSImage?
    let percent: Int
    let selected: Bool

    var body: some View {
        ZStack {
            if let preview {
                Image(nsImage: preview)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .blur(radius: 2.5)
                    .overlay(Color(nsColor: .windowBackgroundColor).opacity(0.4))
                    .transition(.opacity)
            } else {
                Skeleton()
            }
            LoaderWithPercent(percent: percent, size: .mini)
        }
        .animation(.easeOut(duration: 0.25), value: preview)
        .frame(width: 52, height: 52)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(selected ? Color.accentColor : .clear, lineWidth: 2)
        }
        .contentShape(Rectangle())
    }
}

private struct Thumb: View {
    let image: NSImage
    let selected: Bool

    var body: some View {
        Image(nsImage: image)
            .resizable()
            .aspectRatio(contentMode: .fill)
            .frame(width: 52, height: 52)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(selected ? Color.accentColor : .clear, lineWidth: 2)
            }
            .contentShape(Rectangle())
    }
}

// MARK: - Prompt bar

private struct PromptBar: View {
    @Environment(Studio.self) private var studio

    var body: some View {
        @Bindable var studio = studio
        VStack(alignment: .leading, spacing: 10) {
            if !studio.inputImages.isEmpty {
                AttachmentStrip()
                    .transition(.scale(scale: 0.85, anchor: .bottomLeading).combined(with: .opacity))
            }
            HStack(alignment: .bottom, spacing: 10) {
                AttachButton()
                TextField("Опишите изображение…", text: $studio.settings.prompt, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(.system(size: 14))
                    .lineLimit(1...7)
                    .padding(.vertical, 7)
                if studio.isRunning {
                    Button { studio.cancel() } label: {
                        Image(systemName: "stop.fill").frame(width: 22, height: 22)
                    }
                    .buttonStyle(.glass)
                    .controlSize(.large)
                    .help("Остановить (⌘.)")
                } else {
                    Button { studio.generate() } label: {
                        Image(systemName: "arrow.up").font(.body.weight(.semibold)).frame(width: 22, height: 22)
                    }
                    .buttonStyle(.glassProminent)
                    .controlSize(.large)
                    .disabled(studio.settings.prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || studio.selectedModel == nil)
                    .help("Сгенерировать (⌘↩)")
                }
            }
        }
        .padding(.leading, 10)
        .padding(.trailing, 8)
        .padding(.top, studio.inputImages.isEmpty ? 8 : 10)
        .padding(.bottom, 8)
        .glassEffect(in: .rect(cornerRadius: 22))
        .animation(.snappy(duration: 0.25), value: studio.inputImages.count)
        .frame(maxWidth: 820)
        .frame(maxWidth: .infinity)

    }
}

/// Attached images, shown above the text like attachments in modern AI chats.
private struct AttachmentStrip: View {
    @Environment(Studio.self) private var studio

    var body: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 8) {
                ForEach(Array(studio.inputImages.enumerated()), id: \.offset) { index, image in
                    AttachmentThumb(image: image) { studio.removeImage(at: index) }
                }
            }
            .padding(.leading, 2)
            .padding(.vertical, 1)
        }
        .scrollIndicators(.never)
    }
}

private struct AttachmentThumb: View {
    let image: NSImage
    let remove: () -> Void
    @State private var hovering = false

    var body: some View {
        Image(nsImage: image)
            .resizable()
            .aspectRatio(contentMode: .fill)
            .frame(width: 76, height: 76)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(.white.opacity(0.12))
            )
            .overlay(alignment: .topTrailing) {
                Button(action: remove) {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .bold))
                        .frame(width: 20, height: 20)
                        .background(.black.opacity(0.65), in: Circle())
                        .foregroundStyle(.white)
                }
                .buttonStyle(.plain)
                .padding(5)
                .opacity(hovering ? 1 : 0.85)
                .help("Убрать изображение")
                .accessibilityLabel(Text("Убрать изображение"))
            }
            .onHover { hovering = $0 }
            .transition(.scale(scale: 0.85).combined(with: .opacity))
    }
}

private struct AttachButton: View {
    @Environment(Studio.self) private var studio

    var body: some View {
        Button { pick() } label: {
            Image(systemName: "plus")
                .font(.system(size: 15, weight: .medium))
                .frame(width: 34, height: 34)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .disabled(studio.maxImages == 0 || (studio.maxImages > 1 && !studio.canAttachMore))
        .help(help)
    }

    private var help: String {
        let limit = studio.maxImages
        if limit == 0 { return String(localized: "Эта модель рисует только по тексту") }
        if limit == 1 {
            return studio.inputImages.isEmpty
                ? String(localized: "Прикрепить изображение — или перетащите его на холст")
                : String(localized: "Заменить изображение")
        }
        if !studio.canAttachMore { return String(localized: "Прикреплено максимум для этой модели: \(limit)") }
        return String(localized: "Прикрепить изображения (до \(limit)) — или перетащите их на холст")
    }

    private func pick() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = studio.maxImages > 1
        if panel.runModal() == .OK { studio.addImages(panel.urls) }
    }
}
