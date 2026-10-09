//
//  Canon Diagnostics
//
//  Copyright © 2026 Ross Carter. All rights reserved.
//
//  Native macOS application for reading Canon EOS camera
//  information using USB/PTP without external dependencies.
//




import SwiftUI

struct ContentView: View {
  @State private var devices: [CanonUSBDevice] = []
  @State private var lastScan = Date()
  @State private var deviceInfo = ""
  @State private var properties = ""
  @State private var eosEvents = ""
  @State private var usbTest = ""
  @State private var isReading = false
  @State private var showDiagnostics = false
  @State private var editingOwner = false
  @State private var ownerDraft = ""
  @State private var ownerStatus: String? = nil

  private var camera: CanonUSBDevice? { devices.first }
  private var ptpInterface: CanonUSBInterface? {
    camera?.interfaces.first(where: { $0.interfaceClass == 6 })
  }
  private var shutterCount: String {
    if let match = eosEvents.range(of: #"SHUTTER COUNT CANDIDATE:\s*\d+"#, options: .regularExpression) {
      return String(eosEvents[match]).components(separatedBy: ":").last?.trimmingCharacters(in: .whitespaces) ?? "—"
    }
    return "—"
  }
  private var cameraModel: String { value(after: "Model:", in: deviceInfo) ?? camera?.name ?? "—" }
  private var manufacturer: String { value(after: "Manufacturer:", in: deviceInfo) ?? "—" }
  private var serialNumber: String { value(after: "Serial:", in: deviceInfo) ?? "—" }
  private var firmware: String { value(after: "Device version:", in: deviceInfo) ?? "—" }
  private var availableShots: String { value(after: "AVAILABLE SHOTS:", in: eosEvents) ?? "—" }
  private var eosSerial: String { value(after: "EOS SERIAL RAW:", in: eosEvents) ?? "—" }
  private var eosBattery: String {
    guard let raw = value(after: "EOS BATTERY RAW:", in: eosEvents), raw != "Not available" else { return battery }
    return "\(raw) (Canon EOS raw value)"
  }
  private var battery: String {
    guard let line = properties.split(separator: "\n").first(where: { $0.contains("GetDevicePropValue 0xD407: 0x2001") }),
          let bytes = line.components(separatedBy: "data bytes:").last,
          let first = bytes.trimmingCharacters(in: .whitespaces).split(separator: " ").first,
          let raw = UInt32(first, radix: 16) else { return "—" }
    return "\(raw) (raw camera value)"
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      HStack {
        VStack(alignment: .leading, spacing: 3) {
          Text(cameraModel == "—" ? "Canon Camera Information" : cameraModel).font(.title2.bold())
          Text("Native USB and Canon EOS diagnostics").foregroundStyle(.secondary)
        }
        Spacer()
        if isReading { ProgressView().controlSize(.small) }
        Button("Refresh") { refresh() }.disabled(isReading)
        Button("Read Camera") { readCamera() }.disabled(isReading || ptpInterface == nil)
          .buttonStyle(.borderedProminent)
      }
      Divider()
      if camera == nil {
        ContentUnavailableView("No Canon camera detected", systemImage: "camera", description: Text("Connect and wake the camera, then select Refresh."))
      } else {
        ScrollView {
          VStack(alignment: .leading, spacing: 18) {
            GroupBox("Camera Information") {
              VStack(alignment: .leading, spacing: 11) {
                field("Shutter count", shutterCount == "—" ? "Not yet read" : "\(shutterCount) actuations")
                field("Manufacturer", manufacturer)
                field("Canon serial (raw)", eosSerial)
                field("PTP serial number", serialNumber)
                field("Shots remaining", availableShots)
                field("Firmware", firmware.replacingOccurrences(of: "3-", with: ""))
                field("Battery", eosBattery)
                ownerEditor
                if let ownerStatus {
                  Text(ownerStatus).font(.caption).foregroundStyle(.secondary)
                }
                field("Camera nickname", value(after: "CAMERA NICKNAME:", in: eosEvents) ?? "Not yet read")
              }
              .padding(8)
              .frame(maxWidth: .infinity, alignment: .leading)
            }
            GroupBox("Connection") {
              VStack(alignment: .leading, spacing: 9) {
                field("Status", ptpInterface == nil ? "Camera detected; PTP unavailable" : "Connected via USB")
                if let camera {
                  field("Vendor / product ID", "\(hex(camera.vendorID)) / \(hex(camera.productID))")
                  field("USB location", hex(camera.locationID, digits: 8))
                }
                if let ptpInterface {
                  field("Interface", "\(ptpInterface.number) · \(ptpInterface.endpointCount) endpoints")
                  field("Exclusive USB owner", ptpInterface.owner ?? "None reported")
                }
              }
              .padding(8)
              .frame(maxWidth: .infinity, alignment: .leading)
            }
            DisclosureGroup("Diagnostics", isExpanded: $showDiagnostics) {
              VStack(alignment: .leading, spacing: 12) {
                if let ptpInterface {
                  Button("Test USB Access") { testUSB(ptpInterface.id) }.disabled(isReading)
                }
                diagnostic("USB access", usbTest)
                diagnostic("PTP DeviceInfo", deviceInfo)
                diagnostic("PTP properties", properties)
                diagnostic("Canon EOS events", eosEvents)
              }
              .padding(.top, 8)
            }
            .padding(10)
          }
          .padding(.vertical, 4)
        }
      }
      Text("Last scan: \(lastScan.formatted(date: .omitted, time: .standard)) · Reading EOS events temporarily enables remote/event mode.")
        .font(.caption).foregroundStyle(.secondary)
    }
    .padding(20)
    .frame(minWidth: 720, minHeight: 540)
    .onAppear(perform: refresh)
  }

  private var ownerEditor: some View {
    HStack(alignment: .firstTextBaseline, spacing: 12) {
      Text("Owner name")
      if editingOwner {
        TextField("Owner name", text: $ownerDraft)
          .textFieldStyle(.roundedBorder)
          .frame(maxWidth: 280)
          .disabled(isReading)
          .onSubmit { if canSaveOwner { saveOwner() } }
        Button("Save") { saveOwner() }
          .buttonStyle(.borderedProminent)
          .disabled(!canSaveOwner || isReading)
        Button("Cancel") { editingOwner = false; ownerStatus = nil }
          .disabled(isReading)
      } else {
        Text(value(after: "OWNER NAME:", in: eosEvents) ?? "Not yet read")
          .textSelection(.enabled)
        Button("Edit") {
          ownerDraft = value(after: "OWNER NAME:", in: eosEvents) ?? ""
          if ownerDraft == "Not available" { ownerDraft = "" }
          ownerStatus = nil
          editingOwner = true
        }
        .disabled(isReading || ptpInterface == nil || eosEvents.isEmpty)
      }
      Spacer(minLength: 0)
    }
  }
  private var canSaveOwner: Bool {
    let name = ownerDraft.trimmingCharacters(in: .whitespacesAndNewlines)
    return !name.isEmpty && name != value(after: "OWNER NAME:", in: eosEvents)
      && name.utf8.count <= 255 && name.utf8.allSatisfy { $0 >= 32 && $0 <= 126 }
  }

  private func field(_ name: String, _ value: String) -> some View {
    LabeledContent(name, value: value)
      .textSelection(.enabled)
  }
  @ViewBuilder private func diagnostic(_ name: String, _ output: String) -> some View {
    if !output.isEmpty {
      VStack(alignment: .leading, spacing: 4) {
        Text(name).font(.headline)
        Text(output).font(.system(.caption, design: .monospaced))
          .textSelection(.enabled)
          .frame(maxWidth: .infinity, alignment: .leading)
      }
    }
  }
  private func value(after prefix: String, in text: String) -> String? {
    text.split(separator: "\n").first(where: { $0.hasPrefix(prefix) })
      .map { String($0.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces) }
  }
  private func refresh() {
    devices = CanonUSBDiscovery.scan()
    lastScan = Date()
    deviceInfo = ""
    properties = ""
    eosEvents = ""
    usbTest = ""
    editingOwner = false
    ownerStatus = nil
  }
  private func readCamera() {
    guard let id = ptpInterface?.id else { return }
    isReading = true
    editingOwner = false
    ownerStatus = nil
    Task {
      // Separate sessions: the proven readers each open and close their own interface.
      deviceInfo = await CanonPTP.getDeviceInfo(registryID: id)
      properties = await CanonPTPSession.inspect(registryID: id)
      eosEvents = await CanonPTPEOSEvents.read(registryID: id)
      isReading = false
    }
  }
  private func saveOwner() {
    guard let id = ptpInterface?.id else { return }
    let newName = ownerDraft
    isReading = true
    ownerStatus = "Saving and verifying on camera…"
    Task {
      let result = await CanonPTPEOSEvents.writeOwner(registryID: id, name: newName)
      ownerStatus = result.message
      if result.success {
        editingOwner = false
        let refreshed = await CanonPTPEOSEvents.read(registryID: id)
        if value(after: "OWNER NAME:", in: refreshed) == newName {
          ownerStatus = "Owner name saved and verified on the camera."
        } else {
          ownerStatus = result.message
        }
        eosEvents = refreshed
      }
      isReading = false
    }
  }

  private func testUSB(_ id: UInt64) {
    isReading = true
    Task {
      usbTest = CanonUSBAccess.test(registryID: id)
      isReading = false
    }
  }
  
  private func hex(_ value: Int, digits: Int = 4) -> String {
    String(format: "0x%0*X", digits, value)
  }
}
