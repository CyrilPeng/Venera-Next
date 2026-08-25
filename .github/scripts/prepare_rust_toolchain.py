import argparse
import subprocess


def prepare_toolchain(version: str, targets: list[str]) -> None:
    subprocess.run(
        ["rustup", "toolchain", "uninstall", version],
        check=False,
    )

    command = [
        "rustup",
        "toolchain",
        "install",
        version,
        "--profile",
        "minimal",
        "--component",
        "cargo",
    ]
    for target in targets:
        command.extend(["--target", target])
    subprocess.run(command, check=True)
    subprocess.run(
        ["rustup", "run", version, "cargo", "--version"],
        check=True,
    )


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--version", default="1.85.1")
    parser.add_argument("--target", action="append", default=[])
    args = parser.parse_args()
    prepare_toolchain(args.version, args.target)


if __name__ == "__main__":
    main()
