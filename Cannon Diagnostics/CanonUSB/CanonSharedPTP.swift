// Canon Diagnostics — shared macOS ImageCaptureCore transport
import Foundation
import Combine
import ImageCaptureCore
import AppKit
import UniformTypeIdentifiers

@MainActor
final class CanonSharedPTP: NSObject, ObservableObject, ICDeviceBrowserDelegate {
  @Published private(set) var cameras: [ICCameraDevice] = []
  @Published private(set) var busy = false
  @Published var status = "Connect and switch on a Canon EOS camera."
  @Published var deviceInfo = ""
  @Published var properties = ""
  @Published var eosEvents = ""
  @Published var ownerStatus = ""
  @Published var dustDiagnostics = ""
  private let browser = ICDeviceBrowser()
  private var transaction: UInt32 = 1
  private var cameraGeneration = 0
  private var dustLines: [String] = []
  @Published private(set) var rawDustEvent: Data?
  @Published var rawDustSaveStatus = ""

  var camera: ICCameraDevice? { cameras.first(where: { $0.usbVendorID == 0x04A9 }) }

  override init() {
    super.init()
    browser.delegate = self
    browser.browsedDeviceTypeMask = .camera
  }
  func start() { if !browser.isBrowsing { browser.start() } }
  func stop() { if browser.isBrowsing { browser.stop() } }
  func deviceBrowser(_ browser: ICDeviceBrowser, didAdd device: ICDevice, moreComing: Bool) {
    guard let camera = device as? ICCameraDevice else { return }
    if !cameras.contains(where: { $0 === camera }) {
      cameras.append(camera)
      cameraGeneration += 1
      clearCameraReadings()
    }
    status = "Camera discovered: \(camera.name ?? "Unknown")"
  }
  func deviceBrowser(_ browser: ICDeviceBrowser, didRemove device: ICDevice, moreGoing: Bool) {
    cameras.removeAll { $0 === device }
    cameraGeneration += 1
    clearCameraReadings()
    status = cameras.isEmpty ? "Camera disconnected." : "Camera list updated."
  }
  private func clearCameraReadings() {
    deviceInfo = ""
    properties = ""
    eosEvents = ""
    ownerStatus = ""
    dustDiagnostics = ""
    rawDustEvent = nil
    rawDustSaveStatus = ""
  }
  func refresh() {
    cameraGeneration += 1
    clearCameraReadings()
    stop()
    start()
  }

