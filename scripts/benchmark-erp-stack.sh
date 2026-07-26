#!/usr/bin/env bash
set -Eeuo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"

if command -v python3 >/dev/null 2>&1; then
  python_bin=python3
elif command -v python >/dev/null 2>&1; then
  python_bin=python
else
  printf '[HATA] ERP benchmark icin Python 3.10+ gerekli\n' >&2
  exit 1
fi

exec "$python_bin" "${script_dir}/erp_stack_benchmark.py" "$@"
