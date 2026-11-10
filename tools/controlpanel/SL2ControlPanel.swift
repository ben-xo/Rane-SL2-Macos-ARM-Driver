// SL2ControlPanel.swift — "SL 2 Control Panel", a small app to see and set the Rane SL 2's state:
// connection, firmware and driver versions, sample rate, latency, each deck's analogue thru and the
// CD/PHONO (line/phono) switch, the decks' input and output levels, and the output volume. It talks to the
// SL2Device HAL plug-in through CoreAudio, as sl2panel does:
//   'sl2s'  the driver's status (SL2StatusPacket, SL2Status.h)
//   'sl2h'  a 64-byte HID command to the box; reading it back returns the box's reply
//   'sl2m'  the peak level of each input and output channel since the last read
//   'sl2i'  the input safety offset setting, in microseconds (set with nothing streaming)
// and the device's standard output volume.
// Built by tools/controlpanel/build-app.sh (make controlpanel).

import AppKit
import CoreAudio
import IOKit
import SwiftUI

// MARK: - The driver, through CoreAudio

enum SL2Driver {
    static let deviceUID = "com.rane.sl2.hal.device"
    static let pluginBundleID = "io.github.pepeleedj.sl2device"
    static let driverBundlePath = "/Library/Audio/Plug-Ins/HAL/SL2Device.driver"

    static let vendorID = 0x1cc5
    static let productID = 0x0013

    // HID: command 0x41 carries MIDI-style messages; Note On / Note Off of these notes switch a
    // deck's thru on / off (docs/SL2-COMMANDS.md).
    static let cmdHidi: UInt8 = 0x41
    static let noteThru: [UInt8] = [0x5C, 0x5D]

    static func fourCC(_ s: String) -> AudioObjectPropertySelector {
        s.utf8.reduce(0) { $0 << 8 | AudioObjectPropertySelector($1) }
    }
    static let propStatus = fourCC("sl2s")
    static let propHID = fourCC("sl2h")
    static let propInSafety = fourCC("sl2i")

    static func address(_ selector: AudioObjectPropertySelector,
                        _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }

