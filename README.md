# meshcore-v

A [MeshCore](https://meshcore.io) **Companion Radio Protocol** client library for the
[V programming language](https://vlang.io), over USB serial.

It lets a host program talk to a MeshCore companion-mode radio (e.g. a Heltec V3
flashed with `companion_radio_usb` firmware): read device info, send/receive
direct and channel text messages, and subscribe to events — with the mesh
routing/encryption handled by the radio.

The API deliberately mirrors the official Python library
([`meshcore_py`](https://github.com/meshcore-dev/meshcore_py)) — `create_serial`,
`subscribe` / `wait_for_event`, and command methods — so it's familiar to anyone
who has used that library.

> Status: early (v0.1.0). Serial transport implemented and verified on real
> hardware (Heltec V3, firmware v1.17.1). BLE/TCP transports not yet implemented.

## Install

```sh
v install --git https://github.com/CptnDuras/meshcore-v
```

Or vendor it and import the `meshcore` module.

## Quick start (echo bot)

```v
import meshcore
import time

fn main() {
	mut mc := meshcore.create_serial('/dev/ttyUSB0', 115200, false)!  // FreeBSD: /dev/cuaU0
	defer { mc.disconnect() }

	// Echo every incoming direct message back to its sender.
	mc.subscribe(.contact_msg_recv, fn [mut mc] (ev meshcore.Event) {
		mc.send_msg(ev.payload.pubkey_prefix, 'you said: ${ev.payload.text}') or {}
	})
	mc.start_auto_message_fetching()

	for { time.sleep(1 * time.second) }
}
```

See [`examples/echo.v`](examples/echo.v).

## Public API (subset)

Connection / lifecycle:
- `create_serial(port string, baud int, debug bool) !&MeshCore`
- `mc.disconnect()`

Commands (encode + await response):
- `mc.send_appstart(app_name string) !Event`      // -> SELF_INFO
- `mc.send_device_query() !Event`                 // -> DEVICE_INFO
- `mc.get_msg(timeout_ms int) ?Event`             // next queued message
- `mc.send_msg(pubkey_prefix_hex string, text string) !Event`  // direct message
- `mc.send_chan_msg(channel_idx u8, text string) !Event`       // channel (0 = public)

Events:
- `mc.subscribe(event_type EventType, cb fn (Event)) Subscription`
- `mc.subscribe_filtered(event_type, cb, filters map[string]string) Subscription`
- `mc.wait_for_event(event_type EventType, timeout_ms int) ?Event`
- `mc.start_auto_message_fetching()` / drain queued + future messages
- `EventType`: `self_info`, `device_info`, `contact_msg_recv`, `channel_msg_recv`,
  `no_more_msgs`, `msg_sent`, `messages_waiting`, `advertisement`, `ack`, `ok`,
  `error`, `raw`, ...

## Notes / gotchas

- **Serial only** for now. Open once and hold the connection — MeshCore radios are
  ESP32-based and reset when DTR is toggled on (re)open. This library clears
  `HUPCL` so closing does not drop DTR, but avoid rapid reconnect cycles.
- The library's event dispatcher runs subscription callbacks on their own threads,
  so a handler may safely issue commands (which block awaiting a response) without
  deadlocking the dispatch loop.
- FreeBSD serial device is typically `/dev/cuaU0`; Linux `/dev/ttyUSB0`.

## License

MIT — see [LICENSE](LICENSE).
