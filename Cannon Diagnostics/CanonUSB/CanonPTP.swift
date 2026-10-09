import Foundation
import IOKit
import IOUSBHost

enum CanonPTP {
  static func getDeviceInfo(registryID: UInt64) async -> String {
    var log = ["PTP GetDeviceInfo (0x1001) — read-only"]
    guard let matching = IORegistryEntryIDMatching(registryID) else { return "Registry match failed." }
    let service = IOServiceGetMatchingService(kIOMainPortDefault, matching)
    guard service != 0 else { return "Camera interface unavailable. Wake it and refresh." }
    defer { IOObjectRelease(service) }
    do {
      let usb = try IOUSBHostInterface(__ioService: service, options: [], queue: nil)
      let endpoints = endpointAddresses(usb)
      log.append("Endpoints: " + endpoints.map { String(format: "0x%02X", $0.address) + " (" + $0.kind + ")" }.joined(separator: ", "))
      guard let outAddress = endpoints.first(where: { $0.kind == "bulk OUT" })?.address,
            let inAddress = endpoints.first(where: { $0.kind == "bulk IN" })?.address else {
        return (log + ["Missing bulk IN/OUT endpoint; no command sent."]).joined(separator: "\n")
      }
      let outPipe = try usb.copyPipe(withAddress: Int(outAddress))
      let inPipe = try usb.copyPipe(withAddress: Int(inAddress))
      // PTP USB command container: length 12, type 1, operation 0x1001, transaction 1.
      let command = NSMutableData(data: Data([12, 0, 0, 0, 1, 0, 1, 16, 1, 0, 0, 0]))
      log.append("OUT: 12-byte GetDeviceInfo command; transaction 1")
      let (outStatus, outCount) = try await outPipe.enqueueIORequest(with: command, completionTimeout: 5)
      guard outStatus == kIOReturnSuccess, outCount == 12 else {
        return (log + ["OUT failed: status \(hex(outStatus)), transferred \(outCount) bytes"]).joined(separator: "\n")
      }
      let input = NSMutableData(length: 16384)!
      let (inStatus, inCount) = try await inPipe.enqueueIORequest(with: input, completionTimeout: 5)
      guard inStatus == kIOReturnSuccess else {
        return (log + ["IN failed: \(hex(inStatus))"]).joined(separator: "\n")
      }
      let received = Data(bytes: input.bytes, count: min(inCount, input.length))
      log.append("IN: \(received.count) bytes")
      guard received.count >= 12 else { return (log + ["Short PTP container."]).joined(separator: "\n") }
      let size = Int(u32(received, 0))
      let type = u16(received, 4)
      let code = u16(received, 6)
      let transaction = u32(received, 8)
      log.append(String(format: "Container: type %d, code 0x%04X, transaction %d, declared %d bytes", type, code, transaction, size))
      guard transaction == 1, size >= 12, size <= received.count else {
        return (log + ["Unexpected or incomplete PTP container."]).joined(separator: "\n")
      }
      if type == 2 {
        let payload = received.subdata(in: 12..<size)
        log.append(contentsOf: describeDeviceInfo(payload))
        // GetDeviceInfo has a data phase followed by a response phase.
        let response = NSMutableData(length: 512)!
        let (status, count) = try await inPipe.enqueueIORequest(with: response, completionTimeout: 5)
        if status == kIOReturnSuccess && count >= 12 {
          let data = Data(bytes: response.bytes, count: min(count, response.length))
          log.append(String(format: "Response: 0x%04X (0x2001 means OK)", u16(data, 6)))
        } else {
          log.append("Response read failed: \(hex(status)), \(count) bytes")
        }
      } else if type == 3 {
        log.append("Camera returned a response without a data phase: \(String(format: "0x%04X", code))")
      } else {
        log.append("Unexpected container type; no further reads.")
      }
    } catch {
      let ns = error as NSError
      log.append("ERROR: \(ns.localizedDescription) [\(ns.domain): \(ns.code)]")
    }
    return log.joined(separator: "\n")
  }

  private struct Endpoint {
    let address: UInt8
    let kind: String
  }

