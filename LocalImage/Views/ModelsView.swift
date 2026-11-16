import SwiftUI

/// What the download sheet is about to fetch.
enum DownloadTarget: Identifiable, Hashable {
    case catalog(CatalogEntry)
    case repo(String)

    var id: String {
        switch self {
        case .catalog(let entry): "c:" + entry.id
        case .repo(let repo): "r:" + repo
        }
    }
}

struct ModelsView: View {
    enum Tab: String, CaseIterable {
        case installed = "Мои модели", catalog = "Каталог", hub = "Hugging Face"
        var title: String {
            switch self {
            case .installed: String(localized: "Мои модели")
            case .catalog: String(localized: "Каталог")
            case .hub: "Hugging Face"
            }
        }
    }

    @Environment(ModelStore.self) private var store
    @State private var tab: Tab = .catalog
    @State private var target: DownloadTarget?
    @State private var didPickInitialTab = false

    var body: some View {
        VStack(spacing: 0) {
            HardwareStrip()
                .padding(.horizontal, 20)
                .padding(.top, 12)
                .padding(.bottom, 10)
            Divider()
            Group {
                switch tab {
                case .installed: InstalledList(onBrowse: { tab = .catalog })
                case .catalog: CatalogGrid(target: $target)
                case .hub: HubSearch(target: $target)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .navigationTitle("Модели")
        .toolbar {
            ToolbarItem(placement: .principal) {
                Picker("Раздел", selection: $tab) {
                    ForEach(Tab.allCases, id: \.self) { tab in
                        Text(tab.title).tag(tab)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 360)
            }
        }
        .sheet(item: $target) { target in
            DownloadSheet(target: target) { tab = .installed }
        }
        .onAppear {
            guard !didPickInitialTab else { return }
            didPickInitialTab = true
            tab = store.models.isEmpty ? .catalog : .installed
        }
    }
}

// MARK: - Hardware

private struct HardwareStrip: View {
    @Environment(ModelStore.self) private var store

    var body: some View {
        let hw = Hardware.current
        let free = Paths.freeDiskBytes(at: Paths.models)
        HStack(spacing: 18) {
            Label(hw.chip.replacingOccurrences(of: "Apple ", with: ""), systemImage: "cpu")
            Label("\(Int(hw.memoryGB.rounded())) ГБ памяти", systemImage: "memorychip")
            Label("GPU \(Format.gb(hw.budgetGB))", systemImage: "square.stack.3d.up")
            Label("\(Format.bytes(free)) свободно", systemImage: "internaldrive")
            Spacer()
            InfoButton(verbatim: hardwareAdvice(hw), title: "Подсказки по железу")
        }
        .font(.callout)
        .foregroundStyle(.secondary)
        .labelStyle(.titleAndIcon)
    }

    private func hardwareAdvice(_ hw: Hardware) -> String {
        var lines: [String] = []
        lines.append(String(localized: "На этом Mac GPU может держать ≈ \(Format.gb(hw.budgetGB)) без подкачки — это главный ориентир при выборе модели и её сборки."))
        if hw.memoryGB <= 18 {
            lines.append(String(localized: "16 ГБ: лучший выбор — Z-Image Turbo, FLUX.2 klein 4B, FLUX 3 klein и Qwen-Image 2.1 Turbo. Берите 8-битную сборку, если она помещается, иначе 4-битную. Модели на 12–20 млрд параметров работают только в 4 битах и на умеренных разрешениях."))
        } else if hw.memoryGB <= 36 {
            lines.append(String(localized: "24–36 ГБ: комфортно работают все модели до 12 млрд в 8 битах; Qwen-Image 20B — в 4–6 битах."))
        } else {
            lines.append(String(localized: "Памяти достаточно для любых моделей в 8-битных сборках и даже в BF16."))
        }
        if hw.prefersFloat16 {
            lines.append(String(localized: "Чип \(hw.chip.replacingOccurrences(of: "Apple ", with: "")) медленно работает с bfloat16, поэтому приложение автоматически считает в float16 там, где модель это поддерживает (≈ +25% скорости)."))
        }
        return lines.joined(separator: "\n\n")
    }
}

// MARK: - Installed

private struct InstalledList: View {
    @Environment(ModelStore.self) private var store
    var onBrowse: () -> Void

    var body: some View {
        if store.models.isEmpty {
            EmptyStateView(symbol: "shippingbox", title: "Моделей пока нет",
                           message: "Выберите модель в каталоге или найдите любую совместимую на Hugging Face.",
                           action: ("Открыть каталог", onBrowse))
        } else {
            List {
                ForEach(store.models) { model in
                    InstalledRow(model: model)
                        .listRowSeparator(.hidden)
                }
            }
            .listStyle(.inset)
            .scrollContentBackground(.hidden)
        }
    }
}

private struct InstalledRow: View {
    @Environment(ModelStore.self) private var store
    @Environment(Studio.self) private var studio
    @Environment(AppModel.self) private var app
    @Environment(Engine.self) private var engine
    @Environment(HFMeta.self) private var meta
    let model: InstalledModel
    @State private var confirmDelete = false
    @State private var hovering = false
    /// Read so the time badge follows the load limit in Settings.
    @AppStorage(HardwareLoad.percentKey) private var loadPercent = 100

    var body: some View {
        let card = meta.card(for: model.repo)
        let caps = engine.caps(for: model.family)
        HStack(alignment: .center, spacing: 12) {
            HFAvatar(owner: String(model.repo.split(separator: "/").first ?? ""), size: 38)
                .opacity(model.isReady ? 1 : 0.55)
            VStack(alignment: .leading, spacing: 2) {
                Text(model.title)
                    .font(.system(size: 15, weight: .semibold))
                    .lineLimit(1)
                Text(model.repo)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .textSelection(.enabled)
            }
            .layoutPriority(1)
            Spacer(minLength: 12)
            if model.isReady {
                ModelBadges(family: model.family, caps: caps,
                            prebuiltBits: model.prebuilt ? .some(model.prebuiltBits) : nil,
                            gated: card?.gated ?? false,
                            localQuant: model.prebuilt ? nil : model.quantLabel)
                HStack(spacing: 8) {
                    Text(model.sizeOnDisk.map(Format.bytes) ?? "")
                        .help("Занимает на диске")
                        .frame(width: 58, alignment: .trailing)
                    Label(Format.count(card?.downloads ?? 0), systemImage: "arrow.down.circle")
                        .help("Загрузок за последний месяц на Hugging Face")
                        .frame(width: 66, alignment: .trailing)
                    Label(Format.count(card?.likes ?? 0), systemImage: "heart")
                        .help("Лайков на Hugging Face")
                        .frame(width: 54, alignment: .trailing)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .lineLimit(1)
                .redacted(reason: card == nil ? .placeholder : [])
            }
            status
                .fixedSize(horizontal: model.isReady, vertical: false)
                .frame(maxWidth: model.isReady ? nil : 360, alignment: .trailing)
            Menu {
                if model.isReady {
                    Button("Использовать в студии") {
                        studio.selectModel(model.id)
                        app.section = .studio
                    }
                }
                Button("Показать в Finder") { NSWorkspace.shared.activateFileViewerSelecting([model.root]) }
                Button("Открыть на Hugging Face") {
                    NSWorkspace.shared.open(URL(string: "https://huggingface.co/\(model.repo)")!)
                }
                Divider()
                Button("Удалить…", role: .destructive) { confirmDelete = true }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(hovering ? Color.primary.opacity(0.05) : .clear, in: RoundedRectangle(cornerRadius: 10))
        .onHover { hovering = $0 }
        .confirmationDialog("Удалить «\(model.title)»?", isPresented: $confirmDelete) {
            Button("Удалить с диска", role: .destructive) {
                if studio.settings.modelID == model.id { studio.settings.modelID = nil }
                store.remove(model.id)
                if studio.settings.modelID == nil { studio.settings.modelID = store.readyModels.first?.id }
            }
        } message: {
            Text("Файлы модели (\(model.sizeOnDisk.map(Format.bytes) ?? Format.bytes(model.totalBytes))) будут удалены. Скачать её можно снова в любой момент.")
        }
    }

    private func timeHelp(_ time: TimeEstimate) -> LocalizedStringResource {
        let load = Format.duration(time.load), denoise = Format.duration(time.denoise), decode = Format.duration(time.decode)
        let perStep = String(format: "%.1f", time.perStep)
        if HardwareLoad.percent < 100 {
            return "Стандартное изображение (1 МП, \(time.steps) шагов) на этом Mac при нагрузке \(HardwareLoad.percent)%: загрузка и промпт ≈ \(load), шаги ≈ \(denoise) (\(perStep) с на шаг), декодирование ≈ \(decode). Оценка по замерам прошлых генераций."
        }
        return "Стандартное изображение (1 МП, \(time.steps) шагов) на этом Mac: загрузка и промпт ≈ \(load), шаги ≈ \(denoise) (\(perStep) с на шаг), декодирование ≈ \(decode). Оценка по замерам прошлых генераций."
    }

    @ViewBuilder
    private var status: some View {
        let progress = store.progress[model.id]
        switch model.status {
        case .ready:
            HStack(spacing: 12) {
                // One standard image (1 MP) at the model's default steps, from the phases measured on this Mac.
                let steps = engine.caps(for: model.family)?.defaultSteps ?? 20
                if let time = model.timeEstimate(steps: steps, megapixels: Quality.standard.megapixels) {
                    HintIcon(symbol: "timer", help: timeHelp(time), text: "≈ " + Format.duration(time.total))
                }
                let peak = MemoryModel.peakGB(model.footprint)
                FitBadge(fit: MemoryModel.fit(peak: peak), peak: peak)
            }
        case .downloading, .queued:
            VStack(alignment: .trailing, spacing: 4) {
                HStack(spacing: 8) {
                    ProgressView(value: progress?.fraction ?? 0)
                        .frame(width: 180)
                    controlButton("pause.fill", "Пауза") { store.pause(model.id) }
                }
                Text(downloadCaption(progress))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .lineLimit(1)
            }
        case .paused:
            HStack(spacing: 8) {
                Text("Пауза · \(Int((progress?.fraction ?? 0) * 100))%")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                controlButton("play.fill", "Продолжить") { store.start(model.id) }
            }
        case .quantizing:
            VStack(alignment: .trailing, spacing: 4) {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Оптимизация").font(.callout)
                    InfoButton("Скачанные веса квантуются под выбранное сочетание (текст \(Format.bits(model.textBits)), изображение \(Format.bits(model.imageBits))) и сохраняются в формате MLX. Это делается один раз; затем модель грузится за секунды.")
                }
                if let note = progress?.note, !note.isEmpty {
                    Text(note).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                }
            }
        case .failed:
            HStack(spacing: 8) {
                Text(model.error ?? String(localized: "Ошибка"))
                    .font(.caption)
                    .foregroundStyle(.red)
                    .lineLimit(2)
                    .multilineTextAlignment(.trailing)
                    .help(model.error ?? "")
                controlButton("arrow.clockwise", "Повторить") { store.start(model.id) }
            }
        }
    }

    private func downloadCaption(_ progress: TransferProgress?) -> String {
        guard let progress, progress.total > 0 else { return "В очереди" }
        if !progress.note.isEmpty { return progress.note }
        var parts = [String(localized: "\(Format.bytes(progress.done)) из \(Format.bytes(progress.total))")]
        if progress.bytesPerSecond > 1 {
            parts.append(Format.speed(progress.bytesPerSecond))
            parts.append(Format.duration(progress.eta))
        }
        return parts.joined(separator: " · ")
    }

    private func controlButton(_ symbol: String, _ help: LocalizedStringResource, action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: symbol) }
            .buttonStyle(.borderless)
            .help(Text(help))
    }
}

// MARK: - Shared bits

/// Author avatar from Hugging Face, with an initials fallback.
struct HFAvatar: View {
    @Environment(HFMeta.self) private var meta
    let owner: String
    var size: CGFloat = 36

    var body: some View {
        let url = meta.avatar(for: owner)
        ZStack {
            if let url {
                AsyncImage(url: url) { phase in
                    if let image = phase.image { image.resizable().aspectRatio(contentMode: .fill) } else { Skeleton() }
                }
            } else {
                Skeleton()   // still resolving, or the Hub has no avatar
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: size * 0.24, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: size * 0.24, style: .continuous).strokeBorder(.white.opacity(0.08)))
    }
}

/// Small icon whose meaning appears on hover.
struct HintIcon: View {
    let symbol: String
    let help: LocalizedStringResource
    var tint: Color = .secondary
    var text: String? = nil

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: symbol)
            if let text { Text(text).monospacedDigit() }
        }
        .font(.system(size: 12, weight: .medium))
        .foregroundStyle(tint)
        .padding(.horizontal, text == nil ? 5 : 7)
        .padding(.vertical, 4)
        .background(tint.opacity(0.10), in: Capsule())
        .lineLimit(1)
        .fixedSize()
        .help(help)
    }
}

/// Facts shared by search rows and catalog cards, derived from repo metadata + engine capabilities.
struct ModelBadges: View {
    let family: String?
    let caps: FamilyCaps?
    let prebuiltBits: Int??
    let gated: Bool
    var localQuant: String? = nil

