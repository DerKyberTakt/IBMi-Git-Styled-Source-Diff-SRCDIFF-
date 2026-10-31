#!/usr/bin/env python3
"""Reference implementation of the SRCDIFF algorithm.

The RPG module SRCDIFFM mirrors this file step for step, so the rows it
produces on the IBM i can be checked against this script line for line:

    python tools/srcdiff_ref.py OLD.txt NEW.txt [--context 3] [--ignblank]

Output: one row per display line, tab separated:  TYPE  OLDLINE  NEWLINE  TEXT
  TYPE  ' ' context  '-' deleted  '+' added  '@' hunk header  '=' stats line
  OLDLINE / NEWLINE are 1-based line positions (0 when not applicable).

Algorithm
  1. strip common prefix / suffix
  2. patience diff: lines unique on both sides -> longest increasing
     subsequence -> anchors; work list of ranges (no recursion)
  3. a range with no anchors falls back to Myers O(ND), capped at MAXD;
     above the cap the range becomes delete-all / insert-all
  4. edit script -> hunks with CONTEXT lines (git header rules), each
     header followed by the nearest preceding 'function' line (func_text)
"""

import argparse
import sys

MAXD = 2000          # Myers cap, must match SRCDIFFM
WHOLE = 9999         # CONTEXT value meaning "show the whole member"


# ----------------------------------------------------------------- keys
def make_key(text, ignblank):
    """Comparison key for one source line (SRCDTA only)."""
    if ignblank:
        return " ".join(text.split())
    return text.rstrip()


# ------------------------------------------------------- function context
_UP = str.maketrans("abcdefghijklmnopqrstuvwxyz", "ABCDEFGHIJKLMNOPQRSTUVWXYZ")
_LBL1 = set("ABCDEFGHIJKLMNOPQRSTUVWXYZ@#$")
_LBLN = _LBL1 | set("0123456789_")


def func_text(text):
    """Text to show after a hunk header when this line starts a 'function'
    (git funcname); '' otherwise. Mirrors funcText() in SRCDIFFM:

      fixed C-spec   col 6 C, col 7 not *, cols 26-35 = BEGSR   -> from col 6
      fixed P-spec   col 6 P, col 7 not *, col 24 = B           -> from col 6
      DDS record     col 6 A, col 7 not *, col 17 = R           -> from col 6
      free RPG       line or line from col 8 starts DCL-PROC / BEGSR
      CL             line starts SUBR, or a label NAME: (not a /* comment)
    """
    t = text[:100].ljust(100)
    u = t.translate(_UP)
    if u[6] != "*":
        if u[5] == "C" and u[25:35].strip(" ") == "BEGSR":
            return t[5:].strip(" ")
        if u[5] == "P" and u[23] == "B":
            return t[5:].strip(" ")
        if u[5] == "A" and u[16] == "R":
            return t[5:].strip(" ")
    for cand in (t.strip(" "), t[7:].strip(" ")):
        cu = cand.translate(_UP)
        if cu.startswith("DCL-PROC ") or cu.startswith("BEGSR ") or cu.startswith("BEGSR;"):
            return cand
    whole = t.strip(" ")
    wu = whole.translate(_UP)
    if wu.startswith("SUBR "):
        return whole
    if wu and wu[0] in _LBL1:
        k = 1
        while k < len(wu) and k < 10 and wu[k] in _LBLN:
            k += 1
        if k < len(wu) and wu[k] == ":":
            return whole
    return ""


def func_index(a_text):
    """ctx[i] = nearest line <= i (1-based) that is a function line, 0 = none."""
    ctx = [0] * (len(a_text) + 1)
    for i in range(1, len(a_text) + 1):
        ctx[i] = i if func_text(a_text[i - 1]) else ctx[i - 1]
    return ctx


