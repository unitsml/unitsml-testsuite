"""Check corpora/features/unitsdb-schema-roundtrip/v1 (F40 additive generation).

Rows come from archive/capture-unitsdb-roundtrip.rb, run unchanged in four
separate processes: two profiles (the unitsdb 2.2.15 gem's bundled data and
UnitsDB b0b4315) times two runs. Each profile's two payloads must be
byte-equal, every archived file must match its seal, vectors.json must
re-derive byte-equal from the payloads, the ids must match the frozen id
digest, and the per-row outcomes must agree with the index.

  python -I scripts/unitsdb_schema_roundtrip.py check | build
"""
import hashlib, json, sys
from collections import Counter
from pathlib import Path
GEN = Path(__file__).resolve().parents[1] / "corpora/features/unitsdb-schema-roundtrip/v1"
PROFILES = {"unitsdb-gem-2.2.15": "gem-2.2.15", "unitsdb-b0b4315": "b0b4315"}
sha = lambda p: hashlib.sha256(p.read_bytes()).hexdigest()
COMPARISON = ("expected_outcome is the Ruby producer's verdict for this check: canon "
              "be_yaml_equivalent_to (the unitsdb-ruby spec contract) AND class-exact structural "
              "equality AND no output-only schema errors; row is the full producer record")


def payload(profile, rerun=False):
    return GEN / "archive" / ("unitsdb-roundtrip-%s%s.jsonl" % (PROFILES[profile], "-rerun" if rerun else ""))


def rows(profile):
    return [json.loads(l) for l in payload(profile).read_text(encoding="utf-8").splitlines()]


def vectors():
    cases = []
    for profile in PROFILES:
        for r in rows(profile):
            cases.append({"id": r["id"], "kind": r["kind"], "profile": profile,
                          "expected_outcome": r.get("outcome"), "row": r, "comparison": COMPARISON})
    return json.dumps({"schema": "unitsml-testsuite-unitsdb-schema-roundtrip/1", "count": len(cases),
                       "cases": cases}, ensure_ascii=False, indent=1) + "\n"


def check():
    ix = json.loads((GEN / "index.json").read_text(encoding="utf-8"))
    bad = [p for p, h in ix["archive_seals"].items() if sha(GEN / p) != h]
    data = json.loads((GEN / "vectors.json").read_text(encoding="utf-8"))
    ids = [c["id"] for c in data["cases"]]
    res = {"bad_seals": bad,
           "runs_byte_equal": all(payload(p).read_bytes() == payload(p, True).read_bytes() for p in PROFILES),
           "vectors_rederived": vectors() == (GEN / "vectors.json").read_text(encoding="utf-8"),
           "vectors_sha": sha(GEN / "vectors.json") == ix["files"]["vectors.json"],
           "ids_digest": hashlib.sha256("\n".join(ids).encode()).hexdigest() == ix["expected_ids_sha256"],
           "ids_count": len(ids) == ix["counts"]["total_rows"], "ids_unique": len(ids) == len(set(ids))}
    # outcomes and counts per profile agree with the index
    agree = True
    for profile in PROFILES:
        rs = rows(profile)
        want = ix["profiles"][profile]
        meta = rs[0]
        agree &= meta["kind"] == "meta" and meta["data_files"] == want["data_files_sha256"]
        recs = [r for r in rs if r["kind"] == "record"]
        per = Counter(r["collection"] for r in recs)
        agree &= dict(per) == want["records_per_collection"]
        for r in rs:
            if r["kind"] == "collection":
                agree &= r["record_count"] == per[r["collection"]] == r["records"]["total"]
        outcomes = Counter(r.get("outcome") for r in rs if r["kind"] != "meta")
        agree &= dict(outcomes) == want["outcomes"]
        agree &= sorted(r["id"] for r in rs if r.get("outcome") == "fail") == want["failing_ids"]
        # a passing database/collection row must have identical canonical JSON before and after
        for r in rs:
            if r["kind"] in ("database", "collection") and r.get("outcome") == "pass":
                agree &= r["canonical_json_sha256"]["input"] == r["canonical_json_sha256"]["output"]
    res["outcomes_match_index"] = bool(agree)
    print(json.dumps(res))
    return 0 if not bad and all(v for k, v in res.items() if k != "bad_seals") else 1


def build():
    (GEN / "vectors.json").write_text(vectors(), encoding="utf-8")
    return 0


if __name__ == "__main__":
    sys.exit({"check": check, "build": build}[sys.argv[1]]())
