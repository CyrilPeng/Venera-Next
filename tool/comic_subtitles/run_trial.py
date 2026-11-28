"""Collect reports from CI builds of the reader trial on disposable hosts."""

import argparse
import base64
import json
import os
import subprocess
import time
import zipfile
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
OUTPUT = ROOT / 'build/subtitle-trial'
PACKAGE = 'com.github.cyrilpeng.veneranext'
SAMPLE = ROOT / 'spec/comic-subtitles/fixtures/mountain-path-0.1.cbz'


def command(*args):
    return subprocess.check_output(args, encoding='utf-8', errors='replace', timeout=45).strip()


def prepare():
    sample = json.dumps(base64.b64encode(SAMPLE.read_bytes()).decode('ascii'))
    revision = json.dumps(command('git', 'rev-parse', 'HEAD'))
    (OUTPUT / 'main.dart').write_text(
        "import '../../tool/comic_subtitles/device_trial.dart' as trial;\n"
        f"Future<void> main() => trial.runTrial({sample}, {revision});\n", encoding='utf-8')


def android_report(log):
    parts = []
    for line in log.splitlines():
        record = line.partition('SUBTITLE_TRIAL_')[2]
        if record.startswith('PART '):
            _, number, data = record.split()
            if int(number) != len(parts):
                raise ValueError('Android trial report has missing or repeated parts')
            parts.append(data)
        elif record.startswith('END '):
            if not parts or int(record.split()[1]) != len(parts):
                raise ValueError('Incomplete Android trial report')
            return json.loads(base64.b64decode(''.join(parts), validate=True))
    return None


def android(serial, memory_mib):
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
    memory = adb('shell', 'cat', '/proc/meminfo').splitlines()[0]
    (OUTPUT / 'device.txt').write_text('\n'.join([
        adb('shell', 'getprop', 'ro.build.fingerprint'), adb('shell', 'wm', 'size'),
        memory, 'airplane_mode_on=1']), encoding='utf-8')
    total_kib = int(memory.split()[1])
    if total_kib > memory_mib * 1024:
        raise RuntimeError(f'Guest MemTotal {total_kib} KiB exceeds the requested {memory_mib} MiB')
    adb('logcat', '-c')
    adb('shell', 'am', 'start', '-W', '-n', PACKAGE + '/.MainActivity')
    limit = time.monotonic() + 180
    while time.monotonic() < limit:
        log = adb('logcat', '-d', '-s', 'flutter:I', 'AndroidRuntime:E')
        (OUTPUT / 'trial.log').write_text(log, encoding='utf-8')
        report = android_report(log)
        if report is not None:
            report.update(memoryMiB=memory_mib, guestMemTotalKiB=total_kib, airplaneMode=True)
            return report
        time.sleep(3)
    raise TimeoutError('No reader report after 180 seconds')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('action', choices=['prepare', 'select-apk', 'windows', 'android'])
    parser.add_argument('--serial', default='emulator-5554')
    parser.add_argument('--memory-mib', type=int, help='RAM configured on the disposable emulator')
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
        if not args.memory_mib or args.memory_mib < 1:
            parser.error('android requires --memory-mib')
        report = android(args.serial, args.memory_mib)
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
