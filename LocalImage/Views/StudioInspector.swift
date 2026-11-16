import SwiftUI

struct StudioInspector: View {
    @Environment(Studio.self) private var studio
    @Environment(ModelStore.self) private var store
    @Environment(AppModel.self) private var app

    var body: some View {
        @Bindable var studio = studio
        let caps = studio.caps
        Form {
            modelSection

            SwiftUI.Section {
                AspectPicker(selection: $studio.settings.aspect, hasSource: studio.initImage != nil)
                VStack(alignment: .leading, spacing: 6) {
                    LabelWithInfo("Качество", info: "Разрешение итогового изображения. Черновик ≈ 0.4 МП — для быстрых проб, Стандарт ≈ 1 МП — родное разрешение большинства моделей, Высокое и Максимум — больше деталей, но больше времени и памяти (расход растёт пропорционально площади).")
                    // Not a segmented Picker: NSSegmentedControl makes every segment as wide as «Максимум»
                    // (~364 pt in all) and can't shrink, so it overflowed the 380 pt panel.
                    FittingSegments(selection: $studio.settings.quality, options: Quality.allCases) { $0.title }
                    let size = studio.dimensions
                    Text("\(size.width) × \(size.height) · \(String(format: "%.1f", studio.megapixels)) МП")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                StepsRow()
                LabeledContent {
                    Stepper("\(studio.settings.count)", value: $studio.settings.count, in: 1...8)
                        .monospacedDigit()
                } label: {
                    LabelWithInfo("Количество", info: "Сколько вариантов сделать подряд с соседними seed. Модель загружается один раз на всю серию, поэтому серия быстрее, чем отдельные запуски. В серии текстовый энкодер остаётся в памяти — пик немного выше.")
                }
                SeedRow()
                if caps?.usesNegativePrompt == true {
                    VStack(alignment: .leading, spacing: 4) {
                        LabelWithInfo("Негативный промпт", info: "Чего не должно быть на изображении. Работает только у моделей, которые его поддерживают.")
                        TextField("", text: $studio.settings.negativePrompt, prompt: Text("размыто, артефакты…"), axis: .vertical)
                            .labelsHidden()
                            .lineLimit(1...3)
                            .textFieldStyle(.roundedBorder)
                    }
                }
            } header: {
                Text("Кадр")
            }

            if studio.initImage != nil {
                SwiftUI.Section {
                    if caps?.img2img == false {
                        Label("Эта модель не поддерживает img2img — исходник будет проигнорирован.", systemImage: "exclamationmark.triangle")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            LabelWithInfo("Влияние исходника", info: "Насколько результат похож на исходное изображение. 0.2–0.4 — сохранить композицию и цвета, перерисовав детали; 0.6–0.8 — лёгкая доработка. Часть первых шагов пропускается, поэтому генерация быстрее.")
                            Spacer()
                            Text(String(format: "%.2f", studio.settings.strength)).monospacedDigit().foregroundStyle(.secondary)
                        }
                        Slider(value: Binding(get: { studio.settings.strength },
                                              set: { studio.settings.strength = ($0 / 0.05).rounded() * 0.05 }),
                               in: 0.05...0.95)
                            .labelsHidden()
                    }
                } header: {
                    Text("Исходное изображение")
                }
            }
        }
        .formStyle(.grouped)
    }

    @ViewBuilder
    private var modelSection: some View {
        @Bindable var studio = studio
        SwiftUI.Section {
            if store.readyModels.isEmpty {
                Button("Скачать модель…") { app.section = .models }
            } else {
                // The model itself is chosen in the toolbar switcher; here only its memory/speed.
                if let peak = studio.estimatedPeak, let fit = studio.fit {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            FitBadge(fit: fit, peak: peak)
                            Spacer()
                            if let seconds = studio.estimatedSeconds {
                                Label("≈ \(Format.duration(seconds))", systemImage: "clock")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .monospacedDigit()
                            }
                            InfoButton(verbatim: memoryInfo(peak: peak, fit: fit), title: "Память и скорость")
                        }
                        MemoryGauge(peak: peak)
                    }
                }
            }
        } header: {
            Text("Память и скорость")
        }
    }

    private func memoryInfo(peak: Double, fit: Fit) -> String {
        let hw = Hardware.current
        let memory = Int(hw.memoryGB.rounded())
        var parts = [
            String(localized: "Оценка пикового расхода памяти для текущих параметров: ≈ \(Format.gb(peak)). GPU этого Mac может держать без подкачки ≈ \(Format.gb(hw.budgetGB)) из \(memory) ГБ."),
            String(localized: "Текстовый энкодер и диффузионная часть не находятся в памяти одновременно: энкодер выгружается сразу после обработки промпта."),
        ]
        switch fit {
        case .comfortable: break
        case .tight: parts.append(String(localized: "Впритык: возможна подкачка и замедление. Помогут меньшее качество, режим «Экономия» или более сильное квантование."))
        case .tooBig: parts.append(String(localized: "Скорее всего не хватит памяти. Уменьшите качество или выберите сборку с меньшей битностью."))
        }
        if studio.estimatedSeconds != nil {
            parts.append(String(localized: "Время оценено по прошлым генерациям этой модели на этом Mac."))
        }
        return parts.joined(separator: "\n\n")
    }
}

