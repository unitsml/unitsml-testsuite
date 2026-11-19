"""Check corpora/features/ruby-explicit-kind-power/v1 (F40 additive generation).

Rows come from archive/capture-power-kind.rb, run unchanged twice per UnitsDB
profile (unitsdb gem 2.2.15 data; UnitsDB #143 merge b0b4315) at unitsml-ruby
2ec9583. Each profile's two payloads must be byte-equal, every archived file
must match its seal, and vectors.json must re-derive byte-equal from the
first payload of each profile.

  python -I scripts/ruby_explicit_kind_power.py check | build
"""
import hashlib, json, sys
from pathlib import Path
GEN = Path(__file__).resolve().parents[1] / "corpora/features/ruby-explicit-kind-power/v1"
PROFILES = ["unitsdb-2.2.15", "unitsdb-143-b0b4315"]
run = lambda p, n: GEN / f"archive/power-kind-{p}-run{n}.jsonl"
sha = lambda p: hashlib.sha256(p.read_bytes()).hexdigest()
STATUS = "current_api_behaviour"
COMPARISON = ("expected: exact equality per profile of outcome, error_class and message, or of the returned "
              "quantity (value class and text, unit, dimension_id, scale, kind, primary_kind)")

def rows(p):
    return [json.loads(l) for l in run(p, 1).read_text(encoding="utf-8").splitlines()]

def vectors():
    snapshots, cases, order = {}, {}, []
    for p in PROFILES:
        for r in rows(p):
            if r["family"] == "snapshot":
                snapshots[p] = {k: v for k, v in r.items() if k not in ("id", "profile", "family")}
                continue
            if r["id"] not in cases:
                order.append(r["id"])
                cases[r["id"]] = {"id": r["id"], "family": r["family"], "item": r["item"], "call": r["call"],
                                  "status": STATUS, "expected": {}}
            cases[r["id"]]["expected"][p] = {k: v for k, v in r.items()
                                             if k in ("outcome", "error_class", "message", "result")}
    out = []
    for i in order:
        c = cases[i]
        c["profiles_agree"] = len({json.dumps(v, sort_keys=True) for v in c["expected"].values()}) == 1
        c["comparison"] = COMPARISON
        out.append(c)
    return json.dumps({"schema": "unitsml-testsuite-ruby-explicit-kind-power/1", "status": STATUS,
                       "count": len(out), "profiles": PROFILES, "snapshots": snapshots, "cases": out},
                      ensure_ascii=False, indent=1) + "\n"

def check():
    ix = json.loads((GEN / "index.json").read_text(encoding="utf-8"))
    bad = [p for p, h in ix["archive_seals"].items() if sha(GEN / p) != h]
    data = json.loads((GEN / "vectors.json").read_text(encoding="utf-8"))
    ids = [c["id"] for c in data["cases"]]
    res = {"bad_seals": bad,
           "runs_byte_equal": all(run(p, 1).read_bytes() == run(p, 2).read_bytes() for p in PROFILES),
           "snapshots_in_use": all(data["snapshots"][p]["snapshot_in_use"] for p in PROFILES),
           "every_case_both_profiles": all(sorted(c["expected"]) == sorted(PROFILES) for c in data["cases"]),
           "vectors_rederived": vectors() == (GEN / "vectors.json").read_text(encoding="utf-8"),
           "vectors_sha": sha(GEN / "vectors.json") == ix["files"]["vectors.json"],
           "ids_match_index": ids == ix["expected_ids"], "ids_unique": len(ids) == len(set(ids))}
    print(json.dumps(res)); return 0 if not bad and all(v for k, v in res.items() if k != "bad_seals") else 1

def build():
    (GEN / "vectors.json").write_text(vectors(), encoding="utf-8"); return 0

if __name__ == "__main__":
    sys.exit({"check": check, "build": build}[sys.argv[1]]())
