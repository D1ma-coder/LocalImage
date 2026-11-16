import SwiftUI

struct DownloadSheet: View {
    let target: DownloadTarget
    var onStarted: () -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(Engine.self) private var engine
    @Environment(ModelStore.self) private var store
    @Environment(HFMeta.self) private var meta

    /// The ready MLX build to download.
    @State private var choice: String?
    @State private var repoAnalysis: RepoAnalysis?
    @State private var familyOverride: String?
    @State private var loading = false
    @State private var starting = false
    @State private var error: String?

    /// Catalog entries, including search results that are a catalog model's original repo —
    /// those get the same ready-made builds as in the catalog.
    private var entry: CatalogEntry? {
        switch target {
        case .catalog(let entry): entry
        case .repo(let repo): Catalog.entries.first { $0.originalRepo.caseInsensitiveCompare(repo) == .orderedSame }
        }
    }

    private var family: String? { familyOverride ?? entry?.family ?? repoAnalysis?.family }

    private var title: String {
        if let entry { return entry.title }
        if case .repo(let repo) = target { return repo.split(separator: "/").last.map(String.init) ?? repo }
        return ""
    }

    private var originalRepo: String {
        if let entry { return entry.originalRepo }
        if case .repo(let repo) = target { return repo }
        return ""
    }

