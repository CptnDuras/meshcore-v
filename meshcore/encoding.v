module meshcore

// Pure command-payload encoders. These build the frame PAYLOAD bytes (the part
// after the '<' + length header, which encode_frame adds). Kept pure and
// connection-free so they are unit-testable without a serial port. The MeshCore
// command methods call these, then write via the connection.

// append little-endian u32
fn put_u32_le(mut p []u8, v u32) {
	p << u8(v & 0xFF)
	p << u8((v >> 8) & 0xFF)
	p << u8((v >> 16) & 0xFF)
	p << u8((v >> 24) & 0xFF)
}

// append little-endian signed i32 (two's complement)
fn put_i32_le(mut p []u8, v i32) {
	u := u32(v)
	put_u32_le(mut p, u)
}

// CMD_APP_START: [1, app_ver=3, 6 reserved (0x20), app_name...]
pub fn encode_app_start(app_name string) []u8 {
	mut p := []u8{}
	p << cmd_app_start
	p << u8(3)
	for _ in 0 .. 6 {
		p << u8(0x20)
	}
	p << app_name.bytes()
	return p
}

// CMD_GET_CONTACTS: [4] for all, or [4, lastmod(u32 LE)] to sync only entries
// modified since `lastmod`. Responds with CONTACT_START, then N CONTACT frames,
// then CONTACT_END.
pub fn encode_get_contacts(since u32) []u8 {
	mut p := []u8{}
	p << cmd_get_contacts
	if since > 0 {
		put_u32_le(mut p, since)
	}
	return p
}

// CMD_ADD_UPDATE_CONTACT (9): adds or updates a contact in the radio's contact
// book — used to auto-accept a node that advertised (NEW_CONTACT). Layout:
//   0x09 public_key(32) type(1) flags(1) out_path_len(1) out_path(var)
//        adv_name(32, NUL-padded) last_advert(u32 LE) adv_lat(i32) adv_lon(i32)
// We add as flood (out_path_len = 0, no path) which is the safe default for a
// freshly-heard node; the radio refines the path as it learns routes.
pub fn encode_add_update_contact(public_key_hex string, ctype u8, flags u8, adv_name string, last_advert u32, adv_lat i32, adv_lon i32) []u8 {
	mut p := []u8{}
	p << cmd_add_update_contact
	// public key: exactly 32 bytes (pad/truncate)
	mut pk := hex_to_bytes(public_key_hex)
	for pk.len < 32 {
		pk << u8(0)
	}
	p << pk[..32]
	p << ctype
	p << flags
	p << u8(0) // out_path_len = 0 (flood; no path bytes follow)
	// adv_name: 32 bytes, NUL-padded
	mut nm := adv_name.bytes()
	if nm.len > 32 {
		nm = nm[..32]
	}
	p << nm
	for _ in nm.len .. 32 {
		p << u8(0)
	}
	put_u32_le(mut p, last_advert)
	put_i32_le(mut p, adv_lat)
	put_i32_le(mut p, adv_lon)
	return p
}

// CMD_SEND_SELF_ADVERT: [7] for zero-hop, [7, 1] for flood.
// Matches the reference meshcore python client (device.send_advert): the
// firmware broadcasts this node's advert so other nodes discover it.
pub fn encode_send_self_advert(flood bool) []u8 {
	if flood {
		return [cmd_send_self_advert, u8(1)]
	}
	return [cmd_send_self_advert]
}

// CMD_SET_ADVERT_NAME: [8, name(UTF-8)] — sets this node's advertised device
// name (the friendly name other nodes see). Mirrors device.set_name().
pub fn encode_set_advert_name(name string) []u8 {
	mut p := []u8{}
	p << cmd_set_advert_name
	p << name.bytes()
	return p
}

// CMD_DEVICE_QUERY: [22, app_target_ver]
pub fn encode_device_query(app_target_ver u8) []u8 {
	return [cmd_device_query, app_target_ver]
}

// CMD_SYNC_NEXT_MESSAGE: [10]
pub fn encode_sync_next_message() []u8 {
	return [cmd_sync_next_message]
}

// CMD_SEND_TXT_MSG: [2, txt_type=0, attempt, ts(u32 LE), pubkey_prefix(6), text(<=160)]
pub fn encode_send_txt_msg(prefix []u8, ts u32, text string) []u8 {
	mut p := []u8{}
	p << cmd_send_txt_msg
	p << u8(0) // txt_type plain
	p << u8(0) // attempt
	put_u32_le(mut p, ts)
	for i in 0 .. 6 {
		if i < prefix.len {
			p << prefix[i]
		} else {
			p << u8(0)
		}
	}
	mut t := text
	if t.len > 160 {
		t = t[..160]
	}
	p << t.bytes()
	return p
}

// CMD_SEND_CHANNEL_TXT_MSG: [3, txt_type=0, channel_idx, ts(u32 LE), text(<=150)]
pub fn encode_send_channel_txt_msg(channel_idx u8, ts u32, text string) []u8 {
	mut p := []u8{}
	p << cmd_send_channel_txt_msg
	p << u8(0)
	p << channel_idx
	put_u32_le(mut p, ts)
	mut t := text
	if t.len > 150 {
		t = t[..150]
	}
	p << t.bytes()
	return p
}
