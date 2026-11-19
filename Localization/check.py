#!/usr/bin/env python3
"""Validate shipped strings, printf arguments, Info.plist descriptions and optional Xcode extraction."""
import argparse
from collections import Counter
import json
from pathlib import Path
import plistlib
import re
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
RESOURCES = ROOT / "Resources"
LANGUAGE_SOURCE = (ROOT / "Security/WalletLanguage.swift").read_text()
LANGUAGES = set(re.findall(r'"([a-z]{2}(?:-Ha(?:ns|nt))?)"',
                    LANGUAGE_SOURCE.split("static let supported =", 1)[1].split("]", 1)[0])) - {"en"}
FORMAT = re.compile(r"%(?:(\d+)\$)?(lld|llu|ld|lu|d|u|@|%)")
# Cognates, international terms and accepted loanwords that naturally match English.
SHARED_TERMS = {"24h", "Max", "Address", "App PIN", "Block", "Confirmations", "Contacts", "Date", "Direction",
                "Free", "Label", "Mainnet", "Name", "Normal", "OK", "Offline", "Pause", "Personal",
                "Phrase", "Privacy", "Privacy Pulse", "Project", "Status", "Testnet", "Tor", "Total", "Transaction",
                "Unlock", "Wallet", "Wallets", "/ 100", "Exodus / Cake BIP39", "PIN", "Monero", "XMR"}

def placeholders(value):
    items = []
    for explicit, kind in FORMAT.findall(value):
        if kind == "%": continue
        items.append((int(explicit) if explicit else len(items) + 1, kind))
    return Counter(items)

def load_catalog(name):
    return json.loads((RESOURCES / name).read_text())["strings"]

def validate(catalog, label, info=None):
    for key, entry in catalog.items():
        if entry.get("shouldTranslate") is False:
            continue
        locales = entry["localizations"]
        expected = LANGUAGES | ({"en"} if info else set())
        assert set(locales) == expected, (label, key, expected ^ set(locales))
        source = info[key] if info else key
        for locale, value in locales.items():
            unit = value["stringUnit"]
            target = unit["value"]
            assert target.strip() and unit["state"] in {"translated", "needs_review"}, (label, locale, key)
            assert not re.search(r"ZXQ[A-Z]QXZ|ARG\d+END|\{\{.+?\}\}", target), (label, locale, key)
            assert placeholders(source) == placeholders(target), (label, locale, key, target)
            if placeholders(source):
                assert "%" not in FORMAT.sub("", target), ("Unexpected format directive", label, locale, key, target)
            for token in ("DELETE", "m/44′/128′/0′/0/0"):
                if token in source: assert token in target, ("Changed literal input", label, locale, key)
            if locale != "en" and source.casefold() == target.casefold():
                assert source in SHARED_TERMS, ("Unreviewed identical source and target", locale, source)
            if info and locale == "en":
                assert source == target, ("Stale Info.plist description", key)

def validate_compilation(local, info):
    with tempfile.TemporaryDirectory() as tmp:
        for name in ("Localizable", "InfoPlist"):
            subprocess.run(["xcrun", "xcstringstool", "compile", str(RESOURCES / (name + ".xcstrings")),
                            "--output-directory", tmp], check=True)
        for locale in sorted(LANGUAGES | {"en"}):
            for table, source in (("Localizable", local), ("InfoPlist", info)):
                file = Path(tmp) / (locale + ".lproj") / (table + ".strings")
                compiled = json.loads(subprocess.check_output(["plutil", "-convert", "json", "-o", "-", str(file)]))
                for key, entry in source.items():
                    if entry.get("shouldTranslate") is False: continue
                    val = entry["localizations"].get(locale)
                    expected = val["stringUnit"]["value"] if val else key
                    assert compiled.get(key) == expected, ("Missing compiled translation", table, locale, key)

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--compile", action="store_true", help="compile both catalogs with Xcode and inspect all .lproj output")
    parser.add_argument("--derived-data", type=Path, help="compare the app and widget's compiler-extracted UI keys from a clean build")
    args = parser.parse_args()
    local, info = load_catalog("Localizable.xcstrings"), load_catalog("InfoPlist.xcstrings")
    descriptions = plistlib.loads((RESOURCES / "Info.plist").read_bytes())
    validate(local, "Localizable")
    validate(info, "InfoPlist", descriptions)
    for key in descriptions:
        if key.endswith("UsageDescription"): assert key in info, key
    if args.derived_data:
        seen = set()
        for path in args.derived_data.rglob("*.stringsdata"):
            raw = json.loads(path.read_text())
            source = Path(raw.get("source", ""))
            if source.suffix != ".swift" or source.parent.name not in {"App","Core","Security","Interface","SyncWidget","Shared"}:
                continue
            seen.update(record["key"] for record in raw.get("tables", {}).get("Localizable", []))
        assert seen, "No app or widget Swift localization extraction output found."
        assert seen <= local.keys(), ("Missing compiler-extracted keys", sorted(seen - local.keys()))
        print(f"Matched {len(seen)} compiler-extracted keys.")
    if args.compile: validate_compilation(local, info)
    names = sorted(LANGUAGES | {"en"})
    print(f"Verified {len(local)} source keys and {len(info)} permission descriptions across {len(names)} languages.")

if __name__ == "__main__": main()
