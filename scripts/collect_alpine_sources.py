#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Clement Rahula
"""Fetch the corresponding source for the Alpine packages Lukotta ships.

Binary packages map to fewer source packages: the apk database records each
package's origin, so 58 shipped packages resolve to a smaller set of APKBUILDs.
For each origin this fetches the build recipe (the "scripts used to control
compilation") and the upstream tarballs the recipe names.

    collect_alpine_sources.py <packages.db> <outdir> <alpine-tag> [cachedir]

Given a cache directory, every fetch is kept there under the hash of its URL
and taken from there next time. These are the bulk of a release's source
archive and none of them change: the recipes are pinned to an Alpine tag and
the tarballs to a version, so a URL that is the same names the same bytes. A
package that moves has a new URL and is fetched afresh.
"""
import hashlib, os, re, shutil, sys, subprocess

db_path, out, tag = sys.argv[1], sys.argv[2], sys.argv[3]
cache = sys.argv[4] if len(sys.argv) > 4 else None
os.makedirs(out, exist_ok=True)
if cache:
    os.makedirs(cache, exist_ok=True)


def cached(url):
    """The stored copy of this URL, if there is one that is whole."""
    if not cache:
        return None
    key = os.path.join(cache, hashlib.sha256(url.encode()).hexdigest())
    if not (os.path.exists(key) and os.path.exists(key + ".sha256")):
        return None
    data = open(key, "rb").read()
    if hashlib.sha256(data).hexdigest() != open(key + ".sha256").read().strip():
        return None
    return data


def keep(url, data):
    """Store this URL's contents for the next release."""
    if not cache:
        return
    key = os.path.join(cache, hashlib.sha256(url.encode()).hexdigest())
    tmp = key + ".part"
    try:
        with open(tmp, "wb") as f:
            f.write(data)
        with open(key + ".sha256", "w") as f:
            f.write(hashlib.sha256(data).hexdigest())
        shutil.move(tmp, key)
    except OSError:
        # A cache that cannot be written is not a release that cannot be made.
        if os.path.exists(tmp):
            os.unlink(tmp)

origins, lic_of, cur_o, cur_l = set(), {}, None, None
for line in open(db_path, encoding="utf-8", errors="replace"):
    if line.startswith("o:"):
        cur_o = line[2:].strip()
        origins.add(cur_o)
    elif line.startswith("L:"):
        cur_l = line[2:].strip()
    elif not line.strip():
        if cur_o:
            lic_of[cur_o] = (lic_of.get(cur_o, "") + " " + (cur_l or "")).strip()
        cur_o = cur_l = None
origins = sorted(o for o in origins if o)

COPYLEFT = ("GPL", "LGPL", "AGPL", "MPL", "CDDL", "EPL", "OSL")

def is_copyleft(pkg):
    return any(t in lic_of.get(pkg, "") for t in COPYLEFT)
print(f"  {len(origins)} source packages behind the shipped binaries")

BASE = "https://gitlab.alpinelinux.org/alpine/aports/-/raw/{tag}/{repo}/{pkg}/APKBUILD"
failures, warnings, fetched = [], [], 0
# How much of this release's source came from the last one's.
from_cache = 0

class FetchError(Exception):
    pass

def get(url, timeout=30):
    """Fetch via curl, or from the cache. GitLab answers 418 to unfamiliar
    User-Agents, so using curl's default identity is more reliable than
    hand-rolling headers."""
    global from_cache
    stored = cached(url)
    if stored is not None:
        from_cache += 1
        return stored
    r = subprocess.run(
        ["/usr/bin/curl", "--fail", "--location", "--silent", "--show-error",
         "--retry", "2", "--max-time", str(timeout), url],
        capture_output=True)
    if r.returncode != 0:
        raise FetchError(r.stderr.decode("utf-8", "replace").strip() or f"curl exit {r.returncode}")
    keep(url, r.stdout)
    return r.stdout

def _strip(value, pattern, from_end, longest):
    """Bash ${v%pat} / ${v%%pat} / ${v#pat} / ${v##pat}."""
    import fnmatch
    hits = []
    for i in range(len(value) + 1):
        part = value[i:] if from_end else value[:i]
        if fnmatch.fnmatchcase(part, pattern):
            hits.append(i)
    if not hits:
        return value
    if from_end:
        return value[: (min(hits) if longest else max(hits))]
    return value[(max(hits) if longest else min(hits)) :]


def _expansion(inner, vars_):
    """Evaluate the body of a ${...} expansion."""
    m = re.match(r"^([A-Za-z_][A-Za-z0-9_]*)(.*)$", inner, re.S)
    if not m:
        return ""
    name, rest = m.group(1), m.group(2)
    value = vars_.get(name, "")
    if not rest:
        return value

    def pat(p):
        # The pattern may reference other variables and may be quoted.
        return expand(p, vars_).replace('"', "").replace("'", "")
    if rest.startswith("%%"):
        return _strip(value, pat(rest[2:]), from_end=True, longest=True)
    if rest.startswith("%"):
        return _strip(value, pat(rest[1:]), from_end=True, longest=False)
    if rest.startswith("##"):
        return _strip(value, pat(rest[2:]), from_end=False, longest=True)
    if rest.startswith("#"):
        return _strip(value, pat(rest[1:]), from_end=False, longest=False)
    if rest.startswith("//"):
        frm, _, to = rest[2:].partition("/")
        return value.replace(frm, to)
    if rest.startswith("/"):
        frm, _, to = rest[1:].partition("/")
        return value.replace(frm, to, 1)
    return value