  // ImageCaptureCore owns the PTP session; do not send PTP OpenSession/CloseSession.
  private func withSession<T>(_ action: (ICCameraDevice) async throws -> T) async throws -> T {
    guard let camera else { throw PTPError.message("No Canon camera discovered by ImageCaptureCore.") }
    let alreadyOpen = camera.hasOpenSession
    if !alreadyOpen { try await camera.requestOpenSession(options: nil) }
    do {
      let result = try await action(camera)
      if !alreadyOpen { try? await camera.requestCloseSession(options: nil) }
      return result
    } catch {
      if !alreadyOpen { try? await camera.requestCloseSession(options: nil) }
      throw error
    }
  }
  private func execute(_ camera: ICCameraDevice, _ operation: UInt16, _ params: [UInt32] = [], send: Data? = nil) async throws -> (UInt16, Data) {
    let id = transaction
    transaction &+= 1
    var command = Data()
    put32(&command, UInt32(12 + params.count * 4))
    put16(&command, 1)
    put16(&command, operation)
    put32(&command, id)
    for param in params { put32(&command, param) }
    let (data, response) = try await camera.requestSendPTPCommand(command, outData: send)
    guard response.count >= 12, u16(response, 4) == 3 else {
      throw PTPError.message(String(format: "Invalid response to 0x%04X", operation))
    }
    return (u16(response, 6), data)
  }
  func readCamera() {
    guard !busy else { return }
    busy = true
    let generation = cameraGeneration
    status = "Reading camera…"
    Task {
      do {
        try await withSession { camera in
          let info = try await execute(camera, 0x1001)
          guard generation == cameraGeneration else { return }
          deviceInfo = "GetDeviceInfo: \(code(info.0))\n" + describeDeviceInfo(info.1)
          var lines = ["PTP device properties"]
          for prop: UInt16 in [0xD402, 0xD407, 0xD406] {
            let desc = try await execute(camera, 0x1014, [UInt32(prop)])
            lines.append("GetDevicePropDesc \(code(prop)): \(code(desc.0)); \(desc.1.count) bytes")
            let value = try await execute(camera, 0x1015, [UInt32(prop)])
            lines.append("GetDevicePropValue \(code(prop)): \(code(value.0)), data bytes: \(preview(value.1))")
          }
          guard generation == cameraGeneration else { return }
          properties = lines.joined(separator: "\n")
          let events = await readEOS(camera)
          guard generation == cameraGeneration else { return }
          eosEvents = events
        }
        if generation == cameraGeneration { status = "Camera read complete." }
      } catch {
        if generation == cameraGeneration { status = "Read failed: \(error.localizedDescription)" }
      }
      busy = false
    }
  }
  private func readEOS(_ camera: ICCameraDevice) async -> String {
    var lines = ["Canon EOS event/property diagnostics"]
    var remote = false
    var events = false
    var owner: String?
    var nickname: String?
    var shutter: UInt32?
    var shots: UInt32?
    var serial: UInt32?
    var battery: UInt32?
    do {
      let r = try await execute(camera, 0x9114, [1])
      lines.append("SetRemoteMode(1): \(code(r.0))")
      remote = r.0 == 0x2001
      if remote {
        let e = try await execute(camera, 0x9115, [1])
        lines.append("SetEventMode(1): \(code(e.0))")
        events = e.0 == 0x2001
      }
      if events {
        for attempt in 1...4 {
          let poll = try await execute(camera, 0x9116)
          lines.append("GetEvent #\(attempt): \(code(poll.0)); \(poll.1.count) bytes")
          guard poll.0 == 0x2001 else { break }
          let parsed = CanonEOSEventDecoder.parse(poll.1)
          lines.append(contentsOf: parsed.lines)
          if let value = parsed.owner { owner = value }
          if let value = parsed.nickname { nickname = value }
          if let value = parsed.shutterCount { shutter = value }
          if let value = parsed.availableShots { shots = value }
          if let value = parsed.eosSerial { serial = value }
          if let value = parsed.batteryPower { battery = value }
          if parsed.eventCount == 0 { break }
        }
        // Some EOS bodies, including the 50D, do not emit every property
        // in the initial event burst. Request missing values explicitly.
        for property: UInt32 in [0xD115, 0xD1AF] {
          if property == 0xD115 && owner != nil { continue }
          if property == 0xD1AF && serial != nil { continue }
          let request = try await execute(camera, 0x9127, [property])
          lines.append(String(format: "Request EOS property 0x%04X: %@", property, code(request.0)))
          guard request.0 == 0x2001 else { continue }
          for attempt in 1...4 {
            let poll = try await execute(camera, 0x9116)
            lines.append("Property poll #\(attempt): \(code(poll.0)); \(poll.1.count) bytes")
            guard poll.0 == 0x2001 else { break }
            let parsed = CanonEOSEventDecoder.parse(poll.1)
            lines.append(contentsOf: parsed.lines)
            if let value = parsed.owner { owner = value }
            if let value = parsed.eosSerial { serial = value }
            if property == 0xD115 && owner != nil { break }
            if property == 0xD1AF && serial != nil { break }
            if parsed.eventCount == 0 { break }
          }
        }
      }
    } catch { lines.append("EOS diagnostic error: \(error)") }
    if events { _ = try? await execute(camera, 0x9115, [0]) }
    if remote { _ = try? await execute(camera, 0x9114, [0]) }
    lines.append("SHUTTER COUNT CANDIDATE: " + (shutter.map(String.init) ?? "Not available"))
    lines.append("OWNER NAME: " + (owner ?? "Not available"))
    lines.append("CAMERA NICKNAME: " + (nickname ?? "Not available"))
    lines.append("AVAILABLE SHOTS: " + (shots.map(String.init) ?? "Not available"))
    lines.append("EOS SERIAL RAW: " + (serial.map { String(format: "0x%08X", $0) } ?? "Not available"))
    lines.append("EOS BATTERY RAW: " + (battery.map(String.init) ?? "Not available"))
    return lines.joined(separator: "\n")
  }
  // Read-only inventory: inspect advertised PTP capabilities and EOS property events.
  // Does not assume that a camera-side dust-calibration getter exists.
  func inspectDustData() {
    guard !busy else {
      dustDiagnostics = "Inspection could not start: another camera operation is running."
      return
    }
    busy = true
    rawDustEvent = nil
    rawDustSaveStatus = ""
    status = "Inspecting camera capabilities…"
    dustLines = ["Canon EOS dust-data investigation", "Read-only inventory; no undocumented commands."]
    dustDiagnostics = dustLines.joined(separator: "\n")
    Task { @MainActor in
      do {
        try await withSession { camera in
          recordDust("Camera: \(camera.name ?? "Unknown")")
          recordDust("PTP session opened through ImageCaptureCore.")
          do {
            let info = try await execute(camera, 0x1001)
            recordDust("GetDeviceInfo: \(code(info.0)); \(info.1.count) bytes")
            if info.0 == 0x2001 {
              for line in capabilityInventory(info.1) { recordDust(line) }
            }
          } catch { recordDust("GetDeviceInfo error: \(error.localizedDescription)") }
          do {
            let extended = try await execute(camera, 0x9108)
            recordDust("Canon EOS GetDeviceInfoEx (0x9108): \(code(extended.0)); \(extended.1.count) bytes")
            if extended.0 == 0x2001 { recordDust("Extended data preview: \(preview(extended.1))") }
          } catch { recordDust("GetDeviceInfoEx error: \(error.localizedDescription)") }
          var remote = false
          var events = false
          do {
            let r = try await execute(camera, 0x9114, [1])
            recordDust("SetRemoteMode(1): \(code(r.0))")
            remote = r.0 == 0x2001
            if remote {
              let e = try await execute(camera, 0x9115, [1])
              recordDust("SetEventMode(1): \(code(e.0))")
              events = e.0 == 0x2001
            }
            if events {
              for attempt in 1...4 {
                let result = try await execute(camera, 0x9116)
                recordDust("GetEvent #\(attempt): \(code(result.0)); \(result.1.count) bytes")
                guard result.0 == 0x2001 else { break }
                if rawDustEvent == nil && result.1.count > 8 { rawDustEvent = result.1 }
                let records = inventoryEOSRecords(result.1)
                for line in records.lines { recordDust(line) }
                if records.count == 0 { break }
              }
              // Explicitly request properties which some models omit from initial events.
              for property: UInt32 in [0xD115, 0xD1AF] {
                let request = try await execute(camera, 0x9127, [property])
                recordDust(String(format: "Request EOS property 0x%04X: %@", property, code(request.0)))
                guard request.0 == 0x2001 else { continue }
                for attempt in 1...4 {
                  let poll = try await execute(camera, 0x9116)
                  recordDust("Requested property poll #\(attempt): \(code(poll.0)); \(poll.1.count) bytes")
                  guard poll.0 == 0x2001 else { break }
                  let records = inventoryEOSRecords(poll.1)
                  for line in records.lines { recordDust(line) }
                  if records.count == 0 { break }
                }
              }
            }
          } catch { recordDust("EOS inventory error: \(error.localizedDescription)") }
          if events {
            let result = try? await execute(camera, 0x9115, [0])
            recordDust("SetEventMode(0): \(result.map { code($0.0) } ?? "failed")")
          }
          if remote {
            let result = try? await execute(camera, 0x9114, [0])
            recordDust("SetRemoteMode(0): \(result.map { code($0.0) } ?? "failed")")
          }
        }
        recordDust("Inspection complete. These records do not establish whether Dust Delete Data is directly readable.")
        status = "Dust-data inspection complete."
      } catch {
        recordDust("Inspection failed: \(error.localizedDescription)")
        status = "Dust-data inspection failed."
      }
      busy = false
    }
  }

