#!/usr/bin/env python3
"""Contract evaluation SDK — deterministic catalog/skill checks and eval cases.

No network. No model. Informational host-agent baselines are recorded, never gated.
"""
from __future__ import print_function

import json
import os
import re
import sys
from datetime import datetime, timezone

HERE = os.path.dirname(os.path.abspath(__file__))
EVALS = os.path.dirname(HERE)


def repo_root(start=None):
    cur = os.path.abspath(start or os.path.join(EVALS, ".."))
    return cur


def load_json(path):
    with open(path) as fh:
        return json.load(fh)


def rel(root, path):
    return os.path.relpath(path, root).replace(os.sep, "/")


def fail(msg):
    print(msg, file=sys.stderr)
    return False


PLUGIN_PATH = re.compile(r"\$NIGHTSHIFT_PLUGIN_ROOT/([^\s`\"')]+)")
TITLE = re.compile(r"^# .+ — (finite|open-ended) — ", re.M)
FRONTMATTER = re.compile(r"^---\n(.*?)\n---\n", re.S)
ITEM_GATE = r"item gate"


def estimated_tokens(n_bytes, bytes_per_token):
    if bytes_per_token < 1:
        bytes_per_token = 4
    return (n_bytes + bytes_per_token - 1) // bytes_per_token


def read_text(path):
    with open(path) as fh:
        return fh.read()


def list_catalog(root, shifts_dir):
    d = os.path.join(root, shifts_dir)
    out = []
    for name in sorted(os.listdir(d)):
        if name.endswith(".md"):
            cid = name[:-3]
            out.append({"id": cid, "kind": "catalog", "source": os.path.join(shifts_dir, name)})
    return out


def list_skills(config):
    out = []
    for cid, source in sorted((config.get("skills") or {}).items()):
        out.append({"id": cid, "kind": "skill", "source": source})
    return out


def has_section(text, patterns):
    for pat in patterns:
        if re.search(pat, text, re.I | re.M):
            return True
    return False


def extract_plugin_refs(text):
    refs = []
    for m in PLUGIN_PATH.finditer(text):
        refs.append(m.group(1).rstrip(".,;:"))
    return refs


def missing_contract_result(item):
    sections = {
        "trigger": False,
        "workModes": False,
        "capabilities": False,
        "evidence": False,
        "ending": False,
        "refusal": False,
        "time": False,
        "verification": False,
        "overlap": False,
        "contextBudget": True,
        "references": False,
        "fixtures": True,
    }
    return {
        "id": item["id"],
        "kind": item["kind"],
        "source": item["source"],
        "bytes": 0,
        "estimatedTokens": 0,
        "ending": None,
        "sections": sections,
        "errors": ["missing source file"],
    }


def budget_errors(cfg, item, n_bytes, tokens):
    errors = []
    max_b = int(cfg["budgets"]["maxBytes"])
    max_t = int(cfg["budgets"]["maxEstimatedTokens"])
    print(
        "budget id=%s maxBytes=%s measuredBytes=%s maxEstimatedTokens=%s measuredEstimatedTokens=%s"
        % (item["id"], max_b, n_bytes, max_t, tokens)
    )
    if n_bytes > max_b:
        errors.append("oversized instructions: %s bytes > maxBytes %s" % (n_bytes, max_b))
    if tokens > max_t:
        errors.append(
            "oversized instructions: %s estimated tokens > maxEstimatedTokens %s" % (tokens, max_t)
        )
    return errors


def check_catalog_sections(text, sections, errors):
    tm = TITLE.search(text)
    if tm:
        sections["ending"] = True
    sections["trigger"] = bool(tm) or has_section(text, [r"^Use when", r"^A night spent"])
    sections["workModes"] = has_section(
        text, [r"Supported", r"artifact mode", r"repository", r"item[- ]gate", r"monorepo", r"work mode"]
    )
    sections["refusal"] = has_section(text, [r"\bnever\b", r"do not ", r"Do not "])
    sections["verification"] = has_section(text, [r"^- Verify:", r"- Verify:"])
    sections["time"] = has_section(
        text, [r"Typical hours", r"Ending: open-ended", r"quitting time"]
    )
    sections["evidence"] = has_section(
        text,
        [r"cited-research", ITEM_GATE, r"receipts", r"snag-log"],
    )
    sections["overlap"] = has_section(
        text,
        [r"does not replace", r"Dedupe", r"snag-log", r"Never select"],
    )
    sections["capabilities"] = has_section(
        text,
        [r"Never select this entry in artifact mode", r"Supported", r"test runner"],
    )
    if not re.search(r"^```text$", text, re.M):
        errors.append("missing pasteable punch-list fence")
    if not re.search(r"^- \[ \] \*\*.+\*\*", text, re.M):
        errors.append("missing punch-list item")
    if not sections["ending"]:
        errors.append("missing ending in title (finite|open-ended)")
    if not sections["verification"]:
        errors.append("missing verification section")
    if not sections["trigger"]:
        errors.append("missing trigger/applicability")
    return tm.group(1) if tm else None