  private static func endpointAddresses(_ usb: IOUSBHostInterface) -> [Endpoint] {
    let base = UnsafeRawPointer(usb.configurationDescriptor).assumingMemoryBound(to: UInt8.self)
    let total = min(Int(base[2]) | (Int(base[3]) << 8), 4096)
    let wanted = usb.interfaceDescriptor.pointee.bInterfaceNumber
    let alternate = usb.interfaceDescriptor.pointee.bAlternateSetting
    var offset = 0
    var active = false
    var found: [Endpoint] = []
    while offset + 2 <= total {
      let length = Int(base[offset])
      if length < 2 || offset + length > total { break }
      let type = base[offset + 1]
      if type == 4 && length >= 9 {
        active = base[offset + 2] == wanted && base[offset + 3] == alternate
      } else if type == 5 && length >= 7 && active {
        let address = base[offset + 2]
        let transfer = base[offset + 3] & 3
        let direction = address & 0x80 == 0 ? "OUT" : "IN"
        let kind = transfer == 2 ? "bulk \(direction)" : (transfer == 3 ? "interrupt \(direction)" : "other \(direction)")
        found.append(Endpoint(address: address, kind: kind))
      }
      offset += length
    }
    return found
  }

  private static func describeDeviceInfo(_ data: Data) -> [String] {
    var cursor = 0
    func read16() -> UInt16? {
      guard cursor + 2 <= data.count else { return nil }
      let result = u16(data, cursor)
      cursor += 2
      return result
    }
    func read32() -> UInt32? {
      guard cursor + 4 <= data.count else { return nil }
      let result = u32(data, cursor)
      cursor += 4
      return result
    }
    func readString() -> String? {
      guard cursor < data.count else { return nil }
      let count = Int(data[cursor]); cursor += 1
      guard cursor + count * 2 <= data.count else { return nil }
      var units: [UInt16] = []
      for _ in 0..<count { units.append(u16(data, cursor)); cursor += 2 }
      if units.last == 0 { units.removeLast() }
      return String(decoding: units, as: UTF16.self)
    }
    func readArray() -> [UInt16]? {
      guard let count = read32(), count <= 4096, cursor + Int(count) * 2 <= data.count else { return nil }
      return (0..<Int(count)).compactMap { _ in read16() }
    }
    guard let standard = read16(), let vendor = read32(), let extensionVersion = read16(),
          let extensionName = readString(), let mode = read16(),
          let operations = readArray(), let events = readArray(),
          let properties = readArray(), let captures = readArray(), let images = readArray(),
          let manufacturer = readString(), let model = readString(),
          let version = readString(), let serial = readString() else {
      return ["DeviceInfo payload incomplete or not standard PTP (\(data.count) bytes)."]
    }
    return [
      "Manufacturer: \(manufacturer)", "Model: \(model)", "Device version: \(version)",
      "Serial: \(serial)", "PTP standard: \(standard)",
      String(format: "Vendor extension: 0x%08X, version %d, %@", vendor, extensionVersion, extensionName),
      "Functional mode: \(mode)",
      "Supported operations (\(operations.count)): " + codes(operations),
      "Supported events (\(events.count)): " + codes(events),
      "Supported properties (\(properties.count)): " + codes(properties),
      "Capture formats: " + codes(captures), "Image formats: " + codes(images)
    ]
  }

  private static func codes(_ values: [UInt16]) -> String {
    values.map { String(format: "0x%04X", $0) }.joined(separator: ", ")
  }
  private static func u16(_ data: Data, _ offset: Int) -> UInt16 {
    UInt16(data[offset]) | (UInt16(data[offset + 1]) << 8)
  }
  private static func u32(_ data: Data, _ offset: Int) -> UInt32 {
    UInt32(data[offset]) | (UInt32(data[offset + 1]) << 8) | (UInt32(data[offset + 2]) << 16) | (UInt32(data[offset + 3]) << 24)
  }
  private static func hex(_ status: IOReturn) -> String {
    String(format: "0x%08X", UInt32(bitPattern: status))
  }
}
