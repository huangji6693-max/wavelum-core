#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage: scripts/sync-interfaces.sh [--check] [--strict] [--print-generated] [--install-pre-commit]

Validates that Solidity interfaces do not drift away from Soroban #[contractimpl]
entrypoints. By default the script checks interface function names, parameter
counts, and compatible primitive parameter types.

Options:
  --check               Validate interfaces. This is the default.
  --strict              Also fail when Rust entrypoints are missing from Solidity.
  --print-generated     Print a generated Solidity skeleton from Rust signatures.
  --install-pre-commit  Install a local .git/hooks/pre-commit validator.
  -h, --help            Show this help.
USAGE
}

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

CHECK=1
STRICT=0
PRINT_GENERATED=0

while [ "$#" -gt 0 ]; do
  case "$1" in
    --check)
      CHECK=1
      ;;
    --strict)
      STRICT=1
      ;;
    --print-generated)
      PRINT_GENERATED=1
      ;;
    --install-pre-commit)
      if [ ! -d "${REPO_ROOT}/.git" ]; then
        echo "Cannot install pre-commit hook: ${REPO_ROOT}/.git was not found." >&2
        exit 1
      fi
      mkdir -p "${REPO_ROOT}/.git/hooks"
      cat > "${REPO_ROOT}/.git/hooks/pre-commit" <<'HOOK'
#!/usr/bin/env bash
set -euo pipefail

scripts/sync-interfaces.sh --check
HOOK
      chmod +x "${REPO_ROOT}/.git/hooks/pre-commit"
      echo "Installed .git/hooks/pre-commit interface sync validator."
      exit 0
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown option: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
  shift
done

if command -v python3 >/dev/null 2>&1; then
  PYTHON_BIN=python3
elif command -v python >/dev/null 2>&1; then
  PYTHON_BIN=python
else
  echo "python3 or python is required for interface synchronization." >&2
  exit 127
fi

export REPO_ROOT CHECK STRICT PRINT_GENERATED

exec "${PYTHON_BIN}" - <<'PY'
import dataclasses
import os
import re
import sys
from pathlib import Path

ROOT = Path(os.environ["REPO_ROOT"])
CHECK = os.environ.get("CHECK") == "1"
STRICT = os.environ.get("STRICT") == "1"
PRINT_GENERATED = os.environ.get("PRINT_GENERATED") == "1"

MAPPINGS = [
    {
        "name": "VestingVault",
        "rust": ROOT / "contracts" / "vesting_vault" / "src" / "lib.rs",
        "solidity": ROOT / "contracts" / "interfaces" / "IVestingVault.sol",
        "evm_impl": ROOT / "contracts" / "src" / "VestingVault" / "VestingVault.sol",
    },
    {
        "name": "SanctionsOracle",
        "rust": None,
        "solidity": ROOT / "contracts" / "interfaces" / "ISanctionsOracle.sol",
        "evm_impl": ROOT / "contracts" / "src" / "VestingVault" / "SanctionsOracle.sol",
    },
    {
        "name": "RevenueOracle",
        "rust": None,
        "solidity": ROOT / "contracts" / "interfaces" / "IRevenueOracle.sol",
        "evm_impl": ROOT / "contracts" / "src" / "VestingVault" / "RevenueOracle.sol",
    },
]


@dataclasses.dataclass(frozen=True)
class RustFunction:
    name: str
    params: list[tuple[str, str]]
    result: str | None


@dataclasses.dataclass(frozen=True)
class SolidityFunction:
    name: str
    params: list[str]
    sync_allowed: bool
    sync_reason: str | None


def strip_comments(text: str) -> str:
    text = re.sub(r"/\*.*?\*/", "", text, flags=re.S)
    text = re.sub(r"//.*", "", text)
    return text


def split_top_level(value: str) -> list[str]:
    parts: list[str] = []
    current: list[str] = []
    depth = 0
    for char in value:
        if char in "(<[":
            depth += 1
        elif char in ")>]":
            depth -= 1
        if char == "," and depth == 0:
            part = "".join(current).strip()
            if part:
                parts.append(part)
            current = []
            continue
        current.append(char)
    part = "".join(current).strip()
    if part:
        parts.append(part)
    return parts


def snake_to_camel(name: str) -> str:
    head, *tail = name.split("_")
    return head + "".join(part[:1].upper() + part[1:] for part in tail)


def camel_to_snake(name: str) -> str:
    value = re.sub(r"(.)([A-Z][a-z]+)", r"\1_\2", name)
    value = re.sub(r"([a-z0-9])([A-Z])", r"\1_\2", value)
    return value.lower()