    /// The SL 2's CoreAudio device, listed by the driver while a box is attached.
    static func device() -> AudioObjectID? {
        var addr = address(kAudioHardwarePropertyTranslateUIDToDevice)
        var uid = deviceUID as CFString
        var dev = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let err = withUnsafePointer(to: &uid) {
            AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr,
                                       UInt32(MemoryLayout<CFString>.size), $0, &size, &dev)
        }
        return err == noErr && dev != kAudioObjectUnknown ? dev : nil
    }

    /// The SL2Device plug-in is loaded in coreaudiod.
    static func pluginLoaded() -> Bool {
        var addr = address(kAudioHardwarePropertyTranslateBundleIDToPlugIn)
        var bundle = pluginBundleID as CFString
        var plugin = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let err = withUnsafePointer(to: &bundle) {
            AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr,
                                       UInt32(MemoryLayout<CFString>.size), $0, &size, &plugin)
        }
        return err == noErr && plugin != kAudioObjectUnknown
    }

    /// An SL 2 is in the USB registry (with or without the driver).
    static func boxOnUSB() -> Bool {
        guard let match = IOServiceMatching("IOUSBHostDevice") as NSMutableDictionary? else { return false }
        match["idVendor"] = vendorID
        match["idProduct"] = productID
        let service = IOServiceGetMatchingService(kIOMainPortDefault, match)
        guard service != 0 else { return false }
        IOObjectRelease(service)
        return true
    }

    /// The installed driver's version, from its bundle.
    static func driverVersion() -> String? {
        Bundle(path: driverBundlePath)?.infoDictionary?["CFBundleShortVersionString"] as? String
    }

    /// The driver's status packet; a shorter packet (an older driver) is zero-filled.
    static func status(_ dev: AudioObjectID) -> SL2StatusPacket? {
        var addr = address(propStatus)
        var data: Unmanaged<CFData>?
        var size = UInt32(MemoryLayout<Unmanaged<CFData>?>.size)
        guard AudioObjectGetPropertyData(dev, &addr, 0, nil, &size, &data) == noErr,
              let cf = data?.takeRetainedValue() else { return nil }
        var packet = SL2StatusPacket()
        let bytes = cf as Data
        _ = withUnsafeMutableBytes(of: &packet) { dst in
            bytes.copyBytes(to: dst.bindMemory(to: UInt8.self), count: min(bytes.count, dst.count))
        }
        return packet
    }

    /// Send one 3-byte MIDI-style message to the box (HID 0x41) and wait for its reply.
    @discardableResult
    static func sendHidi(_ dev: AudioObjectID, _ status: UInt8, _ note: UInt8, _ velocity: UInt8 = 0) -> Bool {
        // Build the command: [0] 0x41, [1..4] tag, [5] message length, [6...] the message.
        var request = [UInt8](repeating: 0, count: 64)
        request[0] = cmdHidi
        request[1] = 1
        request[5] = 3
        request[6] = status; request[7] = note; request[8] = velocity
        // Writing 'sl2h' sends it.
        var addr = address(propHID)
        let cfIn = Data(request) as CFData
        var ref = Unmanaged.passUnretained(cfIn)   // the property's value is the CFDataRef itself
        let sent = withExtendedLifetime(cfIn) {
            AudioObjectSetPropertyData(dev, &addr, 0, nil, UInt32(MemoryLayout<Unmanaged<CFData>>.size), &ref)
        }
        guard sent == noErr else { return false }
        // Reading 'sl2h' returns the box's reply: 0x41 if it took the command.
        var reply: Unmanaged<CFData>?
        var size = UInt32(MemoryLayout<Unmanaged<CFData>?>.size)
        guard AudioObjectGetPropertyData(dev, &addr, 0, nil, &size, &reply) == noErr,
              let out = reply?.takeRetainedValue() as Data? else { return false }
        return out.first == cmdHidi
    }

    static let propMeters = fourCC("sl2m")

    /// The peak level (0...1) of inputs 1-4 then outputs 1-4 since the last read. Reading keeps the
    /// driver measuring for another second; nil if the driver has no meters.
    static func meters(_ dev: AudioObjectID) -> [Float]? {
        var addr = address(propMeters)
        var data: Unmanaged<CFData>?
        var size = UInt32(MemoryLayout<Unmanaged<CFData>?>.size)
        guard AudioObjectGetPropertyData(dev, &addr, 0, nil, &size, &data) == noErr,
              let cf = data?.takeRetainedValue() else { return nil }
        let bytes = cf as Data
        guard bytes.count == 8 * MemoryLayout<Float32>.size else { return nil }
        var peaks = [Float32](repeating: 0, count: 8)
        _ = peaks.withUnsafeMutableBytes { bytes.copyBytes(to: $0) }
        return peaks
    }

    /// The output's main volume as a slider position (0...1) and in dB, or nil if there is none.
    static func volume(_ dev: AudioObjectID) -> (scalar: Float, db: Float)? {
        var scalarAddr = address(kAudioDevicePropertyVolumeScalar, kAudioObjectPropertyScopeOutput)
        var dbAddr = address(kAudioDevicePropertyVolumeDecibels, kAudioObjectPropertyScopeOutput)
        var scalar: Float32 = 0, db: Float32 = 0
        var size = UInt32(MemoryLayout<Float32>.size)
        guard AudioObjectGetPropertyData(dev, &scalarAddr, 0, nil, &size, &scalar) == noErr,
              AudioObjectGetPropertyData(dev, &dbAddr, 0, nil, &size, &db) == noErr else { return nil }
        return (scalar, db)
    }

    static func setVolume(_ dev: AudioObjectID, _ scalar: Float) {
        var addr = address(kAudioDevicePropertyVolumeScalar, kAudioObjectPropertyScopeOutput)
        var value = Float32(scalar)
        AudioObjectSetPropertyData(dev, &addr, 0, nil, UInt32(MemoryLayout<Float32>.size), &value)
    }

    /// The output mute, or nil if there is none.
    static func muted(_ dev: AudioObjectID) -> Bool? {
        var addr = address(kAudioDevicePropertyMute, kAudioObjectPropertyScopeOutput)
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        return AudioObjectGetPropertyData(dev, &addr, 0, nil, &size, &value) == noErr ? value != 0 : nil
    }

    static func setMuted(_ dev: AudioObjectID, _ muted: Bool) {
        var addr = address(kAudioDevicePropertyMute, kAudioObjectPropertyScopeOutput)
        var value: UInt32 = muted ? 1 : 0
        AudioObjectSetPropertyData(dev, &addr, 0, nil, UInt32(MemoryLayout<UInt32>.size), &value)
    }

    /// Audio MIDI Setup, where each output channel's volume is set.
    static let audioMIDISetup = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.audio.AudioMIDISetup")

    /// Set the input safety offset (microseconds). The driver takes it only with nothing streaming,
    /// then has CoreAudio set the device up again with it, which takes about half a second.
    @discardableResult
    static func setInputSafety(_ dev: AudioObjectID, _ us: Int) -> Bool {
        var addr = address(propInSafety)
        let number = us as CFNumber
        var ref = Unmanaged.passUnretained(number)   // the property's value is the CFNumberRef itself
        return withExtendedLifetime(number) {
            AudioObjectSetPropertyData(dev, &addr, 0, nil, UInt32(MemoryLayout<Unmanaged<CFNumber>>.size), &ref)
        } == noErr
    }

    static func setSampleRate(_ dev: AudioObjectID, _ rate: Double) {
        var addr = address(kAudioDevicePropertyNominalSampleRate)
        var value = rate
        AudioObjectSetPropertyData(dev, &addr, 0, nil, UInt32(MemoryLayout<Float64>.size), &value)
    }

    static func uint32(_ obj: AudioObjectID, _ selector: AudioObjectPropertySelector, _ scope: AudioObjectPropertyScope) -> UInt32 {
        var addr = address(selector, scope)
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        return AudioObjectGetPropertyData(obj, &addr, 0, nil, &size, &value) == noErr ? value : 0
    }

    /// The latency the driver reports in one direction, in frames: device latency, safety offset
    /// and the stream's latency (what an app adds to its own buffer).
    static func latencyFrames(_ dev: AudioObjectID, _ scope: AudioObjectPropertyScope) -> UInt32 {
        var total = uint32(dev, kAudioDevicePropertyLatency, scope) + uint32(dev, kAudioDevicePropertySafetyOffset, scope)
        var addr = address(kAudioDevicePropertyStreams, scope)
        var stream = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        if AudioObjectGetPropertyData(dev, &addr, 0, nil, &size, &stream) == noErr, stream != kAudioObjectUnknown {
            total += uint32(stream, kAudioStreamPropertyLatency, kAudioObjectPropertyScopeGlobal)
        }
        return total
    }
}

