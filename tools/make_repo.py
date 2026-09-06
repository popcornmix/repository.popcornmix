#!/usr/bin/env python3
"""Maintain the published tree of the popcornmix Kodi add-on repository.

  make_repo.py add <zip> --series piers --arch aarch64
  make_repo.py build [--check]

"add" files a built add-on zip under docs/, "build" regenerates everything
derived from it: the per-target addons.xml indexes, the repository add-on and
its zip, and the landing page. "add" runs "build" afterwards, so the tree is
never left half updated.
"""

import argparse
import hashlib
import re
import shutil
import sys
import zipfile
import xml.etree.ElementTree as ET
from pathlib import Path

REPO_ID = "repository.popcornmix"
REPO_URL = "https://popcornmix.github.io/repository.popcornmix"

# Kodi filters <dir> entries on the version of the "xbmc.addon" pseudo add-on
# (ADDON_API in Kodi's version.txt), which trails the Kodi version through a
# development cycle: Kodi 22 alphas report 21.90.x and only the release reports
# 22.0.0. Hence each range starts at the previous major's .90.
SERIES = {
    "omega": ("20.90.0", "21.9.9", "Kodi 21 Omega"),
    "piers": ("21.90.0", "22.9.9", "Kodi 22 Piers"),
}

# Kodi has no notion of a LibreELEC project, so an aarch64 build serves every
# aarch64 device on the matching Kodi release.
ARCHES = {
    "aarch64": "linux-aarch64",
    "armv7": "linux-armv7",
    "x86_64": "linux-x86_64",
}

ROOT = Path(__file__).resolve().parent.parent
SRC = ROOT / REPO_ID
DOCS = ROOT / "docs"
SELF_DIR = "repository"

# A fixed timestamp keeps the generated zip byte-for-byte reproducible, so
# "build --check" can tell a stale tree from an unchanged one.
ZIP_DATE = (1980, 1, 1, 0, 0, 0)


def version_key(version):
    return tuple(int(part) for part in re.findall(r"\d+", version))


def addon_xml_from_zip(path):
    """Return (addon id, parsed addon.xml) from an add-on zip."""
    with zipfile.ZipFile(path) as archive:
        names = [
            name
            for name in archive.namelist()
            if name.count("/") == 1 and name.endswith("/addon.xml")
        ]
        if len(names) != 1:
            sys.exit(f"{path}: expected one <addon id>/addon.xml, found {len(names)}")
        root = ET.fromstring(archive.read(names[0]))
    addon_id = names[0].split("/")[0]
    if root.get("id") != addon_id:
        sys.exit(f"{path}: directory {addon_id} does not match add-on id {root.get('id')}")
    return addon_id, root


def metadata(root):
    for extension in root.findall("extension"):
        if extension.get("point") == "xbmc.addon.metadata":
            return extension
    return None


def assets(root):
    element = metadata(root)
    element = element.find("assets") if element is not None else None
    return [child.text for child in element if child.text] if element is not None else []


def set_platform(root, platform):
    element = metadata(root)
    if element is None:
        element = ET.SubElement(root, "extension", {"point": "xbmc.addon.metadata"})
    child = element.find("platform")
    if child is None:
        child = ET.SubElement(element, "platform")
    child.text = platform


def newest_zips(directory):
    """Newest zip per add-on id under a docs/<series>/<arch> directory."""
    found = {}
    for addon_dir in sorted(p for p in directory.iterdir() if p.is_dir()):
        zips = sorted(addon_dir.glob("*.zip"), key=lambda p: version_key(p.stem))
        if zips:
            found[addon_dir.name] = zips[-1]
    return found


def serialise(addons):
    ET.indent(addons, "  ")
    return ('<?xml version="1.0" encoding="UTF-8"?>\n' + ET.tostring(addons, encoding="unicode") + "\n").encode()


def digest(data, name):
    """A sha256sum line, which is also what Kodi reads up to the first space."""
    return f"{hashlib.sha256(data).hexdigest()}  {name}\n".encode()


def targets():
    """Published (series, arch) pairs, in the order they appear in the tables."""
    for series in SERIES:
        for arch in ARCHES:
            directory = DOCS / series / arch
            if directory.is_dir() and newest_zips(directory):
                yield series, arch


def dir_block(path, comment, minversion=None, maxversion=None):
    versions = ""
    if minversion:
        versions = f' minversion="{minversion}" maxversion="{maxversion}"'
    url = f"{REPO_URL}/{path}"
    return (
        f"    <!-- {comment} -->\n"
        f"    <dir{versions}>\n"
        f"      <info>{url}/addons.xml</info>\n"
        f'      <checksum verify="sha256">{url}/addons.xml.sha256</checksum>\n'
        f'      <datadir zip="true">{url}</datadir>\n'
        f"      <hashes>sha256</hashes>\n"
        f"    </dir>"
    )


