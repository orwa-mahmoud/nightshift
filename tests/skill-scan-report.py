#!/usr/bin/env python3
"""Write the skill-scan job summary from one scanner run.

The scanner is not invoked here. Pass its exit status and any JSON files it
already wrote. Cisco reports use summary.findings_by_severity and
results[].findings[].file_path. Other JSON is counted only when every finding
has a severity string.
"""

import argparse
import json
import os
import sys

SEVERITIES = ("critical", "high", "medium", "low", "info")


def load_reports(paths):
    reports = []
    errors = []
    for path in paths:
        try:
            with open(path, encoding="utf-8") as handle:
                reports.append(json.load(handle))
        except (OSError, UnicodeError, json.JSONDecodeError) as exc:
            errors.append(f"{path}: {exc}")
    return reports, errors


def cisco_totals(report):
    summary = report.get("summary") if isinstance(report, dict) else None
    counts = summary.get("findings_by_severity") if isinstance(summary, dict) else None
    if not isinstance(counts, dict):
        return None
    totals = {}
    for name in SEVERITIES:
        value = counts.get(name, 0)
        if isinstance(value, bool) or not isinstance(value, int):
            return None
        totals[name] = value
    return totals


def finding_totals(findings):
    totals = {name: 0 for name in SEVERITIES}
    for finding in findings:
        if not isinstance(finding, dict):
            return None
        severity = finding.get("severity")
        if not isinstance(severity, str) or severity.lower() not in totals:
            return None
        totals[severity.lower()] += 1
    return totals


def collect(report, totals, paths, count_findings=True):
    if isinstance(report, list):
        for item in report:
            collect(item, totals, paths, count_findings)
        return
    if not isinstance(report, dict):
        return
    known = cisco_totals(report)
    if known is not None and count_findings:
        for name, value in known.items():
            totals[name] = totals.get(name, 0) + value
        count_findings = False
    findings = report.get("findings")
    if isinstance(findings, list):
        if count_findings:
            counted = finding_totals(findings)
            if counted is not None:
                for name, value in counted.items():
                    totals[name] = totals.get(name, 0) + value
        for finding in findings:
            if not isinstance(finding, dict):
                continue
            for key in ("file_path", "path", "skill_path"):
                value = finding.get(key)
                if isinstance(value, str) and value:
                    paths.add(value)
                    break
    results = report.get("results")
    if isinstance(results, list):
        for result in results:
            if not isinstance(result, dict):
                continue
            nested = result.get("findings")
            if isinstance(nested, list) and nested:
                for key in ("skill_directory", "skill_name"):
                    value = result.get(key)
                    if isinstance(value, str) and value:
                        paths.add(value)
                        break
            collect(result, totals, paths, count_findings)


def outcome_of(args):
    if args.outcome:
        return args.outcome
    if args.exit_code == 0:
        return "pass"
    return "fail"


def why_of(args, errors, totals):
    if args.why:
        return args.why
    if errors:
        return "the scanner output could not be parsed"
    if args.exit_code not in (None, 0):
        return f"scanner exit {args.exit_code}"
    if totals and any(totals.values()):
        return "findings were reported below the failure threshold"
    return "the scanner reported no findings"


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--tool", required=True)
    parser.add_argument("--scope", default="")
    parser.add_argument("--exit", dest="exit_code", type=int)
    parser.add_argument("--outcome", choices=("pass", "fail", "skip", "classification-failed"))
    parser.add_argument("--why", default="")
    parser.add_argument("--json", dest="json_paths", action="append", default=[])
    args = parser.parse_args()

    reports, errors = load_reports(args.json_paths)
    totals = {name: 0 for name in SEVERITIES}
    paths = set()
    structured = False
    for report in reports:
        before = dict(totals)
        collect(report, totals, paths)
        if totals != before or cisco_totals(report) is not None or (
            isinstance(report, dict) and isinstance(report.get("findings"), list)
        ):
            structured = True
    if errors:
        structured = False
        totals = None

    outcome = outcome_of(args)
    lines = [
        f"### {args.tool}",
        "",
        f"- Outcome: {outcome}",
        f"- Scope: {args.scope or 'not selected'}",
        f"- Why: {why_of(args, errors, totals if structured else None)}",
    ]
    if outcome == "skip":
        lines.append("- The scanner was not run.")
    elif outcome == "classification-failed":
        lines.append("- The path filter did not return a decision, so the scanner was not run.")
    elif errors:
        lines.append("- Severity totals: unavailable")
        lines.append("- The full output is in this step's log.")
        for error in errors:
            lines.append(f"- Parse error: {error}")
    elif structured and totals is not None:
        rendered = ", ".join(f"{name} {totals[name]}" for name in SEVERITIES)
        lines.append(f"- Severity totals: {rendered}")
        if paths:
            lines.append("- Affected skill paths:")
            for path in sorted(paths):
                lines.append(f"  - `{path}`")
        else:
            lines.append("- Affected skill paths: none")
        lines.append("- The full output is in this step's log.")
    else:
        lines.append("- Severity totals: the scanner output had no severity counts")
        lines.append("- The full output is in this step's log.")
    lines.append("")
    text = "\n".join(lines)
    sys.stdout.write(text)
    summary = os.environ.get("GITHUB_STEP_SUMMARY")
    if summary:
        with open(summary, "a", encoding="utf-8") as handle:
            handle.write(text)


if __name__ == "__main__":
    main()