  func exportPropertyInventory() {
    guard !dustDiagnostics.isEmpty else {
      rawDustSaveStatus = "Collect the property inventory first."
      return
    }
    let panel = NSSavePanel()
    panel.title = "Export Canon EOS property inventory"
    let model = camera?.name?.replacingOccurrences(of: " ", with: "-") ?? "CanonEOS"
    panel.nameFieldStringValue = "\(model)-Properties.txt"
    panel.allowedContentTypes = [.plainText]
    panel.canCreateDirectories = true
    guard panel.runModal() == .OK, let url = panel.url else { return }
    do {
      let text = "Camera: \(camera?.name ?? "Disconnected")\n\n" + dustDiagnostics
      try text.write(to: url, atomically: true, encoding: .utf8)
      rawDustSaveStatus = "Exported \(url.lastPathComponent)."
    } catch { rawDustSaveStatus = "Export failed: \(error.localizedDescription)" }
  }

  // Saves the complete first non-empty 0x9116 GetEvent payload, without truncating property values.
  func saveRawDustEvent() {
    guard let data = rawDustEvent else {
      rawDustSaveStatus = "Run Inspect Dust Data first."
      return
    }
    let panel = NSSavePanel()
    panel.title = "Save complete EOS event response"
    panel.nameFieldStringValue = "\(camera?.name?.replacingOccurrences(of: " ", with: "-") ?? "CanonEOS")-GetEvent.bin"
    panel.allowedContentTypes = [.data]
    panel.canCreateDirectories = true
    if panel.runModal() == .OK, let url = panel.url {
      do {
        try data.write(to: url, options: .atomic)
        rawDustSaveStatus = "Saved \(data.count) bytes to \(url.lastPathComponent)."
      } catch {
        rawDustSaveStatus = "Save failed: \(error.localizedDescription)"
      }
    }
  }

