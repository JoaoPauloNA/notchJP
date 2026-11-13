#!/usr/bin/env python3
"""Record coarse process CPU/RSS samples; compare only under the same workload."""
import argparse
import json
from pathlib import Path
import statistics
import subprocess
import time

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--pid', type=int, required=True)
parser.add_argument('--samples', type=int, default=12)
parser.add_argument('--interval', type=float, default=5)
parser.add_argument('--conditions', required=True)
parser.add_argument('--output', type=Path, required=True)
args = parser.parse_args()
if args.pid <= 0 or not 2 <= args.samples <= 1000 or not 0.5 <= args.interval <= 60:
    parser.error('Use a positive PID, 2–1000 samples and interval 0.5–60 seconds.')
samples = []
for index in range(args.samples):
    data = subprocess.check_output(['ps', '-p', str(args.pid), '-o', '%cpu=', '-o', 'rss='], text=True).split()
    if len(data) != 2:
        raise SystemExit('Process exited; no complete report written.')
    samples.append({'cpu_percent': float(data[0]), 'rss_mib': int(data[1]) / 1024})
    if index + 1 < args.samples:
        time.sleep(args.interval)
report = {'conditions': args.conditions, 'interval_seconds': args.interval, 'samples': samples,
          'mean_cpu_percent': statistics.mean(x['cpu_percent'] for x in samples),
          'mean_rss_mib': statistics.mean(x['rss_mib'] for x in samples),
          'limitation': 'ps CPU is a coarse estimate, not interval energy usage. Background activity and workload must be controlled.'}
args.output.write_text(json.dumps(report, indent=2) + '\n')
print(json.dumps({key: value for key, value in report.items() if key != 'samples'}))
