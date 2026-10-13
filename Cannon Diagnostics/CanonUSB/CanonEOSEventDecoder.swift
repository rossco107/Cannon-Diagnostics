import Foundation

enum CanonEOSEventDecoder {
  static func parse(_ data: Data) -> (lines: [String], shutterCount: UInt32?, owner: String?, nickname: String?, eventCount: Int, availableShots: UInt32?, eosSerial: String?, batteryPower: UInt32?) {
    var lines: [String] = []
    var offset = 0
    var count = 0
    var shutter: UInt32?
    var owner: String?
    var nickname: String?
    var shots: UInt32?
    var serial: String?
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
        } else if (property == 0xD11B || property == 0xD111) && size >= 16 {
          let value = u32(data, offset + 12)
          switch property {
          case 0xD11B: shots = value; lines.append("EOS available shots 0xD11B: \(value)")
          default: battery = value; lines.append("EOS battery power 0xD111 raw: \(value)")
          }
        } else if property == 0xD115 || property == 0xD125 || property == 0xD1AF {
          let raw = data.subdata(in: (offset + 12)..<(offset + size))
          if let name = decodeEOSString(raw) {
            if property == 0xD115 {
              owner = name
              lines.append("EOS owner property 0xD115: \(name)")
            } else if property == 0xD125 {
              nickname = name
              lines.append("EOS nickname property 0xD125: \(name)")
            } else {
              serial = name
              lines.append("EOS serial property 0xD1AF: \(name)")
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

  private static func u32(_ data: Data, _ offset: Int) -> UInt32 {
    UInt32(data[offset]) | UInt32(data[offset + 1]) << 8 | UInt32(data[offset + 2]) << 16 | UInt32(data[offset + 3]) << 24
  }
}
