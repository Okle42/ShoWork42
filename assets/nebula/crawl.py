# 把 esm.sh 上固定版本的 ES 模組（含相依）全抓下來，打成一個 classic script：window.__NEB = {mods:{路徑:原始碼}, entries:{...}}
import re, json, sys, urllib.request
BASE = 'https://esm.sh'
ENTRIES = {
  'THREE': '/three@0.180.0?target=es2022',
  'FG': '/3d-force-graph@1.80.1?deps=three@0.180.0&target=es2022',
  'Bloom': '/three@0.180.0/examples/jsm/postprocessing/UnrealBloomPass.js?target=es2022',
  'Output': '/three@0.180.0/examples/jsm/postprocessing/OutputPass.js?target=es2022',
}
SPEC = re.compile(r'''((?:\bfrom|\bimport)\s*\(?\s*)(["'])((?:/|\./|\.\./)[^"']+)\2''')
import posixpath
def absol(base, spec):
    if spec.startswith('/'): return spec
    d = posixpath.dirname(base.split('?')[0])
    return posixpath.normpath(posixpath.join(d, spec))
mods = {}
def get(path):
    if path in mods: return
    with urllib.request.urlopen(BASE + path, timeout=30) as r:
        src = r.read().decode('utf-8')
    deps = []
    def fix(m):
        a = absol(path, m.group(3)); deps.append(a)
        return m.group(1) + m.group(2) + a + m.group(2)
    src = SPEC.sub(fix, src)          # 相對路徑一律改成絕對路徑（頁面那邊只認 / 開頭）
    mods[path] = src
    for d in deps: get(d)
for p in ENTRIES.values(): get(p)
out = 'window.__NEB=' + json.dumps({'mods': mods, 'entries': ENTRIES}, ensure_ascii=False) + ';'
open(sys.argv[1], 'w').write(out)
print(len(mods), 'modules', len(out) // 1024, 'KB')
for k in sorted(mods): print(' ', k, len(mods[k]))
