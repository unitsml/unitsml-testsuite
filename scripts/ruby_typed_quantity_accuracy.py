"""Check corpora/features/ruby-typed-quantity-accuracy/v1 (F40 additive generation).

Rows come from archive/capture-typed-quantity-accuracy.rb, run unchanged in two
separate processes at plurimath-ruby 0a1df68 with unitsml-ruby de4f5b9. The two
payloads must be byte-equal, every archived file must match its seal, and
vectors.json must re-derive byte-equal from the payload.

  python -I scripts/ruby_typed_quantity_accuracy.py check | build
"""
import hashlib, json, sys
from pathlib import Path
GEN = Path(__file__).resolve().parents[1] / "corpora/features/ruby-typed-quantity-accuracy/v1"
A = GEN / "archive/typed-quantity-accuracy-0a1df68.jsonl"
B = GEN / "archive/typed-quantity-accuracy-0a1df68-rerun.jsonl"
sha = lambda p: hashlib.sha256(p.read_bytes()).hexdigest()
COMPARISON = ("expected: exact equality of the wire-encoded library result (value class and digits, "
              "unit, accuracy symbol); ruby_wire is the verbatim Ruby request response at the producer head")

def vectors():
    cases = []
    for line in A.read_text(encoding="utf-8").splitlines():
        r = json.loads(line)
        cases.append({"id": r["id"], "family": r["family"], "note": r["note"],
                      "input": {"formula": r["formula"], "inputs": r["inputs"]},
                      "request_json": json.dumps(r["request"], ensure_ascii=False, separators=(",", ":")),
                      "expected": r["library"], "ruby_wire": r["ruby_wire"], "comparison": COMPARISON})
    return json.dumps({"schema": "unitsml-testsuite-ruby-typed-quantity-accuracy/1", "count": len(cases),
                       "cases": cases}, ensure_ascii=False, indent=1) + "\n"

def check():
    ix = json.loads((GEN / "index.json").read_text(encoding="utf-8"))
    bad = [p for p, h in ix["archive_seals"].items() if sha(GEN / p) != h]
    data = json.loads((GEN / "vectors.json").read_text(encoding="utf-8"))
    ids = [c["id"] for c in data["cases"]]
    res = {"bad_seals": bad, "runs_byte_equal": A.read_bytes() == B.read_bytes(),
           "vectors_rederived": vectors() == (GEN / "vectors.json").read_text(encoding="utf-8"),
           "vectors_sha": sha(GEN / "vectors.json") == ix["files"]["vectors.json"],
           "ids_match_index": ids == ix["expected_ids"], "ids_unique": len(ids) == len(set(ids))}
    print(json.dumps(res)); return 0 if not bad and all(v for k, v in res.items() if k != "bad_seals") else 1

def build():
    (GEN / "vectors.json").write_text(vectors(), encoding="utf-8"); return 0

if __name__ == "__main__":
    sys.exit({"check": check, "build": build}[sys.argv[1]]())
