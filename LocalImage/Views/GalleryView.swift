import SwiftUI

struct GalleryView: View {
    @Environment(Studio.self) private var studio
    @Environment(AppModel.self) private var app
    @State private var selection: GalleryItem?
    @State private var search = ""

    private var items: [GalleryItem] {
        guard !search.isEmpty else { return studio.gallery }
        return studio.gallery.filter { $0.record?.prompt.localizedCaseInsensitiveContains(search) == true }
    }

    var body: some View {
        Group {
            if studio.gallery.isEmpty {
                EmptyStateView(symbol: "photo.on.rectangle.angled", title: "Здесь появятся ваши изображения",
                               message: "Все результаты сохраняются в \(Paths.outputs.path.replacingOccurrences(of: NSHomeDirectory(), with: "~")) вместе с параметрами генерации.")
            } else {
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 170, maximum: 260), spacing: 10)], spacing: 10) {
                        ForEach(items) { item in
                            GalleryTile(item: item)
                                .onTapGesture { selection = item }
                                .contextMenu {
                                    ImageActions(url: item.url)
                                    if let record = item.record {
                                        Button("Повторить параметры") { reuse(record, seed: true) }
                                    }
                                    Divider()
                                    Button("В корзину", role: .destructive) { studio.delete(item) }
                                }
                        }
                    }
                    .padding(16)
                }
            }
        }
        .navigationTitle("Галерея")
        .searchable(text: $search, prompt: "Поиск по промпту")
        .toolbar {
            ToolbarItem {
                Button { NSWorkspace.shared.open(Paths.ensure(Paths.outputs)) } label: {
                    Label("Открыть папку", systemImage: "folder")
                }
            }
        }
        .sheet(item: $selection) { item in
            GalleryDetail(item: item) { record, seed in
                reuse(record, seed: seed)
                selection = nil
            }
        }
        .onAppear { studio.loadGallery() }
    }

    private func reuse(_ record: GenerationRecord, seed: Bool) {
        studio.reuse(record, includeSeed: seed)
        app.section = .studio
    }
}

private struct GalleryTile: View {
    let item: GalleryItem

    var body: some View {
        Color.clear
            .aspectRatio(1, contentMode: .fit)
            .overlay {
                if let image = Thumbnails.image(item.url) {
                    Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
                } else {
                    Rectangle().fill(.quaternary)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .contentShape(Rectangle())
            .help(item.record?.prompt ?? item.url.lastPathComponent)
            .draggable(item.url)
    }
}

/// Small cached thumbnails so the gallery stays smooth with thousands of images.
enum Thumbnails {
    private static let cache = NSCache<NSURL, NSImage>()

    static func image(_ url: URL) -> NSImage? {
        if let hit = cache.object(forKey: url as NSURL) { return hit }
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                  kCGImageSourceCreateThumbnailFromImageAlways: true,
                  kCGImageSourceThumbnailMaxPixelSize: 520,
                  kCGImageSourceCreateThumbnailWithTransform: true,
              ] as CFDictionary)
        else { return nil }
        let image = NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
        cache.setObject(image, forKey: url as NSURL)
        return image
    }
}

private struct GalleryDetail: View {
    let item: GalleryItem
    var reuse: (GenerationRecord, Bool) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        HStack(spacing: 0) {
            if let image = ImageCache.image(item.url) {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding(20)
                    .contextMenu { ImageActions(url: item.url) }
                    .draggable(item.url)
            }
            Divider()
            VStack(alignment: .leading, spacing: 14) {
                if let record = item.record {
                    Text(record.prompt)
                        .font(.callout)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 6) {
                        row("Модель", "\(record.modelTitle) · \(record.quant)")
                        row("Размер", "\(record.width) × \(record.height)")
                        row("Шаги", "\(record.steps)")
                        row("Seed", "\(record.seed)")
                        if let guidance = record.guidance { row("Guidance", String(format: "%.1f", guidance)) }
                        if let strength = record.strength { row("Исходник", String(format: "%.2f", strength)) }
                        if let seconds = record.seconds { row("Время", Format.duration(seconds)) }
                        row("Дата", record.date.formatted(date: .abbreviated, time: .shortened))
                    }
                    .font(.caption)
                    Spacer()
                    Button("Повторить с тем же seed") { reuse(record, true) }
                        .buttonStyle(.glassProminent)
                    Button("Параметры с новым seed") { reuse(record, false) }
                        .buttonStyle(.glass)
                } else {
                    Text(item.url.lastPathComponent).font(.caption)
                    Spacer()
                }
                HStack {
                    Button("В Finder") { NSWorkspace.shared.activateFileViewerSelecting([item.url]) }
                    Spacer()
                    Button("Закрыть") { dismiss() }.keyboardShortcut(.cancelAction)
                }
            }
            .padding(20)
            .frame(width: 280)
        }
        .frame(minWidth: 900, minHeight: 620)
    }

    private func row(_ title: LocalizedStringResource, _ value: String) -> some View {
        GridRow {
            Text(title).foregroundStyle(.secondary)
            Text(value).textSelection(.enabled).monospacedDigit()
        }
    }
}
