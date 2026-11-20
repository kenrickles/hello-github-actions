#!/usr/bin/env bash
set -euo pipefail
echo '== Runner resources =='
nproc
free -h
df -h .
echo '== Download original 14-part archive =='
mkdir -p archive project
for i in $(seq 1 14); do
  printf -v part '%02d' "$i"
  curl --fail --location --silent --show-error --retry 3 --max-time 300 \
    "https://alpo.ge/lean.tar.gz.part$part" -o "archive/part$part"
  printf 'Downloaded part%s: %s bytes\n' "$part" "$(stat -c %s "archive/part$part")"
done
cat archive/part* > lean.tar.gz
echo '9631b4f020199e580ba86178cb56c6e9b09f690c2369a80dc4334aa93f49c7fc  lean.tar.gz' | sha256sum --check
stat -c 'Joined archive size: %s bytes' lean.tar.gz
echo '== Extract and independently scan the original archive =='
tar --extract --gzip --file lean.tar.gz --directory project --no-same-owner --no-same-permissions
python3 - <<'PY'
from pathlib import Path
import json,re
files = sorted(Path('project').rglob('*.lean'))
forbidden = ('axiom','sorry','admit','native_decide','unsafe','opaque','extern','implemented_by','skipKernelTC')
p = re.compile(r'\b(?:'+'|'.join(map(re.escape,forbidden))+r')\b')
counts={name:0 for name in forbidden}
findings=[]
total_bytes=0
for f in files:
    total_bytes += f.stat().st_size
    with f.open(encoding='utf-8', errors='replace') as stream:
        for num,line in enumerate(stream,1):
            for m in p.finditer(line):
                key=m.group()
                counts[key]+=1
                if len(findings)<30:
                    findings.append(f'{f}:{num}: {line.strip()[:160]}')
main=[f for f in files if f.name=='Main.lean']
main_snippets={}
for f in main:
    body=f.read_text(errors='replace')
    if all(x in body for x in ('riemannHypothesis','LFunction_eq_zero_re')):
        main_snippets[str(f)]=[line.strip() for line in body.splitlines() if line.lstrip().startswith('theorem ')]
report={
    'lean_file_count':len(files),
    'lean_source_bytes':total_bytes,
    'forbidden_token_counts':counts,
    'first_matches':findings,
    'main_theorems':main_snippets,
    'archive_sha256':'9631b4f020199e580ba86178cb56c6e9b09f690c2369a80dc4334aa93f49c7fc'
}
Path('rh-audit-report.json').write_text(json.dumps(report,indent=2))
print(json.dumps(report,indent=2)[:12000])
assert len(files)==175187, f'Unexpected source file count: {len(files)}'
assert all(v==0 for v in counts.values()), f'Suspicious tokens found: {counts}'
assert main_snippets, 'Could not locate expected Main.lean theorem declarations'
print('PASS: archive SHA, file count, literal token scan, and Main.lean declarations checked.')
print('NOTICE: this does NOT compile or kernel-check the RH proof.')
PY