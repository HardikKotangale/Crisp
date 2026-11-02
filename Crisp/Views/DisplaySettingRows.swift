import SwiftUI

/// Windows-style Scale under a display's other sliders: larger text and icons, still
/// sharp. Stops at the steps the display can really do, and commits on release, because
/// each one is a mode switch and the screen blinks. Hidden when there are no steps.
struct DisplayScaleSliderView: View {
    @ObservedObject var display: DisplayInfo
    // Worked out when the mode changes, not in body: a brightness drag re-renders this
    // view every tick and the mode list runs to hundreds.
    @State private var scales: [DisplayScale] = []
    @State private var position = 0.0
    @State private var isDragging = false
    @State private var isSwitching = false

    private var shown: DisplayScale? {
        scales.indices.contains(Int(position)) ? scales[Int(position)] : nil
    }

    var body: some View {
        // A stack, not a Group: a modifier on a Group goes to its children, and with none
        // yet the task would never run to create one.
        VStack(spacing: 0) {
            if scales.count > 1 {
                HStack(spacing: 8) {
                    BrightnessStepButton(systemName: "textformat.size.smaller") { step(-1) }

                    Slider(value: $position, in: 0...Double(scales.count - 1), step: 1) { editing in
                        isDragging = editing
                        if !editing { commit() }
                    }
                    .controlSize(.small)
                    .disabled(isSwitching)
                    .accessibilityLabel("Text size")
                    .accessibilityValue("\(shown?.percent ?? 100)%")

                    BrightnessStepButton(systemName: "textformat.size.larger") { step(1) }

                    Text(verbatim: "\(shown?.percent ?? 100)%")
                        .font(.caption.monospacedDigit())
                        .foregroundColor(.secondary)
                        .frame(width: 36, alignment: .trailing)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 4)
                .help("Text size: makes text, icons and windows larger on this display. They stay sharp.")
            }
        }
        .task(id: "\(display.currentDisplayMode?.id ?? 0)/\(display.availableModes.count)") { load() }
    }

    private func load() {
        guard !isDragging, !isSwitching else { return }
        let info = DisplayScaleService.options(for: display)
        scales = info?.scales ?? []
        // Nearest step, for a size picked in the Resolution list that no step names.
        let current = info?.current ?? 100
        position = Double(scales.indices.min { abs(scales[$0].percent - current) < abs(scales[$1].percent - current) } ?? 0)
    }

    private func step(_ delta: Int) {
        position = max(0, min(Double(scales.count - 1), position + Double(delta)))
        commit()
    }

    private func commit() {
        guard let scale = shown, !isSwitching else { return }
        isSwitching = true
        Task {
            _ = await DisplayScaleService.apply(scale, to: display)
            isSwitching = false
            load()
        }
    }
}

/// Names an external display (#253). macOS numbers identical monitors itself, so this is
/// how to tell them apart; blank goes back to its name.
struct DisplayNameRow: View {
    @ObservedObject var display: DisplayInfo
    @State private var text = ""
    @State private var isHovered = false
    @FocusState private var focused: Bool

    var body: some View {
        if !display.isBuiltin {
            HStack {
                MenuItemIcon(systemName: "pencil", color: .gray, active: false)
                Text("Display Name")
                    .font(.body)
                Spacer()
                // Explicit placeholder: macOS drops a plain field's own once focused.
                ZStack(alignment: .trailing) {
                    if text.isEmpty {
                        Text(verbatim: display.systemName)
                            .font(.body)
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                            .allowsHitTesting(false)
                    }
                    TextField("", text: $text)
                        .textFieldStyle(.plain)
                        .font(.body)
                        .multilineTextAlignment(.trailing)
                        .focused($focused)
                        .onSubmit(save)
                }
                .frame(maxWidth: 150)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 3)
            .menuRowHover(isHovered)
            .onHover { isHovered = $0 }
            .onAppear(perform: load)
            .onChange(of: focused) { _, isFocused in
                if !isFocused { save() }
            }
        }
    }

    private func load() {
        text = SettingsService.shared.displayName(forDisplayUUID: display.displayUUID) ?? ""
    }

    private func save() {
        SettingsService.shared.setDisplayName(text, forDisplayUUID: display.displayUUID)
        display.applyName()
        load()
    }
}

/// Shows and switches the signal's color mode (#249). Hidden when there is nothing to
/// pick: the built-in, Intel, or a display with one mode.
struct ColorModeRow: View {
    let display: DisplayInfo
    @State private var modes: [DisplayColorMode] = []
    @State private var current: UInt32?
    @State private var isSwitching = false
    @State private var isHovered = false

    var body: some View {
        // A stack, not a Group: see DisplayScaleSliderView.
        VStack(spacing: 0) {
            if modes.count > 1 {
                let names = DisplayColorMode.names(of: modes)
                HStack {
                    MenuItemIcon(systemName: "circle.lefthalf.filled", color: .purple, active: false)
                    Text("Color Mode")
                        .font(.body)
                    Spacer()
                    Menu {
                        ForEach(modes) { mode in
                            Button {
                                select(mode)
                            } label: {
                                if mode.id == current {
                                    Label(names[mode.id] ?? mode.label, systemImage: "checkmark")
                                } else {
                                    Text(verbatim: names[mode.id] ?? mode.label)
                                }
                            }
                        }
                    } label: {
                        Text(verbatim: current.flatMap { names[$0] } ?? "")
                            .font(.body)
                            .foregroundColor(.secondary)
                    }
                    .buttonStyle(.plain)
                    .fixedSize()
                    .disabled(isSwitching)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 3)
                .menuRowHover(isHovered)
                .onHover { isHovered = $0 }
            }
        }
        .task { await reload() }
        // macOS picks again after a reconnect or a resolution change.
        .onReceive(NotificationCenter.default.publisher(for: .crispPanelDidOpen)) { _ in
            Task { await reload() }
        }
    }

    private func reload() async {
        let displayID = display.displayID
        let info = await Task.detached { ColorModeService.modes(for: displayID) }.value
        modes = info?.modes ?? []
        current = info?.current
    }

    private func select(_ mode: DisplayColorMode) {
        guard mode.id != current else { return }
        isSwitching = true
        let displayID = display.displayID
        Task {
            _ = await Task.detached { ColorModeService.set(mode.id, for: displayID) }.value
            await reload()
            isSwitching = false
        }
    }
}
