module main

import os
import time
import meshcore

// Echo example — uses ONLY the public meshcore library API.
// Mirrors meshcore_py's pubsub/echo examples: connect, subscribe to incoming
// DMs, echo them back, and auto-fetch queued messages.
fn main() {
	port := if os.args.len > 1 { os.args[1] } else { '/dev/cuaU0' }
	println('Connecting to ${port} ...')

	mut mc := meshcore.create_serial(port, 115200, false) or {
		eprintln('connect failed: ${err}')
		exit(1)
	}
	defer {
		mc.disconnect()
	}

	// The appstart during create_serial already fetched SELF_INFO; ask again
	// so we can print it via the public API.
	si := mc.send_appstart('meshbbs') or {
		eprintln('appstart failed: ${err}')
		exit(1)
	}
	println('Connected as ${si.payload.name} @ ${si.payload.radio_freq} MHz SF${si.payload.radio_sf}')
	println('pubkey ${si.payload.public_key[..12]}...\n')

	// Echo handler: reply to every incoming DM.
	handler := fn [mut mc] (ev meshcore.Event) {
		sender := ev.payload.pubkey_prefix
		text := ev.payload.text
		println('[DM] from ${sender}: ${text}')
		reply := 'you said: ${text}'
		mc.send_msg(sender, reply) or {
			eprintln('  reply failed: ${err}')
			return
		}
		println('  -> echoed back to ${sender}')
	}
	mc.subscribe(.contact_msg_recv, handler)

	// Auto-fetch queued + future messages.
	mc.start_auto_message_fetching()

	println('Echo bot running. DM this node from XeroKuhl. Ctrl-C to stop.\n')
	for {
		time.sleep(1 * time.second)
	}
}