    var body: some View {
        HStack(spacing: 5) {
            if let localQuant {
                HintIcon(symbol: "cpu", help: "Квантована на этом Mac из оригинала (текстовый энкодер · модель изображения)", tint: .green, text: localQuant)
            }
            if let bits = prebuiltBits {
                HintIcon(symbol: "cpu", help: "Готовая MLX-сборка: уже квантована, скачивается меньше и работает сразу", tint: .green,
                         text: Format.bits(bits))
            }
            if let family {
                HintIcon(symbol: "checkmark.seal.fill", help: "Совместима с движком: архитектура «\(Catalog.title(for: family))»", tint: .accentColor)
            } else {
                HintIcon(symbol: "questionmark.diamond", help: "Архитектура не распознана — выбрать её можно вручную при скачивании", tint: .orange)
            }
            if let references = caps?.references, references > 0 {
                HintIcon(symbol: "photo.stack", help: "Редактирует по прикреплённым изображениям: до \(references) шт.")
            }
            if caps?.img2img == true {
                HintIcon(symbol: "photo.on.rectangle.angled", help: "Поддерживает img2img: генерация по исходному изображению")
            }
            if caps?.supportsGuidance == true {
                HintIcon(symbol: "dial.medium", help: "Поддерживает guidance (CFG): можно задавать строгость следования промпту")
            }
            if caps?.usesNegativePrompt == true {
                HintIcon(symbol: "minus.circle", help: "Учитывает негативный промпт")
            }
            if caps?.computePrecision == true && Hardware.current.prefersFloat16 {
                HintIcon(symbol: "bolt.fill", help: "Ускорение float16 на этом Mac (M1/M2)", tint: .yellow)
            }
            if gated {
                HintIcon(symbol: "lock.fill", help: "Закрытая модель: нужно принять лицензию на Hugging Face и указать токен", tint: .orange)
            }
        }
    }
}

// MARK: - Catalog

private struct CatalogGrid: View {
    @Environment(ModelStore.self) private var store
    @Environment(HFMeta.self) private var meta
    @Binding var target: DownloadTarget?

