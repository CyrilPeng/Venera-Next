<div align="center">
  <a href="README.md">简体中文</a> | <a href="README.en.md">English</a> | <strong>Deutsch</strong> | <a href="README.ja.md">日本語</a>

  <br>
  <img src="assets/readme_logo.png" alt="VeneraNext" width="200" />

  # VeneraNext

  ![Flutter](https://img.shields.io/badge/Flutter-3.41.4-02569B?logo=flutter&logoColor=white&style=flat-square)
  [![Release](https://img.shields.io/github/v/release/CyrilPeng/venera-next?label=Release&color=10B981&style=flat-square)](https://github.com/CyrilPeng/venera-next/releases/latest)
  ![License](https://img.shields.io/badge/License-GPL--3.0-10B981?style=flat-square)
  <br>
  [![Downloads](https://img.shields.io/github/downloads/CyrilPeng/venera-next/total?style=flat-square&color=2ea44f&logo=github)](https://tooomm.github.io/github-release-stats/?user=CyrilPeng&repo=venera-next)
  [![Afdian](https://img.shields.io/badge/Afdian-Sponsor-ff69b4?style=flat-square)](https://ifdian.net/a/cyril)

  <a href="https://trendshift.io/repositories/140830?utm_source=repository-badge&amp;utm_medium=badge&amp;utm_campaign=badge-repository-140830" target="_blank" rel="noopener noreferrer"><img src="https://trendshift.io/api/badge/repositories/140830" alt="VeneraNext-Repository-Badge auf Trendshift" width="250" height="55" /></a>
  <a href="https://trendshift.io/repositories/140830?utm_source=trendshift-badge&amp;utm_medium=badge&amp;utm_campaign=badge-trendshift-140830" target="_blank" rel="noopener noreferrer"><img src="https://trendshift.io/api/badge/trendshift/repositories/140830/daily?language=Dart" alt="VeneraNext in der täglichen Dart-Rangliste auf Trendshift" width="250" height="55" /></a>

</div>

<!-- featured-sponsors:start -->
<!-- featured-sponsors:end -->

---

<details>
<summary>Inhalt</summary>

- [1. Einführung](#introduction)
- [2. Besonderheiten](#highlights)
- [3. Download und Installation](#download-and-installation)
  - [3.1 Android-Smartphones und -Tablets](#android-phones-and-tablets)
  - [3.2 Android TV](#android-tv)
  - [3.3 Windows](#windows)
  - [3.4 HarmonyOS](#harmonyos)
  - [3.5 Linux](#linux)
  - [3.6 iOS](#ios)
  - [3.7 macOS](#macos)
- [4. Schnellstart](#quick-start)
- [5. Bedienung](#usage-guide)
- [6. Comic-Quellen entwickeln](#developing-comic-sources)
- [7. Häufige Fragen](#faq)
- [8. Ressourcen für Entwickler](#developer-resources)
- [9. GitHub-Sterne im Zeitverlauf](#star-history)
- [10. Hinweise](#statement)
- [11. Sponsoren](#sponsors)
- [12. Danksagung](#acknowledgements)
- [13. Lizenz](#license)
- [14. Community-Links](#community-links)

</details>

<a id="introduction"></a>
## 1. Einführung

[VeneraNext](https://github.com/CyrilPeng/venera-next) führt die Entwicklung von [Venera](https://github.com/venera-app/venera) fort, einem mit Flutter entwickelten Comicreader für **Android, Android TV, Windows, Linux, iOS, macOS und HarmonyOS**.

Dieser Fork macht das Lesen flüssiger: Im Wasserfallmodus geht es ohne Verlassen des Lesefensters über Kapitelgrenzen hinweg weiter. Langes Drücken auf Favorisieren überspringt die Ordnerauswahl; für nächtliches Lesen und E-Ink-Geräte gibt es eigene Anpassungen. Lokaler Import, Offline-Downloads, Lesestatistiken und geräteübergreifende Synchronisation erleichtern das Finden und Lesen von Comics sowie das Verfolgen laufender Serien.

JavaScript-Erweiterungen, lokales Lesen, Suche und Kategorien, Favoriten und Downloads sowie die von Quellen bereitgestellten Anmeldungen, Kommentare und Bewertungen bleiben verfügbar.

Die App-Oberfläche unterstützt vereinfachtes und traditionelles Chinesisch, Englisch, Deutsch und Japanisch. Die Auswahl steht unter **Einstellungen → App → Sprache**. Die Projektstartseite bleibt standardmäßig auf Chinesisch. Deutsch und Japanisch sind ab `v1.18.5` in stabilen Releases enthalten.

**Direktzugriff:** [Installation](#download-and-installation) · [Bedienung](#usage-guide) · [Eine Quelle schreiben](doc/api/comic_source.en.md) · [JavaScript-API](doc/api/js.en.md) · [Änderungsprotokoll](CHANGELOG.md)

> [!IMPORTANT]
> Dieses Repository pflegt den Reader und die Erweiterungslaufzeit. Es stellt keine Comic-Quellen bereit, bündelt oder hostet sie nicht und empfiehlt sie auch nicht. Rechtmäßig nutzbare Erweiterungen müssen selbst eingerichtet werden; Inhalte und Verfügbarkeit hängen von der jeweiligen Erweiterung und ihrem Dienst ab.

<div align="center">
  <a href="https://github.com/CyrilPeng/Venera-Next">
    <img alt="GitHub-Hauptrepository" src="https://img.shields.io/badge/GitHub-Main_repository-181717?style=for-the-badge&logo=github&logoColor=white" />
  </a>
  <a href="https://gitee.com/CyrilPeng/venera-next">
    <img alt="Gitee-Spiegel in China" src="https://img.shields.io/badge/Gitee-China_mirror-C71D23?style=for-the-badge&logo=gitee&logoColor=white" />
  </a>
</div>

---

<a id="screenshots"></a>
### 1.1 Bildschirmfotos

| Startseite: Verlauf, Später lesen und Updateverfolgung | Comicdetails |
|---|---|
| <a href="https://git-pictures.cyrilworkshop.dpdns.org/veneranext/Home.jpg"><img src="https://git-pictures.cyrilworkshop.dpdns.org/veneranext/Home.jpg" alt="VeneraNext-Startseite mit Verlauf, Später lesen und Updateverfolgung" width="100%" /></a> | <a href="https://git-pictures.cyrilworkshop.dpdns.org/veneranext/Details.jpg"><img src="https://git-pictures.cyrilworkshop.dpdns.org/veneranext/Details.jpg" alt="VeneraNext-Comicdetailseite mit Leseaktionen, Informationen und Kapiteln" width="100%" /></a> |

---

<a id="highlights"></a>
## 2. Besonderheiten

<a id="track-updates-with-one-long-press"></a>
### 2.1 Updates mit einem langen Druck verfolgen

Mit den Standardeinstellungen fügt **langes Drücken auf Favorisieren** auf der Comicdetailseite den Comic direkt zum Ordner für Updates verfolgen hinzu, ohne die Ordnerauswahl zu öffnen. Die App prüft automatisch auf neue Inhalte und zeigt deren Anzahl und die Comiccover auf der Startseite. Ein Cover öffnet die Detailseite; mit Lesen oder Fortfahren beginnt die Lektüre.

Bei einer Neuinstallation wird dieser Ordner automatisch angelegt; sein Standardname ist „追更“. Zum Ändern des Schnellfavoriten- oder Updateordners siehe [Favoriten, Später lesen und Updateverfolgung](#favorites-read-later-and-update-tracking).

<a id="reading-experience"></a>
### 2.2 Leseerlebnis

- **Kapitelübergreifender Wasserfallmodus (Standard außerhalb von TV):** Am Kapitelende einfach weiterlesen. Das nächste Kapitel wird nahe dem Ende automatisch geladen; bereits geladene Kapitel können auch wieder nach oben durchblättert werden. Der Fortschritt entspricht der tatsächlichen Leseposition.
- **Android TV und TV-Boxen:** Eigenes TV-Paket mit Querformat-Launcher, Fernbedienungsnavigation, sichtbarem Fokus und speichersparender Einzelansicht als Standard. Es lässt sich parallel zur mobilen App installieren.
- **Breite Doppelseiten vertikal teilen:** Im vertikalen fortlaufenden oder Wasserfallmodus lassen sich die beiden Hälften einer Doppelseite untereinander anzeigen. Ihre Reihenfolge kann an die Leserichtung angepasst werden.
- **Nachtabdunklung:** Comicbilder im Lesefenster abdunkeln, ohne die Systemhelligkeit zu verändern.
- **E-Ink-Auffrischung:** Im Galeriemodus kann ein kurzes Aufblinken nach einer einstellbaren Anzahl von Seitenwechseln Geisterbilder reduzieren. Intervall und Muster sind anpassbar.
- **Praktischere Detailseite:** Herunterladen und Lesen/Fortfahren sind leichter erreichbar; Kapitelfortschritt und Updates sind sichtbar. Die zuletzt gewählte Kapitelsortierung wird gespeichert.

<a id="discovery-favorites-and-data"></a>
### 2.3 Entdecken, Favoriten und Daten

- **Später lesen:** Geplante Lektüre in einer eigenen Liste speichern und direkt von der Startseite aufrufen.
- **Lokale Bibliothek:** Bildordner, CBZ/ZIP/7Z/CB7, PDF und bildbasierte EPUB importieren und direkt lesen, einschließlich Kapitelordnern und natürlicher Sortierung. Lokale Comics lassen sich als CBZ exportieren.
- **WebDAV für Synchronisation, Backups und NAS:** Einstellungen, Favoriten und Lesefortschritt zwischen Geräten synchronisieren, lokale Comics sichern oder Bildordner auf einem NAS online lesen. Jede Funktion wird getrennt eingerichtet.
- **Lesestatistik:** Die Lesezeit erfassen. Im Verlauf stehen Gesamtzeit, gelesene Comics und eine Rangliste nach Lesezeit.
- **Favoritengalerie und Suchkurzbefehle:** Favoriten als Covergalerie anzeigen, häufige Autoren-/Tagsuchen speichern und favorisierte Bilder je Comic durchsuchen.

<a id="core-venera-capabilities-retained"></a>
### 2.4 Weiterhin verfügbare Venera-Funktionen

- **Erweiterbare Quellen:** JavaScript-Erweiterungen können Suche, quellenübergreifende Suche, Entdecken-Seiten, Kategorien, Ranglisten und Tagübersetzungen bereitstellen.
- **Flexibles Lesen:** Seitenwechsel im Galeriemodus, Scrollen innerhalb eines Kapitels, Zoom und mehrere Bilder pro Ansicht; Bedienung per Touch, Tastatur oder mobilen Lautstärketasten.
- **Favoriten und Offline-Zugriff:** Lokale und Online-Favoriten, Verlauf, gespeicherte Bilder und Downloadwarteschlange. Heruntergeladene Kapitel sind offline lesbar.
- **Quellenabhängige Interaktion:** Konten, Cookies, Kommentare und Antworten, Likes und Bewertungen, soweit die Erweiterung sie implementiert.
- **Mehrere Geräte:** WebDAV-Synchronisation der App-Daten, Import/Export und [Headless-Befehle](doc/user/headless.en.md) für Skripte.

---

<a id="download-and-installation"></a>
## 3. Download und Installation

<a id="android-phones-and-tablets"></a>
### 3.1 Android-Smartphones und -Tablets

Eine APK aus der [neuesten stabilen Veröffentlichung](https://github.com/CyrilPeng/Venera-Next/releases/latest) herunterladen:

| Datei | Beschreibung | Empfohlen für |
|---|---|---|
| `VeneraNext-xxx-android.apk` | Universelles Paket | Die meisten Android-Geräte |
| `VeneraNext-xxx-android-arm64-v8a.apk` | ARM64-Paket | Android-Geräte mit Unterstützung für ARM64-Apps |
| `VeneraNext-xxx-android-armeabi-v7a.apk` | ARM32-Paket | Ältere 32-Bit-Geräte |
| `VeneraNext-xxx-android-x86_64.apk` | x86_64-Paket | x86_64-Geräte oder Emulatoren |

Im Zweifel das universelle Paket `VeneraNext-xxx-android.apk` verwenden.

<a id="android-tv"></a>
### 3.2 Android TV

Eine TV-APK aus der [neuesten stabilen Veröffentlichung](https://github.com/CyrilPeng/venera-next/releases/latest) herunterladen:

| Datei | Beschreibung | Empfohlen für |
|---|---|---|
| `VeneraNext-xxx-android-tv.apk` | Universelles TV-Paket | Die meisten Android-TVs oder TV-Boxen |
| `VeneraNext-xxx-android-tv-arm64-v8a.apk` | TV-ARM64-Paket | TVs oder TV-Boxen mit Unterstützung für ARM64-Apps |
| `VeneraNext-xxx-android-tv-armeabi-v7a.apk` | TV-ARM32-Paket | TVs oder TV-Boxen mit 32-Bit-System |
| `VeneraNext-xxx-android-tv-x86_64.apk` | TV-x86_64-Paket | x86_64-Geräte oder Emulatoren |

Im Zweifel das universelle TV-Paket `VeneraNext-xxx-android-tv.apk` verwenden.

Die APK auf den TV übertragen und per Sideload installieren. Der Launchername ist **VeneraNext TV**. Die TV-App kann neben der mobilen App installiert werden und speichert ihre Daten getrennt.

Zur Bedienung siehe [TV-Fernbedienung und speichersparendes Lesen](#tv-remote-controls-and-low-memory-reading). Installation und Updates erklärt [Android-TV-Verteilung](doc/distribution/android_tv.en.md) (Englisch).

<a id="windows"></a>
### 3.3 Windows

winget wird empfohlen, da für spätere Updates dieselbe Paket-ID verwendet werden kann:

```powershell
winget install --id CyrilPeng.VeneraNext --exact
winget upgrade --id CyrilPeng.VeneraNext --exact
```

Alternativ stehen `VeneraNext-xxx-windows-installer.exe` und das portable ZIP in der [neuesten stabilen Veröffentlichung](https://github.com/CyrilPeng/Venera-Next/releases/latest) bereit. Portable Versionen werden nicht von winget verwaltet und müssen manuell aktualisiert werden. Neue Versionen können in winget später erscheinen, weil Microsoft die Manifeständerungen prüft. Vor einer erneuten Prüfung `winget source update` ausführen.

Einzelheiten zu Installer, portabler Version und winget stehen unter [Windows-Verteilung](doc/distribution/windows.en.md) (Englisch).

<a id="harmonyos-beta"></a>
<a id="harmonyos"></a>
### 3.4 HarmonyOS

Das HarmonyOS-Paket unter Assets der [neuesten stabilen Veröffentlichung](https://github.com/CyrilPeng/Venera-Next/releases/latest) herunterladen. Ab `v1.18.5` wird HarmonyOS mit derselben Version wie die anderen Plattformen über Releases veröffentlicht. Öffentliche Anhänge lassen sich ohne GitHub-Anmeldung direkt herunterladen:

| Datei | Beschreibung | Empfohlen für |
|---|---|---|
| `VeneraNext-xxx-harmonyos-arm64-unsigned.hap` | Unsigniertes ARM64-Paket | HarmonyOS-Smartphones und -Tablets mit API-26-Unterstützung |

Dieselbe Veröffentlichung enthält `harmonyos-manifest.json` und `harmonyos-SHA256SUMS`. Diese prüfen, anschließend das HAP selbst signieren und installieren. Die Updateprüfung in der App öffnet eine Veröffentlichung mit dem passenden HAP. Für Updates den bisherigen Signaturschlüssel behalten. Anleitung und bekannte Plattformgrenzen stehen in der [HarmonyOS-Installationsanleitung](doc/distribution/harmonyos-reader.en.md) (Englisch).

<a id="linux"></a>
### 3.5 Linux

Das Paket für die eigene Distribution und Architektur aus der [neuesten stabilen Veröffentlichung](https://github.com/CyrilPeng/venera-next/releases/latest) herunterladen:

| Distribution / Format | Installation oder Start |
|---|---|
| Debian / Ubuntu (DEB) | `sudo apt install ./venera-next_xxx_amd64.deb` (auf ARM64 `arm64` verwenden) |
| Fedora und andere Distributionen mit den erforderlichen Abhängigkeiten (RPM) | `sudo dnf install ./venera-next-xxx.x86_64.rpm` (auf ARM64 `aarch64` verwenden) |
| Arch Linux (x86_64) | `sudo pacman -U ./venera-next-xxx-x86_64.pkg.tar.zst` |
| AppImage (x86_64 / ARM64) | Erst `chmod +x VeneraNext-xxx-x86_64.AppImage`, dann `./VeneraNext-xxx-x86_64.AppImage` ausführen (auf ARM64 die `aarch64`-Datei verwenden) |

`xxx` durch die Versionsnummer im heruntergeladenen Dateinamen ersetzen. RPM und AppImage sind für x86_64 und ARM64 verfügbar. Die Architektur lässt sich mit `uname -m` prüfen.

Linux-Pakete werden unter Ubuntu 22.04 mit glibc 2.35 als Basis gebaut. Das aktuelle stabile AppImage enthält GTK 3 und WebKitGTK 4.1; eine separate Installation ist nicht nötig. Auf dem Host werden weiterhin glibc 2.35 oder neuer sowie kompatible OpenGL-/EGL-Treiber benötigt. Abhängigkeiten, FUSE-Probleme und Distributionskompatibilität behandelt [Linux-Installation und -Verteilung](doc/distribution/linux.en.md) (Englisch).

<a id="ios"></a>
### 3.6 iOS

Die IPA aus der [neuesten stabilen Veröffentlichung](https://github.com/CyrilPeng/Venera-Next/releases/latest) herunterladen und mit AltStore installieren.

<a id="macos"></a>
### 3.7 macOS

`VeneraNext-xxx.dmg` aus der [neuesten stabilen Veröffentlichung](https://github.com/CyrilPeng/Venera-Next/releases/latest) herunterladen.

---

<a id="quick-start"></a>
## 4. Schnellstart

1. **Installieren:** Die passende Version aus der [neuesten stabilen Veröffentlichung](https://github.com/CyrilPeng/venera-next/releases/latest) installieren. Für TVs das separate Paket unter [Android TV](#android-tv) wählen.
2. **Inhalte hinzufügen:** Zum Einstieg reicht eine Möglichkeit: vorhandene Comicdateien über Lokal → Importieren; Onlineserien über eine Erweiterung in der Comic-Quellenverwaltung; NAS-Ordner über Einstellungen → App → WebDAV-Comicbibliothek.
3. **Lesen:** Smartphones und Desktop verwenden standardmäßig den kapitelübergreifenden Wasserfallmodus, TV die speichersparende Einzelansicht. Zum Verfolgen einer Serie den Favoritenknopf auf ihrer Detailseite lange drücken. Lesemodus, Doppelseitenteilung, Nachtabdunklung und weitere Optionen sind unter Einstellungen → Lesen oder direkt im Lesefenster anpassbar.

<a id="usage-guide"></a>
## 5. Bedienung

<a id="reading-modes-and-progress"></a>
### 5.1 Lesemodi und Fortschritt

| Modus | Richtungen | Geeignet für |
|---|---|---|
| Wasserfall (Standard außerhalb von TV) | Oben nach unten | Kapitelübergreifendes Lesen; angrenzende Kapitel werden nahe den Grenzen geladen |
| Galerie | L→R / R→L / O→U | Seitenweises Lesen mit einstellbarer Mehrbildansicht |
| Fortlaufend | L→R / R→L / O→U | Scrollen innerhalb des aktuellen Kapitels mit klaren Grenzen |

- **Vorladen:** Unter Einstellungen → Lesen die Anzahl vorgeladener Bilder festlegen, um kommende Seiten vorzubereiten und Wartezeiten zu reduzieren. Mehr Bilder benötigen auch mehr Daten und Arbeitsspeicher.
- **Fortsetzen:** Kapitel und Seite werden gespeichert. Im Wasserfallmodus zählt das tatsächlich gelesene Kapitel. Aufsteigend/Absteigend auf der Detailseite ändert nur die Darstellung der Liste.
- **Individuelle Leseeinstellungen:** Gerätespezifische oder comicspezifische Einstellungen aktivieren, um nicht jedes Mal neu anpassen zu müssen.
- **v1.18.4:** Das Lesemenü über seine Werkzeugleiste sperren und mit dem kleinen Schloss am Rand entsperren. Umblättern, Scrollen und Zoom bleiben nutzbar. Vertikales fortlaufendes Lesen und Wasserfall bieten Weiße Seitenränder beschneiden, standardmäßig ausgeschaltet. Das Deaktivieren stellt die vollständige Anzeige wieder her; Originaldateien, Downloads und Exporte bleiben unverändert. Siehe [Seitenränder und Zuschnitt](doc/user/reader_width.en.md) (Englisch).

| Einzelansicht | Geteilte Doppelseite |
|---|---|
| <a href="https://git-pictures.cyrilworkshop.dpdns.org/veneranext/Single%20Page%20View.jpg"><img src="https://git-pictures.cyrilworkshop.dpdns.org/veneranext/Single%20Page%20View.jpg" alt="Breite Seite vor dem Teilen" width="100%" /></a> | <a href="https://git-pictures.cyrilworkshop.dpdns.org/veneranext/Double%20Page%20View.jpg"><img src="https://git-pictures.cyrilworkshop.dpdns.org/veneranext/Double%20Page%20View.jpg" alt="Dieselbe Doppelseite mit aktivierter Teilung" width="100%" /></a> |

<a id="tv-remote-controls-and-low-memory-reading"></a>
### 5.2 TV-Fernbedienung und speichersparendes Lesen

- **Hauptoberfläche:** Mit Richtungstasten den Fokus verschieben, mit OK / Gamepad A aktivieren und mit Zurück / Gamepad B zurückgehen. Eine Menütaste öffnet bei unterstützten Steuerelementen das Kontextmenü.
- **Lesefläche:** Richtungstasten blättern oder scrollen; OK öffnet das Lesemenü. Bei geöffnetem Menü bewegen die Richtungstasten den Fokus, ohne im Hintergrund Seiten zu wechseln. Zurück schließt zuerst das Menü, danach wird der Fortschritt gespeichert und das Lesefenster verlassen.
- **Speichersparende Vorgaben:** Einzelansicht, eine Seite vorladen, 64 MiB Cache für dekodierte Bilder und ein Dekodierbudget von etwa 2,07 Megapixeln. Einstellungen → Lesen → TV-Modus für wenig Arbeitsspeicher deaktivieren, um bisherige Einstellungen und Modi wie Wasserfall zu verwenden. Der Schalter gilt nur für dieses Gerät und wird weder gesichert noch synchronisiert.
- **Hinweise:** Originale bleiben im speichersparenden Modus unverändert; lange Bildstreifen und vergrößerte Details können unschärfer wirken. Webanmeldung, CAPTCHA und Dateiauswahl können eine Eingabemethode oder ein weiteres Gerät erfordern.

<a id="nighttime-and-e-ink-reading"></a>
### 5.3 Nacht- und E-Ink-Lesen

- **Nachtabdunklung:** Im Lesefenster über die Einstellungen oder das untere Schnellpanel aktivieren und die Helligkeit zwischen 20 % und 100 % wählen. Nur das Bild innerhalb der App wird beeinflusst. Das helle, dunkle oder systemabhängige Design steht unter Einstellungen → Darstellung.
- **E-Ink:** Im Galeriemodus die Auffrischung aktivieren. Ein Aufblinken alle 1–10 Seitenwechsel, 100–1500 ms Dauer und Schwarz, Weiß oder Weiß dann Schwarz sind einstellbar. Fortlaufend und Wasserfall lösen keine Auffrischung aus.

<a id="favorites-read-later-and-update-tracking"></a>
### 5.4 Favoriten, Später lesen und Updateverfolgung

`v1.18.4` bietet Comics auswählen in der breiten Werkzeugleiste oder im schmalen Mehr-Menü sowie Unterordner sortieren. Bei genügend Platz erscheinen Alle auswählen, Auswahl umkehren und Auswahl aufheben in der Werkzeugleiste. Auf dem Desktop beendet Escape die Auswahl oder Suche. Das Favoritenpanel auf der Comicdetailseite nutzt die gesamte verfügbare Höhe; Neuer Ordner bleibt rechts in der festen Werkzeugleiste. Siehe [Favoritenordner und Sammelaktionen](doc/user/favorite_folders.en.md) (Englisch).

- **Favoriten:** Favorisieren auf der Detailseite öffnet das Panel zur Auswahl eines lokalen Ordners oder Quellenkontos, abhängig von der Erweiterung. Die Favoritenseite bietet Liste oder Covergalerie mit automatischer Anordnung oder 2–6 Spalten.
- **Schnellfavorit:** Langes Drücken auf Favorisieren fügt direkt zum gewählten lokalen Ordner hinzu, standardmäßig dem Updateordner. Das Ziel unter Einstellungen → Lokale Favoriten → Schnellfavorit ändern.
- **Updateverfolgung:** Auf der Startseite Updates verfolgen öffnen und den Zielordner wählen oder mit Jetzt prüfen manuell aktualisieren.
- **Später lesen:** Auf der Comicdetailseite oder im Menü lokaler Comics hinzufügen oder entfernen. Die vollständige Liste steht auf der Startseite. Das Öffnen eines Comics entfernt ihn nicht aus der Liste.
- **Lesestatistik:** Der Verlauf zeigt Gesamtzeit, gelesene Comics und Zeitranglisten. Der Verlauf kann nach einer Aufbewahrungsdauer bereinigt werden.
- **Suchkurzbefehle:** Häufige Autoren-/Tagsuchen speichern und auf der Suchseite wiederverwenden.

<a id="local-comics-and-offline-downloads"></a>
### 5.5 Lokale Comics und Offline-Downloads

| Inhalt | Import und Lesen |
|---|---|
| Bildordner | Einzel- und Stapelimport einschließlich Kapitelordnern; optionale Cover und natürliche Dateinamensortierung |
| CBZ / ZIP / 7Z / CB7 | In die lokale Bibliothek entpacken; auch Archive mit äußerem Ordner und Kapitelordnern |
| PDF | Mehrere Dateien nacheinander mit Fortschritt und Abbruch importieren; Seiten als lokale JPEGs rendern, erste Seite als Cover |
| Bildbasierte EPUB | Bilder in EPUB-Lesereihenfolge importieren; Titel, Autor, Cover und Kapitelnavigation nach Verfügbarkeit übernehmen |
| Quellen-Downloads | Kapitel in der lokalen Bibliothek zum Offline-Lesen, Exportieren und Archivieren speichern |

CBZ-Export, Wiederherstellung von Downloads durch Scannen, Kapitellöschung und Speicherumzug sind verfügbar. PDF-/EPUB-Import benötigt zusätzlichen Speicher. Reine Text-EPUB, direkt gezeichnete SVG-Seiten, verschlüsselte PDF und MOBI/AZW/AZW3 werden nicht unterstützt. Ordnerbeispiele, Archivkompatibilität und Metadatenvorlagen stehen unter [lokaler Import, CBZ und WebDAV-Bibliothek](doc/user/import_comic.en.md) (Englisch).

<a id="network-comic-extensions"></a>
### 5.6 Erweiterungen für Online-Comics

Vom Benutzer installierte JavaScript-Erweiterungen liefern Online-Inhalte. Suche, Entdecken-Seiten, Kategorien, Konten, Favoriten und Kommentare hängen von der jeweiligen Erweiterung ab.

Einen kompatiblen Skriptlink oder eine Datei in der Comic-Quellenverwaltung hinzufügen. Für eigene Erweiterungen mit [Comic-Quellen entwickeln](#developing-comic-sources) beginnen.

<a id="webdav-data-sync-archives-and-online-library"></a>
### 5.7 WebDAV-Synchronisation, Archive und Online-Bibliothek

Diese Funktionen werden getrennt eingerichtet:

| Funktion | Eintrag unter Einstellungen → App | Zweck |
|---|---|---|
| App-Datensynchronisation | Datensynchronisation | Einstellungen, Favoriten, Verlauf, Cookies und Quelldateien synchronisieren; lokale Comicbilder sind ausgeschlossen |
| Comicarchive | Comicarchiv-Backup | Lokale Comics als CBZ hochladen oder Archive in die lokale Bibliothek herunterladen |
| Online-Bibliothek | WebDAV-Comicbibliothek | Entfernte Bildordner bei Bedarf laden und Ordnerinformationen sowie Bilder zwischenspeichern |

Die Online-Bibliothek unterstützt Bildordner, Kapitelordner und entpackte CBZ-Exporte aus VeneraNext. Eine `metadata.json` kann Titel, Autor, Tags und Kapitelinformationen ergänzen. Das Regal zeigt zuerst zwischengespeicherte Comics und prüft anschließend den Server auf neue oder geänderte Inhalte. Manuelle Synchronisation und automatische Aktualisierungsintervalle sind möglich.

Entfernte CBZ/ZIP/7Z/CB7 müssen vor dem Lesen auf dem Server entpackt oder lokal wiederhergestellt werden. Siehe [Ordner- und Metadatenregeln](doc/user/import_comic.en.md#webdav-online-library) (Englisch).

<a id="keyword-blocking"></a>
### 5.8 Schlüsselwortfilter

Schlüsselwörter für Comics und Kommentare werden getrennt unter **Einstellungen → Entdecken** verwaltet. `v1.18.4` bietet **Text enthält**, **Ganzes Wort**, **Exakter Tag** und eine Groß-/Kleinschreibungseinstellung je Regel. Vor dem Speichern mit Beispieltext testen oder die ausgeblendete Anzahl in einer Comicliste anklicken, um Gründe zu sehen und Regeln zu bearbeiten. Für kurze Abkürzungen wie `BL` wird **Ganzes Wort** empfohlen, damit nicht auch `black` erfasst wird. Bestehende Regeln behalten ihr Verhalten.

Beispiele und Backupkompatibilität stehen unter [Schlüsselwortfilter und Treffergründe](doc/user/keyword_blocking.en.md) (Englisch).

<a id="developing-comic-sources"></a>
## 6. Comic-Quellen entwickeln

**Einstieg für eigene Drittanbieter-Erweiterungen (Dokumente auf Englisch):**

| Dokument | Inhalt |
|---|---|
| [Anleitung für Comic-Quellen](doc/api/comic_source.en.md) | Minimalbeispiel, Schnittstellen für Suche/Details/Kapitel, Bildanfragen und optionale Funktionen |
| [Minimale Quellenvorlage](doc/examples/minimal_source.js) | Kopierbare JS-Datei, die den gesamten Ladeablauf mit einer fiktiven API zeigt |
| [JavaScript-API](doc/api/js.en.md) | Netzwerk, HTML-Verarbeitung, Quellenspeicher, UI, Bildverarbeitung und Laufzeitgrenzen |
| [Lokales Quellen-Debugging](doc/development/source_debugging.en.md) | Importieren, Bearbeiten, JS-Evaluator und Protokolle |

Chinesische Fassungen: [漫画源编写指南](doc/api/comic_source.zh.md) · [JavaScript API](doc/api/js.zh.md) · [本地调试](doc/development/source_debugging.zh.md).

Dieser Fork pflegt weiterhin Venera-kompatible Erweiterungsschnittstellen. Wasserfallmodus, Doppelseitenteilung und Nachtabdunklung gehören zum Reader. Erweiterungen liefern stabile Comic-/Kapitel-IDs, korrekt geordnete Kapitel und Bilder sowie gültige Aktualisierungsdaten. Sie benötigen keine gesonderten Regeln für jeden Lesemodus.

<a id="faq"></a>
## 7. Häufige Fragen

<a id="does-veneranext-include-comic-sources"></a>
### 7.1 Enthält VeneraNext Comic-Quellen?

Es werden keine Quellen und kein empfohlener Katalog mitgeliefert. Lokale Comics importieren oder eine rechtmäßig nutzbare, kompatible Erweiterung beziehungsweise WebDAV-Bibliothek einrichten.

<a id="why-are-search-results-or-images-missing"></a>
### 7.2 Warum fehlen Suchergebnisse oder Bilder?

Zuerst Erweiterung, Anmeldestatus (Cookies), Dienstverfügbarkeit und Netzwerk prüfen. Probleme mit Webseiten und Inhalten an den jeweiligen Erweiterungsbetreuer melden. Reader- oder Laufzeitprobleme, die unabhängig von einer bestimmten Webseite reproduzierbar sind, können gemäß den [Beitragsrichtlinien](CONTRIBUTING.en.md) (Englisch) gemeldet werden.

<a id="how-often-are-updates-checked-and-why-are-some-updates-not-flagged"></a>
### 7.3 Wie oft werden Updates geprüft und warum werden manche nicht markiert?

- **Automatische Prüfungen:** Während die App läuft, erfolgt alle 10 Minuten eine Prüfung. Comics, die in den letzten 24 Stunden erfolgreich geprüft wurden, werden übersprungen. Jetzt prüfen auf der Seite Updates verfolgen aktualisiert sofort.
- **Erkennung:** Ein Comic wird markiert, wenn die Erweiterung eine geänderte, gültige Aktualisierungszeit liefert. Ein neues Kapitel ohne geänderte Aktualisierungszeit wird möglicherweise nicht markiert.
- **Anzeige:** Einstellungen → Entdecken → Aktualisierungsstatus auf Comic-Kacheln anzeigen steuert die Anzeige auf Vorschaubildern, nicht die Prüfungen selbst oder die Anzahl auf der Startseitenkarte.

<a id="how-do-i-shrink-strip-comics-on-a-tablet"></a>
### 7.4 Wie lassen sich lange Bildstreifen auf einem Tablet verkleinern?

In den Leseeinstellungen vertikales fortlaufendes Lesen oder Wasserfall wählen und **Bildstreifen verkleinern (Rand pro Seite)** anpassen. 20 % Rand auf jeder Seite ergeben 60 % der ursprünglichen Bildbreite bei proportionaler Höhe und unverändertem Fortschritt. Siehe [Bildstreifengröße und Seitenränder](doc/user/reader_width.en.md) (Englisch).

<a id="how-do-i-update-on-windows"></a>
### 7.5 Wie aktualisiere ich unter Windows?

`winget upgrade --id CyrilPeng.VeneraNext --exact` ausführen. Die Verfügbarkeit in der öffentlichen Paketquelle kann hinter GitHub Release zurückliegen; zuerst `winget source update` versuchen. Portable Installationen müssen manuell heruntergeladen und aktualisiert werden.

<a id="developer-resources"></a>
## 8. Ressourcen für Entwickler

- [Build und Entwicklung](doc/development/build.en.md): Flutter/Rust, gesperrte Abhängigkeiten, Tests und Releases (Englisch).
- [HarmonyOS-Builds und Releases](doc/development/harmonyos_releases.en.md): gemeinsame Quellversion, unabhängiges SDK, unsigniertes HAP und optionale Geräteberichte (Englisch).
- [Mitwirken](CONTRIBUTING.en.md) · [Abhängigkeitsverwaltung](doc/development/dependencies.en.md) (Englisch).
- [Windows-Verteilung](doc/distribution/windows.en.md) · [Headless-Modus](doc/user/headless.en.md) (Englisch).
- [Sicherheitsrichtlinie](SECURITY.md) · [Verhaltenskodex](CODE_OF_CONDUCT.md) · [Dokumentationsindex](doc/README.en.md). Die weiterführende Dokumentation liegt derzeit auf Chinesisch oder Englisch vor.

---

<a id="star-history"></a>
## 9. GitHub-Sterne im Zeitverlauf

<a href="https://www.star-history.com/?repos=CyrilPeng%2Fvenera-next&type=date&legend=top-left">
 <picture>
   <source media="(prefers-color-scheme: dark)" srcset="https://api.star-history.com/chart?repos=CyrilPeng/venera-next&type=date&theme=dark&legend=top-left&sealed_token=2JdfPV5RItrAVJNxNXhSHVr6mVbj9H_y_YMHJio2smj8uoRHGQKgrtY9k0PmbxUf6q0P-dR90ZWZSKlDDaygMd90LT7F0xI-2Bbtiq5muew1iXUSEFJzfouyqu70BiWT-hUeD9BKbFsdVr1knEJDWBqAArkJYIJcJCOYLZ5rUdpFdQ2aBIhT8wTQnOED" />
   <source media="(prefers-color-scheme: light)" srcset="https://api.star-history.com/chart?repos=CyrilPeng/venera-next&type=date&legend=top-left&sealed_token=2JdfPV5RItrAVJNxNXhSHVr6mVbj9H_y_YMHJio2smj8uoRHGQKgrtY9k0PmbxUf6q0P-dR90ZWZSKlDDaygMd90LT7F0xI-2Bbtiq5muew1iXUSEFJzfouyqu70BiWT-hUeD9BKbFsdVr1knEJDWBqAArkJYIJcJCOYLZ5rUdpFdQ2aBIhT8wTQnOED" />
   <img alt="GitHub-Sterne im Zeitverlauf" src="https://api.star-history.com/chart?repos=CyrilPeng/venera-next&type=date&legend=top-left&sealed_token=2JdfPV5RItrAVJNxNXhSHVr6mVbj9H_y_YMHJio2smj8uoRHGQKgrtY9k0PmbxUf6q0P-dR90ZWZSKlDDaygMd90LT7F0xI-2Bbtiq5muew1iXUSEFJzfouyqu70BiWT-hUeD9BKbFsdVr1knEJDWBqAArkJYIJcJCOYLZ5rUdpFdQ2aBIhT8wTQnOED" />
 </picture>
</a>

---

<a id="statement"></a>
## 10. Hinweise

Dieses Repository pflegt den Comicreader VeneraNext selbst. Es **stellt keine Comic-Quellen bereit, bündelt oder hostet sie nicht, empfiehlt sie nicht und verwaltet keine Inhalte der Quellseiten**.

Online-Lesen nutzt Erweiterungen, die mit der JavaScript-API kompatibel sind. Benutzer sind selbst für die Einrichtung rechtmäßig nutzbarer Erweiterungen verantwortlich. Suchergebnisse, Kapitel, Bildverfügbarkeit und Urheberrechte hängen von der jeweiligen Quellseite und ihrer Erweiterung ab.

**Keine Issues zu Comic-Quellen, Inhalten der Quellseiten, Verfügbarkeit bestimmter Titel oder Urheberrechten einreichen. Solche Meldungen werden geschlossen.**

---

<a id="sponsors"></a>
## 11. Sponsoren

VeneraNext ist ein aus persönlichem Interesse gepflegtes Projekt und wird nicht gewinnorientiert betrieben. Wenn es beim täglichen Lesen hilft, kann die weitere Pflege über [Afdian](https://ifdian.net/a/cyril) unterstützt werden.

Der Sponsorenstatus wird regelmäßig über die Afdian-API synchronisiert. Für eine öffentliche Nennung `公开昵称：Dein Name` in die Bestellnotiz schreiben. Ohne ausdrücklich angegebenen öffentlichen Namen wird die Bestellung nicht angezeigt.

Sponsorenliste und Anzeigeregeln stehen in [SPONSORS.md](SPONSORS.md) (Chinesisch).

---

<a id="acknowledgements"></a>
## 12. Danksagung

Vielen Dank an [Venera](https://github.com/venera-app/venera) für die Reader- und Erweiterungsgrundlage und an [EhTagTranslation](https://github.com/EhTagTranslation/Database) für die chinesischen Tagübersetzungen. Vielen Dank auch an alle Mitwirkenden und Sponsoren.

<a id="license"></a>
## 13. Lizenz

Dieses Projekt steht unter der GPL-3.0-Lizenz.

---

<a id="community-links"></a>
## 14. Community-Links

- [LINUX DO](https://linux.do/)