def check_skill_sections(text, sections, errors):
    fm = FRONTMATTER.match(text)
    sections["trigger"] = bool(fm) and "description:" in fm.group(1)
    if not sections["trigger"]:
        errors.append("missing YAML frontmatter description (trigger)")
    sections["ending"] = has_section(text, [r"hours", r"deadline", r"quitting time"])
    sections["refusal"] = has_section(text, [r"\b[Nn]ever\b", r"refuse"])
    sections["workModes"] = has_section(text, [r"artifact", r"repository"])
    sections["verification"] = has_section(text, [ITEM_GATE, r"Verify", r"receipts"])
    sections["time"] = has_section(text, [r"hours", r"deadline"])
    sections["evidence"] = has_section(text, [r"receipts", r"punch-list", r"evidence"])
    sections["overlap"] = has_section(
        text, [r"does not replace", r"Never select", r"not a "]
    )
    sections["capabilities"] = has_section(
        text, [r"artifact mode", r"work mode", r"applicable"]
    )
    ending = None
    tm = TITLE.search(text)
    if tm:
        ending = tm.group(1)
    return ending


def check_contract_references(root, text, sections, errors):
    refs = extract_plugin_refs(text)
    plugin_root = os.path.join(root, "plugins/nightshift")
    missing_refs = []
    for ref in refs:
        target = os.path.join(plugin_root, ref)
        if not os.path.exists(target):
            missing_refs.append(ref)
    if refs:
        sections["references"] = not missing_refs
    else:
        # Catalog entries may cite relative reference names.
        sections["references"] = has_section(
            text, [r"cited-research\.md", r"execution-modes\.md", ITEM_GATE]
        )
    for ref in missing_refs:
        errors.append("broken reference: $NIGHTSHIFT_PLUGIN_ROOT/%s" % ref)


def check_contract(root, cfg, _ident, item):
    src = os.path.join(root, item["source"])
    if not os.path.isfile(src):
        return missing_contract_result(item)

    sections = {
        "trigger": False,
        "workModes": False,
        "capabilities": False,
        "evidence": False,
        "ending": False,
        "refusal": False,
        "time": False,
        "verification": False,
        "overlap": False,
        "contextBudget": True,
        "references": False,
        "fixtures": True,
    }
    text = read_text(src)
    n_bytes = len(text.encode("utf-8"))
    bpt = int(cfg["budgets"]["bytesPerToken"])
    tokens = estimated_tokens(n_bytes, bpt)
    errors = budget_errors(cfg, item, n_bytes, tokens)

    ending = None
    if item["kind"] == "catalog":
        ending = check_catalog_sections(text, sections, errors)
    else:
        ending = check_skill_sections(text, sections, errors)

    check_contract_references(root, text, sections, errors)

    return {
        "id": item["id"],
        "kind": item["kind"],
        "source": item["source"],
        "bytes": n_bytes,
        "estimatedTokens": tokens,
        "ending": ending,
        "sections": sections,
        "errors": errors,
    }


def validate_case_schema(root, cfg, case, schema_validator):
    schema = os.path.join(root, cfg["caseSchema"])
    tmp = os.path.join(EVALS, ".case-tmp.json")
    with open(tmp, "w") as fh:
        json.dump(case, fh)
    rc = schema_validator(schema, tmp)
    try:
        os.remove(tmp)
    except OSError:
        pass
    return rc == 0


def fixture_path(root, fixture):
    fix_path = (
        os.path.join(root, "evals", fixture)
        if not fixture.startswith("evals/")
        else os.path.join(root, fixture)
    )
    if fixture.startswith("fixtures/"):
        fix_path = os.path.join(EVALS, fixture)
    return fix_path