private struct StepsRow: View {
    @Environment(Studio.self) private var studio

    var body: some View {
        let defaultSteps = studio.caps?.defaultSteps ?? 20
        let upper = max(50, defaultSteps * 3)
        let value = Binding<Double>(
            get: { Double(studio.settings.steps ?? defaultSteps) },
            set: { let n = Int($0.rounded()); studio.settings.steps = n == defaultSteps ? nil : n })
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                LabelWithInfo("Шаги", info: "Количество итераций очистки шума. У каждой модели своё оптимальное значение (у turbo/distilled моделей — 4–16, у базовых — 30–50). Больше шагов — чуть больше деталей, но дольше. Каждый шаг виден в ленте под холстом.")
                Spacer()
                if studio.settings.steps != nil {
                    Button("Авто") { studio.settings.steps = nil }
                        .buttonStyle(.link)
                        .font(.caption)
                }
                Text("\(studio.effectiveSteps)")
                    .monospacedDigit()
                    .foregroundStyle(studio.settings.steps == nil ? .secondary : .primary)
            }
            // No `step:` here or in the other sliders: a stepped NSSlider draws tick marks and, like the
            // segmented control, reports a minimum width that can exceed the column. Snapping is in the binding.
            Slider(value: value, in: 1...Double(upper))
                .labelsHidden()
        }
    }
}

private struct SeedRow: View {
    @Environment(Studio.self) private var studio

    var body: some View {
        @Bindable var studio = studio
        LabeledContent {
            HStack(spacing: 6) {
                TextField("Seed", value: $studio.settings.seed, format: .number.grouping(.never))
                    .labelsHidden()
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 110)
                    .disabled(studio.settings.randomSeed)
                    .monospacedDigit()
                Button {
                    studio.settings.seed = Int.random(in: 1...999_999_999)
                } label: {
                    Image(systemName: "dice")
                }
                .buttonStyle(.borderless)
                .help("Новый seed")
                Toggle("Случайный", isOn: $studio.settings.randomSeed)
                    .toggleStyle(.button)
                    .controlSize(.small)
                    .help("Новый случайный seed при каждом запуске")
            }
        } label: {
            LabelWithInfo("Seed", info: "Начальный шум. Одинаковые seed и параметры дают одинаковое изображение — зафиксируйте seed, чтобы менять промпт и сравнивать результат.")
        }
    }
}

/// Technical generation options; shown in Settings → «Генерация».
struct AdvancedRows: View {
    @Environment(Studio.self) private var studio
    let caps: FamilyCaps?

