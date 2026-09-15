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

fn test_encode_send_self_advert_zero_hop() {
	// zero-hop advert is a single command byte 0x07
	assert encode_send_self_advert(false) == [cmd_send_self_advert]
	assert encode_send_self_advert(false) == [u8(7)]
}

fn test_encode_send_self_advert_flood() {
	// flood advert appends 0x01
	assert encode_send_self_advert(true) == [cmd_send_self_advert, u8(1)]
	assert encode_send_self_advert(true) == [u8(7), u8(1)]
}

fn test_encode_get_contacts_all() {
	assert encode_get_contacts(0) == [cmd_get_contacts]
	assert encode_get_contacts(0) == [u8(4)]
}

fn test_encode_get_contacts_since() {
	p := encode_get_contacts(u32(0x40302010))
	assert p[0] == cmd_get_contacts
	assert p[1] == u8(0x10)
	assert p[2] == u8(0x20)
	assert p[3] == u8(0x30)
	assert p[4] == u8(0x40)
}

fn test_encode_set_advert_name() {
	p := encode_set_advert_name('MESHBBS')
	assert p[0] == cmd_set_advert_name // 8
	assert p[1..] == 'MESHBBS'.bytes()
}

fn test_encode_add_update_contact_layout() {
	pk := '4b81424f7106' + '00'.repeat(26) // 32-byte key (12 hex + padding)
	p := encode_add_update_contact(pk, u8(1), u8(0), 'XeroKuhl', u32(0x11223344), i32(0), i32(0))
	assert p[0] == cmd_add_update_contact // 9
	// public key: 32 bytes at offset 1; first 6 are the prefix
	assert p[1..7] == [u8(0x4b), 0x81, 0x42, 0x4f, 0x71, 0x06]
	assert p[33] == u8(1) // type
	assert p[34] == u8(0) // flags
	assert p[35] == u8(0) // out_path_len = 0 (flood)
	// adv_name is 32 bytes right after out_path_len (no path bytes)
	name_bytes := p[36..68]
	assert name_bytes[..8] == 'XeroKuhl'.bytes()
	// last_advert u32 LE at offset 68
	assert p[68] == u8(0x44)
	assert p[69] == u8(0x33)
	assert p[70] == u8(0x22)
	assert p[71] == u8(0x11)
	// total: 1 + 32 + 1 + 1 + 1 + 32 + 4 + 4 + 4 = 80 bytes
	assert p.len == 80
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

fn test_encode_send_channel_data_layout() {
	// data_type 0x1234 must be encoded LITTLE-endian: bytes 0x34, 0x12
	payload := [u8(0xDE), 0xAD, 0xBE, 0xEF]
	p := encode_send_channel_data(u8(2), u16(0x1234), payload)
	assert p[0] == cmd_send_channel_data // 0x3E
	assert p[1] == u8(2) // channel_idx
	assert p[2] == u8(0xFF) // path_len = flood
	// data_type little-endian
	assert p[3] == u8(0x34)
	assert p[4] == u8(0x12)
	// payload follows verbatim
	assert p[5..] == payload
	// total: 3 header + 2 data_type + 4 payload = 9
	assert p.len == 9
}

fn test_encode_send_channel_data_truncates() {
	long := []u8{len: 300, init: u8(0x41)}
	p := encode_send_channel_data(u8(0), u16(0), long)
	// header(3) + data_type(2) = 5 bytes, then payload capped at 163
	assert p[5..].len == 163
}

fn test_hex_to_bytes_roundtrip() {
	b := hex_to_bytes('4b81424f7106')
	assert b == [u8(0x4b), 0x81, 0x42, 0x4f, 0x71, 0x06]
	// odd/short input should not crash
	_ := hex_to_bytes('4b8')
	_ := hex_to_bytes('')
	assert true
}
