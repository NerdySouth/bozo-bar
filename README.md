<p align="center">
  <img src="logo.png" width="256" alt="BozoBar">
</p>

<h1 align="center">BozoBar</h1>

<p align="center">
  macOS menu bar app for controlling Bose QuietComfort and QuietComfort Ultra headphones.
</p>

---

BozoBar lives in your menu bar and talks directly to Bose QuietComfort Ultra
and QuietComfort headphones using the BMAP protocol. No companion app required.

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
- Bose QuietComfort Ultra Headphones, paired via system Bluetooth settings
- Bose QuietComfort Headphones, paired via system Bluetooth settings
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

BozoBar uses the Bose Message Access Protocol (BMAP), a proprietary protocol
reverse-engineered from the Bose Music Android app. It selects the working
transport for each paired device: BLE/GATT for QuietComfort Ultra, and classic
Bluetooth RFCOMM for QuietComfort models that expose BMAP controls there.

The app auto-discovers paired Bose devices on launch, connects, and
queries battery, audio mode, noise cancellation, and standby timer state.

### Architecture

```
BozoBarApp          SwiftUI @main, MenuBarExtra
  └─ HeadphoneViewModel   Published state, forwards to BleManager
           └─ BleManager      CoreBluetooth central + transport selection
                ├─ RfcommBmapManager  Classic Bluetooth BMAP transport
                ├─ BmapCodec       Packet codec, BLE segmentation/reassembly
                └─ BmapProtocol    Query builders and response parsers
```

## Supported devices

- Bose QuietComfort Ultra Headphones
- Bose QuietComfort Headphones

Other Bose headphones that use the BMAP protocol over BLE may also work
but have not been tested.

## Related

[bozo](https://github.com/NerdySouth/bozo) — Rust implementation of the
same protocol, with a background daemon (`bozod`) and terminal UI (`bozo`).
Available on [crates.io](https://crates.io/crates/bozo-proto).

## License

[MIT](LICENSE)
