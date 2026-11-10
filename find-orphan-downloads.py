#!/usr/bin/env python3
# find-orphan-downloads.py  ---  READ-ONLY discovery tool.  DELETES NOTHING.
#
# Finds large *media* files under the qBittorrent downloads tree that are:
#   (a) NOT part of any torrent qBittorrent currently manages  (authoritative:
#       queried live from the qBittorrent WebUI API), AND
#   (b) have link count == 1  (not hardlinked into the media library, so removing
#       them would actually reclaim space and they are not shared with anything), AND
#   (c) match a positive media-extension allowlist  (never archives/par2/nfo/subs).
#
# Rationale: releases are often downloaded as .rar sets and then unpacked. qBittorrent
# only needs the archive parts (they ARE in the torrent). The unpacked media files are
# NOT in any torrent, and once the *arr apps have imported them (usually by copy or
# hardlink) the download-side copy is reclaimable.
#
# SAFETY (by construction):
#   * There is deliberately NO os.remove/unlink/rename/rmdir/open-for-write/shutil
#     anywhere in this file. It cannot modify the filesystem even with a logic bug.
#   * If the qbit API is unreachable or returns 0 torrents, it ABORTS (a false-empty
#     "managed" set is the only way this logic could ever misclassify files, so we
#     refuse to run in that state).
#   * Any torrent whose file list can't be fetched has its whole folder EXCLUDED from
#     candidates (we never guess about a folder we couldn't fully enumerate).
#   * Only regular files strictly under the downloads root are considered; symlinks are
#     never followed and never flagged.
#
# Intended to run INSIDE the qbit container (sees both localhost:8080 and /downloads).
import os, sys, json, stat as statmod, posixpath, urllib.request

API       = os.environ.get("QBIT_API", "http://localhost:8080/api/v2")
DL_ROOT   = os.environ.get("DL_ROOT", "/downloads")               # path as the container sees it
HOST_ROOT = os.environ.get("HOST_ROOT", "/pool1/media/downloads") # path on the host (display only)
MIN_BYTES = int(os.environ.get("MIN_MB", "200")) * 1024 * 1024
MEDIA_EXT = {".mkv", ".mp4", ".avi", ".m2ts", ".ts", ".mov", ".m4v",
             ".wmv", ".mpg", ".mpeg", ".flv", ".vob", ".iso", ".divx"}

def api_get(path):
    with urllib.request.urlopen(API + path, timeout=30) as r:
        return json.load(r)

def human(n):
    for u in ("B", "KiB", "MiB", "GiB", "TiB"):
        if n < 1024 or u == "TiB":
            return f"{n:.1f}{u}" if u != "B" else f"{n}B"
        n /= 1024.0

def hostify(p):
    return HOST_ROOT + p[len(DL_ROOT):] if p.startswith(DL_ROOT) else p

def main():
    if not os.path.isdir(DL_ROOT):
        print(f"FATAL: downloads root {DL_ROOT!r} is not a directory.", file=sys.stderr); sys.exit(5)

    # 1) Authoritative list of files qbit manages ----------------------------
    try:
        torrents = api_get("/torrents/info")
    except Exception as e:
        print(f"FATAL: qbit API /torrents/info failed ({e}); refusing to run.", file=sys.stderr); sys.exit(2)
    if not isinstance(torrents, list) or len(torrents) == 0:
        print("FATAL: qbit reported 0 torrents; refusing to run (would misclassify every "
              "file as an orphan).", file=sys.stderr); sys.exit(3)

    managed = set()          # exact absolute file paths qbit requires
    failed_roots = []        # content_path of torrents we could not fully enumerate
    fetch_errors = 0
    for t in torrents:
        h  = t.get("hash")
        sp = t.get("save_path") or ""
        cp = t.get("content_path") or ""
        try:
            files = api_get(f"/torrents/files?hash={h}")
        except Exception:
            fetch_errors += 1
            if cp:
                failed_roots.append(posixpath.normpath(cp))
            continue
        for f in files:
            name = f.get("name")
            if name:
                managed.add(posixpath.normpath(posixpath.join(sp, name)))

    if len(managed) == 0:
        print("FATAL: managed file set came back empty; refusing to run.", file=sys.stderr); sys.exit(4)

    # 2) Walk the downloads tree (read-only) ---------------------------------
    candidates = []               # (size, path)
    total_media = 0               # total bytes of all media files we saw
    total_media_files = 0
    skipped_uncertain = 0
    for dirpath, dirs, files in os.walk(DL_ROOT, followlinks=False):
        for fn in files:
            p = os.path.join(dirpath, fn)
            try:
                st = os.lstat(p)
            except OSError:
                continue
            if not statmod.S_ISREG(st.st_mode):     # skip symlinks/specials; never follow
                continue
            ext = os.path.splitext(fn)[1].lower()
            if ext not in MEDIA_EXT:
                continue
            total_media += st.st_size
            total_media_files += 1
            if st.st_size < MIN_BYTES:
                continue
            if st.st_nlink != 1:                     # hardlinked (shared) -> not reclaimable, skip
                continue
            np = posixpath.normpath(p)
            if np in managed:                        # qbit needs it -> skip
                continue
            if any(np == r or np.startswith(r + "/") for r in failed_roots):
                skipped_uncertain += 1               # couldn't verify this torrent -> be safe, skip
                continue
            candidates.append((st.st_size, np))

    candidates.sort(reverse=True)
    reclaim = sum(s for s, _ in candidates)

    # 3) Report (stdout only; nothing is modified) ---------------------------
    print("=" * 78)
    print("READ-ONLY orphaned-download report  (NOTHING has been or will be deleted)")
    print("=" * 78)
    print(f"downloads root      : {HOST_ROOT}  (container: {DL_ROOT})")
    print(f"torrents in qbit    : {len(torrents)}")
    print(f"files qbit requires : {len(managed)}")
    if fetch_errors:
        print(f"torrents unreadable : {fetch_errors}  (their folders EXCLUDED from candidates)")
    print(f"media files seen    : {total_media_files}  totalling {human(total_media)}")
    print(f"size threshold      : >= {MIN_BYTES // (1024*1024)} MiB")
    print(f"media allowlist     : {' '.join(sorted(MEDIA_EXT))}")
    if skipped_uncertain:
        print(f"skipped (uncertain) : {skipped_uncertain} file(s) in unreadable-torrent folders")
    print("-" * 78)
    print(f"CANDIDATES (orphan media, nlink==1, not required by qbit): {len(candidates)}")
    print(f"RECLAIMABLE IF REMOVED: {human(reclaim)}")
    print("-" * 78)
    for size, p in candidates:
        print(f"{human(size):>10}  {hostify(p)}")
    print("-" * 78)
    print("Review this list before ANY deletion. This script does not delete.")

if __name__ == "__main__":
    main()
