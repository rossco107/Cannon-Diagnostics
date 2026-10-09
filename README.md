# Canon Diagnostics

A lightweight native macOS application for reading camera information directly from Canon EOS cameras over USB.

Developed and tested with the **Canon EOS 40D**, using Swift, SwiftUI and Apple's IOKit framework. No gPhoto2, Homebrew or external runtime dependencies are required.

## Features

- Read the camera's mechanical shutter count
- Display and edit the camera owner's name
- Display the camera model and manufacturer
- Read firmware version and serial numbers
- Display battery information and available shots, where supported
- Show USB connection information
- Inspect PTP and Canon EOS protocol diagnostics

The application communicates directly with the camera using Picture Transfer Protocol (PTP) and Canon's proprietary EOS extensions.

## Compatibility

**Tested camera:** Canon EOS 40D  
**Operating system:** macOS 14 Sonoma or later  
**Processor:** Intel or Apple Silicon  
**Connection:** USB cable between the camera and Mac

Other Canon EOS models may work, but have not been tested.

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

The application will retrieve available camera information and display it in the main window.

To change the camera owner's name, select **Edit** beside Owner name, enter the new name and click **Save**.

A collapsible Diagnostics section provides additional technical information.

## How it works

Canon Diagnostics uses Apple's `IOUSBHost` APIs to communicate with the camera's USB interface.

Standard PTP commands retrieve device information, while Canon EOS vendor-specific commands provide additional properties such as shutter count and owner name.

The application temporarily enables Canon's remote and event modes while retrieving certain properties, then attempts to restore the normal connection state.

## Limitations

- Only the Canon EOS 40D has been tested.
- Some properties may not be available on every camera.
- Battery information may be displayed as a raw camera value rather than a percentage.
- The shutter count is read-only.
- Owner-name changes modify information stored in the camera.
- The application requires direct USB access and must run without App Sandbox.

## Privacy

Canon Diagnostics operates locally on your Mac. It does not require an internet connection or a cloud account.

## Copyright

Copyright © 2026 Ross Carter. All rights reserved.

The source code is publicly available for inspection. No permission to modify or redistribute it is granted unless a separate licence is provided.



### Compatibility and disclaimer

Canon Diagnostics has been developed and tested with the **Canon EOS 40D only**.

Other Canon EOS cameras may work, but compatibility has not been tested or verified.

The application communicates directly with camera hardware using USB/PTP and proprietary Canon commands. Some operations may modify information stored in the camera.

**Use at your own risk.** The software is provided "AS IS", without warranty of any kind, subject to applicable law. The author accepts no liability for damage, data loss or other problems arising from its use, to the extent permitted by law.

Canon Diagnostics is an independent project and is not affiliated with or endorsed by Canon.
