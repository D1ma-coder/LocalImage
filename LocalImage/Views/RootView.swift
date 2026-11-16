import SwiftUI

struct RootView: View {
    @Environment(AppModel.self) private var app
    @Environment(Engine.self) private var engine
    @Environment(ModelStore.self) private var store
    @Environment(Studio.self) private var studio

    private var studioActive: Bool { engine.isReady && app.section == .studio }

    var body: some View {
        @Bindable var app = app
        NavigationSplitView {
            List(selection: $app.section) {
                ForEach(Section.allCases, id: \.self) { section in
                    Label(section.title, systemImage: section.symbol)
                        .badge(section == .models ? store.activeCount : 0)
                        .tag(section)
                }
            }
            .navigationSplitViewColumnWidth(min: 170, ideal: 190, max: 240)
            .safeAreaInset(edge: .bottom) {
                VStack(spacing: 10) {
                    EngineFooter()
                        .padding(.horizontal, 8)
                    SettingsButton()
                }
                .padding(12)
            }
        } detail: {
            Group {
                if !engine.isReady {
                    EngineSetupView()
                } else {
                    switch app.section {
                    case .studio: StudioView()
                    case .models: ModelsView()
                    case .gallery: GalleryView()
                    }
                }
            }
            // Fixed ideal width: otherwise the content's ideal (e.g. prompt text as you type) leaks into
            // the split view, which then keeps re-sizing the inspector.
            .frame(minWidth: 380, idealWidth: 640, maxWidth: .infinity, maxHeight: .infinity)
            // Explicit limits: otherwise the split view takes the detail's current fitting width as its
            // minimum, and opening the inspector first collapses the sidebar, then re-expands it.
            .navigationSplitViewColumnWidth(min: 380, ideal: 640)
        }
        // Attached to the split view (not the detail) so the panel is a full-height column,
        // exactly like the sidebar on the left. Its toggle lives inside it; when the panel
        // is closed, macOS moves that same button to the trailing edge of the toolbar.
        .inspector(isPresented: Binding(
            get: { studioActive && app.inspectorShown },
            set: { app.inspectorShown = $0 }
        )) {
            StudioInspector()
                // Fixed width (what the content needs): a flexible range let the column follow the
                // content's ideal width and re-size on every change (ETA text, values).
                .inspectorColumnWidth(380)
                .toolbar {
                    if studioActive {
                        ToolbarItem { InspectorToggle(shown: $app.inspectorShown) }
                        ToolbarSpacer(.flexible)
                    }
                }
        }
    }
}

private struct EngineFooter: View {
    @Environment(Engine.self) private var engine

    var body: some View {
        let hw = Hardware.current
        HStack(spacing: 6) {
            Circle()
                .fill(engine.isReady ? Color.green : Color.orange)
                .frame(width: 7, height: 7)
            Text(engine.isReady ? "MLX · \(engine.info?.mflux ?? "")" : String(localized: "Движок"))
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            let gpuCores = hw.gpuCores.map { String(localized: ", \($0)-ядерный GPU") } ?? ""
            InfoButton(
                "\(hw.chip), \(Int(hw.memoryGB.rounded())) ГБ объединённой памяти\(gpuCores).\n\nДвижок: mflux \(engine.info?.mflux ?? "—") на MLX \(engine.info?.mlx ?? "—") — нативный фреймворк Apple для машинного обучения на Apple Silicon. Модели работают полностью локально, ничего не уходит в сеть.\n\nДоступно GPU без подкачки: \(Format.gb(hw.budgetGB)).",
                title: "Этот Mac")
        }
    }
}

/// Bottom-of-sidebar entry to the Settings window.
private struct SettingsButton: View {
    @Environment(\.openSettings) private var openSettings
    @State private var hovering = false

    var body: some View {
        Button {
            openSettings()
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "gearshape")
                    .font(.system(size: 14))
                    .foregroundStyle(.secondary)
                    .frame(width: 18)
                Text("Настройки")
                    .font(.callout)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(hovering ? Color.primary.opacity(0.07) : .clear, in: RoundedRectangle(cornerRadius: 8))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help("Настройки (⌘,)")
    }
}
