"""Collect lightweight host metrics until the one-case XCTest run finishes."""
import datetime
import pathlib
import re
import subprocess
import sys
import time

output = pathlib.Path(sys.argv[1])
started = None
sampled = False
samplers = []

def command(*args):
    return subprocess.run(args, capture_output=True, text=True, check=False).stdout

with (output / "resources.log").open("w", buffering=1) as metrics:
    while not (output / "done").exists():
        timestamp = datetime.datetime.now(datetime.timezone.utc).isoformat()
        print(timestamp, file=metrics)
        vm = command("vm_stat")
        for line in vm.splitlines():
            if re.search(r"page size|Pages free|Pages occupied by compressor|Pageouts|Swapins|Swapouts", line):
                print(line, file=metrics)
        print(command("sysctl", "vm.loadavg", "vm.swapusage").strip(), file=metrics)
        rows = []
        targets = {}
        for line in command("ps", "-A", "-o", "pid=,pcpu=,rss=,comm=").splitlines():
            parts = line.strip().split(None, 3)
            if len(parts) != 4:
                continue
            pid, cpu, rss, path = parts
            name = pathlib.Path(path).name
            if name in {"Palvia", "xcodebuild", "PalviaUITests-Runner", "CoreSimulatorService", "testmanagerd"}:
                targets.setdefault(name, []).append(pid)
            rows.append((float(cpu), name, pid, rss))
        for cpu, name, pid, rss in sorted(rows, reverse=True)[:7]:
            print(f"top pid={pid} cpu={cpu}% rssKiB={rss} {name}", file=metrics)
        if "Palvia" in targets and started is None:
            started = time.monotonic()
            print(f"First observed Palvia PID {targets['Palvia'][0]}", file=metrics)
        if started is not None and not sampled and time.monotonic() - started >= 25:
            log = output / "xcode.log"
            activity = log.read_text(errors="replace") if log.exists() else ""
            if "Setting up automation session" not in activity and "Tap " not in activity:
                for name in ("Palvia", "xcodebuild"):
                    for pid in targets.get(name, []):
                        samplers.append(subprocess.Popen(["sample", pid, "2", "10", "-file", str(output / f"{name}-{pid}.sample")], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL))
            sampled = True
        time.sleep(4)
for process in samplers:
    process.wait()