def check_case_contract(case, contracts_by_id, errors):
    cid = case.get("contract")
    if cid not in contracts_by_id:
        errors.append("unknown contract %s" % cid)
    ending = case.get("expectedEnding")
    if cid in contracts_by_id and contracts_by_id[cid].get("ending") and ending:
        if contracts_by_id[cid]["kind"] == "catalog" and contracts_by_id[cid]["ending"] != ending:
            errors.append(
                "expectedEnding %s does not match contract ending %s"
                % (ending, contracts_by_id[cid]["ending"])
            )


def check_case_identifiers(case, ident, errors):
    host = case.get("host")
    if host not in ident["hosts"]:
        errors.append("host not in frozen identifiers")
    if case.get("workMode") not in ident["workModes"]:
        errors.append("workMode not in frozen identifiers")
    if case.get("authority") not in ident["authority"]:
        errors.append("authority not in frozen identifiers")
    if case.get("interruption") not in ident["interruption"]:
        errors.append("interruption not in frozen identifiers")


def check_expected_routing(case, fixture, marks, errors):
    expected = case.get("expectedRouting") or []
    applicable = set(marks.get("applicable") or [])
    not_app = set(marks.get("notApplicable") or [])
    for route in expected:
        if route == "none":
            continue
        if applicable and route not in applicable:
            errors.append(
                "routing %s is not applicable on fixture %s" % (route, fixture)
            )
        if route in not_app:
            errors.append(
                "routing %s is forbidden by fixture %s" % (route, fixture)
            )


def check_required_evidence(case, marks, errors):
    req = set(case.get("requiredEvidence") or [])
    available = set(marks.get("evidence") or [])
    missing_ev = sorted(req - available) if available else []
    if available and missing_ev:
        errors.append("required evidence missing from fixture: %s" % missing_ev)


def check_fixture_scenario(case, marks, errors):
    if case.get("workMode") != marks.get("workMode") and marks.get("workMode"):
        errors.append(
            "case workMode %s != fixture workMode %s"
            % (case.get("workMode"), marks.get("workMode"))
        )
    if case.get("scenario") == "unsafe-authority" and case.get("authority") != "unsafe":
        errors.append("unsafe-authority scenario requires authority=unsafe")
    if case.get("scenario") == "artifact-mode" and case.get("workMode") != "artifact":
        errors.append("artifact-mode scenario requires workMode=artifact")


def check_fixture_markers(case, fixture, marks, errors):
    check_expected_routing(case, fixture, marks, errors)
    check_required_evidence(case, marks, errors)
    check_fixture_scenario(case, marks, errors)


def check_case_fixture(root, case, errors):
    fixture = case.get("fixture") or ""
    fix_path = fixture_path(root, fixture)
    if not os.path.isdir(fix_path):
        errors.append("missing fixture directory: %s" % fixture)
        return
    markers = os.path.join(fix_path, ".eval-markers.json")
    if not os.path.isfile(markers):
        errors.append("fixture %s has no .eval-markers.json" % fixture)
        return
    check_fixture_markers(case, fixture, load_json(markers), errors)


def check_case(root, cfg, ident, case, contracts_by_id, schema_validator):
    errors = []
    if not validate_case_schema(root, cfg, case, schema_validator):
        errors.append("case does not match evals/schema/case-v1.json")

    check_case_contract(case, contracts_by_id, errors)
    check_case_identifiers(case, ident, errors)

    forbidden = set(case.get("forbiddenRouting") or [])
    expected = case.get("expectedRouting") or []
    overlap = forbidden.intersection(expected)
    if overlap:
        errors.append("forbiddenRouting overlaps expectedRouting: %s" % sorted(overlap))

    check_case_fixture(root, case, errors)
    return {"id": case.get("id"), "errors": errors}


def duplicate_triggers(contracts):
    errors = []
    seen = {}
    for c in contracts:
        key = c["id"]
        if key in seen:
            errors.append("duplicate/ambiguous trigger id %s (%s and %s)" % (key, seen[key], c["source"]))
        seen[key] = c["source"]
    titles = {}
    for c in contracts:
        if c["kind"] != "catalog":
            continue
        src = c.get("_title")
        if src:
            if src in titles:
                errors.append("duplicate/ambiguous title %s" % src)
            titles[src] = c["id"]
    return errors


def load_cases(root):
    path = os.path.join(root, "evals", "cases", "v1.json")
    data = load_json(path)
    if not isinstance(data, list):
        raise SystemExit("evals/cases/v1.json must be an array")
    return data


