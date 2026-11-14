import CoreMIDI
import Foundation

/// Listens to every MIDI keyboard connected to the Mac and reports its keys going down and
/// up. CoreMIDI hands the same events to every app that asks, so Logic keeps receiving them
/// and making the sound; this only watches.
@MainActor @Observable
final class MidiKeyboardInput {
    /// Names of the connected MIDI sources.
    private(set) var sources: [String] = []
    /// A key event: pitch, down or up, and when (host time; 0 when the source gave none).
    @ObservationIgnored var onKey: ((_ pitch: Int, _ down: Bool, _ hostTime: UInt64) -> Void)?
    /// A keyboard was plugged in or taken away.
    @ObservationIgnored var onSourcesChanged: (() -> Void)?

    @ObservationIgnored private var client = MIDIClientRef()
    @ObservationIgnored private var port = MIDIPortRef()
    @ObservationIgnored private var connected: Set<MIDIEndpointRef> = []

    func start() {
        guard client == 0 else { return }
        MIDIClientCreateWithBlock("Musicnote 练琴" as CFString, &client) { [weak self] note in
            // Devices plugged in or removed.
            guard note.pointee.messageID == .msgSetupChanged else { return }
            Task { @MainActor in self?.connect() }
        }
        MIDIInputPortCreateWithProtocol(client, "Musicnote 练琴输入" as CFString, ._1_0, &port) { [weak self] list, _ in
            // On CoreMIDI's thread: pick out the note messages, then hand them to the main actor.
            var keys: [(Int, Bool, UInt64)] = []
            for packet in list.unsafeSequence() {
                let count = Int(packet.pointee.wordCount)
                let stamp = packet.pointee.timeStamp
                guard let offset = MemoryLayout<MIDIEventPacket>.offset(of: \.words) else { continue }
                let words = UnsafeRawPointer(packet).advanced(by: offset).assumingMemoryBound(to: UInt32.self)
                for i in 0..<count {
                    let word = words[i]
                    // MIDI 1.0 channel voice messages are one word each: type 2 in the top nibble.
                    guard word >> 28 == 0x2 else { continue }
                    let status = UInt8((word >> 16) & 0xF0), pitch = Int((word >> 8) & 0x7F), velocity = Int(word & 0x7F)
                    if status == 0x90, velocity > 0 { keys.append((pitch, true, stamp)) }
                    else if status == 0x80 || status == 0x90 { keys.append((pitch, false, stamp)) }
                }
            }
            guard !keys.isEmpty else { return }
            Task { @MainActor in
                guard let self else { return }
                for (pitch, down, stamp) in keys { self.onKey?(pitch, down, stamp) }
            }
        }
        connect()
    }

    func stop() {
        guard client != 0 else { return }
        MIDIClientDispose(client) // disposes the port and its connections with it
        client = 0; port = 0
        connected = []
        sources = []
        onSourcesChanged = nil
    }

    /// Connects to every source now present and drops the ones that are gone.
    private func connect() {
        guard port != 0 else { return }
        var present: Set<MIDIEndpointRef> = []
        var names: [String] = []
        for i in 0..<MIDIGetNumberOfSources() {
            let source = MIDIGetSource(i)
            guard source != 0 else { continue }
            var name: Unmanaged<CFString>?
            MIDIObjectGetStringProperty(source, kMIDIPropertyDisplayName, &name)
            let display = (name?.takeRetainedValue() as String?) ?? "MIDI 设备"
            // Logic's own virtual output is always there while Logic runs and is not a keyboard:
            // it carries what Logic plays out, which must not be read as keys pressed.
            if display.hasPrefix("Logic Pro") { continue }
            present.insert(source)
            names.append(display)
            if !connected.contains(source) { MIDIPortConnectSource(port, source, nil) }
        }
        for gone in connected.subtracting(present) { MIDIPortDisconnectSource(port, gone) }
        connected = present
        let changed = sources != names
        sources = names
        if changed { onSourcesChanged?() }
    }
}
