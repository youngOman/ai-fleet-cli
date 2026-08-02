#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""scripts/scan.py 的行為測試。

「一個從不擋東西的 gate 等於沒有 gate」——
所以這裡同時測「該擋的有擋」與「不該擋的沒誤報」。

注意：本檔內的假憑證 / 假私鑰 / 假內網 IP 一律用字串拼接組出來，
不讓危險樣式以完整形式出現在原始碼裡。否則 scan.py 掃到自己的測試檔
就會把 repo 擋下來（release gate 對 tests/ 沒有豁免，這是刻意的）。
"""

import os
import shutil
import subprocess
import sys
import tempfile
import unittest

REPO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SCAN = os.path.join(REPO_ROOT, "scripts", "scan.py")

# --- 拼出來的危險樣本 -------------------------------------------------------
CRED_KEY = "api" + "_key"
CRED_VALUE = "sk_live_" + "9f3ba2c1d8e740aa"
BAD_CREDENTIAL = CRED_KEY + ' = "' + CRED_VALUE + '"'

BAD_PERSONAL_PATH = "source /Users/" + "someone/x" + "/lib/core.sh"
BAD_PRIVATE_KEY = "-----BEGIN " + "RSA PRIVATE KEY" + "-----"
BAD_PRIVATE_IP = "ssh deploy@" + "192.168." + "1.1"
BAD_PRIVATE_IP_10 = "backend " + "10." + "1.2.3" + ":8080"
BAD_PRIVATE_IP_172 = "db " + "172." + "20.0.5"

# --- 不該被擋的樣本 ---------------------------------------------------------
OK_ENV_VAR = "token = " + '"${' + "TOKEN}\""
OK_CHANGE_ME = "token = " + '"CHANGE_ME"'
OK_CHANGE_ME_LONG = "password = " + '"CHANGE_ME_BEFORE_DEPLOY"'
OK_HOME = "source $HOME" + "/.config/fleet/config.env"
OK_TILDE = "cp ~" + "/.local/share/fleet/registry ."
OK_RUNNER = "cd /home/" + "runner/work/ai-fleet-cli"
OK_USER_VAR = "ls /Users/" + "$USER/Developer"
OK_SUBSHELL = "secret = " + '"$(' + 'pass show fleet/token)"'
OK_PLACEHOLDER = CRED_KEY + ' = "' + "your-api-key-goes-here" + '"'
OK_PUBLIC_IP = "dig " + "8.8.8.8"
OK_VERSION = "tmux " + "3.4.1" + " required"


def run_scan(*args, **kwargs):
    """跑 scan.py，回傳 (returncode, stdout, stderr)。"""
    env = dict(os.environ)
    env.pop("SCAN_DENY_HOSTS", None)
    env.update(kwargs.pop("env", {}))
    proc = subprocess.Popen(
        [sys.executable, SCAN] + list(args),
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        env=env,
    )
    out, err = proc.communicate()
    return proc.returncode, out.decode("utf-8"), err.decode("utf-8")


class ScanTestBase(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp(prefix="fleet-scan-test-")
        self.addCleanup(shutil.rmtree, self.tmp, True)

    def write(self, relpath, *lines):
        path = os.path.join(self.tmp, relpath)
        parent = os.path.dirname(path)
        if parent and not os.path.isdir(parent):
            os.makedirs(parent)
        with open(path, "w") as fh:
            fh.write("\n".join(lines) + "\n")
        return path


class TestScanBlocks(ScanTestBase):
    """該擋的要擋住。"""

    def assert_blocked(self, rule, *lines):
        self.write("sample.sh", *lines)
        code, out, _err = run_scan(self.tmp)
        self.assertEqual(code, 1, "應該要被擋下來，實際輸出：\n%s" % out)
        self.assertIn("[%s]" % rule, out)
        self.assertIn("sample.sh:", out)

    def test_inline_credential(self):
        self.assert_blocked("inline-credential", "#!/bin/sh", BAD_CREDENTIAL)

    def test_personal_abs_path(self):
        self.assert_blocked("personal-abs-path", BAD_PERSONAL_PATH)

    def test_private_key_block(self):
        self.assert_blocked("private-key-block", BAD_PRIVATE_KEY, "AAAA")

    def test_private_ip_192(self):
        self.assert_blocked("private-ip", BAD_PRIVATE_IP)

    def test_private_ip_10(self):
        self.assert_blocked("private-ip", BAD_PRIVATE_IP_10)

    def test_private_ip_172(self):
        self.assert_blocked("private-ip", BAD_PRIVATE_IP_172)

    def test_reports_line_number(self):
        self.write("sample.sh", "line one", "line two", BAD_PERSONAL_PATH)
        code, out, _err = run_scan(self.tmp)
        self.assertEqual(code, 1)
        self.assertIn("sample.sh:3: [personal-abs-path]", out)

    def test_credential_value_is_masked(self):
        self.write("sample.sh", BAD_CREDENTIAL)
        code, out, _err = run_scan(self.tmp)
        self.assertEqual(code, 1)
        self.assertNotIn(CRED_VALUE, out)

    def test_internal_host_from_env(self):
        self.write("sample.sh", "curl https://gitea.internal.example/api")
        code, out, _err = run_scan(
            self.tmp, env={"SCAN_DENY_HOSTS": "gitea.internal.example,mm.corp"}
        )
        self.assertEqual(code, 1, out)
        self.assertIn("[internal-host]", out)


class TestScanDoesNotFalsePositive(ScanTestBase):
    """不該擋的不要誤報。"""

    def assert_clean(self, *lines):
        self.write("sample.sh", *lines)
        code, out, _err = run_scan(self.tmp)
        self.assertEqual(code, 0, "不該被擋，但命中了：\n%s" % out)
        self.assertEqual(out.strip(), "")

    def test_shell_variable_placeholder(self):
        self.assert_clean(OK_ENV_VAR)

    def test_change_me_placeholder(self):
        self.assert_clean(OK_CHANGE_ME, OK_CHANGE_ME_LONG)

    def test_home_and_tilde(self):
        self.assert_clean(OK_HOME, OK_TILDE)

    def test_ci_runner_home(self):
        self.assert_clean(OK_RUNNER)

    def test_user_variable_in_path(self):
        self.assert_clean(OK_USER_VAR)

    def test_command_substitution(self):
        self.assert_clean(OK_SUBSHELL)

    def test_your_prefix_placeholder(self):
        self.assert_clean(OK_PLACEHOLDER)

    def test_public_ip_and_version_string(self):
        self.assert_clean(OK_PUBLIC_IP, OK_VERSION)

    def test_internal_host_not_configured_by_default(self):
        self.assert_clean("curl https://gitea.internal.example/api")


class TestScanScope(ScanTestBase):
    """掃描範圍：fixture、二進位、--exclude。"""

    def test_fixture_skips_soft_rules(self):
        self.write(
            os.path.join("tests", "fixtures", "pane.txt"),
            BAD_PRIVATE_IP,
            BAD_CREDENTIAL,
        )
        code, out, _err = run_scan(self.tmp)
        self.assertEqual(code, 0, "fixture 的 IP / 憑證樣式應被容忍：\n%s" % out)

    def test_fixture_still_blocks_hard_rules(self):
        self.write(
            os.path.join("tests", "fixtures", "pane.txt"),
            BAD_PERSONAL_PATH,
        )
        code, out, _err = run_scan(self.tmp)
        self.assertEqual(code, 1)
        self.assertIn("[personal-abs-path]", out)

    def test_fixture_still_blocks_private_key(self):
        self.write(os.path.join("tests", "fixtures", "pane.txt"), BAD_PRIVATE_KEY)
        code, out, _err = run_scan(self.tmp)
        self.assertEqual(code, 1)
        self.assertIn("[private-key-block]", out)

    def test_binary_file_skipped(self):
        path = os.path.join(self.tmp, "blob.bin")
        with open(path, "wb") as fh:
            fh.write(BAD_PERSONAL_PATH.encode("utf-8") + b"\x00\x01\x02")
        code, out, _err = run_scan(self.tmp)
        self.assertEqual(code, 0, out)

    def test_git_dir_skipped(self):
        self.write(os.path.join(".git", "config"), BAD_PERSONAL_PATH)
        code, out, _err = run_scan(self.tmp)
        self.assertEqual(code, 0, out)

    def test_exclude_glob(self):
        self.write("vendor.sh", BAD_PERSONAL_PATH)
        code, _out, _err = run_scan(self.tmp)
        self.assertEqual(code, 1)
        code, out, _err = run_scan(self.tmp, "--exclude", "vendor.sh")
        self.assertEqual(code, 0, out)

    def test_single_file_target(self):
        path = self.write("sample.sh", BAD_PERSONAL_PATH)
        code, out, _err = run_scan(path)
        self.assertEqual(code, 1, out)
        self.assertIn("[personal-abs-path]", out)


class TestScanOnRepo(unittest.TestCase):
    """gate 必須能在本 repo 上實際跑起來。"""

    def test_repo_is_clean(self):
        code, out, err = run_scan()
        self.assertEqual(code, 0, "repo 有命中：\n%s\n%s" % (out, err))


if __name__ == "__main__":
    unittest.main()
