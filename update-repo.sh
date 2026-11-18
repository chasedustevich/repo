#!/usr/bin/env bash
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$REPO_DIR"

export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"

BASE_URL="${REPO_BASE_URL:-https://chasedustevich.github.io/repo}"
SYNC_SIBLINGS=0

usage() {
	cat <<'EOF'
Usage: ./update-repo.sh [--sync]

Options:
  --sync    Copy newer release iphoneos-arm64 .deb packages from sibling
            workspaces (../Asteroid, ../Snoverlay-2,
            ../axon-ios16-compatibility, ../s8edge) into ./debs and prune
            older duplicate versions before rebuilding repository indices.
  -h, --help  Show this help message.
EOF
}

for arg in "$@"; do
	case "$arg" in
		--sync)
			SYNC_SIBLINGS=1
			;;
		-h|--help)
			usage
			exit 0
			;;
		*)
			echo "Unknown argument: $arg" >&2
			usage >&2
			exit 1
			;;
	esac
done

for cmd in dpkg-scanpackages dpkg-deb dpkg python3 bzip2 gzip xz; do
	if ! command -v "$cmd" >/dev/null 2>&1; then
		echo "Error: required command '$cmd' not found in PATH." >&2
		exit 1
	fi
done

mkdir -p "$REPO_DIR/debs"

if [[ "$SYNC_SIBLINGS" -eq 1 ]]; then
	python3 - "$REPO_DIR" <<'PYEOF'
import hashlib
import os
import shutil
import subprocess
import sys

repo_dir = sys.argv[1]
parent_dir = os.path.dirname(repo_dir)
debs_dir = os.path.join(repo_dir, "debs")

sources = [
    ("com.midnightchips.asteroid", os.path.join(parent_dir, "Asteroid")),
    ("com.ryannair05.snoverlay", os.path.join(parent_dir, "Snoverlay-2")),
    ("me.nepeta.axon", os.path.join(parent_dir, "axon-ios16-compatibility")),
    ("com.brunonfl.s8edge", os.path.join(parent_dir, "s8edge")),
]


def read_control_meta(control_path):
    meta = {}
    if not os.path.isfile(control_path):
        return "", ""
    with open(control_path, "r", encoding="utf-8", errors="replace") as f:
        for line in f:
            line = line.strip()
            if ":" in line:
                k, v = line.split(":", 1)
                meta[k.strip()] = v.strip()
    return meta.get("Package", ""), meta.get("Version", "")


def read_deb_meta(path):
    res = subprocess.run(
        ["dpkg-deb", "-f", path, "Package", "Version", "Architecture"],
        capture_output=True,
        text=True,
        check=True,
    )
    meta = {}
    for line in res.stdout.splitlines():
        if ":" in line:
            k, v = line.split(":", 1)
            meta[k.strip()] = v.strip()
    return meta.get("Package", ""), meta.get("Version", ""), meta.get("Architecture", "")


def cmp_ver(a, b):
    if a == b:
        return 0
    if subprocess.run(["dpkg", "--compare-versions", a, "gt", b]).returncode == 0:
        return 1
    return -1


def file_sha256(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(65536), b""):
            h.update(chunk)
    return h.hexdigest()


# Index current debs in repo/debs by (package, arch)
existing_by_pkg = {}
for fname in sorted(os.listdir(debs_dir)):
    if not fname.endswith(".deb"):
        continue
    fpath = os.path.join(debs_dir, fname)
    if not os.path.isfile(fpath):
        continue
    pkg, ver, arch = read_deb_meta(fpath)
    if not pkg:
        continue
    existing_by_pkg.setdefault((pkg, arch), []).append((ver, os.path.getmtime(fpath), fpath))

