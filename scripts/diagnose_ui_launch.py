"""Capture the CI host's stacks if the first XCUIApplication.launch() is slow."""
from datetime import datetime, timezone
from pathlib import Path
import os
import subprocess
import sys
import time
import uuid
from concurrent.futures import ThreadPoolExecutor


DEVICES = Path.home() / "Library/Developer/CoreSimulator/Devices"
CAPTURE_AT_SECONDS = (25, 45)


def collect(args, destination, timeout):
    with destination.open("w") as log:
        try:
            result = subprocess.run(args, stdout=log, stderr=subprocess.STDOUT, timeout=timeout)
            if result.returncode:
                print(f"Command exited {result.returncode}", file=log)
        except (OSError, subprocess.TimeoutExpired) as error:
            print(error, file=log)


def capture(output, marker, build_pid, timeline):
    output.mkdir()
    device = marker.relative_to(DEVICES).parts[0]
    apps = []
    with ThreadPoolExecutor(max_workers=2) as executor:
        def sample(name, pid):
            collect(["/usr/bin/sample", str(pid), "2", "10", "-file", str(output / f"{name}.sample.txt")],
                    output / f"{name}.sample-status.txt", 15)

        executor.submit(sample, "xcodebuild", build_pid)
        # Match this simulator and bundle. An install or debugger stall may leave no App PID yet.
        collect(["ps", "-Aww", "-o", "pid=,%cpu=,rss=,comm="], output / "processes.txt", 3)
        for line in (output / "processes.txt").read_text().splitlines():
            fields = line.strip().split(None, 3)
            if len(fields) == 4 and f"/Devices/{device}/" in fields[3] and fields[3].endswith("/Palvia.app/Palvia"):
                apps.append(fields[0])
        print(f"simulator={device} xcodebuild_pid={build_pid} Palvia_pids={apps}", file=timeline, flush=True)
        if len(apps) == 1:
            executor.submit(sample, "Palvia", apps[0])
        collect(["vm_stat"], output / "vm-stat.txt", 3)
        collect(["sysctl", "hw.logicalcpu", "hw.memsize", "vm.loadavg", "vm.swapusage"],
                output / "host.txt", 3)


def monitor(build, token, output):
    pattern = f"*/data/Containers/Data/Application/*/tmp/palvia-launch-{token}.started"
    marker = None
    captures = iter(CAPTURE_AT_SECONDS)
    next_capture = next(captures)
    with (output / "timeline.txt").open("w", buffering=1) as timeline:
        while build.poll() is None:
            if marker is None:
                marker = next(DEVICES.glob(pattern), None)
                if marker:
                    began = marker.stat().st_mtime
                    print(datetime.fromtimestamp(began, timezone.utc).isoformat(), "launch started",
                          marker.read_text().strip(), file=timeline)
            if marker:
                returned = marker.with_suffix(".returned")
                if returned.exists():
                    stamp = datetime.fromtimestamp(returned.stat().st_mtime, timezone.utc)
                    print(stamp.isoformat(), "launch returned", file=timeline)
                    return
                if time.time() - began >= next_capture:
                    print(datetime.now(timezone.utc).isoformat(), "collecting stacks", file=timeline)
                    capture(output / f"{next_capture}s", marker, build.pid, timeline)
                    next_capture = next(captures, None)
                    if next_capture is None:
                        return
            time.sleep(2)
        if marker is None:
            print("xcodebuild exited before a launch marker was observed", file=timeline)


def main():
    output = Path(sys.argv[1])
    token = str(uuid.uuid4())
    environment = {**os.environ, "TEST_RUNNER_PALVIA_LAUNCH_PROBE": token}
    with subprocess.Popen(["xcodebuild", *sys.argv[2:]], env=environment) as build:
        try:
            output.mkdir(parents=True, exist_ok=True)
            monitor(build, token, output)
        except Exception as error:
            print(f"UI launch diagnostics: {error}", file=sys.stderr)
        return build.wait()


if __name__ == "__main__":
    sys.exit(main())
