#!/usr/bin/env python3
"""GPU, CPU and memory for Flick in each state, against Flick being off.

WindowServer does the drawing for every app, so Flick's real cost shows up there. Each state
is measured in turn, alternating with Flick off, and the rounds are averaged because whatever
else the Mac is doing changes the numbers. No sudo needed. Doesn't move focus.

  tools/perf.py [--rounds 3] [--seconds 8] [--states off,idle,after-grid] [--out report.txt]
"""
import argparse, os, re, subprocess, tempfile, time

APP = "/Applications/Flick.app"
LABEL = "local.flick.app"
AGENT = os.path.expanduser(f"~/Library/LaunchAgents/{LABEL}.plist")
DOMAIN = f"gui/{os.getuid()}"
ALL_STATES = ["off", "idle", "after-panel", "after-grid", "open-panel", "open-grid", "opening", "closing", "animating"]


EXTRA_ENV = []


def sh(*args):
    return subprocess.run(args, capture_output=True, text=True).stdout


def gpu_times():
    """Nanoseconds of GPU time so far, by process."""
    out = sh("ioreg", "-r", "-c", "IOAccelerator", "-l", "-w", "0")
    totals, pending = {}, 0
    for line in out.splitlines():
        if '"AppUsage"' in line:
            pending = sum(int(v) for v in re.findall(r'"accumulatedGPUTime"=(\d+)', line))
        else:
            m = re.search(r'"IOUserClientCreator" = "pid (\d+), (.+?)"', line)
            if m:
                name = m.group(2)
                totals[name] = totals.get(name, 0) + pending
                pending = 0
    return totals


def device_percent():
    m = re.search(r'"Device Utilization %"=(\d+)', sh("ioreg", "-r", "-d", "1", "-w", "0", "-c", "IOAccelerator"))
    return int(m.group(1)) if m else 0


def flick_pid():
    out = sh("pgrep", "-x", "Flick").split()
    return int(out[0]) if out else None


def cpu_seconds(pid):
    t = sh("ps", "-o", "cputime=", "-p", str(pid)).strip()
    if not t:
        return 0.0
    parts = [float(x) for x in t.split(":")]
    return sum(v * 60 ** i for i, v in enumerate(reversed(parts)))


def wait_gone():
    for _ in range(80):
        if flick_pid() is None:
            return
        time.sleep(0.1)


def stop():
    sh("launchctl", "bootout", f"{DOMAIN}/{LABEL}")
    sh("pkill", "-x", "Flick")
    wait_gone()


def restore():
    stop()
    if os.path.exists(AGENT):
        sh("launchctl", "bootstrap", DOMAIN, AGENT)
    else:
        sh("open", APP)


def measure(seconds):
    pid = flick_pid()
    g0, c0, t0 = gpu_times(), cpu_seconds(pid) if pid else 0, time.time()
    device = []
    end = t0 + seconds
    while time.time() < end:
        device.append(device_percent())
        time.sleep(0.5)
    g1, c1, t1 = gpu_times(), cpu_seconds(pid) if pid else 0, time.time()
    span = t1 - t0
    by = {k: (g1.get(k, 0) - g0.get(k, 0)) / 1e9 / span * 100 for k in g1}
    memory = ""
    if pid:
        m = re.search(r"phys_footprint: ([\d.]+ \w+)", sh("footprint", str(pid)))
        memory = m.group(1) if m else ""
    return {"device": sum(device) / max(len(device), 1), "window": by.get("WindowServer", 0.0),
            "flick": by.get("Flick", 0.0), "cpu": (c1 - c0) / span * 100, "memory": memory,
            "top": sorted(by.items(), key=lambda x: -x[1])[:4]}


def run_state(state, seconds, folder):
    if state == "off":
        stop()
        time.sleep(1.5)
        return measure(seconds)
    stop()
    report = os.path.join(folder, "report.txt")
    for f in (report, report + ".ready"):
        if os.path.exists(f):
            os.remove(f)
    held = "none" if state == "idle" else state
    extra = [x for pair in EXTRA_ENV for x in ("--env", pair)]
    subprocess.run(["open", "-n", "--env", f"FLICK_SELFTEST={report}", "--env", f"FLICK_PERFSTATE={held}",
                    "--env", f"FLICK_PERFSECONDS={seconds + 3}", *extra, APP])
    for _ in range(150):
        if os.path.exists(report + ".ready"):
            break
        time.sleep(0.1)
    time.sleep(1.5)
    result = measure(seconds)
    for _ in range(100):
        if os.path.exists(report):
            break
        time.sleep(0.1)
    return result


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--rounds", type=int, default=3)
    parser.add_argument("--seconds", type=int, default=8)
    parser.add_argument("--states", default=",".join(ALL_STATES))
    parser.add_argument("--out")
    parser.add_argument("--env", action="append", default=[], help="extra NAME=value for Flick, to compare variants")
    args = parser.parse_args()
    EXTRA_ENV.extend(args.env)
    states = args.states.split(",")
    results = {s: [] for s in states}
    with tempfile.TemporaryDirectory() as folder:
        try:
            for _ in range(args.rounds):
                for state in states:
                    results[state].append(run_state(state, args.seconds, folder))
        finally:
            restore()

    def mean(rows, key):
        return sum(r[key] for r in rows) / max(len(rows), 1)

    lines = [f"{'state':<13}{'GPU device':>11}{'WindowServer':>14}{'vs off':>9}{'Flick GPU':>11}{'Flick CPU':>11}  memory"]
    off = mean(results["off"], "window") if "off" in results else 0
    for s in states:
        r = results[s]
        lines.append(f"{s:<13}{mean(r, 'device'):>10.1f}%{mean(r, 'window'):>13.1f}%{mean(r, 'window') - off:>+8.1f}%"
                     f"{mean(r, 'flick'):>10.1f}%{mean(r, 'cpu'):>10.1f}%  {r[-1]['memory']}")
    lines.append("")
    lines.append("rounds, WindowServer %: " + "  ".join(f"{s} " + "/".join(f"{x['window']:.0f}" for x in results[s]) for s in states))
    lines.append("busiest in the last sample: " + ", ".join(f"{k} {v:.1f}%" for k, v in results[states[-1]][-1]["top"]))
    text = "\n".join(lines)
    print(text)
    if args.out:
        with open(args.out, "w") as f:
            f.write(text + "\n")


if __name__ == "__main__":
    main()
