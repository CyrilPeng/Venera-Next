import os
import re
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[3]
WORKFLOW = ROOT / ".github/workflows/build.yml"
WRAPPER = ROOT / ".github/scripts/serialized_rustup.py"


def wrapper_steps():
    text = WORKFLOW.read_text(encoding="utf-8")
    steps = re.findall(
        r"^      - name: 串行化 Rustup 安装操作\n"
        r"        run: \|\n(?P<body>(?:          [^\n]*\n)+)",
        text,
        re.MULTILINE,
    )
    return ["\n".join(line[10:] for line in body.splitlines()) for body in steps]


class AppleRustupWrapperTests(unittest.TestCase):
    def test_each_apple_job_creates_destination_before_installing(self):
        steps = wrapper_steps()
        self.assertEqual(len(steps), 2)
        for script in steps:
            with self.subTest(script=script):
                mkdir = 'mkdir -p "$HOME/.cargo/bin"'
                install = 'install .github/scripts/serialized_rustup.py "$HOME/.cargo/bin/rustup"'
                self.assertIn(mkdir, script)
                self.assertLess(script.index(mkdir), script.index(install))
                self.assertLess(
                    script.index('install "$(command -v rustup)" "$RUNNER_TEMP/rustup"'),
                    script.index('rm -f "$HOME/.cargo/bin/rustup"'),
                )

    def test_each_apple_job_prepends_wrapper_to_shell_path(self):
        steps = wrapper_steps()
        self.assertEqual(len(steps), 2)
        for script in steps:
            self.assertIn('echo "$HOME/.cargo/bin" >> "$GITHUB_PATH"', script)

    @unittest.skipUnless(os.name == "posix" and shutil.which("bash"), "requires POSIX install")
    def test_homebrew_layout_without_cargo_bin_is_supported(self):
        for script in wrapper_steps():
            with self.subTest(script=script):
                self.run_install(script, homebrew=True)

    @unittest.skipUnless(os.name == "posix" and shutil.which("bash"), "requires POSIX hard links")
    def test_existing_cargo_and_rustc_proxy_links_are_preserved(self):
        for script in wrapper_steps():
            with self.subTest(script=script):
                self.run_install(script, homebrew=False)

    def run_install(self, script, *, homebrew):
        with tempfile.TemporaryDirectory(prefix="apple rustup ") as directory:
            root = Path(directory)
            home = root / "home"
            home.mkdir()
            runner_temp = root / "runner temp"
            runner_temp.mkdir()
            cargo_bin = home / ".cargo/bin"
            source_bin = root / "homebrew/bin" if homebrew else cargo_bin
            source_bin.mkdir(parents=True)
            source = source_bin / "rustup"
            original = b"original-rustup-binary\n"
            source.write_bytes(original)
            source.chmod(0o755)
            if not homebrew:
                for proxy in ("cargo", "rustc"):
                    os.link(source, cargo_bin / proxy)
            env_file = root / "github env"
            path_file = root / "github path"
            env = dict(
                os.environ,
                HOME=str(home),
                RUNNER_TEMP=str(runner_temp),
                GITHUB_ENV=str(env_file),
                GITHUB_PATH=str(path_file),
                PATH=str(source_bin) + os.pathsep + os.environ["PATH"],
            )
            result = subprocess.run(
                ["bash", "-e", "-c", script],
                cwd=ROOT,
                env=env,
                capture_output=True,
                text=True,
                timeout=20,
            )
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual((runner_temp / "rustup").read_bytes(), original)
            self.assertEqual((cargo_bin / "rustup").read_bytes(), WRAPPER.read_bytes())
            self.assertTrue(os.access(cargo_bin / "rustup", os.X_OK))
            self.assertEqual(path_file.read_text().splitlines(), [str(cargo_bin)])
            self.assertEqual(
                env_file.read_text().splitlines(),
                [
                    f"RUSTUP_REAL_BINARY={runner_temp / 'rustup'}",
                    f"RUSTUP_LOCK_FILE={runner_temp / 'venera-rustup.lock'}",
                ],
            )
            if homebrew:
                self.assertEqual(source.read_bytes(), original)
            else:
                for proxy in ("cargo", "rustc"):
                    self.assertEqual((cargo_bin / proxy).read_bytes(), original)


if __name__ == "__main__":
    unittest.main()