  private func recordDust(_ message: String) {
    dustLines.append(message)
    dustDiagnostics = dustLines.joined(separator: "\n")
  }

  private func capabilityInventory(_ data: Data) -> [String] {
    var offset = 0
    func skip(_ length: Int) -> Bool {
      guard length >= 0, offset + length <= data.count else { return false }
      offset += length
      return true
    }
    func read16() -> UInt16? {
      guard offset + 2 <= data.count else { return nil }
      defer { offset += 2 }
      return u16(data, offset)
    }
    func read32() -> UInt32? {
      guard offset + 4 <= data.count else { return nil }
      defer { offset += 4 }
      return u32(data, offset)
    }
    func readArray() -> [UInt16]? {
      guard let count = read32(), count <= 4096, offset + Int(count) * 2 <= data.count else { return nil }
      return (0..<Int(count)).compactMap { _ in read16() }
    }
    guard skip(2 + 4 + 2), offset < data.count else { return ["DeviceInfo header incomplete"] }
    let vendorStringLength = Int(data[offset])
    guard skip(1 + vendorStringLength * 2 + 2) else { return ["DeviceInfo vendor extension malformed"] }
    guard let operations = readArray(), let events = readArray(), let properties = readArray(), let captureFormats = readArray(), let imageFormats = readArray() else {
      return ["DeviceInfo capability arrays malformed or incomplete"]
    }
    func codes(_ values: [UInt16]) -> String { values.map { code($0) }.joined(separator: " ") }
    return [
      "Advertised operations (\(operations.count)): \(codes(operations))",
      "Advertised events (\(events.count)): \(codes(events))",
      "Advertised device properties (\(properties.count)): \(codes(properties))",
      "Capture formats: \(codes(captureFormats))",
      "Image formats: \(codes(imageFormats))"
    ]
  }

  private func inventoryEOSRecords(_ data: Data) -> (lines: [String], count: Int) {
    var lines: [String] = []
    var offset = 0
    var count = 0
    while offset + 8 <= data.count && count < 512 {
      let size = Int(u32(data, offset))
      let kind = u32(data, offset + 4)
      if size == 0 { break }
      guard size >= 8, offset + size <= data.count else {
        lines.append("Malformed record at offset \(offset): size \(size)")
        break
      }
      count += 1
      let payload = data.subdata(in: (offset + 8)..<(offset + size))
      if kind == 0xC189 && payload.count >= 4 {
        let property = u32(payload, 0)
        let value = payload.dropFirst(4)
        let label = property == 0xD1AC ? " [known shutter count]" : property == 0xD115 ? " [known owner name]" : ""
        lines.append(String(format: "EOS property 0x%04X%@ — %d value bytes: %@", property, label, value.count, preview(Data(value))))
      } else {
        lines.append(String(format: "EOS event 0x%04X — %d payload bytes: %@", kind, payload.count, preview(payload)))
      }
      offset += size
    }
    if count == 0 { lines.append("No EOS event records in this poll.") }
    return (lines, count)
  }

