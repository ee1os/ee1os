#!/usr/bin/env python3
"""Keep GitHub's download counts of the release files (github.com/ee1os/releases).

GitHub counts downloads per uploaded file and forgets the count when the file is replaced,
which every release does to the channel files and removes the old OTA zips. This appends the
counts to a TSV, one row per file whose count changed since the last run:

    time  release tag  asset id  file name  downloads

Run by track-upstream.sh every night and by publish-release.sh before it replaces anything.
The counts are all there is: no phone or person is identified, and a download is not an
install. Our own checks of a release are in them too.

  download-counts.py            append what changed
  download-counts.py --show     the latest count of every file, newest release first
"""
import json
import os
import subprocess
import sys
import time

REPO = "ee1os/releases"
# flash/home, not scratch: snapshotted and backed up
OUT = os.environ.get("COUNTS_FILE", "/mnt/flash/home/faeton/work/ee1os/state-backup/downloads.tsv")


def last():
    """asset id -> its latest row."""
    rows = {}
    try:
        with open(OUT) as f:
            for line in f:
                r = line.rstrip("\n").split("\t")
                if len(r) == 5:
                    rows[r[2]] = r
    except OSError:
        pass
    return rows


def fetch():
    out = subprocess.run(
        ["gh", "api", "repos/%s/releases" % REPO, "--paginate", "-q",
         ".[] | {tag: .tag_name, assets: [.assets[] | {id, name, download_count}]}"],
        capture_output=True, text=True, timeout=120, check=True).stdout
    for line in out.splitlines():
        rel = json.loads(line)
        for a in rel["assets"]:
            yield rel["tag"], str(a["id"]), a["name"], str(a["download_count"])


def main(argv):
    if argv[1:] == ["--show"]:
        for r in sorted(last().values(), key=lambda r: (r[1], r[3]), reverse=True):
            print("\t".join((r[1], r[3], r[4], r[0])))
        return 0
    if argv[1:]:
        print(__doc__, file=sys.stderr)
        return 2
    seen = last()
    now = time.strftime("%Y-%m-%dT%H:%M:%S%z")
    new = [(now, tag, aid, name, count) for tag, aid, name, count in fetch()
           if aid not in seen or seen[aid][4] != count]
    if new:
        os.makedirs(os.path.dirname(OUT), exist_ok=True)
        with open(OUT, "a") as f:
            f.writelines("\t".join(r) + "\n" for r in new)
    print("%d counts changed" % len(new))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
