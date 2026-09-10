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
