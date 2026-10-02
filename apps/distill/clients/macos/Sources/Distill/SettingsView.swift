import SwiftUI
import DistillKit

struct SettingsView: View {
    @EnvironmentObject var engine: AppModel
    @State private var showAdvanced = false
    @State private var extraTools = ""
    @State private var editingVault: VaultProfile?

    private let presets: [(String, Int)] = [("5 min", 5), ("15 min", 15), ("1 hour", 60), ("Daily", 1440)]

    var body: some View {
        Scrolling {
            VStack(alignment: .leading, spacing: 30) {
                Text("Settings").font(Theme.display(30))
                vaults
                schedule
                model
                advanced
                status
            }
            .padding(.horizontal, 40).padding(.top, 40).padding(.bottom, 32)
        }
        .frame(minWidth: 640, minHeight: 640)
        .background(Theme.window)
        .foregroundStyle(Theme.ink)
        .ignoresSafeArea()
        .sheet(item: $editingVault) { vault in
            VaultEditor(vault: vault) { editingVault = nil }.environmentObject(engine)
        }
    }

    // MARK: Vaults

    private var vaults: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Vaults").font(Theme.body(14, .bold))
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: 3), spacing: 12) {
                ForEach(engine.settings.vaults) { vault in
                    let active = vault.path == engine.activeVault?.path
                    let chip = VaultChip.colors(for: vault)
                    Button { engine.settings.activeVaultPath = vault.path } label: {
                        VStack(alignment: .leading, spacing: 12) {
                            HStack {
                                Tile(text: String(vault.name.prefix(1)).uppercased(), fill: chip.0, ink: chip.1, size: 34, display: true)
                                Spacer()
                                if !VaultProfile.isVault(vault.path) {
                                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Theme.peachInk)
                                        .help("Missing .claude-obsidian.json")
                                        .padding(.trailing, 30) // clear of the edit button
                                }
                            }
                            VStack(alignment: .leading, spacing: 3) {
                                Text(vault.name).font(Theme.body(14, .semibold))
                                Text(queueLabel(vault)).font(Theme.body(12)).foregroundStyle(Theme.muted).lineLimit(1)
                            }
                        }
                        .padding(16)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .card(18, selected: active)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .contextMenu {
                        Button("Edit…") { editingVault = vault }
                        Button("Remove", role: .destructive) { remove(vault) }
                    }
                    .overlay(alignment: .topTrailing) {
                        Button { editingVault = vault } label: {
                            Image(systemName: "ellipsis").foregroundStyle(Theme.muted).frame(width: 28, height: 28)
                        }
                        .buttonStyle(.plain).padding(8).help("Edit vault")
                    }
                }
                Button { VaultPicker.addVault(engine: engine) } label: {
                    VStack(spacing: 4) {
                        Image(systemName: "plus").font(.system(size: 18))
                        Text("Add vault").font(Theme.body(13, .semibold))
                    }
                    .foregroundStyle(Theme.primary)
                    .frame(maxWidth: .infinity, minHeight: 112)
                    .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(Color(hex: 0xD6D3CC), style: StrokeStyle(lineWidth: 1.5, dash: [6, 5])))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func queueLabel(_ vault: VaultProfile) -> String {
        vault.queueURL.standardizedFileURL.path == vault.inboxURL.standardizedFileURL.path
            ? "Queue: vault inbox"
            : "Queue: \(vault.queueURL.lastPathComponent)"
    }

    private func remove(_ vault: VaultProfile) {
        engine.settings.vaults.removeAll { $0.path == vault.path }
        if engine.settings.activeVaultPath == vault.path {
            engine.settings.activeVaultPath = engine.settings.vaults.first?.path
        }
    }

    // MARK: Schedule

    private var schedule: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Batch every").font(Theme.body(14, .bold))
                Spacer()
                Text("Automatic").font(Theme.body(13)).foregroundStyle(Theme.muted)
                Toggle("Automatic", isOn: $engine.settings.autoProcessEnabled)
                    .toggleStyle(.switch).labelsHidden().tint(Theme.primary)
            }
            HStack(spacing: 12) {
                IntervalCounter(label: "days", value: intervalPart(.days), range: BatchInterval.Part.days.range)
                IntervalCounter(label: "hours", value: intervalPart(.hours), range: BatchInterval.Part.hours.range)
                IntervalCounter(label: "minutes", value: intervalPart(.minutes), range: BatchInterval.Part.minutes.range)
            }
            HStack(spacing: 8) {
                ForEach(presets, id: \.1) { preset in
                    chip(preset.0, selected: engine.settings.batchIntervalMinutes == preset.1) {
                        engine.settings.batchIntervalMinutes = preset.1
                    }
                }
                if !presets.contains(where: { $0.1 == engine.settings.batchIntervalMinutes }) {
                    chip(BatchInterval(totalMinutes: engine.settings.batchIntervalMinutes).description, selected: true) {}
                }
                Spacer()
                Menu("Wait \(engine.settings.settleSeconds)s for files to settle") {
                    ForEach([0, 5, 10, 30, 60], id: \.self) { s in
                        Button("\(s) seconds") { engine.settings.settleSeconds = s }
                    }
                }
                .menuStyle(.borderlessButton).fixedSize()
                .font(Theme.body(12)).foregroundStyle(Theme.muted)
            }
        }
    }

    private func chip(_ title: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).font(Theme.body(13, .semibold))
                .padding(.horizontal, 14).frame(height: 30)
                .foregroundStyle(selected ? Color.white : Theme.ink)
                .background(Capsule().fill(selected ? Theme.primary : Theme.panel))
        }
        .buttonStyle(.plain)
    }

    private func intervalPart(_ part: BatchInterval.Part) -> Binding<Int> {
        Binding(
            get: { BatchInterval(totalMinutes: engine.settings.batchIntervalMinutes)[part] },
            set: { value in
                var interval = BatchInterval(totalMinutes: engine.settings.batchIntervalMinutes)
                interval[part] = value
                engine.settings.batchIntervalMinutes = interval.totalMinutes
            })
    }

    // MARK: Model

    private var model: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Model").font(Theme.body(14, .bold))
            HStack(spacing: 12) {
                modelCard("haiku", "Haiku", "Fastest and lightest", "bolt", Theme.skyTint, Theme.skyInk)
                modelCard("sonnet", "Sonnet", "Balanced, recommended", "drop", Theme.limeTint, Theme.limeInk)
                modelCard("opus", "Opus", "Deepest synthesis", "star", Theme.peachTint, Theme.peachInk)
            }
            if !["haiku", "sonnet", "opus"].contains(engine.settings.model) {
                Text("Using pinned model \(engine.settings.model)").font(Theme.body(12)).foregroundStyle(Theme.muted)
            }
        }
    }

    private func modelCard(_ id: String, _ name: String, _ note: String, _ icon: String, _ fill: Color, _ ink: Color) -> some View {
        let selected = engine.settings.model == id
        return Button { engine.settings.model = id } label: {
            VStack(alignment: .leading, spacing: 10) {
                Image(systemName: icon).font(.system(size: 15, weight: .semibold)).foregroundStyle(ink)
                    .frame(width: 34, height: 34).background(Circle().fill(fill))
                VStack(alignment: .leading, spacing: 3) {
                    Text(name).font(Theme.body(15, .bold))
                    Text(note).font(Theme.body(12)).foregroundStyle(Theme.muted)
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .card(18, selected: selected)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: Advanced

    private var advanced: some View {
        DisclosureGroup(isExpanded: $showAdvanced) {
            VStack(alignment: .leading, spacing: 12) {
                LabeledField(title: "Specific model") {
                    Picker("", selection: $engine.settings.model) {
                        ForEach(ModelChoice.presets, id: \.id) { Text($0.label).tag($0.id) }
                        if !ModelChoice.presets.contains(where: { $0.id == engine.settings.model }) {
                            Text(engine.settings.model).tag(engine.settings.model)
                        }
                    }
                    .labelsHidden()
                }
                LabeledField(title: "Custom model ID") { TextField("", text: $engine.settings.model).textFieldStyle(.roundedBorder) }
                PathField(title: "claude CLI", path: $engine.settings.claudePath, directory: false)
                PathField(title: "python3", path: $engine.settings.pythonPath, directory: false)
                PathField(title: "node (empty = find it: nvm, Homebrew, /usr/local, /usr/bin)", path: nodePath, directory: false)
                PathField(title: "Product root", path: $engine.settings.productRoot, directory: true)
                LabeledField(title: "Extra allowed tools (one rule per line)") {
                    TextEditor(text: $extraTools)
                        .font(.system(size: 12, design: .monospaced))
                        .frame(minHeight: 60)
                        .scrollContentBackground(.hidden)
                        .padding(6)
                        .background(RoundedRectangle(cornerRadius: 8).fill(Theme.panel))
                        .onAppear { extraTools = engine.settings.extraAllowedTools.joined(separator: "\n") }
                        .onChange(of: extraTools) {
                            engine.settings.extraAllowedTools = extraTools
                                .split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
                        }
                }
            }
            .padding(.top, 12)
        } label: {
            Text("Advanced").font(Theme.body(14, .bold))
        }
        .tint(Theme.primary)
    }

    private var nodePath: Binding<String> {
        Binding(get: { engine.settings.nodePath ?? "" },
                set: { engine.settings.nodePath = $0.trimmingCharacters(in: .whitespaces).isEmpty ? nil : $0 })
    }

    @ViewBuilder private var status: some View {
        let problems = engine.problems
        if case .unreachable(let problem) = engine.connection {
            VStack(alignment: .leading, spacing: 8) {
                Label(problem, systemImage: "bolt.horizontal.circle.fill")
                    .font(Theme.body(13)).foregroundStyle(Theme.peachInk).textSelection(.enabled)
                SoftButton(title: "Retry") { engine.connect() }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 16).fill(Color(hex: 0xFFF4EE)))
        } else if !problems.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(problems, id: \.description) { problem in
                    Label(problem.description, systemImage: "exclamationmark.triangle.fill")
                        .font(Theme.body(13)).foregroundStyle(Theme.peachInk)
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 16).fill(Color(hex: 0xFFF4EE)))
        }
    }
}

