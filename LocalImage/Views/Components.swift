import SwiftUI

/// The "i" button: every explanation in the app lives behind one of these.
struct InfoButton: View {
    let title: LocalizedStringResource?
    let text: LocalizedStringResource
    @State private var shown = false

    init(_ text: LocalizedStringResource, title: LocalizedStringResource? = nil) {
        self.text = text
        self.title = title
    }

    /// Text that is already final (e.g. a model card from Hugging Face): shown as is, not translated.
    init(verbatim text: String, title: LocalizedStringResource? = nil) {
        self.init(LocalizedStringResource(stringLiteral: text), title: title)
    }

    var body: some View {
        Button { shown.toggle() } label: {
            Image(systemName: "info.circle")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(Text(title ?? "Подробнее"))
        .popover(isPresented: $shown, arrowEdge: .trailing) {
            VStack(alignment: .leading, spacing: 8) {
                if let title { Text(title).font(.headline) }
                Text(text)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(14)
            .frame(width: 300, alignment: .leading)
        }
    }
}

/// A form row label with an optional info button.
struct LabelWithInfo: View {
    let title: LocalizedStringResource
    let info: LocalizedStringResource?

    init(_ title: LocalizedStringResource, info: LocalizedStringResource? = nil) {
        self.title = title
        self.info = info
    }

    var body: some View {
        HStack(spacing: 5) {
            Text(title)
            if let info { InfoButton(info, title: title) }
        }
    }
}

struct FitBadge: View {
    let fit: Fit
    var peak: Double?
    var compact = false

    var color: Color {
        switch fit {
        case .comfortable: .green
        case .tight: .orange
        case .tooBig: .red
        }
    }

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: fit.symbol)
            if !compact {
                Text(peak.map { "≈ \(Format.gb($0))" } ?? fit.label)
                    .monospacedDigit()
            }
        }
        .font(.caption.weight(.medium))
        .foregroundStyle(color)
        .help(peak.map { String(localized: "\(fit.label): пик ≈ \(Format.gb($0)) из \(Format.gb(Hardware.current.budgetGB)) доступных GPU") } ?? fit.label)
    }
}

struct Chip: View {
    let text: String
    var tint: Color = .secondary

    var body: some View {
        Text(text)
            .font(.caption2.weight(.medium))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(tint.opacity(0.12), in: Capsule())
            .foregroundStyle(tint == .secondary ? Color.secondary : tint)
    }
}

/// Horizontal memory gauge: model peak vs. GPU budget vs. physical RAM.
struct MemoryGauge: View {
    let peak: Double
    var hardware: Hardware = .current

    var body: some View {
        let total = hardware.memoryBytes > 0 ? Double(hardware.memoryBytes) / 1e9 : 16
        let fit = MemoryModel.fit(peak: peak, hardware: hardware)
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(.quaternary)
                Capsule()
                    .fill(FitBadge(fit: fit).color.gradient)
                    .frame(width: proxy.size.width * min(1, peak / total))
                Rectangle()
                    .fill(.primary.opacity(0.35))
                    .frame(width: 1.5)
                    .offset(x: proxy.size.width * min(1, hardware.budgetGB / total))
            }
        }
        .frame(height: 5)
        .help("Пик ≈ \(Format.gb(peak)). Черта — рекомендуемый бюджет GPU \(Format.gb(hardware.budgetGB)) из \(Format.gb(total)) памяти.")
    }
}

struct EmptyStateView: View {
    let symbol: String
    let title: LocalizedStringResource
    let message: LocalizedStringResource
    var action: (title: LocalizedStringResource, run: () -> Void)?

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 40, weight: .light))
                .foregroundStyle(.tertiary)
            Text(title).font(.title3.weight(.semibold))
            Text(message)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 360)
            if let action {
                Button(action: action.run) { Text(action.title) }
                    .buttonStyle(.glassProminent)
                    .controlSize(.large)
                    .padding(.top, 4)
            }
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct LogView: View {
    let lines: [String]
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Журнал").font(.headline)
                Spacer()
                Button("Скопировать") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(lines.joined(separator: "\n"), forType: .string)
                }
                Button("Готово") { dismiss() }.keyboardShortcut(.defaultAction)
            }
            .padding()
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(Array(lines.enumerated()), id: \.offset) { index, line in
                            Text(line)
                                .font(.system(size: 11, design: .monospaced))
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .id(index)
                        }
                    }
                    .padding()
                }
                .onAppear { proxy.scrollTo(lines.count - 1, anchor: .bottom) }
            }
        }
        .frame(width: 720, height: 460)
    }
}
