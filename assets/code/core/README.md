# antcrate-core

C++ helper binary for AntCrate. Part of a staged Bash → C++ hybrid migration
that preserves the existing Bash CLI surface while moving wrapper guards,
registry I/O, deep traversal, and gap-fill guards to a typed C++17 binary.
The full migration plan lives at `~/.claude/plans/sunny-strolling-book.md`.

**Wave 0 (current):** scaffold only. The binary builds and parses `--version`
and `--help`; no Bash logic has been ported yet. All 316 bats tests continue to
pass unchanged; the C++ build is an additive step in `antcrate --ci` and CI.

## Build

```sh
cmake -B build -S . && cmake --build build && ctest --test-dir build
```

Requires: cmake ≥ 3.20, g++ 13+ or clang++ with C++17 support, ninja (optional).

## Run

```sh
./build/antcrate-core --version   # antcrate-core 0.0.0-stub
./build/antcrate-core --help
```

## Test

```sh
ctest --test-dir build --output-on-failure
```

Tests use the [doctest](https://github.com/doctest/doctest) single-header
framework (vendored at `tests/doctest/doctest.h`, v2.4.11).
