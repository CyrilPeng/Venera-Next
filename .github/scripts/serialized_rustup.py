#!/usr/bin/env python3
"""Serialize rustup mutations that can race during parallel plugin builds."""

import fcntl
import os
import subprocess
import sys
from pathlib import Path


def exec_rustup(real_rustup: str, invoked_as: str, args: list[str]) -> None:
    # rustc/cargo are rustup proxy links; preserve argv[0] for proxy dispatch.
    os.execve(real_rustup, [invoked_as, *args], os.environ.copy())


def main() -> int:
    real_rustup = os.environ.get("RUSTUP_REAL_BINARY")
    if not real_rustup:
        raise SystemExit("RUSTUP_REAL_BINARY is not set")

    invoked_as = Path(sys.argv[0]).name
    args = sys.argv[1:]
    if invoked_as != "rustup" or not args or args[0] not in {
        "component",
        "target",
        "toolchain",
    }:
        exec_rustup(real_rustup, invoked_as, args)
        return 0

    lock_path = Path(os.environ.get("RUSTUP_LOCK_FILE", "/tmp/venera-rustup.lock"))
    lock_path.parent.mkdir(parents=True, exist_ok=True)
    with lock_path.open("w") as lock:
        fcntl.flock(lock.fileno(), fcntl.LOCK_EX)
        return subprocess.run(
            ["rustup", *args],
            executable=real_rustup,
            check=False,
        ).returncode


if __name__ == "__main__":
    sys.exit(main())
