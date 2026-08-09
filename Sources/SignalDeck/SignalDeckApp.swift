import SwiftUI

@main
struct SignalDeckApp: App {
    @State private var controller = SignalDeckController()

    var body: some Scene {
        MenuBarExtra {
            MenuPanel(controller: controller)
        } label: {
            Image(systemName: controller.isActive ? "waveform.badge.mic" : "waveform")
                .symbolRenderingMode(.hierarchical)
        }
        .menuBarExtraStyle(.window)

        // The rack editor is a real window, not a popover. A popover dismisses itself the
        // moment you click into an Audio Unit's editor window, which makes rack editing
        // unusable — this is why SoundSource uses a window too.
        Window("SignalDeck Rack", id: RackWindow.id) {
            RackView(controller: controller)
        }
        .defaultSize(width: 420, height: 560)
        .windowResizability(.contentSize)
    }
}

enum RackWindow {
    static let id = "rack"
}

struct MenuPanel: View {
    @Bindable var controller: SignalDeckController
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            Divider()
            targetPicker

            HStack {
                Text("Rack").font(.subheadline).fontWeight(.medium)
                Spacer()
                Text(controller.rack.name)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Button {
                openWindow(id: RackWindow.id)
                NSApp.activate(ignoringOtherApps: true)
            } label: {
                Label("Edit Effects…", systemImage: "slider.horizontal.3")
                    .frame(maxWidth: .infinity)
            }

            SignalFlowMeters(
                inputLevels: controller.inputLevels,
                outputLevels: controller.outputLevels,
                isActive: controller.isActive
            )

            if controller.isActive {
                meters
            }

            if let error = controller.errorMessage {
                errorBanner(error)
            }

            Divider()

            HStack {
                Text(controller.statusMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer()
                Button("Quit") { controller.quit() }
                    .buttonStyle(.borderless)
                    .font(.caption)
            }
        }
        .padding(16)
        .frame(width: 320)
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("SignalDeck").font(.headline)
                Text("Per-app audio effects")
                    .font(.caption).foregroundStyle(.secondary)
                // Selectable so it can be pasted straight into a bug report.
                Text(AppVersion.display)
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.tertiary)
                    .textSelection(.enabled)
                    .help("Version, build, and the commit this was built from")
            }
            Spacer()
            Toggle("", isOn: Binding(
                get: { controller.isActive },
                set: { controller.setActive($0) }
            ))
            .toggleStyle(.switch)
            .labelsHidden()
            .disabled(controller.selectedApp == nil)
        }
    }

    private var targetPicker: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Source").font(.subheadline).fontWeight(.medium)
                Spacer()
                Button { controller.refreshApps() } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .help("Rescan running apps")
            }

            Picker("", selection: $controller.selectedApp) {
                Text("None").tag(Optional<AudioProcess>.none)
                ForEach(controller.availableApps) { app in
                    HStack {
                        if let icon = app.icon {
                            Image(nsImage: icon).resizable().frame(width: 16, height: 16)
                        }
                        Text(app.isPlayingAudio ? "\(app.name) ●" : app.name)
                    }
                    .tag(Optional(app))
                }
            }
            .labelsHidden()
        }
    }

    private var meters: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Gain reduction").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Text(String(format: "%.1f dB", -abs(controller.gainReductionDB)))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            ProgressView(value: Double(min(abs(controller.gainReductionDB), 20)), total: 20)
                .progressViewStyle(.linear)

            if controller.rackLatencyMilliseconds > 1 {
                // Worth surfacing: rack latency shifts audio relative to Plex's video.
                Text(String(format: "Rack latency %.1f ms", controller.rackLatencyMilliseconds))
                    .font(.caption2)
                    .foregroundStyle(controller.rackLatencyMilliseconds > 40 ? .orange : .secondary)
            }
        }
    }

    private func errorBanner(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .font(.caption)
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
            if !controller.hasAudioCapturePermission {
                Button("Open Privacy Settings…") { controller.openPrivacySettings() }
                    .buttonStyle(.borderless)
                    .font(.caption)
            }
        }
    }
}
