module meshcore

// local hex->bytes for fixtures (independent of library internals)
fn hx(s string) []u8 {
	mut out := []u8{}
	mut i := 0
	for i + 2 <= s.len {
		hi := hexnib(s[i])
		lo := hexnib(s[i + 1])
		out << u8((hi << 4) | lo)
		i += 2
	}
	return out
}

fn hexnib(c u8) u8 {
	if c >= `0` && c <= `9` {
		return c - `0`
	}
	if c >= `a` && c <= `f` {
		return c - `a` + 10
	}
	if c >= `A` && c <= `F` {
		return c - `A` + 10
	}
	return 0
}

// --- golden fixtures captured from a real Heltec V3 (fw v1.17.1) ---
const fx_self_info = '050116168026ba87b0186959e142fb7243cca485d11c39c1da4c09e4ae71ef863e5b7d4a000000000000000000000000bde40d0024f4000007053830323642413837'
const fx_contact_v3 = '103100004b81424f7106ff00ad48a26a4168616864676562616a73'

fn test_parse_self_info_golden() {
	ev := parse_frame(hx(fx_self_info))
	assert ev.typ == .self_info
	p := ev.payload
	assert p.tx_power == 22
	assert p.max_tx_pow == 22
	assert p.public_key == '8026ba87b0186959e142fb7243cca485d11c39c1da4c09e4ae71ef863e5b7d4a'
	assert p.radio_freq == 910.525
	assert p.radio_bw == 62.5
	assert p.radio_sf == 7
	assert p.radio_cr == 5
	assert p.name == '8026BA87'
}

fn test_parse_device_info_golden() {
	// build a DEVICE_INFO frame with known fields at spec offsets:
	// [0]=13 [1]=fw_ver [2]=maxc/2 [3]=maxch [4..8]=ble_pin
	// [8..20]=build "14-Aug-2026\0" [20..60]=model "Heltec V3\0..." [60..80]=ver
	mut b := []u8{len: 80, init: 0}
	b[0] = u8(13)
	b[1] = u8(13) // firmware_ver
	build := '14-Aug-2026'.bytes()
	for i, c in build {
		b[8 + i] = c
	}
	model := 'Heltec V3'.bytes()
	for i, c in model {
		b[20 + i] = c
	}
	ver := 'v1.17.1-d929643'.bytes()
	for i, c in ver {
		b[60 + i] = c
	}
	ev := parse_frame(b)
	assert ev.typ == .device_info
	assert ev.payload.firmware_ver == 13
	assert ev.payload.fw_build == '14-Aug-2026'
	assert ev.payload.model == 'Heltec V3'
	assert ev.payload.fw_version == 'v1.17.1-d929643'
}

fn test_parse_contact_msg_v3_golden() {
	ev := parse_frame(hx(fx_contact_v3))
	assert ev.typ == .contact_msg_recv
	assert ev.payload.pubkey_prefix == '4b81424f7106'
	assert ev.payload.text == 'Ahahdgebajs'
	// attribute exposed for wait_for_event filtering
	assert ev.attributes['pubkey_prefix'] == '4b81424f7106'
}

fn test_parse_contact_msg_nonv3() {
	// code 7: [7, prefix(6), path_len, txt_type, ts(4), text]
	mut b := [u8(7)]
	b << [u8(0xAA), 0xBB, 0xCC, 0xDD, 0xEE, 0xFF] // prefix
	b << u8(0xFF) // path_len
	b << u8(0) // txt_type
	b << [u8(0x10), 0x20, 0x30, 0x40] // ts LE
	b << 'hi'.bytes()
	ev := parse_frame(b)
	assert ev.typ == .contact_msg_recv
	assert ev.payload.pubkey_prefix == 'aabbccddeeff'
	assert ev.payload.text == 'hi'
}

fn test_parse_sent() {
	// [6, type, ack(4), timeout(4)]
	b := [u8(6), u8(0), u8(0x65), u8(0x78), u8(0x2c), u8(0xa1), u8(0x28), u8(0x08),
		u8(0), u8(0)]
	ev := parse_frame(b)
	assert ev.typ == .msg_sent
	assert ev.payload.expected_ack == '65782ca1'
}

fn test_parse_control_codes() {
	assert parse_frame([u8(0)]).typ == .ok
	assert parse_frame([u8(10)]).typ == .no_more_msgs
	assert parse_frame([u8(0x83)]).typ == .messages_waiting
	err_ev := parse_frame([u8(1), u8(6)])
	assert err_ev.typ == .error
	assert err_ev.payload.err_code == 6
}

fn test_parse_advert() {
	mut b := [u8(0x80)]
	for i in 0 .. 32 {
		b << u8(i)
	}
	ev := parse_frame(b)
	assert ev.typ == .advertisement
	assert ev.payload.public_key.len == 64 // 32 bytes hex
}

fn test_parse_unknown_and_empty() {
	u := parse_frame([u8(0x77), u8(0xAB)])
	assert u.typ == .raw
	assert u.payload.raw_hex == '77ab'
	e := parse_frame([]u8{})
	assert e.typ == .raw
}

fn test_parse_truncated_self_info_graceful() {
	// too short to be a real SELF_INFO -> raw, no crash
	ev := parse_frame([u8(5), u8(1), u8(2)])
	assert ev.typ == .raw
}
