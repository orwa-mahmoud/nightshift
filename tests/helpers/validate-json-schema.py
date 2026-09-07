#!/usr/bin/env python3
"""Validate one JSON document against a local Draft-07 subset schema.

Supports type, properties, additionalProperties, required, enum, items, minItems,
minimum, maximum, minLength, maxLength, pattern, and patternProperties. Enough to
test Nightshift's rules and eval schemas without an extra package. Exit 0 on
success, 1 on validation or usage failure.
"""
from __future__ import print_function

import json
import re
import sys


def fail(path, msg):
    print("%s: %s" % (path or "$", msg), file=sys.stderr)
    return False


def check_type(instance, expected, path):
    mapping = {
        dict: "object",
        list: "array",
        str: "string",
        bool: "boolean",
        type(None): "null",
    }
    if isinstance(instance, bool):
        got = "boolean"
    elif isinstance(instance, int) and not isinstance(instance, bool):
        got = "integer"
    elif isinstance(instance, float):
        got = "number"
    else:
        got = mapping.get(type(instance), type(instance).__name__)
    types = expected if isinstance(expected, list) else [expected]
    if "number" in types and got == "integer":
        return True
    if got in types:
        return True
    return fail(path, "expected %s, got %s" % ("|".join(types), got))


def validate(instance, schema, path="$"):
    ok = True
    expected = schema.get("type")
    if expected is not None:
        ok = check_type(instance, expected, path) and ok
        if not ok:
            return False
    if "enum" in schema:
        if instance not in schema["enum"]:
            ok = fail(path, "not in enum")
    # A keyword applies to its own type and says nothing about any other, so a nullable field
    # carrying a bound validates when it is unset. `type` is what rejects a wrong type.
    numeric = not isinstance(instance, bool) and isinstance(instance, (int, float))
    if "minimum" in schema and numeric:
        if instance < schema["minimum"]:
            ok = fail(path, "below minimum %s" % schema["minimum"])
    if "maximum" in schema and numeric:
        if instance > schema["maximum"]:
            ok = fail(path, "above maximum %s" % schema["maximum"])
    if "minLength" in schema and isinstance(instance, str):
        if len(instance) < schema["minLength"]:
            ok = fail(path, "shorter than minLength %s" % schema["minLength"])
    if "maxLength" in schema and isinstance(instance, str):
        if len(instance) > schema["maxLength"]:
            ok = fail(path, "longer than maxLength %s" % schema["maxLength"])
    if "pattern" in schema and isinstance(instance, str):
        if re.search(schema["pattern"], instance) is None:
            ok = fail(path, "does not match %s" % schema["pattern"])
    if isinstance(instance, list):
        if "minItems" in schema and len(instance) < schema["minItems"]:
            ok = fail(path, "fewer than minItems %s" % schema["minItems"])
        item_schema = schema.get("items")
        if isinstance(item_schema, dict):
            for i, value in enumerate(instance):
                ok = validate(value, item_schema, "%s[%s]" % (path, i)) and ok
    if isinstance(instance, dict):
        required = schema.get("required") or []
        for key in required:
            if key not in instance:
                ok = fail(path, "missing required property %s" % key)
        props = schema.get("properties") or {}
        patterns = schema.get("patternProperties") or {}
        additional = schema.get("additionalProperties", True)
        for key, value in instance.items():
            child = "%s.%s" % (path, key)
            if key in props:
                ok = validate(value, props[key], child) and ok
                continue
            matched = False
            for pat, sub in patterns.items():
                if re.search(pat, key):
                    ok = validate(value, sub, child) and ok
                    matched = True
                    break
            if matched:
                continue
            if additional is False:
                ok = fail(child, "additional property not allowed")
            elif isinstance(additional, dict):
                ok = validate(value, additional, child) and ok
    return ok


def main(argv):
    if len(argv) != 3:
        print("usage: validate-json-schema.py SCHEMA DOCUMENT", file=sys.stderr)
        return 1
    with open(argv[1]) as fh:
        schema = json.load(fh)
    with open(argv[2]) as fh:
        document = json.load(fh)
    return 0 if validate(document, schema) else 1


if __name__ == "__main__":
    sys.exit(main(sys.argv))
