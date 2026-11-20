# Maramat Duino-S support — handover

Status: **working slice with live watch**. FBD compile to MFLW, MaraProt v1 over USB CDC **and
Ethernet TCP 5020**, automatic local-network/USB discovery, device identification/status, full image
upload, and live slot watching are implemented. RS-485 and DFU are not.

## What the Duino-S is

The Duino-S (`STM32F407`, firmware `Duino-S_FW`) is **not** a Dirigo D3Net PLC. It runs the MaraVM
bytecode VM and speaks MaraProt v1 over USB CDC, Ethernet TCP **5020**, and RS-485.

Sources used:

- `https://github.com/supopur/Duino-S_FW/blob/master/MARAPROT.md`
- `https://github.com/supopur/Duino-S_FW` (`Core/Inc/mara_vm.h`, `Core/Src/mara_vm.c`,
  `Core/Inc/plc_hal.h`, `Core/Src/plc_hal.c`)
- `https://github.com/supopur/maraflow` (`MflwEmitter.java`, `MaraProtClient.java`,
  `NativeMaraVm.java`)

## Code map

| File | Purpose |
| --- | --- |
| `Sources/WirebenchHardware/MaraProtFrame.swift` | MaraProt v1 frame codec, CRC-16-CCITT and CRC-32 |
| `Sources/WirebenchHardware/MaraProtClient.swift` | MaraProt client: ping, GET_INFO, VM_STATUS, VM control, chunked upload, watch subscribe/poll, slot read/write |
| `Sources/WirebenchHardware/MaraTCPTransport.swift` | Ethernet TCP transport (POSIX sockets, port 5020) |
| `Sources/WirebenchHardware/MaraDiscovery.swift` | Local subnet scan and USB-port probing, accepted only through GET_INFO's model identity |
| `Sources/WirebenchModel/DuinoCompiler.swift` | FBD project → MFLW image, slot allocation and opcode emission |
| `Sources/WirebenchModel/DuinoMacroExpansion.swift` | Inlines FBD macro sheets before emission |
| `Sources/WirebenchModel/AppModel+Duino.swift` | `HardwareFamily`, identify, compile+upload, live watch session, UI state |
| `Sources/WirebenchMaraVM/` | Swift owner for the portable `mara_vm.c` used by tests |
| `Sources/WirebenchMaraVMC/` | Vendored portable MaraVM C engine (`mara_vm.c`, `mara_vm.h`) |
| `Sources/WirebenchApp/HardwareLinkView.swift` | PLC family picker, Duino-S identify/upload actions |
| `Sources/WirebenchCLI/WirebenchCLI.swift` | `duino-build`, `duino-upload` commands |
| `Tests/WirebenchTests/DuinoCompilerTests.swift` | compile + firmware-VM execution tests |
| `Tests/WirebenchTests/MaraProtTests.swift` | framing, checksums, client/upload tests |

## MFLW image

72-byte header, little-endian, as `mara_vm.h`:

```
0  magic 0x574C464D ("MFLW")      20 numBoolSlots
4  format 0x0001                  22 numIntSlots
6  target model 0x0407            24 numLongSlots
8  image size (bytes)             26 numFloatSlots
12 payload CRC-32 (from byte 72)  28 numStateSlots
16 project hash                   32 estop config
20 ...                           36 init table offset (=72)
                                 40 init entry count
                                 44 threadOffset[0..5] (thread 1..5; 0 unused)
72 init table: [slot u16][reserved u16][raw bits u64] × count
   then thread 1 bytecode, thread 2, ... thread 5
```

Every thread ends with `HALT` (`0x00`). Instructions are 8-byte words
`[opcode u8][flags u8][enSlot u16][dstSlot u16][srcA u16]`, with operation-specific trailing
`u16`/`u64` operands. Slot ID = `(type << 14) | index`, types BOOL=0, INT=1, LONG=2, FLOAT=3.
`0xFFFF` is the always-enabled slot.

## Compiler coverage

Implemented from Maraflow's emitter and the firmware VM:

- BOOL: And/Nand/Or/Nor/Xor/Xnor, Not, RS/SR
- Math: Add/Sub/Mul/Min/Max, Div/Mod, Abs/Neg/Sqrt/Sin/Cos, Clamp
- Comparators: EQ/NE/GT/GE/LT/LE
- Switches: Sel
- Timers: Timer (TON), SinglePulse (one-shot)
- Conversion: PackBits/UnpackBits
- I/O: IREF/OREF, PWM
- Visual variables/Value: initial values and slot names
- FBD macro sheets (inline expansion, nested)
- Native Dirigo blocks covered by `MaraflowExporter.bridge`: And/Or/Xor/Not/RS, IAdd/ISub/IMul,
  IAbs/INeg, FSqrt/FSin/FCos, FAdd/FSub/FMul, ISwitch, Div, 8xDI/8xDO/PulseGen/SinglePulse and
  the visual variable types (the latter few still need their emitter cases in a later pass)

Explicitly rejected with a compile error:

- ST and LD pages (FBD only in this pass)
- Blocks with no `MaraflowDefinition` and no bridge mapping
- VM opcodes not implemented by the portable firmware VM (for example PulseGen)

A wire from a display/unsupported block is treated as constant 0 and reported in `notes`; it does
not abort the image.

## UI

Hardware Link now has a `Dirigo` / `Duino-S` segmented picker.

