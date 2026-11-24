<div align="center">
  <a href="README.md">简体中文</a> | <a href="README.en.md">English</a> | <a href="README.de.md">Deutsch</a> | <strong>日本語</strong>

  <br>
  <img src="assets/readme_logo.png" alt="VeneraNext" width="200" />

  # VeneraNext

  ![Flutter](https://img.shields.io/badge/Flutter-3.41.4-02569B?logo=flutter&logoColor=white&style=flat-square)
  [![Release](https://img.shields.io/github/v/release/CyrilPeng/venera-next?label=Release&color=10B981&style=flat-square)](https://github.com/CyrilPeng/venera-next/releases/latest)
  ![License](https://img.shields.io/badge/License-GPL--3.0-10B981?style=flat-square)
  <br>
  [![Downloads](https://img.shields.io/github/downloads/CyrilPeng/venera-next/total?style=flat-square&color=2ea44f&logo=github)](https://tooomm.github.io/github-release-stats/?user=CyrilPeng&repo=venera-next)
  [![Afdian](https://img.shields.io/badge/Afdian-Sponsor-ff69b4?style=flat-square)](https://ifdian.net/a/cyril)

  <a href="https://trendshift.io/repositories/140830?utm_source=repository-badge&amp;utm_medium=badge&amp;utm_campaign=badge-repository-140830" target="_blank" rel="noopener noreferrer"><img src="https://trendshift.io/api/badge/repositories/140830" alt="Trendshift の VeneraNext リポジトリバッジ" width="250" height="55" /></a>
  <a href="https://trendshift.io/repositories/140830?utm_source=trendshift-badge&amp;utm_medium=badge&amp;utm_campaign=badge-trendshift-140830" target="_blank" rel="noopener noreferrer"><img src="https://trendshift.io/api/badge/trendshift/repositories/140830/daily?language=Dart" alt="Trendshift の VeneraNext 日次 Dart ランキング" width="250" height="55" /></a>

</div>

<!-- featured-sponsors:start -->
<!-- featured-sponsors:end -->

---

<details>
<summary>目次</summary>

- [1. はじめに](#introduction)
- [2. 主な特長](#highlights)
- [3. ダウンロードとインストール](#download-and-installation)
  - [3.1 Android スマートフォン・タブレット](#android-phones-and-tablets)
  - [3.2 Android TV](#android-tv)
  - [3.3 Windows](#windows)
  - [3.4 HarmonyOS（ベータ版）](#harmonyos-beta)
  - [3.5 Linux](#linux)
  - [3.6 iOS](#ios)
  - [3.7 macOS](#macos)
- [4. クイックスタート](#quick-start)
- [5. 使い方](#usage-guide)
- [6. 漫画ソースの開発](#developing-comic-sources)
- [7. よくある質問](#faq)
- [8. 開発者向け情報](#developer-resources)
- [9. スター数の推移](#star-history)
- [10. プロジェクトの方針](#statement)
- [11. スポンサー](#sponsors)
- [12. 謝辞](#acknowledgements)
- [13. ライセンス](#license)
- [14. コミュニティリンク](#community-links)

</details>

<a id="introduction"></a>
## 1. はじめに

[VeneraNext](https://github.com/CyrilPeng/venera-next) は、Flutter 製漫画リーダー [Venera](https://github.com/venera-app/venera) の開発を引き継ぐプロジェクトです。**Android、Android TV、Windows、Linux、iOS、macOS** に対応し、**HarmonyOS ベータ版**は独立して配布しています。

このフォークでは、読書を中断する操作を減らしています。ウォーターフォールモードなら読書画面を離れずに章をまたいで読み進められ、お気に入りボタンの長押しでフォルダー選択を省略できます。夜間や電子ペーパー端末向けの調整も用意しました。ローカルのインポート、オフラインダウンロード、読書統計、端末間の同期により、漫画を探す・読む・更新を追う操作を使いやすくしています。

Venera の JavaScript 拡張、ローカル読書、検索とカテゴリー、お気に入り、ダウンロードに加え、ソースが提供するログイン・コメント・評価も引き続き利用できます。

アプリの画面は簡体字中国語、繁体字中国語、英語、ドイツ語、日本語に対応します。**「設定 → アプリ → 言語」**で選択できます。プロジェクトのデフォルト README は引き続き中国語です。ドイツ語と日本語は開発版で追加した機能で、次の安定版リリースから利用できます。

**クイックリンク：** [インストール](#download-and-installation) · [使い方](#usage-guide) · [ソースの作成](doc/api/comic_source.en.md) · [JavaScript API](doc/api/js.en.md) · [変更履歴](CHANGELOG.md)

> [!IMPORTANT]
> このリポジトリはリーダー本体と拡張の実行環境をメンテナンスします。漫画ソースの提供、同梱、ホスティング、推奨は行いません。利用者自身が適法な拡張を設定する必要があります。内容と利用可否は各拡張とサービスに依存します。

<div align="center">
  <a href="https://github.com/CyrilPeng/Venera-Next">
    <img alt="GitHub メインリポジトリ" src="https://img.shields.io/badge/GitHub-Main_repository-181717?style=for-the-badge&logo=github&logoColor=white" />
  </a>
  <a href="https://gitee.com/CyrilPeng/venera-next">
    <img alt="中国向け Gitee ミラー" src="https://img.shields.io/badge/Gitee-China_mirror-C71D23?style=for-the-badge&logo=gitee&logoColor=white" />
  </a>
</div>

---

<a id="screenshots"></a>
### 1.1 スクリーンショット

| ホーム：履歴・あとで読む・更新チェック | 漫画の詳細 |
|---|---|
| <a href="https://git-pictures.cyrilworkshop.dpdns.org/veneranext/Home.jpg"><img src="https://git-pictures.cyrilworkshop.dpdns.org/veneranext/Home.jpg" alt="読書履歴・あとで読む・更新チェックを表示した VeneraNext のホーム" width="100%" /></a> | <a href="https://git-pictures.cyrilworkshop.dpdns.org/veneranext/Details.jpg"><img src="https://git-pictures.cyrilworkshop.dpdns.org/veneranext/Details.jpg" alt="読書操作・作品情報・章を表示した VeneraNext の漫画詳細" width="100%" /></a> |

---

<a id="highlights"></a>
## 2. 主な特長

<a id="track-updates-with-one-long-press"></a>
### 2.1 長押しで更新をチェック

デフォルト設定では、漫画の詳細ページで**お気に入りボタンを長押し**すると、フォルダー選択を開かずに更新チェック用のフォルダーへ追加します。アプリは更新を自動確認し、ホームに更新件数と漫画の表紙を表示します。表紙をタップして詳細を開き、「読む」または「続行」を選ぶと読書を開始できます。

新規インストール時にこのフォルダーを自動作成します。デフォルト名は「追更」です。クイックお気に入りや更新チェックの対象フォルダーを変更する方法は、[お気に入り・あとで読む・更新チェック](#favorites-read-later-and-update-tracking)を参照してください。

<a id="reading-experience"></a>
### 2.2 読書機能

- **章をまたぐウォーターフォール読書（TV 以外のデフォルト）：** 章の終わりに近づくと次の章を自動で読み込み、そのまま読書を続けられます。読み込み済みの前の章にも戻れます。実際に読んでいる位置を進捗として記録します。
- **Android TV・TV ボックス：** 横向きのランチャー、リモコンの方向キー操作、見やすいフォーカス表示を備えた専用パッケージです。単ページの省メモリー読書がデフォルトで、モバイル版と共存できます。
- **横長の見開きを縦に分割：** スマートフォンで見開きが小さくなる場合は、縦方向の連続・ウォーターフォールモードで見開き分割を有効にすると、左右を上下に並べて表示できます。読む方向に合わせて順序も入れ替えられます。
- **夜間の調光：** システムの明るさを変更せず、読書画面内の漫画画像を暗くできます。
- **電子ペーパーのリフレッシュ：** ギャラリーモードでは指定したページ送り間隔で画面を点滅させ、残像を軽減できます。間隔と点滅方法を調整できます。
- **使いやすい詳細ページ：** ダウンロードと読む・続行ボタンを見つけやすくし、章の進捗と更新状態を表示します。最後に選んだ章の並び順も記憶します。

<a id="discovery-favorites-and-data"></a>
### 2.3 作品探し・お気に入り・データ管理

- **あとで読む：** 読む予定の漫画を専用リストに保存し、ホームからすぐに開けます。
- **ローカルライブラリ：** 画像フォルダー、CBZ/ZIP/7Z/CB7、PDF、画像形式の EPUB をインポートしてすぐに読めます。章フォルダーと自然順ソートに対応し、ローカル漫画を CBZ としてエクスポートできます。
- **WebDAV の同期・バックアップ・NAS 読書：** 設定、お気に入り、読書の進捗を端末間で同期し、ローカル漫画をバックアップしたり、NAS の画像フォルダーをオンラインで読んだりできます。各機能は個別に設定します。
- **読書統計：** 読書時間を記録します。履歴で合計時間、読んだ漫画、読書時間順のランキングを確認できます。
- **お気に入りギャラリーと検索ショートカット：** お気に入りを表紙のギャラリーで表示し、よく使う作者・タグ検索を保存できます。お気に入りの画像も漫画ごとに閲覧できます。

<a id="core-venera-capabilities-retained"></a>
### 2.4 引き継いだ Venera の機能

- **拡張可能なソース：** JavaScript で検索、横断検索、見つけるページ、カテゴリー、ランキング、タグ翻訳を提供できます。
- **柔軟な読書：** ギャラリーでのページ送り、章内スクロール、拡大、複数画像表示に対応します。タッチ、キーボード、モバイル端末の音量ボタンで操作できます。
- **お気に入りとオフライン利用：** ローカル・オンラインのお気に入り、履歴、保存画像、ダウンロードキューを利用できます。ダウンロードした章はオフラインで読めます。
- **ソースによる交流機能：** 拡張が対応していれば、アカウント、Cookie、コメントと返信、いいね、評価を利用できます。
- **複数端末：** WebDAV のアプリデータ同期、インポート・エクスポート、スクリプト向けの[ヘッドレスコマンド](doc/user/headless.en.md)に対応します。

---

<a id="download-and-installation"></a>
## 3. ダウンロードとインストール

<a id="android-phones-and-tablets"></a>
### 3.1 Android スマートフォン・タブレット

[最新の安定版](https://github.com/CyrilPeng/Venera-Next/releases/latest)から APK をダウンロードしてください。

| ファイル | 説明 | 対象端末 |
|---|---|---|
| `VeneraNext-xxx-android.apk` | 汎用版 | 大半の Android 端末 |
| `VeneraNext-xxx-android-arm64-v8a.apk` | ARM64 版 | ARM64 アプリに対応する Android 端末 |
| `VeneraNext-xxx-android-armeabi-v7a.apk` | ARM32 版 | 古い 32 ビット端末 |
| `VeneraNext-xxx-android-x86_64.apk` | x86_64 版 | x86_64 端末・エミュレーター |

迷った場合は汎用版の `VeneraNext-xxx-android.apk` を使用してください。

<a id="android-tv"></a>
### 3.2 Android TV

[最新の安定版](https://github.com/CyrilPeng/venera-next/releases/latest)から TV 用 APK をダウンロードしてください。

| ファイル | 説明 | 対象端末 |
|---|---|---|
| `VeneraNext-xxx-android-tv.apk` | TV 汎用版 | 大半の Android TV・TV ボックス |
| `VeneraNext-xxx-android-tv-arm64-v8a.apk` | TV ARM64 版 | ARM64 アプリに対応する TV・TV ボックス |
| `VeneraNext-xxx-android-tv-armeabi-v7a.apk` | TV ARM32 版 | 32 ビット OS の TV・TV ボックス |
| `VeneraNext-xxx-android-tv-x86_64.apk` | TV x86_64 版 | x86_64 端末・エミュレーター |

迷った場合は TV 汎用版の `VeneraNext-xxx-android-tv.apk` を使用してください。

APK を TV に転送してサイドロードしてください。ランチャー名は **VeneraNext TV** です。モバイル版と共存でき、データは別々に保存します。

操作は[TV リモコンと省メモリー読書](#tv-remote-controls-and-low-memory-reading)、インストールと更新の詳細は [Android TV の配布](doc/distribution/android_tv.en.md)（英語）を参照してください。

<a id="windows"></a>
### 3.3 Windows

今後も同じパッケージ ID で更新できる winget をおすすめします。

```powershell
winget install --id CyrilPeng.VeneraNext --exact
winget upgrade --id CyrilPeng.VeneraNext --exact
```

[最新の安定版](https://github.com/CyrilPeng/Venera-Next/releases/latest)から `VeneraNext-xxx-windows-installer.exe` またはポータブル ZIP を入手することもできます。ポータブル版は winget の管理対象ではなく、手動更新が必要です。Microsoft がマニフェストの変更を審査するため、winget への反映は GitHub Release より遅れる場合があります。再確認する前に `winget source update` を実行してください。

インストーラー、ポータブル版、winget の詳細は [Windows の配布](doc/distribution/windows.en.md)（英語）を参照してください。

<a id="harmonyos-beta"></a>
### 3.4 HarmonyOS（ベータ版）

[HarmonyOS ベータ版ワークフロー](https://github.com/CyrilPeng/Venera-Next/actions/workflows/harmonyos-release.yml)の成功した実行から `harmonyos-release` アーティファクトをダウンロードしてください。`v1.18.4` 以降、未署名の HarmonyOS ベータ版は独立して配布し、通常の安定版リリースには HAP を含めません。過去のリリース添付ファイルは引き続き利用できます。

| ファイル | 説明 | 対象端末 |
|---|---|---|
| `VeneraNext-xxx-harmonyos-arm64-unsigned.hap` | 未署名 ARM64 ベータ版 | API 26 の要件を満たす HarmonyOS スマートフォン・タブレット |

同じ実行のマニフェスト、ソースのコミット、SHA-256 を確認してから、自分で署名してサイドロードしてください。更新時には元の署名鍵を使い、アンインストールやデータ消去は行わないでください。HarmonyOS 実機での受け入れ確認はまだ完了していません。手順と制限は [HarmonyOS ベータ版のインストールガイド](doc/distribution/harmonyos-reader.en.md)（英語）を参照してください。

<a id="linux"></a>
### 3.5 Linux

[最新の安定版](https://github.com/CyrilPeng/venera-next/releases/latest)から、ディストリビューションとアーキテクチャに合ったパッケージをダウンロードしてください。

| ディストリビューション・形式 | インストール・実行方法 |
|---|---|
| Debian / Ubuntu（DEB） | `sudo apt install ./venera-next_xxx_amd64.deb`（ARM64 では `arm64` を使用） |
| Fedora および必要な依存ライブラリを提供するディストリビューション（RPM） | `sudo dnf install ./venera-next-xxx.x86_64.rpm`（ARM64 では `aarch64` を使用） |
| Arch Linux (x86_64) | `sudo pacman -U ./venera-next-xxx-x86_64.pkg.tar.zst` |
| AppImage（x86_64 / ARM64） | `chmod +x VeneraNext-xxx-x86_64.AppImage` のあと `./VeneraNext-xxx-x86_64.AppImage` を実行（ARM64 では `aarch64` のファイルを使用） |

`xxx` はダウンロードしたファイル名の実際のバージョンに置き換えてください。RPM と AppImage は x86_64 と ARM64 に対応します。`uname -m` でアーキテクチャを確認できます。

Linux パッケージは Ubuntu 22.04 でビルドし、glibc 2.35 を基準としています。現在の安定版 AppImage は GTK 3 と WebKitGTK 4.1 を同梱するため、別途インストールする必要はありません。ただし、ホスト側には glibc 2.35 以降と対応する OpenGL/EGL ドライバーが必要です。依存関係、FUSE のトラブル、ディストリビューションの互換性は [Linux のインストールと配布](doc/distribution/linux.en.md)（英語）を参照してください。

<a id="ios"></a>
### 3.6 iOS

[最新の安定版](https://github.com/CyrilPeng/Venera-Next/releases/latest)から IPA をダウンロードし、AltStore でサイドロードしてください。

<a id="macos"></a>
### 3.7 macOS

[最新の安定版](https://github.com/CyrilPeng/Venera-Next/releases/latest)から `VeneraNext-xxx.dmg` をダウンロードしてください。

---

<a id="quick-start"></a>
## 4. クイックスタート

1. **インストール：** [最新の安定版](https://github.com/CyrilPeng/venera-next/releases/latest)から端末用のパッケージをインストールします。TV は [Android TV](#android-tv) の専用パッケージを選んでください。
2. **コンテンツを追加：** 次のいずれかで始められます。手元の漫画ファイルは「ローカル → インポート」、オンラインの作品は漫画ソース管理で拡張を追加、NAS のフォルダーは「設定 → アプリ → WebDAV 漫画ライブラリ」を使用します。
3. **読書を開始：** スマートフォンとデスクトップは章をまたぐウォーターフォール、TV は単ページの省メモリー読書がデフォルトです。更新を追いたい作品は、詳細ページのお気に入りボタンを長押ししてみてください。読書モード、見開き分割、夜間の調光などは「設定 → 読書」や読書画面から変更できます。

<a id="usage-guide"></a>
## 5. 使い方

<a id="reading-modes-and-progress"></a>
### 5.1 読書モードと進捗

| モード | 方向 | 適した使い方 |
|---|---|---|
| ウォーターフォール（TV 以外のデフォルト） | 上から下 | 章をまたぐ連続読書。境界付近で隣の章を読み込みます |
| ギャラリー | 左→右 / 右→左 / 上→下 | ページ単位の読書。複数画像の配置を設定できます |
| 連続 | 左→右 / 右→左 / 上→下 | 現在の章の中をスクロール。章の境界は明示されます |

- **先読み：** 「設定 → 読書」で先読みする画像数を調整すると、次の画像を準備して待ち時間を減らせます。画像数を増やすと通信量とメモリー使用量も増えます。
- **続きから読む：** 章とページを保存し、ウォーターフォールでは実際に読んでいる章を記録します。詳細ページの昇順・降順は一覧の表示順だけを変えます。
- **個別の読書設定：** 端末ごと、または漫画ごとの設定を有効にすると、毎回調整する必要がなくなります。
- **v1.18.4：** 読書メニューのツールバーからメニューをロックし、画面端の小さな鍵で解除できます。ページ送り、スクロール、拡大は引き続き使えます。縦方向の連続・ウォーターフォールには「左右の白い余白を切り取る」があり、デフォルトではオフです。オフに戻すと画像全体を表示します。元のファイル、ダウンロード、エクスポートは変更しません。[左右の余白と切り取り](doc/user/reader_width.en.md)（英語）を参照してください。

| 単ページ表示 | 見開き分割表示 |
|---|---|
| <a href="https://git-pictures.cyrilworkshop.dpdns.org/veneranext/Single%20Page%20View.jpg"><img src="https://git-pictures.cyrilworkshop.dpdns.org/veneranext/Single%20Page%20View.jpg" alt="分割前の横長ページ" width="100%" /></a> | <a href="https://git-pictures.cyrilworkshop.dpdns.org/veneranext/Double%20Page%20View.jpg"><img src="https://git-pictures.cyrilworkshop.dpdns.org/veneranext/Double%20Page%20View.jpg" alt="見開き分割を有効にした同じページ" width="100%" /></a> |

<a id="tv-remote-controls-and-low-memory-reading"></a>
### 5.2 TV リモコンと省メモリー読書

- **メイン画面：** 方向キーでフォーカスを移動し、決定・ゲームパッド A で実行、戻る・ゲームパッド B で戻ります。メニューキーがあるリモコンは、対応する操作部品のコンテキストメニューを開けます。
- **読書画面：** 方向キーでページ送りやスクロールを行い、決定キーで読書メニューを開きます。メニューが開いている間は方向キーで項目を選び、背後のページは送りません。戻るキーはまずメニューを閉じ、次に進捗を保存して読書画面を終了します。
- **省メモリーのデフォルト：** 単ページ表示、1 ページの先読み、64 MiB のデコード済み画像キャッシュ、約 207 万画素のデコード上限です。「設定 → 読書 → TV 省メモリーモード」をオフにすると、以前の設定に戻してウォーターフォールなどを使えます。この切り替えは端末ごとに保存し、バックアップや同期には含めません。
- **注意：** 省メモリーモードは元の画像を変更しませんが、縦長の画像や拡大した細部が不鮮明に見える場合があります。ウェブログイン、CAPTCHA、ファイル選択などには入力手段や補助端末が必要になることがあります。

<a id="nighttime-and-e-ink-reading"></a>
### 5.3 夜間・電子ペーパーでの読書

- **夜間の調光：** 読書画面の設定または下部のクイックパネルで有効にし、20～100% に調整できます。アプリ内の画像だけに影響します。アプリのライト・ダーク・システムテーマは「設定 → 外観」で選択します。
- **電子ペーパー：** ギャラリーモードでリフレッシュを有効にし、1～10 回のページ送りごと、100～1500 ms の点滅時間、黒・白・白のあと黒の点滅方法を選べます。連続・ウォーターフォールでは実行しません。

<a id="favorites-read-later-and-update-tracking"></a>
### 5.4 お気に入り・あとで読む・更新チェック

`v1.18.4` は、広い画面のツールバーまたは狭い画面の「その他」メニューに「漫画を選択」を追加し、サブフォルダーの並べ替えにも対応しました。空間に余裕があれば「すべて選択」「選択を反転」「選択を解除」をツールバーに表示します。デスクトップでは Esc で選択や検索を終了できます。漫画詳細のお気に入りパネルは利用可能な高さ全体を使い、固定ツールバー右側に新しいフォルダーボタンを表示します。[お気に入りフォルダーと一括操作](doc/user/favorite_folders.en.md)（英語）を参照してください。

- **お気に入り：** 詳細ページのお気に入りボタンでパネルを開き、ローカルフォルダーまたはソースのアカウントを選択します。アカウントの利用は拡張によります。お気に入りページはリスト・表紙ギャラリーに対応し、列数は自動または 2～6 列で設定できます。
- **クイックお気に入り：** 詳細ページのお気に入りボタンを長押しすると、指定したローカルフォルダーに直接追加します。デフォルトは更新チェック用のフォルダーです。「設定 → ローカルのお気に入り → クイックお気に入り」で変更できます。
- **更新チェック：** ホームから「更新をチェック」を開いて対象フォルダーを選択します。「今すぐ確認」で手動更新できます。
- **あとで読む：** 漫画の詳細やローカル漫画のメニューから追加・削除できます。ホームから全件のリストを開けます。漫画を開いてもリストから削除しません。
- **読書統計：** 履歴に総読書時間、読んだ漫画、時間順ランキングを表示します。履歴は保持期間に応じて消去できます。
- **検索ショートカット：** よく使う作者・タグ検索を保存し、検索ページから再利用できます。

<a id="local-comics-and-offline-downloads"></a>
### 5.5 ローカル漫画とオフラインダウンロード

| コンテンツ | インポートと読書の動作 |
|---|---|
| 画像フォルダー | 単一・一括インポート、章フォルダー、任意の表紙、ファイル名の自然順ソートに対応 |
| CBZ / ZIP / 7Z / CB7 | ローカルライブラリに展開。外側フォルダーや章フォルダーがあるアーカイブにも対応 |
| PDF | 複数ファイルを順次インポート。進捗表示とキャンセルに対応。ページをローカルの JPEG に変換し、最初のページを表紙に使用 |
| 画像形式の EPUB | EPUB の読書順で画像をインポート。可能な場合はタイトル・作者・表紙・章ナビゲーションを保持 |
| ソースからのダウンロード | 章をローカルライブラリに保存してオフライン読書、エクスポート、アーカイブに利用 |

CBZ のエクスポート、スキャンによるダウンロードの復元、章の削除、保存先の移動に対応します。PDF・EPUB のインポートは追加の容量を消費します。テキストのみの EPUB、直接描画する SVG ページ、暗号化された PDF、MOBI/AZW/AZW3 には対応していません。フォルダー例、アーカイブの互換性、メタデータのテンプレートは[ローカルインポート・CBZ・WebDAV ライブラリ](doc/user/import_comic.en.md)（英語）を参照してください。

<a id="network-comic-extensions"></a>
### 5.6 オンライン漫画の拡張

利用者がインストールした JavaScript 拡張がオンラインのコンテンツを提供します。検索、作品探し、カテゴリー、アカウント、お気に入り、コメントの機能は拡張によって異なります。

漫画ソース管理で対応するスクリプトのリンクまたはファイルを追加してください。拡張を作成する場合は[漫画ソースの開発](#developing-comic-sources)から始められます。

<a id="webdav-data-sync-archives-and-online-library"></a>
### 5.7 WebDAV のデータ同期・アーカイブ・オンラインライブラリ

これらの機能は個別に設定します。

| 機能 | 「設定 → アプリ」の項目 | 用途 |
|---|---|---|
| アプリデータの同期 | データ同期 | 設定、お気に入り、履歴、Cookie、ソースファイルを同期。ローカル漫画の画像は除外 |
| 漫画アーカイブ | 漫画アーカイブのバックアップ | ローカル漫画を CBZ としてアップロード、またはアーカイブをローカルライブラリへダウンロード |
| オンラインライブラリ | WebDAV 漫画ライブラリ | サーバーの画像フォルダーを必要に応じて読み込み、フォルダー情報と画像をキャッシュ |

オンラインライブラリは画像フォルダー、章フォルダー、VeneraNext がエクスポートした CBZ の展開先に対応します。`metadata.json` でタイトル、作者、タグ、章情報を追加できます。本棚はまずキャッシュ済みの漫画を表示し、その後サーバーの新規・変更コンテンツを確認します。手動同期または自動更新間隔を設定できます。

サーバー上の CBZ/ZIP/7Z/CB7 は、読む前にサーバーで展開するかローカルに復元する必要があります。[フォルダーとメタデータのルール](doc/user/import_comic.en.md#webdav-online-library)（英語）を参照してください。

<a id="keyword-blocking"></a>
### 5.8 キーワードブロック

漫画とコメントのキーワードは**「設定 → 見つける」**で別々に管理します。`v1.18.4` は**「文字列を含む」「単語単位」「タグの完全一致」**と、ルールごとの大文字・小文字の設定に対応します。保存前にサンプルを試すか、漫画一覧の非表示件数をタップして理由の確認とルールの編集ができます。`BL` のような短い略語には**「単語単位」**を使うと `black` への誤一致を防げます。既存のルールの動作は保持します。

例とバックアップの互換性は[キーワードブロックと一致理由](doc/user/keyword_blocking.en.md)（英語）を参照してください。

<a id="developing-comic-sources"></a>
## 6. 漫画ソースの開発

**サードパーティ拡張の開発は、次の資料から始めてください（英語）。**

| 資料 | 内容 |
|---|---|
| [漫画ソースガイド](doc/api/comic_source.en.md) | 最小例、検索・詳細・章の契約、画像リクエスト、任意の機能 |
| [最小ソーステンプレート](doc/examples/minimal_source.js) | 架空の API で一連の読み込みを示す、コピー可能な JS ファイル |
| [JavaScript API](doc/api/js.en.md) | 通信、HTML 解析、ソースの保存領域、UI、画像処理、実行時の制限 |
| [ソースのローカルデバッグ](doc/development/source_debugging.en.md) | インポート、編集、JS Evaluator、ログ |

中国語版：[漫画源编写指南](doc/api/comic_source.zh.md) · [JavaScript API](doc/api/js.zh.md) · [本地调试](doc/development/source_debugging.zh.md)。

このフォークは Venera 互換の拡張インターフェースを引き続きメンテナンスします。ウォーターフォール、見開き分割、夜間の調光はリーダー側が担当します。拡張は安定した漫画・章の ID、正しい順序の章と画像、有効な更新日時を提供し、読書モードごとに別のルールを設ける必要はありません。

<a id="faq"></a>
## 7. よくある質問

<a id="does-veneranext-include-comic-sources"></a>
### 7.1 VeneraNext に漫画ソースは含まれていますか？

ソースや推奨カタログは同梱しません。ローカル漫画をインポートするか、適法な対応拡張または WebDAV ライブラリを設定してください。

<a id="why-are-search-results-or-images-missing"></a>
### 7.2 検索結果や画像が表示されないのはなぜですか？

まず漫画ソース拡張、ログイン状態（Cookie）、サービスの稼働状況、ネットワークを確認してください。サイトや内容の問題は該当する拡張のメンテナーに連絡してください。特定のサイトに依存せず再現するリーダーや拡張実行環境の問題は、[貢献ガイド](CONTRIBUTING.en.md)（英語）に従って報告できます。

<a id="how-often-are-updates-checked-and-why-are-some-updates-not-flagged"></a>
### 7.3 更新の確認間隔と、更新が表示されない理由は？

- **自動確認：** アプリ実行中は 10 分ごとに確認し、過去 24 時間以内に確認が成功した漫画はスキップします。「更新をチェック」ページの「今すぐ確認」で即座に更新できます。
- **更新の判定：** 拡張が返す有効な更新日時が変わると、漫画を更新ありと判定します。新しい章が増えても更新日時が変わっていなければ、表示されない場合があります。
- **更新マーク：** 「設定 → 見つける → 漫画カードに更新状態を表示」はサムネイル上の表示を制御します。更新の確認やホームカードの件数には影響しません。

<a id="how-do-i-shrink-strip-comics-on-a-tablet"></a>
### 7.4 タブレットで縦長漫画を小さく表示するには？

読書設定で縦方向の連続またはウォーターフォールを選び、**「縦長漫画を縮小（片側の余白）」**を調整してください。左右各 20% なら画像の幅は元の 60% となり、高さも比例して縮小します。読書の進捗は保持します。[縦長漫画のサイズと左右の余白](doc/user/reader_width.en.md)（英語）を参照してください。

<a id="how-do-i-update-on-windows"></a>
### 7.5 Windows で更新するには？

`winget upgrade --id CyrilPeng.VeneraNext --exact` を実行してください。公開パッケージソースへの反映は GitHub Release より遅れる場合があるため、先に `winget source update` を試してください。ポータブル版は手動で新しいファイルをダウンロードして更新します。

<a id="developer-resources"></a>
## 8. 開発者向け情報

- [ビルドと開発](doc/development/build.en.md)：Flutter/Rust、固定された依存関係、テスト、リリース（英語）。
- [HarmonyOS の独立ベータビルド](doc/development/harmonyos_releases.en.md)：正確な主ブランチのソース、独立 SDK、未署名 HAP、実機での受け入れ確認（英語）。
- [貢献ガイド](CONTRIBUTING.en.md) · [依存関係の管理](doc/development/dependencies.en.md)（英語）。
- [Windows の配布](doc/distribution/windows.en.md) · [ヘッドレスモード](doc/user/headless.en.md)（英語）。
- [セキュリティ方針](SECURITY.md) · [行動規範](CODE_OF_CONDUCT.md) · [ドキュメント一覧](doc/README.en.md)。詳細資料は現在、中国語または英語で提供しています。

---

<a id="star-history"></a>
## 9. スター数の推移

<a href="https://www.star-history.com/?repos=CyrilPeng%2Fvenera-next&type=date&legend=top-left">
 <picture>
   <source media="(prefers-color-scheme: dark)" srcset="https://api.star-history.com/chart?repos=CyrilPeng/venera-next&type=date&theme=dark&legend=top-left&sealed_token=2JdfPV5RItrAVJNxNXhSHVr6mVbj9H_y_YMHJio2smj8uoRHGQKgrtY9k0PmbxUf6q0P-dR90ZWZSKlDDaygMd90LT7F0xI-2Bbtiq5muew1iXUSEFJzfouyqu70BiWT-hUeD9BKbFsdVr1knEJDWBqAArkJYIJcJCOYLZ5rUdpFdQ2aBIhT8wTQnOED" />
   <source media="(prefers-color-scheme: light)" srcset="https://api.star-history.com/chart?repos=CyrilPeng/venera-next&type=date&legend=top-left&sealed_token=2JdfPV5RItrAVJNxNXhSHVr6mVbj9H_y_YMHJio2smj8uoRHGQKgrtY9k0PmbxUf6q0P-dR90ZWZSKlDDaygMd90LT7F0xI-2Bbtiq5muew1iXUSEFJzfouyqu70BiWT-hUeD9BKbFsdVr1knEJDWBqAArkJYIJcJCOYLZ5rUdpFdQ2aBIhT8wTQnOED" />
   <img alt="GitHub スター数の推移" src="https://api.star-history.com/chart?repos=CyrilPeng/venera-next&type=date&legend=top-left&sealed_token=2JdfPV5RItrAVJNxNXhSHVr6mVbj9H_y_YMHJio2smj8uoRHGQKgrtY9k0PmbxUf6q0P-dR90ZWZSKlDDaygMd90LT7F0xI-2Bbtiq5muew1iXUSEFJzfouyqu70BiWT-hUeD9BKbFsdVr1knEJDWBqAArkJYIJcJCOYLZ5rUdpFdQ2aBIhT8wTQnOED" />
 </picture>
</a>

---

<a id="statement"></a>
## 10. プロジェクトの方針

このリポジトリは VeneraNext 漫画リーダー本体をメンテナンスします。**漫画ソースの提供、同梱、ホスティング、推奨や、ソースサイトの内容の管理は行いません。**

オンライン読書は JavaScript API と互換性のある拡張を使用します。適法な拡張の設定は利用者自身の責任です。検索結果、章の読み込み、画像の利用可否、コンテンツの著作権は、各ソースサイトと拡張の実装に依存します。

**漫画ソース、ソースサイトの内容、特定の作品の利用可否、著作権についての Issue は提出しないでください。そのような報告はクローズします。**

---

<a id="sponsors"></a>
## 11. スポンサー

VeneraNext は個人の関心からメンテナンスしている、営利目的ではないプロジェクトです。日々の読書に役立っている場合は、[愛発電](https://ifdian.net/a/cyril)から継続的なメンテナンスを支援できます。

スポンサーの状態は愛発電 API で定期的に同期します。公開の謝辞を希望する場合は、注文の備考に `公开昵称：あなたの名前` と記入してください。公開名の明示がない注文は表示しません。

スポンサー一覧と表示方針は [SPONSORS.md](SPONSORS.md)（中国語）を参照してください。

---

<a id="acknowledgements"></a>
## 12. 謝辞

リーダーと拡張の基盤を提供した [Venera](https://github.com/venera-app/venera)、中国語のタグ翻訳を提供した [EhTagTranslation](https://github.com/EhTagTranslation/Database) に感謝します。また、すべての貢献者とスポンサーの皆さまに感謝します。

<a id="license"></a>
## 13. ライセンス

このプロジェクトは GPL-3.0 ライセンスで公開しています。

---

<a id="community-links"></a>
## 14. コミュニティリンク

- [LINUX DO](https://linux.do/)
