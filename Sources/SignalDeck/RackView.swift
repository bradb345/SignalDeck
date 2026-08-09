import AVFoundation
import SwiftUI

/// The rack editor: an ordered list of inserts, each openable in its own AU editor window.
struct RackView: View {
    @Bindable var controller: SignalDeckController

    @State private var catalog: [(manufacturer: String, entries: [AudioUnitCatalog.Entry])] = []
    @State private var isPresentingSaveSheet = false
    @State private var newRackName = ""

    var body: some View {
        VStack(spacing: 0) {
            rackToolbar
            Divider()
            slotList
            Divider()
            footer
        }
        .frame(minWidth: 420, minHeight: 480)
        .onAppear { catalog = AudioUnitCatalog.groupedByManufacturer() }
        .sheet(isPresented: $isPresentingSaveSheet) { saveSheet }
    }

    // MARK: - Toolbar

    private var rackToolbar: some View {
        HStack {
            Menu {
                Section("Factory") {
                    ForEach(FactoryRacks.all) { snapshot in
                        Button(snapshot.name) {
                            Task { await controller.loadRack(snapshot) }
                        }
                    }
                }
                if !controller.store.userRacks.isEmpty {
                    Section("Saved") {
                        ForEach(controller.store.userRacks) { snapshot in
                            Button(snapshot.name) {
                                Task { await controller.loadRack(snapshot) }
                            }
                        }
                    }
                }
            } label: {
                Label(controller.rack.name, systemImage: "rectangle.stack")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()

            Spacer()

            Button {
                newRackName = controller.rack.name
                isPresentingSaveSheet = true
            } label: {
                Label("Save As…", systemImage: "square.and.arrow.down")
            }
            .buttonStyle(.borderless)
        }
        .padding(12)
    }

    // MARK: - Slots

    private var slotList: some View {
        List {
            ForEach(controller.rack.slots) { slot in
                SlotRow(slot: slot) {
                    AudioUnitWindowController.shared.show(slot)
                } onRemove: {
                    controller.removeEffect(slot)
                } onBypassChanged: {
                    controller.persistCurrentRack()
                }
            }
            .onMove { source, destination in
                controller.moveEffects(from: source, to: destination)
            }

            if controller.rack.slots.isEmpty {
                ContentUnavailableView(
                    "No effects",
                    systemImage: "waveform.path",
                    description: Text("Audio passes through untouched. Add an Audio Unit below.")
                )
                .listRowSeparator(.hidden)
            }
        }
        .listStyle(.inset)
    }

    // MARK: - Footer

    private var footer: some View {
        VStack(spacing: 10) {
            SignalFlowMeters(
                inputLevels: controller.inputLevels,
                outputLevels: controller.outputLevels,
                isActive: controller.isActive
            )

            HStack {
                Menu {
                    ForEach(catalog, id: \.manufacturer) { group in
                        Section(group.manufacturer) {
                            ForEach(group.entries) { entry in
                                Button(entry.name) {
                                    Task { await controller.addEffect(entry) }
                                }
                            }
                        }
                    }
                } label: {
                    Label("Add Effect", systemImage: "plus")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()

                Spacer()

                Text("Signal flows top to bottom")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 10) {
                Image(systemName: "speaker.wave.2")
                    .foregroundStyle(.secondary)
                Slider(
                    value: Binding(
                        get: { Double(controller.outputGainDB) },
                        set: { controller.outputGainDB = Float($0) }
                    ),
                    in: -24...12
                ) {
                    Text("Output trim")
                }
                .labelsHidden()
                Text(String(format: "%+.1f dB", controller.outputGainDB))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(width: 60, alignment: .trailing)
            }
        }
        .padding(12)
    }

    // MARK: - Save sheet

    private var saveSheet: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Save Rack").font(.headline)
            TextField("Name", text: $newRackName)
                .textFieldStyle(.roundedBorder)
                .frame(width: 260)
            Text("Saves every effect in order, including each plugin's own editor state.")
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Cancel") { isPresentingSaveSheet = false }
                Button("Save") {
                    controller.saveCurrentRack(as: newRackName)
                    isPresentingSaveSheet = false
                }
                .keyboardShortcut(.defaultAction)
                .disabled(newRackName.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
    }
}

// MARK: - Row

private struct SlotRow: View {
    @Bindable var slot: EffectSlot
    let onOpen: () -> Void
    let onRemove: () -> Void
    let onBypassChanged: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "line.3.horizontal")
                .foregroundStyle(.tertiary)
                .font(.caption)

            VStack(alignment: .leading, spacing: 1) {
                Text(slot.displayName)
                    .fontWeight(.medium)
                    .foregroundStyle(slot.isBypassed ? .secondary : .primary)
                Text(slot.manufacturer)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Toggle("Bypass", isOn: Binding(
                get: { slot.isBypassed },
                set: { slot.isBypassed = $0; onBypassChanged() }
            ))
            .toggleStyle(.button)
            .labelsHidden()
            .help(slot.isBypassed ? "Bypassed" : "Active")

            Button(action: onOpen) {
                Image(systemName: "slider.horizontal.below.rectangle")
            }
            .buttonStyle(.borderless)
            .help("Open editor")

            Button(action: onRemove) {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .help("Remove from rack")
        }
        .padding(.vertical, 4)
        .opacity(slot.isBypassed ? 0.6 : 1)
    }
}
