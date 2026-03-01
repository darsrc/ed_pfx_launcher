#!/usr/bin/env python3
import argparse
import json
import sys


def parse_items(raw: str):
    return [x for x in raw.split("|") if x]


def fallback(prefixes, protons):
    if not prefixes or not protons:
        return {"saved": False, "reason": "missing_candidates"}
    return {"saved": True, "prefix_dir": prefixes[0], "proton_dir": protons[0], "ui": "legacy"}


def run_wizard(prefixes, protons):
    try:
        from prompt_toolkit.shortcuts import radiolist_dialog, button_dialog
    except Exception:
        return fallback(prefixes, protons)

    p_choices = [(p, p) for p in prefixes]
    r_choices = [(p, p) for p in protons]
    if not p_choices or not r_choices:
        return {"saved": False, "reason": "missing_candidates"}

    prefix = radiolist_dialog(
        title="ed_pfx_launcher wizard",
        text="Select Steam compatdata/pfx location:",
        values=p_choices,
    ).run()
    if not prefix:
        return {"saved": False, "reason": "cancel_prefix"}

    proton = radiolist_dialog(
        title="ed_pfx_launcher wizard",
        text="Select Proton directory:",
        values=r_choices,
    ).run()
    if not proton:
        return {"saved": False, "reason": "cancel_proton"}

    choice = button_dialog(
        title="Review",
        text=f"Prefix: {prefix}\nProton: {proton}\n\nSave these settings?",
        buttons=[("Save", "save"), ("Cancel", "cancel")],
    ).run()
    if choice != "save":
        return {"saved": False, "reason": "cancel_review", "prefix_dir": prefix, "proton_dir": proton}

    return {"saved": True, "prefix_dir": prefix, "proton_dir": proton, "ui": "wizard"}


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--prefixes", required=True)
    ap.add_argument("--protons", required=True)
    args = ap.parse_args()

    prefixes = parse_items(args.prefixes)
    protons = parse_items(args.protons)

    if not sys.stdin.isatty() or not sys.stdout.isatty():
        result = fallback(prefixes, protons)
        result["fallback_reason"] = "non_tty"
    else:
        result = run_wizard(prefixes, protons)
    print(json.dumps(result))


if __name__ == "__main__":
    main()
