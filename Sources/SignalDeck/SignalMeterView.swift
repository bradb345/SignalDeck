import SwiftUI

/// A stereo level meter: an RMS bar with a peak line riding on top of it, per channel.
///
/// The point of this view is diagnostic before it is decorative — "is audio reaching SignalDeck,
/// and is SignalDeck putting audio back out?" is the first question to ask when nothing is
/// audible, and the answer is otherwise invisible.
struct SignalMeterView: View {

    let title: String
    let levels: AudioLevels
    /// Draw greyed out when the pipeline isn't running.
    var isActive: Bool = true
    /// The dB ruler is worth showing once per group, not once per meter.
    var showsScale: Bool = true

    /// Bottom of the scale. -60 dBFS keeps quiet dialogue visible without amplifying noise.
    private let floorDB: Float = -60

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            header
            VStack(spacing: 2) {
                bar(rms: levels.rmsLeft, peak: levels.peakLeft)
                bar(rms: levels.rmsRight, peak: levels.peakRight)
            }
            if showsScale { scale }
        }
    }

    private var header: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(indicatorColor)
                .frame(width: 6, height: 6)
                .accessibilityHidden(true)
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            Text(readout)
                .font(.caption.monospacedDigit())
                .foregroundStyle(isClipping ? .orange : .secondary)
        }
    }

    private var readout: String {
        guard isActive else { return "—" }
        let db = AudioLevels.decibels(levels.peak, floor: floorDB)
        guard db > floorDB else { return "−∞ dB" }
        // `+ 0` collapses -0.0 to 0.0, otherwise a peak just under full scale reads "-0 dB".
        return String(format: "%.0f dB", db.rounded() + 0)
    }

    private var indicatorColor: Color {
        guard isActive else { return .secondary.opacity(0.4) }
        return levels.hasSignal ? .green : .secondary.opacity(0.5)
    }

    private var isClipping: Bool { isActive && levels.peak >= 0.999 }

    private func bar(rms: Float, peak: Float) -> some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            let rmsFraction = fraction(rms)
            let peakFraction = fraction(peak)

            ZStack(alignment: .leading) {
                Capsule()
                    .fill(.quaternary)

                // The gradient is laid out across the *full* bar and then masked, so a given dB
                // level always gets the same colour. Sizing the gradient to the fill instead
                // squeezes the whole ramp into it and paints quiet signals orange.
                Capsule()
                    .fill(fillStyle)
                    .frame(width: width)
                    .mask(alignment: .leading) {
                        Capsule().frame(width: max(0, width * CGFloat(rmsFraction)))
                    }

                if isActive, peakFraction > 0 {
                    Capsule()
                        .fill(peakColor(peak))
                        .frame(width: 2)
                        .offset(x: min(width - 2, max(0, width * CGFloat(peakFraction) - 1)))
                }
            }
        }
        .frame(height: 6)
        .animation(.linear(duration: 1.0 / 30.0), value: rms)
    }

    /// Colour stops pinned to dB positions rather than spread evenly, so "it went yellow" always
    /// means the same loudness.
    private var fillStyle: LinearGradient {
        guard isActive else {
            return LinearGradient(colors: [.secondary.opacity(0.3)],
                                  startPoint: .leading, endPoint: .trailing)
        }
        func stop(_ color: Color, at db: Float) -> Gradient.Stop {
            Gradient.Stop(color: color,
                          location: CGFloat(AudioLevels.fraction(ofDecibels: db, floor: floorDB)))
        }
        return LinearGradient(
            stops: [
                stop(.green, at: floorDB),
                stop(.green, at: -18),
                stop(.yellow, at: -9),
                stop(.orange, at: -3),
                stop(.red, at: 0)
            ],
            startPoint: .leading, endPoint: .trailing
        )
    }

    private func peakColor(_ peak: Float) -> Color {
        let db = AudioLevels.decibels(peak, floor: floorDB)
        if db >= -0.1 { return .red }
        if db >= -6 { return .orange }
        return .primary.opacity(0.6)
    }

    private func fraction(_ amplitude: Float) -> Float {
        guard isActive else { return 0 }
        return AudioLevels.fraction(ofDecibels: AudioLevels.decibels(amplitude, floor: floorDB),
                                    floor: floorDB)
    }

    /// Tick labels at the dB positions people actually reference.
    private var scale: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            ForEach([Float(-60), -40, -20, -6, 0], id: \.self) { db in
                let x = CGFloat(AudioLevels.fraction(ofDecibels: db, floor: floorDB)) * width
                Text(db == floorDB ? "−∞" : "\(Int(db))")
                    .font(.system(size: 8))
                    .foregroundStyle(.tertiary)
                    .fixedSize()
                    .position(x: min(max(x, 8), width - 8), y: 5)
            }
        }
        .frame(height: 10)
    }
}

/// Input and output meters stacked, which together read as a signal-flow diagram: if "In" moves
/// and "Out" doesn't, the rack is the problem; if neither moves, the tap is.
struct SignalFlowMeters: View {
    let inputLevels: AudioLevels
    let outputLevels: AudioLevels
    let isActive: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            SignalMeterView(title: "Input · from app", levels: inputLevels,
                            isActive: isActive, showsScale: false)
            SignalMeterView(title: "Output · to speakers", levels: outputLevels,
                            isActive: isActive, showsScale: true)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel)
    }

    private var accessibilityLabel: String {
        guard isActive else { return "Signal meters, inactive" }
        let input = AudioLevels.decibels(inputLevels.peak)
        let output = AudioLevels.decibels(outputLevels.peak)
        return String(format: "Input peak %.0f decibels, output peak %.0f decibels", input, output)
    }
}
