#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""libexec/fleet-lint 的行為測試。

「一個從不擋東西的 lint 等於沒有 lint」——
所以這裡同時測「該報的有報」與「合格報告不誤報」,
並且明確釘住 exit code 契約:error → 1、warn → 0、--strict + warn → 1。
warn 不擋工作流是刻意設計,退化成擋人會讓大家整支繞過去。
"""

import os
import shutil
import subprocess
import sys
import tempfile
import unittest

REPO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
LINT = os.path.join(REPO_ROOT, "libexec", "fleet-lint")

# --- 合格報告的四節內容 -----------------------------------------------------

GOOD = """\
# 修好看板欄位錯位

## 做了什麼

改用 east_asian_width 算顯示寬度,表格不再錯位。

## 改了哪些檔

- libexec/fleet-mon:120 新增 char_width()
- libexec/fleet-mon:158 pad() 改成先算寬度再補空白

## 怎麼驗證

```console
$ python3 -m unittest tests.test_lint -v
OK
```

## 殘留問題

emoji ZWJ 序列(👨‍👩‍👧)還是會算成多格,尚未處理。
"""


def write(dirpath, name, text):
    path = os.path.join(dirpath, name)
    with open(path, "w", encoding="utf-8") as fh:
        fh.write(text)
    return path


def run_lint(*args):
    p = subprocess.run([sys.executable, LINT] + list(args),
                       capture_output=True, text=True, cwd=REPO_ROOT)
    return p.returncode, p.stdout + p.stderr


def issues_of(out, level):
    """挑出某個嚴重度的問題行(結尾那行總結不算)。"""
    return [ln for ln in out.splitlines() if "[%s]" % level in ln]


class LintTestBase(unittest.TestCase):
    def setUp(self):
        self.dir = tempfile.mkdtemp(prefix="fleet-lint-test-")
        self.addCleanup(shutil.rmtree, self.dir, True)

    def lint(self, text, name="20260803-0930-cc1-看板欄位錯位.md", *extra):
        path = write(self.dir, name, text)
        return run_lint(path, *extra)


class TestGoodReport(LintTestBase):
    def test_full_report_is_clean(self):
        """四節齊全且合格 → 0 問題、exit 0。"""
        rc, out = self.lint(GOOD)
        self.assertEqual(rc, 0, out)
        self.assertEqual(issues_of(out, "error"), [], out)
        self.assertEqual(issues_of(out, "warn"), [], out)
        self.assertIn("1 份完全乾淨", out)

    def test_numbered_list_headings_accepted(self):
        """標題用編號清單而不是 markdown heading 也要認得。"""
        text = (
            "1. 做了什麼\n\n修好了。\n\n"
            "2. 改了哪些檔\n\nlib/core.sh:88 調整預設值\n\n"
            "3. 怎麼驗證\n\n```\n$ bash -n lib/core.sh\n```\n\n"
            "4. 殘留問題\n\n無。\n"
        )
        rc, out = self.lint(text)
        self.assertEqual(issues_of(out, "error"), [], out)
        self.assertEqual(rc, 0, out)

    def test_decorated_headings_accepted(self):
        """標題前後有 emoji / 編號 / 標點也要認得(寬鬆比對)。"""
        text = (
            "## ✅ 1. 做了什麼(結論先講)\n\n修好了。\n\n"
            "## 📝 改了哪些檔:\n\nlib/core.sh:88\n\n"
            "## 🔍 怎麼驗證?\n\n```\n$ true\n```\n\n"
            "## ⚠️ 殘留問題 —\n\n無。\n"
        )
        rc, out = self.lint(text)
        self.assertEqual(issues_of(out, "error"), [], out)
        self.assertEqual(rc, 0, out)


class TestMissingSection(LintTestBase):
    def test_missing_one_section_is_error(self):
        """缺一節 → error 且 exit 1。"""
        text = GOOD.replace("## 殘留問題\n\nemoji ZWJ 序列(👨‍👩‍👧)還是會算成多格,尚未處理。\n", "")
        rc, out = self.lint(text)
        self.assertEqual(rc, 1, out)
        errs = issues_of(out, "error")
        self.assertEqual(len(errs), 1, out)
        self.assertIn("殘留問題", errs[0])

    def test_empty_file_reports_four_errors(self):
        rc, out = self.lint("")
        self.assertEqual(rc, 1, out)
        self.assertEqual(len(issues_of(out, "error")), 4, out)

    def test_missing_file_is_error(self):
        rc, out = run_lint(os.path.join(self.dir, "不存在的報告.md"))
        self.assertEqual(rc, 1, out)
        self.assertEqual(len(issues_of(out, "error")), 1, out)


class TestWarnings(LintTestBase):
    def test_files_section_without_file_line(self):
        """有「改了哪些檔」但沒有 檔案:行號 → warn,不是 error。"""
        text = GOOD.replace(
            "- libexec/fleet-mon:120 新增 char_width()\n"
            "- libexec/fleet-mon:158 pad() 改成先算寬度再補空白\n",
            "改了看板那支程式,還有一點排版。\n")
        rc, out = self.lint(text)
        self.assertEqual(rc, 0, out)
        self.assertEqual(issues_of(out, "error"), [], out)
        warns = issues_of(out, "warn")
        self.assertEqual(len(warns), 1, out)
        self.assertIn("檔案:行號", warns[0])

    def test_verify_section_without_code_block(self):
        """「怎麼驗證」沒有 code block 也沒有縮排區塊 → warn。"""
        text = GOOD.replace(
            "```console\n$ python3 -m unittest tests.test_lint -v\nOK\n```\n",
            "跑了單元測試,全綠。\n")
        rc, out = self.lint(text)
        self.assertEqual(rc, 0, out)
        self.assertEqual(issues_of(out, "error"), [], out)
        warns = issues_of(out, "warn")
        self.assertEqual(len(warns), 1, out)
        self.assertIn("code block", warns[0])

    def test_indented_block_counts_as_output(self):
        """縮排 4 空白的區塊也算貼了輸出,不該 warn。"""
        text = GOOD.replace(
            "```console\n$ python3 -m unittest tests.test_lint -v\nOK\n```\n",
            "    $ python3 -m unittest tests.test_lint -v\n    OK\n")
        rc, out = self.lint(text)
        self.assertEqual(rc, 0, out)
        self.assertEqual(issues_of(out, "warn"), [], out)

    def test_fake_signal_phrase(self):
        """出現「等價執行」這類假訊號用語 → warn。"""
        text = GOOD.replace("OK\n```", "OK\n```\n\n其餘情境等價執行,沒有另外跑。")
        rc, out = self.lint(text)
        self.assertEqual(rc, 0, out)
        warns = issues_of(out, "warn")
        self.assertEqual(len(warns), 1, out)
        self.assertIn("等價執行", warns[0])

    def test_fake_signal_should_pass_phrase(self):
        text = GOOD.replace("OK\n```", "OK\n```\n\n另外兩個 case 應該會過。")
        rc, out = self.lint(text)
        self.assertEqual(rc, 0, out)
        self.assertIn("應該會過", "\n".join(issues_of(out, "warn")))

    def test_bad_filename(self):
        """檔名不符 <YYYYMMDD>-<HHMM>-<worker>-<主題>.md → warn。"""
        rc, out = self.lint(GOOD, "隨手寫的報告.md")
        self.assertEqual(rc, 0, out)
        warns = issues_of(out, "warn")
        self.assertEqual(len(warns), 1, out)
        self.assertIn("檔名不符慣例", warns[0])

    def test_good_filename_no_warn(self):
        rc, out = self.lint(GOOD, "20260803-1530-cx2-報告-lint.md")
        self.assertEqual(rc, 0, out)
        self.assertEqual(issues_of(out, "warn"), [], out)


class TestStrict(LintTestBase):
    def test_strict_turns_warn_into_failure(self):
        """--strict 讓純 warn 也 exit 1;不加就是 0。"""
        path = write(self.dir, "隨手寫的報告.md", GOOD)
        rc_loose, out_loose = run_lint(path)
        rc_strict, out_strict = run_lint("--strict", path)
        self.assertEqual(rc_loose, 0, out_loose)
        self.assertEqual(rc_strict, 1, out_strict)
        self.assertEqual(issues_of(out_strict, "error"), [], out_strict)

    def test_strict_on_clean_report_still_zero(self):
        path = write(self.dir, "20260803-0930-cc1-乾淨報告.md", GOOD)
        rc, out = run_lint("--strict", path)
        self.assertEqual(rc, 0, out)


class TestBatch(LintTestBase):
    def test_all_scans_reports_dir(self):
        """--all 掃 $FLEET_REPORTS 底下的 *.md。"""
        write(self.dir, "20260803-0930-cc1-好報告.md", GOOD)
        write(self.dir, "20260803-0931-cc1-壞報告.md", "# 只有標題\n")
        env = dict(os.environ, FLEET_REPORTS=self.dir)
        p = subprocess.run([sys.executable, LINT, "--all"],
                           capture_output=True, text=True, env=env, cwd=REPO_ROOT)
        out = p.stdout + p.stderr
        self.assertEqual(p.returncode, 1, out)
        self.assertEqual(len(issues_of(out, "error")), 4, out)
        self.assertIn("檢查 2 份報告", out)

    def test_all_on_empty_dir_is_ok(self):
        env = dict(os.environ, FLEET_REPORTS=self.dir)
        p = subprocess.run([sys.executable, LINT, "--all"],
                           capture_output=True, text=True, env=env, cwd=REPO_ROOT)
        self.assertEqual(p.returncode, 0, p.stdout + p.stderr)

    def test_no_args_is_usage_error(self):
        rc, out = run_lint()
        self.assertEqual(rc, 2, out)


class TestOutputFormat(LintTestBase):
    def test_issue_line_shape(self):
        """每個問題一行 `檔案:行號: [error|warn] 說明`。"""
        path = write(self.dir, "20260803-0930-cc1-缺節.md", "# 只有標題\n")
        rc, out = run_lint(path)
        self.assertEqual(rc, 1, out)
        for line in issues_of(out, "error"):
            head, rest = line.split(": [", 1)
            self.assertTrue(head.startswith(path), line)
            self.assertTrue(head[len(path):].startswith(":"), line)
            self.assertTrue(head[len(path) + 1:].isdigit(), line)
            self.assertTrue(rest.startswith("error] "), line)


if __name__ == "__main__":
    unittest.main()
