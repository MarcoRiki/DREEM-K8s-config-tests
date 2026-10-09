#!/usr/bin/env python3
"""Builds the "assignments" of profiles.json for the worker BMHs that actually exist.

profiles.json describes the fleet as an ordered list of "slots", one hardware profile
each (size, consumption_profile, group). The worker BMHs, sorted by name the way a
person reads them (node-2 before node-10), take the slots in order. The same fleet
therefore comes out whichever BMH became the control plane: with node-0 as control
plane node-1 takes the first slot; with node-5 as control plane node-0 does.

A file without "slots" (the older format) keeps its values: its assignments, in name
order, become the slots. Without a file the built-in default fleet is used.

Usage:
  gen-profiles.py --profiles profiles.json --workers node-0 node-1 ... [--write | --check | --summary]
    (no mode)   print the resulting file
    --write     write the file
    --check     exit 1 if the file's assignments differ from the generated ones
    --summary   print the host -> slot table only
"""
import argparse
import copy
import json
import re
import sys

SLOT_KEYS = ("size", "consumption_profile", "group")

SLOTS_NOTE = [
    "",
    "slots is the ordered list of hardware profiles; assignments is generated from",
    "it by gen-profiles.py (run by init-testbed.sh). The worker BMHs, sorted by name,",
    "take the slots in order, so the fleet is the same whichever BMH the control plane",
    "lands on. Edit slots, not assignments, then run init-testbed.sh",
    "--regenerate-profiles.",
]

DEFAULT = {
    "_comment": [
        "Authoritative, deterministic hardware profile for the testbed.",
        "This file is the ground truth: the SAME values are applied to every arm",
        "(DREEM ENERGY, DREEM QOS, baseline, Cluster Autoscaler) so that any energy",
        "difference between arms is attributable to the scaling algorithm and not to",
        "a re-rolled random fleet. Never regenerate it between arms.",
        "",
        "consumption_profile is the value written to dreemk8s.io/consumption-profile.",
        "It is a relative energy index against baseline_profile (100 = the reference",
        "server whose measured power curve drives the offline analysis). Higher =",
        "consumes more, which matches DREEM's scoring (EnergyProfile is a benefit",
        "criterion in scale-down and a cost criterion in scale-up).",
        "",
        "group is a SECOND, INDEPENDENT node label (A/B/C/D) used for node affinity in",
        "the muBench workmodel, separate from size. It exists to break a confound: on",
        "size alone, EnergyProfile and pod-density/PreferredNodeAffinity move",
        "together (big nodes = high EP AND few, heavy pods = low affinity), so every",
        "scale-down candidate pool showed the same node scoring worst on both axes at",
        "once and the two DREEM profiles (QOS vs ENERGY) could not be told apart.",
        "group is dealt out in snake order over the EnergyProfile-sorted list",
        "(A B C D D C B A, not derived from size), so every group holds one big and",
        "one small node and the groups' EnergyProfile totals differ by at most 10. A pod that prefers a",
        "group can then land on a low-EP or a high-EP node with equal likelihood,",
        "which is what lets the two criteria vary independently in a scale-down",
        "decision.",
        "",
        "The control-plane BMH is deliberately absent from both mappings: it is",
        "discovered at runtime via Machine -> Metal3Machine -> BMH and always",
        "excluded.",
    ] + SLOTS_NOTE,
    "baseline_profile": 220,
    "cores_per_node": 10,
    "ranges": {"small": [160, 210], "big": [230, 280]},
    "slots": [
        {"size": "big", "consumption_profile": 280, "group": "A"},
        {"size": "big", "consumption_profile": 270, "group": "B"},
        {"size": "big", "consumption_profile": 250, "group": "C"},
        {"size": "big", "consumption_profile": 240, "group": "D"},
        {"size": "small", "consumption_profile": 160, "group": "A"},
        {"size": "small", "consumption_profile": 180, "group": "B"},
        {"size": "small", "consumption_profile": 190, "group": "C"},
        {"size": "small", "consumption_profile": 210, "group": "D"},
    ],
}


def natural_key(name):
    return [int(part) if part.isdigit() else part for part in re.split(r"(\d+)", name)]