/// −  N  + counter for one unit of the batch interval.
struct IntervalCounter: View {
    let label: String
    @Binding var value: Int
    let range: ClosedRange<Int>

    var body: some View {
        HStack(spacing: 6) {
            round("minus") { value = max(range.lowerBound, value - 1) }
            VStack(spacing: 1) {
                TextField("", value: $value, format: .number)
                    .textFieldStyle(.plain)
                    .multilineTextAlignment(.center)
                    .font(Theme.display(28))
                    .frame(width: 56)
                Text(label).font(Theme.body(12)).foregroundStyle(Theme.muted)
            }
            .frame(maxWidth: .infinity)
            round("plus") { value = min(range.upperBound, value + 1) }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 16).fill(Theme.panel))
    }

    private func round(_ icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon).font(.system(size: 12, weight: .bold))
                .frame(width: 32, height: 32)
                .background(Circle().fill(Color.white).shadow(color: .black.opacity(0.1), radius: 1, y: 1))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(icon == "plus" ? "More \(label)" : "Fewer \(label)")
    }
}

struct LabeledField<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(Theme.body(12, .semibold)).foregroundStyle(Theme.muted)
            content
        }
    }
}

struct PathField: View {
    let title: String
    @Binding var path: String
    let directory: Bool

    var body: some View {
        LabeledField(title: title) {
            HStack {
                TextField("", text: $path).textFieldStyle(.roundedBorder)
                Button("Choose…") {
                    let panel = NSOpenPanel()
                    panel.canChooseDirectories = directory
                    panel.canChooseFiles = !directory
                    panel.showsHiddenFiles = true
                    if panel.runModal() == .OK, let url = panel.url { path = url.path }
                }
            }
        }
    }
}