    private var isPrebuiltRepo: Bool { entry == nil && repoAnalysis?.isPrebuilt == true }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(20)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if let error {
                        Label(error, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                            .font(.callout)
                    }
                    gatedNotice
                    if entry == nil { familyRow }
                    variants
                }
                .padding(20)
            }
            Divider()
            footer
                .padding(16)
        }
        .frame(width: 600, height: 620)
        .task { await initialLoad() }
    }

    // MARK: Sections

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.title2.weight(.semibold))
                Link(originalRepo, destination: URL(string: "https://huggingface.co/\(originalRepo)")!)
                    .font(.callout)
            }
            Spacer()
            if let entry { InfoButton(verbatim: meta.card(for: entry.originalRepo)?.summary ?? entry.about, title: LocalizedStringResource(stringLiteral: entry.title)) }
        }
    }

    @ViewBuilder
    private var gatedNotice: some View {
        let gated = entry == nil && repoAnalysis?.info.gated == true
        if gated && TokenStore.load() == nil {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "lock.fill").foregroundStyle(.orange)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Закрытая модель").font(.callout.weight(.semibold))
                    Text("Откройте страницу модели, примите условия лицензии и добавьте токен Hugging Face в Настройках (⌘,).")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
        }
    }

    @ViewBuilder
    private var familyRow: some View {
        if loading && repoAnalysis == nil {
            HStack { ProgressView().controlSize(.small); Text("Анализируем репозиторий…").foregroundStyle(.secondary) }
        } else if let detected = repoAnalysis?.family, familyOverride == nil {
            HStack {
                LabelWithInfo("Архитектура", info: "Определена автоматически по model_index.json, base_model из карточки и имени репозитория.")
                Spacer()
                Text(Catalog.title(for: detected)).foregroundStyle(.secondary)
            }
        } else if repoAnalysis != nil {
            HStack {
                LabelWithInfo("Архитектура", info: "Автоматически распознать не удалось. Укажите базовую модель, если это дообучение (fine-tune) поддерживаемой архитектуры — иначе движок не сможет её загрузить.")
                Spacer()
                Picker("", selection: Binding(get: { family ?? "" }, set: { familyOverride = $0.isEmpty ? nil : $0; Task { await reanalyze() } })) {
                    Text("Не распознана").tag("")
                    ForEach(engine.supportedFamilies, id: \.self) { Text(Catalog.title(for: $0)).tag($0) }
                }
                .labelsHidden()
                .frame(width: 240)
            }
        }
    }

    @ViewBuilder
    private var variants: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text("Вариант").font(.headline)
                InfoButton("Готовые сборки — уже квантованные MLX-веса: скачиваются меньше и работают сразу. Меньше бит — меньше памяти и чуть меньше деталей; рекомендуем лучшую сборку, которая помещается в память этого Mac.", title: "Готовые сборки")
            }
            if let entry {
                ForEach(entry.prebuilt) { variant in
                    prebuiltRow(repo: variant.repo, bits: variant.bits, footprint: variant.footprint,
                                download: nil, recommended: variant.repo == recommendedPrebuilt?.repo)
                }
            } else if isPrebuiltRepo, let analysis = repoAnalysis, let fp = analysis.footprintAtSource {
                prebuiltRow(repo: analysis.info.id, bits: analysis.prebuiltBits ?? nil, footprint: fp,
                            download: analysis.downloadBytes, recommended: true)
            }
            if unusableRepo {
                Label {
                    Text("В репозитории нет полной модели в формате diffusers или MLX — только отдельные файлы (GGUF, ComfyUI, один трансформер без энкодера и VAE). Движок не сможет её загрузить.")
                        .fixedSize(horizontal: false, vertical: true)
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                }
                .font(.callout)
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            } else if entry == nil, repoAnalysis != nil, !isPrebuiltRepo {
                Label {
                    Text("Это оригинальные веса, а приложение скачивает только готовые MLX-сборки. Найдите сборку этой модели в поиске — у них значок битности.")
                        .fixedSize(horizontal: false, vertical: true)
                } icon: {
                    Image(systemName: "info.circle.fill").foregroundStyle(.secondary)
                }
                .font(.callout)
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
        }
    }

    /// Search result whose files the engine can't load (single-file / GGUF / ComfyUI checkpoints, no weights picked).
    private var unusableRepo: Bool {
        guard entry == nil, let analysis = repoAnalysis else { return false }
        return (analysis.footprintAtSource?.image ?? 0) < 0.05
    }

    private var recommendedPrebuilt: PrebuiltVariant? {
        guard let entry else { return nil }
        return entry.prebuilt.last { MemoryModel.fit($0.footprint) == .comfortable } ?? entry.prebuilt.first
    }

    private func prebuiltRow(repo: String, bits: Int?, footprint: Footprint, download: Int64?, recommended: Bool) -> some View {
        let peak = MemoryModel.peakGB(footprint)
        return OptionCard(selected: choice == repo) {
            choice = repo
        } content: {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text("Готовая сборка · \(Format.bits(bits))").font(.body.weight(.medium))
                        if recommended { Chip(text: String(localized: "Рекомендуем"), tint: .green) }
                    }
                    Text("Текст \(Format.gb(footprint.text)) · изображение \(Format.gb(footprint.image)) · ↓ \(download.map(Format.bytes) ?? Format.gb(footprint.total))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                FitBadge(fit: MemoryModel.fit(peak: peak), peak: peak)
            }
        }
    }

    private var footer: some View {
        HStack {
            let free = Paths.freeDiskBytes(at: Paths.models)
            Label("\(Format.bytes(free)) свободно", systemImage: "internaldrive")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            Button("Отмена") { dismiss() }
                .keyboardShortcut(.cancelAction)
            Button {
                Task { await startDownload() }
            } label: {
                if starting { ProgressView().controlSize(.small) } else { Text("Скачать") }
            }
            .buttonStyle(.glassProminent)
            .keyboardShortcut(.defaultAction)
            .disabled(choice == nil || family == nil || starting || unusableRepo)
        }
    }

    // MARK: Actions

    private func initialLoad() async {
        if entry != nil {
            choice = recommendedPrebuilt?.repo
            return
        }
        await reanalyze()
    }

    private func reanalyze() async {
        guard case .repo(let repo) = target else { return }
        loading = true
        defer { loading = false }
        do {
            let analysis = try await RepoAnalyzer.analyze(repo: repo, family: familyOverride, engine: engine, countParams: true)
            repoAnalysis = analysis
            error = analysis.family == nil ? String(localized: "Архитектура не распознана — выберите её вручную.") : nil
            choice = analysis.isPrebuilt ? repo : nil
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func startDownload() async {
        guard let family, let repo = choice else { return }
        starting = true
        defer { starting = false }
        do {
            let analysis: RepoAnalysis
            if let ready = repoAnalysis, ready.info.id == repo, ready.family == family {
                analysis = ready
            } else {
                analysis = try await RepoAnalyzer.analyze(repo: repo, family: family, engine: engine, countParams: false)
            }
            let bits = analysis.prebuiltBits ?? nil
            let fp = analysis.footprintAtSource ?? Footprint(text: 0, image: 0, vae: 0)
            store.add(repo: repo, revision: analysis.info.sha, family: family,
                      title: entry?.title ?? title, files: analysis.selectedFiles,
                      prebuilt: true, prebuiltBits: bits, textBits: nil, imageBits: nil,
                      keepSource: true, footprint: fp)
            onStarted()
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
    }
}

private struct OptionCard<Content: View>: View {
    let selected: Bool
    let action: () -> Void
    @ViewBuilder let content: Content

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: selected ? "largecircle.fill.circle" : "circle")
                .foregroundStyle(selected ? Color.accentColor : .secondary)
                .padding(.top, 2)
            content
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(selected ? Color.accentColor.opacity(0.07) : Color.clear, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(selected ? Color.accentColor.opacity(0.5) : Color.secondary.opacity(0.2)))
        .contentShape(Rectangle())
        .onTapGesture(perform: action)
    }
}
