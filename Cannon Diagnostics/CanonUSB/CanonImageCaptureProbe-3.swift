import Foundation
import SwiftUI
import Combine
import ImageCaptureCore

@MainActor
final class CanonImageCaptureProbe: NSObject, ObservableObject, ICDeviceBrowserDelegate {
  @Published var cameras: [ICCameraDevice] = []
  @Published var selectedID: String = ""
  @Published var report = "Waiting for cameras…"
  @Published var working = false
  private let browser = ICDeviceBrowser()

  override init() {
    super.init()
    browser.delegate = self
    browser.browsedDeviceTypeMask = .camera
  }

  func start() {
    if !browser.isBrowsing { browser.start() }
  }

  func stop() {
    if browser.isBrowsing { browser.stop() }
  }

  func deviceBrowser(_ browser: ICDeviceBrowser, didAdd device: ICDevice, moreComing: Bool) {
    guard let camera = device as? ICCameraDevice else { return }
    if !cameras.contains(where: { $0 === camera }) { cameras.append(camera) }
    if selectedID.isEmpty { selectedID = camera.uuidString ?? "" }
    report = "Camera discovered: \(camera.name ?? "Unnamed")\nUSB: \(String(format: "%04X:%04X", camera.usbVendorID, camera.usbProductID))"
  }

  func deviceBrowser(_ browser: ICDeviceBrowser, didRemove device: ICDevice, moreGoing: Bool) {
    cameras.removeAll { $0 === device }
    if !cameras.contains(where: { $0.uuidString == selectedID }) {
      selectedID = cameras.first?.uuidString ?? ""
    }
    report = cameras.isEmpty ? "Camera disconnected." : "Camera list updated."
  }

  func readDeviceInfo() { read(operation: 0x1001, title: "PTP GetDeviceInfo") }
  func readCanonDeviceInfo() { read(operation: 0x9108, title: "Canon EOS GetDeviceInfoEx") }

  private func read(operation: UInt16, title: String) {
    guard !working, let camera = cameras.first(where: { $0.uuidString == selectedID }) else {
      report = "Select a camera first."
      return
    }
    working = true
    report = "Opening ImageCaptureCore session with \(camera.name ?? "camera")…"
    Task {
      let wasOpen = camera.hasOpenSession
      do {
        if !wasOpen { try await camera.requestOpenSession(options: nil) }
        report = String(format: "Session opened. Sending %@ (0x%04X)…", title, operation)
        // PTP command container: length (4), type=1 (2), operation (2), transaction ID (4).
        // Both commands are read-only. Canon 0x9108 is EOS_GetDeviceInfoEx.
        let command = Data([
          12, 0, 0, 0, 1, 0,
          UInt8(operation & 0xFF), UInt8((operation >> 8) & 0xFF),
          1, 0, 0, 0
        ])
        let (data, response) = try await camera.requestSendPTPCommand(command, outData: nil)
        var lines = [
          "Camera: \(camera.name ?? "Unknown")",
          String(format: "%@ (0x%04X)", title, operation),
          "Data (\(data.count) bytes): \(hex(data.prefix(128)))",
          "Response (\(response.count) bytes): \(hex(response.prefix(64)))"
        ]
        if response.count >= 12 {
          let code = word(response, 6)
          let meaning: String
          switch code {
          case 0x2001: meaning = "OK"
          case 0x2005: meaning = "Operation not supported"
          case 0x2002: meaning = "General error"
          case 0x2019: meaning = "Device busy"
          default: meaning = "See PTP/Canon error codes"
          }
          lines.append(String(format: "PTP response: 0x%04X (%@)", code, meaning))
          lines.append(String(format: "Response container type: %u", word(response, 4)))
        } else {
          lines.append("No complete PTP response container returned.")
        }
        if operation == 0x9108 && response.count >= 12 && word(response, 6) == 0x2001 {
          lines.append("Canon proprietary command succeeded through ImageCaptureCore.")
        }
        report = lines.joined(separator: "\n")
      } catch {
        report = "ImageCaptureCore error: \(error.localizedDescription)\n\(error)"
      }
      if !wasOpen && camera.hasOpenSession {
        try? await camera.requestCloseSession(options: nil)
      }
      working = false
    }
  }

  private func hex<S: Sequence>(_ bytes: S) -> String where S.Element == UInt8 {
    bytes.map { String(format: "%02X", $0) }.joined(separator: " ")
  }
  private func word(_ bytes: Data, _ offset: Int) -> UInt16 {
    guard offset + 1 < bytes.count else { return 0 }
    return UInt16(bytes[offset]) | UInt16(bytes[offset + 1]) << 8
  }
  private func dword(_ bytes: Data, _ offset: Int) -> UInt32 {
    guard offset + 3 < bytes.count else { return 0 }
    return UInt32(bytes[offset]) | UInt32(bytes[offset + 1]) << 8 |
      UInt32(bytes[offset + 2]) << 16 | UInt32(bytes[offset + 3]) << 24
  }
}

struct CanonImageCaptureProbeView: View {
  @StateObject private var probe = CanonImageCaptureProbe()

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text("Canon ImageCaptureCore PTP Test").font(.title2.bold())
      Text("Uses macOS camera services — no direct USB interface access")
        .foregroundStyle(.secondary)
      HStack {
        Picker("Camera", selection: $probe.selectedID) {
          ForEach(probe.cameras, id: \.uuidString) { camera in
            Text(camera.name ?? "Unnamed camera").tag(camera.uuidString ?? "")
          }
        }
        .frame(maxWidth: 400)
        Button("Read PTP DeviceInfo") { probe.readDeviceInfo() }
          .disabled(probe.working || probe.selectedID.isEmpty)
        Button("Read Canon DeviceInfoEx") { probe.readCanonDeviceInfo() }
          .disabled(probe.working || probe.selectedID.isEmpty)
        if probe.working { ProgressView().controlSize(.small) }
      }
      ScrollView {
        Text(probe.report)
          .font(.system(.callout, design: .monospaced))
          .textSelection(.enabled)
          .frame(maxWidth: .infinity, alignment: .leading)
          .padding(12)
      }
      .background(.quaternary.opacity(0.35))
      .clipShape(RoundedRectangle(cornerRadius: 8))
    }
    .padding(20)
    .frame(minWidth: 750, minHeight: 480)
    .onAppear { probe.start() }
    .onDisappear { probe.stop() }
  }
}
