"""Tests for tools/srcdiff_ref.py (run: python -m unittest discover tests)."""

import difflib
import os
import random
import sys
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "tools"))
import srcdiff_ref as R  # noqa: E402


def rebuild(rows, side):
    """Rebuild old ('-') or new ('+') text from whole-member rows."""
    keep = (" ", side)
    return [t for ty, _, _, t in rows if ty in keep]


class EditScriptInvariants(unittest.TestCase):
    def check(self, a, b, ignblank=False):
        rows = R.srcdiff(a, b, R.WHOLE, ignblank)
        body = [r for r in rows if r[0] in " +-"]
        self.assertEqual(rebuild(body, "-"), a)
        self.assertEqual(rebuild(body, "+"), b)
        # old/new line numbers must be increasing and complete
        olds = [i for ty, i, _, _ in body if ty != "+"]
        news = [j for ty, _, j, _ in body if ty != "-"]
        self.assertEqual(olds, list(range(1, len(a) + 1)))
        self.assertEqual(news, list(range(1, len(b) + 1)))
        return rows

    def test_identical(self):
        a = ["x", "y", "z"]
        rows = R.srcdiff(a, list(a), 3)
        self.assertEqual(rows, [("=", 0, 0, "Members are identical")])

    def test_trailing_blanks_ignored(self):
        rows = R.srcdiff(["a   ", "b"], ["a", "b  "], 3)
        self.assertEqual(rows[0][0], "=")

    def test_ignblank(self):
        a = ["  eval   x = 1", "b"]
        b = ["eval x = 1", "b"]
        self.assertEqual(R.srcdiff(a, b, 3)[0][0], "@")
        self.assertEqual(R.srcdiff(a, b, 3, ignblank=True)[0][0], "=")

    def test_pure_insert_delete(self):
        self.check([], ["a", "b"])
        self.check(["a", "b"], [])
        self.check([], [])

    def test_small_cases(self):
        self.check(list("abcabba"), list("cbabac"))
        self.check(list("abcdef"), list("abXdef"))
        self.check(list("abcdef"), list("Xabcdef"))
        self.check(list("abcdef"), list("abcdefX"))
        self.check(list("aaaa"), list("aaa"))
        self.check(list("abab"), list("baba"))

    def test_repeated_lines_force_myers(self):
        # no unique lines at all -> Myers path
        a = ["x"] * 30 + ["y"] * 30
        b = ["y"] * 30 + ["x"] * 30
        self.check(a, b)

    def test_myers_cap_fallback(self):
        old = R.MAXD
        try:
            R.MAXD = 4
            a = ["q"] * 10 + list("abcdefghij")
            b = ["q"] * 10 + list("klmnopqrst")
            self.check(a, b)
        finally:
            R.MAXD = old

    def test_fuzz(self):
        rng = random.Random(1234)
        alphabet = ["L%d" % i for i in range(12)]
        for _ in range(400):
            a = [rng.choice(alphabet) for _ in range(rng.randint(0, 40))]
            b = list(a)
            for _ in range(rng.randint(0, 8)):
                op = rng.random()
                if op < 0.4 and b:
                    del b[rng.randrange(len(b))]
                elif op < 0.8:
                    b.insert(rng.randint(0, len(b)), rng.choice(alphabet))
                elif b:
                    b[rng.randrange(len(b))] = rng.choice(alphabet)
            self.check(a, b)


class HunkHeaders(unittest.TestCase):
    def headers(self, a, b, context=3):
        return [t for ty, _, _, t in R.srcdiff(a, b, context) if ty == "@"]

    def difflib_headers(self, a, b, context=3):
        out = []
        for line in difflib.unified_diff(a, b, n=context, lineterm=""):
            if line.startswith("@@"):
                out.append(line)
        return out

    def test_headers_match_git_rules(self):
        base = ["line %d" % i for i in range(1, 31)]
        cases = [
            (base, base[:5] + ["NEW"] + base[5:]),           # insert in middle
            (base, base[:10] + base[12:]),                   # delete two lines
            (base, ["TOP"] + base),                          # insert at top
            (base, base + ["END"]),                          # append
            (base, base[:3] + ["X"] + base[3:20] + ["Y"] + base[20:]),  # two hunks
            (base, base[:3] + ["X"] + base[3:8] + ["Y"] + base[8:]),    # merged hunks
            ([], ["a", "b"]),                                # from empty
            (["a", "b"], []),                                # to empty
        ]
        for a, b in cases:
            self.assertEqual(self.headers(a, b), self.difflib_headers(a, b), (a, b))

    def test_context_zero(self):
        base = ["line %d" % i for i in range(1, 11)]
        b = base[:5] + ["NEW"] + base[5:]
        self.assertEqual(self.headers(base, b, 0), self.difflib_headers(base, b, 0))

    def test_stats_row(self):
        base = ["line %d" % i for i in range(1, 31)]
        rows = R.srcdiff(base, base[:3] + ["X"] + base[3:20] + ["Y", "Z"] + base[21:])
        self.assertEqual(rows[-1], ("=", 0, 0, "2 hunks, +3 -1"))

    def test_whole_member_has_no_headers(self):
        base = ["line %d" % i for i in range(1, 11)]
        rows = R.srcdiff(base, base[:5] + ["NEW"] + base[5:], R.WHOLE)
        self.assertEqual([r for r in rows if r[0] == "@"], [])
        self.assertEqual(len([r for r in rows if r[0] in " +-"]), 11)
        self.assertEqual(rows[-1][3], "1 hunk, +1 -0")


