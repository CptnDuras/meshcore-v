// purge_repeaters: one-off tool to drop every repeater-type contact from the
// radio's own contact book (CMD_REMOVE_CONTACT per entry; the firmware has no
// bulk wipe). Run only while the owning daemon (meshbbs) is stopped, since
// both can't hold the serial port at once.
//
// Usage: purge_repeaters <port> [--dry-run]
import os
import meshcore

fn main() {
	if os.args.len < 2 {
		eprintln('usage: purge_repeaters <port> [--dry-run]')
		exit(1)
	}
	port := os.args[1]
	dry_run := os.args.contains('--dry-run')

	mut mc := meshcore.create_serial(port, 115200, false) or {
		eprintln('could not open ${port}: ${err}')
		exit(1)
	}

	contacts := mc.get_contacts(0, 15000) or {
		eprintln('get_contacts failed: ${err}')
		exit(1)
	}
	println('${contacts.len} contact(s) in the radio contact book')

	mut repeaters := []meshcore.Payload{}
	for c in contacts {
		if c.contact_type == 2 { // REPEATER
			repeaters << c
		}
	}
	println('${repeaters.len} are repeater-type')

	mut removed := 0
	for c in repeaters {
		println('${if dry_run { "[dry-run] would remove" } else { "removing" }} ${c.public_key[..12]} (${c.adv_name})')
		if dry_run {
			continue
		}
		mc.remove_contact(c.public_key) or {
			eprintln('  failed: ${err}')
			continue
		}
		removed++
	}
	println('${if dry_run { 'would remove' } else { 'removed' }} ${if dry_run { repeaters.len } else { removed }} of ${repeaters.len} repeater contact(s)')
}