def normalize_rust_type(value: str) -> str:
    value = value.strip()
    value = value.replace("&", "")
    value = re.sub(r"\s+", "", value)
    return value


def normalize_solidity_type(value: str) -> str:
    value = re.sub(r"\b(calldata|memory|storage|payable)\b", "", value)
    value = re.sub(r"\s+", " ", value).strip()
    if not value:
        return value
    tokens = value.split()
    if len(tokens) > 1:
        value = " ".join(tokens[:-1])
    return re.sub(r"\s+", "", value)


def rust_to_solidity_type(value: str) -> str | None:
    value = normalize_rust_type(value)
    vector = re.fullmatch(r"Vec<(.+)>", value)
    if vector:
        inner = rust_to_solidity_type(vector.group(1))
        return f"{inner}[]" if inner else None
    option = re.fullmatch(r"Option<(.+)>", value)
    if option:
        return rust_to_solidity_type(option.group(1))
    bytes_n = re.fullmatch(r"BytesN<(\d+)>", value)
    if bytes_n:
        size = bytes_n.group(1)
        return f"bytes{size}" if int(size) <= 32 else "bytes"
    mapping = {
        "Address": "address",
        "u32": "uint32",
        "u64": "uint64",
        "i128": "int128",
        "bool": "bool",
        "String": "string",
        "()": None,
    }
    return mapping.get(value, value)


def types_compatible(rust_type: str, solidity_type: str) -> bool:
    expected = rust_to_solidity_type(rust_type)
    actual = normalize_solidity_type(solidity_type)
    if expected is None:
        return actual == ""
    if expected == actual:
        return True
    if expected.startswith("uint") and actual == "uint256":
        return True
    if expected.startswith("int") and actual == "int256":
        return True
    return False


def parse_rust_functions(path: Path) -> list[RustFunction]:
    text = path.read_text(encoding="utf-8")
    text = strip_comments(text)
    matches = re.finditer(
        r"pub\s+fn\s+([A-Za-z_][A-Za-z0-9_]*)\s*\((.*?)\)\s*(?:->\s*([^{]+?))?\s*\{",
        text,
        flags=re.S,
    )
    functions: list[RustFunction] = []
    for match in matches:
        name = match.group(1)
        raw_params = split_top_level(match.group(2))
        params: list[tuple[str, str]] = []
        for raw_param in raw_params:
            if ":" not in raw_param:
                continue
            param_name, param_type = [part.strip() for part in raw_param.split(":", 1)]
            if normalize_rust_type(param_type) == "Env":
                continue
            params.append((param_name.lstrip("_"), param_type))
        result = match.group(3).strip() if match.group(3) else None
        functions.append(RustFunction(name=name, params=params, result=result))
    return functions


def parse_solidity_functions(path: Path) -> list[SolidityFunction]:
    text = path.read_text(encoding="utf-8")
    matches = re.finditer(
        r"(?P<prefix>(?:\s*(?://[^\n]*|/\*.*?\*/))*\s*)function\s+"
        r"(?P<name>[A-Za-z_][A-Za-z0-9_]*)\s*\((?P<params>.*?)\)",
        text,
        flags=re.S,
    )
    functions: list[SolidityFunction] = []
    for match in matches:
        raw_prefix = match.group("prefix")
        raw_params = split_top_level(strip_comments(match.group("params")))
        params = [normalize_solidity_type(param) for param in raw_params if param.strip()]
        allow_match = re.search(r"@custom:sync-allow\s+([^\n*]+)", raw_prefix)
        sync_allowed = allow_match is not None or "sync-interface: ignore" in raw_prefix
        sync_reason = allow_match.group(1).strip() if allow_match else None
        functions.append(
            SolidityFunction(
                name=match.group("name"),
                params=params,
                sync_allowed=sync_allowed,
                sync_reason=sync_reason,
            )
        )
    return functions


def generated_skeleton(contract_name: str, functions: list[RustFunction]) -> str:
    lines = [
        "// Generated skeleton. Review complex Soroban types before committing.",
        f"interface I{contract_name} {{",
    ]
    for func in functions:
        params: list[str] = []
        skipped = False
        for param_name, rust_type in func.params:
            sol_type = rust_to_solidity_type(rust_type)
            if not sol_type:
                skipped = True
                break
            location = " calldata" if sol_type in {"string"} or sol_type.endswith("[]") else ""
            params.append(f"{sol_type}{location} {param_name or 'value'}")
        if skipped:
            continue
        lines.append(f"    function {snake_to_camel(func.name)}({', '.join(params)}) external;")
    lines.append("}")
    return "\n".join(lines)


