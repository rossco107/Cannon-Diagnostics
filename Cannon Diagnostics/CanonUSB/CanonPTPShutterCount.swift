import Foundation
import IOKit
import IOUSBHost

enum CanonPTPShutterCount {
  static func read(registryID: UInt64) async -> String {
    var log = ["EOS shutter count — PTP property 0xD1AC (read-only)"]
    guard let matching = IORegistryEntryIDMatching(registryID) else { return "Registry match failed." }
    let service = IOServiceGetMatchingService(kIOMainPortDefault, matching)
    guard service != 0 else { return "Camera interface unavailable. Wake it and refresh." }
    defer { IOObjectRelease(service) }
    do {
      let usb = try IOUSBHostInterface(__ioService: service, options: [], queue: nil)
      let addresses = endpoints(usb)
      guard let outAddress = addresses.out, let inAddress = addresses.input else {
        return "Bulk IN/OUT endpoints not found."
      }
      let outPipe = try usb.copyPipe(withAddress: Int(outAddress))
      let inPipe = try usb.copyPipe(withAddress: Int(inAddress))
      log.append(String(format: "Bulk OUT 0x%02X, bulk IN 0x%02X", outAddress, inAddress))
      var transaction: UInt32 = 0
      func execute(_ code: UInt16, _ params: [UInt32] = []) async throws -> (UInt16, Data?) {
        let id = transaction
        transaction += 1
        var command = Data()
        put32(&command, UInt32(12 + params.count * 4))
        put16(&command, 1)
        put16(&command, code)
        put32(&command, id)
        for param in params { put32(&command, param) }
        let output = NSMutableData(data: command)
        let (outStatus, outCount) = try await outPipe.enqueueIORequest(with: output, completionTimeout: 5)
        guard outStatus == kIOReturnSuccess, outCount == command.count else {
          throw Failure.message("OUT failed: \(hex(outStatus)), \(outCount)/\(command.count) bytes")
        }
        var payload: Data?
        for _ in 0..<2 {
          let buffer = NSMutableData(length: 16384)!
          let (status, count) = try await inPipe.enqueueIORequest(with: buffer, completionTimeout: 5)
          guard status == kIOReturnSuccess else { throw Failure.message("IN failed: \(hex(status))") }
          let received = Data(bytes: buffer.bytes, count: min(count, buffer.length))
          guard received.count >= 12 else { throw Failure.message("Short PTP container") }
          let length = Int(u32(received, 0))
          let type = u16(received, 4)
          let replyCode = u16(received, 6)
          let replyID = u32(received, 8)
          guard length >= 12, length <= received.count, replyID == id else {
            throw Failure.message("Invalid or incomplete PTP container for transaction \(id)")
          }
          if type == 2 {
            payload = received.subdata(in: 12..<length)
          } else if type == 3 {
            return (replyCode, payload)
          } else {
            throw Failure.message("Unexpected PTP container type \(type)")
          }
        }
        throw Failure.message("Missing PTP response phase")
      }
      let opened = try await execute(0x1002, [1])
      log.append("OpenSession: \(code(opened.0))")
      guard opened.0 == 0x2001 else { return log.joined(separator: "\n") }
      // Probe only the documented shutter-counter property. Do not scan unknown opcodes.
      do {
        let property: UInt16 = 0xD1AC
        let desc = try await execute(0x1014, [UInt32(property)])
        log.append("GetDevicePropDesc 0xD1AC: \(code(desc.0))")
        if desc.0 == 0x2001, let data = desc.1 {
          log.append(describeProperty(data))
        }
        let value = try await execute(0x1015, [UInt32(property)])
        log.append("GetDevicePropValue 0xD1AC: \(code(value.0))")
        if value.0 == 0x2001, let data = value.1 {
          log.append("Raw value: \(preview(data))")
          if data.count == 4 {
            log.append("Shutter count candidate: \(u32(data, 0))")
            log.append("Compare with the earlier reading of 3,559 actuations.")
          } else {
            log.append("Value is not a four-byte counter; no count inferred.")
          }
        } else if value.0 == 0x200A || value.0 == 0x2005 {
          log.append("The camera does not expose this property through standard PTP.")
          log.append("No shutter count was retrieved; Canon-specific investigation is needed.")
        }
      } catch {
        log.append("Shutter-count read failed: \(error)")
      }
      let closed = try await execute(0x1003)
      log.append("CloseSession: \(code(closed.0))")
    } catch {
      log.append("ERROR: \(error)")
    }
    return log.joined(separator: "\n")
  }

  private enum Failure: Error, CustomStringConvertible {
    case message(String)
    var description: String { if case .message(let text) = self { return text }; return "Unknown error" }
  }
  private static func endpoints(_ usb: IOUSBHostInterface) -> (out: UInt8?, input: UInt8?) {
    let base = UnsafeRawPointer(usb.configurationDescriptor).assumingMemoryBound(to: UInt8.self)
    let total = min(Int(base[2]) | (Int(base[3]) << 8), 4096)
    let number = usb.interfaceDescriptor.pointee.bInterfaceNumber
    let alternate = usb.interfaceDescriptor.pointee.bAlternateSetting
    var offset = 0
    var active = false
    var output: UInt8?
    var input: UInt8?
    while offset + 2 <= total {
      let length = Int(base[offset])
      if length < 2 || offset + length > total { break }
      let type = base[offset + 1]
      if type == 4 && length >= 9 {
        active = base[offset + 2] == number && base[offset + 3] == alternate
      } else if type == 5 && length >= 7 && active && base[offset + 3] & 3 == 2 {
        let address = base[offset + 2]
        if address & 0x80 == 0 { output = address } else { input = address }
      }
      offset += length
    }
    return (output, input)
  }
  private static func describeProperty(_ data: Data) -> String {
    guard data.count >= 5 else { return "  Property descriptor incomplete" }
    let property = u16(data, 0)
    let type = u16(data, 2)
    let writable = data[4] != 0
    return "  Property \(code(property)), data type \(code(type)), \(writable ? "writable" : "read-only"); raw descriptor: \(preview(data))"
  }
  private static func preview(_ data: Data) -> String {
    let prefix = data.prefix(64).map { String(format: "%02X", $0) }.joined(separator: " ")
    return prefix + (data.count > 64 ? " …" : "")
  }
  private static func put16(_ data: inout Data, _ value: UInt16) {
    data.append(UInt8(truncatingIfNeeded: value))
    data.append(UInt8(truncatingIfNeeded: value >> 8))
  }
  private static func put32(_ data: inout Data, _ value: UInt32) {
    for shift in stride(from: 0, to: 32, by: 8) { data.append(UInt8(truncatingIfNeeded: value >> shift)) }
  }
  private static func u16(_ data: Data, _ offset: Int) -> UInt16 {
    UInt16(data[offset]) | UInt16(data[offset + 1]) << 8
  }
  private static func u32(_ data: Data, _ offset: Int) -> UInt32 {
    UInt32(data[offset]) | UInt32(data[offset + 1]) << 8 | UInt32(data[offset + 2]) << 16 | UInt32(data[offset + 3]) << 24
  }
  private static func code(_ value: UInt16) -> String { String(format: "0x%04X", value) }
  private static func hex(_ value: IOReturn) -> String { String(format: "0x%08X", UInt32(bitPattern: value)) }
}
