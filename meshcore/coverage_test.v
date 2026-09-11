module meshcore

// Additional tests to close coverage gaps: channel messages (both variants),
// helper edge cases, and Event.is_error.

fn test_parse_channel_msg_nonv3() {
	// code 8: [8, channel_idx, path_len, txt_type, ts(4), text]
	mut b := [u8(8)]
	b << u8(2) // channel_idx
	b << u8(0xFF) // path_len
	b << u8(0) // txt_type
	b << [u8(0x01), 0x02, 0x03, 0x04] // ts LE
	b << 'hello'.bytes()
	ev := parse_frame(b)
	assert ev.typ == .channel_msg_recv
	assert ev.payload.channel_idx == 2
	assert ev.payload.text == 'hello'
}

fn test_parse_channel_msg_v3() {
	// code 17: [17, snr, rsv, rsv, channel_idx, path_len, txt_type, ts(4), text]
	mut b := [u8(17)]
	b << u8(40) // snr
	b << [u8(0), u8(0)] // reserved
	b << u8(1) // channel_idx
	b << u8(0xFF) // path_len
	b << u8(0) // txt_type
	b << [u8(0), 0, 0, 0] // ts
	b << 'chanv3'.bytes()
	ev := parse_frame(b)
	assert ev.typ == .channel_msg_recv
	assert ev.payload.channel_idx == 1
	assert ev.payload.text == 'chanv3'
}

fn test_null_str_hits_maxlen_without_terminator() {
	// a field with no NUL within maxlen should stop at maxlen
	b := 'ABCDEFGH'.bytes()
	// read 3 chars starting at offset 0
	s := null_str(b, 0, 3)
	assert s == 'ABC'
}

fn test_null_str_stops_at_null() {
	b := [u8(0x41), 0x42, 0x00, 0x43] // "AB\0C"
	s := null_str(b, 0, 4)
	assert s == 'AB'
}

fn test_le_u32_reads_little_endian() {
	b := [u8(0x10), 0x20, 0x30, 0x40]
	assert le_u32(b, 0) == u32(0x40302010)
}

fn test_hex_to_bytes_invalid_chars_stop() {
	// 'zz' is not hex -> hexval returns -1 -> loop breaks, empty result
	b := hex_to_bytes('zz')
	assert b.len == 0
	// valid prefix then invalid: stops at invalid
	b2 := hex_to_bytes('41zz')
	assert b2 == [u8(0x41)]
}

fn test_event_is_error() {
	e := Event{
		typ:     .error
		payload: Payload{}
	}
	assert e.is_error() == true
	ok := Event{
		typ:     .ok
		payload: Payload{}
	}
	assert ok.is_error() == false
}

fn test_put_u32_le_helper() {
	mut p := []u8{}
	put_u32_le(mut p, u32(0xAABBCCDD))
	assert p == [u8(0xDD), 0xCC, 0xBB, 0xAA]
}
