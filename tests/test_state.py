#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""libexec/fleet-state 的純函式測試。

這裡測的是整套艦隊的**假訊號防護**:哪些報告該通知、哪些不該、
worker 什麼時候算閒置/卡住。這些判斷靜默壞掉的時候使用者不會發現,
只會覺得「AI 做完沒人叫我」——所以每一條都對應一個真的踩過的坑,
測試名稱直接寫那個坑。

`libexec/fleet-state` 沒有 .py 副檔名(它是可執行檔),用 importlib 直接載入。
所有情境都用 tempfile 造真實檔案並用 os.utime 控制 mtime,不 mock 檔案系統:
mtime 的整數化與 hash 都是真的行為,mock 掉就測不到。
"""

import importlib.util
import json
import os
import sys
import tempfile
import unittest

REPO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
STATE_PATH = os.path.join(REPO_ROOT, "libexec", "fleet-state")


def _load_fleet_state():
    """把沒有 .py 副檔名的 libexec/fleet-state 當成模組載入。

    先關掉 bytecode 快取:不關的話每跑一次測試就在 libexec/ 底下生一個
    __pycache__,雖然有進 .gitignore,但在別人的工作目錄裡長出東西就是不禮貌。
    """
    sys.dont_write_bytecode = True
    spec = importlib.util.spec_from_loader(
        "fleet_state",
        importlib.machinery.SourceFileLoader("fleet_state", STATE_PATH),
    )
    mod = importlib.util.module_from_spec(spec)
    sys.modules["fleet_state"] = mod
    spec.loader.exec_module(mod)
    return mod


fs = _load_fleet_state()

# 測試裡固定用這組門檻,免得每條都重打一次
NOW = 1_800_000_000
STABLE = 3
BACKFILL = 600
MAX_ATTEMPTS = 3
IDS = ["cc1", "cx1"]


class ReportDirCase(unittest.TestCase):
    """提供一個真的報告目錄與寫檔/改 mtime 的小工具。"""

    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.dir = self._tmp.name
        self.addCleanup(self._tmp.cleanup)

    def write_report(self, name, body="內容", mtime=None):
        """寫一份報告並把 mtime 設成指定值,回傳絕對路徑。"""
        path = os.path.join(self.dir, name)
        with open(path, "w", encoding="utf-8") as fh:
            fh.write(body)
        if mtime is not None:
            os.utime(path, (mtime, mtime))
        return path

    def plan(self, state, now=NOW, stable=STABLE, backfill=BACKFILL,
             max_attempts=MAX_ATTEMPTS, ids=None, cooldown=0):
        return fs.plan_reports(
            state, [self.dir], now, stable, backfill, max_attempts,
            IDS if ids is None else ids, cooldown,
        )

    @staticmethod
    def names(todo):
        return [os.path.basename(t[0]) for t in todo]


# ---------------------------------------------------------------------------
# parse_report_name
# ---------------------------------------------------------------------------

class TestParseReportName(unittest.TestCase):
    """檔名 → (worker, 主題)。

    舊版用 `cut -d- -f3` 猜 worker,檔名不合慣例就生出幽靈 worker,
    害 QUIET_AFTER_REPORT 對真正那個 worker 完全失效。
    """

    def test_標準檔名解析出_worker_與中文主題(self):
        self.assertEqual(
            fs.parse_report_name("20260803-0130-cc1-修好登入.md", ["cc1", "cx1"]),
            ("cc1", "修好登入"),
        )

    def test_worker_id_互為前綴時取最長匹配(self):
        # ids 同時有 cc 與 cc1 時,`...-cc1-主題.md` 必須解成 cc1。
        # 取到 cc 的話,通知會掛在錯的 worker 上,cc1 的靜默期永遠不生效。
        self.assertEqual(
            fs.parse_report_name("20260803-0130-cc1-主題.md", ["cc", "cc1"]),
            ("cc1", "主題"),
        )

    def test_worker_id_本身含連字號也要能對上(self):
        self.assertEqual(
            fs.parse_report_name("20260803-0130-team-a1-修好登入.md",
                                 ["team-a", "team-a1"]),
            ("team-a1", "修好登入"),
        )

    def test_對不上_registry_的檔名不可生出幽靈_worker(self):
        # 這是舊版 `cut -d- -f3` 的 bug:會生出一個 registry 裡根本沒有的
        # worker 名。對不上就必須回 '-'。
        worker, topic = fs.parse_report_name(
            "20260803-0130-zz9-隨手記.md", ["cc1", "cx1"])
        self.assertEqual(worker, "-")
        self.assertEqual(topic, "zz9 隨手記")

    def test_沒有日期前綴的檔名不可_crash(self):
        self.assertEqual(
            fs.parse_report_name("random-notes.md", ["cc1"]),
            ("-", "random notes"),
        )

    def test_完全沒有連字號的檔名不可_crash(self):
        self.assertEqual(
            fs.parse_report_name("隨手筆記.md", ["cc1"]),
            ("-", "隨手筆記"),
        )

    def test_檔名只有日期與_worker_沒有主題(self):
        self.assertEqual(
            fs.parse_report_name("20260803-0130-cc1.md", ["cc1"]),
            ("cc1", ""),
        )

    def test_日期欄位不是數字就不當前綴剝掉(self):
        # 剝錯的話 worker 會對到錯的位置
        worker, _ = fs.parse_report_name("notadate-0130-cc1-主題.md", ["cc1"])
        self.assertEqual(worker, "-")

    def test_空的_registry_一律回破折號(self):
        self.assertEqual(
            fs.parse_report_name("20260803-0130-cc1-主題.md", []),
            ("-", "cc1 主題"),
        )


# ---------------------------------------------------------------------------
# plan_reports
# ---------------------------------------------------------------------------

class TestPlanReports(ReportDirCase):

    def test_新報告靜置夠久就進待通知清單且_tag_是_r加mtime(self):
        mtime = NOW - 10
        self.write_report("20260803-0130-cc1-修好登入.md", mtime=mtime)
        state = fs.empty_state()
        todo = self.plan(state)
        self.assertEqual(len(todo), 1)
        path, tag, worker, topic = todo[0]
        self.assertEqual(os.path.basename(path), "20260803-0130-cc1-修好登入.md")
        self.assertEqual(tag, "r%d" % mtime)
        self.assertEqual(worker, "cc1")
        self.assertEqual(topic, "修好登入")

    def test_mtime_太新未達靜置門檻就不通知(self):
        self.write_report("20260803-0130-cc1-半寫入.md", mtime=NOW - 1)
        state = fs.empty_state()
        self.assertEqual(self.plan(state), [])

    def test_未達靜置門檻時不可寫_state_否則下輪重試不了(self):
        # 寫了基準線的話,檔案寫完之後就再也不會被通知——報告永久靜音。
        self.write_report("20260803-0130-cc1-半寫入.md", mtime=NOW - 1)
        state = fs.empty_state()
        self.plan(state)
        self.assertEqual(state["reports"], {})

    def test_靜置門檻剛好達到就通知(self):
        self.write_report("20260803-0130-cc1-剛好.md", mtime=NOW - STABLE)
        state = fs.empty_state()
        self.assertEqual(len(self.plan(state)), 1)

    def test_下一輪掃描時同一份報告在寫完後會被通知(self):
        path = self.write_report("20260803-0130-cc1-半寫入.md", mtime=NOW - 1)
        state = fs.empty_state()
        self.assertEqual(self.plan(state), [])
        # 3 秒後再掃一次:同一個檔、同一個 mtime,現在靜置夠久了
        todo = self.plan(state, now=NOW + STABLE)
        self.assertEqual(self.names(todo), [os.path.basename(path)])

    def test_非_md_檔一律忽略(self):
        self.write_report("20260803-0130-cc1-筆記.txt", mtime=NOW - 10)
        state = fs.empty_state()
        self.assertEqual(self.plan(state), [])


class TestBackfill(ReportDirCase):
    """watcher 首次啟動時,報告目錄裡本來就有一堆舊檔。

    舊版不擋,一口氣把整個目錄洗版給指揮官(實際發生過,一次 6 則)。
    """

    def test_首次見到的舊報告只建基準線不通知(self):
        self.write_report("20260803-0130-cc1-上週的.md", mtime=NOW - BACKFILL - 1)
        state = fs.empty_state()
        self.assertEqual(self.plan(state), [])

    def test_建了基準線且標記_backfilled(self):
        name = "20260803-0130-cc1-上週的.md"
        self.write_report(name, mtime=NOW - BACKFILL - 1)
        state = fs.empty_state()
        self.plan(state)
        entry = state["reports"][name]
        self.assertTrue(entry["backfilled"])
        self.assertEqual(entry["notified_at"], 0)
        self.assertNotEqual(entry["hash"], "")

    def test_backfill_基準線建完後同一份不會再被通知(self):
        self.write_report("20260803-0130-cc1-上週的.md", mtime=NOW - BACKFILL - 1)
        state = fs.empty_state()
        self.plan(state)
        self.assertEqual(self.plan(state, now=NOW + 60), [])

    def test_首次啟動時整個目錄的舊檔一則都不通知(self):
        for i in range(6):
            self.write_report("20260801-01%02d-cc1-舊報告%d.md" % (i, i),
                              body="內容%d" % i,
                              mtime=NOW - BACKFILL - 100 - i)
        state = fs.empty_state()
        self.assertEqual(self.plan(state), [])
        self.assertEqual(len(state["reports"]), 6)

    def test_剛好在_backfill_界線內的新報告照常通知(self):
        # `now - mtime > backfill` 才算舊,等於門檻不算
        self.write_report("20260803-0130-cc1-剛好界線.md", mtime=NOW - BACKFILL)
        state = fs.empty_state()
        self.assertEqual(len(self.plan(state)), 1)

    def test_基準線建完後內容真的改了要能通知(self):
        name = "20260803-0130-cc1-上週的.md"
        path = self.write_report(name, body="舊", mtime=NOW - BACKFILL - 1)
        state = fs.empty_state()
        self.plan(state)
        with open(path, "w", encoding="utf-8") as fh:
            fh.write("補了新的一節")
        os.utime(path, (NOW - 10, NOW - 10))
        self.assertEqual(self.names(self.plan(state)), [name])


class TestContentHashDedup(ReportDirCase):
    """只有內容真的變了才通知。編輯器 touch / 重存同文不算。"""

    def _notified_once(self, name, body="第一版"):
        path = self.write_report(name, body=body, mtime=NOW - 10)
        state = fs.empty_state()
        todo = self.plan(state)
        self.assertEqual(len(todo), 1)
        fs.record_report(state, path, "ok", NOW, MAX_ATTEMPTS)
        return state, path

    def test_檔案被_touch_但內容沒變不再通知(self):
        name = "20260803-0130-cc1-修好登入.md"
        state, path = self._notified_once(name)
        os.utime(path, (NOW + 100, NOW + 100))
        self.assertEqual(self.plan(state, now=NOW + 200), [])

    def test_被_touch_後_state_的_mtime_有跟上(self):
        name = "20260803-0130-cc1-修好登入.md"
        state, path = self._notified_once(name)
        os.utime(path, (NOW + 100, NOW + 100))
        self.plan(state, now=NOW + 200)
        self.assertEqual(state["reports"][name]["mtime"], NOW + 100)

    def test_內容真的改了會再通知一次(self):
        name = "20260803-0130-cc1-修好登入.md"
        state, path = self._notified_once(name)
        with open(path, "w", encoding="utf-8") as fh:
            fh.write("第二版,補了驗收證據")
        os.utime(path, (NOW + 100, NOW + 100))
        todo = self.plan(state, now=NOW + 200)
        self.assertEqual(self.names(todo), [name])

    def test_內容改了但還沒靜置就先不通知(self):
        name = "20260803-0130-cc1-修好登入.md"
        state, path = self._notified_once(name)
        with open(path, "w", encoding="utf-8") as fh:
            fh.write("第二版")
        os.utime(path, (NOW + 100, NOW + 100))
        self.assertEqual(self.plan(state, now=NOW + 101), [])

    def test_通知成功後_record_report_會記下_hash_與時間(self):
        name = "20260803-0130-cc1-修好登入.md"
        state, path = self._notified_once(name)
        entry = state["reports"][name]
        self.assertEqual(entry["hash"], fs.file_md5(path))
        self.assertEqual(entry["notified_at"], NOW)
        self.assertEqual(entry["attempts"], 0)


class TestNotifyCooldown(ReportDirCase):
    """worker 交完報告後常會連續補寫幾次(補章節、補實際輸出、修 lint 格式)。

    每次存檔內容都真的變了,舊版於是每次都通知——實測
    20260806-1217-cc1-create-project-api.md 在 04:55:46 / 04:56:13 /
    04:56:26 / 04:56:50 連送四則,指揮官被同一份報告洗版。
    冷卻窗把這些補寫合併成一則。
    """

    COOLDOWN = 300

    def _notified_once(self, name, body="第一版"):
        path = self.write_report(name, body=body, mtime=NOW - 10)
        state = fs.empty_state()
        todo = self.plan(state, cooldown=self.COOLDOWN)
        self.assertEqual(len(todo), 1)
        fs.record_report(state, path, "ok", NOW, MAX_ATTEMPTS)
        return state, path

    def _rewrite(self, path, body, mtime):
        with open(path, "w", encoding="utf-8") as fh:
            fh.write(body)
        os.utime(path, (mtime, mtime))

    def test_冷卻窗內連續補寫只通知一次(self):
        name = "20260803-0130-cc1-修好登入.md"
        state, path = self._notified_once(name)
        # 首次通知後 27 秒內連改三次(重現實測的 04:55~04:56 那四則)
        for i, offset in enumerate((13, 27, 40)):
            self._rewrite(path, "補了第 %d 段" % i, NOW + offset)
            self.assertEqual(
                self.plan(state, now=NOW + offset + STABLE,
                          cooldown=self.COOLDOWN), [],
                "冷卻窗內第 %d 次補寫不該再通知" % (i + 1))

    def test_冷卻窗過了會把最新版補送一則(self):
        name = "20260803-0130-cc1-修好登入.md"
        state, path = self._notified_once(name)
        self._rewrite(path, "補了驗收證據", NOW + 30)
        self.assertEqual(self.plan(state, now=NOW + 60,
                                   cooldown=self.COOLDOWN), [])
        todo = self.plan(state, now=NOW + self.COOLDOWN + 1,
                         cooldown=self.COOLDOWN)
        self.assertEqual(self.names(todo), [name])

    def test_冷卻期間的修改不可被吃掉(self):
        # 冷卻窗內**刻意不更新 hash**:更新了的話,窗過了就認為「內容沒變」,
        # 那次補寫永久靜音——比洗版更糟,指揮官根本不知道報告改過。
        name = "20260803-0130-cc1-修好登入.md"
        state, path = self._notified_once(name)
        before = state["reports"][name]["hash"]
        self._rewrite(path, "冷卻期間補的內容", NOW + 30)
        self.plan(state, now=NOW + 60, cooldown=self.COOLDOWN)
        self.assertEqual(state["reports"][name]["hash"], before)

    def test_冷卻窗內_mtime_仍要跟上(self):
        name = "20260803-0130-cc1-修好登入.md"
        state, path = self._notified_once(name)
        self._rewrite(path, "補寫", NOW + 30)
        self.plan(state, now=NOW + 60, cooldown=self.COOLDOWN)
        self.assertEqual(state["reports"][name]["mtime"], NOW + 30)

    def test_冷卻設為零就是舊行為(self):
        # 關掉冷卻要能完全回到「內容變就通知」,否則沒有退路可退
        name = "20260803-0130-cc1-修好登入.md"
        state, path = self._notified_once(name)
        self._rewrite(path, "第二版", NOW + 30)
        self.assertEqual(
            self.names(self.plan(state, now=NOW + 60, cooldown=0)), [name])

    def test_沒通知過的報告不受冷卻影響(self):
        # backfill 建的基準線 notified_at=0,不能被當成「剛通知過」而靜音
        name = "20260803-0130-cc1-上週的.md"
        path = self.write_report(name, body="舊", mtime=NOW - BACKFILL - 1)
        state = fs.empty_state()
        self.plan(state, cooldown=self.COOLDOWN)
        self.assertEqual(state["reports"][name]["notified_at"], 0)
        self._rewrite(path, "補了新的一節", NOW - 10)
        self.assertEqual(
            self.names(self.plan(state, cooldown=self.COOLDOWN)), [name])

    def test_不同報告各自獨立冷卻(self):
        # 冷卻是 per-report,不能因為 A 剛通知就把 B 的通知一起吃掉
        state, _ = self._notified_once("20260803-0130-cc1-修好登入.md")
        self.write_report("20260803-0131-cx1-另一份.md", body="乙",
                          mtime=NOW + 10)
        todo = self.plan(state, now=NOW + 20, cooldown=self.COOLDOWN)
        self.assertEqual(self.names(todo), ["20260803-0131-cx1-另一份.md"])


class TestUtf8KeyCollision(ReportDirCase):
    """舊版用 `tr -c 'A-Za-z0-9_.-' '_'` 逐 byte 轉碼當 state 的 key。

    中文主題整段被壓成一串 `_`,於是同日、同 worker 的兩份中文報告
    key 完全一樣 → 後交的那份**永久靜音**。這是真的發生過的 bug,
    而且從指揮官的角度完全看不出來:worker 明明交了報告卻沒人叫他。
    """

    NAME_A = "20260803-0130-cc1-修好登入.md"
    NAME_B = "20260803-0130-cc1-修好登出.md"

    def test_同日同_worker_的兩份中文報告都要通知(self):
        self.write_report(self.NAME_A, body="登入那份", mtime=NOW - 10)
        self.write_report(self.NAME_B, body="登出那份", mtime=NOW - 9)
        state = fs.empty_state()
        todo = self.plan(state)
        self.assertEqual(sorted(self.names(todo)), sorted([self.NAME_A, self.NAME_B]))

    def test_兩份中文報告在_state_裡是兩個獨立的_key(self):
        pa = self.write_report(self.NAME_A, body="登入那份", mtime=NOW - 10)
        pb = self.write_report(self.NAME_B, body="登出那份", mtime=NOW - 9)
        state = fs.empty_state()
        self.plan(state)
        fs.record_report(state, pa, "ok", NOW, MAX_ATTEMPTS)
        fs.record_report(state, pb, "ok", NOW, MAX_ATTEMPTS)
        self.assertEqual(len(state["reports"]), 2)
        self.assertIn(self.NAME_A, state["reports"])
        self.assertIn(self.NAME_B, state["reports"])

    def test_通知過第一份之後第二份不會被連坐靜音(self):
        # 舊版就是死在這裡:A 通知完寫了 key,B 進來時看到同一個 key
        # 且 hash 對不上就一直被當成「同一份被改過」,永遠排不進通知。
        pa = self.write_report(self.NAME_A, body="登入那份", mtime=NOW - 10)
        state = fs.empty_state()
        self.plan(state)
        fs.record_report(state, pa, "ok", NOW, MAX_ATTEMPTS)
        self.write_report(self.NAME_B, body="登出那份", mtime=NOW + 50)
        todo = self.plan(state, now=NOW + 60)
        self.assertEqual(self.names(todo), [self.NAME_B])

    def test_兩份都通知過之後不會再重複通知(self):
        # 這條是 key 碰撞最直接的照妖鏡:兩份報告共用一個 entry 的話,
        # 那個 entry 的 hash 只會是「最後被記錄的那一份」。
        # 於是每一輪掃描都會有一份對不上 hash → 每 3 秒重播一次通知,
        # 兩份報告輪流洗版指揮官,而且永遠停不下來。
        pa = self.write_report(self.NAME_A, body="登入那份", mtime=NOW - 10)
        pb = self.write_report(self.NAME_B, body="登出那份", mtime=NOW - 9)
        state = fs.empty_state()
        self.plan(state)
        fs.record_report(state, pa, "ok", NOW, MAX_ATTEMPTS)
        fs.record_report(state, pb, "ok", NOW, MAX_ATTEMPTS)

        for i in range(5):
            self.assertEqual(
                self.plan(state, now=NOW + 10 * (i + 1)), [],
                "第 %d 輪:兩份都通知過了,不該再吐出任何一份" % i)

    def test_一份報告的失敗次數不可算到另一份頭上(self):
        # key 碰撞時熔斷計數會共用:A 送三次失敗把計數打滿,
        # 剛好同一秒落地的 B 一次都還沒送就被熔斷,永遠靜音。
        pa = self.write_report(self.NAME_A, body="登入那份", mtime=NOW - 10)
        self.write_report(self.NAME_B, body="登出那份", mtime=NOW - 10)
        state = fs.empty_state()
        for _ in range(MAX_ATTEMPTS):
            self.plan(state)
            fs.record_report(state, pa, "fail", NOW, MAX_ATTEMPTS)
        todo = self.names(self.plan(state))
        self.assertIn(self.NAME_B, todo, "B 一次都還沒送就被 A 的失敗次數熔斷了")
        self.assertNotIn(self.NAME_A, todo, "A 自己該熔斷")

    def test_state_檔以_UTF8_原文存_key_不轉碼(self):
        pa = self.write_report(self.NAME_A, body="登入那份", mtime=NOW - 10)
        state = fs.empty_state()
        self.plan(state)
        fs.record_report(state, pa, "ok", NOW, MAX_ATTEMPTS)
        out = os.path.join(self.dir, "state.json")
        fs.save_state(out, state)
        with open(out, "r", encoding="utf-8") as fh:
            data = json.load(fh)
        self.assertIn(self.NAME_A, data["reports"])
        self.assertNotIn("_" * 4, "".join(data["reports"].keys()))


class TestCircuitBreaker(ReportDirCase):
    """同一版連續驗不到就熔斷。寧漏勿轟——報告還在目錄裡,指揮官撈得到。"""

    NAME = "20260803-0130-cc1-修好登入.md"

    def _fail_n_times(self, state, path, n):
        for _ in range(n):
            todo = self.plan(state)
            self.assertEqual(len(todo), 1, "熔斷前每一輪都該吐出這份報告")
            fs.record_report(state, path, "fail", NOW, MAX_ATTEMPTS)

    def test_連續失敗未達上限仍會繼續嘗試(self):
        path = self.write_report(self.NAME, mtime=NOW - 10)
        state = fs.empty_state()
        self._fail_n_times(state, path, MAX_ATTEMPTS - 1)
        self.assertEqual(len(self.plan(state)), 1)

    def test_連續失敗達上限後不再吐出(self):
        path = self.write_report(self.NAME, mtime=NOW - 10)
        state = fs.empty_state()
        self._fail_n_times(state, path, MAX_ATTEMPTS)
        self.assertEqual(self.plan(state), [])

    def test_熔斷後再掃幾輪仍然不吐出(self):
        path = self.write_report(self.NAME, mtime=NOW - 10)
        state = fs.empty_state()
        self._fail_n_times(state, path, MAX_ATTEMPTS)
        for i in range(5):
            self.assertEqual(self.plan(state, now=NOW + 10 * i), [])

    def test_熔斷後內容改了要能恢復通知(self):
        # 熔斷是針對「這一版」,不是針對這個檔。改了內容代表有新東西要報。
        path = self.write_report(self.NAME, body="第一版", mtime=NOW - 10)
        state = fs.empty_state()
        self._fail_n_times(state, path, MAX_ATTEMPTS)
        self.assertEqual(self.plan(state), [])
        with open(path, "w", encoding="utf-8") as fh:
            fh.write("第二版")
        os.utime(path, (NOW + 100, NOW + 100))
        self.assertEqual(self.names(self.plan(state, now=NOW + 200)), [self.NAME])

    def test_恢復後失敗次數重新算(self):
        path = self.write_report(self.NAME, body="第一版", mtime=NOW - 10)
        state = fs.empty_state()
        self._fail_n_times(state, path, MAX_ATTEMPTS)
        with open(path, "w", encoding="utf-8") as fh:
            fh.write("第二版")
        os.utime(path, (NOW + 100, NOW + 100))
        self.plan(state, now=NOW + 200)
        fs.record_report(state, path, "fail", NOW + 200, MAX_ATTEMPTS)
        self.assertEqual(state["reports"][self.NAME]["attempts"], 1)

    def test_中途成功一次就把失敗次數歸零(self):
        path = self.write_report(self.NAME, mtime=NOW - 10)
        state = fs.empty_state()
        self._fail_n_times(state, path, MAX_ATTEMPTS - 1)
        fs.record_report(state, path, "ok", NOW, MAX_ATTEMPTS)
        self.assertEqual(state["reports"][self.NAME]["attempts"], 0)


class TestSkipNeverCountsAsAttempt(ReportDirCase):
    """`skip` 對應「使用者正在打字」與「TUI 沒起來」。

    這兩種情況我們**一個字都沒送出去**,記帳就是誣賴。記了的話:
    使用者連打三次字,報告就被熔斷、永遠不會被通知——
    而使用者只會覺得「AI 做完沒人叫我」,完全查不到原因。
    """

    NAME = "20260803-0130-cc1-修好登入.md"

    def test_連續_skip_一百次也不會熔斷(self):
        path = self.write_report(self.NAME, mtime=NOW - 10)
        state = fs.empty_state()
        for _ in range(100):
            fs.record_report(state, path, "skip", NOW, MAX_ATTEMPTS)
        self.assertEqual(self.names(self.plan(state)), [self.NAME])

    def test_skip_完全不寫任何欄位(self):
        path = self.write_report(self.NAME, mtime=NOW - 10)
        state = fs.empty_state()
        fs.record_report(state, path, "skip", NOW, MAX_ATTEMPTS)
        entry = state["reports"][self.NAME]
        self.assertEqual(entry.get("attempts", 0), 0)
        self.assertNotIn("attempt_mtime", entry)
        self.assertNotIn("notified_at", entry)
        self.assertNotIn("hash", entry)

    def test_每輪都_skip_時報告一直留在待通知清單(self):
        path = self.write_report(self.NAME, mtime=NOW - 10)
        state = fs.empty_state()
        for i in range(10):
            todo = self.plan(state, now=NOW + i)
            self.assertEqual(self.names(todo), [self.NAME],
                             "第 %d 輪:skip 之後通知不可遺失" % i)
            fs.record_report(state, path, "skip", NOW + i, MAX_ATTEMPTS)

    def test_skip_夾在失敗之間也不算一次(self):
        path = self.write_report(self.NAME, mtime=NOW - 10)
        state = fs.empty_state()
        fs.record_report(state, path, "fail", NOW, MAX_ATTEMPTS)
        for _ in range(20):
            fs.record_report(state, path, "skip", NOW, MAX_ATTEMPTS)
        fs.record_report(state, path, "fail", NOW, MAX_ATTEMPTS)
        self.assertEqual(state["reports"][self.NAME]["attempts"], 2)

    def test_檔案不存在時_record_report_不可爆掉(self):
        state = fs.empty_state()
        fs.record_report(state, os.path.join(self.dir, "不存在.md"),
                         "ok", NOW, MAX_ATTEMPTS)
        self.assertEqual(state["reports"], {})


# ---------------------------------------------------------------------------
# worker_tick
# ---------------------------------------------------------------------------

IDLE_SECS = 90
STUCK_SECS = 60
QUIET_AFTER = 300


class TestWorkerTickIdle(unittest.TestCase):

    def tick(self, state, busy, stuck, now, wid="cc1"):
        return fs.worker_tick(state, wid, busy, stuck, now,
                              IDLE_SECS, STUCK_SECS, QUIET_AFTER)

    def test_忙碌時記下_wasbusy_且不通知(self):
        state = fs.empty_state()
        self.assertEqual(self.tick(state, True, False, NOW), [])
        self.assertEqual(state["workers"]["cc1"]["wasbusy"], NOW)

    def test_由忙轉閒未達門檻不通知(self):
        state = fs.empty_state()
        self.tick(state, True, False, NOW)
        self.assertEqual(self.tick(state, False, False, NOW + IDLE_SECS - 1), [])

    def test_閒置超過門檻就發閒置警報(self):
        state = fs.empty_state()
        self.tick(state, True, False, NOW)
        self.assertEqual(
            self.tick(state, False, False, NOW + IDLE_SECS), ["notify-idle"])

    def test_從來沒忙過的_worker_不發閒置警報(self):
        # 沒有 wasbusy 基準點就沒有「由忙轉閒」這回事
        state = fs.empty_state()
        self.assertEqual(self.tick(state, False, False, NOW + 100000), [])

    def test_剛交過報告就閒下來不吵(self):
        state = fs.empty_state()
        fs.record_worker(state, "cc1", "report", NOW)
        self.tick(state, True, False, NOW + 1)
        self.assertEqual(
            self.tick(state, False, False, NOW + 1 + IDLE_SECS), [])

    def test_剛交過報告的靜默期會清掉_wasbusy_避免下輪立刻補噴(self):
        state = fs.empty_state()
        fs.record_worker(state, "cc1", "report", NOW)
        self.tick(state, True, False, NOW + 1)
        self.tick(state, False, False, NOW + 1 + IDLE_SECS)
        self.assertEqual(state["workers"]["cc1"]["wasbusy"], 0)

    def test_靜默期過了之後閒置仍要通知(self):
        state = fs.empty_state()
        fs.record_worker(state, "cc1", "report", NOW)
        self.tick(state, True, False, NOW + QUIET_AFTER)
        self.assertEqual(
            self.tick(state, False, False, NOW + QUIET_AFTER + IDLE_SECS),
            ["notify-idle"])

    def test_已通知過就不重複通知(self):
        state = fs.empty_state()
        self.tick(state, True, False, NOW)
        self.assertEqual(
            self.tick(state, False, False, NOW + IDLE_SECS), ["notify-idle"])
        fs.record_worker(state, "cc1", "idle-notified", NOW + IDLE_SECS)
        self.assertEqual(self.tick(state, False, False, NOW + IDLE_SECS + 10), [])

    def test_再次忙起來會清掉已通知旗標(self):
        state = fs.empty_state()
        self.tick(state, True, False, NOW)
        self.tick(state, False, False, NOW + IDLE_SECS)
        fs.record_worker(state, "cc1", "idle-notified", NOW + IDLE_SECS)
        self.tick(state, True, False, NOW + 200)
        self.assertFalse(state["workers"]["cc1"]["idle_notified"])
        self.assertEqual(
            self.tick(state, False, False, NOW + 200 + IDLE_SECS),
            ["notify-idle"])


class TestWorkerTickStuck(unittest.TestCase):

    def tick(self, state, busy, stuck, now, wid="cc1"):
        return fs.worker_tick(state, wid, busy, stuck, now,
                              IDLE_SECS, STUCK_SECS, QUIET_AFTER)

    def test_有卡住訊號但正在忙就不算卡住(self):
        # worker 忙的時候收到訊息會排隊並顯示排隊提示,做完自然會消化。
        # 不加這個條件會對每個忙碌中被追訊息的 worker 狂發假警報。
        state = fs.empty_state()
        for i in range(10):
            self.assertEqual(
                self.tick(state, True, True, NOW + i * STUCK_SECS), [],
                "忙碌中的排隊訊息不是卡住")

    def test_忙碌中的卡住訊號不會累積計時(self):
        state = fs.empty_state()
        self.tick(state, True, True, NOW)
        self.assertEqual(state["workers"]["cc1"]["stuck_since"], 0)

    def test_卡住但未達門檻不通知(self):
        state = fs.empty_state()
        self.tick(state, False, True, NOW)
        self.assertEqual(self.tick(state, False, True, NOW + STUCK_SECS - 1), [])

    def test_卡住超過門檻就發卡住警報(self):
        state = fs.empty_state()
        self.tick(state, False, True, NOW)
        self.assertEqual(
            self.tick(state, False, True, NOW + STUCK_SECS), ["notify-stuck"])

    def test_第一次看到卡住訊號只起算不通知(self):
        # 起算那一輪就通知的話,STUCK_SECS 等於形同虛設
        state = fs.empty_state()
        self.assertEqual(self.tick(state, False, True, NOW), [])
        self.assertEqual(state["workers"]["cc1"]["stuck_since"], NOW)

    def test_已通知過就不重複通知(self):
        state = fs.empty_state()
        self.tick(state, False, True, NOW)
        self.tick(state, False, True, NOW + STUCK_SECS)
        fs.record_worker(state, "cc1", "stuck-notified", NOW + STUCK_SECS)
        self.assertEqual(self.tick(state, False, True, NOW + STUCK_SECS * 2), [])

    def test_卡住訊號消失就把狀態歸零(self):
        state = fs.empty_state()
        self.tick(state, False, True, NOW)
        self.tick(state, False, True, NOW + STUCK_SECS)
        fs.record_worker(state, "cc1", "stuck-notified", NOW + STUCK_SECS)
        self.tick(state, False, False, NOW + STUCK_SECS + 10)
        w = state["workers"]["cc1"]
        self.assertEqual(w["stuck_since"], 0)
        self.assertFalse(w["stuck_notified"])

    def test_解開之後再卡住要能重新通知(self):
        state = fs.empty_state()
        self.tick(state, False, True, NOW)
        self.tick(state, False, True, NOW + STUCK_SECS)
        fs.record_worker(state, "cc1", "stuck-notified", NOW + STUCK_SECS)
        self.tick(state, False, False, NOW + STUCK_SECS + 10)
        t = NOW + STUCK_SECS + 20
        self.tick(state, False, True, t)
        self.assertEqual(
            self.tick(state, False, True, t + STUCK_SECS), ["notify-stuck"])

    def test_忙起來也會把卡住狀態歸零(self):
        state = fs.empty_state()
        self.tick(state, False, True, NOW)
        self.tick(state, True, True, NOW + 10)
        self.assertEqual(state["workers"]["cc1"]["stuck_since"], 0)


class TestRecordWorker(unittest.TestCase):

    def test_交報告事件會清掉_wasbusy_與已通知旗標(self):
        state = fs.empty_state()
        w = fs.worker_entry(state, "cc1")
        w["wasbusy"] = NOW - 500
        w["idle_notified"] = True
        fs.record_worker(state, "cc1", "report", NOW)
        self.assertEqual(w["lastreport"], NOW)
        self.assertEqual(w["wasbusy"], 0)
        self.assertFalse(w["idle_notified"])

    def test_worker_entry_會補齊所有預設欄位(self):
        state = fs.empty_state()
        w = fs.worker_entry(state, "新來的")
        self.assertEqual(
            sorted(w.keys()),
            sorted(["wasbusy", "lastreport", "stuck_since",
                    "stuck_notified", "idle_notified"]))


# ---------------------------------------------------------------------------
# gc
# ---------------------------------------------------------------------------

class TestGc(ReportDirCase):

    def test_報告檔已刪除就移除對應_entry(self):
        name = "20260803-0130-cc1-已刪.md"
        path = self.write_report(name, mtime=NOW - 10)
        state = fs.empty_state()
        state["reports"][name] = {"mtime": NOW - 10, "hash": "x", "attempts": 0}
        os.remove(path)
        nr, _ = fs.gc(state, [self.dir], IDS)
        self.assertEqual(nr, 1)
        self.assertNotIn(name, state["reports"])

    def test_還在的報告要保留(self):
        name = "20260803-0130-cc1-還在.md"
        self.write_report(name, mtime=NOW - 10)
        state = fs.empty_state()
        state["reports"][name] = {"mtime": NOW - 10, "hash": "x", "attempts": 0}
        nr, _ = fs.gc(state, [self.dir], IDS)
        self.assertEqual(nr, 0)
        self.assertIn(name, state["reports"])

    def test_不在_registry_的_worker_要移除(self):
        state = fs.empty_state()
        fs.worker_entry(state, "cc1")
        fs.worker_entry(state, "已退役")
        _, nw = fs.gc(state, [self.dir], IDS)
        self.assertEqual(nw, 1)
        self.assertIn("cc1", state["workers"])
        self.assertNotIn("已退役", state["workers"])

    def test_registry_裡的_worker_全部保留(self):
        state = fs.empty_state()
        for wid in IDS:
            fs.worker_entry(state, wid)
        _, nw = fs.gc(state, [self.dir], IDS)
        self.assertEqual(nw, 0)
        self.assertEqual(sorted(state["workers"].keys()), sorted(IDS))

    def test_空_registry_會清光所有_worker_記錄(self):
        state = fs.empty_state()
        fs.worker_entry(state, "cc1")
        _, nw = fs.gc(state, [self.dir], [])
        self.assertEqual(nw, 1)
        self.assertEqual(state["workers"], {})

    def test_同時清報告與_worker_並回報筆數(self):
        state = fs.empty_state()
        state["reports"]["不存在的.md"] = {"mtime": 1, "hash": "x"}
        state["reports"]["也不存在的.md"] = {"mtime": 1, "hash": "x"}
        fs.worker_entry(state, "幽靈")
        self.assertEqual(fs.gc(state, [self.dir], IDS), (2, 1))

    def test_報告目錄不存在時不可爆掉(self):
        state = fs.empty_state()
        state["reports"]["某份.md"] = {"mtime": 1, "hash": "x"}
        nr, _ = fs.gc(state, [os.path.join(self.dir, "沒有這個目錄")], IDS)
        self.assertEqual(nr, 1)


# ---------------------------------------------------------------------------
# load_state / save_state
# ---------------------------------------------------------------------------

class TestLoadState(unittest.TestCase):

    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.dir = self._tmp.name
        self.addCleanup(self._tmp.cleanup)
        self.path = os.path.join(self.dir, "state.json")

    def test_檔案不存在回空狀態(self):
        self.assertEqual(fs.load_state(self.path), fs.empty_state())

    def test_壞掉的_JSON_回空狀態(self):
        with open(self.path, "w", encoding="utf-8") as fh:
            fh.write("{這不是 JSON")
        self.assertEqual(fs.load_state(self.path), fs.empty_state())

    def test_壞掉的_JSON_會備份成_corrupt(self):
        # 壞檔不該讓整套艦隊停擺:備份後重新開始。
        # 最壞情況是重播一次通知,比永久卡死好。
        with open(self.path, "w", encoding="utf-8") as fh:
            fh.write("{這不是 JSON")
        fs.load_state(self.path)
        self.assertTrue(os.path.exists(self.path + ".corrupt"))
        self.assertFalse(os.path.exists(self.path))

    def test_備份檔留著原本壞掉的內容(self):
        with open(self.path, "w", encoding="utf-8") as fh:
            fh.write("{這不是 JSON")
        fs.load_state(self.path)
        with open(self.path + ".corrupt", "r", encoding="utf-8") as fh:
            self.assertEqual(fh.read(), "{這不是 JSON")

    def test_內容不是物件也回空狀態(self):
        with open(self.path, "w", encoding="utf-8") as fh:
            fh.write("[1, 2, 3]")
        self.assertEqual(fs.load_state(self.path), fs.empty_state())

    def test_缺欄位的舊_state_會補齊(self):
        with open(self.path, "w", encoding="utf-8") as fh:
            json.dump({"reports": {"a.md": {}}}, fh)
        state = fs.load_state(self.path)
        self.assertEqual(state["workers"], {})
        self.assertEqual(state["version"], fs.SCHEMA_VERSION)
        self.assertIn("a.md", state["reports"])

    def test_存檔再讀回來內容一致含中文_key(self):
        state = fs.empty_state()
        state["reports"]["20260803-0130-cc1-修好登入.md"] = {
            "mtime": NOW, "hash": "abc", "attempts": 0, "notified_at": NOW}
        fs.save_state(self.path, state)
        self.assertEqual(fs.load_state(self.path), state)

    def test_存檔會建出不存在的目錄(self):
        deep = os.path.join(self.dir, "a", "b", "state.json")
        fs.save_state(deep, fs.empty_state())
        self.assertTrue(os.path.isfile(deep))

    def test_存檔後不留下暫存檔(self):
        fs.save_state(self.path, fs.empty_state())
        leftovers = [n for n in os.listdir(self.dir) if ".tmp." in n]
        self.assertEqual(leftovers, [])


# ---------------------------------------------------------------------------
# 小工具
# ---------------------------------------------------------------------------

class TestSplitIds(unittest.TestCase):

    def test_空字串回空清單(self):
        self.assertEqual(fs.split_ids(""), [])
        self.assertEqual(fs.split_ids(None), [])

    def test_多餘空白與換行都吃得下(self):
        # watcher 傳進來的是 `reg_ids | tr '\n' ' '`,結尾一定有空白
        self.assertEqual(fs.split_ids("cc1 cx1 \n"), ["cc1", "cx1"])


class TestScanDirs(ReportDirCase):

    def test_依_mtime_由舊到新排序(self):
        self.write_report("b.md", mtime=NOW - 5)
        self.write_report("a.md", mtime=NOW - 50)
        self.write_report("c.md", mtime=NOW - 1)
        got = [n for _, n, _ in fs.scan_dirs([self.dir])]
        self.assertEqual(got, ["a.md", "b.md", "c.md"])

    def test_同一個實體檔透過兩個目錄只算一次(self):
        # 報告目錄常見用 symlink 串在一起,去重沒做就會通知兩遍
        self.write_report("x.md", mtime=NOW - 5)
        other = os.path.join(self.dir, "link")
        os.symlink(self.dir, other)
        got = fs.scan_dirs([self.dir, other])
        self.assertEqual(len(got), 1)


if __name__ == "__main__":
    unittest.main()
