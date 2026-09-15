module meshcore

import sync
import time

// EventType mirrors meshcore_py's EventType enum (events.py).
// Only the subset needed now is fully wired; the rest are declared so the
// API surface matches and can grow.
pub enum EventType {
	// device & status
	self_info
	device_info
	battery
	current_time
	// contacts
	contacts
	new_contact
	contact_start
	contact
	contact_end
	// messaging
	contact_msg_recv
	channel_msg_recv
	channel_data_recv
	no_more_msgs
	msg_sent
	messages_waiting
	// network / push
	advertisement
	path_update
	ack
	// command responses
	ok
	error
	// connection
	connected
	disconnected
	// catch-all for frames we haven't typed yet
	raw
}

// Payload carries the decoded fields of an event. V lacks Python's dynamic
// dicts, so we use a struct with the union of fields we parse; unused fields
// stay zero. Mirrors the "payload dict" concept pragmatically.
pub struct Payload {
pub mut:
	// self_info / device_info
	name         string
	public_key   string
	adv_type     u8
	tx_power     u8
	max_tx_pow   u8
	radio_freq   f64
	radio_bw     f64
	radio_sf     u8
	radio_cr     u8
	model        string
	fw_version   string
	fw_build     string
	firmware_ver u8
	// messages
	pubkey_prefix string
	channel_idx   u8
	path_len      u8
	txt_type      u8
	sender_ts     u32
	text          string
	// binary channel datagrams (CHANNEL_DATA_RECV): raw payload + its type
	data      []u8
	data_type u16
	// contacts (from CMD_GET_CONTACTS -> CONTACT frames)
	adv_name      string // node friendly name
	contact_type  u8
	last_advert   u32
	contact_count u32 // from CONTACT_START
	// signal quality (from V3 message frames): SNR in dB (0 if unknown)
	snr f64
	// msg_sent
	expected_ack      string
	suggested_timeout u32
	// error
	err_code u8
	reason   string
	// raw fallback
	code    u8
	raw_hex string
}

// Event mirrors events.py Event: type + payload + attributes (for filtering).
pub struct Event {
pub:
	typ     EventType
	payload Payload
pub mut:
	// attributes used for wait_for_event filtering (e.g. pubkey_prefix)
	attributes map[string]string
}

pub fn (e Event) is_error() bool {
	return e.typ == .error
}

// Subscription is a handle returned by subscribe().
pub struct Subscription {
pub:
	id         int
	event_type EventType
	// match_all: if true, fire for any event type
	match_all bool
	filters   map[string]string
mut:
	cb fn (Event) = unsafe { nil }
}

// EventDispatcher mirrors events.py EventDispatcher: a background thread reads
// a channel of Events and fans them out to matching subscriptions.
// V equivalent of the asyncio queue + task.
pub struct EventDispatcher {
mut:
	mu      &sync.Mutex = sync.new_mutex()
	subs    []Subscription
	next_id int
	queue   chan Event = chan Event{ cap: 128 }
	running bool
}

// start launches the background processing thread.
pub fn (mut d EventDispatcher) start() {
	if d.running {
		return
	}
	d.running = true
	spawn d.process()
}

fn (mut d EventDispatcher) process() {
	for d.running {
		ev := <-d.queue or { break }
		// snapshot subscriptions under lock, then call outside lock
		d.mu.lock()
		subs := d.subs.clone()
		d.mu.unlock()
		for s in subs {
			if !s.match_all && s.event_type != ev.typ {
				continue
			}
			if s.filters.len > 0 {
				mut ok := true
				for k, v in s.filters {
					if ev.attributes[k] or { '' } != v {
						ok = false
						break
					}
				}
				if !ok {
					continue
				}
			}
			// Run each callback in its own thread. This mirrors the async
			// behavior of meshcore_py and is REQUIRED: a handler may issue a
			// command and block on wait_for_event; if we called it inline on
			// this single dispatch thread, the response event could never be
			// delivered (reentrancy deadlock).
			cb := s.cb
			spawn cb(ev)
		}
	}
}

// dispatch enqueues an event for delivery.
pub fn (mut d EventDispatcher) dispatch(ev Event) {
	if d.running {
		d.queue <- ev
	}
}

// subscribe registers a callback for an event type (mirrors events.py).
pub fn (mut d EventDispatcher) subscribe(event_type EventType, cb fn (Event)) Subscription {
	return d.subscribe_filtered(event_type, cb, map[string]string{})
}

pub fn (mut d EventDispatcher) subscribe_filtered(event_type EventType, cb fn (Event), filters map[string]string) Subscription {
	d.mu.lock()
	defer { d.mu.unlock() }
	d.next_id++
	s := Subscription{
		id: d.next_id
		event_type: event_type
		match_all: false
		filters: filters.clone()
		cb: cb
	}
	d.subs << s
	return s
}

pub fn (mut d EventDispatcher) unsubscribe(sub Subscription) {
	d.mu.lock()
	defer { d.mu.unlock() }
	for i, s in d.subs {
		if s.id == sub.id {
			d.subs.delete(i)
			return
		}
	}
}

pub fn (mut d EventDispatcher) stop() {
	d.running = false
}

// wait_for_event blocks until a matching event arrives or timeout elapses.
// Mirrors events.py wait_for_event using a one-shot channel.
pub fn (mut d EventDispatcher) wait_for_event(event_type EventType, filters map[string]string, timeout_ms int) ?Event {
	result := chan Event{ cap: 1 }
	// a subscription that pushes the first match into the channel
	cb := fn [result] (ev Event) {
		// non-blocking send; ignore if already delivered
		select {
			result <- ev {
			}
			else {
			}
		}
	}
	sub := d.subscribe_filtered(event_type, cb, filters)
	defer { d.unsubscribe(sub) }

	deadline := time.now().add(timeout_ms * time.millisecond)
	for time.now() < deadline {
		select {
			ev := <-result {
				return ev
			}
			500 * time.millisecond {
				// loop and re-check deadline
			}
		}
	}
	return none
}