    /// Only models that can be downloaded without accepting a license: ready MLX builds are open even when
    /// the original repo is gated. The live Hub flag wins over the built-in one.
    private var openEntries: [CatalogEntry] {
        Catalog.entries.filter { !$0.prebuilt.isEmpty || !(meta.cards[$0.originalRepo]?.gated ?? $0.gated) }
    }

    var body: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 330, maximum: 460), spacing: 16)], spacing: 16) {
                ForEach(openEntries) { entry in
                    CatalogCard(entry: entry, installed: store.models.contains { $0.family == entry.family }) {
                        target = .catalog(entry)
                    }
                }
            }
            .padding(20)
        }
    }
}

/// Everything shown here comes from the Hub (model card, metadata, avatar) — except the
/// memory fit, which is computed for this Mac.
private struct CatalogCard: View {
    @Environment(HFMeta.self) private var meta
    @Environment(Engine.self) private var engine
    let entry: CatalogEntry
    let installed: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        let repo = entry.originalRepo
        let owner = String(repo.split(separator: "/").first ?? "")
        let name = String(repo.split(separator: "/").last ?? "")
        let card = meta.card(for: repo)
        let best = entry.prebuilt
            .map { ($0, MemoryModel.peakGB($0.footprint)) }
            .filter { MemoryModel.fit(peak: $0.1) == .comfortable }
            .last ?? entry.prebuilt.first.map { ($0, MemoryModel.peakGB($0.footprint)) }
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center, spacing: 12) {
                HFAvatar(owner: owner, size: 42)
                VStack(alignment: .leading, spacing: 2) {
                    Text(name)
                        .font(.system(size: 17, weight: .semibold))
                        .lineLimit(1)
                    Text(repo)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                if installed {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                        .help("Уже скачана")
                }
            }
            Group {
                if let summary = card?.summary {
                    Text(summary)
                } else if card != nil {
                    Text("Описание в карточке модели не найдено.").foregroundStyle(.tertiary)
                } else {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(0..<3, id: \.self) { i in
                            RoundedRectangle(cornerRadius: 3).fill(.quaternary).frame(height: 9)
                                .frame(maxWidth: i == 2 ? 180 : .infinity, alignment: .leading)
                        }
                    }
                }
            }
            .font(.callout)
            .foregroundStyle(.secondary)
            .lineLimit(3, reservesSpace: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .help(card?.summary ?? "")

            HStack(spacing: 6) {
                if let params = ParamFormat.billions(card?.parameters) {
                    HintIcon(symbol: "cube", help: "Параметров в репозитории (по метаданным safetensors на Hugging Face)", text: params)
                }
                if let license = card?.license {
                    HintIcon(symbol: "doc.text", help: "Лицензия из карточки модели", text: license)
                }
                if let downloads = card?.downloads {
                    HintIcon(symbol: "arrow.down.circle", help: "Загрузок за последний месяц на Hugging Face", text: Format.count(downloads))
                }
                if let likes = card?.likes {
                    HintIcon(symbol: "heart", help: "Лайков на Hugging Face", text: Format.count(likes))
                }
                Spacer(minLength: 0)
            }
            Divider().opacity(0.5)
            HStack(spacing: 8) {
                ModelBadges(family: entry.family, caps: engine.caps(for: entry.family), prebuiltBits: nil, gated: entry.prebuilt.isEmpty && (card?.gated ?? entry.gated))
                Spacer(minLength: 4)
                if let best {
                    FitBadge(fit: MemoryModel.fit(peak: best.1), peak: best.1)
                        .help("Лучшая готовая сборка для этого Mac: \(Format.bits(best.0.bits))")
                }
                Button(installed ? String(localized: "Ещё вариант") : String(localized: "Скачать"), action: action)
                    .buttonStyle(.glassProminent)
                    .controlSize(.regular)
            }
        }
        .padding(16)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(.white.opacity(hovering ? 0.14 : 0.06)))
        .scaleEffect(hovering ? 1.01 : 1)
        .animation(.snappy(duration: 0.18), value: hovering)
        .onHover { hovering = $0 }
    }
}

