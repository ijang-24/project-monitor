#!/usr/bin/env python3
"""Pengujian stdlib: CLI Bash aktual, metrik, log, dan interaksi terminal PTY.
Jalankan: python3 -I tests/test_monitor.py
Tidak ada dependensi Python untuk aplikasi monitor.sh.
"""
import errno
import fcntl
import os
from pathlib import Path
import pty
import re
import select
import shutil
import signal
import struct
import subprocess
import tempfile
import termios
import time
import unittest

ROOT = Path(__file__).resolve().parents[1]
APP = ROOT / "monitor.sh"


def run(*args, env=None, cwd=ROOT):
    return subprocess.run(args, cwd=cwd, env=env, text=True, capture_output=True, timeout=15)


class Terminal:
    def __init__(self, app=APP, rows=40, cols=100, extra_env=None):
        self.master, self.slave = pty.openpty()
        fcntl.ioctl(self.slave, termios.TIOCSWINSZ, struct.pack("HHHH", rows, cols, 0, 0))
        self.original = termios.tcgetattr(self.slave)
        env = dict(os.environ, TERM="xterm-256color", NEONPULSE_REFRESH="1", NEONPULSE_LOG_INTERVAL="2")
        env.update(extra_env or {})
        self.proc = subprocess.Popen([str(app)], stdin=self.slave, stdout=self.slave,
                                     stderr=self.slave, env=env, cwd=ROOT,
                                     start_new_session=True)
        self.data = b""
        self.closed = False

    def pump(self, duration=0.1):
        deadline = time.monotonic() + duration
        while time.monotonic() < deadline:
            ready, _, _ = select.select([self.master], [], [], max(0, deadline-time.monotonic()))
            if ready:
                try:
                    chunk = os.read(self.master, 65536)
                except OSError as exc:
                    if exc.errno == errno.EIO:
                        break
                    raise
                if not chunk:
                    break
                self.data += chunk
        return self.data.decode("utf-8", errors="replace")

    def wait(self, marker, after=0, timeout=6):
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            self.pump(0.05)
            if marker in self.data[after:].decode("utf-8", errors="replace"):
                return
            if self.proc.poll() is not None:
                break
        raise AssertionError(f"Marker terminal tidak ditemukan: {marker!r}; output={self.data[-1800:]!r}")

    def key(self, key, marker):
        start = len(self.data)
        os.write(self.master, key.encode())
        self.wait(marker, start)

    def resize(self, rows, cols):
        start = len(self.data)
        fcntl.ioctl(self.slave, termios.TIOCSWINSZ, struct.pack("HHHH", rows, cols, 0, 0))
        self.proc.send_signal(signal.SIGWINCH)
        return start

    def quit(self):
        os.write(self.master, b"q")
        code = self.proc.wait(timeout=5)
        self.pump(0.15)
        return code

    def close(self):
        if self.closed:
            return
        if self.proc.poll() is None:
            self.proc.send_signal(signal.SIGTERM)
            self.proc.wait(timeout=5)
        self.pump(0.05)
        os.close(self.master)
        os.close(self.slave)
        self.closed = True


def strip_ansi(text):
    return re.sub(r"\x1b\[[0-?]*[ -/]*[@-~]", "", text)


def latest_frame(data):
    text = data.decode("utf-8", errors="replace")
    start = text.rfind("\x1b[H")
    return strip_ansi(text[start:]).replace("\r", "")


class MonitorTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.work = tempfile.TemporaryDirectory(prefix="neonpulse-", dir=ROOT / "tests")
        cls.sandbox = Path(cls.work.name)
        cls.app = cls.sandbox / "monitor.sh"
        shutil.copy2(APP, cls.app)

    @classmethod
    def tearDownClass(cls):
        cls.work.cleanup()

    def test_01_syntax_permissions_and_backup(self):
        result = run("bash", "-n", str(APP))
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue(os.access(APP, os.X_OK))
        backup = ROOT / "monitor-backup.sh"
        self.assertTrue(backup.read_text().lstrip().startswith("local "))
        self.assertNotEqual(run("bash", "-n", str(backup)).returncode, 0)

    def test_02_real_metrics(self):
        result = run(str(APP), "--once")
        self.assertEqual(result.returncode, 0, result.stderr)
        text = result.stdout
        self.assertNotIn("\x1b", text)
        self.assertIn(subprocess.check_output(["hostname"], text=True).strip(), text)
        self.assertIn(subprocess.check_output(["uname", "-sr"], text=True).strip(), text)
        cpu = re.search(r"CPU: ([\d.]+)%.*Valid sample: (\d)", text)
        self.assertIsNotNone(cpu)
        self.assertEqual(cpu[2], "1")
        self.assertTrue(0 <= float(cpu[1]) <= 100)
        ram = re.search(r"RAM: (\d+)/(\d+) MiB \(([\d.]+)%\) \| Available: (\d+)", text)
        self.assertIsNotNone(ram)
        mem = {line.split(":")[0]: int(line.split()[1]) for line in Path("/proc/meminfo").read_text().splitlines()}
        self.assertEqual(int(ram[2]), mem["MemTotal"]//1024)
        self.assertLessEqual(abs(int(ram[1])+int(ram[4])-int(ram[2])), 2)
        self.assertAlmostEqual(float(ram[3]), 100*int(ram[1])/int(ram[2]), delta=0.2)
        self.assertLess(abs(int(ram[4])-mem["MemAvailable"]//1024), 1024)
        self.assertRegex(text, r"Process count \(all\): [1-9]\d* \| Running \(R\): \d+ \| Valid ps: 1")
        self.assertIn("Valid df: 1", text)
        df_count = len(subprocess.check_output(["df", "-hP"], text=True).splitlines())-1
        self.assertIn(f"All filesystems ({df_count}):", text)
        top = text.split("Top 5 CPU processes", 1)[1].split("=== END", 1)[0].splitlines()[2:]
        self.assertEqual(len(top), 5)
        percentages = [float(row.split()[-3]) for row in top]
        self.assertEqual(percentages, sorted(percentages, reverse=True))
        (ROOT / "tests/snapshot.txt").write_text(text)

    def test_03_append_timestamp_and_path(self):
        logfile = self.sandbox / "logs/monitor.log"
        first = run(str(self.app), "--snapshot", cwd=ROOT / "tests")
        self.assertEqual(first.returncode, 0, first.stderr)
        before = logfile.read_bytes()
        second = run(str(self.app), "--snapshot", cwd=ROOT)
        self.assertEqual(second.returncode, 0, second.stderr)
        after = logfile.read_bytes()
        self.assertTrue(after.startswith(before))
        self.assertEqual(after.count(b"=== NEONPULSE SNAPSHOT"), 2)
        self.assertNotIn(b"\x1b", after)
        self.assertRegex(after.decode(), r"SNAPSHOT \d{4}-\d\d-\d\d \d\d:\d\d:\d\d [+-]\d{4}")
        self.assertIn(b"Hostname:", after)
        self.assertIn(b"All filesystems", after)

    def test_04_invalid_config_and_non_tty(self):
        result = run(str(APP))
        self.assertEqual(result.returncode, 1)
        self.assertIn("terminal interaktif", result.stderr)
        for key, value in [("NEONPULSE_REFRESH", "0"), ("NEONPULSE_WARN", "bad"),
                           ("NEONPULSE_LOG_KEEP", "99"), ("NEONPULSE_CRIT", "50")]:
            env = dict(os.environ, **{key: value})
            self.assertEqual(run(str(APP), "--once", env=env).returncode, 1)
        self.assertEqual(run(str(APP), "--unknown").returncode, 2)
        self.assertEqual(run(str(APP), "--help").returncode, 0)

    def test_05_deterministic_cpu_math_and_bar(self):
        script = r'''
source "$1"
validate_integer REFRESH 08 1 10 || exit 1
[[ $REFRESH == 8 ]] || exit 2
# Mock hanya read /proc/stat untuk menguji rumus; aplikasi tetap memakai /proc asli.
read() {
  if [[ $* == *label* ]]; then
    label=cpu; user=160; nice=20; sys=40; idle=170; iowait=10
    irq=0; softirq=0; steal=0; rest='999 888'
  else builtin read "$@"; fi
}
prev_total=200; prev_idle=100
cpu_sample
[[ $cpu_display == 60.0 && $cpu_ok == 1 ]] || exit 3
unset -f read
setup_style
status_style 70 "$CYAN"; [[ $STATUS == '! WASPADA' ]] || exit 4
status_style 90 "$CYAN"; [[ $STATUS == '!! KRITIS' ]] || exit 5
status_style 99 "$CYAN" 0; [[ $STATUS == 'N/A' ]] || exit 6
COLOR=0; ASCII=1; setup_style
[[ $(bar 150 10) == '##########' ]] || exit 7
[[ $(bar -2 10) == '----------' ]] || exit 8
safe_text $'bad\e[31m\tname'; [[ $REPLY != *$'\e'* && $REPLY != *$'\t'* ]] || exit 9
'''
        result = run("bash", "-c", script, "test", str(APP))
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_06_rotation_and_concurrent_append(self):
        rotation = self.sandbox / "rotation"
        rotation.mkdir()
        app = rotation / "monitor.sh"
        shutil.copy2(APP, app)
        env = dict(os.environ, NEONPULSE_LOG_MAX_BYTES="4096", NEONPULSE_LOG_KEEP="2")
        for _ in range(9):
            result = run(str(app), "--snapshot", env=env)
            self.assertEqual(result.returncode, 0, result.stderr)
        logs = sorted((rotation / "logs").glob("monitor.log*"))
        self.assertEqual([p.name for p in logs], ["monitor.log", "monitor.log.1", "monitor.log.2"])
        for path in logs:
            content = path.read_bytes()
            self.assertTrue(content.endswith(b"=== END SNAPSHOT ===\n"))
            # Allow one oversized snapshot, documented in README.
            if content.count(b"=== NEONPULSE SNAPSHOT") > 1:
                self.assertLessEqual(path.stat().st_size, 4096)
        concurrent = self.sandbox / "concurrent"
        concurrent.mkdir()
        target = concurrent / "monitor.sh"
        shutil.copy2(APP, target)
        jobs = [subprocess.Popen([str(target), "--snapshot"], stdout=subprocess.PIPE, stderr=subprocess.PIPE) for _ in range(4)]
        for job in jobs:
            out, err = job.communicate(timeout=15)
            self.assertEqual(job.returncode, 0, err)
        content = (concurrent / "logs/monitor.log").read_text()
        self.assertEqual(content.count("=== NEONPULSE SNAPSHOT"), 4)
        self.assertEqual(content.count("=== END SNAPSHOT"), 4)
        boundaries = re.findall(r"^=== (NEONPULSE SNAPSHOT|END SNAPSHOT)", content, re.MULTILINE)
        self.assertEqual(boundaries, ["NEONPULSE SNAPSHOT", "END SNAPSHOT"] * 4)

    def test_07_log_failure_is_reported(self):
        blocked = self.sandbox / "blocked"
        blocked.mkdir()
        target = blocked / "monitor.sh"
        shutil.copy2(APP, target)
        (blocked / "logs").write_text("not a directory")
        result = run(str(target), "--snapshot")
        self.assertEqual(result.returncode, 1)
        self.assertIn("Direktori log", result.stderr)

    def test_08_pty_navigation_refresh_logging_resize_cleanup(self):
        term = Terminal(self.app)
        try:
            term.wait("SYSTEM ONLINE")
            term.wait("PROCESS GRID")
            term.pump(0.15)
            dashboard = latest_frame(term.data)
            (ROOT / "tests/dashboard.txt").write_text(dashboard)
            for line in dashboard.splitlines():
                self.assertLessEqual(len(line), 99, line)
            self.assertLessEqual(len(dashboard.splitlines()), 40)
            self.assertTrue(dashboard.rstrip().endswith("╯"))
            initial = len(term.data)
            # Tunggu refresh tanpa input keyboard.
            term.wait("SYSTEM ONLINE", after=initial, timeout=3)
            logfile = self.sandbox / "logs/monitor.log"
            before_count = logfile.read_bytes().count(b"=== NEONPULSE SNAPSHOT")
            term.wait("AUTO LOG tersimpan", after=initial, timeout=4)
            self.assertGreater(logfile.read_bytes().count(b"=== NEONPULSE SNAPSHOT"), before_count)
            for key, marker in [("1", "Model:"), ("2", "Swap:"), ("3", "Root:"),
                                ("4", "CPU% ps ="), ("h", "OPERATOR MANUAL"), ("0", "MEMORY BANK")]:
                term.key(key, marker)
            term.key("]", "[2/")
            term.key("[", "[1/")
            term.key("L", "MANUAL LOG tersimpan")
            start = term.resize(12, 40)
            term.wait("Terminal terlalu kecil", start)
            term.key("l", "Terminal terlalu kecil")
            start = term.resize(30, 76)
            term.wait("SYSTEM ONLINE", start)
            term.pump(0.1)
            minimum = latest_frame(term.data)
            (ROOT / "tests/dashboard-minimum.txt").write_text(minimum)
            self.assertEqual(len(minimum.splitlines()), 30)
            for line in minimum.splitlines():
                self.assertLessEqual(len(line), 75, line)
            self.assertTrue(minimum.rstrip().endswith("╯"))
            self.assertEqual(term.quit(), 0)
            self.assertEqual(termios.tcgetattr(term.slave), term.original)
            self.assertIn(b"\x1b[?25h\x1b[?1049l", term.data)
            (ROOT / "tests/terminal-session.ansi").write_bytes(term.data)
        finally:
            term.close()

    def test_09_signal_cleanup(self):
        for sig, expected in [(signal.SIGINT, 130), (signal.SIGTERM, 143), (signal.SIGHUP, 129)]:
            term = Terminal(self.app)
            try:
                term.wait("SYSTEM ONLINE")
                term.proc.send_signal(sig)
                self.assertEqual(term.proc.wait(timeout=5), expected)
                term.pump(0.1)
                self.assertEqual(termios.tcgetattr(term.slave), term.original)
                self.assertIn(b"\x1b[?25h\x1b[?1049l", term.data)
            finally:
                term.close()

    def test_10_ascii_no_color_and_idle_cpu(self):
        term = Terminal(self.app, extra_env={"NO_COLOR": "1", "NEONPULSE_ASCII": "1"})
        try:
            term.wait("SYSTEM ONLINE")
            term.pump(0.15)
            self.assertNotRegex(term.data.decode(), r"\x1b\[[\d;]*m")
            self.assertIn(b"+---", term.data)
            self.assertNotIn("╭".encode(), term.data)
            # Bash utama: sampling /proc/PID/stat (anak ps/df dilaporkan terpisah).
            before = Path(f"/proc/{term.proc.pid}/stat").read_text().split()
            start = time.monotonic()
            term.pump(3.0)
            after = Path(f"/proc/{term.proc.pid}/stat").read_text().split()
            ticks = sum(int(after[i])-int(before[i]) for i in (13, 14, 15, 16))
            cpu = 100*ticks/os.sysconf("SC_CLK_TCK")/(time.monotonic()-start)
            (ROOT / "tests/idle-cpu.txt").write_text(f"Bash + waited children CPU: {cpu:.2f}% of one core over ~3s\n")
            self.assertLess(cpu, 25, f"Unexpected busy loop: {cpu:.2f}%")
            self.assertEqual(term.quit(), 0)
        finally:
            term.close()

    def test_11_missing_commands_and_partial_metric_failures(self):
        missing = self.sandbox / "missing-tools"
        missing.mkdir()
        env = dict(os.environ, PATH=str(missing))
        result = run("/bin/bash", str(APP), "--once", env=env)
        self.assertEqual(result.returncode, 1)
        self.assertIn("Perintah wajib tidak tersedia", result.stderr)
        script = r'''
source "$1"
ps() { return 1; }
df() { return 1; }
process_values
[[ $proc_ok == 0 && $process_count == 0 ]] || exit 1
root_values
[[ $disk_ok == 0 && ${#disks[@]} == 0 ]] || exit 2
'''
        result = run("bash", "-c", script, "test", str(APP))
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_12_default_refresh_and_auto_log_interval(self):
        term = Terminal(self.app, extra_env={"NEONPULSE_REFRESH": "2", "NEONPULSE_LOG_INTERVAL": "10"})
        try:
            term.wait("SYSTEM ONLINE")
            term.pump(0.15)
            frame = latest_frame(term.data)
            self.assertIn("2s LIVE / 10s LOG", frame)
            start = len(term.data)
            term.wait("SYSTEM ONLINE", after=start, timeout=4)
            term.wait("AUTO LOG tersimpan", after=start, timeout=12)
            self.assertEqual(term.quit(), 0)
        finally:
            term.close()


if __name__ == "__main__":
    unittest.main(verbosity=2)