// MARK: - What the panel shows

struct BoxState: Equatable {
    var streaming: Bool
    var sampleRate: Int
    var firmware: String
    var serial: String
    var phono: Bool
    var thru: [Bool]
    var outputLatencyMs: Double
    var inputLatencyMs: Double
    var volume: Volume?      // the main output volume; nil if none
    struct Volume: Equatable {
        let scalar: Float    // as a slider position, 0...1
        let db: Float
    }
    var muted: Bool?         // the output mute; nil if none
    var input: InputHealth?  // nil from a driver too old to report it
    struct InputHealth: Equatable {
        let safetyUs: Int        // the input safety offset CoreAudio is using
        let settingUs: Int       // the setting; safetyUs is larger while it has fallen back
        let earlyRead: UInt32    // 0 not judged yet, 1 working, 2 not working
        let hubs: Int            // USB hubs between the box and the Mac
        let dropouts: UInt64     // IO cycles since connecting in which input wasn't captured in time
    }
}

enum PanelState: Equatable {
    case driverMissing      // the plug-in isn't loaded: nothing can reach the box
    case noBox              // no SL 2 attached
    case bootloader         // attached, but in its USB bootloader: no firmware
    case connected(BoxState)
}

/// A repeating timer on the main run loop in its common modes, so it keeps firing while a control is
/// being dragged (event tracking), which a timer in the default mode does not.
@MainActor
func repeatingTimer(every interval: TimeInterval, _ body: @escaping @MainActor () -> Void) -> Timer {
    let timer = Timer(timeInterval: interval, repeats: true) { _ in Task { @MainActor in body() } }
    RunLoop.main.add(timer, forMode: .common)
    return timer
}

