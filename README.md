# SignalDeck

A macOS menu bar app that captures the audio of a single application — Plex, or anything else
you pick — runs it through a chain of Audio Units you assemble yourself, and plays the result
out your default output device.

It exists to solve the dialogue-vs-explosion problem: whispered conversation you can't hear at
2am, followed by an action scene that wakes the house. Point SignalDeck at Plex, load the Night
Mode rack, and stop riding the volume knob.

Think of it as a narrowly-scoped SoundSource: one app, one effects chain, no mixer.

## Requirements

| | |
|---|---|
| **To run** | macOS 15.0 or later. macOS 26+ unlocks tap persistence (see below). |
| **To build** | Xcode 26 or Command Line Tools with the macOS 26 SDK (`xcode-select --install`). Full Xcode is not required. |
| **Hardware** | Apple Silicon or Intel — `package.sh` produces a universal binary. |

The macOS 26 SDK is needed even though the app runs on 15.0, because it compiles against
`CATapDescription.bundleIDs` and `isProcessRestoreEnabled` behind `if #available`.

## How it works

```
Plex ──► Core Audio process tap ──► private aggregate device
                                          │
                                    IOProc (real-time)
                                          │
                                    lock-free ring buffer
                                          │
                                    AVAudioSourceNode
                                          │
                                    your rack: AU → AU → AU
                                          │
                                    main mixer ──► default output
```

The tap is created with `muteBehavior = .mutedWhenTapped`, which silences Plex's own path to
the hardware while SignalDeck is reading it. Without that you'd hear both the raw and the
processed stream at once. This is also the main reason the app uses Core Audio process taps
rather than ScreenCaptureKit — SCK has no equivalent mute mechanism.

On **macOS 26+** the tap is additionally pinned by bundle ID with process restore enabled, so
it survives Plex quitting and relaunching. That's what makes it a persistent per-app setting
rather than a capture session you have to restart. On macOS 15 the app falls back to targeting
process IDs and re-taps when it notices the app restart.

## Build & run locally

```bash
git clone https://github.com/bradb345/SignalDeck.git
cd SignalDeck
./build.sh
open build/SignalDeck.app
```

`build.sh` compiles, assembles a `.app` bundle, and ad-hoc signs it. The bundle and signature
are both mandatory — TCC will not grant audio-capture permission to a bare executable.

SignalDeck has no Dock icon (`LSUIElement`). Look for the waveform in the menu bar.

## First run

1. Launch the app. A waveform icon appears in the menu bar.
2. Start playing something in Plex, so it shows up in the **Source** list with a ● marker.
3. Pick Plex from **Source** and flip the toggle on.
4. macOS prompts for permission. Approve it.
   If you miss the prompt, go to **System Settings → Privacy & Security → Screen & System
   Audio Recording** and enable SignalDeck, then toggle SignalDeck off and on again.
5. Click **Edit Effects…** to open the rack.

If Plex's audio goes silent instead of compressed, the tap is muting the app but the engine
isn't feeding output — check Console.app for `SignalDeck` messages.

## Using the rack

The rack window is an ordered list of Audio Units. Signal flows top to bottom.

- **Add Effect** — every effect AU installed on the machine, grouped by manufacturer. Apple
  ships about 23 (dynamics, EQs, filters, delays, reverbs); anything else you install shows up
  here too.
- **Drag to reorder**, toggle **bypass**, or open each unit's **own editor window** with the
  slider button. Units without a custom UI get CoreAudioKit's generated parameter view, so
  everything is editable.
- **Output trim** applies after the chain.
- **Save As…** stores the rack in `~/Library/Application Support/SignalDeck/Racks/`. Each
  effect's full opaque state is saved, so third-party plugin editors round-trip completely.

The live rack, including unsaved tweaks, is restored on next launch.

### Factory racks

| Rack | Chain | For |
|---|---|---|
| **Night Mode** | Compressor → Limiter | Late-night watching. Hard clamp on loud action, +9 dB make-up so dialogue carries at low volume. |
| **Dialogue Boost** | Compressor → EQ (bypassed) → Limiter | Speech-forward. Faster, more aggressive, with an EQ ready for carving 2–4 kHz presence. |
| **Smooth** | Compressor → Limiter | Light levelling that keeps most of the original dynamics. |
| **Passthrough** | — | A/B against the untouched stream. |

**A note on the compressor:** `AUDynamicsProcessor` has no ratio parameter. Its compressor is
`Threshold` + `HeadRoom` — everything above the threshold is squeezed so peaks land roughly
`HeadRoom` dB above it, which means *smaller head room is harder compression*. Don't go
hunting for a ratio knob.

`ExpansionRatio` is a separate downward expander, and its stock default of 2:1 pushes quiet
dialogue *further down* — the opposite of what you want. Every factory rack pins it to 1.0.

Keep an eye on the **rack latency** readout in the menu. It's audio-only delay against Plex's
video, so stacking latent plugins will drift lip sync. Under ~40 ms is imperceptible.

