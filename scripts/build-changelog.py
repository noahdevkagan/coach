#!/usr/bin/env python3
"""Render CHANGELOG.md into docs/changelog.html for getmeetingcoach.com.

The page is a pure function of CHANGELOG.md so the two can never drift:
the push gate regenerates it and fails if the committed copy is stale.

    python3 scripts/build-changelog.py          # write docs/changelog.html
    python3 scripts/build-changelog.py --check  # exit 1 if the committed page is stale
"""
import html
import re
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
CHANGELOG = REPO / "CHANGELOG.md"
OUT = REPO / "docs" / "changelog.html"

HEADER_RE = re.compile(r"^##\s+(?P<version>\S+)(?:\s+—\s+(?P<date>\d{4}-\d{2}-\d{2}))?\s*$")


def inline(text: str) -> str:
    """Escape HTML, then apply the two markdown flavors the changelog uses."""
    text = html.escape(text, quote=False)
    text = re.sub(r"\*\*(.+?)\*\*", r"<strong>\1</strong>", text)
    text = re.sub(r"`([^`]+)`", r"<code>\1</code>", text)
    return text


def parse(md: str):
    releases = []  # (version, date, [bullets])
    current = None
    for line in md.splitlines():
        m = HEADER_RE.match(line)
        if m:
            current = (m.group("version"), m.group("date"), [])
            releases.append(current)
            continue
        if current is None or line.lstrip().startswith("<!--"):
            continue
        if line.startswith(("- ", "* ")):
            current[2].append(line[2:].strip())
        elif line.startswith("  ") and current[2]:  # continuation of a wrapped bullet
            current[2][-1] += " " + line.strip()
    return [r for r in releases if r[2]]  # drop empty sections (e.g. Unreleased)


def pretty_date(iso: str | None) -> str:
    if not iso:
        return ""
    months = ["January", "February", "March", "April", "May", "June", "July",
              "August", "September", "October", "November", "December"]
    y, m, d = iso.split("-")
    return f"{months[int(m) - 1]} {int(d)}, {y}"


def render(releases) -> str:
    sections = []
    for version, date, bullets in releases:
        items = "\n".join(f"      <li>{inline(b)}</li>" for b in bullets)
        date_html = f'\n      <span class="date">{pretty_date(date)}</span>' if date else ""
        sections.append(f"""  <section class="release">
    <h2>{html.escape(version)}{date_html}</h2>
    <ul>
{items}
    </ul>
  </section>""")
    body = "\n\n".join(sections)
    return f"""<!doctype html>
<!-- GENERATED from CHANGELOG.md by scripts/build-changelog.py — do not edit by hand. -->
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Changelog — MeetingCoach for Mac</title>
<meta name="description" content="What's new in MeetingCoach — every release, in plain language.">
<link rel="canonical" href="https://getmeetingcoach.com/changelog">
<link rel="icon" type="image/png" href="/icon.png">
<style>
  * {{ margin: 0; padding: 0; box-sizing: border-box; }}
  body {{
    font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Helvetica, Arial, sans-serif;
    background: #fff;
    color: #1a1a1a;
    line-height: 1.6;
    -webkit-font-smoothing: antialiased;
  }}
  main {{ max-width: 620px; margin: 0 auto; padding: 72px 24px 96px; }}
  .home {{ font-size: 14px; color: #888; text-decoration: none; }}
  .home:hover {{ color: #555; }}
  h1 {{ font-size: 40px; line-height: 1.15; letter-spacing: -0.02em; font-weight: 700; margin-top: 24px; }}
  .sub {{ font-size: 17px; color: #555; margin-top: 12px; }}
  .release {{ margin-top: 56px; }}
  .release h2 {{
    font-size: 20px;
    letter-spacing: -0.01em;
    padding-bottom: 10px;
    border-bottom: 1px solid #eee;
  }}
  .release .date {{ font-size: 13px; font-weight: 400; color: #999; margin-left: 10px; }}
  .release ul {{ list-style: none; margin-top: 16px; }}
  .release li {{
    color: #444;
    font-size: 15px;
    padding-left: 18px;
    position: relative;
    margin-bottom: 10px;
  }}
  .release li::before {{ content: "·"; position: absolute; left: 2px; color: #bbb; }}
  .release code {{
    font-family: ui-monospace, SFMono-Regular, Menlo, monospace;
    font-size: 13px;
    background: #f6f7f9;
    border: 1px solid #eee;
    border-radius: 4px;
    padding: 1px 5px;
  }}
  footer {{
    margin-top: 88px;
    padding-top: 24px;
    border-top: 1px solid #eee;
    font-size: 13px;
    color: #999;
  }}
  footer a {{ color: #999; }}
  @media (max-width: 480px) {{ h1 {{ font-size: 31px; }} }}
</style>
</head>
<body>
<main>
  <a class="home" href="/">&larr; MeetingCoach</a>
  <h1>Changelog</h1>
  <p class="sub">What's new in MeetingCoach — every release, in plain language. The app updates itself automatically.</p>

{body}

  <footer>
    <p>MeetingCoach · <a href="mailto:noahkagan@gmail.com">noahkagan@gmail.com</a> · <a href="https://github.com/noahdevkagan/meeting-coach-releases/releases">Releases on GitHub</a></p>
  </footer>
</main>
</body>
</html>
"""


def main():
    releases = parse(CHANGELOG.read_text())
    if not releases:
        sys.exit("no releases parsed from CHANGELOG.md")
    page = render(releases)
    if "--check" in sys.argv:
        if not OUT.exists() or OUT.read_text() != page:
            sys.exit("docs/changelog.html is stale — run: python3 scripts/build-changelog.py")
        print(f"changelog: docs/changelog.html is current ({len(releases)} releases)")
        return
    OUT.write_text(page)
    print(f"wrote {OUT.relative_to(REPO)} ({len(releases)} releases, latest {releases[0][0]})")


if __name__ == "__main__":
    main()
