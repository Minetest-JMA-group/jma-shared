# filter mod

This mod adds a chat filter for catching unwanted messages using regex.

The filter contains whitelist and blacklist. If a message is matched by a 
regex in whitelist, blacklist isn't checked. Otherwise, it's blocked if
it's matched by a regex in blacklist.

The `/filter` chat command is used for all runtime configuration of the
filter. Check `/filter help` for details. To use this chat command,
the player needs `filtering` privilege.

If a player speaks a word that is listed in the filter list, they are
muted for 1 minute. After that, their `shout` privilege is restored.
If they leave, their `shout` privilege is still restored, but only after
the time expires, not before.

The filter can be put in "Permissive" mode, where violations are logged,
but no action is triggered for them, or "Enforcing" mode where violations
are punished by policy.

## API

### Callbacks

* filter.register_on_violation(func(name, message, violations))
	* Violations is the value of the player's violation counter - which is
	  incremented on a violation, and halved every 10 minutes.
	* Return true if you've handled the violation. No more callbacks will be
	  executation, and the default behaviour (warning/mute/kick) on violation
	  will be skipped.

### Methods
* filter.check_message(name, message)
	* Checks message for violation. Returns true if okay, false if bad.
	  If it returns false, you should cancel the sending of the message and
	  call filter.on_violation()
* filter.on_violation(name, message)
	* Increments violation count, runs callbacks, and punishes the players.
* filter.mute(name, duration)
* filter.show_warning_formspec(name)
* filter.is_blacklisted(message)
	* Checks if the message matches any regex in blacklist, or is longer than max_len
* filter.is_whitelisted(message)
	* Checks if the message matches any regex in whitelist
* filter.export_regex(listname)
	* listname can be "whitelist" or "blacklist". Exports the list to a file in mod directory.
* filter.get_mode()
	* Return 1 or 0 (1 - Enforcing; 0 - Permissive)
* filter.get_lastreg()
  	* Return last blacklist regex pattern that was matched, or "" if none was matched since server startup.
