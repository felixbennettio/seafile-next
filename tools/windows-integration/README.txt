Seafile Next Windows integration

Extract the complete application ZIP to a permanent folder. Run
Install-WindowsIntegration.cmd to enable Explorer's Seafile context menu,
sync/lock status overlays and seafile:// local-file links. Windows requests
administrator access for these system registrations. The client itself can
still run without registration. The source GUIDs and named-pipe protocol are
retained from the original Seafile extension.

Keep this folder in place while registered. Run Uninstall-WindowsIntegration.cmd
before moving/removing it. Unregistration preserves a later installation that
has taken ownership of the same COM identifier. It does not delete accounts,
settings, synced libraries or local files. Explorer may need a new login session
to reload the DLL; these scripts do not stop Explorer or the sync engine.