struct VaultEditor: View {
    @EnvironmentObject var engine: AppModel
    @State var vault: VaultProfile
    var done: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(vault.name).font(Theme.display(22))
            Text(vault.path).font(Theme.body(12)).foregroundStyle(Theme.muted).textSelection(.enabled)
            LabeledField(title: "Queue folder") {
                HStack {
                    Text(vault.queueDirectory).font(Theme.body(12)).lineLimit(1).truncationMode(.middle)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Button("Change…") {
                        if let url = VaultPicker.chooseDirectory(title: "Choose the queue folder for \(vault.name)") {
                            vault.queueDirectory = url.standardizedFileURL.path
                        }
                    }
                }
            }
            Button("Use the vault's inbox/ as the queue") { vault.queueDirectory = vault.inboxURL.path }
                .buttonStyle(.link)
            HStack {
                Button("Remove vault", role: .destructive) {
                    engine.settings.vaults.removeAll { $0.path == vault.path }
                    if engine.settings.activeVaultPath == vault.path {
                        engine.settings.activeVaultPath = engine.settings.vaults.first?.path
                    }
                    done()
                }
                .buttonStyle(.plain).foregroundStyle(Theme.peachInk)
                Spacer()
                SoftButton(title: "Cancel", action: done)
                PrimaryButton(title: "Save") { engine.settings.upsert(vault); done() }
            }
        }
        .padding(28)
        .frame(width: 480)
        .foregroundStyle(Theme.ink)
    }
}
