// SL2ControlPanel.swift — "SL 2 Control Panel", a small app to see and set the Rane SL 2's state:
// connection, firmware and driver versions, sample rate, latency, each deck's analogue thru and the
// LINE/PHONO switch. It talks to the SL2Device HAL plug-in through CoreAudio, as sl2panel does:
//   'sl2s'  the driver's status (SL2StatusPacket, SL2Status.h)
//   'sl2h'  a 64-byte HID command to the box; reading it back returns the box's reply
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
}

enum PanelState: Equatable {
    case driverMissing      // the plug-in isn't loaded: nothing can reach the box
    case noBox              // no SL 2 attached
    case bootloader         // attached, but in its USB bootloader: no firmware
    case connected(BoxState)
}

@MainActor
final class PanelModel: ObservableObject {
    @Published var state: PanelState = .noBox
    @Published var driverVersion: String?
    private var timer: Timer?
    private var device: AudioObjectID?

    init() {
        refresh()
        // The status changes from outside the app (the box's switch, other apps, plugging in):
        // read it twice a second.
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    func refresh() {
        driverVersion = SL2Driver.driverVersion()
        // No driver device: either no box, or no driver to list one.
        guard let dev = SL2Driver.device(), let s = SL2Driver.status(dev) else {
            device = nil
            state = SL2Driver.pluginLoaded() ? .noBox : .driverMissing
            return
        }
        device = dev
        if s.boot_mode != 0 { state = .bootloader; return }
        if s.connected == 0 { state = .noBox; return }
        // Connected: collect what the panel shows.
        let rate = Double(s.sample_rate > 0 ? s.sample_rate : 44100)
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
            inputLatencyMs: Double(SL2Driver.latencyFrames(dev, kAudioObjectPropertyScopeInput)) * 1000 / rate))
    }

    /// Switch a deck's analogue thru (deck 0 or 1), then show what the box reports.
    func setThru(deck: Int, on: Bool) {
        guard let dev = device else { return }
        SL2Driver.sendHidi(dev, on ? 0x90 : 0x80, SL2Driver.noteThru[deck])
        // The box reports the change within a few milliseconds; the driver keeps it in its status.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { self.refresh() }
    }

    /// Change the rate through CoreAudio: the driver changes the box's rate with the HAL's.
    func setSampleRate(_ rate: Int) {
        guard let dev = device else { return }
        SL2Driver.setSampleRate(dev, Double(rate))
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { self.refresh() }
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
        .frame(width: 440)
    }

    @ViewBuilder
    private func connected(_ box: BoxState) -> some View {
        Form {
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
            } header: {
                Text("Audio")
            } footer: {
                Text("Latency as the driver reports it, not counting each app's own buffer (in Serato DJ: USB Buffer Size).")
                    .foregroundStyle(.secondary)
            }
            Section {
                ForEach(0..<2, id: \.self) { deck in
                    Toggle("Deck \(deck + 1) analogue thru", isOn: Binding(get: { box.thru[deck] },
                                                                          set: { model.setThru(deck: deck, on: $0) }))
                }
                LabeledContent("Input", value: box.phono ? "Phono" : "Line")
            } header: {
                Text("Decks")
            } footer: {
                Text("Thru sends a deck's input straight to its outputs. An app playing through the SL 2 switches both decks to USB when it starts, and back to thru when it stops. Phono / Line is the switch on the box.")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        // The window is sized to the whole form, so it never needs to scroll.
        .scrollDisabled(true)
        .scrollIndicators(.never)
        .fixedSize(horizontal: false, vertical: true)
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
