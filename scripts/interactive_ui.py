#!/usr/bin/env python3
import configparser
import os
import sys


def parse_list(raw: str):
    return [x.strip() for x in raw.splitlines() if x.strip()]


def save_config(path: str, prefix: str, proton: str):
    cfg = configparser.ConfigParser()
    if os.path.exists(path):
        cfg.read(path)
    if not cfg.has_section("steam"):
        cfg.add_section("steam")
    if not cfg.has_section("proton"):
        cfg.add_section("proton")
    cfg.set("steam", "prefix_dir", prefix)
    cfg.set("proton", "dir", proton)
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w", encoding="utf-8") as fh:
        cfg.write(fh)


def run_wizard(config_path: str, prefixes, protons) -> int:
    try:
        from prompt_toolkit.shortcuts import radiolist_dialog, yes_no_dialog
    except Exception:
        return 2

    if not prefixes or not protons:
        return 1

    pvals = [(p, f"{os.path.basename(os.path.dirname(p))} - {p}") for p in prefixes]
    prvals = [(p, f"{os.path.basename(p)} - {p}") for p in protons]

    sel_prefix = radiolist_dialog(
        title="ed_pfx_launcher wizard",
        text="Select Steam compatdata prefix (NAME - DIR)",
        values=pvals,
    ).run()
    if not sel_prefix:
        return 3

    sel_proton = radiolist_dialog(
        title="ed_pfx_launcher wizard",
        text="Select Proton directory (NAME - DIR)",
        values=prvals,
    ).run()
    if not sel_proton:
        return 3

    ok = yes_no_dialog(
        title="Review",
        text=f"Save selections?\n\n[steam] prefix_dir={sel_prefix}\n[proton] dir={sel_proton}",
    ).run()
    if not ok:
        return 3

    save_config(config_path, sel_prefix, sel_proton)
    return 0


def main():
    if len(sys.argv) != 4:
        print("usage: interactive_ui.py <config_path> <prefixes_text> <protons_text>", file=sys.stderr)
        return 1

    config_path = sys.argv[1]
    prefixes = parse_list(sys.argv[2])
    protons = parse_list(sys.argv[3])

    if not sys.stdin.isatty() or not sys.stdout.isatty():
        return 4

    return run_wizard(config_path, prefixes, protons)


if __name__ == "__main__":
    raise SystemExit(main())
