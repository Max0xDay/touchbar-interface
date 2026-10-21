# Touch Bar branding
Original bar-with-buttons artwork: `StatusImage.png` is an 88 × 32 transparent black template; `AppIcon.icns` is the matching colour app icon.
From the repository root, run `logoDirectory="$(mktemp -d /tmp/touchbar-branding.XXXXXX)"; swift mtmr/branding/make-logo.swift "$logoDirectory"`.
The output includes both assets, a 1024 px `AppIcon.png` master, and `AppIcon.iconset` (16–512 px at 1x/2x), compiled with `iconutil`.
Back up existing assets, then run `cp "$logoDirectory/StatusImage.png" "$logoDirectory/AppIcon.icns" mtmr/branding/`; restore the backup to roll back.
No network, upstream edits, app build, or restart is needed to regenerate.
