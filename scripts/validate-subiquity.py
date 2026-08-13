#!/usr/bin/env python3
import json
import pathlib
import sys

import jsonschema
import yaml


def main() -> int:
    if len(sys.argv) != 3:
        print("Usage: validate-subiquity.py SCHEMA USER_DATA", file=sys.stderr)
        return 2
    schema_path = pathlib.Path(sys.argv[1])
    user_data_path = pathlib.Path(sys.argv[2])
    schema = json.loads(schema_path.read_text(encoding="utf-8"))
    user_data = yaml.safe_load(user_data_path.read_text(encoding="utf-8"))
    if not isinstance(user_data, dict) or not isinstance(user_data.get("autoinstall"), dict):
        raise ValueError("user-data must contain an autoinstall mapping")
    jsonschema.Draft7Validator(schema).validate(user_data["autoinstall"])
    print(f"Validated {user_data_path} against {schema_path}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
