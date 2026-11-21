module meshcore

// KISS TNC framing (KA9Q/K3MC spec), used by a board running MeshCore's
// *KISS modem* firmware role instead of the companion-radio role — see
// docs/kiss_modem_protocol.md in the meshcore firmware repo. This is a
// different protocol from the rest of this module: different framing,
// different command set, no app_start handshake. A board can only run one
// role at a time.

const kiss_fend = u8(0xC0) // frame delimiter
const kiss_fesc = u8(0xDB) // escape character
const kiss_tfend = u8(0xDC) // escaped FEND
const kiss_tfesc = u8(0xDD) // escaped FESC

// --- Standard KISS commands (host -> TNC), low nibble of the type byte (port 0, single-port TNC) ---
pub const kiss_cmd_data = u8(0x00)
pub const kiss_cmd_txdelay = u8(0x01)
pub const kiss_cmd_persistence = u8(0x02)
pub const kiss_cmd_slottime = u8(0x03)
pub const kiss_cmd_txtail = u8(0x04)
pub const kiss_cmd_fullduplex = u8(0x05)
pub const kiss_cmd_sethardware = u8(0x06) // MeshCore extensions live here
pub const kiss_cmd_return = u8(0xFF)

// --- MeshCore SetHardware sub-commands (host -> TNC) ---
pub const kiss_hw_get_identity = u8(0x01)
pub const kiss_hw_get_random = u8(0x02)
pub const kiss_hw_verify_signature = u8(0x03)
pub const kiss_hw_sign_data = u8(0x04)
pub const kiss_hw_encrypt_data = u8(0x05)
pub const kiss_hw_decrypt_data = u8(0x06)
pub const kiss_hw_key_exchange = u8(0x07)
pub const kiss_hw_hash = u8(0x08)
pub const kiss_hw_set_radio = u8(0x09)
pub const kiss_hw_set_tx_power = u8(0x0A)
pub const kiss_hw_get_radio = u8(0x0B)
pub const kiss_hw_get_tx_power = u8(0x0C)
pub const kiss_hw_get_current_rssi = u8(0x0D)
pub const kiss_hw_is_channel_busy = u8(0x0E)
pub const kiss_hw_get_airtime = u8(0x0F)
pub const kiss_hw_get_noise_floor = u8(0x10)
pub const kiss_hw_get_version = u8(0x11)
pub const kiss_hw_get_stats = u8(0x12)
pub const kiss_hw_get_battery = u8(0x13)
pub const kiss_hw_get_mcu_temp = u8(0x14)
pub const kiss_hw_get_sensors = u8(0x15)
pub const kiss_hw_get_device_name = u8(0x16)
pub const kiss_hw_ping = u8(0x17)
pub const kiss_hw_reboot = u8(0x18)
pub const kiss_hw_set_signal_report = u8(0x19)
pub const kiss_hw_get_signal_report = u8(0x1A)

// --- MeshCore SetHardware responses (TNC -> host): request | 0x80, plus the generic/unsolicited 0xF0+ range ---
pub const kiss_hw_identity = u8(0x81)
pub const kiss_hw_random = u8(0x82)
pub const kiss_hw_verify = u8(0x83)
pub const kiss_hw_signature = u8(0x84)
pub const kiss_hw_encrypted = u8(0x85)
pub const kiss_hw_decrypted = u8(0x86)
pub const kiss_hw_shared_secret = u8(0x87)
pub const kiss_hw_hash_resp = u8(0x88)
pub const kiss_hw_radio = u8(0x8B)
pub const kiss_hw_tx_power_resp = u8(0x8C)
pub const kiss_hw_current_rssi = u8(0x8D)
pub const kiss_hw_channel_busy = u8(0x8E)
pub const kiss_hw_airtime_resp = u8(0x8F)
pub const kiss_hw_noise_floor = u8(0x90)
pub const kiss_hw_version_resp = u8(0x91)
pub const kiss_hw_stats_resp = u8(0x92)
pub const kiss_hw_battery_resp = u8(0x93)
pub const kiss_hw_mcu_temp_resp = u8(0x94)
pub const kiss_hw_sensors_resp = u8(0x95)
pub const kiss_hw_device_name_resp = u8(0x96)
pub const kiss_hw_pong = u8(0x97)
pub const kiss_hw_signal_report_resp = u8(0x9A)
pub const kiss_hw_ok = u8(0xF0)
pub const kiss_hw_error = u8(0xF1)
pub const kiss_hw_tx_done = u8(0xF8) // unsolicited: TX finished
pub const kiss_hw_rx_meta = u8(0xF9) // unsolicited: queued just before the Data frame it describes

