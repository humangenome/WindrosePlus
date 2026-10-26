#!/usr/bin/env python3
"""Checks Windrose+ data files against the schemas in scripts/contract/schemas.

The files in windrose_plus_data are read directly by the dashboard server and by host panels, so their shape is
a contract like the HTTP routes: add fields, never rename or remove one. This checks every file in the folders
given (the samples written by scripts/test-lua/contract.lua, and the fixture game folder the dashboard tests
use), plus the counts a JSON Schema cannot express, and fails if any schema went unused.

Run: python3 scripts/contract/check-data-files.py <folder> [<folder> ...]
     python3 scripts/contract/check-data-files.py --self-test <samples folder>
     python3 scripts/contract/check-data-files.py --partial <folder>   (some schemas may go unused, e.g. saved route answers)
Needs: pip install jsonschema
"""
import json
import os
import re
import sys

from jsonschema import Draft202012Validator

HERE = os.path.dirname(os.path.abspath(__file__))
SCHEMAS = os.path.join(HERE, "schemas")

# file name (without folder) -> schema; the first match wins
RULES = [
    (r"^server_status(\..+)?\.json$", "server_status.schema.json"),
    (r"^livemap_data(\..+)?\.json$", "livemap_data.schema.json"),
    (r"^pois(\..+)?\.json$", "pois.schema.json"),
    (r"^poi_discovered_classes(\..+)?\.json$", "poi_discovered_classes.schema.json"),
    (r"^commands(\..+)?\.json$", "commands.schema.json"),
    (r"^(rcon_command(\..+)?|cmd_[A-Za-z0-9_-]+)\.json$", "rcon_command.schema.json"),
    (r"^(rcon_response(\..+)?|res_[A-Za-z0-9_-]+)\.json$", "rcon_response.schema.json"),
    (r"^console_history(\..+)?\.json$", "console_history.schema.json"),
    (r"^rcon_status(\..+)?\.json$", "rcon_status.schema.json"),
    (r"^(activity(\..+)?|[0-9]{4}-[0-9]{2}-[0-9]{2})\.log$", "activity_log_line.schema.json"),
    (r"^windrose_plus(\..+)?\.json$", "windrose_plus_config.schema.json"),
    (r"^map_coords(\..+)?\.json$", "map_coords.schema.json"),
]
# files in a fixture game folder this check does not cover (built by PowerShell tools or the game itself)
NOT_COVERED = re.compile(r"^(map_generation_status\.json|terrain_v17\.json|.+\.png|.+\.ini|.+\.txt|"
                         r"[A-Za-z0-9_]+\.json\.tmp|dashboard_session\.key|items_full\.json|item_usage\.json|_summary\.json|"
                         r"build\.log|\.gitkeep)$")


def load_schemas():
    validators = {}
    for name in sorted(os.listdir(SCHEMAS)):
        if name.endswith(".schema.json"):
            with open(os.path.join(SCHEMAS, name), encoding="utf-8") as f:
                schema = json.load(f)
            Draft202012Validator.check_schema(schema)
            validators[name] = Draft202012Validator(schema)
    return validators


def extra_checks(schema_name, doc):
    """Counts and cross-field rules a schema cannot say."""
    problems = []
    if schema_name == "commands.schema.json":
        if doc["count"] != len(doc["commands"]):
            problems.append("count %d but %d commands" % (doc["count"], len(doc["commands"])))
        names = [c["name"] for c in doc["commands"]]
        if len(names) != len(set(names)):
            problems.append("a command is listed twice")
    elif schema_name == "livemap_data.schema.json":
        for key, count in (("players", "player_count"), ("mobs", "mob_count"), ("nodes", "node_count")):
            if doc[count] != len(doc[key]):
                problems.append("%s %d but %d %s" % (count, doc[count], len(doc[key]), key))
        if any(p.get("x") is None for p in doc["players"]):
            problems.append("a player without a position is listed (they are left out)")
    elif schema_name == "server_status.schema.json":
        if not doc.get("degraded") and doc["server"]["player_count"] != len(doc["players"]):
            problems.append("player_count %d but %d players" % (doc["server"]["player_count"], len(doc["players"])))
    elif schema_name == "pois.schema.json":
        if doc["total_pois"] != len(doc["pois"]):
            problems.append("total_pois %d but %d pois" % (doc["total_pois"], len(doc["pois"])))
    return problems


