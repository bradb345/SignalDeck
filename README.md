# SignalDeck

A macOS menu bar app that captures the audio of a single application — Plex, or anything else
you pick — runs it through a chain of Audio Units you assemble yourself, and plays the result
out your default output device.

It exists to solve the dialogue-vs-explosion problem: whispered conversation you can't hear at
2am, followed by an action scene that wakes the house. Point SignalDeck at Plex, load the Night
Mode rack, and stop riding the volume knob.

Think of it as a narrowly-scoped SoundSource: one app, one effects chain, no mixer.

## Install

```sh
brew install --cask bradb345/tap/signaldeck
```

That's it — no clone, no Xcode. The cask pulls the universal build from
[Releases](https://github.com/bradb345/SignalDeck/releases), verifies its checksum, and installs
to `/Applications`.

Then jump to [First run](#first-run) to grant the audio permission.

To upgrade later: `brew update && brew upgrade --cask signaldeck`.
To remove it: `brew uninstall --cask signaldeck` (see [Uninstall](#uninstall)).

Other routes — building from source, or downloading the zip by hand — are under
[Installing on another Mac](#installing-on-another-mac).

## Requirements

| | |
|---|---|
| **To run** | macOS 15.0 or later. macOS 26+ unlocks tap persistence (see below). |
| **To build** | Xcode 26 or Command Line Tools with the macOS 26 SDK (`xcode-select --install`). Full Xcode is not required. |
| **Hardware** | Apple Silicon or Intel — `package.sh` produces a universal binary. |

The macOS 26 SDK is needed even though the app runs on 15.0, because it compiles against
`CATapDescription.bundleIDs` and `isProcessRestoreEnabled` behind `if #available`. This only
affects building — the Homebrew cask ships a prebuilt binary and needs no developer tools.

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

## Build from source

Only needed if you're working on SignalDeck — to just use it, see [Install](#install).

```bash
git clone https://github.com/bradb345/SignalDeck.git
cd SignalDeck
./build.sh
open build/SignalDeck.app
```

`build.sh` compiles, assembles a `.app` bundle, and ad-hoc signs it. The bundle and signature
are both mandatory — TCC will not grant audio-capture permission to a bare executable.
`package.sh` does the same but universal (arm64 + Intel) and zipped for distribution.

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
builds are ad-hoc signed and cannot be notarized. macOS quarantines them on download and
Gatekeeper then refuses to open them. Every option below deals with that; the Homebrew cask
just deals with it for you.

### Option A — Homebrew (recommended)

```sh
brew install --cask bradb345/tap/signaldeck
```

No developer tools needed. The cask verifies the download's checksum, installs to
`/Applications`, and clears the quarantine attribute in a `postflight` stanza so the app
launches straight away.

That last part is necessary because **Homebrew 6 quarantines every cask unconditionally** —
the old `--no-quarantine` flag was removed, so a cask for an unnotarized app has to clear the
attribute itself. It runs exactly the `xattr -dr com.apple.quarantine` you'd otherwise type by
hand. Tap source: [bradb345/homebrew-tap](https://github.com/bradb345/homebrew-tap).

Upgrades: `brew update && brew upgrade --cask signaldeck`.

### Option B — build on the target machine

No Gatekeeper friction either, since a locally-built app was never quarantined. Needs the
macOS 26 SDK (see [Requirements](#requirements)).

```bash
xcode-select --install      # if the target Mac has no developer tools
git clone https://github.com/bradb345/SignalDeck.git
cd SignalDeck && ./build.sh
cp -R build/SignalDeck.app /Applications/
open /Applications/SignalDeck.app
```

### Option C — zip by hand

Grab the zip from [Releases](https://github.com/bradb345/SignalDeck/releases), or build one
with `./package.sh` (→ `dist/SignalDeck-<version>.zip` + `.sha256`). Then:

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

### Option D — Developer ID (no friction anywhere)

With a paid Apple Developer account ($99/yr) the app opens anywhere with no warnings, and the
cask wouldn't need its `postflight` workaround:

```bash
SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" ./package.sh
xcrun notarytool submit dist/SignalDeck-0.1.0.zip \
  --apple-id you@example.com --team-id TEAMID --password APP_SPECIFIC_PASSWORD --wait
xcrun stapler staple dist/SignalDeck.app
```

This also fixes the permission-reset annoyance below, since a Developer ID gives the app a
stable signing identity across rebuilds.

## Uninstall

### Homebrew

```sh
brew uninstall --cask signaldeck
```

Quits the app if it's running — the cask declares `uninstall quit:` — and removes
`/Applications/SignalDeck.app`. Your saved racks under
`~/Library/Application Support/SignalDeck/` are **left in place**, so reinstalling picks up
where you left off.

To remove those too:

```sh
brew uninstall --cask --zap signaldeck
```

`--zap` additionally trashes everything in the cask's `zap` stanza:

| Path | What it is |
|---|---|
| `~/Library/Application Support/SignalDeck` | Saved racks and the last-used rack |
| `~/Library/Preferences/com.bradbernard.SignalDeck.plist` | Preferences |
| `~/Library/Saved Application State/com.bradbernard.SignalDeck.savedState` | Window state |

And to drop the tap itself:

```sh
brew untap bradb345/tap
```

### The one thing Homebrew can't remove

The **TCC permission entry survives any uninstall**, `--zap` included — macOS keeps it outside
the app's own storage, and a later reinstall can inherit a stale grant that silently fails.
Clear it explicitly:

```bash
tccutil reset ScreenCapture com.bradbernard.SignalDeck
```

Or remove SignalDeck by hand from System Settings → Privacy & Security → Screen & System Audio
Recording.

### Manual installs

If you installed by building from source or by unzipping a release:

```bash
osascript -e 'quit app "SignalDeck"' 2>/dev/null
rm -rf /Applications/SignalDeck.app
rm -rf ~/Library/Application\ Support/SignalDeck    # saved racks — omit to keep them
tccutil reset ScreenCapture com.bradbernard.SignalDeck
```

## Cutting a release

`package.sh` output is **not byte-reproducible** — `swiftc` and `codesign` embed varying data,
so two runs over identical sources produce different binaries. Always take the cask's checksum
from the *published* asset, never from a local build, or `brew install` fails with a checksum
mismatch:

```bash
./package.sh
gh release create v0.2.0 dist/SignalDeck-0.2.0.zip dist/SignalDeck-0.2.0.zip.sha256 \
  --title "SignalDeck 0.2.0"

# hash what was actually published — this is the value that goes in the cask
shasum -a 256 <(gh release download v0.2.0 -p "*.zip" -O -)
```

Then bump `version` and `sha256` in `Casks/signaldeck.rb` in the tap repo and push.

Pushing a `v*` tag also triggers `.github/workflows/release.yml`, which builds a universal app
on a `macos-26` runner and attaches the zip. Either route works — just remember the checksum
must come from whichever artifact actually ends up on the release.

## Permissions

SignalDeck needs **Screen & System Audio Recording**. It records no screen content — that's
just the TCC category Apple files system-audio capture under. The Info.plist declares
`NSAudioCaptureUsageDescription`, without which the prompt never appears at all.

The app is deliberately **not sandboxed**. Process taps, private aggregate devices, and
enumerating other processes' audio objects don't work cleanly under the sandbox, and an app
that taps another app's audio can't ship on the Mac App Store regardless.

### Permission resets after every rebuild or upgrade

TCC ties the grant to the app's code signature. Ad-hoc signing produces a new signature for
every build, so macOS treats each one as a different app and silently denies capture. This hits
both source rebuilds and `brew upgrade --cask signaldeck`, since each release is a fresh
binary. If the toggle stops working afterwards:

```bash
tccutil reset ScreenCapture com.bradbernard.SignalDeck
```

Then relaunch and approve again. If that doesn't clear it, remove SignalDeck manually from
System Settings → Privacy & Security → Screen & System Audio Recording and re-add it.
A Developer ID certificate ([Option D](#option-d--developer-id-no-friction-anywhere)) makes
this go away.

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
