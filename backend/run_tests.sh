#!/usr/bin/env bash
# Runs backend tests using the project's virtual environment.

cd -- "$(dirname -- "${BASH_SOURCE[0]}")" || exit 1
exec .venv/bin/python -m pytest tests -q -p no:cacheprovider "$@"