@MainActor
final class PanelModel: ObservableObject {
    @Published var state: PanelState = .noBox
    @Published var driverVersion: String?
    /// The level meters, which read the device this model finds (not published: they redraw alone).
    let meters = MeterModel()
    private var timer: Timer?
    private(set) var device: AudioObjectID?
    /// The device whose volume and mute changes we are told of, and the listener that hears them.
    private var watched: AudioObjectID?
    private lazy var volumeListener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
        Task { @MainActor in self?.refresh() }
    }
    private static let watchedProperties = [kAudioDevicePropertyVolumeScalar, kAudioDevicePropertyMute].map {
        SL2Driver.address($0, kAudioObjectPropertyScopeOutput)
    }

    init() {
        meters.device = { [weak self] in self?.device }
        refresh()
        // The status changes from outside the app (the box's switch, other apps, plugging in):
        // read it twice a second. The volume and mute are followed as they change (watch).
        timer = repeatingTimer(every: 0.5) { [weak self] in self?.refresh() }
    }

    /// Be told when the device's main volume or mute changes (the menu bar, the volume keys, Audio
    /// MIDI Setup), so the slider follows at once rather than at the next status read.
    private func watch(_ dev: AudioObjectID?) {
        guard dev != watched else { return }
        if let old = watched {
            for var addr in Self.watchedProperties {
                AudioObjectRemovePropertyListenerBlock(old, &addr, DispatchQueue.main, volumeListener)
            }
        }
        if let new = dev {
            for var addr in Self.watchedProperties {
                AudioObjectAddPropertyListenerBlock(new, &addr, DispatchQueue.main, volumeListener)
            }
        }
        watched = dev
    }

    func refresh() {
        driverVersion = SL2Driver.driverVersion()
        // No driver device: either no box, or no driver to list one.
        guard let dev = SL2Driver.device(), let s = SL2Driver.status(dev) else {
            device = nil
            watch(nil)
            state = SL2Driver.pluginLoaded() ? .noBox : .driverMissing
            return
        }
        device = dev
        watch(dev)
        // The bundle's version can't tell a debug build (make install DEBUG=1 replaces only the
        // binary in it); the running driver says so in its status.
        if s.debug_build != 0, let version = driverVersion { driverVersion = version + " (debug build)" }
        if s.boot_mode != 0 { state = .bootloader; return }
        if s.connected == 0 { state = .noBox; return }
        // Connected: collect what the panel shows.
        let rate = Double(s.sample_rate > 0 ? s.sample_rate : 44100)
        let volume = SL2Driver.volume(dev)
        let serial = withUnsafeBytes(of: s.serial) { raw in
            String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
        }
        state = .connected(BoxState(
            streaming: s.streaming != 0,
            sampleRate: Int(s.sample_rate),
            firmware: s.version_maj == 0 && s.version_min == 0 ? "—" : String(format: "%u.%02u", s.version_maj, s.version_min),
            serial: serial.isEmpty ? "—" : serial,
            phono: s.phono.0 != 0,
            thru: [s.thru.0 != 0, s.thru.1 != 0],
            outputLatencyMs: Double(SL2Driver.latencyFrames(dev, kAudioObjectPropertyScopeOutput)) * 1000 / rate,
            inputLatencyMs: Double(SL2Driver.latencyFrames(dev, kAudioObjectPropertyScopeInput)) * 1000 / rate,
            volume: volume.map { BoxState.Volume(scalar: $0.scalar, db: $0.db) },
            muted: SL2Driver.muted(dev),
            input: s.in_safety_us == 0 ? nil : BoxState.InputHealth(
                safetyUs: Int(s.in_safety_us), settingUs: Int(s.in_safety_setting_us), earlyRead: s.early_read,
                hubs: Int(s.hub_depth), dropouts: s.in_dropouts)))
    }

    /// Set the main output volume (a slider position, 0...1); the menu bar and Audio MIDI Setup follow.
    /// Any level above the minimum unmutes, as the macOS volume slider does. The window updates from
    /// the volume and mute listener (watch), so a slider drag costs one set per step, not a refresh.
    func setVolume(_ scalar: Float, unmuting muted: Bool) {
        guard let dev = device else { return }
        SL2Driver.setVolume(dev, scalar)
        if scalar > 0, muted { SL2Driver.setMuted(dev, false) }
    }

    func setMuted(_ muted: Bool) {
        guard let dev = device else { return }
        SL2Driver.setMuted(dev, muted)
    }

    /// Switch a deck's analogue thru (deck 0 or 1), then show what the box reports.
    func setThru(deck: Int, on: Bool) {
        guard let dev = device else { return }
        SL2Driver.sendHidi(dev, on ? 0x90 : 0x80, SL2Driver.noteThru[deck])
        // The box reports the change within a few milliseconds; the driver keeps it in its status.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { self.refresh() }
    }

    /// Change the input safety offset. CoreAudio sets the device up again with it (the window shows the
    /// SL 2 as gone for a moment).
    func setInputSafety(_ us: Int) {
        guard let dev = device else { return }
        SL2Driver.setInputSafety(dev, us)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { self.refresh() }
    }

    /// Change the rate through CoreAudio: the driver changes the box's rate with the HAL's.
    func setSampleRate(_ rate: Int) {
        guard let dev = device else { return }
        SL2Driver.setSampleRate(dev, Double(rate))
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { self.refresh() }
    }
}

