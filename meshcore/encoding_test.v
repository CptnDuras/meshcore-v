module meshcore

fn test_encode_app_start() {
	p := encode_app_start('meshbbs')
	assert p[0] == cmd_app_start // 1
	assert p[1] == u8(3) // app_ver
	// 6 reserved spaces
	for i in 2 .. 8 {
		assert p[i] == u8(0x20)
	}
	assert p[8..] == 'meshbbs'.bytes()
}

fn test_encode_device_query() {
	assert encode_device_query(3) == [u8(22), u8(3)]
}

fn test_encode_sync_next_message() {
	assert encode_sync_next_message() == [u8(10)]
}

fn test_encode_send_txt_msg_layout() {
	prefix := [u8(0x4b), 0x81, 0x42, 0x4f, 0x71, 0x06]
	p := encode_send_txt_msg(prefix, u32(0x40302010), 'hi')
	assert p[0] == cmd_send_txt_msg // 2
	assert p[1] == u8(0) // txt_type
	assert p[2] == u8(0) // attempt
	// ts little-endian
	assert p[3] == u8(0x10)
	assert p[4] == u8(0x20)
	assert p[5] == u8(0x30)
	assert p[6] == u8(0x40)
	// 6-byte prefix
	assert p[7..13] == prefix
	assert p[13..] == 'hi'.bytes()
}

fn test_encode_send_txt_msg_truncates() {
	prefix := [u8(1), 2, 3, 4, 5, 6]
	long := 'x'.repeat(200)
	p := encode_send_txt_msg(prefix, u32(0), long)
	// header(3) + ts(4) + prefix(6) = 13 bytes, then text capped at 160
	text_part := p[13..]
	assert text_part.len == 160
}

fn test_encode_send_channel_txt_msg_layout() {
	p := encode_send_channel_txt_msg(u8(0), u32(0x40302010), 'yo')
	assert p[0] == cmd_send_channel_txt_msg // 3
	assert p[1] == u8(0) // txt_type
	assert p[2] == u8(0) // channel_idx
	assert p[3] == u8(0x10)
	assert p[6] == u8(0x40)
	assert p[7..] == 'yo'.bytes()
}

fn test_encode_send_channel_txt_msg_truncates() {
	long := 'y'.repeat(200)
	p := encode_send_channel_txt_msg(u8(0), u32(0), long)
	// header(3) + ts(4) = 7 bytes, then text capped at 150
	assert p[7..].len == 150
}

fn test_hex_to_bytes_roundtrip() {
	b := hex_to_bytes('4b81424f7106')
	assert b == [u8(0x4b), 0x81, 0x42, 0x4f, 0x71, 0x06]
	// odd/short input should not crash
	_ := hex_to_bytes('4b8')
	_ := hex_to_bytes('')
	assert true
}
