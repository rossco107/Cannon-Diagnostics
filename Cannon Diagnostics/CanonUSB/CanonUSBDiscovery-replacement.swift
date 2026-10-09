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
import IOKit.usb

struct CanonUSBDevice: Identifiable {
  let id: UInt64
  let name: String
  let vendorID: Int
  let productID: Int
  let locationID: Int
  let interfaces: [CanonUSBInterface]
}

struct CanonUSBInterface: Identifiable {
  let id: UInt64
  let number: Int
  let interfaceClass: Int
  let subclass: Int
  let protocolCode: Int
  let endpointCount: Int
  let owner: String?
}

enum CanonUSBDiscovery {
  static func scan() -> [CanonUSBDevice] {
    guard let matching = IOServiceMatching("IOUSBHostDevice"),
          let services = iterator(matching) else { return [] }
    defer { IOObjectRelease(services) }
    var devices: [CanonUSBDevice] = []
    while case let service = IOIteratorNext(services), service != 0 {
      defer { IOObjectRelease(service) }
      let vendor = integer(service, "idVendor")
      guard vendor == 0x04A9 else { continue }
      let location = integer(service, "locationID")
      devices.append(CanonUSBDevice(
        id: registryID(service),
        name: string(service, "USB Product Name") ?? "Canon USB Device",
        vendorID: vendor,
        productID: integer(service, "idProduct"),
        locationID: location,
        interfaces: interfaces(for: service)
      ))
    }
    return devices
  }

  private static func iterator(_ matching: CFMutableDictionary) -> io_iterator_t? {
    var result: io_iterator_t = 0
    return IOServiceGetMatchingServices(kIOMainPortDefault, matching, &result) == KERN_SUCCESS ? result : nil
  }

  private static func interfaces(for device: io_service_t) -> [CanonUSBInterface] {
    var iterator: io_iterator_t = 0
    guard IORegistryEntryGetChildIterator(device, kIOServicePlane, &iterator) == KERN_SUCCESS else { return [] }
    defer { IOObjectRelease(iterator) }
    var result: [CanonUSBInterface] = []
    while case let child = IOIteratorNext(iterator), child != 0 {
      defer { IOObjectRelease(child) }
      if conforms(child, to: "IOUSBHostInterface") {
        result.append(describe(child))
      } else {
        result.append(contentsOf: interfaces(for: child))
      }
    }
    return result
  }

  private static func conforms(_ service: io_service_t, to className: String) -> Bool {
    let result: Bool = className.withCString { pointer in
      IOObjectConformsTo(service, pointer) != 0
    }
    return result
  }
  private static func describe(_ service: io_service_t) -> CanonUSBInterface {
    CanonUSBInterface(
      id: registryID(service),
      number: integer(service, "bInterfaceNumber"),
      interfaceClass: integer(service, "bInterfaceClass"),
      subclass: integer(service, "bInterfaceSubClass"),
      protocolCode: integer(service, "bInterfaceProtocol"),
      endpointCount: integer(service, "bNumEndpoints"),
      owner: string(service, "UsbExclusiveOwner")
    )
  }

  private static func registryID(_ service: io_service_t) -> UInt64 {
    var id: UInt64 = 0
    IORegistryEntryGetRegistryEntryID(service, &id)
    return id
  }

  private static func property(_ service: io_service_t, _ key: String) -> Any? {
    IORegistryEntryCreateCFProperty(service, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
  }

  private static func integer(_ service: io_service_t, _ key: String) -> Int {
    (property(service, key) as? NSNumber)?.intValue ?? 0
  }

  private static func string(_ service: io_service_t, _ key: String) -> String? {
    property(service, key) as? String
  }
}
