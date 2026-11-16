import SwiftUI

struct DownloadSheet: View {
    let target: DownloadTarget
    var onStarted: () -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(Engine.self) private var engine
    @Environment(ModelStore.self) private var store
    @Environment(HFMeta.self) private var meta

    private enum Choice: Hashable { case prebuilt(String), original }

    @State private var choice: Choice?
    @State private var textBits = 4
    @State private var imageBits = 8
    @State private var keepSource = false
    @State private var original: RepoAnalysis?
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

    private var params: (text: Double, image: Double, vae: Double)? {
        if let entry { return (entry.textParams, entry.imageParams, entry.vaeGB) }
        guard let analysis = original ?? repoAnalysis, let t = analysis.textParams, let i = analysis.imageParams else { return nil }
        return (t, i, analysis.vaeGB)
    }

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
        let gated = (choice == .original && (entry?.gated ?? original?.info.gated ?? false))
            || (entry == nil && repoAnalysis?.info.gated == true)
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
                InfoButton("Готовая сборка — уже квантованные MLX-веса: скачивается меньше, работает сразу.\n\nОригинал — полные веса с Hugging Face, которые приложение квантует само. Так можно задать разную битность для текстового/VL-энкодера и для диффузионной части и получить лучшее качество в рамках памяти этого Mac.", title: "Готовая сборка или оригинал")
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
            } else if !isPrebuiltRepo {
                originalRow
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
        return OptionCard(selected: choice == .prebuilt(repo)) {
            choice = .prebuilt(repo)
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

    private var originalRow: some View {
        OptionCard(selected: choice == .original) {
            choice = .original
            Task { await loadOriginal() }
        } content: {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Оригинал + своё квантование").font(.body.weight(.medium))
                        Text(originalCaption).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if let params {
                        let fp = Footprint.from(textParams: params.text, imageParams: params.image, vaeGB: params.vae, textBits: textBits, imageBits: imageBits)
                        let peak = MemoryModel.peakGB(fp)
                        FitBadge(fit: MemoryModel.fit(peak: peak), peak: peak)
                    } else if loading {
                        ProgressView().controlSize(.small)
                    }
                }
                if choice == .original, let params { quantControls(params) }
            }
        }
    }

    private var originalCaption: String {
        guard let analysis = original ?? (entry == nil ? repoAnalysis : nil) else {
            return String(localized: "Раздельное квантование текстового/VL-энкодера и диффузионной части")
        }
        var text = "↓ \(Format.bytes(analysis.downloadBytes))"
        if let params {
            let fp = Footprint.from(textParams: params.text, imageParams: params.image, vaeGB: params.vae, textBits: textBits, imageBits: imageBits)
            text += " → " + String(localized: "\(Format.gb(fp.total)) на диске")
        }
        return text
    }

    @ViewBuilder
    private func quantControls(_ params: (text: Double, image: Double, vae: Double)) -> some View {
        let suggestions = MemoryModel.suggestions(textParams: params.text, imageParams: params.image, vaeGB: params.vae)
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                ForEach(suggestions) { combo in
                    Button {
                        textBits = combo.textBits
                        imageBits = combo.imageBits
                    } label: {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(combo.label).font(.caption.weight(.semibold))
                            Text("T\(combo.textBits) · I\(combo.imageBits)").font(.caption2).monospacedDigit()
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                    }
                    .buttonStyle(.bordered)
                    .tint(combo.textBits == textBits && combo.imageBits == imageBits ? .accentColor : .secondary)
                }
                InfoButton("Подобрано под \(Int(Hardware.current.memoryGB.rounded())) ГБ этого Mac: максимум качества, при котором пик памяти остаётся в бюджете GPU. Энкодер выгружается до начала рисования, поэтому его битность влияет на пик меньше, чем битность диффузионной части.", title: "Лучшие сочетания")
            }
            bitsPicker("Текстовый / VL-энкодер", selection: $textBits, options: [4, 6, 8, 16],
                       info: "Понимает промпт (\(entry?.textEncoder ?? "LLM/VLM")). Хорошо переносит квантование: 4–6 бит почти не влияют на результат, 8 — практически без потерь.",
                       params: params.text)
            bitsPicker("Изображение (диффузия)", selection: $imageBits, options: [3, 4, 5, 6, 8, 16],
                       info: "Рисует изображение — именно здесь квантование заметнее всего: 8 бит ≈ оригинал, 6 — очень близко, 4 — небольшая потеря мелких деталей, 3 — заметная.",
                       params: params.image)
            Toggle(isOn: $keepSource) {
                LabelWithInfo("Хранить оригинальные веса", info: "Если включено, исходные веса остаются на диске и позже можно пересобрать модель с другим квантованием без повторной загрузки. Иначе после оптимизации они удаляются, освобождая место.")
            }
            .toggleStyle(.checkbox)
        }
        .padding(.top, 2)
    }

    private func bitsPicker(_ title: LocalizedStringResource, selection: Binding<Int>, options: [Int], info: LocalizedStringResource, params: Double) -> some View {
        HStack {
            LabelWithInfo(title, info: info)
            Spacer()
            Text(Format.gb(MemoryModel.runtimeGB(params: params, bits: selection.wrappedValue)))
                .font(.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()
            Picker("", selection: selection) {
                ForEach(options, id: \.self) { Text($0 >= 16 ? "BF16" : String(localized: "\($0) бит")).tag($0) }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .fixedSize()
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
            .disabled(choice == nil || family == nil || starting || unusableRepo || (choice == .original && params == nil))
        }
    }

    // MARK: Actions

    private func initialLoad() async {
        if let entry {
            choice = recommendedPrebuilt.map { .prebuilt($0.repo) } ?? .original
            applySuggestion(text: entry.textParams, image: entry.imageParams, vae: entry.vaeGB)
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
            if analysis.isPrebuilt {
                choice = .prebuilt(repo)
            } else {
                choice = .original
                if let t = analysis.textParams, let i = analysis.imageParams {
                    applySuggestion(text: t, image: i, vae: analysis.vaeGB)
                }
            }
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func loadOriginal() async {
        guard entry != nil, original == nil, !loading else { return }
        loading = true
        defer { loading = false }
        do {
            original = try await RepoAnalyzer.analyze(repo: originalRepo, family: family, engine: engine, countParams: false)
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func applySuggestion(text: Double, image: Double, vae: Double) {
        if let best = MemoryModel.suggestions(textParams: text, imageParams: image, vaeGB: vae).first {
            textBits = best.textBits
            imageBits = best.imageBits
        }
    }

    private func startDownload() async {
        guard let family, let choice else { return }
        starting = true
        defer { starting = false }
        do {
            switch choice {
            case .prebuilt(let repo):
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
            case .original:
                let analysis: RepoAnalysis
                if let ready = original ?? repoAnalysis, ready.family == family {
                    analysis = ready
                } else {
                    analysis = try await RepoAnalyzer.analyze(repo: originalRepo, family: family, engine: engine, countParams: false)
                }
                guard let params else { return }
                let fp = Footprint.from(textParams: params.text, imageParams: params.image, vaeGB: params.vae,
                                        textBits: textBits, imageBits: imageBits)
                store.add(repo: originalRepo, revision: analysis.info.sha, family: family,
                          title: entry?.title ?? title, files: analysis.selectedFiles,
                          prebuilt: false, prebuiltBits: nil,
                          textBits: textBits >= 16 ? nil : textBits, imageBits: imageBits >= 16 ? nil : imageBits,
                          keepSource: keepSource || (textBits >= 16 && imageBits >= 16), footprint: fp)
            }
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
