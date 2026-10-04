#!/bin/bash
# Switch the X1E sound card between its Speaker and Headphones UCM profiles.
#
# Why a script: ACP exposes one profile per UCM device ("HiFi: Speaker: sink"
# / "HiFi: Headphones: sink"), GNOME's Sound panel has no profile selector,
# and jack detection does not work on this machine (the jack pins are CARD
# interface controls while UCM's JackControl lookup uses MIXER - see
# docs/audio-bringup.md).  So switching is manual.
#
# Usage:
#   ./audio-output.sh status
#   ./audio-output.sh speaker
#   ./audio-output.sh headphones
set -u

WANT="${1:-status}"
case "$WANT" in
status|speaker|headphones) ;;
*) echo "usage: $0 [status|speaker|headphones]" >&2; exit 1 ;;
esac

# the ALSA card is the first entry under wpctl's "Devices:" section
DEV="$(wpctl status | awk '/Devices:/{f=1;next} /Sinks:/{f=0} f' \
	| grep -oE '[0-9]+\.' | tr -d '.' | head -1)"
[ -n "$DEV" ] || { echo "no PipeWire ALSA device found" >&2; exit 1; }

python3 - "$DEV" "$WANT" <<'PY'
import json, subprocess, sys

dev, want = sys.argv[1], sys.argv[2]
raw = subprocess.run(["pw-dump", dev], capture_output=True, text=True).stdout
profiles = []
for d in (json.loads(raw) if raw.strip().startswith("[") else [json.loads(raw)]):
    profiles += d.get("info", {}).get("params", {}).get("EnumProfile", [])

if want == "status":
    print(f"card device {dev} profiles:")
    for p in profiles:
        print(f"  [{p.get('index')}] {p.get('name')}  ({p.get('description')})")
    sys.exit(0)

wantname = "Speaker" if want == "speaker" else "Headphones"
for p in profiles:
    name = (p.get("name") or "") + " " + (p.get("description") or "")
    if wantname in name:
        print(f"switching card {dev} to {p.get('name')} (profile {p.get('index')})")
        sys.exit(subprocess.run(["wpctl", "set-profile", dev, str(p.get("index"))]).returncode)
print(f"no profile mentioning '{wantname}' - run '$0 status'", file=sys.stderr)
print("(with ACP the two outputs are usually ports of one profile; pick them in the GNOME sound settings)",
      file=sys.stderr)
sys.exit(1)
PY
