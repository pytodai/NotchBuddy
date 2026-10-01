#!/usr/bin/env python3
"""Summary of one benchmark run in perf.log (see scripts/perf-bench.sh).

    scripts/perf-summary.py <perf.log> [tag]   # tag: the run's "begin" marker text; default: the last run

Columns:
  main     main-thread display ticks: the frame rate of main-thread-driven (SwiftUI) motion
  comp     frames the window server displayed (an in-panel Metal probe redrawn every vsync from its own thread)
  srv      frames the window server skipped although the probe had drawn one (the compositor's own drops)
  probe    the probe thread's worst gap (a comp gap it explains is CPU starvation of the probe, not a dropped frame)
  work     per-frame island work on the main thread during the transition (0-1: motion independent of the main
           thread; the single commit counts 1)
"""
import re, sys

log = sys.argv[1]
lines = open(log).read().splitlines()
if len(sys.argv) > 2:
    tag = sys.argv[2]
else:
    tag = [l for l in lines if l.startswith("# begin ")][-1][len("# begin "):].rsplit(" load ", 1)[0]
start = max(i for i, l in enumerate(lines) if l.startswith("# begin " + tag))
pattern = re.compile(
    r"~?(?P<name>\S+)\s+main\[frames (?P<mf>\d+) fps (?P<mfps>[\d.]+) worst (?P<mworst>[\d.]+)ms dropped (?P<mdrop>\d+)\] "
    r"comp\[frames (?P<cf>\d+) fps (?P<cfps>[\d.]+) worst (?P<cworst>[\d.]+)ms dropped (?P<cdrop>\d+) lost (?P<lost>\d+)\] "
    r"probe\[worst (?P<pworst>[\d.]+)ms server-drops (?P<srv>\d+)\] "
    r"latency (?P<lat>-?[\d.]+)ms stall (?P<stall>[\d.]+)ms work (?P<work>\d+) refresh (?P<refresh>[\d.]+)ms load (?P<load>[\d.]+)")
rows = {}
for l in lines[start + 1:]:
    if l.startswith("# end " + tag):
        break
    m = pattern.match(l)
    # "~": cut short by the next transition (a hover-in that turned into an opening): not a whole measurement.
    if m and not l.startswith("~"):
        rows.setdefault(m.group("name"), []).append({k: float(v) for k, v in m.groupdict().items() if k != "name"})

def p90(v):
    v = sorted(v)
    return v[int(0.9 * (len(v) - 1))]

print(tag)
print(f"{'transition':<12}{'n':>3} | {'main fps':>8} {'worst':>8} {'p90':>8} | {'comp fps':>8} {'worst':>8} {'p90':>8} "
      f"{'srv/tr':>6} {'probe':>7} | {'latency':>7} {'stall':>7} {'work':>5} {'load':>5}")
order = ["hover-in", "hover-out", "open", "close", "tab", "flash", "flash-out", "card", "cardAdvance", "card-out"]
for name in sorted(rows, key=lambda n: order.index(n) if n in order else 99):
    r = rows[name]
    n = len(r)
    avg = lambda k: sum(x[k] for x in r) / n
    lat = [x["lat"] for x in r if x["lat"] >= 0]
    print(f"{name:<12}{n:>3} | {avg('mfps'):>8.1f} {max(x['mworst'] for x in r):>6.1f}ms {p90([x['mworst'] for x in r]):>6.1f}ms | "
          f"{avg('cfps'):>8.1f} {max(x['cworst'] for x in r):>6.1f}ms {p90([x['cworst'] for x in r]):>6.1f}ms "
          f"{avg('srv'):>6.2f} {max(x['pworst'] for x in r):>5.0f}ms | "
          f"{(sum(lat) / len(lat) if lat else -1):>5.0f}ms {max(x['stall'] for x in r):>5.0f}ms {avg('work'):>5.0f} {avg('load'):>5.1f}")
