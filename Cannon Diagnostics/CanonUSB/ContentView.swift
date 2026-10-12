//
//  Canon Diagnostics
//
//  Copyright © 2026 Ross Carter. All rights reserved.
//
//  Native macOS application for reading Canon EOS camera
//  information using USB/PTP without external dependencies.
//




import SwiftUI
import ImageCaptureCore
import UniformTypeIdentifiers
import ImageIO
import AppKit

struct ContentView: View {
  @StateObject private var shared = CanonSharedPTP()
  @State private var selectedJPEG = ""
  @State private var jpegStatus = "No JPEG selected."
  @State private var dustReport: CanonDustData.Report?
  @State private var editingOwner = false
  @State private var ownerDraft = ""

  private var camera: ICCameraDevice? { shared.camera }
  private var deviceInfo: String { shared.deviceInfo }
  private var properties: String { shared.properties }
  private var eosEvents: String { shared.eosEvents }
  private var isReading: Bool { shared.busy }
  private var ownerStatus: String? { shared.ownerStatus.isEmpty ? nil : shared.ownerStatus }
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
          Text("Canon EOS diagnostics via macOS ImageCaptureCore").foregroundStyle(.secondary)
        }
        Spacer()
        if isReading { ProgressView().controlSize(.small) }
        Button("Read Camera") { readCamera() }.disabled(isReading || camera == nil)
          .buttonStyle(.borderedProminent)
      }
      Divider()
      if camera == nil {
        ContentUnavailableView("No Canon camera detected", systemImage: "camera", description: Text("Connect and switch on a Canon camera. It will be detected automatically."))
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
            HStack(spacing: 6) {
              Image(systemName: "cable.connector")
              Text("Connected via ImageCaptureCore")
              Spacer()
              Text(shared.status).lineLimit(1)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            GroupBox("Sensor Dust Test") {
              VStack(alignment: .leading, spacing: 10) {
                Text("Run Dust Delete Data on the camera, then take a new JPEG photograph. Select that JPEG to examine its metadata.")
                  .font(.callout)
                HStack {
                  Button("Choose JPEG…") { chooseJPEG() }
                  if !selectedJPEG.isEmpty {
                    Text(selectedJPEG).lineLimit(1).truncationMode(.middle)
                      .foregroundStyle(.secondary)
                  }
                  Spacer()
                }
                Text(jpegStatus).font(.caption).foregroundStyle(.secondary)
                  .textSelection(.enabled)
                if let report = dustReport {
                  HStack(spacing: 20) {
                    Text("Total: \(report.count)").bold()
                    Text("Large: \(report.large)")
                    Text("Medium: \(report.medium)")
                    Text("Small: \(report.small)")
                  }
                  .font(.callout)
                  Text("Size groups are provisional, based on Canon's recorded spot-size values. Compare new results after repeating Dust Delete Data on the camera.")
                    .font(.caption).foregroundStyle(.secondary)
                }
              }
              .padding(8)
              .frame(maxWidth: .infinity, alignment: .leading)
            }
          }
          .padding(.vertical, 4)
        }
      }
    }
    .padding(20)
    .frame(minWidth: 720, minHeight: 540)
    .onAppear { shared.start() }
    .onDisappear { shared.stop() }
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
        Button("Cancel") { editingOwner = false; shared.ownerStatus = "" }
          .disabled(isReading)
      } else {
        Text(value(after: "OWNER NAME:", in: eosEvents) ?? "Not yet read")
          .textSelection(.enabled)
        Button("Edit") {
          ownerDraft = value(after: "OWNER NAME:", in: eosEvents) ?? ""
          if ownerDraft == "Not available" { ownerDraft = "" }
          shared.ownerStatus = ""
          editingOwner = true
        }
        .disabled(isReading || camera == nil || eosEvents.isEmpty)
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
  private func value(after prefix: String, in text: String) -> String? {
    text.split(separator: "\n").first(where: { $0.hasPrefix(prefix) })
      .map { String($0.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces) }
  }
  private func chooseJPEG() {
    let panel = NSOpenPanel()
    panel.allowedContentTypes = [.jpeg]
    panel.allowsMultipleSelection = false
    panel.canChooseDirectories = false
    guard panel.runModal() == .OK, let url = panel.url else { return }
    selectedJPEG = url.lastPathComponent
    dustReport = nil
    do {
      let report = try CanonDustData.read(url)
      dustReport = report
      jpegStatus = "Canon Dust Delete Data found (\(report.rawBytes) bytes)."
    } catch {
      jpegStatus = error.localizedDescription
    }
  }
  private func readCamera() {
    editingOwner = false
    shared.readCamera()
  }
  private func saveOwner() {
    shared.saveOwner(ownerDraft)
    editingOwner = false
  }
  private func hex(_ value: Int, digits: Int = 4) -> String {
    String(format: "0x%0*X", digits, value)
  }
}
