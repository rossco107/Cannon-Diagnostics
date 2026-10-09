//
//  Canon Diagnostics
//
//  Copyright © 2026 Ross Carter. All rights reserved.
//
//  Native macOS application for reading Canon EOS camera
//  information using USB/PTP without external dependencies.
//



import Foundation
import IOKit
import IOUSBHost

enum CanonPTPEOSEvents {
  static func read(registryID: UInt64) async -> String {
    var log = ["EOS shutter count — Canon event/property diagnostics"]
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
          let buffer = NSMutableData(length: 65536)!
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
      // Canon EOS property values are delivered through vendor event blocks.
      // Remote/event modes alter the connection state temporarily, not exposure settings.
      var remoteEnabled = false
      var eventEnabled = false
      do {
        let remote = try await execute(0x9114, [1])
        log.append("SetRemoteMode(1): \(code(remote.0))")
        remoteEnabled = remote.0 == 0x2001
        if remoteEnabled {
          let event = try await execute(0x9115, [1])
          log.append("SetEventMode(1): \(code(event.0))")
          eventEnabled = event.0 == 0x2001
        }
        if eventEnabled {
          var found = false
          var owner: String?
          var nickname: String?
          var shots: UInt32?
          var serial: UInt32?
          var battery: UInt32?
          for attempt in 1...4 {
            let result = try await execute(0x9116)
            log.append("GetEvent #\(attempt): \(code(result.0)); data \(result.1?.count ?? 0) bytes")
            guard result.0 == 0x2001 else { break }
            guard let payload = result.1 else { break }
            let parsed = parseEvents(payload)
            log.append(contentsOf: parsed.lines)
            if let name = parsed.owner { owner = name }
            if let name = parsed.nickname { nickname = name }
            if let value = parsed.availableShots { shots = value }
            if let value = parsed.eosSerial { serial = value }
            if let value = parsed.batteryPower { battery = value }
            if let count = parsed.shutterCount {
              log.append("SHUTTER COUNT CANDIDATE: \(count) (previous gPhoto2 reading: 3559)")
              found = true
            }
            if parsed.eventCount == 0 { break }
          }
          if !found { log.append("No 0xD1AC shutter-counter event found in this poll.") }
          log.append("OWNER NAME: " + (owner ?? "Not available"))
          log.append("CAMERA NICKNAME: " + (nickname ?? "Not available"))
          log.append("AVAILABLE SHOTS: " + (shots.map(String.init) ?? "Not available"))
          log.append("EOS SERIAL RAW: " + (serial.map { String(format: "0x%08X", $0) } ?? "Not available"))
          log.append("EOS BATTERY RAW: " + (battery.map(String.init) ?? "Not available"))
        }
      } catch {
        log.append("EOS diagnostic failed: \(error)")
      }
      // Best-effort return to normal USB mode, even after an EOS error.
      if eventEnabled {
        do { let result = try await execute(0x9115, [0]); log.append("SetEventMode(0): \(code(result.0))") }
        catch { log.append("Event-mode reset failed: \(error)") }
      }
      if remoteEnabled {
        do { let result = try await execute(0x9114, [0]); log.append("SetRemoteMode(0): \(code(result.0))") }
        catch { log.append("Remote-mode reset failed: \(error)") }
      }
      let closed = try await execute(0x1003)
      log.append("CloseSession: \(code(closed.0))")
    } catch {
      log.append("ERROR: \(error)")
    }
    return log.joined(separator: "\n")
  }

  // Writes the EOS owner string, then requests a fresh property event to verify it.
  static func writeOwner(registryID: UInt64, name: String) async -> (success: Bool, message: String) {
    let bytes = Array(name.utf8)
    guard !bytes.isEmpty, bytes.count <= 255,
          bytes.allSatisfy({ $0 >= 0x20 && $0 <= 0x7E }) else {
      return (false, "Use 1–255 printable ASCII characters for the owner name.")
    }
    guard let matching = IORegistryEntryIDMatching(registryID) else { return (false, "Registry match failed.") }
    let service = IOServiceGetMatchingService(kIOMainPortDefault, matching)
    guard service != 0 else { return (false, "Camera unavailable.") }
    defer { IOObjectRelease(service) }
    do {
      let usb = try IOUSBHostInterface(__ioService: service, options: [], queue: nil)
      let addresses = endpoints(usb)
      guard let outAddress = addresses.out, let inAddress = addresses.input else {
        return (false, "Bulk endpoints unavailable.")
      }
      let outPipe = try usb.copyPipe(withAddress: Int(outAddress))
      let inPipe = try usb.copyPipe(withAddress: Int(inAddress))
      var transaction: UInt32 = 0
      func execute(_ operation: UInt16, params: [UInt32] = [], send: Data? = nil) async throws -> (UInt16, Data?) {
        let id = transaction
        transaction += 1
        var command = Data()
        put32(&command, UInt32(12 + params.count * 4))
        put16(&command, 1)
        put16(&command, operation)
        put32(&command, id)
        for param in params { put32(&command, param) }
        let commandBuffer = NSMutableData(data: command)
        let (outStatus, outCount) = try await outPipe.enqueueIORequest(with: commandBuffer, completionTimeout: 5)
        guard outStatus == kIOReturnSuccess && outCount == command.count else {
          throw Failure.message("Command USB OUT failed")
        }
        if let send {
          var container = Data()
          put32(&container, UInt32(send.count + 12))
          put16(&container, 2)
          put16(&container, operation)
          put32(&container, id)
          container.append(send)
          let buffer = NSMutableData(data: container)
          let (status, count) = try await outPipe.enqueueIORequest(with: buffer, completionTimeout: 5)
          guard status == kIOReturnSuccess && count == container.count else {
            throw Failure.message("Property data USB OUT failed")
          }
        }
        var payload: Data?
        for _ in 0..<2 {
          let buffer = NSMutableData(length: 65536)!
          let (status, count) = try await inPipe.enqueueIORequest(with: buffer, completionTimeout: 5)
          guard status == kIOReturnSuccess else { throw Failure.message("USB IN failed: \(hex(status))") }
          let received = Data(bytes: buffer.bytes, count: min(count, buffer.length))
          guard received.count >= 12 else { throw Failure.message("Short PTP response") }
          let length = Int(u32(received, 0))
          guard length >= 12 && length <= received.count && u32(received, 8) == id else {
            throw Failure.message("Invalid PTP response container")
          }
          let type = u16(received, 4)
          if type == 2 {
            payload = received.subdata(in: 12..<length)
          } else if type == 3 {
            return (u16(received, 6), payload)
          } else {
            throw Failure.message("Unexpected PTP container type")
          }
        }
        throw Failure.message("Missing PTP response")
      }
      let opened = try await execute(0x1002, params: [1])
      guard opened.0 == 0x2001 else { return (false, "OpenSession rejected: \(code(opened.0))") }
      var remote = false
      var events = false
      var result = (success: false, message: "Owner write did not complete.")
      do {
        let r = try await execute(0x9114, params: [1])
        remote = r.0 == 0x2001
        guard remote else { throw Failure.message("Remote mode rejected: \(code(r.0))") }
        let e = try await execute(0x9115, params: [1])
        events = e.0 == 0x2001
        guard events else { throw Failure.message("Event mode rejected: \(code(e.0))") }
        // Discard initial state events before the write so verification cannot use stale data.
        for _ in 0..<3 {
          let poll = try await execute(0x9116)
          guard poll.0 == 0x2001 else { break }
          if (poll.1?.count ?? 0) <= 8 { break }
        }
        var property = Data()
        put32(&property, UInt32(8 + bytes.count + 1))
        put32(&property, 0xD115)
        property.append(contentsOf: bytes)
        property.append(0)
        let written = try await execute(0x9110, send: property)
        guard written.0 == 0x2001 else {
          throw Failure.message("Camera rejected owner change: \(code(written.0))")
        }
        // The 40D has returned 0x2002 to the immediate readback request even
        // after successfully saving. Treat that as unverified, not a failed write.
        result = (true, "Camera accepted owner name. Read Camera to verify it.")
        do {
          let requested = try await execute(0x9127, params: [0xD115])
          if requested.0 == 0x2001 {
            for _ in 0..<4 {
              let poll = try await execute(0x9116)
              guard poll.0 == 0x2001 else { break }
              if let data = poll.1, let confirmed = parseEvents(data).owner {
                if confirmed == name {
                  result = (true, "Owner name saved and verified on the camera.")
                } else {
                  result = (true, "Write accepted; readback returned a different name: \(confirmed). Refresh to check.")
                }
                break
              }
            }
          } else {
            result = (true, "Camera accepted owner name; immediate verification unavailable (\(code(requested.0))). Read Camera to confirm.")
          }
        } catch {
          result = (true, "Camera accepted owner name; verification unavailable: \(error). Read Camera to confirm.")
        }
      } catch {
        result = (false, "Owner update failed: \(error)")
      }
      if events { _ = try? await execute(0x9115, params: [0]) }
      if remote { _ = try? await execute(0x9114, params: [0]) }
      _ = try? await execute(0x1003)
      return result
    } catch {
      return (false, "USB error: \(error)")
    }
  }

  private static func parseEvents(_ data: Data) -> (lines: [String], shutterCount: UInt32?, owner: String?, nickname: String?, eventCount: Int, availableShots: UInt32?, eosSerial: UInt32?, batteryPower: UInt32?) {
    var lines: [String] = []
    var offset = 0
    var count = 0
    var shutter: UInt32?
    var owner: String?
    var nickname: String?
    var shots: UInt32?
    var serial: UInt32?
    var battery: UInt32?
    var otherEvents = 0
    while offset + 8 <= data.count && count < 512 {
      let size = Int(u32(data, offset))
      let kind = u32(data, offset + 4)
      if size == 0 { break }
      guard size >= 8, offset + size <= data.count else {
        lines.append("Malformed EOS event at byte \(offset): size \(size)")
        break
      }
      count += 1
      if kind == 0xC189 && size >= 12 {
        let property = u32(data, offset + 8)
        if property == 0xD1AC && size >= 16 {
          shutter = u32(data, offset + 12)
          lines.append("EOS shutter-counter property 0xD1AC: \(shutter!)")
        } else if (property == 0xD11B || property == 0xD1AF || property == 0xD111) && size >= 16 {
          let value = u32(data, offset + 12)
          switch property {
          case 0xD11B: shots = value; lines.append("EOS available shots 0xD11B: \(value)")
          case 0xD1AF: serial = value; lines.append(String(format: "EOS serial 0xD1AF raw: 0x%08X", value))
          default: battery = value; lines.append("EOS battery power 0xD111 raw: \(value)")
          }
        } else if property == 0xD115 || property == 0xD125 {
          let raw = data.subdata(in: (offset + 12)..<(offset + size))
          if let name = decodeEOSString(raw) {
            if property == 0xD115 {
              owner = name
              lines.append("EOS owner property 0xD115: \(name)")
            } else {
              nickname = name
              lines.append("EOS nickname property 0xD125: \(name)")
            }
          } else {
            lines.append(String(format: "EOS string property 0x%04X: empty or undecodable (%d bytes)", property, raw.count))
          }
        } else {
          otherEvents += 1
        }
      } else {
        otherEvents += 1
      }
      offset += size
    }
    if otherEvents > 0 { lines.append("Other EOS event records: \(otherEvents)") }
    if count == 0 { lines.append("No EOS event records returned.") }
    return (lines, shutter, owner, nickname, count, shots, serial, battery)
  }

  private static func decodeEOSString(_ raw: Data) -> String? {
    // Canon EOS event strings are generally NUL-terminated UTF-8/ASCII;
    // some bodies use UTF-16LE. Do not turn arbitrary binary into an owner name.
    guard !raw.isEmpty else { return nil }
    let bytes = [UInt8](raw)
    if bytes.count >= 4 && bytes[1] == 0 && bytes[3] == 0 {
      var end = 0
      while end + 1 < bytes.count {
        if bytes[end] == 0 && bytes[end + 1] == 0 { break }
        end += 2
      }
      if end > 0, let name = String(data: Data(bytes.prefix(end)), encoding: .utf16LittleEndian) {
        return validName(name)
      }
    }
    let terminated = Data(bytes.prefix(while: { $0 != 0 }))
    guard let name = String(data: terminated, encoding: .utf8) else { return nil }
    return validName(name)
  }

  private static func validName(_ value: String) -> String? {
    let name = value.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !name.isEmpty, name.count <= 128,
          !name.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else { return nil }
    return name
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
