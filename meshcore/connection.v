module meshcore

import term.termios
import time

// --- C serial primitives ---
fn C.open(path &char, flags int, ...int) int
fn C.close(fd int) int
fn C.read(fd int, buf voidptr, count usize) int
fn C.write(fd int, buf voidptr, count usize) int

// Frame markers (MeshCore companion USB framing).
const fend_out = u8(0x3E) // '>' radio -> app
const fend_in = u8(0x3C) //  '<' app  -> radio

// SerialConnection mirrors serial_cx.py: owns the fd and does raw I/O.
// Critically opens WITHOUT dropping DTR on close (clears HUPCL) so the
// ESP32 is not reset.
pub struct SerialConnection {
pub:
	port string
	baud int = 115200
pub mut:
	fd int = -1
}

pub fn (mut c SerialConnection) open() ! {
	o_rdwr := 0x0002
	o_noctty := 0x8000
	o_nonblock := 0x0004
	fd := C.open(&char(c.port.str), o_rdwr | o_noctty | o_nonblock)
	if fd < 0 {
		return error('could not open ${c.port} (fd=${fd})')
	}
	mut t := termios.Termios{}
	if termios.tcgetattr(fd, mut t) != 0 {
		C.close(fd)
		return error('tcgetattr failed on ${c.port}')
	}
	t.c_iflag = termios.flag(int(t.c_iflag) & ~(C.IGNBRK | C.BRKINT | C.PARMRK | C.ISTRIP | C.INLCR | C.IGNCR | C.ICRNL | C.IXON))
	t.c_oflag = termios.flag(int(t.c_oflag) & ~(C.OPOST))
	t.c_lflag = termios.flag(int(t.c_lflag) & ~(C.ECHO | C.ECHONL | C.ICANON | C.ISIG | C.IEXTEN))
	t.c_cflag = termios.flag(int(t.c_cflag) & ~(C.CSIZE | C.PARENB | C.CSTOPB | C.HUPCL))
	t.c_cflag = termios.flag(int(t.c_cflag) | C.CS8 | C.CREAD | C.CLOCAL)
	t.c_cc[C.VMIN] = 0
	t.c_cc[C.VTIME] = 0
	t.c_ispeed = c.baud
	t.c_ospeed = c.baud
	if termios.tcsetattr(fd, C.TCSANOW, mut t) != 0 {
		C.close(fd)
		return error('tcsetattr failed on ${c.port}')
	}
	c.fd = fd
	time.sleep(200 * time.millisecond)
}

// encode_frame wraps a payload in the inbound framing ('<' + uint16 LE length
// + payload). Pure function — testable without a serial port.
pub fn encode_frame(payload []u8) []u8 {
	mut out := []u8{cap: payload.len + 3}
	out << fend_in
	out << u8(payload.len & 0xFF)
	out << u8((payload.len >> 8) & 0xFF)
	out << payload
	return out
}

pub fn (mut c SerialConnection) write_frame(payload []u8) ! {
	out := encode_frame(payload)
	if out.len == 0 {
		return
	}
	n := C.write(c.fd, out.data, usize(out.len))
	if n != out.len {
		return error('short serial write ${n}/${out.len}')
	}
}

pub fn (mut c SerialConnection) read_some(max int) []u8 {
	mut buf := []u8{len: max}
	n := C.read(c.fd, buf.data, usize(max))
	if n <= 0 {
		return []u8{}
	}
	// Trim in place rather than clone - buf is local so this is safe
	buf.trim(n)
	return buf
}

pub fn (mut c SerialConnection) close() {
	if c.fd >= 0 {
		C.close(c.fd)
		c.fd = -1
	}
}

// FrameReader accumulates bytes and extracts complete outbound ('>') frames.
// Mirrors reader.py's framing responsibility.
//
// Memory optimization: uses a read index to avoid repeated clone() calls on
// every frame. The buffer is only compacted when the consumed portion exceeds
// a threshold, reducing allocations from O(frames) to O(1) amortized.
pub struct FrameReader {
mut:
	buf []u8
	pos int // read position into buf
}

// compact shifts unconsumed data to front when we've consumed enough.
// Threshold of 4KB balances memory use vs allocation frequency.
fn (mut r FrameReader) compact() {
	if r.pos > 4096 {
		if r.pos < r.buf.len {
			remaining := r.buf.len - r.pos
			for i := 0; i < remaining; i++ {
				r.buf[i] = r.buf[r.pos + i]
			}
			r.buf.trim(remaining)
		} else {
			r.buf.clear()
		}
		r.pos = 0
	}
}

pub fn (mut r FrameReader) feed(data []u8) {
	if data.len > 0 {
		r.buf << data
	}
}

pub fn (mut r FrameReader) next() ?[]u8 {
	avail := r.buf.len - r.pos
	if avail < 3 {
		r.compact()
		return none
	}
	// Scan for frame start marker
	if r.buf[r.pos] != fend_out {
		mut i := r.pos
		for i < r.buf.len && r.buf[i] != fend_out {
			i++
		}
		r.pos = i
		if r.buf.len - r.pos < 3 {
			r.compact()
			return none
		}
	}
	length := int(u16(r.buf[r.pos + 1]) | (u16(r.buf[r.pos + 2]) << 8))
	total := 3 + length
	if r.buf.len - r.pos < total {
		return none
	}
	// Extract payload - single clone for the returned data only
	payload := r.buf[r.pos + 3 .. r.pos + total].clone()
	r.pos += total
	r.compact()
	return payload
}