def schema_validator_cmd(root):
    helper = os.path.join(root, "tests", "helpers", "validate-json-schema.py")

    def run(schema, document):
        import subprocess

        p = subprocess.Popen(
            [sys.executable, helper, schema, document],
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        )
        _, err = p.communicate()
        if p.returncode != 0 and err:
            sys.stderr.write(err.decode("utf-8", "replace"))
        return p.returncode

    return run


def coverage_errors(ident, cases, contracts_by_id):
    errors = []
    by_contract = {}
    scenarios = set()
    hosts = set()
    for case in cases:
        by_contract.setdefault(case["contract"], set()).add(case["scenario"])
        scenarios.add(case["scenario"])
        hosts.add(case["host"])
    for cid in ident["priorityContracts"]:
        if cid not in contracts_by_id:
            errors.append("priority contract missing from catalog/skills: %s" % cid)
            continue
        have = by_contract.get(cid) or set()
        if "positive" not in have:
            errors.append("missing catalog coverage: no positive case for %s" % cid)
        if "negative" not in have:
            errors.append("missing catalog coverage: no negative case for %s" % cid)
    required_scen = {
        "positive",
        "negative",
        "ambiguous-neighbor",
        "missing-tool",
        "large-backlog",
        "artifact-mode",
        "interrupted-revived",
        "unsafe-authority",
        "unsupported-environment",
    }
    missing_scen = sorted(required_scen - scenarios)
    if missing_scen:
        errors.append("missing scenario coverage: %s" % ", ".join(missing_scen))
    missing_hosts = sorted(set(ident["hosts"]) - hosts)
    if missing_hosts:
        errors.append("missing host coverage: %s" % ", ".join(missing_hosts))
    return errors


def build_report(cfg, contracts, cases, extra_errors):
    ok = True
    for c in contracts:
        if c.get("errors"):
            ok = False
    for c in cases:
        if c.get("errors"):
            ok = False
    if extra_errors:
        ok = False
    return {
        "schemaVersion": 1,
        "generatedAt": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "budgets": cfg["budgets"],
        "contracts": contracts,
        "cases": cases,
        "informationalBaseline": {
            "status": "not-run",
            "gate": False,
            "note": cfg["informationalBaseline"]["note"],
        },
        "extraErrors": extra_errors,
        "ok": ok,
    }


def render_markdown(report):
    lines = [
        "# Eval report",
        "",
        "Generated: %s" % report["generatedAt"],
        "",
        "Deterministic result: **%s**" % ("pass" if report["ok"] else "fail"),
        "",
        "## Size budget",
        "",
        "maxBytes=%s maxEstimatedTokens=%s bytesPerToken=%s"
        % (
            report["budgets"]["maxBytes"],
            report["budgets"]["maxEstimatedTokens"],
            report["budgets"]["bytesPerToken"],
        ),
        "",
        "| Contract | Kind | Bytes | Est. tokens | Ending | Errors |",
        "| --- | --- | ---: | ---: | --- | --- |",
    ]
    for c in report["contracts"]:
        err = "; ".join(c.get("errors") or []) or "—"
        lines.append(
            "| %s | %s | %s | %s | %s | %s |"
            % (c["id"], c["kind"], c["bytes"], c["estimatedTokens"], c.get("ending") or "—", err)
        )
    lines.extend(["", "## Cases", "", "| Case | Errors |", "| --- | --- |"])
    for c in report["cases"]:
        err = "; ".join(c.get("errors") or []) or "—"
        lines.append("| %s | %s |" % (c["id"], err))
    extra = report.get("extraErrors") or []
    lines.extend(["", "## Release checks", ""])
    if extra:
        for e in extra:
            lines.append("- FAIL: %s" % e)
    else:
        lines.append("- pass")
    ib = report["informationalBaseline"]
    lines.extend(
        [
            "",
            "## Informational model baseline",
            "",
            "Status: %s (not a release gate)" % ib["status"],
            "",
            ib["note"],
            "",
        ]
    )
    return "\n".join(lines) + "\n"


def load_checked_contracts(root, cfg, ident, items):
    contracts = []
    titles = {}
    extra = []
    for item in items:
        result = check_contract(root, cfg, ident, item)
        if result["kind"] == "catalog" and result.get("ending"):
            src = os.path.join(root, result["source"])
            first = read_text(src).splitlines()[0]
            if first in titles:
                extra.append("duplicate/ambiguous trigger: %s and %s" % (titles[first], result["id"]))
            titles[first] = result["id"]
        contracts.append(result)
    extra.extend(duplicate_triggers(items))
    return contracts, extra


