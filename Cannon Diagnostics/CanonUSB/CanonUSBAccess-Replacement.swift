import Foundation
import IOKit
import IOUSBHost

enum CanonUSBAccess {
  static func test(registryID: UInt64) -> String {
    guard let matching = IORegistryEntryIDMatching(registryID) else {
      return "Unable to create an IOKit registry match."
    }
    let service = IOServiceGetMatchingService(kIOMainPortDefault, matching)
    guard service != 0 else {
      return "Interface no longer exists. Wake the camera and refresh."
    }
    defer { IOObjectRelease(service) }
    guard IOObjectConformsTo(service, "IOUSBHostInterface") != 0 else {
      return "The selected registry entry is not a USB host interface."
    }
    let ownerBefore = stringProperty(service, "UsbExclusiveOwner") ?? "None reported"
    let product = stringProperty(service, "USB Product Name") ?? "Unknown"
    let number = numberProperty(service, "bInterfaceNumber") ?? -1
    let interfaceClass = numberProperty(service, "bInterfaceClass") ?? -1
    var details = [
      "Device: \(product)",
      "Interface: \(number) (class \(interfaceClass))",
      "Registry ID: 0x\(String(registryID, radix: 16))",
      "Owner before attempt: \(ownerBefore)"
    ]
    do {
      // This initialiser attempts to acquire the interface. No PTP traffic is sent.
      let interface = try IOUSBHostInterface(__ioService: service, options: [], queue: nil)
      withExtendedLifetime(interface) {
        details.append("SUCCESS: IOUSBHostInterface initialised.")
        details.append("No PTP commands sent.")
      }
    } catch {
      let nsError = error as NSError
      details.append("FAILED: \(nsError.localizedDescription)")
      details.append("Domain: \(nsError.domain)")
      details.append("Code: \(nsError.code) (0x\(String(UInt32(truncatingIfNeeded: nsError.code), radix: 16)))")
      if UInt32(truncatingIfNeeded: nsError.code) == 0xe00002c9 {
        details.append("IOKit reports exclusive access denied. The owner may not be published in the registry.")
      }
    }
    let ownerAfter = stringProperty(service, "UsbExclusiveOwner") ?? "None reported"
    details.append("Owner after attempt: \(ownerAfter)")
    return details.joined(separator: "\n")
  }

  private static func property(_ service: io_service_t, _ key: String) -> Any? {
    IORegistryEntryCreateCFProperty(service, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
  }

  private static func stringProperty(_ service: io_service_t, _ key: String) -> String? {
    property(service, key) as? String
  }

  private static func numberProperty(_ service: io_service_t, _ key: String) -> Int? {
    (property(service, key) as? NSNumber)?.intValue
  }
}
