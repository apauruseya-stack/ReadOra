#!/usr/bin/env python3
"""Rewrite the roster block in CONTRIBUTORS.md from this repository's git history.

The roster is derived, never hand-written, and it lists exactly one person: the
maintainer. Run by the Contributors workflow; safe to run locally.

    python scripts/generate_contributors.py            # rewrite the file
    python scripts/generate_contributors.py --check    # exit 1 if out of date

Two things this has to get right:

* **Identity merging.** One person shows up under several names across years -
  a changed username, a work address, a personal one. Entries are merged on a
  normalised name so the maintainer's older handle and their current one do not
  appear as two different people.
* **Upstream versus here.** This is a fork, so most commits belong to the
  upstream project's authors. They are NOT contributors to ReadOra and are not
  listed as such: their authorship stays in the commit graph, which is never
  rewritten, and their credit stays in NOTICE.md. Listing them next to the
  maintainer read as though they worked on this fork.
"""

from __future__ import annotations

import argparse
import re
import subprocess
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
CONTRIBUTORS = REPO / "CONTRIBUTORS.md"
START = "<!-- ROSTER:START -->"
END = "<!-- ROSTER:END -->"

# The only identity the roster lists. Everything else in the fork's history is
# either upstream work or an alias of these two handles for the same person.
OWNER = "apauruseya-stack"
OWNER_URL = "https://github.com/apauruseya-stack"
OWNER_ALIASES = ("apauruseyastack", "apauruseya7866er")

EM_DASH = "\u2014"

# Built at import time from an escape rather than typed as a literal. A Windows
# checkout can be read through cp1252, where a literal em dash in this source
# decodes to a replacement character - which then propagates into the generated
# block and makes the workflow open a pull request on every run. An ASCII escape
# decodes identically under any encoding.
MAINTAINER_ROLE = f"**Maintainer {EM_DASH} ReadOra's author and sole owner**"


def shortlog() -> list[tuple[str, int]]:
    """Return [(display name, commit count)] for every commit on HEAD."""
    out = subprocess.run(
        ["git", "shortlog", "-sne", "HEAD"],
        cwd=REPO,
        check=True,
        capture_output=True,
        text=True,
    ).stdout

    rows: list[tuple[str, int]] = []
    for line in out.splitlines():
        if not line.strip():
            continue
        # Leading count is padded with spaces, and some locales insert NBSP.
        parts = re.split(r"[\s ]+", line.strip(), maxsplit=1)
        if len(parts) != 2:
            continue
        count, identity = parts
        if not count.isdigit():
            continue
        name = identity.rsplit("<", 1)[0].strip()
        if name:
            rows.append((name, int(count)))
    return rows


def normalise(name: str) -> str:
    """Collapse a display name to a merge key."""
    return re.sub(r"[^a-z0-9]", "", name.lower())


def owner_commits(rows: list[tuple[str, int]]) -> int:
    """The maintainer's total, summed across every handle they have committed as.

    Only the owner's rows count: an upstream author's commits are not
    contributions to this fork, however many of them the history carries.
    """
    return sum(count for name, count in rows if normalise(name) in OWNER_ALIASES)


def render(rows: list[tuple[str, int]]) -> str:
    lines = [
        "| Contributor | Commits | Role |",
        "|---|---:|---|",
        f"| {OWNER} | **{owner_commits(rows)}** | {MAINTAINER_ROLE} |",
        "",
        "The roster lists the maintainer only. Upstream authorship from the Zangetsu",
        "years is preserved in the commit graph, which is never rewritten, and credited",
        "in [`NOTICE.md`](NOTICE.md) - those authors do not work on ReadOra, so they are",
        "not listed here.",
    ]
    return "\n".join(lines)


def splice(document: str, block: str) -> str:
    """Replace everything between the roster markers, adding markers if absent."""
    if START in document and END in document:
        head, rest = document.split(START, 1)
        _, tail = rest.split(END, 1)
        return f"{head}{START}\n{block}\n{END}{tail}"

    print(
        "::warning::roster markers missing from CONTRIBUTORS.md - appending the block",
        file=sys.stderr,
    )
    return f"{document.rstrip()}\n\n{START}\n{block}\n{END}\n"


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--check",
        action="store_true",
        help="exit 1 if the file is out of date instead of writing it",
    )
    args = parser.parse_args()

    if not CONTRIBUTORS.exists():
        print(f"error: {CONTRIBUTORS} not found", file=sys.stderr)
        return 1

    block = render(shortlog())
    current = CONTRIBUTORS.read_text(encoding="utf-8")
    updated = splice(current, block)

    if args.check:
        if current != updated:
            print("CONTRIBUTORS.md is out of date.", file=sys.stderr)
            return 1
        print("CONTRIBUTORS.md is up to date.")
        return 0

    if current != updated:
        CONTRIBUTORS.write_text(updated, encoding="utf-8")
        print(f"Updated {CONTRIBUTORS.relative_to(REPO)}")
    else:
        print("Already up to date.")
    return 0


if __name__ == "__main__":
    sys.exit(main())