class Fixtures(unittest.TestCase):
    def test_fixtures_roundtrip(self):
        fx = os.path.join(os.path.dirname(__file__), "..", "tools", "fixtures")
        pairs = sorted(f[:-8] for f in os.listdir(fx) if f.endswith(".old.txt"))
        self.assertTrue(pairs)
        for name in pairs:
            a = R.read_lines(os.path.join(fx, name + ".old.txt"))
            b = R.read_lines(os.path.join(fx, name + ".new.txt"))
            rows = R.srcdiff(a, b, R.WHOLE)
            body = [r for r in rows if r[0] in " +-"]
            self.assertEqual(rebuild(body, "-"), a, name)
            self.assertEqual(rebuild(body, "+"), b, name)
            expected = os.path.join(fx, name + ".expected.txt")
            if os.path.exists(expected):
                got = ["%s\t%d\t%d\t%s" % r for r in R.srcdiff(a, b, 3)]
                self.assertEqual(got, R.read_lines(expected), name)


class FunctionContext(unittest.TestCase):
    def test_rules(self):
        F = R.func_text
        self.assertEqual(F("     C     $READ         BEGSR"), "C     $READ         BEGSR")
        self.assertEqual(F("KW1  C     $read         begsr"), "C     $read         begsr")
        self.assertEqual(F("     C*    $READ         BEGSR"), "")
        self.assertEqual(F("     PGetPrice         B                   EXPORT"),
                         "PGetPrice         B                   EXPORT")
        self.assertEqual(F("     PGetPrice         E"), "")
        self.assertEqual(F("     A          R SFL1                      SFL"),
                         "A          R SFL1                      SFL")
        self.assertEqual(F("     A            MK             1A  O  6  2"), "")
        self.assertEqual(F("dcl-proc getPrice export;"), "dcl-proc getPrice export;")
        self.assertEqual(F("       DCL-PROC main;"), "DCL-PROC main;")
        self.assertEqual(F("KW2    begsr $load;"), "begsr $load;")
        self.assertEqual(F("  // dcl-proc commented;"), "")
        self.assertEqual(F(" NOLIB:      CHGVAR     VAR(&MSG)"), "NOLIB:      CHGVAR     VAR(&MSG)")
        self.assertEqual(F("             SUBR       SUBR(CLEANUP)"), "SUBR       SUBR(CLEANUP)")
        self.assertEqual(F("/* NOTE: not a label */"), "")
        self.assertEqual(F("             CALL       PGM(X)"), "")
        self.assertEqual(F("TOOLONGNAME1: x"), "")
        self.assertEqual(F(""), "")

    def test_header_gets_nearest_preceding_function(self):
        a = ["     C     LoadCust      BEGSR"] + ["     C                   EVAL      X = %d" % i
                                                   for i in range(1, 20)]
        b = list(a)
        b[15] = "     C                   EVAL      X = 99"
        hdrs = [t for ty, _, _, t in R.srcdiff(a, b, 3) if ty == "@"]
        self.assertEqual(hdrs, ["@@ -13,7 +13,7 @@ C     LoadCust      BEGSR"])

    def test_function_line_inside_hunk_not_used(self):
        # git looks only at lines before the hunk's first line
        a = ["x1", "x2", "     C     A             BEGSR", "y"]
        b = ["x1", "x2", "     C     A             BEGSR", "z"]
        hdrs = [t for ty, _, _, t in R.srcdiff(a, b, 3) if ty == "@"]
        self.assertEqual(hdrs, ["@@ -1,4 +1,4 @@"])


if __name__ == "__main__":
    unittest.main()
