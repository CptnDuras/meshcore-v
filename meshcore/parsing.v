module meshcore

// --- Command codes (app -> radio) ---
pub const cmd_app_start = u8(1)
pub const cmd_send_txt_msg = u8(2)
pub const cmd_send_channel_txt_msg = u8(3)
pub const cmd_get_contacts = u8(4)
pub const cmd_sync_next_message = u8(10)
pub const cmd_device_query = u8(22)

// --- Response codes (radio -> app) ---
pub const resp_ok = u8(0)
pub const resp_err = u8(1)
pub const resp_self_info = u8(5)
pub const resp_sent = u8(6)
pub const resp_contact_msg_recv = u8(7)
pub const resp_channel_msg_recv = u8(8)
pub const resp_no_more_messages = u8(10)
pub const resp_device_info = u8(13)
pub const resp_contact_msg_recv_v3 = u8(16)
pub const resp_channel_msg_recv_v3 = u8(17)

// --- Push codes (radio -> app, unsolicited) ---
pub const push_advert = u8(0x80)
pub const push_path_updated = u8(0x81)
pub const push_send_confirmed = u8(0x82)
pub const push_msg_waiting = u8(0x83)

// --- little-endian + string helpers ---
fn le_u32(b []u8, off int) u32 {
	return u32(b[off]) | (u32(b[off + 1]) << 8) | (u32(b[off + 2]) << 16) | (u32(b[off + 3]) << 24)
}

fn null_str(b []u8, off int, maxlen int) string {
	mut s := []u8{}
	mut i := off
	for i < off + maxlen && i < b.len && b[i] != 0 {
		s << b[i]
		i++
	}
	return s.bytestr()
}

// parse_frame turns a raw frame payload into a typed Event.
// Mirrors meshcore_py parsing.py: dispatch on the leading code byte.
pub fn parse_frame(b []u8) Event {
	if b.len == 0 {
		return Event{
			typ:     .raw
			payload: Payload{}
		}
	}
	code := b[0]
	match code {
		resp_ok {
			return Event{
				typ:     .ok
				payload: Payload{
					code: code
				}
			}
		}
		resp_err {
			ec := if b.len > 1 { b[1] } else { u8(0) }
			return Event{
				typ:     .error
				payload: Payload{
					code:     code
					err_code: ec
					reason:   'err_code ${ec}'
				}
			}
		}
		resp_self_info {
			return parse_self_info(b)
		}
		resp_device_info {
			return parse_device_info(b)
		}
		resp_sent {
			return parse_sent(b)
		}
		resp_contact_msg_recv {
			return parse_contact_msg(b, false)
		}
		resp_contact_msg_recv_v3 {
			return parse_contact_msg(b, true)
		}
		resp_channel_msg_recv {
			return parse_channel_msg(b, false)
		}
		resp_channel_msg_recv_v3 {
			return parse_channel_msg(b, true)
		}
		resp_no_more_messages {
			return Event{
				typ:     .no_more_msgs
				payload: Payload{
					code: code
				}
			}
		}
		push_msg_waiting {
			return Event{
				typ:     .messages_waiting
				payload: Payload{
					code: code
				}
			}
		}
		push_advert {
			mut key := []u8{}
			for i in 1 .. b.len {
				if i < 33 {
					key << b[i]
				}
			}
			return Event{
				typ:     .advertisement
				payload: Payload{
					code:       code
					public_key: key.hex()
				}
			}
		}
		push_send_confirmed {
			return Event{
				typ:     .ack
				payload: Payload{
					code: code
				}
			}
		}
		else {
			return Event{
				typ:     .raw
				payload: Payload{
					code:    code
					raw_hex: b.hex()
				}
			}
		}
	}
}

fn parse_self_info(b []u8) Event {
	if b.len < 58 {
		return Event{
			typ:     .raw
			payload: Payload{
				code:    b[0]
				raw_hex: b.hex()
			}
		}
	}
	mut key := []u8{}
	for i in 4 .. 36 {
		key << b[i]
	}
	return Event{
		typ:     .self_info
		payload: Payload{
			code:       b[0]
			adv_type:   b[1]
			tx_power:   b[2]
			max_tx_pow: b[3]
			public_key: key.hex()
			radio_freq: f64(le_u32(b, 48)) / 1000.0
			radio_bw:   f64(le_u32(b, 52)) / 1000.0
			radio_sf:   b[56]
			radio_cr:   b[57]
			name:       null_str(b, 58, b.len - 58)
		}
	}
}

fn parse_device_info(b []u8) Event {
	if b.len < 8 {
		return Event{
			typ:     .raw
			payload: Payload{
				code:    b[0]
				raw_hex: b.hex()
			}
		}
	}
	return Event{
		typ:     .device_info
		payload: Payload{
			code:         b[0]
			firmware_ver: b[1]
			fw_build:     null_str(b, 8, 12)
			model:        null_str(b, 20, 40)
			fw_version:   null_str(b, 60, 20)
		}
	}
}

fn parse_sent(b []u8) Event {
	mut ack := []u8{}
	if b.len >= 6 {
		for i in 2 .. 6 {
			ack << b[i]
		}
	}
	timeout := if b.len >= 10 { le_u32(b, 6) } else { u32(0) }
	return Event{
		typ:     .msg_sent
		payload: Payload{
			code:              b[0]
			expected_ack:      ack.hex()
			suggested_timeout: timeout
		}
	}
}

// CONTACT_MSG_RECV (7):    prefix(6) path_len(1) txt_type(1) ts(4) text...
// CONTACT_MSG_RECV_V3 (16): snr(1) rsv(2) prefix(6) path_len(1) txt_type(1) ts(4) text...
fn parse_contact_msg(b []u8, v3 bool) Event {
	off := if v3 { 4 } else { 1 } // skip code (+ snr+2 reserved for v3)
	mut p := Payload{
		code: b[0]
	}
	mut i := off
	mut pref := []u8{}
	for _ in 0 .. 6 {
		if i < b.len {
			pref << b[i]
			i++
		}
	}
	p.pubkey_prefix = pref.hex()
	if i < b.len {
		p.path_len = b[i]
		i++
	}
	if i < b.len {
		p.txt_type = b[i]
		i++
	}
	if i + 4 <= b.len {
		p.sender_ts = le_u32(b, i)
		i += 4
	}
	if i < b.len {
		p.text = b[i..].bytestr()
	}
	// expose pubkey_prefix as an attribute for wait_for_event filtering
	mut attrs := map[string]string{}
	attrs['pubkey_prefix'] = p.pubkey_prefix
	return Event{
		typ:        .contact_msg_recv
		payload:    p
		attributes: attrs
	}
}

// CHANNEL_MSG_RECV (8):    channel(1) path_len(1) txt_type(1) ts(4) text...
// CHANNEL_MSG_RECV_V3 (17): snr(1) rsv(2) channel(1) path_len(1) txt_type(1) ts(4) text
fn parse_channel_msg(b []u8, v3 bool) Event {
	off := if v3 { 4 } else { 1 }
	mut p := Payload{
		code: b[0]
	}
	mut i := off
	if i < b.len {
		p.channel_idx = b[i]
		i++
	}
	if i < b.len {
		p.path_len = b[i]
		i++
	}
	if i < b.len {
		p.txt_type = b[i]
		i++
	}
	if i + 4 <= b.len {
		p.sender_ts = le_u32(b, i)
		i += 4
	}
	if i < b.len {
		p.text = b[i..].bytestr()
	}
	return Event{
		typ:     .channel_msg_recv
		payload: p
	}
}