def slots_of(current):
    if current and current.get("slots"):
        return current["slots"]
    if current and current.get("assignments"):
        assignments = current["assignments"]
        return [assignments[host] for host in sorted(assignments, key=natural_key)]
    return DEFAULT["slots"]


def validate(doc, slots, workers):
    problems = []
    if len(slots) != len(workers):
        problems.append(f"{len(slots)} slots for {len(workers)} worker BMHs ({' '.join(workers)}): "
                        "edit the slots in profiles.json so there is exactly one per worker")
    ranges = doc.get("ranges", {})
    for number, slot in enumerate(slots, 1):
        missing = [key for key in SLOT_KEYS if slot.get(key) in (None, "")]
        if missing:
            problems.append(f"slot {number} has no {', '.join(missing)}")
            continue
        bounds = ranges.get(slot["size"])
        if bounds and not bounds[0] <= slot["consumption_profile"] <= bounds[1]:
            problems.append(f"slot {number}: consumption_profile {slot['consumption_profile']} "
                            f"is outside the {slot['size']} range {bounds}")
    return problems


def entry(slot):
    return "{ " + ", ".join(f"{json.dumps(key)}: {json.dumps(slot[key])}" for key in SLOT_KEYS) + " }"


def render(doc):
    order = ["_comment", "baseline_profile", "cores_per_node", "ranges", "slots", "assignments"]
    parts = []
    for key in order + [k for k in doc if k not in order]:
        if key not in doc:
            continue
        value = doc[key]
        if key == "ranges":
            body = ",\n".join(f"    {json.dumps(size)}: {json.dumps(bounds)}" for size, bounds in value.items())
            parts.append(f'  "ranges": {{\n{body}\n  }}')
        elif key == "slots":
            body = ",\n".join(f"    {entry(slot)}" for slot in value)
            parts.append(f'  "slots": [\n{body}\n  ]')
        elif key == "assignments":
            body = ",\n".join(f"    {json.dumps(host)}: {entry(slot)}" for host, slot in value.items())
            parts.append(f'  "assignments": {{\n{body}\n  }}')
        else:
            parts.append(f"  {json.dumps(key)}: " + json.dumps(value, indent=2).replace("\n", "\n  "))
    return "{\n" + ",\n".join(parts) + "\n}\n"


def main():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--profiles", required=True)
    parser.add_argument("--workers", nargs="+", required=True)
    mode = parser.add_mutually_exclusive_group()
    mode.add_argument("--write", action="store_true")
    mode.add_argument("--check", action="store_true")
    mode.add_argument("--summary", action="store_true")
    args = parser.parse_args()

    try:
        with open(args.profiles) as f:
            current = json.load(f)
    except FileNotFoundError:
        current = None

    doc = copy.deepcopy(current if current is not None else DEFAULT)
    slots = slots_of(current)
    workers = sorted(set(args.workers), key=natural_key)
    problems = validate(doc, slots, workers)
    if problems:
        for problem in problems:
            print(f"ERROR: {problem}", file=sys.stderr)
        return 2

    assignments = {host: {key: slots[i][key] for key in SLOT_KEYS} for i, host in enumerate(workers)}

    if args.check:
        old = (current or {}).get("assignments", {})
        if old == assignments:
            return 0
        for host in sorted(set(old) | set(assignments), key=natural_key):
            if old.get(host) != assignments.get(host):
                print(f"  {host}: in profiles.json {old.get(host)}, for the live workers {assignments.get(host)}",
                      file=sys.stderr)
        return 1

    doc["slots"] = [{key: slot[key] for key in SLOT_KEYS} for slot in slots]
    doc["assignments"] = assignments
    comment = doc.setdefault("_comment", [])
    if not any("slots is the ordered list" in line for line in comment):
        comment.extend(SLOTS_NOTE)

    if args.summary or args.write:
        for number, (host, slot) in enumerate(assignments.items(), 1):
            print(f"  slot {number}: {host:<10} size={slot['size']:<5} "
                  f"profile={slot['consumption_profile']:<4} group={slot['group']}")
    if args.write:
        with open(args.profiles, "w") as f:
            f.write(render(doc))
        print(f"wrote {args.profiles}")
    elif not args.summary:
        sys.stdout.write(render(doc))
    return 0


if __name__ == "__main__":
    sys.exit(main())
