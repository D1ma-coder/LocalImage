import SwiftUI

struct EngineSetupView: View {
    @Environment(Engine.self) private var engine
    @State private var showLog = false

    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: "cpu")
                .font(.system(size: 44, weight: .light))
                .foregroundStyle(.tint)
                .symbolEffect(.pulse, isActive: isInstalling)

            HStack(spacing: 6) {
                Text("Движок MLX").font(.title2.weight(.semibold))
                InfoButton(
                    "LocalImage использует mflux — самую быструю открытую реализацию современных диффузионных моделей на MLX, фреймворке Apple для Apple Silicon. Устанавливается в изолированное окружение внутри ~/Library/Application Support/LocalImage (Python 3.12 через uv, ~1.5 ГБ). Системный Python не затрагивается.",
                    title: "Что будет установлено")
            }

            content
                .frame(maxWidth: 420)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .sheet(isPresented: $showLog) { LogView(lines: engine.installLog) }
    }

    private var isInstalling: Bool {
        if case .installing = engine.state { return true }
        return false
    }

    @ViewBuilder
    private var content: some View {
        switch engine.state {
        case .checking:
            ProgressView().controlSize(.small)
        case .missing:
            VStack(spacing: 14) {
                Text("Один раз установим окружение для генерации. Это займёт несколько минут.")
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                Button("Установить") { Task { await engine.install() } }
                    .buttonStyle(.glassProminent)
                    .controlSize(.large)
            }
        case .installing(let step, let title, let detail):
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text(title).font(.headline)
                    Spacer()
                    Text("\(step) из \(Engine.installSteps)").foregroundStyle(.secondary).monospacedDigit()
                }
                ProgressView(value: Double(step - 1) + 0.5, total: Double(Engine.installSteps))
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Button("Журнал") { showLog = true }
                    .buttonStyle(.link)
                    .font(.caption)
            }
            .padding(18)
            .glassEffect(in: .rect(cornerRadius: 18))
        case .failed(let message):
            VStack(spacing: 12) {
                Label("Установка не удалась", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(6)
                    .multilineTextAlignment(.center)
                HStack {
                    Button("Журнал") { showLog = true }
                    Button("Повторить") { Task { await engine.install() } }
                        .buttonStyle(.glassProminent)
                }
            }
        case .ready:
            EmptyView()
        }
    }
}