- **Duino-S** has liquid-glass **USB / Ethernet** transport picker. USB shows the selected CDC port;
  Ethernet takes an IP address and TCP port (default 5020). Both offer an **Identify** action
  (background PING, GET_INFO, VM_STATUS; it changes no program state and does not block the editor),
  **Build Project**, and **Watch / Stop Watch**. Build Project now opens a **Duino-S Build** report
  (image size, slots, notes) whose primary action is **Upload to Duino-S**; the standalone upload
  button is gone from the Hardware Link card.
- Watch compiles the same operand→slot table, subscribes up to 512 slots, takes a full snapshot,
  then polls deltas every 100 ms and shows the decoded values in the card.
- Selecting Duino-S / Ethernet starts discovery automatically. **Find** (USB) and **Find Duino-S**
  (Ethernet) rescan; the Ethernet scan probes local IPv4 /24 subnets on TCP 5020 and accepts a
  device only when GET_INFO reports model `0x0407` or a name containing `Duino`. A single result is
  selected automatically; multiple results appear in a device menu.
- **PLC ▸ Watch Duino-S** (⌘⇧W) starts/stops the same watch session from the menu bar.
  **PLC ▸ Find Duino-S** (⌘⇧D) rescans.
- Build → Upload Compiled Program routes to the Duino-S when that family is selected.
- Upload progress, phase and the framed log are reused from the existing Hardware Link.

## CLI

```
wirebench-cli duino-discover [--tcp-port 5020]
wirebench-cli duino-build <project> [--out <image.mflw>]
wirebench-cli duino-upload <project> --port /dev/cu.usbmodem... [--address 0]
wirebench-cli duino-upload <project> --host 192.168.1.50 [--tcp-port 5020]
wirebench-cli duino-watch <project> --port /dev/cu.usbmodem... [--seconds 10]
wirebench-cli duino-watch <project> --host 192.168.1.50 [--seconds 10]
```

`duino-discover` scans local IPv4 subnets and prints the Duino-S boards it finds. `duino-build`
writes the image and prints slot/notes. `duino-upload` identifies the device, refuses
a model other than 0x0407, uploads with auto-start and prints progress.

## USB CDC and Ethernet TCP details

- USB: use the USB virtual COM port (`cu.usbmodem*` on macOS, `ttyACM*` on Linux).
- Open at 115200 8N1 with **no parity** (the CDC line rate is ignored by the device, but the port
  still needs a setting).
- USB station ID `0` (P2P) is the default; RS-485 needs `1..247` and a real transport.
- Ethernet: connect to the device's IP at TCP port 5020. The firmware is point-to-point on TCP, so
  station `0` is used there too.
- Discovery: the firmware starts lwIP with DHCP, but `lwipopts.h` leaves `LWIP_MDNS_RESPONDER` and
  `LWIP_NETBIOS_RESPONDER` at their default 0, and `LWIP_NETIF_HOSTNAME` is 0, so there is no mDNS,
  NetBIOS or hostname to query. Discovery scans the local IPv4 subnets on TCP 5020 and validates
  GET_INFO (`modelId 0x0407`, name `Duino - S`). USB discovery probes each CDC port the same way.
- Frame: `4D 50 10 ST SEQlo SEQhi OP STATUS LENlo LENhi payload CRC16lo CRC16hi`; CRC-16-CCITT
  poly `0x1021`, init `0xFFFF`, over header+payload.
- Upload: `VM_UPLOAD_BEGIN` (total size + full-image CRC32) → repeated `VM_UPLOAD_CHUNK`
  (offset + bytes) → `VM_UPLOAD_COMMIT` (autoStart=1). The commit reply reports the MFLW
  **header's payload CRC** (from byte 72), not the full-image CRC sent at BEGIN; the client compares
  the right one of each.

## Hardware map (firmware source of truth)

From `plc_hal.c`: model ID `0x0407`; DIO channels `2..7`, `9..27` are mapped; channels 0, 1, 8
are not. PWM logical indices 0..7 map to DIO 4,5,6,7,9,10,11,12. ADC has 4 channels; AO 0/1.
The compiler currently takes I/O channel numbers from the block's `Channel` property (IREF/OREF/PWM)
and does not yet validate them against the board map.

## Tests

- `DuinoCompilerTests` build MFLW images and **load/step them in the actual portable `mara_vm.c`**:
  - Bool And
  - wired Int comparator
  - Timer/TON elapsed time
  - nested FBD macro project
  - image header/model/CRC checks
- `MaraProtTests` cover CRC vectors, frame round-trip/corruption, client ping/info/status, chunked
  upload, watch subscribe/poll, slot read/write, a real pseudo-terminal serial exchange, and a real
  loopback TCP exchange.

Run:

```
swift test --disable-sandbox --filter 'DuinoCompilerTests|MaraProtTests'
```

## Known gaps / next steps

1. The Watch UI displays values but does not offer forcing (SLOT_WRITE_BATCH) yet; the client method exists.
2. RS-485 transport; USB CDC and Ethernet TCP 5020 are implemented.
3. ST/LD pages (Maraflow's `StBytecodeCompiler`/ladder) are not ported.
4. Broad native Dirigo block coverage; many `TM*` blocks still have no Duino-S mapping.
5. `IO.8xDI`/`IO.8xDO` and PulseGen: importer/bridge exists, emitter case/VM support still missing.
6. E-stop configuration, retentive/EEPROM parameters and the project's declared target model are not
   carried into the image yet; the compiler always emits model 0x0407.
7. Firmware update/DFU entry.
8. No physical Duino-S has been tested yet. The protocol and image path are validated against the
   firmware VM, a frame-level fake, and a pseudo-terminal serial pair, not real hardware.
9. Project target/profile is a global Hardware Link choice; it is not yet stored in the project.
