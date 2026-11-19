#!/usr/bin/env python3
"""Prove every corpus validator is live: on a clean export of HEAD each one
must pass, and after one byte is appended to a file it seals it must fail.
A validator that passes a tampered corpus would let a silent edit through.

Usage: python scripts/ci_tamper_selftest.py
"""
import io
import os
import subprocess
import sys
import tarfile
import tempfile

# (command relative to the export root, file the command seals)
CHECKS = [
    (["scripts/check_feature_corpus.py", "."], "corpora/features/unitsml-quantities.json"),
    (["scripts/host_evaluator_vectors.py", "check"], "corpora/features/host-evaluator/v1/vectors.json"),
    (["scripts/evaluator_reference_vectors.py", "check"], "corpora/features/evaluator-reference/v1/vectors.json"),
    (["scripts/ruby_feature_additions.py", "check"], "corpora/features/ruby-feature-additions/v1/vectors.json"),
    (["scripts/ruby_unitsml_features.py", "check"], "corpora/features/ruby-unitsml-features/v1/vectors.json"),
    (["scripts/ruby_typed_quantity_accuracy.py", "check"], "corpora/features/ruby-typed-quantity-accuracy/v1/vectors.json"),
    (["scripts/unitsdb_schema_roundtrip.py", "check"], "corpora/features/unitsdb-schema-roundtrip/v1/vectors.json"),
    (["scripts/ruby_explicit_kind_power.py", "check"], "corpora/features/ruby-explicit-kind-power/v1/vectors.json"),
]


def export(dest):
    archive = subprocess.run(["git", "archive", "--format=tar", "HEAD"], check=True, capture_output=True).stdout
    with tarfile.open(fileobj=io.BytesIO(archive)) as tar:
        if hasattr(tarfile, "data_filter"):
            tar.extractall(dest, filter="data")
        else:
            tar.extractall(dest)


def run(root, command):
    return subprocess.run([sys.executable, "-I", *command], cwd=root, capture_output=True, text=True).returncode


def main():
    failures = []
    for command, sealed in CHECKS:
        with tempfile.TemporaryDirectory() as clean, tempfile.TemporaryDirectory() as tampered:
            export(clean)
            export(tampered)
            with open(os.path.join(tampered, sealed), "ab") as fh:
                fh.write(b"\n")
            ok_clean = run(clean, command) == 0
            caught = run(tampered, command) != 0
            print({"check": " ".join(command), "clean_passes": ok_clean, "tamper_caught": caught})
            if not (ok_clean and caught):
                failures.append(command[0])
    if failures:
        print("validators not proven live:", failures)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