    var body: some View {
        @Bindable var studio = studio
        if caps?.supportsGuidance == true {
            let value = Binding<Double>(
                get: { studio.settings.guidance ?? 3.5 },
                set: { studio.settings.guidance = ($0 * 2).rounded() / 2 })
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    LabelWithInfo("Guidance", info: "Насколько строго следовать промпту (CFG). «Авто» — значение по умолчанию для модели. Выше — точнее и контрастнее, но с риском пересвета и артефактов.")
                    Spacer()
                    if studio.settings.guidance != nil {
                        Button("Авто") { studio.settings.guidance = nil }.buttonStyle(.link).font(.caption)
                        Text(String(format: "%.1f", value.wrappedValue)).monospacedDigit()
                    } else {
                        Text("Авто").foregroundStyle(.secondary)
                    }
                }
                Slider(value: value, in: 1...10)
                    .labelsHidden()
            }
        }
        VStack(alignment: .leading, spacing: 6) {
            LabelWithInfo("Память", info: "Экономия — ограничивает кэш MLX, декодирует изображение по частям и выгружает модель сразу после шагов (mflux --low-ram): медленнее, но надёжнее на 16 ГБ. Скорость — максимум кэша. Авто включает экономию, когда оценка пика близка к пределу памяти.")
            Picker("Память", selection: $studio.settings.memoryMode) {
                ForEach(MemoryMode.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
        }
        LabeledContent {
            Picker("", selection: $studio.settings.precision) {
                ForEach(Precision.allCases) { Text($0.title).tag($0) }
            }
            .labelsHidden()
            .frame(width: 120)
            .disabled(caps?.computePrecision == false)
        } label: {
            LabelWithInfo("Точность", info: "Формат вычислений внутри attention и MLP. На M1/M2 bfloat16 эмулируется, а float16 быстрее (на M2 Pro ≈ +27%), поэтому «Авто» выбирает float16 там, где модель это поддерживает. На M3 и новее разница мала. Изображение при той же seed может чуть отличаться.")
        }
        LabeledContent {
            Picker("", selection: $studio.settings.previewEvery) {
                Text("Каждый шаг").tag(1)
                Text("Каждый 2-й").tag(2)
                Text("Каждый 4-й").tag(4)
                Text("Выкл").tag(0)
            }
            .labelsHidden()
            .frame(width: 130)
        } label: {
            LabelWithInfo("Превью", info: "Как часто показывать промежуточный результат. На каждом шаге движок оценивает, каким будет чистое изображение (x̂₀), и декодирует его. Это стоит ~0.5 с на шаг; «Выкл» — максимальная скорость.")
        }
        Toggle(isOn: $studio.settings.previewFull) {
            LabelWithInfo("Превью в полном разрешении", info: "По умолчанию превью декодируется в половинном разрешении — это в 4 раза быстрее. Полное разрешение показывает мелкие детали, но замедляет каждый шаг.")
        }
        .disabled(studio.settings.previewEvery == 0)
    }
}

private struct AspectPicker: View {
    @Binding var selection: Aspect
    let hasSource: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            LabelWithInfo("Формат", info: "Соотношение сторон. Общая площадь задаётся качеством, поэтому у широких кадров меньше высота. «Исх.» берёт пропорции исходного изображения.")
            HStack(spacing: 4) {
                ForEach(Aspect.presets + (hasSource ? [.source] : [])) { aspect in
                    Button { selection = aspect } label: {
                        VStack(spacing: 3) {
                            shape(for: aspect)
                                .frame(width: 22, height: 22)
                            Text(aspect == .source ? String(localized: "Исх.") : aspect.rawValue)
                                .font(.system(size: 9, weight: .medium))
                                .monospacedDigit()
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 5)
                        .background(selection == aspect ? Color.accentColor.opacity(0.18) : .clear,
                                    in: RoundedRectangle(cornerRadius: 7))
                        .foregroundStyle(selection == aspect ? Color.accentColor : .secondary)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help(aspect.title)
                }
            }
        }
    }

    @ViewBuilder
    private func shape(for aspect: Aspect) -> some View {
        if aspect == .source {
            Image(systemName: "photo").font(.system(size: 13))
        } else {
            let r = aspect.ratio
            let w = r >= 1 ? 20.0 : 20.0 * r
            let h = r >= 1 ? 20.0 / r : 20.0
            RoundedRectangle(cornerRadius: 2.5)
                .strokeBorder(lineWidth: 1.5)
                .frame(width: w, height: h)
        }
    }
}

/// Segmented control that always fits the offered width (segments share it equally, labels shrink if needed).
struct FittingSegments<Value: Hashable>: View {
    @Binding var selection: Value
    let options: [Value]
    let title: (Value) -> String

    var body: some View {
        HStack(spacing: 2) {
            ForEach(options, id: \.self) { option in
                let selected = option == selection
                Button { selection = option } label: {
                    Text(title(option))
                        .font(.callout)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 4)
                        .foregroundStyle(selected ? Color.white : .primary)
                        .background(selected ? Color.accentColor : .clear, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(2)
        .background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .animation(.snappy(duration: 0.15), value: selection)
    }
}
