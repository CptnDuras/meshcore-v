module meshcore

import time

// KissClient drives a board running MeshCore's KISS modem firmware role
// (kiss_framing.v / docs/kiss_modem_protocol.md) — a raw LoRa TNC, not the
// mesh companion app. It reuses SerialConnection's raw I/O (same 115200 8N1
// transport) but speaks KISS framing on top instead of the '<'/'>' one.
//
// This client is synchronous: each hw_* request writes a frame and blocks
// for its matching response, skipping over any unsolicited frames (Data,
// TxDone, RxMeta) that arrive first. Callers who need those should read them
// with recv_frame directly — typically in a loop, between (or instead of)
// issuing requests — since the TNC can send one at any time.
pub struct KissClient {
pub mut:
	conn   SerialConnection
	reader KissFrameReader
}

pub fn create_kiss_serial(port string) !&KissClient {
	mut kc := &KissClient{
		conn: SerialConnection{
			port: port
			baud: 115200
		}
	}
	kc.conn.open()!
	return kc
}

pub fn (mut kc KissClient) close() {
	kc.conn.close()
}

// recv_frame blocks (polling the serial port) until a complete KISS frame
// arrives or timeout_ms elapses.
pub fn (mut kc KissClient) recv_frame(timeout_ms int) ?KissFrame {
	deadline := time.now().add(timeout_ms * time.millisecond)
	for time.now() < deadline {
		if f := kc.reader.next() {
			return f
		}
		data := kc.conn.read_some(512)
		if data.len > 0 {
			kc.reader.feed(data)
			if f := kc.reader.next() {
				return f
			}
		} else {
			time.sleep(20 * time.millisecond)
		}
	}
	return none
}

// hw_request sends a SetHardware sub-command and waits for its matching
// response (or an Error frame), ignoring unrelated frames in between.
fn (mut kc KissClient) hw_request(sub u8, payload []u8, want_resp u8, timeout_ms int) ![]u8 {
	kc.conn.write_raw(encode_kiss_hw(sub, payload))!
	deadline := time.now().add(timeout_ms * time.millisecond)
	for {
		remaining := deadline - time.now()
		if remaining <= 0 {
			return error('timeout waiting for KISS response 0x${want_resp:02x}')
		}
		f := kc.recv_frame(int(remaining.milliseconds())) or {
			return error('timeout waiting for KISS response 0x${want_resp:02x}')
		}
		if f.cmd == kiss_cmd_sethardware && f.data.len > 0 {
			if f.data[0] == want_resp {
				return f.data[1..].clone()
			}
			if f.data[0] == kiss_hw_error {
				code := if f.data.len > 1 { f.data[1] } else { u8(0) }
				return error('KISS error code ${code}')
			}
		}
		// else: an unrelated/unsolicited frame (Data, TxDone, RxMeta) that
		// arrived while we were waiting — loop and keep waiting for ours.
	}
	return error('timeout waiting for KISS response 0x${want_resp:02x}')
}

pub fn (mut kc KissClient) get_identity(timeout_ms int) ![]u8 {
	return kc.hw_request(kiss_hw_get_identity, []u8{}, kiss_hw_identity, timeout_ms)
}

pub fn (mut kc KissClient) get_random(length u8, timeout_ms int) ![]u8 {
	return kc.hw_request(kiss_hw_get_random, [length], kiss_hw_random, timeout_ms)
}

pub fn (mut kc KissClient) get_version(timeout_ms int) !u8 {
	r := kc.hw_request(kiss_hw_get_version, []u8{}, kiss_hw_version_resp, timeout_ms)!
	return if r.len > 0 { r[0] } else { u8(0) }
}

// KissRadioParams mirrors the firmware's SetRadio/Radio layout: all values
// little-endian, Freq/BW in Hz.
pub struct KissRadioParams {
pub:
	freq_hz u32
	bw_hz   u32
	sf      u8
	cr      u8
}

pub fn (mut kc KissClient) get_radio(timeout_ms int) !KissRadioParams {
	r := kc.hw_request(kiss_hw_get_radio, []u8{}, kiss_hw_radio, timeout_ms)!
	if r.len < 10 {
		return error('short GetRadio response (${r.len} bytes)')
	}
	return KissRadioParams{
		freq_hz: le_u32(r, 0)
		bw_hz:   le_u32(r, 4)
		sf:      r[8]
		cr:      r[9]
	}
}

pub fn (mut kc KissClient) set_radio(p KissRadioParams, timeout_ms int) ! {
	mut data := []u8{}
	put_u32_le(mut data, p.freq_hz)
	put_u32_le(mut data, p.bw_hz)
	data << p.sf
	data << p.cr
	kc.hw_request(kiss_hw_set_radio, data, kiss_hw_radio, timeout_ms)!
}

pub fn (mut kc KissClient) get_tx_power(timeout_ms int) !u8 {
	r := kc.hw_request(kiss_hw_get_tx_power, []u8{}, kiss_hw_tx_power_resp, timeout_ms)!
	return if r.len > 0 { r[0] } else { u8(0) }
}

pub fn (mut kc KissClient) set_tx_power(dbm u8, timeout_ms int) ! {
	kc.hw_request(kiss_hw_set_tx_power, [dbm], kiss_hw_tx_power_resp, timeout_ms)!
}

// get_current_rssi returns the radio's current RSSI in dBm (signed).
pub fn (mut kc KissClient) get_current_rssi(timeout_ms int) !int {
	r := kc.hw_request(kiss_hw_get_current_rssi, []u8{}, kiss_hw_current_rssi, timeout_ms)!
	return if r.len > 0 { signed_i8(r[0]) } else { 0 }
}

