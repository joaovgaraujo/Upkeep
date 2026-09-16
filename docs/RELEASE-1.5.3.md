# Upkeep 1.5.3

Fixes updates refusing to start with “A System Update run is already in
progress” after an interrupted run. The old directory-only guard could leave
a fresh abandoned lock blocking updates for three hours.

The guard now records the batch engine's process ID and creation time, checks
that process before refusing another run, and immediately recovers dead owners.
Legacy empty lock folders recover after checking for a running older engine.
Active runs never lose their lock merely because three hours have passed.
Ownership inspection and changes are serialized with a Windows named mutex.
Process-inspection and filesystem failures stop the run with a specific diagnostic.

If the engine stops before producing a summary, the GUI displays the guard's
diagnostic in the result and Summary views rather than asking you to run a
category again.

Install this version over 1.5.2 and retry the selected update categories. No
manual lock deletion is required. A genuinely active engine still blocks a
second run and the diagnostic identifies its process ID.

Validation: 10 lock tests passed, including real cmd.exe/Windows PowerShell
handoff, concurrent callers, forced termination and immediate retry, paths with
spaces/apostrophes, legacy locks, PID reuse and failed process inspection.
All 61 Rust tests passed. Tests did not install updates or restart Windows;
the reported second PC has not been tested directly.