# ----------------------------------------------------------------- myers
def myers(a, alo, ahi, b, blo, bhi):
    """Classic Myers forward diff on a[alo:ahi] vs b[blo:bhi].

    Returns list of ops (type, i, j) with 0-based absolute indexes, or None
    when the edit distance exceeds MAXD.
    """
    n = ahi - alo
    m = bhi - blo
    dmax = min(MAXD, n + m)
    off = dmax                       # v index = k + off
    v = [0] * (2 * dmax + 2)
    v[off + 1] = 0
    trace = []
    found = False
    for d in range(dmax + 1):
        trace.append(v[:])           # snapshot before step d is applied
        for k in range(-d, d + 1, 2):
            if k == -d or (k != d and v[off + k - 1] < v[off + k + 1]):
                x = v[off + k + 1]           # move down (insert)
            else:
                x = v[off + k - 1] + 1       # move right (delete)
            y = x - k
            while x < n and y < m and a[alo + x] == b[blo + y]:
                x += 1
                y += 1
            v[off + k] = x
            if x >= n and y >= m:
                found = True
                break
        if found:
            break
    if not found:
        return None

    # backtrack
    ops = []
    x, y = n, m
    for d in range(len(trace) - 1, -1, -1):
        vv = trace[d]
        k = x - y
        if k == -d or (k != d and vv[off + k - 1] < vv[off + k + 1]):
            pk = k + 1
        else:
            pk = k - 1
        px = vv[off + pk]
        py = px - pk
        while x > px and y > py:
            x -= 1
            y -= 1
            ops.append((" ", alo + x, blo + y))
        if d > 0:
            if x == px:                      # came down: insert b[py]
                ops.append(("+", -1, blo + py))
            else:                            # came right: delete a[px]
                ops.append(("-", alo + px, -1))
        x, y = px, py
    ops.reverse()
    return ops


def replace_all(a, alo, ahi, b, blo, bhi):
    ops = [("-", i, -1) for i in range(alo, ahi)]
    ops += [("+", -1, j) for j in range(blo, bhi)]
    return ops


# -------------------------------------------------------------- patience
def unique_anchors(a, alo, ahi, b, blo, bhi):
    """Pairs (i, j) of lines unique in both ranges, sorted by i then LIS on j."""
    cnt_a = {}
    for i in range(alo, ahi):
        k = a[i]
        cnt_a[k] = (cnt_a[k][0] + 1, i) if k in cnt_a else (1, i)
    cnt_b = {}
    for j in range(blo, bhi):
        k = b[j]
        cnt_b[k] = (cnt_b[k][0] + 1, j) if k in cnt_b else (1, j)
    pairs = []
    for k, (ca, i) in cnt_a.items():
        if ca == 1 and k in cnt_b and cnt_b[k][0] == 1:
            pairs.append((i, cnt_b[k][1]))
    pairs.sort()
    if not pairs:
        return []
    # longest increasing subsequence on j (patience sorting with back links)
    tails = []          # index into pairs of the smallest tail for each length
    prev = [-1] * len(pairs)
    for idx, (_, j) in enumerate(pairs):
        lo, hi = 0, len(tails)
        while lo < hi:
            mid = (lo + hi) // 2
            if pairs[tails[mid]][1] < j:
                lo = mid + 1
            else:
                hi = mid
        if lo > 0:
            prev[idx] = tails[lo - 1]
        if lo == len(tails):
            tails.append(idx)
        else:
            tails[lo] = idx
    out = []
    idx = tails[-1]
    while idx != -1:
        out.append(pairs[idx])
        idx = prev[idx]
    out.reverse()
    return out


def diff_keys(a, b):
    """Edit script for key lists a, b: list of (type, i, j), 0-based."""
    n, m = len(a), len(b)
    ops = []
    # work list of (kind, alo, ahi, blo, bhi); kind 'R' = range to diff,
    # 'E' = range of equal lines (same length both sides) to emit as context
    work = [("R", 0, n, 0, m)]
    while work:
        kind, alo, ahi, blo, bhi = work.pop()
        if kind == "E":
            for t in range(ahi - alo):
                ops.append((" ", alo + t, blo + t))
            continue
        # common prefix
        while alo < ahi and blo < bhi and a[alo] == b[blo]:
            ops.append((" ", alo, blo))
            alo += 1
            blo += 1
        # common suffix (emitted after the middle -> push as one equal range)
        tail = []
        s = 0
        while alo < ahi - s and blo < bhi - s and a[ahi - 1 - s] == b[bhi - 1 - s]:
            s += 1
        if s:
            tail.append(("E", ahi - s, ahi, bhi - s, bhi))
            ahi -= s
            bhi -= s
        if alo == ahi and blo == bhi:
            pass
        elif alo == ahi:
            ops += [("+", -1, j) for j in range(blo, bhi)]
        elif blo == bhi:
            ops += [("-", i, -1) for i in range(alo, ahi)]
        else:
            anchors = unique_anchors(a, alo, ahi, b, blo, bhi)
            if not anchors:
                res = myers(a, alo, ahi, b, blo, bhi)
                if res is None:
                    res = replace_all(a, alo, ahi, b, blo, bhi)
                ops += res
            else:
                # push in reverse so the first gap is processed next
                segs = []
                ca, cb = alo, blo
                for (i, j) in anchors:
                    segs.append(("R", ca, i, cb, j))
                    segs.append(("E", i, i + 1, j, j + 1))
                    ca, cb = i + 1, j + 1
                segs.append(("R", ca, ahi, cb, bhi))
                tail = tail + list(reversed(segs))
        # tail = [suffix equal range] + segments in reverse order, so the
        # pops come out as: segments in forward order, then the suffix.
        work.extend(tail)
    return ops