/// The level meters: each deck's input and output, read from the driver 60 times a second. Kept
/// apart from PanelModel so the meters redraw on their own, not the whole window. They respond fast
/// (a new peak at once, falling the full range in a third of a second), so they show how promptly
/// audio, a DVS record's timecode for one, starts and stops.
@MainActor
final class MeterModel: ObservableObject {
    /// Peak level in dB (meterFloorDb...0) of each channel: inputs 1-4 (left deck L, R, right deck L, R),
    /// then outputs 1-4.
    @Published var levels: [Float] = Array(repeating: MeterModel.meterFloorDb, count: 8)
    static let meterFloorDb: Float = -60
    private static let ticksPerSecond = 60.0
    private static let fallDbPerTick: Float = 3     // 180 dB a second
    private var timer: Timer?
    /// The device to read, from PanelModel.
    var device: () -> AudioObjectID? = { nil }

    init() {
        timer = repeatingTimer(every: 1.0 / Self.ticksPerSecond) { [weak self] in self?.tick() }
    }

    private func tick() {
        // Read the driver only while the window can be seen: once nothing reads them, the driver stops
        // measuring (after a second), so a hidden or minimised panel costs nothing.
        guard NSApp.windows.contains(where: { $0.isVisible && $0.occlusionState.contains(.visible) }) else { return }
        let peaks = device().flatMap { SL2Driver.meters($0) } ?? Array(repeating: 0, count: 8)
        // A meter jumps up to a new peak and falls back fast, but not so fast that a short peak is gone
        // before it is drawn.
        let next = zip(levels, peaks).map { shown, peak in
            let db = peak > 0 ? max(20 * log10(peak), Self.meterFloorDb) : Self.meterFloorDb
            return max(db, shown - Self.fallDbPerTick)
        }
        // Publish only a change, so still meters don't redraw.
        if next != levels { levels = next }
    }
}

