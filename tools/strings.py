#!/usr/bin/env python3
"""Baut Resources/Localizable.xcstrings aus den beim Build extrahierten Schlüsseln (*.stringsdata)
und den englischen Übersetzungen in tools/en.json. Deutsch ist Ausgangssprache (Schlüssel = deutscher Text).
  python3 tools/strings.py           → schreibt den Katalog, listet fehlende Übersetzungen
  python3 tools/strings.py --missing → nur fehlende als JSON-Gerüst ausgeben"""
import json, glob, os, sys, re
root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
keys = {}
derived = os.environ.get("HOMEFIND_DERIVED", os.path.expanduser("~/Library/Caches/homefind-build"))
for f in glob.glob(os.path.join(derived, "Build/Intermediates.noindex/HomeFind.build/*/HomeFind.build/Objects-normal/*/*.stringsdata")):
    d = json.load(open(f))
    for e in d.get("tables", {}).get("Localizable", []):
        keys[e["key"]] = True
en_path = os.path.join(root, "tools/en.json")
en = json.load(open(en_path)) if os.path.exists(en_path) else {}
# Zeichenketten ohne Buchstaben (z. B. "·", "%@") brauchen keine Übersetzung
def needs(k): return re.search(r"[A-Za-zÄÖÜäöüß]", re.sub(r"%(\d\$)?(lld|ld|d|@|f|\.\df)", "", k)) is not None
missing = sorted(k for k in keys if needs(k) and k not in en)
if "--missing" in sys.argv:
    print(json.dumps({k: "" for k in missing}, ensure_ascii=False, indent=1)); sys.exit(0)
def positional(s):
    # mehrere Platzhalter → nummerieren (%1$@ …), wie Xcode es im Katalog erwartet
    specs = re.findall(r"%(?:\d\$)?(?:lld|ld|d|@|f|\.\df)", s)
    if len(specs) < 2 or re.search(r"%\d\$", s): return s
    i = 0
    def rep(m):
        nonlocal i; i += 1
        return "%" + str(i) + "$" + m.group(1)
    return re.sub(r"%(lld|ld|d|@|f|\.\df)", rep, s)
strings = {}
for k in sorted(keys):
    entry = {}
    if k in en and en[k]:
        entry = {"localizations": {"en": {"stringUnit": {"state": "translated", "value": positional(en[k])}}}}
        if positional(k) != k:
            entry["localizations"]["de"] = {"stringUnit": {"state": "translated", "value": positional(k)}}
    strings[k] = entry
cat = {"sourceLanguage": "de", "strings": strings, "version": "1.0"}
json.dump(cat, open(os.path.join(root, "Resources/Localizable.xcstrings"), "w"), ensure_ascii=False, indent=2, sort_keys=True)
print(f"{len(keys)} Schlüssel, {len(missing)} ohne Übersetzung")
for k in missing: print("  fehlt:", k)
