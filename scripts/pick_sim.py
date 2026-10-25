import json, sys, re
data = json.load(sys.stdin)["devices"]
cands = []
for runtime, devs in data.items():
    m = re.search(r"iOS-(\d+)-(\d+)", runtime)
    if not m:
        continue
    ver = (int(m.group(1)), int(m.group(2)))
    for d in devs:
        n = d["name"]
        if "iPad" not in n:
            continue
        score = 3 if "iPad Pro 11" in n and "M4" in n else 2 if "iPad Pro 11" in n else 1
        cands.append((ver, score, d["udid"]))
if not cands:
    sys.exit("no iPad simulator")
cands.sort()
print(cands[-1][2])