pub fn (mut kc KissClient) is_channel_busy(timeout_ms int) !bool {
	r := kc.hw_request(kiss_hw_is_channel_busy, []u8{}, kiss_hw_channel_busy, timeout_ms)!
	return r.len > 0 && r[0] != 0
}

// get_airtime estimates the airtime (ms) of a packet of the given length,
// at the radio's current settings.
pub fn (mut kc KissClient) get_airtime(packet_len u8, timeout_ms int) !u32 {
	r := kc.hw_request(kiss_hw_get_airtime, [packet_len], kiss_hw_airtime_resp, timeout_ms)!
	if r.len < 4 {
		return error('short GetAirtime response (${r.len} bytes)')
	}
	return le_u32(r, 0)
}

// get_noise_floor returns the current noise floor in dBm (signed). The
// firmware recalibrates it every 2s with an AGC reset every 30s.
pub fn (mut kc KissClient) get_noise_floor(timeout_ms int) !int {
	r := kc.hw_request(kiss_hw_get_noise_floor, []u8{}, kiss_hw_noise_floor, timeout_ms)!
	if r.len < 2 {
		return error('short GetNoiseFloor response (${r.len} bytes)')
	}
	return signed_i16(le_u16(r, 0))
}

pub struct KissStats {
pub:
	rx     u32
	tx     u32
	errors u32
}

pub fn (mut kc KissClient) get_stats(timeout_ms int) !KissStats {
	r := kc.hw_request(kiss_hw_get_stats, []u8{}, kiss_hw_stats_resp, timeout_ms)!
	if r.len < 12 {
		return error('short GetStats response (${r.len} bytes)')
	}
	return KissStats{
		rx:     le_u32(r, 0)
		tx:     le_u32(r, 4)
		errors: le_u32(r, 8)
	}
}

pub fn (mut kc KissClient) get_battery(timeout_ms int) !u16 {
	r := kc.hw_request(kiss_hw_get_battery, []u8{}, kiss_hw_battery_resp, timeout_ms)!
	if r.len < 2 {
		return error('short GetBattery response (${r.len} bytes)')
	}
	return le_u16(r, 0)
}

// get_mcu_temp returns the MCU temperature in tenths of a degree C (e.g.
// 253 = 25.3C). Errors with NoCallback if the board does not support it.
pub fn (mut kc KissClient) get_mcu_temp(timeout_ms int) !int {
	r := kc.hw_request(kiss_hw_get_mcu_temp, []u8{}, kiss_hw_mcu_temp_resp, timeout_ms)!
	if r.len < 2 {
		return error('short GetMCUTemp response (${r.len} bytes)')
	}
	return signed_i16(le_u16(r, 0))
}

pub fn (mut kc KissClient) get_device_name(timeout_ms int) !string {
	r := kc.hw_request(kiss_hw_get_device_name, []u8{}, kiss_hw_device_name_resp, timeout_ms)!
	return r.bytestr()
}

pub fn (mut kc KissClient) ping(timeout_ms int) ! {
	kc.hw_request(kiss_hw_ping, []u8{}, kiss_hw_pong, timeout_ms)!
}

// reboot restarts the board. The firmware replies OK, flushes, then reboots,
// so the serial connection drops; this does not wait for that OK.
pub fn (mut kc KissClient) reboot() ! {
	kc.conn.write_raw(encode_kiss_hw(kiss_hw_reboot, []u8{}))!
}

// set_signal_report enables/disables the unsolicited RxMeta frame that
// follows each received Data frame (SNR + RSSI). Enabled by default.
pub fn (mut kc KissClient) set_signal_report(enable bool, timeout_ms int) ! {
	kc.hw_request(kiss_hw_set_signal_report, [if enable { u8(1) } else { u8(0) }], kiss_hw_signal_report_resp,
		timeout_ms)!
}

// send_data queues a raw packet for transmission (standard KISS Data frame).
// Only one packet may be pending; call recv_frame to see the TxBusy error or
// eventual TxDone.
pub fn (mut kc KissClient) send_data(payload []u8) ! {
	kc.conn.write_raw(encode_kiss_frame(kiss_cmd_data, payload))!
}

// set_tx_delay/set_persistence/set_slot_time/set_tx_tail/set_full_duplex
// configure the standard KISS CSMA parameters (no reply expected).
pub fn (mut kc KissClient) set_tx_delay(tens_of_ms u8) ! {
	kc.conn.write_raw(encode_kiss_frame(kiss_cmd_txdelay, [tens_of_ms]))!
}

pub fn (mut kc KissClient) set_persistence(p u8) ! {
	kc.conn.write_raw(encode_kiss_frame(kiss_cmd_persistence, [p]))!
}

pub fn (mut kc KissClient) set_slot_time(tens_of_ms u8) ! {
	kc.conn.write_raw(encode_kiss_frame(kiss_cmd_slottime, [tens_of_ms]))!
}

pub fn (mut kc KissClient) set_tx_tail(tens_of_ms u8) ! {
	kc.conn.write_raw(encode_kiss_frame(kiss_cmd_txtail, [tens_of_ms]))!
}

pub fn (mut kc KissClient) set_full_duplex(full bool) ! {
	kc.conn.write_raw(encode_kiss_frame(kiss_cmd_fullduplex, [if full { u8(1) } else { u8(0) }]))!
}

fn signed_i8(b u8) int {
	return if b > 127 { int(b) - 256 } else { int(b) }
}

fn signed_i16(v u16) int {
	return if v > 32767 { int(v) - 65536 } else { int(v) }
}