def expand(value, vars_):
    """Expand $var and ${var...} forms, repeating so nested variables resolve."""
    for _ in range(6):
        out, i, changed = [], 0, False
        while i < len(value):
            if value[i] == "$" and i + 1 < len(value):
                if value[i + 1] == "{":
                    depth, j = 1, i + 2
                    while j < len(value) and depth:
                        if value[j] == "{":
                            depth += 1
                        elif value[j] == "}":
                            depth -= 1
                        j += 1
                    out.append(_expansion(value[i + 2 : j - 1], vars_))
                    i, changed = j, True
                    continue
                m = re.match(r"[A-Za-z_][A-Za-z0-9_]*", value[i + 1 :])
                if m:
                    out.append(vars_.get(m.group(0), ""))
                    i, changed = i + 1 + len(m.group(0)), True
                    continue
            out.append(value[i])
            i += 1
        value = "".join(out)
        if not changed:
            break
    return value


for pkg in origins:
    body = None
    for repo in ("main", "community", "testing"):
        try:
            body = get(BASE.format(tag=tag, repo=repo, pkg=pkg))
            break
        except FetchError:
            continue
    if body is None:
        failures.append(f"{pkg}: no APKBUILD found in main/community/testing at {tag}")
        continue

    pdir = os.path.join(out, pkg)
    os.makedirs(pdir, exist_ok=True)
    open(os.path.join(pdir, "APKBUILD"), "wb").write(body)
    fetched += 1

    text = body.decode("utf-8", "replace")
    # Evaluate assignments sequentially, expanding each against what is already
    # defined. Recipes reassign variables in terms of themselves, so collecting
    # every assignment first and expanding afterwards gets the wrong answer.
    vars_ = {}
    for m in re.finditer(r'^\s*([A-Za-z_][A-Za-z0-9_]*)=(?:"([^"]*)"|\'([^\']*)\'|([^\s;]*))',
                         text, re.M):
        raw = m.group(2) or m.group(3) or m.group(4) or ""
        vars_[m.group(1)] = expand(raw, vars_)

    sm = re.search(r'^source=(?:"([^"]*)"|\'([^\']*)\'|(\S*))', text, re.M | re.S)
    if not sm:
        continue
    for token in (sm.group(1) or sm.group(2) or sm.group(3) or "").split():
        raw = expand(token, vars_)
        alias, sep, tail = raw.partition("::")
        url = tail if sep else raw
        if not url.startswith(("http://", "https://")):
            continue
        name = (alias if sep else os.path.basename(url)) or f"{pkg}-source"
        dest = os.path.join(pdir, name)
        if os.path.exists(dest):
            # Already here from an earlier pass over the same directory. Put it
            # in the cache if it is not there yet, so a tree collected before
            # there was a cache still saves the next release the download.
            if cached(url) is None:
                keep(url, open(dest, "rb").read())
            continue

        # Upstream first; then Alpine's own distfiles mirror, which holds every
        # source Alpine built from. Upstream projects move and delete tarballs,
        # and the mirror is what the recipe was actually built against.
        candidates = [url]

        # SQLite names its tarballs by a version code the APKBUILD computes with
        # shell arithmetic — 3.53.2 becomes 3530200 — which the expansion above
        # cannot evaluate, so it produced a name that exists nowhere. Build the
        # code here, and try the years SQLite files releases under.
        if pkg.startswith("sqlite"):
            pv = vars_.get("pkgver", "")
            parts = pv.split(".")
            if len(parts) >= 3 and all(x.isdigit() for x in parts[:3]):
                code = f"{int(parts[0])}{int(parts[1]):02d}{int(parts[2]):02d}00"
                stem = f"sqlite-autoconf-{code}.tar.gz"
                candidates = [f"https://sqlite.org/{y}/{stem}" for y in (2026, 2025, 2024)]
                candidates.append(f"https://distfiles.alpinelinux.org/distfiles/{stem}")
                name = stem
                dest = os.path.join(pdir, name)
                if os.path.exists(dest):
                    if not any(cached(c) is not None for c in candidates):
                        keep(candidates[0], open(dest, "rb").read())
                    continue

        if name and "$" not in name:
            candidates += [
                f"https://distfiles.alpinelinux.org/distfiles/v3.24/{name}",
                f"https://distfiles.alpinelinux.org/distfiles/edge/{name}",
                f"https://distfiles.alpinelinux.org/distfiles/{name}",
            ]
        last, data = None, None
        for cand in candidates:
            try:
                data = get(cand, timeout=120)
                last = None
                break
            except Exception as e:
                last = f"{cand}: {e}"
        if data is not None:
            open(dest, "wb").write(data)
        elif last:
            # Only copyleft components carry a source obligation; permissive
            # ones are mirrored as a courtesy and must not fail the release.
            (failures if is_copyleft(pkg) else warnings).append(f"{pkg}: {last}")

print(f"  {fetched}/{len(origins)} recipes fetched")
if from_cache:
    print(f"  {from_cache} file(s) kept from an earlier release rather than downloaded")
if warnings:
    print(f"  {len(warnings)} permissive-licence source(s) unavailable (no obligation):")
    for w in warnings[:10]:
        print(f"    {w}")
if failures:
    print(f"  {len(failures)} COPYLEFT source(s) missing — release must not ship:")
    for f in failures[:25]:
        print(f"    {f}")
    sys.exit(1)