def validate_mapping(mapping: dict[str, object]) -> tuple[list[str], list[str]]:
    rust_path = mapping["rust"]
    solidity_path = mapping["solidity"]
    evm_impl_path = mapping.get("evm_impl")
    contract_name = mapping["name"]
    assert rust_path is None or isinstance(rust_path, Path)
    assert isinstance(solidity_path, Path)
    assert evm_impl_path is None or isinstance(evm_impl_path, Path)
    assert isinstance(contract_name, str)

    if not solidity_path.exists():
        return [f"{solidity_path.relative_to(ROOT)} is missing"], []

    solidity_functions = parse_solidity_functions(solidity_path)
    errors: list[str] = []
    warnings: list[str] = []

    if evm_impl_path is not None:
        if not evm_impl_path.exists():
            return [f"{evm_impl_path.relative_to(ROOT)} is missing"], []
        impl_functions = {fn.name: fn for fn in parse_solidity_functions(evm_impl_path)}
        for solidity in solidity_functions:
            impl = impl_functions.get(solidity.name)
            if impl is None:
                errors.append(
                    f"{solidity_path.relative_to(ROOT)}: function {solidity.name} is missing in {evm_impl_path.relative_to(ROOT)}"
                )
            elif len(impl.params) != len(solidity.params):
                errors.append(
                    f"{solidity_path.relative_to(ROOT)}: function {solidity.name} has {len(solidity.params)} params, "
                    f"but {evm_impl_path.relative_to(ROOT)} has {len(impl.params)}"
                )

    if rust_path is None:
        return errors, warnings

    if not rust_path.exists():
        return [f"{rust_path.relative_to(ROOT)} is missing"], []

    rust_functions = parse_rust_functions(rust_path)
    rust_by_name = {func.name: func for func in rust_functions}
    rust_by_solidity_name = {snake_to_camel(func.name): func for func in rust_functions}

    def report(solidity: SolidityFunction, message: str) -> None:
        if solidity.sync_allowed and not STRICT:
            reason = f" ({solidity.sync_reason})" if solidity.sync_reason else ""
            warnings.append(f"{message}; allowed by @custom:sync-allow{reason}")
        else:
            errors.append(message)

    for solidity in solidity_functions:
        rust = rust_by_solidity_name.get(solidity.name) or rust_by_name.get(solidity.name) or rust_by_name.get(camel_to_snake(solidity.name))
        if rust is None:
            report(
                solidity,
                f"{solidity_path.relative_to(ROOT)}: function {solidity.name} has no matching Rust entrypoint",
            )
            continue
        if len(solidity.params) != len(rust.params):
            report(
                solidity,
                f"{solidity_path.relative_to(ROOT)}: function {solidity.name} has {len(solidity.params)} params, "
                f"but Rust {rust.name} has {len(rust.params)}",
            )
            continue
        for index, ((_, rust_type), solidity_type) in enumerate(zip(rust.params, solidity.params), start=1):
            if not types_compatible(rust_type, solidity_type):
                report(
                    solidity,
                    f"{solidity_path.relative_to(ROOT)}: function {solidity.name} param {index} is {solidity_type}, "
                    f"but Rust {rust.name} uses {normalize_rust_type(rust_type)}",
                )

    missing_from_solidity = [
        snake_to_camel(func.name)
        for func in rust_functions
        if snake_to_camel(func.name) not in {fn.name for fn in solidity_functions}
    ]
    if missing_from_solidity:
        message = (
            f"{solidity_path.relative_to(ROOT)} omits {len(missing_from_solidity)} Rust entrypoints: "
            + ", ".join(missing_from_solidity[:12])
            + (" ..." if len(missing_from_solidity) > 12 else "")
        )
        if STRICT:
            errors.append(message)
        else:
            warnings.append(message)

    if PRINT_GENERATED:
        print(generated_skeleton(contract_name, rust_functions))

    return errors, warnings


all_errors: list[str] = []
all_warnings: list[str] = []
for item in MAPPINGS:
    errors, warnings = validate_mapping(item)
    all_errors.extend(errors)
    all_warnings.extend(warnings)

for warning in all_warnings:
    print(f"warning: {warning}", file=sys.stderr)

if all_errors:
    print("Interface synchronization check failed:", file=sys.stderr)
    for error in all_errors:
        print(f"  - {error}", file=sys.stderr)
    sys.exit(1)

if CHECK:
    print("Interface synchronization check passed.")
PY
