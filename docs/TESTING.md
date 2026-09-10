# meshcore-v Test Suite Specification

Goal: verify the library's pure logic — framing, protocol encode/decode, and the
event dispatcher — **without any radio or serial port**, runnable with `v test .`.

## Testability principle

I/O (opening/reading/writing the serial fd) is isolated in `SerialConnection`
and is NOT unit-tested (it needs hardware). Everything else is pure and testable:

- **Framing** is pure byte manipulation.
- **Parsing** (`parse_frame` and helpers) is pure: `[]u8 -> Event`.
- **Command encoding** is pure: build the payload bytes for each command.
- **EventDispatcher** is in-process (threads + channels), testable with fake events.

### Refactor for testability (small, non-breaking)
- Add pure `encode_frame(payload []u8) []u8` (the `<` + LE-length + payload logic)
  so framing is testable independent of `SerialConnection.write_frame`, which
  will call it.
- Add pure command-encoders returning `[]u8` (payloads), independent of the
  connection: `encode_app_start`, `encode_device_query`, `encode_send_txt_msg`,
  `encode_send_channel_txt_msg`, `encode_sync_next_message`. The `MeshCore`
  command methods call these then write via the connection.

## Golden fixtures (captured from real Heltec V3, firmware v1.17.1)

- **SELF_INFO** (code 5):
  `050116168026ba87b0186959e142fb7243cca485d11c39c1da4c09e4ae71ef863e5b7d4a000000000000000000000000bde40d0024f4000007053830323642413837`
  Expect: tx_power=22, max_tx=22, pubkey=8026ba87...5b7d4a, freq=910.525,
  bw=62.5, sf=7, cr=5, name="8026BA87".
- **DEVICE_INFO** (code 13):
  `0d0daf280000000031342d4175672d323032360048656c74656320563300...` (+ version
  "v1.17.1-d929643" at offset 60). Expect: firmware_ver=13, fw_build="14-Aug-2026",
  model="Heltec V3", fw_version="v1.17.1-d929643".
- **CONTACT_MSG_RECV_V3** (code 16):
  `103100004b81424f7106ff00ad48a26a4168616864676562616a73`
  Expect: pubkey_prefix="4b81424f7106", text="Ahahdgebajs".

## Test modules (files: *_test.v, run with `v test .`)

### framing_test.v
1. `encode_frame` prepends `<` (0x3C) + uint16 LE length + payload.
2. round-trip: `encode_frame` then strip header -> original payload.
3. FrameReader.next extracts one full '>' frame; buffer left empty.
4. FrameReader handles a partial frame (returns none until complete).
5. FrameReader resyncs past leading garbage to the '>' marker.
6. FrameReader extracts two back-to-back frames across one feed.
7. FrameReader handles a frame split across two feeds.

### parsing_test.v
8. SELF_INFO golden decode -> all fields match expected.
9. DEVICE_INFO golden decode -> model/version/build/fw_ver match.
10. CONTACT_MSG_RECV_V3 golden decode -> prefix + text; attributes carry prefix.
11. CONTACT_MSG_RECV (non-v3) offsets: synthesized frame decodes text/prefix.
12. RESP_SENT decode -> expected_ack hex + suggested_timeout.
13. NO_MORE_MESSAGES / MSG_WAITING / OK / ERR map to correct EventType.
14. ADVERT decode -> 32-byte pubkey hex.
15. Unknown code -> EventType.raw with raw_hex set.
16. Empty payload -> EventType.raw, no crash.
17. Truncated SELF_INFO (len<58) -> EventType.raw (graceful).

### encoding_test.v
18. encode_app_start('meshbbs') == [1,3, six 0x20, 'meshbbs' bytes].
19. encode_device_query(3) == [22,3].
20. encode_send_txt_msg: [2,0,attempt, ts(4 LE), 6-byte prefix, text]; text >160 truncated.
21. encode_send_channel_txt_msg: [3,0,chan, ts(4 LE), text]; text >150 truncated.
22. encode_sync_next_message == [10].
23. hex_to_bytes round-trips a known hex string; odd/short input safe.

### events_test.v
24. subscribe + dispatch: matching event type invokes callback (via shared channel).
25. filter: subscribe_filtered only fires when attribute matches.
26. wait_for_event returns the event when dispatched within timeout.
27. wait_for_event returns none on timeout.
28. unsubscribe stops further callbacks.

## Out of scope (needs hardware / not unit-tested)
- SerialConnection.open/read_some/write_frame (real fd + termios).
- MeshCore.create_serial end-to-end (covered by live manual test + examples/echo.v).
