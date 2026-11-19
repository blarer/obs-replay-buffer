"""Verify every planned move by eyeballing contact sheets.

Confidence alone proved insufficient: spot checks found errors at 67-79%, all
caused by clips whose true subject has no class (desktop, Dead Space). This
renders a sheet per planned move so each one can be confirmed before any file
is touched.
"""
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
import sort_clips as sc
from contact_sheet import sheet

OUT = Path(__file__).with_name("_verify_all")


def main() -> int:
    ref = sc.build_reference()
    OUT.mkdir(exist_ok=True)
    rows = []
    for p in sc.suspect_files():
        label, conf, votes = sc.classify(p, ref)
        rows.append((p, label, conf))

    rows.sort(key=lambda r: r[2])   # least confident first
    for i, (p, label, conf) in enumerate(rows):
        name = f"{i:02d}_conf{int(conf*100):03d}_{p.parent.name}__{label}__{p.stem[:22]}.jpg"
        sheet(p, OUT / name)

    print(f"\n{len(rows)} sheets in {OUT}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