## Installing on another Mac

**The honest summary:** there is no paid Apple Developer certificate on this project, so
released builds are ad-hoc signed and cannot be notarized. macOS will block them on first
launch on any machine that didn't build them. That's a one-time two-command fix, not a
permanent problem — but you should know it's coming.

### Option A — build on the target machine (recommended)

Cleanest path, no Gatekeeper friction at all, since a locally-built app was never quarantined.

```bash
xcode-select --install      # if the target Mac has no developer tools
git clone https://github.com/bradb345/SignalDeck.git
cd SignalDeck && ./build.sh
cp -R build/SignalDeck.app /Applications/
open /Applications/SignalDeck.app
```

### Option B — zip from GitHub Releases

Tag a release and let CI build it:

```bash
git tag v0.1.0 && git push origin v0.1.0
```

`.github/workflows/release.yml` builds a universal app and attaches the zip to the release.
You can also run the workflow manually from the Actions tab to get a build artifact without
tagging.

To build the zip yourself instead:

```bash
./package.sh          # → dist/SignalDeck-0.1.0.zip (+ .sha256)
```

On the target machine, after downloading and unzipping:

```bash
cp -R ~/Downloads/SignalDeck.app /Applications/
xattr -dr com.apple.quarantine /Applications/SignalDeck.app
open /Applications/SignalDeck.app
```

That `xattr` line is the important one. Without it macOS reports the app as damaged, and on
macOS 15+ the old right-click → Open bypass no longer works for unsigned apps — you'd have to
go to **System Settings → Privacy & Security** and click **Open Anyway** after a blocked
launch instead.

> Always transfer the app as a zip made by `ditto` (which `package.sh` uses). Plain `zip -r`
> mangles bundle symlinks and extended attributes, which invalidates the code signature.

### Option C — Developer ID (no friction)

With a paid Apple Developer account ($99/yr) the app opens anywhere with no warnings:

```bash
SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" ./package.sh
xcrun notarytool submit dist/SignalDeck-0.1.0.zip \
  --apple-id you@example.com --team-id TEAMID --password APP_SPECIFIC_PASSWORD --wait
xcrun stapler staple dist/SignalDeck.app
```

This also fixes the permission-reset annoyance below, since a Developer ID gives the app a
stable signing identity across rebuilds.

## Permissions

SignalDeck needs **Screen & System Audio Recording**. It records no screen content — that's
just the TCC category Apple files system-audio capture under. The Info.plist declares
`NSAudioCaptureUsageDescription`, without which the prompt never appears at all.

The app is deliberately **not sandboxed**. Process taps, private aggregate devices, and
enumerating other processes' audio objects don't work cleanly under the sandbox, and an app
that taps another app's audio can't ship on the Mac App Store regardless.

### Permission resets after every rebuild

TCC ties the grant to the app's code signature. Ad-hoc signing produces a new signature every
build, so macOS treats each rebuild as a different app and silently denies capture. If the
toggle stops working after you rebuild:

```bash
tccutil reset ScreenCapture com.bradbernard.SignalDeck
```

Then relaunch and approve again. If that doesn't clear it, remove SignalDeck manually from
System Settings → Privacy & Security → Screen & System Audio Recording and re-add it.
A Developer ID certificate (Option C) makes this go away.

## Project layout

```
Sources/SignalDeck/
  AudioProcessDiscovery.swift    Running apps → Core Audio process objects
  ProcessTapCapture.swift        Tap, private aggregate device, real-time IOProc
  AudioRingBuffer.swift          Lock-free SPSC bridge between the two audio threads
  AudioUnitCatalog.swift         Enumerates installed effect AUs
  Rack.swift                     Ordered inserts + snapshot/restore
  RackStore.swift                Saved racks on disk
  FactoryRacks.swift             Night Mode / Dialogue Boost / Smooth / Passthrough
  SignalDeckEngine.swift         AVAudioEngine graph, live re-patching, metering
  AudioUnitWindowController.swift  Hosts each AU's native editor window
  SignalDeckController.swift     Orchestration
  SignalDeckApp.swift            MenuBarExtra
  RackView.swift                 Rack editor window

Resources/Info.plist             NSAudioCaptureUsageDescription, LSUIElement
Resources/SignalDeck.entitlements
build.sh                         Dev build (arm64, ad-hoc signed)
package.sh                       Release build (universal, zipped)
```

## Known limitations

- Plex's audio is captured as a **stereo mixdown**. Multichannel sources are folded to stereo
  before the rack sees them.
- Switching output device (speakers → headphones) tears down and rebuilds the tap. Brief gap,
  rack state survives.
- Third-party AU hosting follows the standard host contract but has only been exercised with
  Apple's built-in units. If a plugin destabilises the app, set
  `SignalDeckEngine.instantiationOptions` to `.loadOutOfProcess` — costs some latency, but a
  plugin crash then takes down only the AU host process.
- No per-app output redirect, multi-app chains, or volume overdrive. Out of scope for now.