// MARK: - Hugging Face search

enum HubSort: String, CaseIterable, Identifiable {
    case trending = "trendingScore", downloads, likes, updated = "lastModified"
    var id: String { rawValue }
    var title: String {
        switch self {
        case .trending: String(localized: "В тренде")
        case .downloads: String(localized: "Популярные")
        case .likes: String(localized: "Любимые")
        case .updated: String(localized: "Недавно обновлённые")
        }
    }
    var symbol: String {
        switch self {
        case .trending: "flame"
        case .downloads: "arrow.down.circle"
        case .likes: "heart"
        case .updated: "clock"
        }
    }
}

private struct HubSearch: View {
    @Environment(Engine.self) private var engine
    @Binding var target: DownloadTarget?
    @State private var query = ""
    @State private var results: [HFModelSummary] = []
    @State private var loading = false
    @State private var error: String?
    @State private var searchTask: Task<Void, Never>?
    @AppStorage("hub.sort") private var sort: HubSort = .trending
    @AppStorage("hub.family") private var family = ""
    @AppStorage("hub.bits") private var bits = 0          // 0 = any
    @AppStorage("hub.onlySupported") private var onlySupported = true
    @AppStorage("hub.openOnly") private var openOnly = false

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 10) {
                HStack(spacing: 10) {
                    HStack {
                        Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                        TextField("Поиск моделей или org/repo", text: $query)
                            .textFieldStyle(.plain)
                            .onSubmit { openOrSearch() }
                        if loading { ProgressView().controlSize(.small) }
                        if !query.isEmpty {
                            Button { query = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary) }
                                .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .glassEffect(in: .capsule)
                    InfoButton("Поиск готовых MLX-сборок mflux по всему Hugging Face, включая сборки дообученных моделей. Модели из каталога находятся и по имени оригинала. Можно ввести точное имя «org/repo» и нажать ↩.\n\nСовместимыми считаются сборки, архитектуру которых знает движок. Наведите на значки справа в строке, чтобы увидеть, что они значат.", title: "Поиск на Hugging Face")
                }
                filterBar
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
            .onChange(of: query) { scheduleSearch() }
            .onChange(of: sort) { scheduleSearch(immediate: true) }
            .onAppear { if results.isEmpty { scheduleSearch(immediate: true) } }

            if let error {
                Text(error).foregroundStyle(.red).font(.callout).padding()
            }
            let shown = filtered
            if shown.isEmpty && !loading {
                EmptyStateView(symbol: "line.3.horizontal.decrease.circle", title: "Ничего не найдено",
                               message: "Измените запрос или ослабьте фильтры.")
            } else {
                List(shown) { model in
                    Button { target = .repo(model.id) } label: { HubRow(model: model) }
                        .buttonStyle(.plain)
                        .listRowSeparator(.hidden)
                }
                .listStyle(.inset)
                .scrollContentBackground(.hidden)
            }
        }
    }

    private var filterBar: some View {
        HStack(spacing: 8) {
            Menu {
                Picker("Сортировка", selection: $sort) {
                    ForEach(HubSort.allCases) { Label($0.title, systemImage: $0.symbol).tag($0) }
                }
                .pickerStyle(.inline)
            } label: {
                Label(sort.title, systemImage: sort.symbol)
            }
            .fixedSize()

            Menu {
                Picker("Архитектура", selection: $family) {
                    Text("Любая архитектура").tag("")
                    Divider()
                    ForEach(engine.supportedFamilies, id: \.self) { Text(Catalog.title(for: $0)).tag($0) }
                }
                .pickerStyle(.inline)
            } label: {
                Label(family.isEmpty ? String(localized: "Архитектура") : Catalog.title(for: family), systemImage: "cube")
            }
            .fixedSize()

            Menu {
                Picker("Битность", selection: $bits) {
                    Text("Любая битность").tag(0)
                    ForEach([3, 4, 5, 6, 8], id: \.self) { Text("\($0)-бит").tag($0) }
                    Text("BF16").tag(16)
                }
                .pickerStyle(.inline)
            } label: {
                Label(bits == 0 ? String(localized: "Битность") : (bits == 16 ? "BF16" : String(localized: "\(bits)-бит")), systemImage: "square.stack.3d.down.right")
            }
            .fixedSize()
            .help("Битность готовых MLX-сборок")

            Spacer(minLength: 0)
            Toggle(isOn: $onlySupported) { Label("Совместимые", systemImage: "checkmark.seal") }
                .toggleStyle(.button)
                .labelStyle(.iconOnly)
                .fixedSize()
                .help("Только модели, которые умеет запускать движок")
            Toggle(isOn: $openOnly) { Label("Открытые", systemImage: "lock.open") }
                .toggleStyle(.button)
                .labelStyle(.iconOnly)
                .fixedSize()
                .help("Скрыть закрытые (gated) модели, требующие принять лицензию")
        }
        .controlSize(.small)
    }

    private var filtered: [HFModelSummary] {
        let supported = engine.supportedFamilies
        return results.filter { model in
            let fam = FamilyDetector.byName(model.id).flatMap { supported.contains($0) ? $0 : nil }
            let mlxBits = FamilyDetector.prebuiltBits(id: model.id, tags: model.tags ?? [], library: model.libraryName)
            if onlySupported && fam == nil { return false }
            if !family.isEmpty && fam != family { return false }
            if openOnly && model.isGated { return false }
            // Only ready MLX builds are downloaded; a catalog model's original opens its builds.
            if mlxBits == nil && !Catalog.entries.contains(where: { $0.originalRepo.caseInsensitiveCompare(model.id) == .orderedSame }) {
                return false
            }
            if bits != 0 {
                guard let b = mlxBits else { return false }
                if (b ?? 16) != bits { return false }
            }
            return true
        }
    }

    private func openOrSearch() {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        if trimmed.split(separator: "/").count == 2, !trimmed.contains(" ") {
            target = .repo(trimmed)
        } else {
            scheduleSearch(immediate: true)
        }
    }

    private func scheduleSearch(immediate: Bool = false) {
        searchTask?.cancel()
        let text = query.trimmingCharacters(in: .whitespaces)
        let sortKey = sort.rawValue
        searchTask = Task {
            if !immediate { try? await Task.sleep(for: .milliseconds(350)) }
            guard !Task.isCancelled else { return }
            loading = true
            defer { loading = false }
            do {
                var found: [HFModelSummary]
                do {
                    // MLX builds (tagged mflux) + the matching originals, which are kept only for catalog models.
                    async let mlx = HFClient.search(text.count >= 2 ? text : "", sort: sortKey, tag: "mflux", limit: 100)
                    async let all = HFClient.search(text.count >= 2 ? text : "", sort: sortKey,
                                                    pipelineTag: text.count >= 2 ? nil : "text-to-image", limit: 100)
                    let (a, b) = try await (mlx, all)
                    var seen = Set<String>()
                    found = (a + b).filter { seen.insert($0.id).inserted }
                    found.sort { lhs, rhs in
                        switch sort {
                        case .downloads: (lhs.downloads ?? 0) > (rhs.downloads ?? 0)
                        case .likes: (lhs.likes ?? 0) > (rhs.likes ?? 0)
                        case .trending: (lhs.trendingScore ?? 0) > (rhs.trendingScore ?? 0)
                        case .updated: (lhs.lastModified ?? "") > (rhs.lastModified ?? "")
                        }
                    }
                }
                guard !Task.isCancelled else { return }
                results = found
                error = nil
            } catch {
                if !Task.isCancelled { self.error = error.localizedDescription }
            }
        }
    }
}

