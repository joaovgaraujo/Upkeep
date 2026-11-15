# Upkeep 1.9.6

Logitech G HUB's updater service is no longer listed as safe to turn off.

## Why

The Startup & Services page marked "LGHUB Updater Service" as "Safe to turn off", so the "Turn off N safe-to-turn-off" button added in 1.9.5 would disable it. G HUB starts that service itself when it opens. On a PC where it was disabled, G HUB stopped working; setting it to Manual and reopening G HUB brought it back.

The service is now marked "Keep", and its note says to leave it on Manual: it doesn't start with Windows that way, and G HUB can still start it when it opens. Upkeep's own G HUB update step already starts the service for the update and then puts it back the way it was, so nothing changes there.

## Validation

- 86 Rust tests pass. A new check confirms that LGHUBUpdaterService gets "Keep" advice.
