#!/usr/bin/env python3
"""Pack a web-wallpaper source dir into a .livewallpaper zip.

Layout expected under <src>/:
    manifest.json
    content/...            (the payload; for web: content/web/index.html)

Computes `checksum` over the content/ payload per docs/PACKAGE_FORMAT.md
(the frozen v1 algorithm), stamps it into the manifest, and writes a zip.

Usage: python3 pack.py <src-dir> <out.livewallpaper>
"""
import hashlib, json, os, sys, zipfile


def content_checksum(content_dir: str) -> str:
    # 1. every regular file under content/, path relative to content/
    rels = []
    for root, _dirs, files in os.walk(content_dir):
        for name in files:
            if name == ".DS_Store":
                continue
            full = os.path.join(root, name)
            rels.append(os.path.relpath(full, content_dir))
    # 2. sort ascending by raw utf-8 bytes
    rels.sort(key=lambda p: p.encode("utf-8"))
    h = hashlib.sha256()
    for rel in rels:
        # 3. utf-8 relative path (posix separators) + 0x00 + file bytes
        h.update(rel.replace(os.sep, "/").encode("utf-8"))
        h.update(b"\x00")
        with open(os.path.join(content_dir, rel), "rb") as f:
            h.update(f.read())
    # 4. "sha256-" + lowercase hex
    return "sha256-" + h.hexdigest()


def main() -> int:
    if len(sys.argv) != 3:
        print(__doc__)
        return 2
    src, out = sys.argv[1], sys.argv[2]
    content_dir = os.path.join(src, "content")
    if not os.path.isdir(content_dir):
        print(f"missing {content_dir}", file=sys.stderr)
        return 1

    manifest = json.load(open(os.path.join(src, "manifest.json")))
    manifest["checksum"] = content_checksum(content_dir)

    with zipfile.ZipFile(out, "w", zipfile.ZIP_DEFLATED) as z:
        z.writestr("manifest.json", json.dumps(manifest, indent=2))
        for root, _dirs, files in os.walk(content_dir):
            for name in files:
                if name == ".DS_Store":
                    continue
                full = os.path.join(root, name)
                arc = os.path.relpath(full, src).replace(os.sep, "/")
                z.write(full, arc)
    print(f"wrote {out}  ({manifest['checksum']})")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
