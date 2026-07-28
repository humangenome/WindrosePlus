#!/usr/bin/env python3
"""verify-published-artifacts.py - never-publish assertion for this repo's release assets.

GENERATED FILE - do not hand-edit. A scheduled out-of-band scan compares this file's
sha256 against its generated source and alerts on drift, so local edits will be flagged.

Asserts the never-publish policy over the entries of an archive, read from the archive's
own central directory. It never classifies by filename or byte count.

Usage:
  verify-published-artifacts.py <archive> [<archive> ...]     check local archives
  verify-published-artifacts.py --release <tag>               check every asset on a release
                                                              (needs gh on PATH)
It reads entry NAMES, entry CRCs and entry CONTENT (ASCII and UTF-16LE). A layout-only
guard passes an archive whose files carry private text, which is exactly how a
structurally perfect package once shipped a host mod whose comment header named internal
code paths. This one opens every member.

Exit: 0 clean, 1 violation, 2 error. Fails closed on anything it cannot read.
"""
import fnmatch, json, os, re, subprocess, sys, tarfile, tempfile, zipfile

MAX_MEMBER = 128 * 1024 * 1024
SKIP_PREFIXES = [
    "ue4ss/ue4ss_signatures/",
    "app/ue4ss/ue4ss_signatures/",
    "ue4ss-client/ue4ss_signatures/",
    "ue4ss-server/ue4ss_signatures/"
]
REPO_RULES = {
    "entry_deny": [
        {
            "id": "HEARTH-BWHOST",
            "re": "(?i)(^|/)bw_host(/|$)",
            "desc": "Bellwright host mod (RULE #21d)"
        },
        {
            "id": "CAULDRON-STEAMEMU",
            "re": "(?i)(goldberg|gbe_fork|steam_api64|steam_settings|steam_interfaces|steamemu|coldclientloader)",
            "desc": "Steam emulator / headless-auth recipe (RULE #21e)"
        },
        {
            "id": "CAULDRON-HOSTPREP",
            "re": "(?i)(Cauldron\\.HostPrep|SteamEosHostLaunchPrep)",
            "desc": "private Cauldron host-launch-prep implementation (RULE #21e)"
        },
        {
            "id": "LANTERN-HOSTPATCH-SRC",
            "re": "(?i)LanternHostPatch[^/]*\\.(cpp|cxx|cc|h|hpp|hxx|lib|exp|pdb)$",
            "desc": "LanternHostPatch source (RULE #21c)"
        }
    ],
    "entry_crc_deny": [
        {
            "id": "HEARTH-SIG-SERVER",
            "re": "(?i)UE4SS_Signatures/GUObjectHashTables\\.lua$",
            "crc": 2631040471,
            "desc": "SERVER-variant Bellwright signature pack (RULE #21d)"
        }
    ]
}


def _allowed(rule, member):
    pats = rule.get("allow_files")
    if not pats:
        return False
    m = member.replace("\\", "/").lower()
    return any(fnmatch.fnmatch(os.path.basename(m), p) or fnmatch.fnmatch(m, p) for p in pats)


def _skipped(member):
    m = member.replace("\\", "/").lower()
    return any(m.startswith(p) or ("/" + p) in m for p in SKIP_PREFIXES)


def _strings(blob, n=6):
    out = []
    for mm in re.finditer(rb"[\x20-\x7e]{%d,}" % n, blob):
        out.append(mm.group().decode("ascii", "replace"))
    for mm in re.finditer(rb"(?:[\x20-\x7e]\x00){%d,}" % n, blob):
        out.append(mm.group().decode("utf-16-le", "replace"))
    return "\n".join(out)


def scan_member(member, blob, out):
    """Read CONTENT, in ASCII and UTF-16. A layout guard never opens a file; that is how a
    structurally perfect package shipped a comment header naming internal code paths."""
    if _skipped(member):
        return
    for r in REPO_RULES.get("token_deny", []):
        if _allowed(r, member):
            continue
        for tok in r["tokens"]:
            hits = []
            if tok.encode("utf-8", "ignore") in blob:
                hits.append("ascii")
            if tok.encode("utf-16-le", "ignore") in blob:
                hits.append("utf-16")
            if hits:
                out.append((r["id"], r["desc"],
                            "content of %s: %r (%s)" % (member, tok, "+".join(hits))))
    rules = REPO_RULES.get("text_deny", []) + REPO_RULES.get("binary_deny", [])
    if not rules:
        return
    texty = blob[:4096].count(b"\x00") == 0 and len(blob) <= 4 * 1024 * 1024
    text = blob.decode("utf-8", "replace") if texty else _strings(blob)
    for r in rules:
        if _allowed(r, member):
            continue
        mm = re.search(r["re"], text)
        if mm:
            out.append((r["id"], r["desc"],
                        "content of %s: %r" % (member, mm.group()[:120])))


def entries_of(path):
    low = path.lower()
    if low.endswith((".tar.gz", ".tgz", ".tar")):
        mode = "r:gz" if low.endswith((".tar.gz", ".tgz")) else "r:"
        with tarfile.open(path, mode) as tf:
            return [{"name": m.name, "size": m.size, "crc": None} for m in tf.getmembers()]
    with zipfile.ZipFile(path) as zf:
        bad = zf.testzip()
        if bad:
            raise RuntimeError("corrupt member: %s" % bad)
        return [{"name": i.filename, "size": i.file_size, "crc": i.CRC} for i in zf.infolist()]