/// A horizontal level meter, from meterFloorDb to 0 dB: green, then yellow from -12 dB, red from -3 dB.
struct LevelMeter: View {
    let db: Float
    var label = "Level"
    var body: some View {
        GeometryReader { geo in
            let floor = MeterModel.meterFloorDb
            let fraction = CGFloat((db - floor) / -floor)
            ZStack(alignment: .leading) {
                Capsule().fill(.quaternary)
                Capsule()
                    .fill(LinearGradient(stops: [.init(color: .green, location: 0),
                                                 .init(color: .green, location: 0.78),
                                                 .init(color: .yellow, location: 0.8),
                                                 .init(color: .yellow, location: 0.93),
                                                 .init(color: .red, location: 0.95)],
                                         startPoint: .leading, endPoint: .trailing))
                    .frame(width: geo.size.width)
                    .mask(alignment: .leading) { Capsule().frame(width: geo.size.width * max(0, min(1, fraction))) }
            }
        }
        .frame(height: 6)
        .accessibilityElement()
        .accessibilityLabel(label)
        .accessibilityValue(db <= MeterModel.meterFloorDb ? "silent" : String(format: "%.0f dB", db))
    }
}

/// A deck's stereo meter: one bar for its left channel, one for its right.
struct StereoMeter: View {
    let left: Float, right: Float
    var body: some View {
        VStack(spacing: 3) {
            ForEach([("L", left), ("R", right)], id: \.0) { side, db in
                HStack(spacing: 6) {
                    Text(side).font(.caption2).foregroundStyle(.secondary).frame(width: 8)
                    LevelMeter(db: db, label: side == "L" ? "Left" : "Right")
                }
            }
        }
    }
}

/// A labelled stereo meter row, observing the meters itself so that only it redraws as they move.
struct DeckMeterRow: View {
    @ObservedObject var meters: MeterModel
    let name: String
    let left: Int, right: Int   // indexes into meters.levels
    var body: some View {
        LabeledContent(name) { StereoMeter(left: meters.levels[left], right: meters.levels[right]) }
    }
}

// MARK: - The window

struct PanelView: View {
    @ObservedObject var model: PanelModel

    var body: some View {
        Group {
            switch model.state {
            case .driverMissing:
                Message(symbol: "exclamationmark.triangle", title: "SL 2 driver not loaded",
                        text: "Install the Rane SL 2 driver package, then open this app again.")
            case .noBox:
                Message(symbol: "cable.connector", title: "No SL 2 connected",
                        text: "Connect the SL 2 by USB, directly or through a single hub.")
            case .bootloader:
                Message(symbol: "exclamationmark.triangle", title: "The SL 2 has no firmware loaded",
                        text: "The box is in its USB bootloader and passes no audio until its firmware is restored. Run Firmware-SL2.command from the installer folder.")
            case .connected(let box):
                connected(box)
            }
        }
    }

    /// One column of the connected view: a grouped form sized to its sections, so it never scrolls.
    private func column<Content: View>(@ViewBuilder _ sections: () -> Content) -> some View {
        Form { sections() }
            .formStyle(.grouped)
            .scrollDisabled(true)
            .scrollIndicators(.never)
            .frame(width: Self.columnWidth)
            .fixedSize(horizontal: false, vertical: true)
    }
    static let columnWidth: CGFloat = 440
    /// The decks as the box marks them: the left deck is channels 1/2 (the firmware's deck 1, thru note
    /// 0x5C), the right deck channels 3/4 (deck 2, 0x5D), for inputs and outputs alike.
    static let deckNames = ["Left deck (1/2)", "Right deck (3/4)"]