# Sync release iphoneos-arm64 package matching control Version from each sibling workspace
for fallback_pkg, ws_dir in sources:
    src_dir = os.path.join(ws_dir, "packages")
    if not os.path.isdir(src_dir):
        print(f"[sync] Skipping missing directory: {src_dir}")
        continue

    ctrl_pkg, ctrl_ver = read_control_meta(os.path.join(ws_dir, "control"))
    expected_pkg = ctrl_pkg or fallback_pkg

    candidates = []
    for fname in sorted(os.listdir(src_dir)):
        if not fname.endswith(".deb"):
            continue
        fpath = os.path.join(src_dir, fname)
        if not os.path.isfile(fpath):
            continue
        pkg, ver, arch = read_deb_meta(fpath)
        if pkg != expected_pkg or arch != "iphoneos-arm64" or "+debug" in ver:
            continue
        candidates.append((ver, os.path.getmtime(fpath), fpath))

    if not candidates:
        print(f"[sync] No release iphoneos-arm64 .deb found for {expected_pkg} in {src_dir}")
        continue

    # Prefer candidate matching workspace control Version; otherwise pick highest version
    exact = [c for c in candidates if ctrl_ver and c[0] == ctrl_ver]
    if exact:
        best = max(exact, key=lambda c: c[1])
    else:
        best = candidates[0]
        for cand in candidates[1:]:
            c = cmp_ver(cand[0], best[0])
            if c > 0 or (c == 0 and cand[1] > best[1]):
                best = cand

    cand_ver, cand_mtime, cand_path = best
    key = (expected_pkg, "iphoneos-arm64")
    current_list = existing_by_pkg.get(key, [])

    should_copy = False
    if len(current_list) != 1:
        should_copy = True
    else:
        cur_ver, _, cur_path = current_list[0]
        if cur_ver != cand_ver or os.path.basename(cur_path) != os.path.basename(cand_path):
            should_copy = True
        elif file_sha256(cand_path) != file_sha256(cur_path):
            should_copy = True

    if should_copy:
        dest_name = os.path.basename(cand_path)
        dest_path = os.path.join(debs_dir, dest_name)
        shutil.copy2(cand_path, dest_path)
        print(f"[sync] Synced {dest_name} ({cand_ver})")
        # Remove any other versions/files for this package+arch
        for _, _, old_path in current_list:
            if os.path.abspath(old_path) != os.path.abspath(dest_path) and os.path.exists(old_path):
                os.remove(old_path)
                print(f"[sync] Pruned {os.path.basename(old_path)}")
        existing_by_pkg[key] = [(cand_ver, os.path.getmtime(dest_path), dest_path)]
    else:
        print(f"[sync] Up to date: {expected_pkg} ({cand_ver})")

# Prune any remaining older duplicates of the same (package, arch) in debs/
for key, entries in existing_by_pkg.items():
    if len(entries) <= 1:
        continue
    best = entries[0]
    for entry in entries[1:]:
        c = cmp_ver(entry[0], best[0])
        if c > 0 or (c == 0 and entry[1] > best[1]):
            best = entry
    for _, _, fpath in entries:
        if os.path.abspath(fpath) != os.path.abspath(best[2]) and os.path.exists(fpath):
            os.remove(fpath)
            print(f"[sync] Pruned duplicate {os.path.basename(fpath)}")
PYEOF
fi

dpkg-scanpackages -m ./debs > Packages.tmp

python3 - "$REPO_DIR" "$BASE_URL" "Packages.tmp" <<'PYEOF'
import json
import os
import re
import subprocess
import sys

repo_dir, base_url, packages_tmp = sys.argv[1], sys.argv[2].rstrip("/"), sys.argv[3]

with open(packages_tmp, "r", encoding="utf-8") as f:
    raw = f.read()


def cmp_ver(a, b):
    if a == b:
        return 0
    if subprocess.run(["dpkg", "--compare-versions", a, "gt", b]).returncode == 0:
        return 1
    return -1


def parse_stanza_fields(lines):
    fields = {}
    for line in lines:
        if line and not line[0].isspace() and ":" in line:
            k, v = line.split(":", 1)
            fields[k.strip()] = v.strip()
    return fields


def update_stanza_field(lines, key, value, replace_if_present=True):
    prefix = f"{key}:"
    for idx, line in enumerate(lines):
        if line.startswith(prefix):
            if replace_if_present or not line.split(":", 1)[1].strip():
                lines[idx] = f"{key}: {value}"
            return lines
    lines.append(f"{key}: {value}")
    return lines


stanzas_raw = [s for s in raw.strip("\n").split("\n\n") if s.strip()]
processed_stanzas = []
latest_versions = {}

