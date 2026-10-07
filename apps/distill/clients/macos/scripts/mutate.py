#!/usr/bin/env python3
"""Mutation testing for the Distill Swift package (Muter needs a newer Xcode).

Applies one classic mutation at a time to a source file, rebuilds, runs only the
tests that exercise that file, and reports which mutants the tests killed.

    apps/distill/clients/macos/scripts/mutate.py \
        --file Sources/DistillKit/ActionsFilters.swift --filter ActionsFiltersTests

Safety: mutants are applied in throwaway copies of the package (under
--workdir, outside the repository), never in this checkout. Each mutant is
written in a try/finally that puts the pristine file back and checks its hash
before the next one.

Scoring: a mutant whose build fails is "invalid" and left out of the score;
one whose filtered tests fail (or crash, or time out) is "killed"; one whose
tests all pass "survived". Score = killed / (killed + survived).

Operators (code only: never inside string literals or comments):
  ror   flip == / !=, < / <=, > / >= (spaced binary operators only)
  lcr   && <-> ||
  neg   drop a prefix ! ; `.isEmpty` -> `.isEmpty == false`
  bool  true <-> false
  aor   + <-> - (spaced, not next to a string literal)
  ret   `return "..."` -> `return ""`; `return <int>` -> another int
  stmt  delete a lone assignment or call statement line
"""
from __future__ import annotations

import argparse
import concurrent.futures as cf
import hashlib
import json
import os
import re
import signal
import subprocess
import sys
import threading
import time
from dataclasses import dataclass, asdict
from pathlib import Path

PACKAGE = Path(__file__).resolve().parent.parent
DEFAULT_WORKDIR = Path(os.environ.get("TMPDIR", "/tmp")) / "distill-mutate"


# MARK: Lexing: which characters are code


def code_mask(src: str) -> list[bool]:
    """True for characters that are code; False inside comments and string literals
    (interpolations included: a string is treated as one opaque token)."""
    mask = [True] * len(src)
    i, n = 0, len(src)

    def blank(a: int, b: int) -> None:
        for k in range(a, min(b, n)):
            mask[k] = False

    while i < n:
        c = src[i]
        if src.startswith("//", i):
            j = src.find("\n", i)
            j = n if j < 0 else j
            blank(i, j)
            i = j
        elif src.startswith("/*", i):
            depth, j = 1, i + 2
            while j < n and depth:
                if src.startswith("/*", j):
                    depth, j = depth + 1, j + 2
                elif src.startswith("*/", j):
                    depth, j = depth - 1, j + 2
                else:
                    j += 1
            blank(i, j)
            i = j
        elif c == '"' or (c == "#" and re.match(r'#+"', src[i:])):
            j = string_end(src, i)
            blank(i, j)
            i = j
        else:
            i += 1
    return mask


def string_end(src: str, i: int) -> int:
    """Index just past the string literal starting at i (handles #raw, multi-line and \\( ) nesting)."""
    hashes = 0
    while src[i] == "#":
        hashes, i = hashes + 1, i + 1
    multi = src.startswith('"""', i)
    quote = '"""' if multi else '"'
    close = quote + "#" * hashes
    escape = "\\" + "#" * hashes
    j = i + len(quote)
    n = len(src)
    while j < n:
        if src.startswith(escape + "(", j):
            # Interpolation: skip to the matching paren (strings inside are skipped too).
            j += len(escape) + 1
            depth = 1
            while j < n and depth:
                ch = src[j]
                if ch == '"' or (ch == "#" and re.match(r'#+"', src[j:])):
                    j = string_end(src, j)
                    continue
                depth += {"(": 1, ")": -1}.get(ch, 0)
                j += 1
            continue
        if src.startswith(escape, j):
            j += len(escape) + 1
            continue
        if src.startswith(close, j):
            return j + len(close)
        if not multi and src[j] == "\n":
            return j
        j += 1
    return n


# MARK: Mutants


@dataclass
class Mutant:
    id: int
    op: str
    line: int
    start: int
    end: int
    replacement: str
    original: str
    before: str = ""
    after: str = ""
    status: str = "pending"
    seconds: float = 0.0
    detail: str = ""


SPACED = [
    ("ror", " == ", " != "), ("ror", " != ", " == "),
    ("ror", " < ", " <= "), ("ror", " <= ", " < "),
    ("ror", " > ", " >= "), ("ror", " >= ", " > "),
    ("lcr", " && ", " || "), ("lcr", " || ", " && "),
    ("aor", " + ", " - "), ("aor", " - ", " + "),
]
STMT_SKIP = re.compile(r"^(let|var|return|if|guard|else|case|default|func|for|while|switch|do|try|throw|defer|"
                       r"public|private|fileprivate|internal|static|struct|enum|class|extension|init|"
                       r"import|@|}|\{|\)|\]|#|break|continue|fallthrough|where)\b")
