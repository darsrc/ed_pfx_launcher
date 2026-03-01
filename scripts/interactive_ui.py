#!/usr/bin/env python3
"""Interactive UI backend for ed_pfx_launcher.

Outputs newline-delimited key=value pairs:
  status=save|cancel|fallback
  prefix=<selected prefix path>
  proton=<selected proton executable path>
  message=<human-readable context>
"""

from __future__ import annotations

import argparse
import os
import sys
from typing import List, Tuple


def pick_by_mode(items: List[str], mode: str) -> str:
    if not items:
        raise ValueError("no candidates available")
    mode = (mode or "first").lower()
    if mode == "newest":
        return max(items, key=lambda p: os.path.getmtime(p))
    return sorted(items)[0]


def emit(status: str, prefix: str = "", proton: str = "", message: str = "") -> int:
    print(f"status={status}")
    if prefix:
        print(f"prefix={prefix}")
    if proton:
        print(f"proton={proton}")
    if message:
        print(f"message={message}")
    return 0


def non_tty_fallback(prefixes: List[str], protons: List[str], prefix_mode: str, proton_mode: str, reason: str) -> int:
    prefix = pick_by_mode(prefixes, prefix_mode)
    proton = pick_by_mode(protons, proton_mode)
    return emit(
        "fallback",
        prefix,
        proton,
        f"non-TTY fallback to legacy-compatible auto-select ({reason})",
    )


def run_prompt_toolkit(prefixes: List[str], protons: List[str]) -> Tuple[str, str] | None:
    from prompt_toolkit.shortcuts import button_dialog, radiolist_dialog, yes_no_dialog

    prefix = prefixes[0]
    proton = protons[0]

    while True:
        selected_prefix = radiolist_dialog(
            title="ed_pfx_launcher wizard",
            text="Step 1/3: Select Wine prefix candidate",
            values=[(item, item) for item in prefixes],
            default=prefix,
            ok_text="Next",
            cancel_text="Cancel",
        ).run()
        if selected_prefix is None:
            if yes_no_dialog(title="Cancel setup", text="Cancel without saving changes?").run():
                return None
            continue
        prefix = selected_prefix

        selected_proton = radiolist_dialog(
            title="ed_pfx_launcher wizard",
            text="Step 2/3: Select Proton candidate",
            values=[(item, item) for item in protons],
            default=proton,
            ok_text="Next",
            cancel_text="Back",
        ).run()
        if selected_proton is None:
            continue
        proton = selected_proton

        action = button_dialog(
            title="Review selections",
            text=(
                "Step 3/3: Review and confirm\n\n"
                f"Prefix: {prefix}\n"
                f"Proton: {proton}\n\n"
                "Select Save to persist, Edit to revise, or Cancel to exit."
            ),
            buttons=[
                ("Save", "save"),
                ("Edit Prefix", "edit_prefix"),
                ("Edit Proton", "edit_proton"),
                ("Cancel", "cancel"),
            ],
        ).run()

        if action == "save":
            if yes_no_dialog(title="Confirm save", text="Write selected prefix and Proton to config?").run():
                return prefix, proton
            continue
        if action == "edit_prefix":
            continue
        if action == "edit_proton":
            selected_proton = radiolist_dialog(
                title="ed_pfx_launcher wizard",
                text="Step 2/3: Select Proton candidate",
                values=[(item, item) for item in protons],
                default=proton,
                ok_text="Review",
                cancel_text="Back",
            ).run()
            if selected_proton is not None:
                proton = selected_proton
            continue

        if yes_no_dialog(title="Cancel setup", text="Cancel without saving changes?").run():
            return None


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Interactive UI backend for ed_pfx_launcher")
    parser.add_argument("--prefix-candidate", action="append", default=[])
    parser.add_argument("--proton-candidate", action="append", default=[])
    parser.add_argument("--prefix-select", default="first")
    parser.add_argument("--proton-select", default="first")
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    prefixes = args.prefix_candidate
    protons = args.proton_candidate

    if not prefixes or not protons:
        print("status=error")
        print("message=missing candidates")
        return 2

    test_action = os.environ.get("ED_PFX_UI_TEST_ACTION", "").lower().strip()
    if test_action == "cancel":
        return emit("cancel", message="test-action cancel")
    if test_action == "save":
        prefix = pick_by_mode(prefixes, args.prefix_select)
        proton = pick_by_mode(protons, args.proton_select)
        return emit("save", prefix, proton, "test-action save")

    if not (sys.stdin.isatty() and sys.stdout.isatty()):
        return non_tty_fallback(prefixes, protons, args.prefix_select, args.proton_select, "stdin/stdout not tty")

    try:
        result = run_prompt_toolkit(prefixes, protons)
    except Exception as exc:  # prompt_toolkit missing or terminal backend issue
        return non_tty_fallback(prefixes, protons, args.prefix_select, args.proton_select, f"wizard unavailable: {exc}")

    if result is None:
        return emit("cancel", message="user cancelled")

    prefix, proton = result
    return emit("save", prefix, proton, "wizard confirmed save")


if __name__ == "__main__":
    raise SystemExit(main())

