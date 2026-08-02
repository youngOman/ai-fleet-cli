#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""release gate：擋住個人資料被推上公開 repo。

用法：
    python3 scripts/scan.py [路徑...]           # 不給路徑就掃 repo 根
    python3 scripts/scan.py --exclude 'docs/*'  # 可重複

命中就印 `檔案:行號: [規則] 內容摘要` 並以 exit code 1 結束。

設計原則
--------
1. 只用標準庫，不引入任何第三方相依（CI 要能在乾淨 runner 上直接跑）。
2. 所有規則都是**內容規則**，不提供「這個檔案整組豁免這條規則」的路徑白名單。
   唯一的例外是 tests/fixtures/（錄下來的畫面快照，本來就會出現 IP、
   看起來像憑證的亂碼），但即使是 fixture 也照樣跑
   personal-abs-path 與 private-key-block —— 這兩條沒有任何正當理由出現。
3. 寧可誤報也不要漏報。誤報請改內容或用 --exclude 明確排除該檔案，
   不要放寬規則。
"""

import argparse
import fnmatch
import os
import re
import sys

# --- 掃描範圍 --------------------------------------------------------------

# 這些目錄整組跳過（版控中繼資料、快取、虛擬環境、相依套件）
SKIP_DIRS = frozenset({
    ".git",
    ".hg",
    ".svn",
    "__pycache__",
    ".venv",
    "venv",
    "node_modules",
    ".mypy_cache",
    ".pytest_cache",
    ".ruff_cache",
})

# fixture 只跑這兩條硬規則
FIXTURE_RULES = frozenset({"personal-abs-path", "private-key-block"})

# 單檔上限，超過視為資料檔跳過（避免掃到巨大 log）
MAX_BYTES = 5 * 1024 * 1024


# --- 規則 ------------------------------------------------------------------

# 個人絕對路徑。`/Users/$USER`、`${HOME}`、`~` 這類佔位符因為第一段
# 不是純識別字元，天生就不會被這個 pattern 命中。
RE_PERSONAL_PATH = re.compile(r"/(?:Users|home)/([A-Za-z0-9._][A-Za-z0-9._\-]*)/")

# CI runner 與慣用佔位使用者名稱不算個人資料
ALLOWED_HOME_NAMES = frozenset({
    "runner",       # GitHub Actions
    "user",
    "username",
    "youruser",
    "your-user",
    "your_name",
    "USER",
    "HOME",
    "linuxbrew",
})

RE_CREDENTIAL = re.compile(
    r"(?i)(token|secret|password|api[_-]?key|bearer)"
    r"\s*[:=]\s*"
    r"['\"]?([A-Za-z0-9_\-]{16,})"
)

# 明顯是佔位符的值 → 不算憑證
RE_PLACEHOLDER_VALUE = re.compile(
    r"(?i)("
    r"change[_-]?me"
    r"|your[_-]?"
    r"|example"
    r"|sample"
    r"|placeholder"
    r"|redacted"
    r"|dummy"
    r"|xxx"
    r")"
)
# 全部同一個字元（xxxxxxxx…、00000000…）也是佔位符
RE_MONOTONE_VALUE = re.compile(r"^(.)\1+$")
# 值其實是變數展開 / 角括號佔位 → 交給 shell 或模板引擎，不是硬編憑證
RE_STRUCTURAL_PLACEHOLDER = re.compile(r"\$\{|\$\(|<[^>]{0,64}>|\$[A-Za-z_]")

RE_PRIVATE_IP = re.compile(
    r"(?<![0-9.])("
    r"10\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}"
    r"|172\.(?:1[6-9]|2[0-9]|3[01])\.[0-9]{1,3}\.[0-9]{1,3}"
    r"|192\.168\.[0-9]{1,3}\.[0-9]{1,3}"
    r")(?![0-9.])"
)

RE_PRIVATE_KEY = re.compile(r"-----BEGIN [A-Z ]*PRIVATE KEY-----")


def _mask(value):
    """把敏感值遮掉大半，只留前 4 碼供人辨識。"""
    if len(value) <= 4:
        return "****"
    return value[:4] + "*" * min(len(value) - 4, 12)


def check_personal_path(line):
    hits = []
    for m in RE_PERSONAL_PATH.finditer(line):
        name = m.group(1)
        if name in ALLOWED_HOME_NAMES:
            continue
        hits.append(m.group(0))
    return hits


def check_credential(line):
    hits = []
    for m in RE_CREDENTIAL.finditer(line):
        key, value = m.group(1), m.group(2)
        if RE_PLACEHOLDER_VALUE.search(value):
            continue
        if RE_MONOTONE_VALUE.match(value):
            continue
        # 看整段（含 key 與值前後）是否為變數展開 / 角括號佔位
        window = line[max(0, m.start() - 2):min(len(line), m.end() + 2)]
        if RE_STRUCTURAL_PLACEHOLDER.search(window):
            continue
        hits.append("%s=%s" % (key, _mask(value)))
    return hits


def check_private_ip(line):
    # 刻意不排除「文件中的說明用途」：寧可誤報也不要漏掉真實內網位址
    return [m.group(0) for m in RE_PRIVATE_IP.finditer(line)]


def check_private_key(line):
    return [m.group(0) for m in RE_PRIVATE_KEY.finditer(line)]


def make_host_checker(hosts):
    if not hosts:
        return None
    pattern = re.compile(
        r"(?i)(" + "|".join(re.escape(h) for h in hosts) + r")"
    )

    def _check(line):
        return [m.group(0) for m in pattern.finditer(line)]

    return _check


def build_rules(deny_hosts):
    """回傳 [(規則名, 檢查函式), ...]。"""
    rules = [
        ("personal-abs-path", check_personal_path),
        ("inline-credential", check_credential),
        ("private-ip", check_private_ip),
        ("private-key-block", check_private_key),
    ]
    host_checker = make_host_checker(deny_hosts)
    if host_checker is not None:
        rules.append(("internal-host", host_checker))
    return rules


# --- 檔案走訪 --------------------------------------------------------------

def is_fixture(rel_path):
    """判斷是否位於 tests/fixtures/ 之下。"""
    parts = rel_path.replace(os.sep, "/").split("/")
    for i in range(len(parts) - 1):
        if parts[i] == "tests" and parts[i + 1] == "fixtures":
            return True
    return False


def is_excluded(rel_path, patterns):
    posix = rel_path.replace(os.sep, "/")
    base = posix.rsplit("/", 1)[-1]
    for pat in patterns:
        if fnmatch.fnmatch(posix, pat) or fnmatch.fnmatch(base, pat):
            return True
        # 目錄型 pattern：docs → docs/ 之下全部
        if fnmatch.fnmatch(posix, pat.rstrip("/") + "/*"):
            return True
    return False


def iter_files(paths):
    """走訪所有待掃檔案，yield 絕對路徑。"""
    for p in paths:
        if os.path.isfile(p):
            yield os.path.abspath(p)
            continue
        for dirpath, dirnames, filenames in os.walk(p):
            dirnames[:] = sorted(d for d in dirnames if d not in SKIP_DIRS)
            for name in sorted(filenames):
                yield os.path.join(dirpath, name)


def read_text(path):
    """讀檔；含 NUL byte（二進位）或過大就回傳 None 表示跳過。"""
    try:
        if os.path.getsize(path) > MAX_BYTES:
            return None
        with open(path, "rb") as fh:
            raw = fh.read()
    except (OSError, IOError):
        return None
    if b"\x00" in raw:
        return None
    return raw.decode("utf-8", errors="replace")


def scan_file(path, rel_path, rules, out):
    """掃一個檔案，回傳命中筆數。"""
    text = read_text(path)
    if text is None:
        return 0

    fixture = is_fixture(rel_path)
    count = 0
    for lineno, line in enumerate(text.splitlines(), start=1):
        for rule_name, checker in rules:
            if fixture and rule_name not in FIXTURE_RULES:
                continue
            for hit in checker(line):
                summary = hit.strip()
                if len(summary) > 120:
                    summary = summary[:117] + "..."
                out.write("%s:%d: [%s] %s\n" % (rel_path, lineno, rule_name, summary))
                count += 1
    return count


def main(argv=None):
    repo_root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

    parser = argparse.ArgumentParser(
        description="release gate：擋個人絕對路徑 / 憑證 / 內網位址 / 私鑰",
    )
    parser.add_argument(
        "paths", nargs="*",
        help="要掃描的檔案或目錄（預設為 repo 根目錄）",
    )
    parser.add_argument(
        "--exclude", action="append", default=[], metavar="GLOB",
        help="排除符合 glob 的檔案（可重複）",
    )
    args = parser.parse_args(argv)

    paths = args.paths or [repo_root]
    base = os.path.abspath(paths[0]) if len(paths) == 1 else repo_root
    if os.path.isfile(base):
        base = os.path.dirname(base)

    deny_hosts = [
        h.strip() for h in os.environ.get("SCAN_DENY_HOSTS", "").split(",")
        if h.strip()
    ]
    rules = build_rules(deny_hosts)

    total = 0
    scanned = 0
    for abs_path in iter_files(paths):
        try:
            rel_path = os.path.relpath(abs_path, base)
        except ValueError:
            rel_path = abs_path
        if rel_path.startswith(".." + os.sep) or rel_path == "..":
            rel_path = abs_path
        if is_excluded(rel_path, args.exclude):
            continue
        scanned += 1
        total += scan_file(abs_path, rel_path, rules, sys.stdout)

    if total:
        sys.stderr.write(
            "\nrelease gate 失敗：%d 筆命中（已掃 %d 個檔案）\n" % (total, scanned)
        )
        sys.stderr.write(
            "請修掉內容；確定是誤報再用 --exclude 排除該檔案，不要放寬規則。\n"
        )
        return 1

    sys.stderr.write("release gate 通過：已掃 %d 個檔案，無命中。\n" % scanned)
    return 0


if __name__ == "__main__":
    sys.exit(main())