def read_members(path, out):
    low = path.lower()
    if low.endswith((".tar.gz", ".tgz", ".tar")):
        mode = "r:gz" if low.endswith((".tar.gz", ".tgz")) else "r:"
        with tarfile.open(path, mode) as tf:
            for m in tf.getmembers():
                if m.isfile() and m.size <= MAX_MEMBER:
                    scan_member(m.name, tf.extractfile(m).read(), out)
        return
    if low.endswith(".zip"):
        with zipfile.ZipFile(path) as zf:
            for i in zf.infolist():
                if not i.is_dir() and i.file_size <= MAX_MEMBER:
                    scan_member(i.filename, zf.read(i), out)
        return
    if os.path.getsize(path) <= MAX_MEMBER:
        with open(path, "rb") as f:
            scan_member(os.path.basename(path), f.read(), out)


def check(path):
    name = os.path.basename(path)
    out = []
    for r in REPO_RULES.get("asset_name_deny", []):
        if re.search(r["re"], name):
            out.append((r["id"], r["desc"], "asset filename: %s" % name))
    low = name.lower()
    if any(low.endswith(x) for x in (".zip", ".tar.gz", ".tgz", ".tar")):
        try:
            ents = entries_of(path)
        except Exception as exc:
            return out + [("SCAN-UNREADABLE", "archive could not be read - fails closed", str(exc)[:200])]
        if not ents:
            return out + [("SCAN-EMPTY", "archive parsed to zero entries - fails closed", name)]
        names = [e["name"] for e in ents]
        for r in REPO_RULES.get("entry_deny", []):
            rx = re.compile(r["re"])
            for e in ents:
                if rx.search(e["name"]):
                    out.append((r["id"], r["desc"], "entry: %s (%d bytes)" % (e["name"], e["size"])))
        for r in REPO_RULES.get("entry_crc_deny", []):
            rx = re.compile(r["re"])
            for e in ents:
                if e["crc"] is not None and e["crc"] == r["crc"] and rx.search(e["name"]):
                    out.append((r["id"], r["desc"], "entry: %s crc32=%d" % (e["name"], e["crc"])))
        for r in REPO_RULES.get("entry_cooccur_deny", []):
            trig = re.compile(r["if_re"])
            if any(trig.search(n) for n in names):
                then = re.compile(r["then_re"])
                for e in ents:
                    if then.search(e["name"]):
                        out.append((r["id"], r["desc"], "entry: %s" % e["name"]))
    try:
        read_members(path, out)
    except Exception as exc:
        out.append(("SCAN-CONTENT-FAILED", "content scan failed - fails closed", str(exc)[:200]))
    return out


def main():
    args = sys.argv[1:]
    if not args:
        print("usage: verify-published-artifacts.py <archive>... | --release <tag>")
        return 2
    paths = []
    tmp = None
    if args[0] == "--release":
        if len(args) < 2:
            print("--release needs a tag")
            return 2
        tag = args[1]
        # Ask what the release actually has BEFORE downloading. A release with zero assets
        # is a normal state (an asset can be removed), and `gh release download` exits
        # non-zero on it - treating that as a scan failure is cry-wolf, and a scanner that
        # cries wolf is one nobody reads. A real download failure below still fails closed.
        q = subprocess.run(["gh", "release", "view", tag, "--json", "assets"],
                           capture_output=True, text=True)
        if q.returncode != 0:
            print("could not read release %s: %s" % (tag, q.stderr.strip()[:300]))
            return 2
        try:
            n_assets = len(json.loads(q.stdout).get("assets") or [])
        except Exception as exc:
            print("could not parse release %s: %s" % (tag, exc))
            return 2
        if n_assets == 0:
            print("release %s has no assets" % tag)
            return 0
        tmp = tempfile.mkdtemp(prefix="pubscan-")
        p = subprocess.run(["gh", "release", "download", tag, "--dir", tmp, "--clobber"],
                           capture_output=True, text=True)
        if p.returncode != 0:
            print("could not download release %s: %s" % (tag, p.stderr.strip()[:300]))
            return 2
        paths = [os.path.join(tmp, f) for f in sorted(os.listdir(tmp))]
        if len(paths) != n_assets:
            print("release %s: expected %d assets, downloaded %d - failing closed"
                  % (tag, n_assets, len(paths)))
            return 2
    else:
        paths = args

    bad = 0
    for path in paths:
        hits = check(path)
        if hits:
            bad += len(hits)
            print("FAIL %s" % os.path.basename(path))
            for rid, desc, where in hits:
                print("   %-24s %s" % (rid, desc))
                print("   %-24s %s" % ("", where))
        else:
            print("OK   %s" % os.path.basename(path))
    if bad:
        print("\nREFUSING: %d never-publish violation(s). Do not publish or leave this asset up." % bad)
        return 1
    print("\n%d asset(s) checked, no never-publish violations." % len(paths))
    return 0


if __name__ == "__main__":
    sys.exit(main())
