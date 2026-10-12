import Foundation
import IOKit
import IOUSBHost
import SwiftUI

// Temporary read-only PTP capability probe. No remote-mode or property writes.
enum CanonPTPProbe {
  private enum ProbeError: Error, CustomStringConvertible {
    case message(String)
    var description: String { if case .message(let s) = self { return s }; return "Unknown error" }
  }
  private static func u16(_ d: Data, _ i: Int) -> UInt16 { UInt16(d[i]) | UInt16(d[i + 1]) << 8 }
  private static func u32(_ d: Data, _ i: Int) -> UInt32 {
    UInt32(d[i]) | UInt32(d[i + 1]) << 8 | UInt32(d[i + 2]) << 16 | UInt32(d[i + 3]) << 24
  }
  private static func put16(_ d: inout Data, _ v: UInt16) { d.append(UInt8(truncatingIfNeeded: v)); d.append(UInt8(truncatingIfNeeded: v >> 8)) }
  private static func put32(_ d: inout Data, _ v: UInt32) {
    for shift in stride(from: 0, to: 32, by: 8) { d.append(UInt8(truncatingIfNeeded: v >> shift)) }
  }
  private static func hex(_ n: UInt16) -> String { String(format: "0x%04X", n) }
  private static func endpoints(_ usb: IOUSBHostInterface) -> (UInt8?, UInt8?) {
    let p = UnsafeRawPointer(usb.configurationDescriptor).assumingMemoryBound(to: UInt8.self)
    let total = min(Int(p[2]) | Int(p[3]) << 8, 4096)
    let number = usb.interfaceDescriptor.pointee.bInterfaceNumber
    let alt = usb.interfaceDescriptor.pointee.bAlternateSetting
    var offset = 0, active = false
    var output: UInt8?, input: UInt8?
    while offset + 2 <= total {
      let size = Int(p[offset])
      if size < 2 || offset + size > total { break }
      if p[offset + 1] == 4 && size >= 9 {
        active = p[offset + 2] == number && p[offset + 3] == alt
      } else if p[offset + 1] == 5 && size >= 7 && active && p[offset + 3] & 3 == 2 {
        let address = p[offset + 2]
        if address & 0x80 == 0 { output = address } else { input = address }
      }
      offset += size
    }
    return (output, input)
  }
  private struct DeviceInfo {
    let operations: [UInt16]
    let properties: [UInt16]
    let summary: String
  }
  private static func parseDeviceInfo(_ d: Data) throws -> DeviceInfo {
    var p = 0
    func read16() throws -> UInt16 {
      guard p + 2 <= d.count else { throw ProbeError.message("Truncated DeviceInfo") }
      defer { p += 2 }; return u16(d, p)
    }
    func read32() throws -> UInt32 {
      guard p + 4 <= d.count else { throw ProbeError.message("Truncated DeviceInfo") }
      defer { p += 4 }; return u32(d, p)
    }
    func string() throws -> String {
      guard p < d.count else { throw ProbeError.message("Truncated PTP string") }
      let count = Int(d[p]); p += 1
      guard p + count * 2 <= d.count else { throw ProbeError.message("Invalid PTP string") }
      var units: [UInt16] = []
      for _ in 0..<count { units.append(try read16()) }
      if units.last == 0 { units.removeLast() }
      return String(decoding: units, as: UTF16.self)
    }
    func array() throws -> [UInt16] {
      let count = Int(try read32())
      guard count <= 4096, p + count * 2 <= d.count else { throw ProbeError.message("Invalid PTP array") }
      var result: [UInt16] = []
      for _ in 0..<count { result.append(try read16()) }
      return result
    }
    _ = try read16(); _ = try read32(); _ = try read16()
    _ = try string(); _ = try read16()
    let operations = try array()
    _ = try array()
    let properties = try array()
    _ = try array(); _ = try array()
    let manufacturer = try string(), model = try string(), version = try string()
    return DeviceInfo(operations: operations, properties: properties,
      summary: "\(manufacturer) \(model) — \(version)")
  }
  static func run(registryID: UInt64) async -> String {
    var lines = ["Read-only Canon PTP capability probe"]
    guard let match = IORegistryEntryIDMatching(registryID) else { return "Registry matching failed" }
    let service = IOServiceGetMatchingService(kIOMainPortDefault, match)
    guard service != 0 else { return "Camera USB interface not found" }
    defer { IOObjectRelease(service) }
    do {
      let usb = try IOUSBHostInterface(__ioService: service, options: [], queue: nil)
      let addresses = endpoints(usb)
      guard let outAddress = addresses.0, let inAddress = addresses.1 else {
        return "No bulk PTP endpoints found"
      }
      let outPipe = try usb.copyPipe(withAddress: Int(outAddress))
      let inPipe = try usb.copyPipe(withAddress: Int(inAddress))
      var transaction: UInt32 = 1
      // Reads complete USB PTP containers, including multi-packet data phases.
      func receive() async throws -> (UInt16, UInt16, UInt32, Data) {
        var accumulated = Data()
        var expected: Int?
        while true {
          let buffer = NSMutableData(length: 65536)!
          let (status, count) = try await inPipe.enqueueIORequest(with: buffer, completionTimeout: 5)
          guard status == kIOReturnSuccess, count > 0 else { throw ProbeError.message("USB read failed: \(status)") }
          accumulated.append(Data(bytes: buffer.bytes, count: min(count, buffer.length)))
          if expected == nil && accumulated.count >= 12 {
            expected = Int(u32(accumulated, 0))
            guard let expected, expected >= 12, expected <= 2_000_000 else {
              throw ProbeError.message("Invalid PTP container length")
            }
          }
          if let expected, accumulated.count >= expected {
            guard accumulated.count == expected else { throw ProbeError.message("Unexpected trailing USB data") }
            return (u16(accumulated, 4), u16(accumulated, 6), u32(accumulated, 8), accumulated.subdata(in: 12..<expected))
          }
        }
      }
      func execute(_ operation: UInt16, _ parameters: [UInt32] = []) async throws -> (UInt16, Data?) {
        let id = transaction; transaction += 1
        var command = Data()
        put32(&command, UInt32(12 + parameters.count * 4))
        put16(&command, 1); put16(&command, operation); put32(&command, id)
        for value in parameters { put32(&command, value) }
        let output = NSMutableData(data: command)
        let (status, count) = try await outPipe.enqueueIORequest(with: output, completionTimeout: 5)
        guard status == kIOReturnSuccess, count == command.count else {
          throw ProbeError.message("USB command failed: \(status)")
        }
        var payload: Data?
        for _ in 0..<2 {
          let (type, code, replyID, data) = try await receive()
          guard replyID == id else { throw ProbeError.message("PTP transaction mismatch") }
          if type == 2 { payload = data }
          else if type == 3 { return (code, payload) }
          else { throw ProbeError.message("Unexpected PTP container type \(type)") }
        }
        throw ProbeError.message("Missing PTP response")
      }
      let standard = try await execute(0x1001)
      lines.append("GetDeviceInfo: \(hex(standard.0))")
      guard standard.0 == 0x2001, let data = standard.1 else { return lines.joined(separator: "\n") }
      let info = try parseDeviceInfo(data)
      lines.append(info.summary)
      lines.append("\nOPERATIONS (\(info.operations.count))")
      for value in info.operations { lines.append(hex(value)) }
      lines.append("\nPROPERTIES (\(info.properties.count))")
      for value in info.properties { lines.append(hex(value)) }
      guard info.operations.contains(0x9108) else {
        lines.append("\nEOS_GetDeviceInfoEx (0x9108) not advertised; not attempted.")
        return lines.joined(separator: "\n")
      }
      let opened = try await execute(0x1002, [1])
      lines.append("\nOpenSession: \(hex(opened.0))")
      guard opened.0 == 0x2001 else { return lines.joined(separator: "\n") }
      do {
        let extended = try await execute(0x9108)
        lines.append("EOS_GetDeviceInfoEx: \(hex(extended.0))")
        if let payload = extended.1 {
          lines.append("Extended payload: \(payload.count) bytes")
          // Hex is intentionally preserved; its proprietary structure is not assumed.
          lines.append("EXTENDED DATA (hex):")
          for offset in stride(from: 0, to: payload.count, by: 16) {
            let part = payload[offset..<min(offset + 16, payload.count)]
            lines.append(String(format: "%04X: ", offset) + part.map { String(format: "%02X", $0) }.joined(separator: " "))
          }
        }
      } catch { lines.append("Extended query error: \(error)") }
      do {
        let closed = try await execute(0x1003)
        lines.append("CloseSession: \(hex(closed.0))")
      } catch { lines.append("CloseSession error: \(error)") }
    } catch { lines.append("ERROR: \(error)") }
    return lines.joined(separator: "\n")
  }
}

// Temporary standalone UI. Change the app's WindowGroup root to CanonPTPProbeView().
struct CanonPTPProbeView: View {
  @State private var devices: [CanonUSBDevice] = []
  @State private var output = "Connect and switch on the camera, then press Refresh."
  @State private var busy = false
  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack {
        Text("Canon PTP Capability Probe").font(.title2.bold())
        Spacer()
        Button("Refresh") { devices = CanonUSBDiscovery.scan() }.disabled(busy)
      }
      if let camera = devices.first,
         let ptp = camera.interfaces.first(where: { $0.interfaceClass == 6 }) {
        Text(camera.name)
        Button("Read PTP capabilities") {
          busy = true
          Task {
            output = await CanonPTPProbe.run(registryID: ptp.id)
            busy = false
          }
        }.disabled(busy)
      } else {
        Text("No Canon PTP interface detected")
      }
      ScrollView {
        Text(output).font(.system(.callout, design: .monospaced))
          .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
      }
    }
    .padding(20)
    .frame(minWidth: 720, minHeight: 520)
    .onAppear { devices = CanonUSBDiscovery.scan() }
  }
}
