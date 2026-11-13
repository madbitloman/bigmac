#!/usr/bin/env python3
"""Refreshes Resources/hosts-blocklist.txt from StevenBlack's unified hosts list (MIT).

Only host names are kept: whatever address a line points at, BigMac writes every entry as
0.0.0.0, so a hostile upstream line such as "1.2.3.4 yourbank.com" can never become a redirect.
Usage: scripts/hosts-blocklist.py [hosts-file]   (downloads the list when no file is given)
"""
import re, sys, urllib.request, pathlib

URL = "https://raw.githubusercontent.com/StevenBlack/hosts/master/hosts"
LABEL = re.compile(r"^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$")
SKIP = {"localhost", "localhost.localdomain", "local", "broadcasthost", "ip6-localhost", "ip6-loopback",
        "ip6-localnet", "ip6-mcastprefix", "ip6-allnodes", "ip6-allrouters", "ip6-allhosts", "0.0.0.0"}

def valid(host):
    labels = host.split(".")
    return (len(labels) >= 2 and len(host) <= 253 and all(LABEL.match(l) for l in labels)
            and any(c.isalpha() for c in labels[-1]))

text = pathlib.Path(sys.argv[1]).read_text() if len(sys.argv) > 1 else urllib.request.urlopen(URL, timeout=60).read().decode()
version = next((l.split(":", 1)[1].strip() for l in text.splitlines() if l.startswith("# Date:")), "unknown")
names = set()
for line in text.splitlines():
    fields = line.split("#", 1)[0].split()
    if len(fields) >= 2 and fields[0] in ("0.0.0.0", "127.0.0.1"):
        for name in fields[1:]:
            name = name.lower().rstrip(".")
            if name not in SKIP and valid(name):
                names.add(name)
out = pathlib.Path(__file__).resolve().parent.parent / "Resources" / "hosts-blocklist.txt"
out.write_text(f"# StevenBlack/hosts unified list, {version}. MIT licence, https://github.com/StevenBlack/hosts\n"
               + "\n".join(sorted(names)) + "\n")
print(f"{len(names)} names -> {out}")
