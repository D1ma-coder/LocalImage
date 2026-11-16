import SwiftUI

enum SettingsTab: String { case generation, huggingFace, folders, engine }

extension Notification.Name {
    /// Posted when the Hugging Face token is saved or removed.
    static let hfTokenChanged = Notification.Name("LocalImage.hfTokenChanged")
}

struct SettingsView: View {
    @AppStorage("settings.tab") private var tab: SettingsTab = .huggingFace

    var body: some View {
        TabView(selection: $tab) {
            GenerationSettingsTab().tabItem { Label("Генерация", systemImage: "slider.horizontal.3") }.tag(SettingsTab.generation)
            AccountSettings().tabItem { Label("Hugging Face", systemImage: "key") }.tag(SettingsTab.huggingFace)
            StorageSettings().tabItem { Label("Папки", systemImage: "folder") }.tag(SettingsTab.folders)
            EngineSettings().tabItem { Label("Движок", systemImage: "cpu") }.tag(SettingsTab.engine)
        }
        .frame(width: 560, height: 520)
    }
}

private struct GenerationSettingsTab: View {
    @Environment(Studio.self) private var studio
    @State private var showLog = false

    var body: some View {
        Form {
            SwiftUI.Section {
                AdvancedRows(caps: studio.caps)
            } header: {
                HStack(spacing: 5) {
                    Text(studio.selectedModel.map { String(localized: "Для модели «\($0.title)»") } ?? String(localized: "Генерация"))
                    InfoButton("Технические параметры генерации. По умолчанию всё подобрано автоматически под модель и этот Mac — менять их не обязательно. Guidance появляется только у моделей, которые его поддерживают. Негативный промпт — в панели параметров.")
                }
            }
            SwiftUI.Section {
                Button("Журнал последней генерации") { showLog = true }
                    .disabled(studio.log.isEmpty)
            }
        }
        .formStyle(.grouped)
        .sheet(isPresented: $showLog) { LogView(lines: studio.log) }
    }
}

private struct AccountSettings: View {
    enum Check: Equatable { case idle, checking, valid(String), invalid(String) }

    @State private var token = TokenStore.load() ?? ""
    @State private var check: Check = .idle
    @State private var task: Task<Void, Never>?

    var body: some View {
        Form {
            SwiftUI.Section {
                HStack(spacing: 8) {
                    SecureField("", text: $token, prompt: Text("hf_…"))
                        .labelsHidden()
                        .textFieldStyle(.plain)
                    statusIcon
                }
                if case .valid(let name) = check {
                    Text("Подключено: \(name)").font(.caption).foregroundStyle(.secondary)
                } else if case .invalid(let reason) = check {
                    Text(reason).font(.caption).foregroundStyle(.red)
                }
            } header: {
                HStack(spacing: 5) {
                    Text("Токен Hugging Face")
                    InfoButton("Необязателен. Нужен для закрытых (gated) моделей — например, оригинальных FLUX — и повышает лимиты скачивания. Подойдёт токен с правом Read (huggingface.co → Settings → Access Tokens).\n\nСохраняется и проверяется автоматически при вводе. Хранится в файле ~/Library/Application Support/LocalImage/hf_token, доступном только вашему пользователю, и передаётся только на huggingface.co.")
                }
            }
        }
        .formStyle(.grouped)
        .onChange(of: token) { schedule() }
        .onAppear { if !token.isEmpty { schedule(delay: 0) } }
    }

    @ViewBuilder
    private var statusIcon: some View {
        switch check {
        case .idle: EmptyView()
        case .checking: ProgressView().controlSize(.small)
        case .valid: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .invalid: Image(systemName: "xmark.circle.fill").foregroundStyle(.red)
        }
    }