# ----------------------------------------------------------------- hunks
def hunk_header(os_, ol, ns, nl):
    """git-style '@@ -os,ol +ns,nl @@' (1-based, ',1' omitted, empty range
    reported at the line before)."""
    def rng(s, l):
        if l == 0:
            return "%d,0" % (s - 1)
        if l == 1:
            return "%d" % s
        return "%d,%d" % (s, l)
    return "@@ -%s +%s @@" % (rng(os_, ol), rng(ns, nl))


def build_rows(ops, a_text, b_text, context, ctx=None):
    """Edit script -> display rows (type, oldline, newline, text)."""
    rows = []
    adds = sum(1 for t, _, _ in ops if t == "+")
    dels = sum(1 for t, _, _ in ops if t == "-")
    def row(op):
        t, i, j = op
        if t == " ":
            return (" ", i + 1, j + 1, a_text[i])
        if t == "-":
            return ("-", i + 1, 0, a_text[i])
        return ("+", 0, j + 1, b_text[j])

    if adds == 0 and dels == 0:
        if context >= WHOLE:          # F6 on identical members: show it all
            rows += [row(op) for op in ops]
        rows.append(("=", 0, 0, "Members are identical"))
        return rows

    hunks = 0
    if context >= WHOLE:
        hunks = 1
        rows += [row(op) for op in ops]
    else:
        nops = len(ops)
        pos = 0
        while pos < nops:
            # find next change
            while pos < nops and ops[pos][0] == " ":
                pos += 1
            if pos >= nops:
                break
            start = max(0, pos - context)
            # extend end while gaps between changes are <= 2*context
            end = pos
            while True:
                while end < nops and ops[end][0] != " ":
                    end += 1
                # end is at a context op (or past the end)
                gap_start = end
                while end < nops and ops[end][0] == " " and end - gap_start < 2 * context:
                    end += 1
                if end < nops and ops[end][0] != " ":
                    continue             # another change within reach
                # no more changes within 2*context: trim trailing context
                end = min(gap_start + context, nops)
                break
            # header counts
            ol = sum(1 for t, _, _ in ops[start:end] if t != "+")
            nl = sum(1 for t, _, _ in ops[start:end] if t != "-")
            # first old / new line numbers inside the hunk
            os_ = next((i + 1 for t, i, _ in ops[start:end] if t != "+"), 0)
            ns = next((j + 1 for t, _, j in ops[start:end] if t != "-"), 0)
            if ol == 0:
                os_ = next((i + 1 for t, i, _ in reversed(ops[:start]) if t != "+"), 0) + 1
            if nl == 0:
                ns = next((j + 1 for t, _, j in reversed(ops[:start]) if t != "-"), 0) + 1
            hunks += 1
            hdr = hunk_header(os_, ol, ns, nl)
            if ctx is not None and os_ - 1 >= 1 and ctx[os_ - 1]:
                hdr = hdr + " " + func_text(a_text[ctx[os_ - 1] - 1])
            rows.append(("@", 0, 0, hdr[:100]))
            rows += [row(op) for op in ops[start:end]]
            pos = end
    rows.append(("=", 0, 0, "%d hunk%s, +%d -%d" % (hunks, "" if hunks == 1 else "s", adds, dels)))
    return rows


def srcdiff(a_text, b_text, context=3, ignblank=False):
    a = [make_key(t, ignblank) for t in a_text]
    b = [make_key(t, ignblank) for t in b_text]
    ops = diff_keys(a, b)
    return build_rows(ops, a_text, b_text, context, func_index(a_text))


def read_lines(path):
    with open(path, "r", encoding="utf-8", errors="replace", newline="") as f:
        data = f.read()
    lines = data.replace("\r\n", "\n").replace("\r", "\n").split("\n")
    if lines and lines[-1] == "":
        lines.pop()
    return [l.rstrip() for l in lines]


def main(argv=None):
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("old")
    p.add_argument("new")
    p.add_argument("--context", type=int, default=3)
    p.add_argument("--ignblank", action="store_true")
    p.add_argument("--git", action="store_true", help="print like 'git diff' instead of rows")
    args = p.parse_args(argv)
    rows = srcdiff(read_lines(args.old), read_lines(args.new), args.context, args.ignblank)
    for t, i, j, text in rows:
        if args.git:
            print(("%s%s" % (t, text)) if t in " +-" else text)
        else:
            print("%s\t%d\t%d\t%s" % (t, i, j, text))
    return 0


if __name__ == "__main__":
    sys.exit(main())
