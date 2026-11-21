module meshcore

fn test_encode_kiss_frame_basic() {
	p := encode_kiss_frame(kiss_cmd_data, [u8(1), 2, 3])
	assert p == [u8(0xC0), 0x00, 1, 2, 3, 0xC0]
}

fn test_encode_kiss_frame_escapes_fend_and_fesc() {
	p := encode_kiss_frame(kiss_cmd_data, [u8(0xC0), 0xDB, 0x41])
	// FEND -> FESC TFEND, FESC -> FESC TFESC, then the plain byte
	assert p == [u8(0xC0), 0x00, 0xDB, 0xDC, 0xDB, 0xDD, 0x41, 0xC0]
}

fn test_encode_kiss_hw_layout() {
	p := encode_kiss_hw(kiss_hw_get_version, []u8{})
	assert p == [u8(0xC0), kiss_cmd_sethardware, kiss_hw_get_version, 0xC0]
}

fn test_kiss_frame_reader_single_frame() {
	mut r := KissFrameReader{}
	r.feed(encode_kiss_frame(kiss_cmd_data, [u8(1), 2, 3]))
	f := r.next() or { panic('expected a frame') }
	assert f.cmd == kiss_cmd_data
	assert f.data == [u8(1), 2, 3]
	assert r.next() == none
}

fn test_kiss_frame_reader_unescapes_data() {
	mut r := KissFrameReader{}
	r.feed(encode_kiss_hw(kiss_hw_get_version, [u8(0xC0), 0xDB]))
	f := r.next() or { panic('expected a frame') }
	assert f.cmd == kiss_cmd_sethardware
	assert f.data == [kiss_hw_get_version, 0xC0, 0xDB]
}

fn test_kiss_frame_reader_skips_padding_and_splits_frames() {
	mut r := KissFrameReader{}
	mut buf := []u8{}
	buf << u8(0xC0) // leading pad FEND (no-op)
	buf << encode_kiss_frame(kiss_cmd_data, [u8(1)])
	buf << encode_kiss_frame(kiss_cmd_txdelay, [u8(50)])
	r.feed(buf)
	f1 := r.next() or { panic('expected frame 1') }
	assert f1.cmd == kiss_cmd_data
	assert f1.data == [u8(1)]
	f2 := r.next() or { panic('expected frame 2') }
	assert f2.cmd == kiss_cmd_txdelay
	assert f2.data == [u8(50)]
	assert r.next() == none
}

fn test_kiss_frame_reader_partial_frame_waits_for_more() {
	mut r := KissFrameReader{}
	full := encode_kiss_frame(kiss_cmd_data, [u8(1), 2, 3])
	r.feed(full[..3]) // FEND + cmd + one data byte, no closing FEND yet
	assert r.next() == none
	r.feed(full[3..]) // the rest, including the closing FEND
	f := r.next() or { panic('expected a frame once complete') }
	assert f.cmd == kiss_cmd_data
	assert f.data == [u8(1), 2, 3]
}