    @ViewBuilder
    private func connected(_ box: BoxState) -> some View {
        HStack(alignment: .top, spacing: 0) {
            column { boxSections(box) }
            column { levelSections(box) }
        }
    }

    /// The left column: the box, its audio settings and the decks.
    @ViewBuilder
    private func boxSections(_ box: BoxState) -> some View {
        let warnings = Self.warnings(box)
        if !warnings.isEmpty {
            Section {
                ForEach(warnings, id: \.self) { text in
                    Label(text, systemImage: "exclamationmark.triangle.fill")
                        .symbolRenderingMode(.multicolor)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        Section("Rane SL 2") {
            LabeledContent("Status", value: box.streaming ? "Connected, streaming audio" : "Connected")
            LabeledContent("Firmware", value: box.firmware)
            LabeledContent("Serial number", value: box.serial)
            LabeledContent("Driver", value: model.driverVersion ?? "—")
        }
        Section {
            Picker("Sample rate", selection: Binding(get: { box.sampleRate },
                                                     set: { model.setSampleRate($0) })) {
                Text("44.1 kHz").tag(44100)
                Text("48 kHz").tag(48000)
            }
            LabeledContent("Output latency", value: String(format: "%.1f ms", box.outputLatencyMs))
            LabeledContent("Input latency", value: String(format: "%.1f ms", box.inputLatencyMs))
            if let input = box.input {
                Picker("Input safety offset", selection: Binding(get: { input.settingUs },
                                                                 set: { model.setInputSafety($0) })) {
                    ForEach(Self.safetyChoices(input.settingUs), id: \.self) { us in
                        Text(Self.ms(us) + (us == 1500 ? " (default)" : "")).tag(us)
                    }
                }
                .disabled(box.streaming)
            }
        } header: {
            Text("Audio")
        } footer: {
            Text("Latency as the driver reports it, not counting each app's own buffer (in Serato DJ: USB Buffer Size). The input safety offset is how long the driver lets each input sample arrive before an app reads it: raise it if you hear gaps in the input. It can be changed only while no app is using the SL 2.")
                .foregroundStyle(.secondary)
        }
        Section {
            ForEach(0..<2, id: \.self) { deck in
                Toggle("\(Self.deckNames[deck]) analogue thru", isOn: Binding(get: { box.thru[deck] },
                                                                      set: { model.setThru(deck: deck, on: $0) }))
            }
            LabeledContent("Input", value: box.phono ? "Phono" : "CD (line)")
        } header: {
            Text("Decks")
        } footer: {
            Text("Thru sends a deck's input straight to its outputs. An app playing through the SL 2 switches both decks to USB when it starts, and back to thru when it stops. CD / Phono is the switch on the box, for both decks.")
                .foregroundStyle(.secondary)
        }
    }

    /// The input safety offsets to choose from, with the current setting among them.
    static func safetyChoices(_ setting: Int) -> [Int] {
        let choices = [1500, 2000, 3000, 4000, 8000]
        return choices.contains(setting) ? choices : (choices + [setting]).sorted()
    }
    static func ms(_ us: Int) -> String {
        us % 1000 == 0 ? "\(us / 1000) ms" : String(format: "%.1f ms", Double(us) / 1000)
    }

    /// What the panel warns about: input the driver couldn't read early, input dropouts, and hubs.
    static func warnings(_ box: BoxState) -> [String] {
        guard let input = box.input else { return [] }
        var w: [String] = []
        if input.earlyRead == 2 {
            w.append("Input can't be read early on this Mac, so the input safety offset is \(ms(input.safetyUs)) until the SL 2 is connected again or the setting is changed (it is \(ms(input.settingUs))). Connecting it directly to the Mac may help.")
        } else if input.safetyUs != input.settingUs {
            w.append("The input safety offset is \(ms(input.safetyUs)) until the SL 2 is connected again or the setting is changed (it is \(ms(input.settingUs))).")
        }
        if input.dropouts > 0 {
            let times = input.dropouts == 1 ? "once" : "\(input.dropouts) times"
            w.append("Input dropped out \(times) since the SL 2 was connected. If you hear gaps in the input, raise the input safety offset.")
        }
        if input.hubs > 1 {
            w.append("The SL 2 is connected through \(input.hubs) USB hubs, one inside another. Connect it directly to the Mac, or through a single hub: nested hubs add latency and can make USB audio unreliable.")
        } else if input.hubs == 1 {
            w.append("The SL 2 is connected through a USB hub. For the lowest latency, connect it directly to the Mac.")
        }
        return w
    }

    /// The Outputs footer, with "Audio MIDI Setup" a link that opens it (plain text if it can't be found).
    private var outputsFooter: AttributedString {
        var text = AttributedString("The volume applies to everything the SL 2 plays, Serato's decks included, like the volume keys. Set each output channel's own volume in ")
        var app = AttributedString("Audio MIDI Setup")
        if let url = SL2Driver.audioMIDISetup { app.link = url }
        text.append(app)
        text.append(AttributedString("."))
        return text
    }

    /// The right column: the input and output levels, and the output volume.
    @ViewBuilder
    private func levelSections(_ box: BoxState) -> some View {
        Section {
            DeckMeterRow(meters: model.meters, name: Self.deckNames[0], left: 0, right: 1)
            DeckMeterRow(meters: model.meters, name: Self.deckNames[1], left: 2, right: 3)
        } header: {
            Text("Inputs")
        } footer: {
            Text("The level of each deck's input, left and right, while an app is using the SL 2. With nothing using it the decks are on thru, and the box sends the computer no audio.")
                .foregroundStyle(.secondary)
        }
        Section {
            if let volume = box.volume {
                LabeledContent("Volume") {
                    HStack {
                        Slider(value: Binding(get: { volume.scalar },
                                              set: { model.setVolume($0, unmuting: box.muted == true) }), in: 0...1)
                        Text(box.muted == true ? "Muted" : volume.scalar <= 0 ? "Off" : String(format: "%.0f dB", volume.db))
                            .monospacedDigit()
                            .frame(width: 52, alignment: .trailing)
                    }
                }
            }
            if let muted = box.muted {
                Toggle("Mute", isOn: Binding(get: { muted }, set: { model.setMuted($0) }))
            }
            DeckMeterRow(meters: model.meters, name: Self.deckNames[0], left: 4, right: 5)
            DeckMeterRow(meters: model.meters, name: Self.deckNames[1], left: 6, right: 7)
        } header: {
            Text("Outputs")
        } footer: {
            Text(outputsFooter)
                .foregroundStyle(.secondary)
                // The link is the app's bundle: launch it (the default handler does nothing with an .app).
                .environment(\.openURL, OpenURLAction { url in
                    guard url.pathExtension == "app" else { return .systemAction }
                    NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
                    return .handled
                })
        }
    }
}

struct Message: View {
    let symbol: String, title: String, text: String
    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: symbol).font(.system(size: 34)).foregroundStyle(.secondary)
            Text(title).font(.title3).bold()
            Text(text).multilineTextAlignment(.center).foregroundStyle(.secondary)
        }
        .padding(32)
        .frame(width: PanelView.columnWidth)
    }
}

// MARK: - The app

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

@main
struct SL2ControlPanelApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var model = PanelModel()

    var body: some Scene {
        Window("SL 2 Control Panel", id: "main") {
            PanelView(model: model)
        }
        .windowResizability(.contentSize)
    }
}
