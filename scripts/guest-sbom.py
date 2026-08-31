#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Clement Rahula
"""Write a CycloneDX SBOM of the Alpine guest that actually ships.

    guest-sbom.py <packages.db> <out.json>

The audit workflow used to point Trivy at the base image in the registry,
which is not what ships: "anylinuxfs init" boots that image and installs into
it, and trim-image.py then takes packages back out. The registry copy carries
16 packages; the guest carries 66. Scanning it answered a question nobody had
asked, and left the other 50 unwatched.

So the inventory is published instead. The source is the same Alpine package
database THIRD_PARTY_NOTICES.md is built from -- the one captured from the
image that ships -- and the result is committed, because the audit runs on a
Linux runner from a bare checkout and cannot see a vendor tree or a macOS
build.

Two fields matter more than they look:

  SrcName    Alpine's security database is keyed by the source package, not
             the binary one. An advisory against "openssl" is what makes
             libcrypto3 and libssl3 report. Strip this property and Trivy
             matches nothing, reports a clean image and exits 0 -- the one
             failure this job must not have. Measured, not assumed.
  the OS     The operating-system component is what tells Trivy which Alpine
  component  advisory feed to read. Packages listed flat, with no such
             component above them, parse without complaint and match nothing.

Nothing here is generated from the clock: no timestamp, no serial number, and
the components are sorted. Regenerating an unchanged image produces an
unchanged file, so a diff means the guest moved.
"""
import json, sys

if len(sys.argv) != 3:
    sys.exit(__doc__.strip().splitlines()[2].strip())
db_path, out_path = sys.argv[1], sys.argv[2]

# The installed database is blank-line separated records of single-letter
# fields. Only the identifying ones are read; the file lists are what make the
# file large and say nothing about which advisories apply.
packages, cur = [], {}
for line in open(db_path, encoding="utf-8", errors="replace"):
    line = line.rstrip("\n")
    if not line:
        if cur.get("P"):
            packages.append(cur)
        cur = {}
        continue
    if len(line) > 1 and line[1] == ":" and line[0] not in ("F", "R", "Z", "a", "M"):
        cur.setdefault(line[0], line[2:])
if cur.get("P"):
    packages.append(cur)

if not packages:
    sys.exit(f"error: no packages in {db_path}")

# The guest states its own Alpine version. Taking it from the lock or from a
# constant would let the two drift apart silently, and the advisory feed is
# chosen by this number.
release = next((p for p in packages if p.get("P") == "alpine-release"), None)
if not release:
    sys.exit(
        f"error: {db_path} has no alpine-release package, so the Alpine\n"
        "       version is unknown and no advisory feed can be chosen.")
os_version = release["V"].rsplit("-r", 1)[0]

arch = release.get("A", "aarch64")

components, refs = [], []
for p in sorted(packages, key=lambda p: p["P"]):
    name, version = p["P"], p.get("V", "")
    # The origin defaults to the package's own name: a package that is not a
    # subpackage is its own source, and Trivy needs the field either way.
    src = p.get("o", name)
    ref = f"pkg:apk/alpine/{name}@{version}?arch={p.get('A', arch)}&distro=alpine-{os_version}"
    component = {
        "bom-ref": ref,
        "type": "library",
        "name": name,
        "version": version,
        "purl": ref,
        "properties": [
            {"name": "aquasecurity:trivy:PkgType", "value": "alpine"},
            {"name": "aquasecurity:trivy:SrcName", "value": src},
            {"name": "aquasecurity:trivy:SrcVersion", "value": version},
        ],
    }
    if p.get("L"):
        component["licenses"] = [{"expression": p["L"]}]
    components.append(component)
    refs.append(ref)

OS_REF = "alpine-guest-os"
ROOT_REF = "lukotta-linux-guest"
components.append({
    "bom-ref": OS_REF,
    "type": "operating-system",
    "name": "alpine",
    "version": os_version,
})

bom = {
    "bomFormat": "CycloneDX",
    "specVersion": "1.6",
    "version": 1,
    "metadata": {
        "component": {
            "bom-ref": ROOT_REF,
            "type": "application",
            "name": "lukotta-linux-guest",
            "version": os_version,
        },
    },
    "components": components,
    # Trivy reads the OS packages as the dependencies of the operating-system
    # component. Flat lists of components parse, and then match nothing.
    "dependencies": [
        {"ref": ROOT_REF, "dependsOn": [OS_REF]},
        {"ref": OS_REF, "dependsOn": refs},
    ] + [{"ref": r, "dependsOn": []} for r in refs],
}

with open(out_path, "w", encoding="utf-8") as fh:
    json.dump(bom, fh, indent=2, sort_keys=False)
    fh.write("\n")
print(f"wrote {out_path}: {len(refs)} packages, alpine {os_version}")
