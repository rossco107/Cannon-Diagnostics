# Canon Diagnostics

A lightweight native macOS application for reading camera information from Canon EOS digital SLR cameras over USB, and examining sensor dust information recorded in Canon JPEG files.

Developed and tested with the **Canon EOS 40D and EOS 50D**, using Swift, SwiftUI and Apple's ImageCaptureCore framework. No gPhoto2, Homebrew or external runtime dependencies are required.

## Features

- Read the camera's shutter count
- Display and edit the camera owner's name
- Display the camera model and manufacturer
- Read firmware version and camera serial numbers
- Display battery information and available shots, where supported
- Detect USB camera connections and disconnections
- Analyse Canon JPEG Dust Delete Data and report detected dust marks by approximate size
- Access hidden developer diagnostics to inspect and export PTP and Canon EOS property information

The application communicates with the camera using Picture Transfer Protocol (PTP) and Canon's proprietary EOS extensions.

## Compatibility

**Tested cameras:** Canon EOS 40D and Canon EOS 50D  
**Operating system:** macOS 14 Sonoma or later  
**Processor:** Intel or Apple Silicon  
**Connection:** USB cable between the camera and Mac

Other Canon EOS models may work, but have not been tested or verified. Available properties and behaviour can differ between models.

## Installation

### Build from source

1. Clone or download this repository.
2. Open the Xcode project.
3. Select the macOS application target.
4. Ensure **App Sandbox** is disabled under Signing & Capabilities.
5. Build and run the application.

### Download a compiled application

If a compiled version is available under [Releases](../../releases), download and extract it.

The application may not be signed or notarised by Apple. macOS may block it on first launch. If you trust the downloaded application, you can authorise it through **System Settings → Privacy & Security → Open Anyway**.

## Using the application

1. Connect your Canon EOS camera to the Mac using USB.
2. Switch the camera on.
3. Launch Canon Diagnostics.
4. Click **Read Camera**.

The application retrieves available camera information and displays it in the main window.

To change the camera owner's name, select **Edit** beside Owner name, enter the new name and click **Save**. This changes information stored in the camera.

### Sensor dust test

Use the **Sensor Dust Test** section to select a JPEG taken with the camera after running its built-in Dust Delete Data procedure. The application reads the proprietary Canon dust information embedded in the JPEG and reports detected marks, grouped into approximate size categories.

This is an interpretation of the camera's recorded Dust Delete Data, **not** a live sensor inspection or a calibrated measurement of dust size. Results depend on the data stored in the selected JPEG.

### Developer diagnostics

Hold **Command (⌘)** and click the Canon EOS camera heading to reveal the hidden **Developer Diagnostics** section. Repeat to hide it.

The section provides tools to collect and export a camera property inventory and save raw Canon EOS event data. These exports can be used to investigate differences between camera models. They are intended for diagnostics rather than everyday use.

## How it works

Canon Diagnostics uses Apple's **ImageCaptureCore** framework to discover connected cameras and exchange PTP commands over USB.

Standard PTP commands retrieve device information, while Canon EOS vendor-specific commands provide additional properties such as shutter count, owner name and serial number. The application temporarily enables Canon's remote and event modes when retrieving certain properties, then attempts to restore the normal connection state.

The sensor dust test reads Canon-specific metadata from an existing JPEG file; it does not obtain a live dust map from the camera.

## Limitations

- Only the Canon EOS 40D and EOS 50D have been tested.
- Some properties may not be available on every camera.
- Battery information may be displayed as a raw camera value rather than a percentage.
- Shutter count is read-only.
- Owner-name changes modify information stored in the camera.
- Sensor dust results are approximate and require a JPEG containing Canon Dust Delete Data.
- Direct camera access requires the application to run without App Sandbox.

## Privacy

Canon Diagnostics operates locally on your Mac. It does not require an internet connection or a cloud account. Diagnostic files are exported only when you choose to save them.

## Copyright

Copyright © 2026 Ross Carter. All rights reserved.

The source code is publicly available for inspection. No permission to modify or redistribute it is granted unless a separate licence is provided.

## Disclaimer

Canon Diagnostics is an independent project and is not affiliated with or endorsed by Canon.

The application communicates directly with camera hardware using USB/PTP and proprietary Canon commands. Some operations, including changing the owner name, may modify information stored in the camera.

**Use at your own risk.** The software is provided "AS IS", without warranty of any kind, subject to applicable law. The author accepts no liability for damage, data loss or other problems arising from its use, to the extent permitted by law.
