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
echo '== Import closure and metaprogramming audit =='
python3 - <<'PY'
from pathlib import Path
from collections import Counter
import json,re
root=Path('project/lean/src')
assert (root/'Main.lean').is_file(), 'Expected original lean/src/Main.lean missing'
files=list(root.rglob('*.lean'))
modules={'.'.join(p.relative_to(root).with_suffix('').parts):p for p in files}
edges={}
meta=Counter()
meta_examples=[]
needle=re.compile(r'\b(addDecl|addAndCompile|modifyEnv|setEnv|allowUnsafeReducibility|run_cmd|run_tac)\b')
for module,path in modules.items():
    imports=[]
    with path.open(encoding='utf-8',errors='replace') as fd:
        for line_no,line in enumerate(fd,1):
            line=line.strip()
            if line.startswith('import '):
                imports += line[7:].split()
            for match in needle.finditer(line):
                meta[match.group()] += 1
                if len(meta_examples)<30:
                    meta_examples.append(f'{path}:{line_no}:{line[:140]}')
    edges[module]=[x for x in imports if x in modules]
seen=set()
pending=['Main']
while pending:
    node=pending.pop()
    if node in seen:
        continue
    seen.add(node)
    pending.extend(edges.get(node,()))
not_reached=sorted(modules.keys()-seen)
report={
    'module_count':len(modules),
    'internal_import_edges':sum(map(len,edges.values())),
    'reachable_from_Main':len(seen),
    'unreachable_modules_count':len(not_reached),
    'unreachable_modules_sample':not_reached[:20],
    'metaprogramming_token_counts':dict(meta),
    'metaprogramming_examples':meta_examples,
    'main_direct_internal_imports':edges.get('Main',[])
}
Path('rh-import-graph.json').write_text(json.dumps(report,indent=2))
print(json.dumps(report,indent=2)[:10000])
if not_reached:
    print('WARNING: lexical import parser leaves modules unreachable; this is not a Lean kernel verdict.')
else:
    print('PASS: all original Lean files are in the lexical import closure of Main.')
print('NOTICE: graph and metaprogramming inspection do NOT validate theorem correctness.')
PY

echo '== Audit graph cycles and dangerous declarations =='
python3 - <<'PY'
from pathlib import Path
from collections import Counter
import re,json
root=Path('project/lean/src')
modules={'.'.join(p.relative_to(root).with_suffix('').parts):p for p in root.rglob('*.lean')}
imports={}
danger=Counter()
samples={}
patterns={
 'sorryAx':re.compile(r'\bsorryAx\b'),
 'Lean.ofReduceBool':re.compile(r'\b(?:Lean\.)?ofReduceBool\b'),
 'trustCompiler':re.compile(r'\btrustCompiler\b'),
 'debug.skipKernelTC':re.compile(r'\bdebug\.skipKernelTC\b'),
 'setEnv':re.compile(r'\bsetEnv\b'),
 'addDecl':re.compile(r'\baddDecl\b'),
 'run_cmd':re.compile(r'\brun_cmd\b'),
 'declare_syntax_cat':re.compile(r'\bdeclare_syntax_cat\b'),
 'macro_rules':re.compile(r'\bmacro_rules\b'),
 'axiom_command':re.compile(r'^\s*axiom\b'),
 'constant_command':re.compile(r'^\s*constant\b'),
 'theorem_False':re.compile(r'\btheorem\s+\S+\s*:\s*False\b')
}
for name,path in modules.items():
    xs=[]
    with path.open(encoding='utf-8',errors='replace') as fh:
        for line_num,line in enumerate(fh,1):
            if line.startswith('import '):
                xs.extend([v for v in line[7:].split() if v in modules])
            for label,pat in patterns.items():
                if pat.search(line):
                    danger[label]+=1
                    samples.setdefault(label,[])
                    if len(samples[label])<8:
                        samples[label].append(f'{path.relative_to(root)}:{line_num}:{line.strip()[:130]}')
    imports[name]=xs
# Three-color DFS, iterative to avoid Python recursion limit.
colors={}
cycles=[]
for node in modules:
    if colors.get(node): continue
    colors[node]=1
    stack=[(node,iter(imports[node]))]
    while stack:
        n,it=stack[-1]
        try: child=next(it)
        except StopIteration:
            colors[n]=2
            stack.pop()
            continue
        state=colors.get(child,0)
        if state==0:
            colors[child]=1
            stack.append((child,iter(imports[child])))
        elif state==1 and len(cycles)<10:
            cycles.append((n,child))
result={'modules':len(modules),'cycles':cycles,'dangerous_or_meta_pattern_counts':dict(danger),'examples':samples}
print(json.dumps(result,indent=2)[:12000])
assert not cycles,'Internal import graph contains cycles'
for key in ('sorryAx','Lean.ofReduceBool','trustCompiler','debug.skipKernelTC','axiom_command','constant_command','theorem_False'):
    assert danger[key]==0,f'Potentially dangerous syntax: {key} = {danger[key]}'
print('PASS: no internal import cycles and no listed dangerous declarations found by lexical search.')
print('NOTICE: syntax matching is not a Lean parser, and neither this nor any earlier scan constitutes a kernel proof.')
PY