STMT_CALL = re.compile(r"^[A-Za-z_][\w.]*(\[[^\]]*\])?(\.[A-Za-z_]\w*)*\s*(\(.*\)|\s[-+*/]?=\s.+)$")


def all_code(mask: list[bool], a: int, b: int) -> bool:
    return all(mask[a:b])


def negated(src: str, pos: int) -> bool:
    """Whether the expression ending at pos starts with a prefix ! (then `.isEmpty == false`
    would only repeat the `neg` mutant that drops the !)."""
    depth, k = 0, pos - 1
    while k >= 0:
        ch = src[k]
        if ch in ")]":
            depth += 1
        elif ch in "([":
            if depth == 0:
                break
            depth -= 1
        elif depth == 0 and (ch.isspace() or ch in "{,"):
            break
        k -= 1
    return src[k + 1:k + 2] == "!"


def generate(src: str, ops: set[str], lines: set[int] | None) -> list[Mutant]:
    mask = code_mask(src)
    starts = [0]
    for k, ch in enumerate(src):
        if ch == "\n":
            starts.append(k + 1)
    out: list[Mutant] = []

    def line_of(pos: int) -> int:
        lo, hi = 0, len(starts) - 1
        while lo < hi:
            mid = (lo + hi + 1) // 2
            if starts[mid] <= pos:
                lo = mid
            else:
                hi = mid - 1
        return lo + 1

    def add(op: str, a: int, b: int, rep: str) -> None:
        ln = line_of(a)
        if lines and ln not in lines:
            return
        out.append(Mutant(id=0, op=op, line=ln, start=a, end=b, replacement=rep, original=src[a:b]))

    for op, frm, to in SPACED:
        if op not in ops:
            continue
        for m in re.finditer(re.escape(frm), src):
            a, b = m.start(), m.end()
            if not all_code(mask, a, b):
                continue
            if op == "aor":
                left = src[a - 1] if a else ""
                right = src[b] if b < len(src) else ""
                if '"' in (left, right) or not mask[a - 1] or (b < len(src) and not mask[b]):
                    continue
            add(op, a, b, to)

    if "lcr" in ops:
        pass  # covered in SPACED

    if "neg" in ops:
        for m in re.finditer(r"(?<=[\s(\[{,])!(?=[A-Za-z_$(.])", src):
            if all_code(mask, m.start(), m.end()):
                add("neg", m.start(), m.end(), "")
        for m in re.finditer(r"\.isEmpty\b(?!\s*[=!]=)", src):
            if all_code(mask, m.start(), m.end()) and not src[max(0, m.start() - 1)] == "\\" and not negated(src, m.start()):
                add("neg", m.start(), m.end(), ".isEmpty == false")

    if "bool" in ops:
        for m in re.finditer(r"\b(true|false)\b", src):
            if all_code(mask, m.start(), m.end()):
                add("bool", m.start(), m.end(), "false" if m.group() == "true" else "true")

    if "ret" in ops:
        for m in re.finditer(r"\breturn (\"[^\"\\\n]+\"|\d+)(?=\s*($|[}\n;]))", src, re.M):
            if not mask[m.start()]:
                continue
            a, b = m.start(1), m.end(1)
            val = m.group(1)
            rep = '""' if val.startswith('"') else str(int(val) + 1 if int(val) == 0 else 0)
            add("ret", a, b, rep)

    if "stmt" in ops:
        for idx, a in enumerate(starts):
            b = starts[idx + 1] - 1 if idx + 1 < len(starts) else len(src)
            text = src[a:b]
            stripped = text.strip()
            if not stripped or not mask[a + len(text) - len(text.lstrip())]:
                continue
            if STMT_SKIP.match(stripped) or stripped.endswith(("{", ",", "(", "[")) or "{" in stripped or "}" in stripped:
                continue
            if stripped.count("(") != stripped.count(")") or stripped.count("[") != stripped.count("]"):
                continue
            if not STMT_CALL.match(stripped):
                continue
            # The previous line must end a statement (not continue an expression).
            prev = src[starts[idx - 1]:a].rstrip() if idx else ""
            if prev.endswith(("=", "+", "-", "&&", "||", "?", ":", ",", "(", ".")) or stripped.startswith("."):
                continue
            lead = len(text) - len(text.lstrip())
            add("stmt", a + lead, b, "")

    out.sort(key=lambda m: (m.start, m.op))
    for k, m in enumerate(out, 1):
        m.id = k
        ls = src.rfind("\n", 0, m.start) + 1
        le = src.find("\n", m.end)
        le = len(src) if le < 0 else le
        m.before = src[ls:le].strip()
        m.after = (src[ls:m.start] + m.replacement + src[m.end:le]).strip()
    return out


