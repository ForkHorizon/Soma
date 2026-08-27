import json, os

gt = os.path.expanduser("~/Library/Application Support/Soma/GroundTruth")

settled = set()
for line in open(f"{gt}/gold.jsonl"):
    try:
        settled.add(json.loads(line)["file"])
    except Exception:
        pass

choices = {}
for line in open(f"{gt}/review_progress.jsonl"):
    try:
        r = json.loads(line)
    except Exception:
        continue
    choices.setdefault(r["file"], {})[r["operation"]] = r["signature"]

review = []
for line in open(f"{gt}/verdicts.jsonl"):
    try:
        v = json.loads(line)
    except Exception:
        continue
    if v.get("status") == "review":
        review.append(v)

no_multi = []        # not settled, zero multi-alt operations (auto-assemblable)
interrupted = []     # not settled, multi-alt ops all decided, gold write missing
active = 0
for v in review:
    f = v["file"]
    if f in settled:
        continue
    ops = v.get("review_operations") or []
    multi = [o for o in ops if len(o.get("alternatives", [])) > 1]
    done = choices.get(f, {})
    remaining = [o for o in multi if done.get(o["id"]) != o["signature"]]
    if not multi:
        no_multi.append(f)
    elif not remaining:
        interrupted.append(f)
    else:
        active += 1

print("non-settled review files:", active + len(no_multi) + len(interrupted))
print("active (questions remain):", active)
print("zero human questions (auto-assemblable):", len(no_multi), no_multi[:5])
print("fully decided, gold write missing:", len(interrupted), interrupted[:5])
