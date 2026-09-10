module meshcore

import time

fn mk_event(typ EventType, prefix string) Event {
	mut attrs := map[string]string{}
	if prefix.len > 0 {
		attrs['pubkey_prefix'] = prefix
	}
	return Event{
		typ:        typ
		payload:    Payload{}
		attributes: attrs
	}
}

fn test_subscribe_and_dispatch() {
	mut d := &EventDispatcher{}
	d.start()
	defer { d.stop() }
	got := chan EventType{cap: 1}
	cb := fn [got] (ev Event) {
		got <- ev.typ
	}
	d.subscribe(.contact_msg_recv, cb)
	d.dispatch(mk_event(.contact_msg_recv, ''))
	select {
		t := <-got {
			assert t == EventType.contact_msg_recv
		}
		2 * time.second {
			assert false, 'callback was not invoked'
		}
	}
}

fn test_subscribe_type_filtering() {
	mut d := &EventDispatcher{}
	d.start()
	defer { d.stop() }
	got := chan int{cap: 4}
	cb := fn [got] (ev Event) {
		got <- 1
	}
	d.subscribe(.ok, cb)
	// dispatch a different type -> should NOT fire
	d.dispatch(mk_event(.error, ''))
	// dispatch matching type -> should fire
	d.dispatch(mk_event(.ok, ''))
	select {
		_ := <-got {
			assert true
		}
		2 * time.second {
			assert false, 'matching event did not fire'
		}
	}
	// ensure only one fired (the error one didn't)
	time.sleep(200 * time.millisecond)
	mut count := 1
	for {
		select {
			_ := <-got {
				count++
			}
			else {
				break
			}
		}
	}
	assert count == 1
}

fn test_attribute_filter() {
	mut d := &EventDispatcher{}
	d.start()
	defer { d.stop() }
	got := chan int{cap: 2}
	cb := fn [got] (ev Event) {
		got <- 1
	}
	mut filters := map[string]string{}
	filters['pubkey_prefix'] = 'abc123'
	d.subscribe_filtered(.contact_msg_recv, cb, filters)
	// non-matching attribute -> no fire
	d.dispatch(mk_event(.contact_msg_recv, 'deadbeef'))
	// matching -> fire
	d.dispatch(mk_event(.contact_msg_recv, 'abc123'))
	select {
		_ := <-got {
			assert true
		}
		2 * time.second {
			assert false, 'filtered event did not fire on match'
		}
	}
}

fn test_wait_for_event_success() {
	mut d := &EventDispatcher{}
	d.start()
	defer { d.stop() }
	spawn fn [mut d] () {
		time.sleep(150 * time.millisecond)
		d.dispatch(mk_event(.self_info, ''))
	}()
	ev := d.wait_for_event(.self_info, map[string]string{}, 3000) or {
		assert false, 'wait_for_event timed out unexpectedly'
		return
	}
	assert ev.typ == .self_info
}

fn test_wait_for_event_timeout() {
	mut d := &EventDispatcher{}
	d.start()
	defer { d.stop() }
	ev := d.wait_for_event(.device_info, map[string]string{}, 400)
	assert ev == none
}

fn test_unsubscribe_stops_delivery() {
	mut d := &EventDispatcher{}
	d.start()
	defer { d.stop() }
	got := chan int{cap: 2}
	cb := fn [got] (ev Event) {
		got <- 1
	}
	sub := d.subscribe(.ok, cb)
	d.unsubscribe(sub)
	d.dispatch(mk_event(.ok, ''))
	time.sleep(300 * time.millisecond)
	mut fired := false
	select {
		_ := <-got {
			fired = true
		}
		else {}
	}
	assert fired == false, 'callback fired after unsubscribe'
}