for stanza in stanzas_raw:
    lines = stanza.splitlines()
    fields = parse_stanza_fields(lines)
    pkg = fields.get("Package", "")
    ver = fields.get("Version", "")
    filename = fields.get("Filename", "")

    if filename:
        norm_filename = f"./debs/{os.path.basename(filename)}"
        lines = update_stanza_field(lines, "Filename", norm_filename, replace_if_present=True)

    if pkg:
        if ver:
            prev = latest_versions.get(pkg)
            if prev is None or cmp_ver(ver, prev) > 0:
                latest_versions[pkg] = ver

        dep_dir = os.path.join(repo_dir, "depictions", pkg)
        info_xml = os.path.join(dep_dir, "info.xml")
        sileo_json = os.path.join(dep_dir, "sileo.json")
        pkg_icon = os.path.join(dep_dir, "icon.png")
        pkg_banner = os.path.join(dep_dir, "banner.png")

        if os.path.isfile(info_xml) and not fields.get("Depiction"):
            lines = update_stanza_field(
                lines,
                "Depiction",
                f"{base_url}/depictions/?p={pkg}",
                replace_if_present=False,
            )

        if os.path.isfile(sileo_json) and not fields.get("SileoDepiction"):
            lines = update_stanza_field(
                lines,
                "SileoDepiction",
                f"{base_url}/depictions/{pkg}/sileo.json",
                replace_if_present=False,
            )

        if os.path.isfile(pkg_icon) and not fields.get("Icon"):
            lines = update_stanza_field(
                lines,
                "Icon",
                f"{base_url}/depictions/{pkg}/icon.png",
                replace_if_present=False,
            )

        if os.path.isfile(pkg_banner) and not fields.get("Header"):
            lines = update_stanza_field(
                lines,
                "Header",
                f"{base_url}/depictions/{pkg}/banner.png",
                replace_if_present=False,
            )

    processed_stanzas.append("\n".join(lines))

output = ("\n\n".join(processed_stanzas) + "\n") if processed_stanzas else ""
with open(packages_tmp, "w", encoding="utf-8") as f:
    f.write(output)

# Synchronize depiction versions with the latest .deb version per package
for pkg, ver in latest_versions.items():
    dep_dir = os.path.join(repo_dir, "depictions", pkg)

    info_xml = os.path.join(dep_dir, "info.xml")
    if os.path.isfile(info_xml):
        with open(info_xml, "r", encoding="utf-8") as f:
            xml_text = f.read()
        new_xml, count = re.subn(
            r"(<version>)(.*?)(</version>)",
            rf"\g<1>{ver}\g<3>",
            xml_text,
            count=1,
        )
        if count > 0 and new_xml != xml_text:
            with open(info_xml, "w", encoding="utf-8") as f:
                f.write(new_xml)
            print(f"[depiction] Updated {pkg}/info.xml version -> {ver}")

    changelog_xml = os.path.join(dep_dir, "changelog.xml")
    if os.path.isfile(changelog_xml):
        with open(changelog_xml, "r", encoding="utf-8") as f:
            cl_text = f.read()
        new_cl, count = re.subn(
            r"(<version>)(.*?)(</version>)",
            rf"\g<1>{ver}\g<3>",
            cl_text,
            count=1,
        )
        if count > 0 and new_cl != cl_text:
            with open(changelog_xml, "w", encoding="utf-8") as f:
                f.write(new_cl)
            print(f"[depiction] Updated {pkg}/changelog.xml version -> {ver}")

    sileo_json = os.path.join(dep_dir, "sileo.json")
    pkg_banner = os.path.join(dep_dir, "banner.png")
    if os.path.isfile(sileo_json):
        with open(sileo_json, "r", encoding="utf-8") as f:
            data = json.load(f)
        changed = False
        if os.path.isfile(pkg_banner):
            banner_url = f"{base_url}/depictions/{pkg}/banner.png"
            if data.get("headerImage") != banner_url:
                data["headerImage"] = banner_url
                changed = True
        for tab in data.get("tabs", []):
            is_changelog_tab = tab.get("tabname") == "Changelog"
            updated_changelog_header = False
            for view in tab.get("views", []):
                if view.get("class") == "DepictionTableTextView" and view.get("title") == "Version":
                    if view.get("text") != ver:
                        view["text"] = ver
                        changed = True
                elif (
                    is_changelog_tab
                    and not updated_changelog_header
                    and view.get("class") == "DepictionHeaderView"
                ):
                    if view.get("title") != ver:
                        view["title"] = ver
                        changed = True
                    updated_changelog_header = True
        if changed:
            with open(sileo_json, "w", encoding="utf-8") as f:
                json.dump(data, f, indent=2)
                f.write("\n")
            print(f"[depiction] Updated {pkg}/sileo.json -> {ver}")
PYEOF

mv Packages.tmp Packages
bzip2 -c9 Packages > Packages.bz2
gzip -c9n Packages > Packages.gz
xz -c9 Packages > Packages.xz

echo "Repository indices rebuilt:"
ls -lh Packages Packages.bz2 Packages.gz Packages.xz
