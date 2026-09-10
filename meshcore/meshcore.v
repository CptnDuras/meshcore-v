module meshcore

import time

// MeshCore is the top-level client, mirroring meshcore.py's MeshCore class.
// It owns the connection, the frame reader (in a background thread), and the
// event dispatcher, and exposes commands + subscribe/wait_for_event.
pub struct MeshCore {
pub mut:
	conn       SerialConnection
	dispatcher &EventDispatcher = &EventDispatcher{}
	reader     FrameReader
	running    bool
	debug      bool
	auto_fetch bool
}

// create_serial mirrors MeshCore.create_serial(): open, start dispatcher +
// reader loop, send appstart, and return the ready client.
pub fn create_serial(port string, baud int, debug bool) !&MeshCore {
	mut mc := &MeshCore{
		conn:  SerialConnection{
			port: port
			baud: baud
		}
		debug: debug
	}
	mc.conn.open()!
	mc.dispatcher.start()
	mc.running = true
	spawn mc.read_loop()
	time.sleep(300 * time.millisecond) // settle after open

	// appstart is required by firmware to initialize the session
	res := mc.send_appstart('meshbbs') or {
		mc.disconnect()
		return error('no response to appstart: ${err}')
	}
	if res.is_error() {
		mc.disconnect()
		return error('appstart returned error')
	}
	return mc
}

// read_loop pumps the serial port, extracts frames, parses them into Events,
// and dispatches. Mirrors reader.py + the dispatch pipeline.
fn (mut mc MeshCore) read_loop() {
	for mc.running {
		chunk := mc.conn.read_some(512)
		if chunk.len > 0 {
			mc.reader.feed(chunk)
			for {
				payload := mc.reader.next() or { break }
				if payload.len == 0 {
					continue
				}
				if mc.debug {
					eprintln('  <- code=${payload[0]} len=${payload.len} hex=${payload.hex()}')
				}
				ev := parse_frame(payload)
				mc.dispatcher.dispatch(ev)
			}
		} else {
			time.sleep(15 * time.millisecond)
		}
	}
}

pub fn (mut mc MeshCore) disconnect() {
	mc.running = false
	mc.dispatcher.stop()
	mc.conn.close()
}

// --- public subscribe / wait_for_event (delegate to dispatcher) ---
pub fn (mut mc MeshCore) subscribe(event_type EventType, cb fn (Event)) Subscription {
	return mc.dispatcher.subscribe(event_type, cb)
}

pub fn (mut mc MeshCore) subscribe_filtered(event_type EventType, cb fn (Event), filters map[string]string) Subscription {
	return mc.dispatcher.subscribe_filtered(event_type, cb, filters)
}

pub fn (mut mc MeshCore) unsubscribe(sub Subscription) {
	mc.dispatcher.unsubscribe(sub)
}

pub fn (mut mc MeshCore) wait_for_event(event_type EventType, timeout_ms int) ?Event {
	return mc.dispatcher.wait_for_event(event_type, map[string]string{}, timeout_ms)
}

// --- commands (encode + write + wait_for_event for the response) ---

// send_appstart -> SELF_INFO
pub fn (mut mc MeshCore) send_appstart(app_name string) !Event {
	mc.conn.write_frame(encode_app_start(app_name))!
	return mc.wait_for_event(.self_info, 5000) or { return error('timeout waiting for SELF_INFO') }
}

// send_device_query -> DEVICE_INFO
pub fn (mut mc MeshCore) send_device_query() !Event {
	mc.conn.write_frame(encode_device_query(3))!
	return mc.wait_for_event(.device_info, 5000) or {
		return error('timeout waiting for DEVICE_INFO')
	}
}

// get_msg -> CONTACT_MSG_RECV / CHANNEL_MSG_RECV / NO_MORE_MSGS
// Mirrors commands.get_msg(): request next queued message.
pub fn (mut mc MeshCore) get_msg(timeout_ms int) ?Event {
	mc.conn.write_frame(encode_sync_next_message()) or { return none }
	// any of these three may come back; wait for whichever arrives first by
	// racing three short waits is overkill — instead wait on a small window
	// and let the reader dispatch; we subscribe to all three via match.
	deadline := time.now().add(timeout_ms * time.millisecond)
	result := chan Event{cap: 1}
	cb := fn [result] (ev Event) {
		select {
			result <- ev {}
			else {}
		}
	}
	s1 := mc.dispatcher.subscribe(.contact_msg_recv, cb)
	s2 := mc.dispatcher.subscribe(.channel_msg_recv, cb)
	s3 := mc.dispatcher.subscribe(.no_more_msgs, cb)
	defer {
		mc.dispatcher.unsubscribe(s1)
		mc.dispatcher.unsubscribe(s2)
		mc.dispatcher.unsubscribe(s3)
	}
	for time.now() < deadline {
		select {
			ev := <-result {
				return ev
			}
			300 * time.millisecond {}
		}
	}
	return none
}

// send_msg sends a direct text message to a contact identified by the first
// 6 bytes of its public key (hex). Mirrors commands.send_msg().
pub fn (mut mc MeshCore) send_msg(pubkey_prefix_hex string, text string) !Event {
	prefix := hex_to_bytes(pubkey_prefix_hex)
	if prefix.len < 6 {
		return error('pubkey prefix must be >= 6 bytes')
	}
	ts := u32(time.now().unix())
	mc.conn.write_frame(encode_send_txt_msg(prefix, ts, text))!
	return mc.wait_for_event(.msg_sent, 5000) or { return error('timeout waiting for SENT') }
}

// send_chan_msg sends a text message to a channel (0 = public).
pub fn (mut mc MeshCore) send_chan_msg(channel_idx u8, text string) !Event {
	ts := u32(time.now().unix())
	mc.conn.write_frame(encode_send_channel_txt_msg(channel_idx, ts, text))!
	// channel send responds with OK (per spec)
	return mc.wait_for_event(.ok, 5000) or { return error('timeout waiting for OK') }
}

// start_auto_message_fetching mirrors meshcore.py: on MESSAGES_WAITING, drain
// the queue via get_msg until NO_MORE_MSGS. Runs a background thread.
pub fn (mut mc MeshCore) start_auto_message_fetching() {
	mc.auto_fetch = true
	// subscribe: when messages waiting, spawn a drain
	mc_cb := fn [mut mc] (ev Event) {
		spawn mc.drain_messages()
	}
	mc.dispatcher.subscribe(.messages_waiting, mc_cb)
	// also do an initial drain in case messages are already queued
	spawn mc.drain_messages()
}

fn (mut mc MeshCore) drain_messages() {
	for mc.running {
		ev := mc.get_msg(4000) or { break }
		if ev.typ == .no_more_msgs || ev.typ == .error {
			break
		}
		time.sleep(100 * time.millisecond)
	}
}

// hex_to_bytes converts a hex string to bytes (helper).
fn hex_to_bytes(s string) []u8 {
	mut out := []u8{}
	mut i := 0
	for i + 1 < s.len + 1 && i + 2 <= s.len {
		hi := hexval(s[i])
		lo := hexval(s[i + 1])
		if hi < 0 || lo < 0 {
			break
		}
		out << u8((u32(hi) << 4) | u32(lo))
		i += 2
	}
	return out
}

fn hexval(c u8) int {
	if c >= `0` && c <= `9` {
		return int(c - `0`)
	}
	if c >= `a` && c <= `f` {
		return int(c - `a`) + 10
	}
	if c >= `A` && c <= `F` {
		return int(c - `A`) + 10
	}
	return -1
}