def repository_addon_xml():
    blocks = [dir_block(SELF_DIR, "this add-on, so the repository can update itself")]
    for series, arch in targets():
        minversion, maxversion, label = SERIES[series]
        blocks.append(dir_block(f"{series}/{arch}", f"{label}, {arch}", minversion, maxversion))
    template = (SRC / "addon.xml.in").read_text()
    return template.replace("@DIRS@", "\n".join(blocks)).encode()


def index_html(published):
    zip_name = f"{REPO_ID}-{ET.fromstring(repository_addon_xml()).get('version')}.zip"
    rows = "\n".join(
        f"        <tr><td>{SERIES[series][2]}</td><td>{arch}</td>"
        f"<td>{'<br>'.join(f'{i} {v}' for i, v in sorted(addons.items()))}</td></tr>"
        for series, arch, addons in published
    ) or '        <tr><td colspan="3">Nothing published yet.</td></tr>'
    return f"""<!doctype html>
<html lang="en-GB">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>popcornmix Add-ons</title>
<style>
  :root {{ color-scheme: light dark; }}
  body {{ font: 16px/1.6 system-ui, sans-serif; max-width: 44rem; margin: 0 auto; padding: 2rem 1.25rem; }}
  code, kbd {{ font-family: ui-monospace, monospace; font-size: 0.9em; }}
  a.zip {{ display: inline-block; padding: 0.6rem 1rem; border: 1px solid; border-radius: 0.4rem;
           text-decoration: none; font-weight: 600; }}
  table {{ border-collapse: collapse; width: 100%; margin: 1rem 0; }}
  th, td {{ text-align: left; padding: 0.4rem 0.6rem; border-bottom: 1px solid; vertical-align: top; }}
  ol li {{ margin: 0.35rem 0; }}
</style>
</head>
<body>
<h1>popcornmix Add-ons</h1>
<p>A Kodi add-on repository. It currently carries
<a href="https://github.com/popcornmix/inputstream.airplay">inputstream.airplay</a>, an AirPlay
receiver for screen mirroring, video streamed from apps, and audio.</p>

<p><a class="zip" href="{SELF_DIR}/{REPO_ID}/{zip_name}">Download {zip_name}</a></p>

<h2>Installing on LibreELEC</h2>
<ol>
  <li>Copy the zip above to the machine running Kodi &mdash; over the network, or onto a USB stick.</li>
  <li>In Kodi, go to <kbd>Settings &rarr; System &rarr; Add-ons</kbd> and turn on <em>Unknown sources</em>.</li>
  <li><kbd>Settings &rarr; Add-ons &rarr; Install from zip file</kbd>, and pick the zip.</li>
  <li><kbd>Install from repository &rarr; popcornmix Add-ons &rarr; VideoPlayer InputStream</kbd>,
      and install <em>AirPlay Receiver</em>.</li>
</ol>
<p>Kodi serves the build matching its own version and architecture, and updates the add-on from
here as new builds are published.</p>

<h2>Published</h2>
<table>
  <thead><tr><th>Kodi</th><th>Architecture</th><th>Add-ons</th></tr></thead>
  <tbody>
{rows}
  </tbody>
</table>
</body>
</html>
"""


