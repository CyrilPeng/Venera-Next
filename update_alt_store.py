import json
import re
import requests
import os
from datetime import datetime

def prepare_description(text):
    text = re.sub('<[^<]+?>', '', text) # Remove HTML tags
    text = re.sub(r'#{1,6}\s?', '', text) # Remove markdown header tags
    text = re.sub(r'\*{2}', '', text) # Remove all occurrences of two consecutive asterisks
    text = re.sub(r'(?<=\r|\n)-', '•', text) # Only replace - with • if it is preceded by \r or \n
    text = re.sub(r'`', '"', text) # Replace ` with "
    text = re.sub(r'\r\n\r\n', '\r \n', text) # Replace \r\n\r\n with \r \n (avoid incorrect display of the description regarding paragraphs)
    return text

def fetch_latest_release(repo_url):
    api_url = f"https://api.github.com/repos/{repo_url}/releases"
    headers = {
        "Accept": "application/vnd.github+json",
        "X-GitHub-Api-Version": "2022-11-28",
    }
    token = os.environ.get("GITHUB_TOKEN") or os.environ.get("GH_TOKEN")
    if token:
        headers["Authorization"] = f"Bearer {token}"
    try:
        response = requests.get(api_url, headers=headers, timeout=30)
        response.raise_for_status()
        releases = response.json()
        for release in releases:
            if not release.get("draft") and not release.get("prerelease"):
                return release
        raise RuntimeError("No published release found.")
    except requests.RequestException as e:
        print(f"Error fetching releases: {e}")
        raise

def extract_version(tag_name):
    version_match = re.search(r"(\d+\.\d+\.\d+)", tag_name)
    if not version_match:
        raise RuntimeError(f"Could not parse version from tag_name: {tag_name}")
    return version_match.group(1)

def find_ipa_asset(assets, version):
    ipa_assets = [
        asset for asset in assets
        if asset.get("name", "").lower().endswith(".ipa")
    ]

    expected_name = re.compile(
        rf"^venera-ios-{re.escape(version)}(?:\+\d+)?\.ipa$",
        re.IGNORECASE,
    )
    for asset in ipa_assets:
        if expected_name.match(asset["name"]):
            return asset

    for asset in ipa_assets:
        name = asset["name"].lower()
        if name.startswith("venera-ios-") and version in name:
            return asset

    if len(ipa_assets) == 1:
        return ipa_assets[0]

    available = ", ".join(asset.get("name", "<unnamed>") for asset in assets)
    raise RuntimeError(
        "IPA file not found in release assets. "
        f"Available assets: {available or '<none>'}"
    )

def update_json_file_release(json_file, latest_release):
    if not isinstance(latest_release, dict):
        raise RuntimeError("Error getting latest release")

    try:
        with open(json_file, "r", encoding="utf-8-sig") as file:
            data = json.load(file)
    except json.JSONDecodeError as e:
        print(f"Error reading JSON file: {e}")
        data = {"apps": []}
        raise

    app = data["apps"][0]

    full_version = latest_release["tag_name"]
    tag = latest_release["tag_name"]
    version = extract_version(full_version)
    version_date = latest_release["published_at"]
    date_obj = datetime.strptime(version_date, "%Y-%m-%dT%H:%M:%SZ")
    version_date = date_obj.strftime("%Y-%m-%d")

    description = latest_release.get("body") or ""
    description = prepare_description(description)

    assets = latest_release.get("assets", [])
    asset = find_ipa_asset(assets, version)
    download_url = asset["browser_download_url"]
    size = asset["size"]

    version_entry = {
        "version": version,
        "date": version_date,
        "localizedDescription": description,
        "downloadURL": download_url,
        "size": size
    }

    app["versions"] = [
        item for item in app.setdefault("versions", [])
        if item.get("version") != version
    ]

    app["versions"].insert(0, version_entry)

    app.update({
        "version": version,
        "versionDate": version_date,
        "versionDescription": description,
        "downloadURL": download_url,
        "size": size
    })

    if "news" not in data:
        data["news"] = []

    news_identifier = f"release-{full_version}"
    date_string = date_obj.strftime("%d/%m/%y")
    news_entry = {
        "appID": "com.github.wgh136.venera",
        "caption": f"Update of Venera just got released!",
        "date": latest_release["published_at"],
        "identifier": news_identifier,
        "notify": True,
        "tintColor": "#0784FC",
        "title": f"{full_version} - Venera  {date_string}",
        "url": f"https://github.com/CyrilPeng/venera-next/releases/tag/{tag}"
    }

    news_entry_exists = any(
        item.get("identifier") == news_identifier for item in data["news"]
    )
    if not news_entry_exists:
        data["news"].append(news_entry)

    try:
        with open(json_file, "w", encoding="utf-8") as file:
            json.dump(data, file, indent=2)
        print("JSON file updated successfully.")
    except IOError as e:
        print(f"Error writing to JSON file: {e}")
        raise

def main():
    repo_url = "CyrilPeng/venera-next"
    is_nightly = "NIGHTLY_LINK" in os.environ

    try:
        fetched_data_latest = fetch_latest_release(repo_url)
        json_file = "alt_store.json"
        update_json_file_release(json_file, fetched_data_latest)
    except Exception as e:
        print(f"An error occurred: {e}")
        raise

if __name__ == "__main__":
    main()