private struct HubRow: View {
    @Environment(Engine.self) private var engine
    let model: HFModelSummary
    @State private var hovering = false

    var body: some View {
        let supported = engine.supportedFamilies
        let family = FamilyDetector.byName(model.id).flatMap { supported.contains($0) ? $0 : nil }
        let mlxBits = FamilyDetector.prebuiltBits(id: model.id, tags: model.tags ?? [], library: model.libraryName)
        HStack(spacing: 12) {
            HFAvatar(owner: model.owner, size: 38)
            VStack(alignment: .leading, spacing: 2) {
                Text(model.name)
                    .font(.system(size: 15, weight: .semibold))
                    .lineLimit(1)
                Text(model.id)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
            Spacer(minLength: 12)
            ModelBadges(family: family, caps: family.flatMap { engine.caps(for: $0) }, prebuiltBits: mlxBits, gated: model.isGated)
            HStack(spacing: 8) {
                Text(ParamFormat.billions(model.parameters) ?? "")
                    .help("Параметров (по метаданным safetensors)")
                    .frame(width: 38, alignment: .trailing)
                Label(Format.count(model.downloads ?? 0), systemImage: "arrow.down.circle")
                    .help("Загрузок за последний месяц")
                    .frame(width: 66, alignment: .trailing)
                Label(Format.count(model.likes ?? 0), systemImage: "heart")
                    .help("Лайков")
                    .frame(width: 54, alignment: .trailing)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .monospacedDigit()
            .lineLimit(1)
            Image(systemName: "chevron.right").foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(hovering ? Color.primary.opacity(0.05) : .clear, in: RoundedRectangle(cornerRadius: 10))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
    }
}