def generate():
    """Every generated file, as {path relative to the repository root: bytes}."""
    files = {Path("docs/.nojekyll"): b""}
    published = []

    for series, arch in targets():
        found = newest_zips(DOCS / series / arch)
        addons = ET.Element("addons")
        versions = {}
        for addon_id, path in sorted(found.items()):
            _, root = addon_xml_from_zip(path)
            # Kodi drops repository entries whose <platform> does not match the
            # running system, and that is all that separates the builds for
            # each architecture: they share an add-on id and a version.
            set_platform(root, ARCHES[arch])
            addons.append(root)
            versions[addon_id] = root.get("version")
            files[path.relative_to(ROOT).with_name(path.name + ".sha256")] = digest(
                path.read_bytes(), path.name
            )
        index = serialise(addons)
        base = Path("docs") / series / arch
        files[base / "addons.xml"] = index
        files[base / "addons.xml.sha256"] = digest(index, "addons.xml")
        published.append((series, arch, versions))

    addon_xml = repository_addon_xml()
    root = ET.fromstring(addon_xml)
    version = root.get("version")
    set_platform(root, "all")

    addons = ET.Element("addons")
    addons.append(root)
    index = serialise(addons)
    base = Path("docs") / SELF_DIR
    files[base / "addons.xml"] = index
    files[base / "addons.xml.sha256"] = digest(index, "addons.xml")

    contents = [(f"{REPO_ID}/addon.xml", addon_xml)]
    for asset in assets(root):
        contents.append((f"{REPO_ID}/{asset}", (SRC / asset).read_bytes()))
        files[base / REPO_ID / asset] = (SRC / asset).read_bytes()

    buffer = zipfile.ZipFile(zip_path := ROOT / ".make_repo.zip", "w", zipfile.ZIP_DEFLATED)
    for name, data in contents:
        buffer.writestr(zipfile.ZipInfo(name, ZIP_DATE), data)
    buffer.close()
    zip_name = f"{REPO_ID}-{version}.zip"
    files[base / REPO_ID / zip_name] = zip_path.read_bytes()
    files[base / REPO_ID / f"{zip_name}.sha256"] = digest(zip_path.read_bytes(), zip_name)
    zip_path.unlink()

    files[Path("docs/index.html")] = index_html(published).encode()
    return files


def build(check):
    files = generate()
    stale = []
    for path, data in sorted(files.items()):
        target = ROOT / path
        if target.exists() and target.read_bytes() == data:
            continue
        stale.append(path)
        if not check:
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_bytes(data)

    # A zip is named after its version, so a version bump writes a new file
    # beside the old one rather than over it, leaving the old one served and
    # still installable.
    left_over = [
        path
        for path in [*(DOCS / SELF_DIR / REPO_ID).glob(f"{REPO_ID}-*.zip"), *DOCS.rglob("*.sha256")]
        if path.relative_to(ROOT) not in files
    ]

    if check:
        for path in stale:
            print(f"out of date: {path}")
        for path in left_over:
            print(f"left over: {path.relative_to(ROOT)}")
        if stale or left_over:
            sys.exit("docs/ does not match its sources; run tools/make_repo.py build")
        print("docs/ is up to date")
    else:
        for path in stale:
            print(f"wrote {path}")
        for path in left_over:
            path.unlink()
            print(f"removed {path.relative_to(ROOT)}")
        if not stale and not left_over:
            print("docs/ was already up to date")


def add(source, series, arch):
    if series not in SERIES:
        sys.exit(f"unknown series {series}; expected one of {', '.join(SERIES)}")
    if arch not in ARCHES:
        sys.exit(f"unknown architecture {arch}; expected one of {', '.join(ARCHES)}")

    addon_id, root = addon_xml_from_zip(source)
    version = root.get("version")
    destination = DOCS / series / arch / addon_id
    destination.mkdir(parents=True, exist_ok=True)

    for old in destination.glob("*.zip"):
        if old.name != f"{addon_id}-{version}.zip":
            old.unlink()
            print(f"removed {old.relative_to(ROOT)}")
    for old in destination.glob("changelog-*.txt"):
        if old.name != f"changelog-{version}.txt":
            old.unlink()

    shutil.copyfile(source, destination / f"{addon_id}-{version}.zip")
    print(f"wrote {(destination / f'{addon_id}-{version}.zip').relative_to(ROOT)}")

    # Kodi fetches artwork and the changelog from beside the zip rather than
    # from inside it, so the browser can show them before anything is installed.
    with zipfile.ZipFile(source) as archive:
        names = set(archive.namelist())
        for asset in assets(root):
            if f"{addon_id}/{asset}" in names:
                path = destination / asset
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_bytes(archive.read(f"{addon_id}/{asset}"))
        if f"{addon_id}/changelog.txt" in names:
            (destination / f"changelog-{version}.txt").write_bytes(
                archive.read(f"{addon_id}/changelog.txt")
            )

    build(check=False)


def main():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    commands = parser.add_subparsers(dest="command", required=True)

    add_parser = commands.add_parser("add", help="file a built add-on zip under docs/")
    add_parser.add_argument("zip", type=Path)
    add_parser.add_argument("--series", required=True, help=f"one of: {', '.join(SERIES)}")
    add_parser.add_argument("--arch", required=True, help=f"one of: {', '.join(ARCHES)}")

    build_parser = commands.add_parser("build", help="regenerate everything derived from docs/")
    build_parser.add_argument(
        "--check", action="store_true", help="report a stale tree instead of writing to it"
    )

    args = parser.parse_args()
    if args.command == "add":
        add(args.zip, args.series, args.arch)
    else:
        build(args.check)


if __name__ == "__main__":
    main()
