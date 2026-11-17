#!/usr/bin/env python3
"""summarize.py results/<file>.txt: print the README results table (failed/total runs)."""
import re, sys

rows, order = {}, []
for line in open(sys.argv[1]):
    m = (re.match(r'(repro|stress|test_package) (\S+) (arm64|x86_64): (\d+)/(\d+) failed', line)
         or re.match(r'(noshm) (\S+) (arm64|x86_64): rc=(\d+)', line))
    if not m:
        continue
    test, name, arch = m[1], m[2], m[3]
    if test == 'test_package' and name.endswith('-debug'):
        test, name = 'debug', name[:-len('-debug')]
    if test == 'noshm':
        rc = int(m[4]); val = 'ok' if rc == 0 else ('**abort**' if rc == 134 else f'**rc={rc}**')
    else:
        f, t = int(m[4]), int(m[5]); val = f'**{f}/{t}**' if f else f'{f}/{t}'
    if name not in rows:
        rows[name] = {}; order.append(name)
    rows[name][(test, arch)] = val

cols = [('repro', 'bug 1: repro'), ('stress', 'bug 1: stress'), ('debug', 'bug 2: test_package, Debug libomp'),
        ('noshm', 'bug 3: test_package in noshm.sb'), ('test_package', 'test_package, Release')]
archs = ['arm64', 'x86_64']
print('| libomp | ' + ' | '.join(f'{h} {a}' for _, h in cols for a in archs) + ' |')
print('|---' * (1 + len(cols) * len(archs)) + '|')
for n in order:
    label = n.replace('-parent', '^ (parent)')
    print(f'| {label} | ' + ' | '.join(rows[n].get((c, a), '') for c, _ in cols for a in archs) + ' |')