def load_checked_cases(root, cfg, ident, contracts):
    cases_raw = load_cases(root)
    validator = schema_validator_cmd(root)
    by_id = {c["id"]: c for c in contracts}
    cases = [
        check_case(root, cfg, ident, case, by_id, validator) for case in cases_raw
    ]
    return cases, cases_raw, by_id


def write_validation_report(root, report):
    reports = os.path.join(EVALS, "reports")
    os.makedirs(reports, exist_ok=True)
    json_path = os.path.join(reports, "latest.json")
    md_path = os.path.join(reports, "latest.md")
    with open(json_path, "w") as fh:
        json.dump(report, fh, indent=2, sort_keys=True)
        fh.write("\n")
    with open(md_path, "w") as fh:
        fh.write(render_markdown(report))
    print("wrote %s" % rel(root, md_path))
    print("wrote %s" % rel(root, json_path))


def print_validation_errors(contracts, cases, extra):
    for c in contracts:
        for e in c.get("errors") or []:
            print("contract %s: %s" % (c["id"], e))
    for c in cases:
        for e in c.get("errors") or []:
            print("case %s: %s" % (c["id"], e))
    for e in extra:
        print("release: %s" % e)


def cmd_validate(root, write_report=False):
    cfg = load_json(os.path.join(EVALS, "config.json"))
    ident = load_json(os.path.join(root, cfg["identifiers"]))
    items = list_catalog(root, cfg["catalogShifts"]) + list_skills(cfg)
    contracts, extra = load_checked_contracts(root, cfg, ident, items)
    cases, cases_raw, by_id = load_checked_cases(root, cfg, ident, contracts)
    extra.extend(coverage_errors(ident, cases_raw, by_id))

    report = build_report(cfg, contracts, cases, extra)
    if write_report:
        write_validation_report(root, report)
    print_validation_errors(contracts, cases, extra)
    return 0 if report["ok"] else 2


def cmd_check_file(root, path):
    cfg = load_json(os.path.join(EVALS, "config.json"))
    ident = load_json(os.path.join(root, cfg["identifiers"]))
    abs_path = path if os.path.isabs(path) else os.path.join(os.getcwd(), path)
    kind = "catalog"
    cid = os.path.splitext(os.path.basename(abs_path))[0]
    if abs_path.endswith("SKILL.md"):
        kind = "skill"
        parent = os.path.basename(os.path.dirname(abs_path))
        cid = parent
    item = {"id": cid, "kind": kind, "source": rel(root, abs_path)}
    result = check_contract(root, cfg, ident, item)
    for e in result.get("errors") or []:
        print("contract %s: %s" % (cid, e))
    return 0 if not result.get("errors") else 2


def usage():
    print(
        "usage: evals/validate.sh [--root DIR] [--report] [path]\n"
        "       evals/run.sh [--root DIR]",
        file=sys.stderr,
    )
    return 1


def parse_main_args(argv):
    root = repo_root()
    write_report = False
    paths = []
    command = "validate"
    args = argv[1:]
    if args and args[0] in ("validate", "run", "check"):
        command = args[0]
        args = args[1:]
    i = 0
    while i < len(args):
        a = args[i]
        if a == "--root":
            if i + 1 >= len(args):
                return None, usage()
            root = os.path.abspath(args[i + 1])
            i += 2
            continue
        if a == "--report":
            write_report = True
            i += 1
            continue
        if a in ("-h", "--help"):
            return None, usage()
        paths.append(a)
        i += 1
    return {
        "root": root,
        "write_report": write_report,
        "paths": paths,
        "command": command,
    }, None


def main(argv):
    opts, err = parse_main_args(argv)
    if err is not None:
        return err
    os.chdir(opts["root"])
    if opts["command"] == "run":
        return cmd_validate(opts["root"], write_report=True)
    if opts["paths"]:
        rc = 0
        for p in opts["paths"]:
            r = cmd_check_file(opts["root"], p)
            if r != 0:
                rc = r
        return rc
    return cmd_validate(opts["root"], write_report=opts["write_report"])


if __name__ == "__main__":
    sys.exit(main(sys.argv))
