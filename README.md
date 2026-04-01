<p align="center">
  <img src="logo.png" width="256" alt="BozoBar">
</p>

<h1 align="center">BozoBar</h1>

<p align="center">
  macOS menu bar app for controlling Bose QC Ultra headphones over Bluetooth.
</p>

---

BozoBar lives in your menu bar and talks directly to your Bose QC Ultra
headphones over BLE using the BMAP protocol. No companion app required.

## Features

| Feature | Description |
|---------|-------------|
| Battery | Live battery percentage and remaining play time |
| Audio Modes | Switch between Quiet, Aware, and custom modes |
| Standby Timer | Set auto-off timeout (5 min to 2 hours, or never) |
| Power Off | Power down headphones from the menu bar |
| Reconnect | Re-scan and reconnect if the connection drops |

## Requirements

- macOS 13.0+
- Bose QC Ultra Headphones (Gen 1), paired via system Bluetooth settings
- Bluetooth permission granted to BozoBar

## Install

### Mac App Store

*Coming soon.*

### Build from source

```
swift build
```

Open in Xcode for signing and archiving:

```
open Package.swift
```

## How it works

BozoBar uses CoreBluetooth to communicate with your headphones via the
Bose Message Access Protocol (BMAP) — a proprietary BLE GATT protocol
reverse-engineered from the Bose Music Android app.

The app auto-discovers paired Bose devices on launch, connects, and
queries battery, audio mode, noise cancellation, and standby timer state.
All control commands are sent as segmented BMAP packets over a single
BLE characteristic.

### Architecture

```
BozoBarApp          SwiftUI @main, MenuBarExtra
  └─ HeadphoneViewModel   Published state, forwards to BleManager
       └─ BleManager      CoreBluetooth central + peripheral delegate
            ├─ BmapCodec       Packet codec, BLE segmentation/reassembly
            └─ BmapProtocol    Query builders and response parsers
```

## Supported devices

- Bose QuietComfort Ultra Headphones

Other Bose headphones that use the BMAP protocol over BLE may also work
but have not been tested.

## Related

[bozo](https://github.com/NerdySouth/bozo) — Rust implementation of the
same protocol, with a background daemon (`bozod`) and terminal UI (`bozo`).
Available on [crates.io](https://crates.io/crates/bozo-proto).

## License

[MIT](LICENSE)
