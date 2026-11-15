import SwiftUI

@main
struct LocalImageApp: App {
    @State private var app = AppModel()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(app)
                .environment(app.engine)
                .environment(app.store)
                .environment(app.studio)
                .environment(app.meta)
                .frame(minWidth: 980, minHeight: 640)
                .task { await app.start() }
        }
        .windowToolbarStyle(.unified)
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandGroup(after: .sidebar) {
                Button(app.inspectorShown ? "Скрыть параметры" : "Показать параметры") {
                    app.section = .studio
                    app.inspectorShown.toggle()
                }
                .keyboardShortcut("i", modifiers: [.command, .option])
            }
            CommandMenu("Генерация") {
                Button("Сгенерировать") { app.studio.generate() }
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(app.studio.isRunning)
                Button("Остановить") { app.studio.cancel() }
                    .keyboardShortcut(".", modifiers: .command)
                    .disabled(!app.studio.isRunning)
                Divider()
                Button("Новый случайный seed") {
                    app.studio.settings.seed = Int.random(in: 1...999_999_999)
                    app.studio.settings.randomSeed = false
                }
                .keyboardShortcut("r", modifiers: [.command, .shift])
            }
        }

        Settings {
            SettingsView()
                .environment(app)
                .environment(app.engine)
                .environment(app.store)
                .environment(app.studio)
                .environment(app.meta)
        }
    }
}

enum Section: String, Hashable, CaseIterable {
    case studio, models, gallery

    var title: String {
        switch self {
        case .studio: "Студия"
        case .models: "Модели"
        case .gallery: "Галерея"
        }
    }

    var symbol: String {
        switch self {
        case .studio: "wand.and.sparkles"
        case .models: "shippingbox"
        case .gallery: "photo.on.rectangle.angled"
        }
    }
}

@Observable
final class AppModel {
    let engine = Engine()
    let gate = HeavyJobGate()
    let store: ModelStore
    let studio: Studio
    let meta = HFMeta()
    var section: Section = .studio
    /// Not @AppStorage: that re-renders on *any* UserDefaults write (every settings save, the split view's
    /// own autosave while the sidebar animates), rebuilding the root view and the whole toolbar.
    var inspectorShown = UserDefaults.standard.object(forKey: "studio.inspectorShown") as? Bool ?? true {
        didSet { UserDefaults.standard.set(inspectorShown, forKey: "studio.inspectorShown") }
    }
    private var started = false

    init() {
        store = ModelStore(gate: gate)
        studio = Studio(store: store, engine: engine, gate: gate)
        store.engine = engine
    }

    func start() async {
        guard !started else { return }
        started = true
        NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: .main
        ) { [studio, store] _ in
            MainActor.assumeIsolated {
                studio.shutdown()
                store.shutdown()
            }
        }
        store.load()
        studio.loadGallery()
        if studio.selectedModel == nil { studio.settings.modelID = store.readyModels.first?.id }
        await engine.bootstrap()
        if !engine.isReady { section = .studio }
    }
}
