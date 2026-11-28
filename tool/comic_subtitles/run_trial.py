"""Collect reports from CI builds of the reader trial on disposable hosts."""

import argparse
import base64
import io
import json
import os
import subprocess
import sys
import time
import zipfile
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
OUTPUT = ROOT / 'build/subtitle-trial'
PACKAGE = 'com.github.cyrilpeng.veneranext'


def command(*args):
    return subprocess.check_output(args, encoding='utf-8', errors='replace', timeout=45).strip()


def prepare():
    sys.path.insert(0, str(ROOT / 'spec/comic-subtitles'))
    from check_examples import portable_files, read_examples
    buffer = io.BytesIO()
    with zipfile.ZipFile(buffer, 'w') as archive:
        for name, content in sorted(portable_files(*read_examples()).items()):
            archive.writestr(zipfile.ZipInfo(name), content)
    sample = json.dumps(base64.b64encode(buffer.getvalue()).decode('ascii'))
    revision = json.dumps(command('git', 'rev-parse', 'HEAD'))
    (OUTPUT / 'main.dart').write_text(
        "import '../../tool/comic_subtitles/device_trial.dart' as trial;\n"
        f"Future<void> main() => trial.runTrial({sample}, {revision});\n", encoding='utf-8')


def android(serial):
    def adb(*args):
        return command('adb', '-s', serial, *args)

    if adb('shell', 'getprop', 'ro.kernel.qemu') != '1' and adb('shell', 'getprop', 'ro.boot.qemu') != '1':
        raise ValueError('Select a disposable emulator for this automatic airplane-mode trial')
    adb('install', str(OUTPUT / 'trial.apk'))
    adb('shell', 'cmd', 'connectivity', 'airplane-mode', 'enable')
    adb('shell', 'svc', 'wifi', 'disable')
    adb('shell', 'svc', 'data', 'disable')
    if adb('shell', 'settings', 'get', 'global', 'airplane_mode_on') != '1':
        raise RuntimeError('Airplane mode did not engage')
    (OUTPUT / 'device.txt').write_text('\n'.join([
        adb('shell', 'getprop', 'ro.build.fingerprint'), adb('shell', 'wm', 'size'),
        adb('shell', 'cat', '/proc/meminfo').splitlines()[0], 'airplane_mode_on=1']), encoding='utf-8')
    adb('logcat', '-c')
    adb('shell', 'am', 'start', '-W', '-n', PACKAGE + '/.MainActivity')
    limit = time.monotonic() + 180
    while time.monotonic() < limit:
        log = adb('logcat', '-d', '-s', 'flutter:I', 'AndroidRuntime:E')
        (OUTPUT / 'trial.log').write_text(log, encoding='utf-8')
        for line in log.splitlines():
            if 'SUBTITLE_TRIAL_RESULT ' in line:
                return json.loads(line.split('SUBTITLE_TRIAL_RESULT ', 1)[1])
        time.sleep(3)
    raise TimeoutError('No reader report after 180 seconds')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('action', choices=['prepare', 'select-apk', 'windows', 'android'])
    parser.add_argument('--serial', default='emulator-5554')
    args = parser.parse_args()
    OUTPUT.mkdir(exist_ok=True, parents=True)
    if args.action == 'prepare':
        return prepare()
    if args.action == 'select-apk':
        import shutil
        candidates = sorted((ROOT / 'build/app/outputs/apk/mobile/release').rglob('*.apk'), key=lambda path: path.stat().st_size)
        for path in candidates:
            with zipfile.ZipFile(path) as archive:
                if 'lib/x86_64/libapp.so' in archive.namelist():
                    shutil.copyfile(path, OUTPUT / 'trial.apk')
                    return
        raise ValueError('No x86_64 reader APK')
    path = OUTPUT / 'report.json'
    if args.action == 'android':
        report = android(args.serial)
        path.write_text(json.dumps(report, indent=2), encoding='utf-8')
    else:
        exe = ROOT / 'build/windows/x64/runner/Release/VeneraNext.exe'
        with (OUTPUT / 'trial.log').open('w', encoding='utf-8') as log:
            subprocess.run([exe], cwd=exe.parent, env={**os.environ, 'SUBTITLE_TRIAL_OUTPUT': str(path)},
                           stdout=log, stderr=subprocess.STDOUT, timeout=180, check=True)
        report = json.loads(path.read_bytes())
    if report.get('revision') != command('git', 'rev-parse', 'HEAD') or not report.get('passed'):
        raise RuntimeError(report)
    print(json.dumps(report, indent=2))


if __name__ == '__main__':
    main()
