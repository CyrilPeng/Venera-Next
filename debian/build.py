import subprocess
import sys
from pathlib import Path

arch = sys.argv[1]
debianContent = ''
desktopContent = ''
version = ''

with open('debian/debian.yaml', 'r') as f:
    debianContent = f.read()
with open('debian/gui/venera-next.desktop', 'r') as f:
    desktopContent = f.read()
with open('pubspec.yaml', 'r') as f:
    version = str.split(str.split(f.read(), 'version: ')[1], '+')[0]

try:
    with open('debian/debian.yaml', 'w') as f:
        content = debianContent.replace('{{Version}}', version)
        if arch == 'x64':
            content = content.replace('{{Arch}}', 'x64')
            content = content.replace('{{Architecture}}', 'amd64')
        elif arch == 'arm64':
            content = content.replace('{{Arch}}', 'arm64')
            content = content.replace('{{Architecture}}', 'arm64')
        f.write(content)
    with open('debian/gui/venera-next.desktop', 'w') as f:
        f.write(desktopContent.replace('{{Version}}', version))

    subprocess.run(["flutter", "build", "linux"], check=True)
    subprocess.run(
        [str(Path.home() / '.pub-cache' / 'bin' / 'flutter_to_debian')],
        check=True,
    )
finally:
    with open('debian/debian.yaml', 'w') as f:
        f.write(debianContent)
    with open('debian/gui/venera-next.desktop', 'w') as f:
        f.write(desktopContent)
