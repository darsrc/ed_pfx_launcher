#!/usr/bin/env python3
import argparse
import sys


def legacy_select(items, label):
    print(f"Select {label}:")
    for i, item in enumerate(items, 1):
        print(f"  {i}) {item}")
    print("  0) cancel")
    choice = input("> ").strip()
    if choice == "0":
        return None
    idx = int(choice) - 1
    return items[idx]


def wizard(prefixes, protons):
    try:
        from prompt_toolkit.shortcuts import radiolist_dialog, button_dialog
    except Exception as exc:
        print(f"ERROR|prompt_toolkit unavailable: {exc}")
        return 2

    pref = radiolist_dialog(
        title="ed_pfx_launcher wizard",
        text="Select Steam prefix",
        values=[(p, p) for p in prefixes],
    ).run()
    if pref is None:
        print("CANCEL|prefix")
        return 0

    prot = radiolist_dialog(
        title="ed_pfx_launcher wizard",
        text="Select Proton directory",
        values=[(p, p) for p in protons],
    ).run()
    if prot is None:
        print("CANCEL|proton")
        return 0

    action = button_dialog(
        title="Review",
        text=f"Prefix:\n{pref}\n\nProton:\n{prot}\n",
        buttons=[("Save", "save"), ("Cancel", "cancel")],
    ).run()
    if action != "save":
        print("CANCEL|review")
        return 0

    print(f"OK|{pref}|{prot}")
    return 0


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--prefix", nargs="+", required=True)
    parser.add_argument("--proton", nargs="+", required=True)
    parser.add_argument("--legacy", action="store_true")
    args = parser.parse_args()

    if args.legacy:
        try:
            pref = legacy_select(args.prefix, "prefix")
            if not pref:
                print("CANCEL|legacy-prefix")
                return 0
            prot = legacy_select(args.proton, "proton")
            if not prot:
                print("CANCEL|legacy-proton")
                return 0
            print(f"OK|{pref}|{prot}")
            return 0
        except Exception as exc:
            print(f"ERROR|legacy failed: {exc}")
            return 2

    return wizard(args.prefix, args.proton)


if __name__ == "__main__":
    sys.exit(main())
