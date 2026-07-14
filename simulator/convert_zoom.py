"""Convert a meeting transcript export to simulator format.

Handles two input formats (auto-detected):
  Zoom Docs (.md):   **Speaker Name** · HH:MM:SS\nText\n\n...
  VTT-style (.txt):  HH:MM:SS --> HH:MM:SS\nSpeaker Name: Text\n\n...

Output: [mm:ss] Speaker: text  (speaker matching you_name becomes "You")
"""
import re
import sys
from pathlib import Path

ZOOM_ENTRY = re.compile(r"^\*\*(.+?)\*\*\s*·\s*(\d{1,2}):(\d{2}):(\d{2})")
VTT_ENTRY = re.compile(r"^(\d{1,2}):(\d{2}):(\d{2})\s*-->\s*\d{1,2}:\d{2}:\d{2}\s*$")
VTT_TEXT = re.compile(r"^([^:]+?):\s*(.*)$")


def parse_zoom(lines: list[str]) -> list[tuple[int, str, str]]:
    entries = []
    i = 0
    while i < len(lines):
        m = ZOOM_ENTRY.match(lines[i])
        if m:
            speaker = m.group(1).strip()
            abs_secs = int(m.group(2)) * 3600 + int(m.group(3)) * 60 + int(m.group(4))
            # Collect text lines until next blank or next entry
            i += 1
            text_parts = []
            while i < len(lines) and not ZOOM_ENTRY.match(lines[i]) and lines[i].strip() != "---":
                if lines[i].strip():
                    text_parts.append(lines[i].strip())
                i += 1
            text = " ".join(text_parts)
            if text:
                entries.append((abs_secs, speaker, text))
        else:
            i += 1
    return entries


def parse_vtt(lines: list[str]) -> list[tuple[int, str, str]]:
    entries = []
    i = 0
    while i < len(lines):
        m = VTT_ENTRY.match(lines[i].strip())
        if m:
            abs_secs = int(m.group(1)) * 3600 + int(m.group(2)) * 60 + int(m.group(3))
            i += 1
            while i < len(lines) and not lines[i].strip():
                i += 1
            if i < len(lines):
                t = VTT_TEXT.match(lines[i].strip())
                if t:
                    entries.append((abs_secs, t.group(1).strip(), t.group(2).strip()))
                i += 1
        else:
            i += 1
    return entries


def convert(src: Path, dst: Path, you_name: str = "noah kagan"):
    lines = src.read_text().splitlines()
    entries = parse_zoom(lines) or parse_vtt(lines)

    if not entries:
        print("No entries parsed!", file=sys.stderr)
        sys.exit(1)

    start = entries[0][0]
    out = []
    for abs_secs, speaker, text in entries:
        rel = abs_secs - start
        mm, ss = divmod(rel, 60)
        label = "You" if speaker.lower() == you_name.lower() else speaker
        out.append(f"[{mm:02d}:{ss:02d}] {label}: {text}")

    dst.write_text("\n".join(out) + "\n")
    print(f"Converted {len(out)} utterances → {dst}")

if __name__ == "__main__":
    src = Path(sys.argv[1])
    dst = Path(sys.argv[2]) if len(sys.argv) > 2 else Path("samples/zoom_meeting.txt")
    convert(src, dst)