  func saveOwner(_ name: String) {
    let bytes = Array(name.utf8)
    guard !busy, !bytes.isEmpty, bytes.count <= 255, bytes.allSatisfy({ $0 >= 32 && $0 <= 126 }) else {
      ownerStatus = "Owner name must be 1–255 printable ASCII characters."
      return
    }
    busy = true
    ownerStatus = "Saving owner name…"
    Task {
      do {
        try await withSession { camera in
          let remote = try await execute(camera, 0x9114, [1])
          guard remote.0 == 0x2001 else { throw PTPError.message("Remote mode: \(code(remote.0))") }
          let event = try await execute(camera, 0x9115, [1])
          guard event.0 == 0x2001 else { throw PTPError.message("Event mode: \(code(event.0))") }
          // Clear initial property events so verification does not use stale state.
          for _ in 0..<3 {
            let poll = try await execute(camera, 0x9116)
            if poll.0 != 0x2001 || poll.1.count <= 8 { break }
          }
          var property = Data()
          put32(&property, UInt32(8 + bytes.count + 1))
          put32(&property, 0xD115)
          property.append(contentsOf: bytes)
          property.append(0)
          let result = try await execute(camera, 0x9110, send: property)
          guard result.0 == 0x2001 else { throw PTPError.message("Camera rejected write: \(code(result.0))") }
          ownerStatus = "Camera accepted owner name; checking readback…"
          let request = try await execute(camera, 0x9127, [0xD115])
          var verified = false
          if request.0 == 0x2001 {
            for _ in 0..<4 {
              let poll = try await execute(camera, 0x9116)
              guard poll.0 == 0x2001 else { break }
              if let confirmed = CanonEOSEventDecoder.parse(poll.1).owner {
                verified = confirmed == name
                ownerStatus = verified ? "Owner name saved and verified." : "Write accepted; readback was \(confirmed)."
                break
              }
            }
          }
          if !verified && ownerStatus == "Camera accepted owner name; checking readback…" {
            ownerStatus = "Write accepted, but the 50D did not confirm the saved name."
          }
          _ = try? await execute(camera, 0x9115, [0])
          _ = try? await execute(camera, 0x9114, [0])
          eosEvents = await readEOS(camera)
          if eosEvents.contains("OWNER NAME: \(name)") { ownerStatus = "Owner name saved and verified." }
        }
      } catch { ownerStatus = "Owner update failed: \(error.localizedDescription)" }
      busy = false
    }
  }
  private func describeDeviceInfo(_ data: Data) -> String {
    var offset = 0
    func word() -> UInt16? {
      guard offset + 2 <= data.count else { return nil }
      defer { offset += 2 }
      return u16(data, offset)
    }
    func dword() -> UInt32? {
      guard offset + 4 <= data.count else { return nil }
      defer { offset += 4 }
      return u32(data, offset)
    }
    func skipWords() {
      guard let count = dword(), count < 2048 else { return }
      offset = min(data.count, offset + Int(count) * 2)
    }
    func string() -> String {
      guard offset < data.count else { return "—" }
      let count = Int(data[offset]); offset += 1
      guard offset + count * 2 <= data.count else { return "—" }
      let units = (0..<count).map { u16(data, offset + $0 * 2) }
      offset += count * 2
      return String(decoding: units.prefix(while: { $0 != 0 }), as: UTF16.self)
    }
    _ = word(); _ = dword(); _ = word()
    let vendor = string()
    _ = word()
    skipWords(); skipWords(); skipWords(); skipWords(); skipWords()
    return "Vendor extension: \(vendor)\nManufacturer: \(string())\nModel: \(string())\nDevice version: \(string())\nSerial: \(string())"
  }
  private func put16(_ data: inout Data, _ value: UInt16) {
    data.append(UInt8(truncatingIfNeeded: value))
    data.append(UInt8(truncatingIfNeeded: value >> 8))
  }
  private func put32(_ data: inout Data, _ value: UInt32) {
    for shift in stride(from: 0, to: 32, by: 8) { data.append(UInt8(truncatingIfNeeded: value >> shift)) }
  }
  private func u16(_ data: Data, _ offset: Int) -> UInt16 {
    UInt16(data[offset]) | UInt16(data[offset + 1]) << 8
  }
  private func u32(_ data: Data, _ offset: Int) -> UInt32 {
    UInt32(data[offset]) | UInt32(data[offset + 1]) << 8 | UInt32(data[offset + 2]) << 16 | UInt32(data[offset + 3]) << 24
  }
  private func code(_ value: UInt16) -> String { String(format: "0x%04X", value) }
  private func preview(_ data: Data) -> String { data.prefix(64).map { String(format: "%02X", $0) }.joined(separator: " ") }
  private enum PTPError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case .message(let message) = self { return message }; return nil }
  }
}
