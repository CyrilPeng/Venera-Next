import platform
import subprocess
import os
import shutil
import hashlib
from urllib.request import Request, urlopen

file = open('pubspec.yaml', 'r')
content = file.read()
file.close()

subprocess.run(["flutter", "build", "windows", "--target-platform", "windows-arm64"], shell=True)

if os.path.exists("build/app-windows.zip"):
    os.remove("build/app-windows.zip")

version = str.split(str.split(content, 'version: ')[1], '+')[0]

release_dir = "build/windows/arm64/runner/Release"
package_name = f"VeneraNext-{version}-windows-arm64"
package_dir = f"build/windows/{package_name}"
zip_path = f"build/windows/{package_name}.zip"

if os.path.exists(zip_path):
    os.remove(zip_path)
if os.path.exists(package_dir):
    shutil.rmtree(package_dir)

shutil.copytree(release_dir, package_dir)
subprocess.run(["tar", "-a", "-c", "-f", zip_path, "-C", "build/windows", package_name], shell=True)
shutil.rmtree(package_dir)

issPath = "windows/build_arm64.iss"

issContent = ""
file = open(issPath, 'r')
issContent = file.read()
newContent = issContent
newContent = newContent.replace("{{version}}", version)
newContent = newContent.replace("{{root_path}}", os.getcwd())
file.close()
file = open(issPath, 'w')
file.write(newContent)
file.close()

if not os.path.exists("windows/ChineseSimplified.isl"):
    # download ChineseSimplified.isl
    url = (
        "https://cdn.jsdelivr.net/gh/kira-96/"
        "Inno-Setup-Chinese-Simplified-Translation@"
        "1ace6a485174288c7416d0979cc2db1f0990f95a/ChineseSimplified.isl"
    )
    request = Request(url, headers={"User-Agent": "VeneraNext-Windows-Build"})
    with urlopen(request, timeout=30) as response:
        content = response.read()
    if not content:
        raise RuntimeError("Downloaded ChineseSimplified.isl is empty")
    digest = hashlib.sha256(content).hexdigest()
    expected = "bc76580176cba3303fb4b0edfd4c65557cc57dad09d1efc3f8d16557c0f2d694"
    if digest != expected:
        raise RuntimeError(
            "Downloaded ChineseSimplified.isl failed SHA256 verification: "
            f"{digest}"
        )
    with open('windows/ChineseSimplified.isl', 'wb') as file:
        file.write(content)

subprocess.run(["iscc", issPath], shell=True)

with open(issPath, 'w') as file:
    file.write(issContent)