// kiss_escape applies FESC/TFEND/TFESC escaping to raw frame data (the part
// between the FEND delimiters).
fn kiss_escape(data []u8) []u8 {
	mut out := []u8{cap: data.len}
	for b in data {
		if b == kiss_fend {
			out << kiss_fesc
			out << kiss_tfend
		} else if b == kiss_fesc {
			out << kiss_fesc
			out << kiss_tfesc
		} else {
			out << b
		}
	}
	return out
}

fn kiss_unescape(data []u8) []u8 {
	mut out := []u8{cap: data.len}
	mut i := 0
	for i < data.len {
		b := data[i]
		if b == kiss_fesc && i + 1 < data.len && data[i + 1] == kiss_tfend {
			out << kiss_fend
			i += 2
		} else if b == kiss_fesc && i + 1 < data.len && data[i + 1] == kiss_tfesc {
			out << kiss_fesc
			i += 2
		} else {
			out << b
			i++
		}
	}
	return out
}

// encode_kiss_frame builds a full KISS frame: FEND + type byte + escaped data + FEND.
pub fn encode_kiss_frame(cmd u8, data []u8) []u8 {
	mut out := []u8{cap: data.len + 3}
	out << kiss_fend
	out << cmd
	out << kiss_escape(data)
	out << kiss_fend
	return out
}

// encode_kiss_hw builds a SetHardware (0x06) frame carrying a MeshCore
// sub-command and its data.
pub fn encode_kiss_hw(sub u8, data []u8) []u8 {
	mut payload := []u8{cap: data.len + 1}
	payload << sub
	payload << data
	return encode_kiss_frame(kiss_cmd_sethardware, payload)
}

// KissFrame is one decoded, unescaped KISS frame: its type byte and data.
pub struct KissFrame {
pub:
	cmd  u8
	data []u8
}

// KissFrameReader accumulates bytes and extracts complete KISS frames,
// delimited by FEND. Mirrors FrameReader's role for the companion protocol's
// length-prefixed framing.
pub struct KissFrameReader {
mut:
	buf []u8
}

pub fn (mut r KissFrameReader) feed(data []u8) {
	if data.len > 0 {
		r.buf << data
	}
}

// next returns the next complete frame, if one is fully buffered. Leading
// and repeated FENDs (common as inter-frame padding) are skipped; an empty
// frame between two FENDs is skipped too.
pub fn (mut r KissFrameReader) next() ?KissFrame {
	for {
		mut start := 0
		for start < r.buf.len && r.buf[start] == kiss_fend {
			start++
		}
		if start >= r.buf.len {
			r.buf.clear()
			return none
		}
		mut end := start
		for end < r.buf.len && r.buf[end] != kiss_fend {
			end++
		}
		if end >= r.buf.len {
			// no closing FEND yet; keep the partial frame buffered
			if start > 0 {
				r.buf = r.buf[start..].clone()
			}
			return none
		}
		raw := r.buf[start..end].clone()
		r.buf = r.buf[end..].clone()
		if raw.len == 0 {
			continue // empty frame between two FENDs; keep scanning
		}
		return KissFrame{
			cmd:  raw[0]
			data: kiss_unescape(raw[1..])
		}
	}
	return none
}