    /// Debounced: save + validate half a second after the last keystroke.
    private func schedule(delay: Double = 0.5) {
        task?.cancel()
        let value = token.trimmingCharacters(in: .whitespacesAndNewlines)
        task = Task {
            if delay > 0 { try? await Task.sleep(for: .seconds(delay)) }
            guard !Task.isCancelled else { return }
            TokenStore.save(value.isEmpty ? nil : value)
            NotificationCenter.default.post(name: .hfTokenChanged, object: nil)
            guard !value.isEmpty else { check = .idle; return }
            check = .checking
            do {
                let name = try await HFClient.whoami()
                guard !Task.isCancelled else { return }
                check = .valid(name)
            } catch {
                guard !Task.isCancelled else { return }
                check = .invalid(value.hasPrefix("hf_") ? String(localized: "Токен не принят Hugging Face") : String(localized: "Токен должен начинаться с hf_"))
            }
        }
    }
}

private struct StorageSettings: View {
    @AppStorage("modelsDirectory") private var modelsDirectory = ""
    @AppStorage("outputsDirectory") private var outputsDirectory = ""
    @Environment(ModelStore.self) private var store
    @Environment(Studio.self) private var studio

    var body: some View {
        Form {
            folderRow("Модели", path: $modelsDirectory, fallback: Paths.defaultModels,
                      info: "Где хранятся скачанные модели. Можно выбрать внешний SSD. Уже скачанные модели не переносятся автоматически — переместите папки вручную.") {
                store.load()
            }
            folderRow("Результаты", path: $outputsDirectory, fallback: Paths.defaultOutputs,
                      info: "Куда сохраняются изображения (PNG + .lix.json с параметрами).") {
                studio.loadGallery()
            }
        }
        .formStyle(.grouped)
    }

    private func folderRow(_ title: LocalizedStringResource, path: Binding<String>, fallback: URL, info: LocalizedStringResource, changed: @escaping () -> Void) -> some View {
        LabeledContent {
            HStack {
                Text((path.wrappedValue.isEmpty ? fallback.path : path.wrappedValue).replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .foregroundStyle(.secondary)
                Button("Изменить…") {
                    let panel = NSOpenPanel()
                    panel.canChooseDirectories = true
                    panel.canChooseFiles = false
                    panel.canCreateDirectories = true
                    if panel.runModal() == .OK, let url = panel.url {
                        path.wrappedValue = url.path
                        changed()
                    }
                }
                if !path.wrappedValue.isEmpty {
                    Button("Сбросить") { path.wrappedValue = ""; changed() }
                }
            }
        } label: {
            LabelWithInfo(title, info: info)
        }
    }
}

private struct EngineSettings: View {
    @Environment(Engine.self) private var engine
    @State private var showLog = false
    @State private var confirmReinstall = false

    var body: some View {
        Form {
            SwiftUI.Section {
                LabeledContent("mflux", value: engine.info?.mflux ?? "—")
                LabeledContent("MLX", value: engine.info?.mlx ?? "—")
                LabeledContent("Семейств моделей", value: "\(engine.info?.families.count ?? 0)")
                LabeledContent("Окружение") {
                    Button(Paths.engine.path.replacingOccurrences(of: NSHomeDirectory(), with: "~")) {
                        NSWorkspace.shared.open(Paths.ensure(Paths.engine))
                    }
                    .buttonStyle(.link)
                }
            } header: {
                HStack(spacing: 5) {
                    Text("Движок")
                    InfoButton("mflux на MLX — нативная для Apple Silicon реализация FLUX, Qwen-Image, Z-Image и других моделей. Версия закреплена, чтобы пошаговые превью и раздельное квантование работали стабильно.")
                }
            }
            SwiftUI.Section {
                HStack {
                    Button("Журнал установки") { showLog = true }
                    Spacer()
                    Button("Переустановить…") { confirmReinstall = true }
                }
            }
        }
        .formStyle(.grouped)
        .sheet(isPresented: $showLog) { LogView(lines: engine.installLog) }
        .confirmationDialog("Переустановить движок?", isPresented: $confirmReinstall) {
            Button("Переустановить") { Task { await engine.reinstall() } }
        } message: {
            Text("Окружение Python будет создано заново. Модели и изображения не затрагиваются.")
        }
    }
}
