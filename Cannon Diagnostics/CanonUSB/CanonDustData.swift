import Foundation

enum CanonDustData {
  struct Report {
    let count: Int
    let large: Int
    let medium: Int
    let small: Int
    let rawBytes: Int
  }
  enum ParseError: LocalizedError {
    case invalidJPEG, missingEXIF, missingMakerNote, missingDustData, invalidDustData
    var errorDescription: String? {
      switch self {
      case .invalidJPEG: return "This is not a valid JPEG file."
      case .missingEXIF: return "No EXIF metadata was found."
      case .missingMakerNote: return "No Canon MakerNote was found."
      case .missingDustData: return "No Canon Dust Delete Data record was found."
      case .invalidDustData: return "The Canon Dust Delete Data record could not be interpreted."
      }
    }
  }
  static func read(_ url: URL) throws -> Report {
    let data = try Data(contentsOf: url)
    let bytes = [UInt8](data)
    func u16(_ p: Int, _ little: Bool) -> Int? {
      guard p >= 0, p + 2 <= bytes.count else { return nil }
      return little ? Int(bytes[p]) | (Int(bytes[p + 1]) << 8) : (Int(bytes[p]) << 8) | Int(bytes[p + 1])
    }
    func u32(_ p: Int, _ little: Bool) -> Int? {
      guard p >= 0, p + 4 <= bytes.count else { return nil }
      if little { return Int(bytes[p]) | (Int(bytes[p + 1]) << 8) | (Int(bytes[p + 2]) << 16) | (Int(bytes[p + 3]) << 24) }
      return (Int(bytes[p]) << 24) | (Int(bytes[p + 1]) << 16) | (Int(bytes[p + 2]) << 8) | Int(bytes[p + 3])
    }
    guard bytes.count > 4, bytes[0] == 0xFF, bytes[1] == 0xD8 else { throw ParseError.invalidJPEG }
    var tiff: Int? = nil
    var p = 2
    while p + 4 <= bytes.count {
      guard bytes[p] == 0xFF else { break }
      let marker = bytes[p + 1]
      if marker == 0xDA || marker == 0xD9 { break }
      guard let segmentLength = u16(p + 2, false), segmentLength >= 2,
            p + 2 + segmentLength <= bytes.count else { break }
      if marker == 0xE1, segmentLength >= 8,
         Array(bytes[(p + 4)..<(p + 10)]) == [69, 120, 105, 102, 0, 0] {
        tiff = p + 10
        break
      }
      p += 2 + segmentLength
    }
    guard let base = tiff else { throw ParseError.missingEXIF }
    let little = bytes[base] == 0x49 && bytes[base + 1] == 0x49
    guard little || (bytes[base] == 0x4D && bytes[base + 1] == 0x4D),
          u16(base + 2, little) == 42 else { throw ParseError.missingEXIF }
    func entry(_ offset: Int, _ tag: Int) -> (type: Int, count: Int, value: Int)? {
      guard let n = u16(offset, little), n < 500,
            offset + 2 + n * 12 <= bytes.count else { return nil }
      for i in 0..<n {
        let at = offset + 2 + i * 12
        if u16(at, little) == tag,
           let type = u16(at + 2, little), let count = u32(at + 4, little),
           let value = u32(at + 8, little) { return (type, count, value) }
      }
      return nil
    }
    guard let root = u32(base + 4, little),
          let exif = entry(base + root, 0x8769),
          let maker = entry(base + exif.value, 0x927C),
          maker.type == 7, maker.count >= 2,
          base + maker.value + maker.count <= bytes.count else { throw ParseError.missingMakerNote }
    let makerStart = base + maker.value
    guard let dust = entry(makerStart, 0x0097), dust.type == 7, dust.count >= 38,
          base + dust.value + dust.count <= bytes.count else { throw ParseError.missingDustData }
    let start = base + dust.value
    guard let count = u16(start + 4, little), count <= 100,
          34 + count * 6 <= dust.count else { throw ParseError.invalidDustData }
    var large = 0, medium = 0, small = 0
    for i in 0..<count {
      guard let size = u16(start + 34 + i * 6 + 4, little) else { throw ParseError.invalidDustData }
      if size >= 20 { large += 1 }
      else if size >= 10 { medium += 1 }
      else { small += 1 }
    }
    return Report(count: count, large: large, medium: medium, small: small, rawBytes: dust.count)
  }
}
