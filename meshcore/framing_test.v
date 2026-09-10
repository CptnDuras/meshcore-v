module meshcore

fn test_encode_frame_header() {
	payload := [u8(0x01), 0x02, 0x03]
	f := encode_frame(payload)
	assert f[0] == u8(0x3C) // '<'
	assert f[1] == u8(3) // length low
	assert f[2] == u8(0) // length high
	assert f[3..] == payload
}

fn test_encode_frame_roundtrip() {
	payload := 'meshbbs'.bytes()
	f := encode_frame(payload)
	length := int(u16(f[1]) | (u16(f[2]) << 8))
	assert length == payload.len
	assert f[3..3 + length] == payload
}

fn test_reader_single_frame() {
	// outbound frame: '>' + len + payload
	payload := [u8(0x05), 0xAA, 0xBB]
	mut r := FrameReader{}
	r.feed([u8(0x3E), u8(3), u8(0)])
	r.feed(payload)
	got := r.next() or {
		assert false, 'expected a frame'
		return
	}
	assert got == payload
	// buffer drained -> no more
	assert r.next() == none
}

fn test_reader_partial_then_complete() {
	mut r := FrameReader{}
	r.feed([u8(0x3E), u8(4), u8(0), u8(0x0D)]) // header + 1 of 4 bytes
	assert r.next() == none // incomplete
	r.feed([u8(0x01), 0x02, 0x03]) // remaining 3 bytes
	got := r.next() or {
		assert false, 'expected a frame after completion'
		return
	}
	assert got == [u8(0x0D), 0x01, 0x02, 0x03]
}

fn test_reader_resync_past_garbage() {
	mut r := FrameReader{}
	// leading junk, then a valid frame
	r.feed([u8(0xFF), 0x00, 0x99])
	r.feed([u8(0x3E), u8(2), u8(0), u8(0x0A), u8(0x0B)])
	got := r.next() or {
		assert false, 'expected frame after resync'
		return
	}
	assert got == [u8(0x0A), u8(0x0B)]
}

fn test_reader_two_back_to_back() {
	mut r := FrameReader{}
	r.feed([u8(0x3E), u8(1), u8(0), u8(0x05)]) // frame 1: [0x05]
	r.feed([u8(0x3E), u8(1), u8(0), u8(0x0A)]) // frame 2: [0x0A]
	a := r.next() or {
		assert false, 'frame 1'
		return
	}
	b := r.next() or {
		assert false, 'frame 2'
		return
	}
	assert a == [u8(0x05)]
	assert b == [u8(0x0A)]
	assert r.next() == none
}

fn test_reader_split_across_feeds() {
	mut r := FrameReader{}
	r.feed([u8(0x3E)]) // just the marker
	assert r.next() == none
	r.feed([u8(2), u8(0)]) // length
	assert r.next() == none
	r.feed([u8(0x41)]) // 1 of 2 payload
	assert r.next() == none
	r.feed([u8(0x42)]) // last byte
	got := r.next() or {
		assert false, 'expected assembled frame'
		return
	}
	assert got == [u8(0x41), u8(0x42)]
}