# MARK: Running


def sha(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


KIT_ONLY_PACKAGE = """// swift-tools-version:5.10
// Written by scripts/mutate.py --kit-only: DistillKit and its tests alone, so a mutant
// rebuilds one module and links a small test bundle.
import PackageDescription

let package = Package(
    name: "Distill",
    platforms: [.macOS(.v14)],
    targets: [
        .target(name: "DistillKit"),
        .testTarget(name: "DistillKitTests", dependencies: ["DistillKit"]),
    ]
)
"""


def sync_copy(dest: Path, kit_only: bool) -> None:
    dest.mkdir(parents=True, exist_ok=True)
    excludes = ["--exclude", ".build", "--exclude", ".swiftpm"]
    if kit_only:
        excludes += ["--exclude", "/Sources/Distill/", "--exclude", "/Tests/DistillTests/", "--exclude", "/Package.swift"]
    subprocess.run(["rsync", "-a", "--delete", *excludes, f"{PACKAGE}/Package.swift", f"{PACKAGE}/Sources", f"{PACKAGE}/Tests",
                    f"{PACKAGE}/Resources", f"{dest}/"], check=True)
    if kit_only:
        (dest / "Package.swift").write_text(KIT_ONLY_PACKAGE)
    # Shared fixtures a test reads five levels above itself (SlackTargetTests: apps/distill/core/…/*.cases.json).
    shared = PACKAGE.parent.parent / "core" / "src" / "actions"
    mirror = dest.parent.parent / "core" / "src" / "actions"
    for case in shared.glob("*.cases.json"):
        mirror.mkdir(parents=True, exist_ok=True)
        (mirror / case.name).write_bytes(case.read_bytes())


def run(cmd: list[str], cwd: Path, timeout: int) -> tuple[int | None, str]:
    try:
        p = subprocess.run(cmd, cwd=cwd, capture_output=True, text=True, timeout=timeout)
        return p.returncode, p.stdout + p.stderr
    except subprocess.TimeoutExpired as e:
        out = (e.stdout or b"")
        return None, out.decode() if isinstance(out, bytes) else out


def build(copy: Path) -> tuple[bool, str]:
    code, out = run(["swift", "build", "--build-tests"], copy, 900)
    return code == 0, out


def test(copy: Path, filt: str, timeout: int) -> tuple[str, str]:
    code, out = run(["swift", "test", "--skip-build", "--filter", filt], copy, timeout)
    if code is None:
        return "killed", "timeout"
    executed = [int(x) for x in re.findall(r"Executed (\d+) tests?", out)]
    if code == 0:
        if not executed or max(executed) == 0:
            return "error", "no tests ran"
        return "survived", ""
    failure = next((l.strip() for l in out.splitlines() if ": error: " in l), "")
    return "killed", failure[-300:] or f"exit {code}"


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--file", required=True, help="source file, relative to the package (Sources/DistillKit/X.swift)")
    ap.add_argument("--filter", required=True, help="swift test --filter regex: every test class that exercises the file")
    ap.add_argument("--ops", default="ror,lcr,neg,bool,aor,ret,stmt")
    ap.add_argument("--lines", default="", help="only these lines: 10-40,55")
    ap.add_argument("--only", default="", help="only these mutant ids: 3,7,12")
    ap.add_argument("--jobs", type=int, default=3, help="package copies building in parallel")
    ap.add_argument("--workdir", type=Path, default=DEFAULT_WORKDIR)
    ap.add_argument("--out", type=Path, help="write the JSON report here")
    ap.add_argument("--timeout", type=int, default=300, help="seconds per test run (a timeout counts as killed)")
    ap.add_argument("--list", action="store_true", help="print the mutants and stop")
    ap.add_argument("--kit-only", action="store_true",
                    help="copies hold only DistillKit and DistillKitTests (faster; the filter must name DistillKitTests classes)")
    ap.add_argument("--resume", action="store_true", help="keep the decided mutants already in --out (same file contents)")
    args = ap.parse_args()

    rel = Path(args.file)
    src_path = PACKAGE / rel
    pristine = src_path.read_text()
    pristine_hash = hashlib.sha256(pristine.encode()).hexdigest()
    lines: set[int] = set()
    for part in filter(None, args.lines.split(",")):
        a, _, b = part.partition("-")
        lines.update(range(int(a), int(b or a) + 1))
    mutants = generate(pristine, set(args.ops.split(",")), lines or None)
    if args.only:
        keep = {int(x) for x in args.only.split(",")}
        mutants = [m for m in mutants if m.id in keep]
    decided: dict[int, Mutant] = {}
    if args.resume and args.out and args.out.exists():
        old = json.loads(args.out.read_text())
        if old.get("sha256") == pristine_hash and old.get("filter") == args.filter:
            decided = {d["id"]: Mutant(**d) for d in old["mutants"] if d["status"] in ("killed", "survived", "invalid")}
    todo = [m for m in mutants if m.id not in decided]
    if args.list:
        for m in mutants:
            print(f"#{m.id:<4} {m.op:<5} L{m.line:<5} {m.before}\n{'':17}-> {m.after}")
        print(f"{len(mutants)} mutants")
        return 0

    jobs = max(1, min(args.jobs, len(todo) or 1))
    copies = [args.workdir / f"{'kit' if args.kit_only else 'copy'}-{k}" for k in range(jobs)]
    print(f"{rel}: {len(mutants)} mutants ({len(decided)} already decided), {jobs} copies under {args.workdir}", flush=True)

    # Whatever stops this run (Ctrl-C, SIGTERM), every copy gets the pristine file back.
    def restore_all(*_: object) -> None:
        for copy in copies:
            target = copy / rel
            if target.exists() and sha(target) != pristine_hash:
                target.write_text(pristine)
        if _:
            os._exit(130)

    signal.signal(signal.SIGTERM, restore_all)
    signal.signal(signal.SIGINT, restore_all)
    signal.signal(signal.SIGHUP, restore_all)

    def report(results: list[Mutant]) -> dict:
        counts = {s: sum(1 for m in results if m.status == s) for s in ("killed", "survived", "invalid", "error")}
        valid = counts["killed"] + counts["survived"]
        score = 100.0 * counts["killed"] / valid if valid else 0.0
        if args.out:
            args.out.parent.mkdir(parents=True, exist_ok=True)
            args.out.write_text(json.dumps({"file": str(rel), "filter": args.filter, "sha256": pristine_hash, "counts": counts,
                                            "score": round(score, 1), "mutants": [asdict(m) for m in sorted(results, key=lambda m: m.id)]},
                                           indent=1))
        return {"counts": counts, "score": score}

    def prepare(copy: Path) -> None:
        sync_copy(copy, args.kit_only)
        ok, out = build(copy)
        if not ok:
            raise SystemExit(f"pristine build failed in {copy}:\n{out[-2000:]}")
        status, detail = test(copy, args.filter, args.timeout)
        if status != "survived":
            raise SystemExit(f"pristine tests must pass in {copy} ({status}: {detail})")

    with cf.ThreadPoolExecutor(jobs) as ex:
        list(ex.map(prepare, copies))
    print("baseline: pristine build and filtered tests pass", flush=True)

    free: list[Path] = list(copies)
    lock = threading.Lock()
    done = [0]
    finished: list[Mutant] = list(decided.values())

    def one(m: Mutant) -> Mutant:
        with lock:
            copy = free.pop()
        target = copy / rel
        t0 = time.time()
        try:
            target.write_text(pristine[:m.start] + m.replacement + pristine[m.end:])
            ok, out = build(copy)
            if not ok:
                m.status = "invalid"
                m.detail = next((l.strip() for l in out.splitlines() if "error:" in l), "")[-200:]
            else:
                m.status, m.detail = test(copy, args.filter, args.timeout)
        finally:
            target.write_text(pristine)
            if sha(target) != pristine_hash:
                raise SystemExit(f"could not restore {target}")
            m.seconds = round(time.time() - t0, 1)
            with lock:
                free.append(copy)
                done[0] += 1
                finished.append(m)
                report(finished)
                why = f"  ({m.detail[:140]})" if m.status in ("invalid", "error") else ""
                print(f"[{done[0]}/{len(todo)}] #{m.id} {m.op} L{m.line} {m.status} {m.seconds}s: {m.after[:110]}{why}", flush=True)
        return m

    with cf.ThreadPoolExecutor(jobs) as ex:
        list(ex.map(one, todo))
    results = sorted(finished, key=lambda m: m.id)

    # Leave every copy pristine and built, ready for the next run.
    for copy in copies:
        if sha(copy / rel) != pristine_hash:
            raise SystemExit(f"{copy / rel} is not pristine")
    if sha(src_path) != pristine_hash:
        raise SystemExit(f"{src_path} changed during the run")

    r = report(results)
    counts, score = r["counts"], r["score"]
    print(f"\n{rel}: killed {counts['killed']}, survived {counts['survived']}, invalid {counts['invalid']}, "
          f"error {counts['error']}; score {score:.1f}%")
    for m in results:
        if m.status in ("survived", "error"):
            print(f"  {m.status.upper()} #{m.id} {m.op} L{m.line}: {m.before}\n{'':12}-> {m.after}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