def check_file(path, schema_name, validator):
    problems = []
    with open(path, "rb") as f:
        raw = f.read()
    if raw.startswith(b"\xef\xbb\xbf"):
        problems.append("starts with a byte order mark (the readers expect plain UTF-8)")
        raw = raw[3:]
    try:
        text = raw.decode("utf-8")
    except UnicodeDecodeError as e:
        return ["not UTF-8: %s" % e]
    docs = []
    if schema_name == "activity_log_line.schema.json":
        for n, line in enumerate(text.splitlines(), 1):
            if line.strip():
                try:
                    docs.append(("line %d" % n, json.loads(line)))
                except ValueError as e:
                    problems.append("line %d is not JSON: %s" % (n, e))
        if not docs:
            problems.append("no lines")
    else:
        try:
            docs.append(("", json.loads(text)))
        except ValueError as e:
            return problems + ["not JSON: %s" % e]
    for where, doc in docs:
        for err in sorted(validator.iter_errors(doc), key=lambda e: list(e.absolute_path)):
            at = "/".join(str(p) for p in err.absolute_path) or "(top)"
            problems.append("%s%s: %s" % (where + " " if where else "", at, err.message[:200]))
        if not problems:
            problems.extend(extra_checks(schema_name, doc))
    return problems


def self_test(folder):
    """Each required field, taken out of a real sample one at a time, must make the check fail; so must a field
    renamed and a number turned into text. Guards against schemas that let everything through."""
    validators = load_schemas()
    failed = 0
    tried = 0
    for name in sorted(os.listdir(folder)):
        schema_name = next((s for pattern, s in RULES if re.match(pattern, name)), None)
        if schema_name is None or schema_name == "activity_log_line.schema.json":
            continue
        with open(os.path.join(folder, name), encoding="utf-8") as f:
            doc = json.load(f)
        target = doc[0] if isinstance(doc, list) and doc else doc
        required = validators[schema_name].schema.get("required") or \
            validators[schema_name].schema.get("items", {}).get("required") or []
        for key in required:
            broken = json.loads(json.dumps(doc))
            t = broken[0] if isinstance(broken, list) else broken
            value = t.pop(key)
            t[key + "_renamed"] = value
            tried += 1
            if not list(validators[schema_name].iter_errors(broken)) and not extra_checks(schema_name, broken):
                print("FAIL self-test: %s still passes with %s renamed" % (name, key))
                failed += 1
        for key, value in list(target.items()):
            if isinstance(value, (int, float)) and not isinstance(value, bool) and key in required:
                broken = json.loads(json.dumps(doc))
                t = broken[0] if isinstance(broken, list) else broken
                t[key] = str(value)
                tried += 1
                if not list(validators[schema_name].iter_errors(broken)):
                    print("FAIL self-test: %s still passes with %s as text" % (name, key))
                    failed += 1
    print("self-test: %d broken copies tried, %d slipped through" % (tried, failed))
    return 1 if failed or tried == 0 else 0


def main(folders):
    if not folders:
        print(__doc__)
        return 2
    if folders[0] == "--self-test":
        return self_test(folders[1])
    partial = folders[0] == "--partial"
    if partial:
        folders = folders[1:]
    validators = load_schemas()
    used = set()
    failed = 0
    checked = 0
    for folder in folders:
        for dirpath, _, names in os.walk(folder):
            for name in sorted(names):
                path = os.path.join(dirpath, name)
                rel = os.path.relpath(path, folder)
                schema_name = next((s for pattern, s in RULES if re.match(pattern, name)), None)
                if schema_name is None:
                    if NOT_COVERED.match(name):
                        continue
                    print("FAIL %s: no schema covers this file (add one, or list it as not covered)" % rel)
                    failed += 1
                    continue
                problems = check_file(path, schema_name, validators[schema_name])
                checked += 1
                used.add(schema_name)
                if problems:
                    failed += 1
                    print("FAIL %s (%s)" % (rel, schema_name))
                    for p in problems[:12]:
                        print("       " + p)
                else:
                    print("ok   %s (%s)" % (rel, schema_name))
    for name in ([] if partial else sorted(set(validators) - used)):
        print("FAIL schema %s checked no file: a schema nothing is checked against stops meaning anything" % name)
        failed += 1
    print("%d file(s) checked, %d problem(s)" % (checked, failed))
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
