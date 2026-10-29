#!/usr/bin/env python3
"""For every no_build_system result, fetch the repo tree and say what is actually there."""
import json,sys,re,subprocess,collections
rows=[]
for f in sys.argv[1:]: rows+=json.load(open(f))
BUILD=re.compile(r'(^|/)(CMakeLists\.txt|Makefile|GNUmakefile|meson\.build|Cargo\.toml|go\.mod|package\.json|pyproject\.toml|setup\.py|build\.gradle(\.kts)?|.*\.sln|.*\.vcxproj|.*\.xcodeproj|SConstruct|premake5\.lua|build\.zig|.*\.pro|configure\.ac|build\.sh|build\.bat|build\.ps1)$')
out=[]
for r in [x for x in rows if x['result']=='no_build_system']:
    m=re.match(r'https://github.com/([^/]+)/([^/]+)',r['repo'])
    if not m: out.append({**r,'tree':'non-github'}); continue
    p=subprocess.run(['gh','api',f'repos/{m.group(1)}/{m.group(2)}/git/trees/HEAD?recursive=1','-q','[.tree[].path]|join("\n")'],capture_output=True,text=True)
    paths=[x for x in p.stdout.split('\n') if x]
    hits=[x for x in paths if BUILD.search(x)]
    top=collections.Counter((x.split('/')[0] if '/' in x else x) for x in paths)
    exts=collections.Counter(x.rsplit('.',1)[-1].lower() for x in paths if '.' in x.split('/')[-1])
    if not paths: kind='empty_or_unreadable'
    elif any(re.search(r'(^|/)(CMakeLists\.txt|Makefile|GNUmakefile|meson\.build|Cargo\.toml|go\.mod|build\.gradle)',h) for h in hits): kind='build_files_in_subdir'
    elif any(re.search(r'\.(sln|vcxproj)$',h) for h in hits): kind='windows_project_in_subdir'
    elif any(re.search(r'(^|/)(build\.(sh|bat|ps1)|premake5\.lua|SConstruct|build\.zig|configure\.ac|.*\.pro)$',h) for h in hits): kind='custom_build_script'
    elif any(re.search(r'(^|/)package\.json$',h) for h in hits) or exts.get('html',0)+exts.get('js',0)>5: kind='web_or_node_without_build'
    elif exts.get('py',0)>3 and sum(exts.get(e,0) for e in ['c','cpp','cc','rs','h'])<3: kind='python_scripts'
    elif sum(exts.get(e,0) for e in ['c','cpp','cc','rs','h','hpp','asm','s'])>5: kind='sources_no_build_files'
    elif exts.get('md',0)>=max(1,len(paths)//2) or len(paths)<=5: kind='docs_or_notes_only'
    else: kind='other'
    out.append({'id':r['id'],'repo':r['repo'],'outcome_reported':r['outcome_reported'],'kind':kind,'n_paths':len(paths),'build_hits':hits[:6],'top_exts':exts.most_common(5)})
json.dump(out,open('results/tree-check.json','w'),indent=1)
print(collections.Counter(o['kind'] for o in out))
print("Works only:",collections.Counter(o['kind'] for o in out if o['outcome_reported']=='Works'))
