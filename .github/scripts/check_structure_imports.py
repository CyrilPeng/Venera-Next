import argparse
import re
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
LIB_DIR = ROOT / "lib"
COMPONENTS_DIR = LIB_DIR / "components"
COMPONENTS_BARREL = COMPONENTS_DIR / "components.dart"
FOUNDATION_APP_PATH = (LIB_DIR / "foundation" / "app.dart").resolve()
FOUNDATION_CONTEXT_PATH = (LIB_DIR / "foundation" / "context.dart").resolve()
FOUNDATION_EXTENSIONS_BARREL = LIB_DIR / "foundation" / "extensions.dart"
FOUNDATION_WIDGET_UTILS_PATH = (LIB_DIR / "foundation" / "widget_utils.dart").resolve()
PAGES_DIR = LIB_DIR / "pages"
RETIRED_DART_PATHS = {
    LIB_DIR / "utils" / "tags_translation.dart": (
        "tag translation belongs in features/comic_source/"
    ),
    LIB_DIR / "utils" / "translations.dart": (
        "app localization belongs in foundation/"
    ),
    LIB_DIR / "utils" / "image.dart": (
        "image processing belongs in foundation/"
    ),
    LIB_DIR / "utils" / "io.dart": (
        "file system helpers belong in foundation/file_system.dart; "
        "platform file interaction belongs in foundation/file_interaction.dart"
    ),
    LIB_DIR / "utils" / "file_type.dart": (
        "file type detection belongs in foundation/file_type.dart"
    ),
    LIB_DIR / "utils" / "init.dart": (
        "initialization lifecycle belongs in foundation/init.dart"
    ),
    LIB_DIR / "utils" / "throttled_task_runner.dart": (
        "throttled task scheduling belongs in foundation/throttled_task_runner.dart"
    ),
    LIB_DIR / "utils" / "channel.dart": (
        "async queue primitives belong in foundation/channel.dart"
    ),
    LIB_DIR / "utils" / "clipboard_image.dart": (
        "reader clipboard image interaction belongs in features/reader/"
    ),
    LIB_DIR / "utils" / "volume.dart": (
        "reader volume key listening belongs in features/reader/"
    ),
    LIB_DIR / "utils" / "opencc.dart": (
        "Chinese conversion belongs in foundation/opencc.dart"
    ),
    LIB_DIR / "utils" / "ext.dart": (
        "common Dart extensions belong in foundation/extensions.dart"
    ),
}
RETIRED_DART_DIRS = {
    LIB_DIR / "utils": (
        "utils/ has been retired; use foundation/ for cross-domain primitives "
        "or features/<domain>/ for domain-specific helpers"
    ),
}

IMPORT_RE = re.compile(r"\b(?:import|export)\s+['\"]([^'\"]+)['\"]")
EXPORT_RE = re.compile(r"\bexport\s+['\"]([^'\"]+)['\"]")
PART_RE = re.compile(r"\bpart\s+['\"]([^'\"]+)['\"]")
PART_OF_RE = re.compile(r"^\s*part\s+of\b", re.MULTILINE)
SCHEME_RE = re.compile(r"^[a-zA-Z][a-zA-Z0-9+.-]*:")
COMPONENTS_PART_OF_RE = re.compile(
    r"^\s*part\s+of\s+['\"]components\.dart['\"]\s*;", re.MULTILINE
)
APP_SINGLETON_RE = re.compile(r"\bApp\b")
CONTEXT_EXTENSION_RE = re.compile(
    r"\bcontext\.(?:"
    r"pop|canPop|to|toReplacement|width|height|padding|viewInsets|"
    r"colorScheme|brightness|isDarkMode|showMessage|useBackgroundColor|"
    r"useTextColor"
    r")\b"
)
WIDGET_UTILS_RE = re.compile(
    r"\bts\b|"
    r"\.(?:"
    r"padding|paddingLeft|paddingRight|paddingTop|paddingBottom|"
    r"paddingVertical|paddingHorizontal|paddingAll|toCenter|toAlign|"
    r"sliverPadding|sliverPaddingAll|sliverPaddingVertical|"
    r"sliverPaddingHorizontal|fixWidth|fixHeight|toSliver|toOpacity"
    r")\("
)


def _feature_path(*parts: str) -> Path:
    path = LIB_DIR / "features"
    for part in parts:
        path /= part
    return path.resolve()


def _app_shell_path(*parts: str) -> Path:
    path = LIB_DIR / "app_shell"
    for part in parts:
        path /= part
    return path.resolve()


def _app_runtime_path(*parts: str) -> Path:
    path = LIB_DIR / "app_runtime"
    for part in parts:
        path /= part
    return path.resolve()


def _foundation_path(*parts: str) -> Path:
    path = LIB_DIR / "foundation"
    for part in parts:
        path /= part
    return path.resolve()


RETIRED_PART_TARGETS = {
    _feature_path("comic_source", "comic_source_manager.dart"): {
        "models.dart": (
            "comic source models belong in an independent comic_source "
            "implementation file"
        ),
        "types.dart": (
            "comic source callback types belong in an independent "
            "comic_source implementation file"
        ),
        "category.dart": (
            "comic source category data belongs in an independent "
            "comic_source implementation file"
        ),
        "source_translation.dart": (
            "comic source translation extensions belong in an independent "
            "comic_source implementation file"
        ),
        "image_loading.dart": (
            "comic source image loading registration belongs in an "
            "independent comic_source implementation file"
        ),
        "favorites.dart": (
            "comic source favorite data belongs in an independent "
            "comic_source implementation file"
        ),
        "js_bridge.dart": (
            "comic source JS data bridge belongs in an independent "
            "comic_source implementation file"
        ),
        "comic_type_bridge.dart": (
            "comic source type bridge belongs in an independent "
            "comic_source implementation file"
        ),
        "source.dart": (
            "comic source main class and source configuration data belong "
            "in an independent comic_source implementation file"
        ),
        "parser.dart": (
            "comic source parser belongs in an independent comic_source "
            "implementation file"
        ),
    },
    _feature_path("reader", "reader.dart"): {
        "chapter_comments.dart": (
            "reader chapter comments page belongs in an independent reader "
            "implementation file"
        ),
    },
    _feature_path("reader", "reader_page.dart"): {
        "scaffold.dart": (
            "reader scaffold belongs in an independent reader implementation "
            "file"
        ),
        "images.dart": (
            "reader image views belong in an independent reader implementation "
            "file"
        ),
        "gesture.dart": (
            "reader gestures belong in an independent reader implementation "
            "file"
        ),
        "comic_image.dart": (
            "reader comic image widget belongs in an independent reader "
            "implementation file"
        ),
        "loading.dart": (
            "reader loading entry belongs in an independent reader "
            "implementation file"
        ),
        "chapters.dart": (
            "reader chapter list belongs in an independent reader "
            "implementation file"
        ),
    },
    _feature_path("comic_details", "comic_page.dart"): {
        "comments_page.dart": (
            "comic comments page belongs in an independent comic_details "
            "implementation file"
        ),
        "cover_viewer.dart": (
            "comic cover viewer belongs in an independent comic_details "
            "implementation file"
        ),
        "comments_preview.dart": (
            "comic comments preview belongs in an independent comic_details "
            "implementation file"
        ),
        "thumbnails.dart": (
            "comic thumbnails preview belongs in an independent comic_details "
            "implementation file"
        ),
        "chapters.dart": (
            "comic chapters list belongs in an independent comic_details "
            "implementation file"
        ),
        "favorite.dart": (
            "comic favorite panel belongs in an independent comic_details "
            "implementation file"
        ),
        "actions.dart": (
            "comic details actions belong in an independent comic_details "
            "implementation file"
        ),
    },
    _feature_path("history", "history_manager.dart"): {
        "image_favorites.dart": (
            "image favorites management belongs in an independent history "
            "feature implementation file"
        )
    },
    _feature_path("favorites", "favorites_page.dart"): {
        "favorite_actions.dart": (
            "favorite actions belong in an independent favorites "
            "implementation file"
        ),
        "local_favorites_page.dart": (
            "local favorites page belongs in an independent favorites "
            "implementation file"
        ),
        "network_favorites_page.dart": (
            "network favorites page belongs in an independent favorites "
            "implementation file"
        ),
        "side_bar.dart": (
            "favorites folder sidebar belongs in an independent favorites "
            "implementation file"
        )
    },
    _feature_path("image_favorites", "image_favorites_page.dart"): {
        "image_favorites_gallery_page.dart": (
            "image favorites gallery page belongs in an independent "
            "image_favorites implementation file"
        ),
        "image_favorites_item.dart": (
            "image favorites item belongs in an independent image_favorites "
            "implementation file"
        ),
        "image_favorites_photo_view.dart": (
            "image favorites photo view belongs in an independent "
            "image_favorites implementation file"
        )
    },
    _feature_path("settings", "app.dart"): {
        "logs.dart": (
            "logs page belongs in an independent settings implementation file"
        )
    },
    _feature_path("settings", "settings_page.dart"): {
        "about.dart": (
            "about and changelog settings belong in an independent settings "
            "implementation file"
        ),
        "app.dart": (
            "app settings belong in an independent settings implementation "
            "file"
        ),
        "appearance.dart": (
            "appearance settings belong in an independent settings "
            "implementation file"
        ),
        "debug.dart": (
            "debug settings belong in an independent settings implementation "
            "file"
        ),
        "explore_settings.dart": (
            "explore settings belong in an independent settings "
            "implementation file"
        ),
        "local_favorites.dart": (
            "local favorites settings belong in an independent settings "
            "implementation file"
        ),
        "network.dart": (
            "network settings belong in an independent settings "
            "implementation file"
        ),
        "reader.dart": (
            "reader settings belong in an independent settings "
            "implementation file"
        ),
        "setting_components.dart": (
            "shared settings widgets belong in an independent settings "
            "implementation file"
        )
    },
}

NO_PART_TARGETS = {
    _feature_path("comic_source", "comic_source_manager.dart"): (
        "comic_source_manager.dart must remain a normal comic_source "
        "implementation file; split parser and source data into independent "
        "files instead"
    ),
    _feature_path("comic_details", "comic_page.dart"): (
        "comic_page.dart must remain a normal comic_details implementation "
        "file; split details views and actions into independent files instead"
    ),
    _feature_path("favorites", "favorites_page.dart"): (
        "favorites_page.dart must remain a normal favorites implementation "
        "file; split favorites views and widgets into independent files instead"
    ),
    _feature_path("image_favorites", "image_favorites_page.dart"): (
        "image_favorites_page.dart must remain a normal image_favorites "
        "implementation file; split image favorites views and widgets into "
        "independent files instead"
    ),
    _feature_path("settings", "settings_page.dart"): (
        "settings_page.dart must remain a normal settings implementation file; "
        "split settings sections into independent files instead"
    ),
    _feature_path("reader", "reader.dart"): (
        "reader.dart must remain an export-only reader entrypoint; split "
        "reader implementation files instead"
    ),
    _feature_path("reader", "reader_page.dart"): (
        "reader_page.dart must remain a normal reader implementation file; "
        "split reader views and controls into independent files instead"
    ),
}

RETIRED_PART_OF_PATHS = {
    _feature_path("comic_source", "models.dart"): (
        "comic source models must not be part of comic_source_manager.dart"
    ),
    _feature_path("comic_source", "types.dart"): (
        "comic source callback types must not be part of comic_source_manager.dart"
    ),
    _feature_path("comic_source", "category.dart"): (
        "comic source category data must not be part of comic_source_manager.dart"
    ),
    _feature_path("comic_source", "source_translation.dart"): (
        "comic source translation extensions must not be part of "
        "comic_source_manager.dart"
    ),
    _feature_path("comic_source", "image_loading.dart"): (
        "comic source image loading registration must not be part of "
        "comic_source_manager.dart"
    ),
    _feature_path("comic_source", "favorites.dart"): (
        "comic source favorite data must not be part of comic_source_manager.dart"
    ),
    _feature_path("comic_source", "js_bridge.dart"): (
        "comic source JS data bridge must not be part of comic_source_manager.dart"
    ),
    _feature_path("comic_source", "comic_type_bridge.dart"): (
        "comic source type bridge must not be part of comic_source_manager.dart"
    ),
    _feature_path("comic_source", "source.dart"): (
        "comic source main class and source configuration data must not be part "
        "of comic_source_manager.dart"
    ),
    _feature_path("comic_source", "parser.dart"): (
        "comic source parser must not be part of comic_source_manager.dart"
    ),
    _feature_path("reader", "chapter_comments.dart"): (
        "reader chapter comments page must not be part of reader.dart"
    ),
    _feature_path("reader", "scaffold.dart"): (
        "reader scaffold must not be part of reader_page.dart"
    ),
    _feature_path("reader", "images.dart"): (
        "reader image views must not be part of reader_page.dart"
    ),
    _feature_path("reader", "gesture.dart"): (
        "reader gestures must not be part of reader_page.dart"
    ),
    _feature_path("reader", "comic_image.dart"): (
        "reader comic image widget must not be part of reader_page.dart"
    ),
    _feature_path("reader", "loading.dart"): (
        "reader loading entry must not be part of reader_page.dart"
    ),
    _feature_path("reader", "chapters.dart"): (
        "reader chapter list must not be part of reader_page.dart"
    ),
    _feature_path("comic_details", "cover_viewer.dart"): (
        "comic cover viewer must not be part of comic_page.dart"
    ),
    _feature_path("comic_details", "comments_page.dart"): (
        "comic comments page must not be part of comic_page.dart"
    ),
    _feature_path("comic_details", "comments_preview.dart"): (
        "comic comments preview must not be part of comic_page.dart"
    ),
    _feature_path("comic_details", "thumbnails.dart"): (
        "comic thumbnails preview must not be part of comic_page.dart"
    ),
    _feature_path("comic_details", "chapters.dart"): (
        "comic chapters list must not be part of comic_page.dart"
    ),
    _feature_path("comic_details", "favorite.dart"): (
        "comic favorite panel must not be part of comic_page.dart"
    ),
    _feature_path("comic_details", "actions.dart"): (
        "comic details actions must not be part of comic_page.dart"
    ),
    _feature_path("history", "image_favorites.dart"): (
        "image favorites management must not be part of history_manager.dart"
    ),
    _feature_path("favorites", "favorite_actions.dart"): (
        "favorite actions must not be part of favorites_page.dart"
    ),
    _feature_path("favorites", "local_favorites_page.dart"): (
        "local favorites page must not be part of favorites_page.dart"
    ),
    _feature_path("favorites", "network_favorites_page.dart"): (
        "network favorites page must not be part of favorites_page.dart"
    ),
    _feature_path("favorites", "side_bar.dart"): (
        "favorites folder sidebar must not be part of favorites_page.dart"
    ),
    _feature_path("image_favorites", "image_favorites_photo_view.dart"): (
        "image favorites photo view must not be part of image_favorites_page.dart"
    ),
    _feature_path("image_favorites", "image_favorites_gallery_page.dart"): (
        "image favorites gallery page must not be part of image_favorites_page.dart"
    ),
    _feature_path("image_favorites", "image_favorites_item.dart"): (
        "image favorites item must not be part of image_favorites_page.dart"
    ),
    _feature_path("settings", "setting_components.dart"): (
        "shared settings widgets must not be part of settings_page.dart"
    ),
    _feature_path("settings", "about.dart"): (
        "about and changelog settings must not be part of settings_page.dart"
    ),
    _feature_path("settings", "app.dart"): (
        "app settings must not be part of settings_page.dart"
    ),
    _feature_path("settings", "appearance.dart"): (
        "appearance settings must not be part of settings_page.dart"
    ),
    _feature_path("settings", "debug.dart"): (
        "debug settings must not be part of settings_page.dart"
    ),
    _feature_path("settings", "explore_settings.dart"): (
        "explore settings must not be part of settings_page.dart"
    ),
    _feature_path("settings", "local_favorites.dart"): (
        "local favorites settings must not be part of settings_page.dart"
    ),
    _feature_path("settings", "logs.dart"): (
        "logs page must not be part of app.dart"
    ),
    _feature_path("settings", "network.dart"): (
        "network settings must not be part of settings_page.dart"
    ),
    _feature_path("settings", "reader.dart"): (
        "reader settings must not be part of settings_page.dart"
    ),
}


APP_SHELL_ENTRYPOINT_TARGETS = {
    _app_shell_path("auth_page.dart"): _app_shell_path("app_shell.dart"),
    _app_shell_path("home_page.dart"): _app_shell_path("app_shell.dart"),
    _app_shell_path("main_page.dart"): _app_shell_path("app_shell.dart"),
}

APP_RUNTIME_ENTRYPOINT_TARGETS = {
    _app_runtime_path("headless.dart"): _app_runtime_path("app_runtime.dart"),
    _app_runtime_path("init.dart"): _app_runtime_path("app_runtime.dart"),
}

FOUNDATION_ENTRYPOINT_TARGETS = {
    _foundation_path("extensions", "future_extensions.dart"): _foundation_path(
        "extensions.dart"
    ),
    _foundation_path("extensions", "list_extensions.dart"): _foundation_path(
        "extensions.dart"
    ),
    _foundation_path(
        "extensions",
        "nullable_collection_converters.dart",
    ): _foundation_path("extensions.dart"),
    _foundation_path("extensions", "string_extensions.dart"): _foundation_path(
        "extensions.dart"
    ),
}

UTILS_IO_PATH = (LIB_DIR / "utils" / "io.dart").resolve()
FILE_SYSTEM_ENTRYPOINT_PATH = (LIB_DIR / "foundation" / "file_system.dart").resolve()

FEATURE_ENTRYPOINT_TARGETS = {
    _feature_path("comic_widgets", "comic_list.dart"): _feature_path(
        "comic_widgets",
        "comic_widgets.dart",
    ),
    _feature_path("comic_widgets", "comic_tile.dart"): _feature_path(
        "comic_widgets",
        "comic_widgets.dart",
    ),
    _feature_path("comic_widgets", "rating.dart"): _feature_path(
        "comic_widgets",
        "comic_widgets.dart",
    ),
    _feature_path("comic_source", "category.dart"): _feature_path(
        "comic_source",
        "comic_source.dart",
    ),
    _feature_path("comic_source", "comic_source_manager.dart"): _feature_path(
        "comic_source",
        "comic_source.dart",
    ),
    _feature_path("comic_source", "comic_source_page.dart"): _feature_path(
        "comic_source",
        "comic_source.dart",
    ),
    _feature_path("comic_source", "comic_source_summary.dart"): _feature_path(
        "comic_source",
        "comic_source.dart",
    ),
    _feature_path("comic_source", "comic_type_bridge.dart"): _feature_path(
        "comic_source",
        "comic_source.dart",
    ),
    _feature_path("comic_source", "favorites.dart"): _feature_path(
        "comic_source",
        "comic_source.dart",
    ),
    _feature_path("comic_source", "image_loading.dart"): _feature_path(
        "comic_source",
        "comic_source.dart",
    ),
    _feature_path("comic_source", "js_bridge.dart"): _feature_path(
        "comic_source",
        "comic_source.dart",
    ),
    _feature_path("comic_source", "models.dart"): _feature_path(
        "comic_source",
        "comic_source.dart",
    ),
    _feature_path("comic_source", "normalization.dart"): _feature_path(
        "comic_source",
        "comic_source.dart",
    ),
    _feature_path("comic_source", "parser.dart"): _feature_path(
        "comic_source",
        "comic_source.dart",
    ),
    _feature_path("comic_source", "source_translation.dart"): _feature_path(
        "comic_source",
        "comic_source.dart",
    ),
    _feature_path("comic_source", "source.dart"): _feature_path(
        "comic_source",
        "comic_source.dart",
    ),
    _feature_path("comic_source", "tags_translation.dart"): _feature_path(
        "comic_source",
        "comic_source.dart",
    ),
    _feature_path("comic_source", "types.dart"): _feature_path(
        "comic_source",
        "comic_source.dart",
    ),
    _feature_path("comic_details", "action_button.dart"): _feature_path(
        "comic_details",
        "comic_details.dart",
    ),
    _feature_path("comic_details", "comic_page.dart"): _feature_path(
        "comic_details",
        "comic_details.dart",
    ),
    _feature_path("discovery", "categories_page.dart"): _feature_path(
        "discovery",
        "discovery.dart",
    ),
    _feature_path("discovery", "category_comics_page.dart"): _feature_path(
        "discovery",
        "discovery.dart",
    ),
    _feature_path("discovery", "explore_page.dart"): _feature_path(
        "discovery",
        "discovery.dart",
    ),
    _feature_path("discovery", "ranking_page.dart"): _feature_path(
        "discovery",
        "discovery.dart",
    ),
    _feature_path("favorites", "favorite_actions.dart"): _feature_path(
        "favorites",
        "favorites.dart",
    ),
    _feature_path("favorites", "favorites_manager.dart"): _feature_path(
        "favorites",
        "favorites.dart",
    ),
    _feature_path("favorites", "favorites_page.dart"): _feature_path(
        "favorites",
        "favorites.dart",
    ),
    _feature_path("follow_updates", "follow_updates_manager.dart"): _feature_path(
        "follow_updates",
        "follow_updates.dart",
    ),
    _feature_path("follow_updates", "follow_updates_page.dart"): _feature_path(
        "follow_updates",
        "follow_updates.dart",
    ),
    _feature_path("history", "history_image_provider.dart"): _feature_path(
        "history",
        "history.dart",
    ),
    _feature_path("history", "history_manager.dart"): _feature_path(
        "history",
        "history.dart",
    ),
    _feature_path("history", "history_page.dart"): _feature_path(
        "history",
        "history.dart",
    ),
    _feature_path("history", "history_summary.dart"): _feature_path(
        "history",
        "history.dart",
    ),
    _feature_path("history", "image_favorites.dart"): _feature_path(
        "history",
        "history.dart",
    ),
    _feature_path("history", "image_favorites_models.dart"): _feature_path(
        "history",
        "history.dart",
    ),
    _feature_path("history", "image_favorites_provider.dart"): _feature_path(
        "history",
        "history.dart",
    ),
    _feature_path("image_favorites", "image_favorites_page.dart"): _feature_path(
        "image_favorites",
        "image_favorites.dart",
    ),
    _feature_path(
        "image_favorites",
        "image_favorites_summary.dart",
    ): _feature_path(
        "image_favorites",
        "image_favorites.dart",
    ),
    _feature_path("image_favorites", "type.dart"): _feature_path(
        "image_favorites",
        "image_favorites.dart",
    ),
    _feature_path("comic_storage", "archive_metadata.dart"): _feature_path(
        "comic_storage",
        "comic_storage.dart",
    ),
    _feature_path("comic_storage", "comic_file_rules.dart"): _feature_path(
        "comic_storage",
        "comic_storage.dart",
    ),
    _feature_path("comic_storage", "file_system_layout.dart"): _feature_path(
        "comic_storage",
        "comic_storage.dart",
    ),
    _feature_path("local_comics", "import_export", "cbz.dart"): _feature_path(
        "local_comics",
        "import_export",
        "import_export.dart",
    ),
    _feature_path(
        "local_comics",
        "import_export",
        "comic_export.dart",
    ): _feature_path(
        "local_comics",
        "import_export",
        "import_export.dart",
    ),
    _feature_path(
        "local_comics",
        "import_export",
        "comic_import.dart",
    ): _feature_path(
        "local_comics",
        "import_export",
        "import_export.dart",
    ),
    _feature_path("local_comics", "import_export", "epub.dart"): _feature_path(
        "local_comics",
        "import_export",
        "import_export.dart",
    ),
    _feature_path(
        "local_comics",
        "import_export",
        "import_comic.dart",
    ): _feature_path(
        "local_comics",
        "import_export",
        "import_export.dart",
    ),
    _feature_path("local_comics", "import_export", "pdf.dart"): _feature_path(
        "local_comics",
        "import_export",
        "import_export.dart",
    ),
    _feature_path("local_comics", "downloading_page.dart"): _feature_path(
        "local_comics",
        "local_comics.dart",
    ),
    _feature_path("local_comics", "download.dart"): _feature_path(
        "local_comics",
        "local_comics.dart",
    ),
    _feature_path("local_comics", "local.dart"): _feature_path(
        "local_comics",
        "local_comics.dart",
    ),
    _feature_path("local_comics", "local_comic_image.dart"): _feature_path(
        "local_comics",
        "local_comics.dart",
    ),
    _feature_path("local_comics", "local_comics_page.dart"): _feature_path(
        "local_comics",
        "local_comics.dart",
    ),
    _feature_path("local_comics", "local_comics_summary.dart"): _feature_path(
        "local_comics",
        "local_comics.dart",
    ),
    _feature_path("reader", "chapter_comments.dart"): _feature_path(
        "reader",
        "reader.dart",
    ),
    _feature_path("reader", "chapters.dart"): _feature_path(
        "reader",
        "reader.dart",
    ),
    _feature_path("reader", "clipboard_image.dart"): _feature_path(
        "reader",
        "reader.dart",
    ),
    _feature_path("reader", "comic_image.dart"): _feature_path(
        "reader",
        "reader.dart",
    ),
    _feature_path("reader", "gesture.dart"): _feature_path(
        "reader",
        "reader.dart",
    ),
    _feature_path("reader", "images.dart"): _feature_path(
        "reader",
        "reader.dart",
    ),
    _feature_path("reader", "loading.dart"): _feature_path(
        "reader",
        "reader.dart",
    ),
    _feature_path("reader", "reader_page.dart"): _feature_path(
        "reader",
        "reader.dart",
    ),
    _feature_path("reader", "scaffold.dart"): _feature_path(
        "reader",
        "reader.dart",
    ),
    _feature_path("reader", "volume.dart"): _feature_path(
        "reader",
        "reader.dart",
    ),
    _feature_path("reader", "waterfall_flow.dart"): _feature_path(
        "reader",
        "reader.dart",
    ),
    _feature_path("search", "aggregated_search_page.dart"): _feature_path(
        "search",
        "search.dart",
    ),
    _feature_path("search", "search_entry.dart"): _feature_path(
        "search",
        "search.dart",
    ),
    _feature_path("search", "search_filter.dart"): _feature_path(
        "search",
        "search.dart",
    ),
    _feature_path("search", "search_page.dart"): _feature_path(
        "search",
        "search.dart",
    ),
    _feature_path("search", "search_result_page.dart"): _feature_path(
        "search",
        "search.dart",
    ),
    _feature_path("settings", "about.dart"): _feature_path(
        "settings",
        "settings.dart",
    ),
    _feature_path("settings", "app.dart"): _feature_path(
        "settings",
        "settings.dart",
    ),
    _feature_path("settings", "appearance.dart"): _feature_path(
        "settings",
        "settings.dart",
    ),
    _feature_path("settings", "debug.dart"): _feature_path(
        "settings",
        "settings.dart",
    ),
    _feature_path("settings", "explore_settings.dart"): _feature_path(
        "settings",
        "settings.dart",
    ),
    _feature_path("settings", "local_favorites.dart"): _feature_path(
        "settings",
        "settings.dart",
    ),
    _feature_path("settings", "logs.dart"): _feature_path(
        "settings",
        "settings.dart",
    ),
    _feature_path("settings", "network.dart"): _feature_path(
        "settings",
        "settings.dart",
    ),
    _feature_path("settings", "reader.dart"): _feature_path(
        "settings",
        "settings.dart",
    ),
    _feature_path("settings", "setting_components.dart"): _feature_path(
        "settings",
        "settings.dart",
    ),
    _feature_path("settings", "settings_page.dart"): _feature_path(
        "settings",
        "settings.dart",
    ),
    _feature_path("sync", "app_data_transfer.dart"): _feature_path(
        "sync",
        "sync.dart",
    ),
    _feature_path("sync", "comic_archive_page.dart"): _feature_path(
        "sync",
        "sync.dart",
    ),
    _feature_path("sync", "comic_backup.dart"): _feature_path(
        "sync",
        "sync.dart",
    ),
    _feature_path("sync", "data_sync.dart"): _feature_path(
        "sync",
        "sync.dart",
    ),
    _feature_path("sync", "sync_status_summary.dart"): _feature_path(
        "sync",
        "sync.dart",
    ),
}

FILE_SYSTEM_DIRECT_IMPORT_SOURCES = {
    _feature_path("comic_source", "comic_source_manager.dart"),
    _feature_path("favorites", "local_favorite_image.dart"),
    _feature_path("history", "image_favorites_provider.dart"),
    _feature_path("local_comics", "downloading_page.dart"),
    _feature_path("local_comics", "import_export", "cbz.dart"),
    _feature_path("local_comics", "local_comic_image.dart"),
    _feature_path("sync", "app_data_transfer.dart"),
    _feature_path("sync", "comic_archive_page.dart"),
    _feature_path("sync", "comic_backup.dart"),
    _feature_path("sync", "data_sync.dart"),
}


def _relative(path: Path) -> str:
    return path.relative_to(ROOT).as_posix()


def _module(path: Path) -> str:
    relative = path.relative_to(LIB_DIR).as_posix()
    parts = relative.split("/")
    if parts[0] == "features" and len(parts) > 1:
        return f"features/{parts[1]}"
    return parts[0]


def _resolve_import(source: Path, specifier: str) -> Path | None:
    if specifier.startswith("package:venera_next/"):
        return (LIB_DIR / specifier.removeprefix("package:venera_next/")).resolve()
    if SCHEME_RE.match(specifier):
        return None
    return (source.parent / specifier).resolve()


def _is_restricted(source: Path, target: Path) -> bool:
    source_module = _module(source)
    target_module = _module(target)
    if target_module == "app_shell":
        if source_module == "app_shell":
            return False
        return source_module in {
            "foundation",
            "network",
            "utils",
            "components",
            "routing",
        } or source_module.startswith("features/")
    if target_module == "app_runtime":
        if source_module == "app_runtime":
            return False
        return source_module in {
            "app_shell",
            "foundation",
            "network",
            "utils",
            "components",
            "routing",
        } or source_module.startswith("features/")
    if source_module in {"foundation", "network", "utils"}:
        if target_module == "components":
            return True
    if source_module in {"foundation", "network", "utils", "components"}:
        return target_module.startswith("features/") or target_module == "pages"
    if source_module.startswith("features/"):
        return target_module == "pages"
    return False


def _scan_restricted_imports() -> set[str]:
    imports = set()
    for source in sorted(LIB_DIR.rglob("*.dart")):
        text = source.read_text(encoding="utf-8")
        for match in IMPORT_RE.finditer(text):
            target = _resolve_import(source, match.group(1))
            if target is None:
                continue
            try:
                target.relative_to(LIB_DIR)
            except ValueError:
                continue
            if _is_restricted(source, target):
                imports.add(f"{_relative(source)} -> {_relative(target)}")
    return imports


def _scan_retired_pages_violations() -> set[str]:
    if not PAGES_DIR.exists():
        return set()

    violations = set()
    for source in sorted(PAGES_DIR.rglob("*.dart")):
        violations.add(
            f"{_relative(source)}: pages directory has been retired; "
            "use app_shell/ or features/<domain>/"
        )
    return violations


def _scan_retired_dart_path_violations() -> set[str]:
    violations = set()
    for source, message in RETIRED_DART_PATHS.items():
        if source.exists():
            violations.add(f"{_relative(source)}: retired path; {message}")
    return violations


def _scan_retired_dart_dir_violations() -> set[str]:
    violations = set()
    retired_paths = {source.resolve() for source in RETIRED_DART_PATHS}
    for directory, message in RETIRED_DART_DIRS.items():
        if not directory.exists():
            continue
        for source in sorted(directory.rglob("*.dart")):
            if source.resolve() in retired_paths:
                continue
            violations.add(f"{_relative(source)}: retired directory; {message}")
    return violations


def _scan_retired_part_violations() -> set[str]:
    violations = set()
    for source, retired_parts in RETIRED_PART_TARGETS.items():
        if not source.exists():
            continue
        text = source.read_text(encoding="utf-8")
        for match in PART_RE.finditer(text):
            part_name = match.group(1)
            message = retired_parts.get(part_name)
            if message is None:
                continue
            violations.add(f"{_relative(source)}: retired part; {message}")

    for source, message in NO_PART_TARGETS.items():
        if not source.exists():
            continue
        text = source.read_text(encoding="utf-8")
        if PART_RE.search(text):
            violations.add(f"{_relative(source)}: part library retired; {message}")

    for source, message in RETIRED_PART_OF_PATHS.items():
        if not source.exists():
            continue
        text = source.read_text(encoding="utf-8")
        if PART_OF_RE.search(text):
            violations.add(f"{_relative(source)}: retired part file; {message}")

    return violations


def _scan_component_barrel_violations() -> set[str]:
    violations = set()

    barrel_text = COMPONENTS_BARREL.read_text(encoding="utf-8")
    for line_number, line in enumerate(barrel_text.splitlines(), start=1):
        stripped = line.strip()
        if stripped.startswith(("import ", "part ")):
            violations.add(
                f"{_relative(COMPONENTS_BARREL)}:{line_number}: "
                "components.dart must remain an export-only barrel"
            )

    for source in sorted(COMPONENTS_DIR.glob("*.dart")):
        if source == COMPONENTS_BARREL:
            continue
        text = source.read_text(encoding="utf-8")
        if COMPONENTS_PART_OF_RE.search(text):
            violations.add(
                f"{_relative(source)}: component files must not use "
                "part of components.dart"
            )
        for match in IMPORT_RE.finditer(text):
            target = _resolve_import(source, match.group(1))
            if target == COMPONENTS_BARREL:
                violations.add(
                    f"{_relative(source)}: component files must not import "
                    "components.dart"
                )

    return violations


def _scan_app_import_violations(directory: Path, label: str) -> set[str]:
    violations = set()

    for source in sorted(directory.rglob("*.dart")):
        text = source.read_text(encoding="utf-8")
        uses_app_singleton = APP_SINGLETON_RE.search(text) is not None
        for match in IMPORT_RE.finditer(text):
            target = _resolve_import(source, match.group(1))
            if target != FOUNDATION_APP_PATH or uses_app_singleton:
                continue
            violations.add(
                f"{_relative(source)}: {label} files should import "
                "foundation/context.dart and foundation/widget_utils.dart "
                "directly unless they use App"
            )

    return violations


def _scan_component_app_import_violations() -> set[str]:
    return _scan_app_import_violations(COMPONENTS_DIR, "component")


def _scan_foundation_app_reexport_violations() -> set[str]:
    violations = set()
    text = FOUNDATION_APP_PATH.read_text(encoding="utf-8")
    forbidden_exports = {
        FOUNDATION_CONTEXT_PATH: "foundation/context.dart",
        FOUNDATION_WIDGET_UTILS_PATH: "foundation/widget_utils.dart",
    }

    for match in EXPORT_RE.finditer(text):
        target = _resolve_import(FOUNDATION_APP_PATH, match.group(1))
        if target in forbidden_exports:
            violations.add(
                f"{_relative(FOUNDATION_APP_PATH)}: foundation/app.dart must "
                f"not re-export {forbidden_exports[target]}"
            )

    return violations


def _scan_component_ui_import_violations() -> set[str]:
    violations = set()

    for source in sorted(COMPONENTS_DIR.glob("*.dart")):
        text = source.read_text(encoding="utf-8")
        imports = {
            _resolve_import(source, match.group(1))
            for match in IMPORT_RE.finditer(text)
        }
        if (
            CONTEXT_EXTENSION_RE.search(text)
            and FOUNDATION_CONTEXT_PATH not in imports
        ):
            violations.add(
                f"{_relative(source)}: components using BuildContext UI "
                "extensions must import foundation/context.dart directly"
            )
        if (
            WIDGET_UTILS_RE.search(text)
            and FOUNDATION_WIDGET_UTILS_PATH not in imports
        ):
            violations.add(
                f"{_relative(source)}: components using Widget/TextStyle/Color "
                "helpers must import foundation/widget_utils.dart directly"
            )

    return violations


def _scan_comic_source_app_import_violations() -> set[str]:
    return _scan_app_import_violations(
        _feature_path("comic_source"),
        "comic_source",
    )


def _scan_comic_details_app_import_violations() -> set[str]:
    return _scan_app_import_violations(
        _feature_path("comic_details"),
        "comic_details",
    )


def _scan_discovery_app_import_violations() -> set[str]:
    return _scan_app_import_violations(_feature_path("discovery"), "discovery")


def _scan_history_app_import_violations() -> set[str]:
    return _scan_app_import_violations(_feature_path("history"), "history")


def _scan_local_comics_app_import_violations() -> set[str]:
    return _scan_app_import_violations(
        _feature_path("local_comics"),
        "local_comics",
    )


def _scan_reader_app_import_violations() -> set[str]:
    return _scan_app_import_violations(_feature_path("reader"), "reader")


def _scan_search_app_import_violations() -> set[str]:
    return _scan_app_import_violations(_feature_path("search"), "search")


def _scan_settings_app_import_violations() -> set[str]:
    return _scan_app_import_violations(_feature_path("settings"), "settings")


def _scan_sync_app_import_violations() -> set[str]:
    return _scan_app_import_violations(_feature_path("sync"), "sync")


def _scan_foundation_barrel_violations() -> set[str]:
    violations = set()

    text = FOUNDATION_EXTENSIONS_BARREL.read_text(encoding="utf-8")
    for line_number, line in enumerate(text.splitlines(), start=1):
        stripped = line.strip()
        if stripped.startswith(("import ", "part ")):
            violations.add(
                f"{_relative(FOUNDATION_EXTENSIONS_BARREL)}:{line_number}: "
                "extensions.dart must remain an export-only barrel"
            )

    return violations


def _scan_entrypoint_violations(entrypoint_targets: dict[Path, Path]) -> set[str]:
    violations = set()
    for source in sorted(LIB_DIR.rglob("*.dart")):
        source = source.resolve()
        text = source.read_text(encoding="utf-8")
        for match in IMPORT_RE.finditer(text):
            target = _resolve_import(source, match.group(1))
            if target is None:
                continue
            public_entrypoint = entrypoint_targets.get(target)
            if public_entrypoint is None:
                continue
            if source == public_entrypoint:
                continue
            if _module(source) == _module(target):
                continue
            violations.add(
                f"{_relative(source)} -> {_relative(target)} "
                f"(use {_relative(public_entrypoint)})"
            )
    return violations


def _scan_feature_entrypoint_violations() -> set[str]:
    return _scan_entrypoint_violations(FEATURE_ENTRYPOINT_TARGETS)


def _scan_app_shell_entrypoint_violations() -> set[str]:
    return _scan_entrypoint_violations(APP_SHELL_ENTRYPOINT_TARGETS)


def _scan_app_runtime_entrypoint_violations() -> set[str]:
    return _scan_entrypoint_violations(APP_RUNTIME_ENTRYPOINT_TARGETS)


def _scan_foundation_entrypoint_violations() -> set[str]:
    return _scan_entrypoint_violations(FOUNDATION_ENTRYPOINT_TARGETS)


def _scan_file_system_import_violations() -> set[str]:
    violations = set()
    for source in sorted(LIB_DIR.rglob("*.dart")):
        source = source.resolve()
        if (
            _module(source) != "foundation"
            and source not in FILE_SYSTEM_DIRECT_IMPORT_SOURCES
        ):
            continue
        text = source.read_text(encoding="utf-8")
        for match in IMPORT_RE.finditer(text):
            target = _resolve_import(source, match.group(1))
            if target == UTILS_IO_PATH:
                violations.add(
                    f"{_relative(source)} -> {_relative(UTILS_IO_PATH)} "
                    f"(use {_relative(FILE_SYSTEM_ENTRYPOINT_PATH)})"
                )
    return violations


def main() -> None:
    parser = argparse.ArgumentParser(
        description="Check import boundaries for lib/ structure."
    )
    parser.add_argument(
        "--print-baseline",
        action="store_true",
        help="Print the current restricted imports.",
    )
    args = parser.parse_args()

    restricted_imports = _scan_restricted_imports()
    if args.print_baseline:
        for item in sorted(restricted_imports):
            print(item)
        return

    component_barrel_violations = _scan_component_barrel_violations()
    component_app_import_violations = _scan_component_app_import_violations()
    foundation_app_reexport_violations = _scan_foundation_app_reexport_violations()
    component_ui_import_violations = _scan_component_ui_import_violations()
    comic_source_app_import_violations = _scan_comic_source_app_import_violations()
    comic_details_app_import_violations = _scan_comic_details_app_import_violations()
    discovery_app_import_violations = _scan_discovery_app_import_violations()
    history_app_import_violations = _scan_history_app_import_violations()
    local_comics_app_import_violations = _scan_local_comics_app_import_violations()
    reader_app_import_violations = _scan_reader_app_import_violations()
    search_app_import_violations = _scan_search_app_import_violations()
    settings_app_import_violations = _scan_settings_app_import_violations()
    sync_app_import_violations = _scan_sync_app_import_violations()
    foundation_barrel_violations = _scan_foundation_barrel_violations()
    feature_entrypoint_violations = _scan_feature_entrypoint_violations()
    app_shell_entrypoint_violations = _scan_app_shell_entrypoint_violations()
    app_runtime_entrypoint_violations = _scan_app_runtime_entrypoint_violations()
    foundation_entrypoint_violations = _scan_foundation_entrypoint_violations()
    file_system_import_violations = _scan_file_system_import_violations()
    retired_pages_violations = _scan_retired_pages_violations()
    retired_dart_path_violations = _scan_retired_dart_path_violations()
    retired_dart_dir_violations = _scan_retired_dart_dir_violations()
    retired_part_violations = _scan_retired_part_violations()

    if (
        restricted_imports
        or component_barrel_violations
        or component_app_import_violations
        or foundation_app_reexport_violations
        or component_ui_import_violations
        or comic_source_app_import_violations
        or comic_details_app_import_violations
        or discovery_app_import_violations
        or history_app_import_violations
        or local_comics_app_import_violations
        or reader_app_import_violations
        or search_app_import_violations
        or settings_app_import_violations
        or sync_app_import_violations
        or foundation_barrel_violations
        or feature_entrypoint_violations
        or app_shell_entrypoint_violations
        or app_runtime_entrypoint_violations
        or foundation_entrypoint_violations
        or file_system_import_violations
        or retired_pages_violations
        or retired_dart_path_violations
        or retired_dart_dir_violations
        or retired_part_violations
    ):
        if restricted_imports:
            print("Restricted imports:")
            for item in sorted(restricted_imports):
                print(f"  {item}")
        if retired_pages_violations:
            print("Retired pages directory violations:")
            for item in sorted(retired_pages_violations):
                print(f"  {item}")
        if retired_dart_path_violations:
            print("Retired Dart path violations:")
            for item in sorted(retired_dart_path_violations):
                print(f"  {item}")
        if retired_dart_dir_violations:
            print("Retired Dart directory violations:")
            for item in sorted(retired_dart_dir_violations):
                print(f"  {item}")
        if retired_part_violations:
            print("Retired part violations:")
            for item in sorted(retired_part_violations):
                print(f"  {item}")
        if component_barrel_violations:
            print("Component barrel violations:")
            for item in sorted(component_barrel_violations):
                print(f"  {item}")
        if component_app_import_violations:
            print("Component App import violations:")
            for item in sorted(component_app_import_violations):
                print(f"  {item}")
        if foundation_app_reexport_violations:
            print("Foundation App re-export violations:")
            for item in sorted(foundation_app_reexport_violations):
                print(f"  {item}")
        if component_ui_import_violations:
            print("Component UI import violations:")
            for item in sorted(component_ui_import_violations):
                print(f"  {item}")
        if comic_source_app_import_violations:
            print("Comic source App import violations:")
            for item in sorted(comic_source_app_import_violations):
                print(f"  {item}")
        if comic_details_app_import_violations:
            print("Comic details App import violations:")
            for item in sorted(comic_details_app_import_violations):
                print(f"  {item}")
        if discovery_app_import_violations:
            print("Discovery App import violations:")
            for item in sorted(discovery_app_import_violations):
                print(f"  {item}")
        if history_app_import_violations:
            print("History App import violations:")
            for item in sorted(history_app_import_violations):
                print(f"  {item}")
        if local_comics_app_import_violations:
            print("Local comics App import violations:")
            for item in sorted(local_comics_app_import_violations):
                print(f"  {item}")
        if reader_app_import_violations:
            print("Reader App import violations:")
            for item in sorted(reader_app_import_violations):
                print(f"  {item}")
        if search_app_import_violations:
            print("Search App import violations:")
            for item in sorted(search_app_import_violations):
                print(f"  {item}")
        if settings_app_import_violations:
            print("Settings App import violations:")
            for item in sorted(settings_app_import_violations):
                print(f"  {item}")
        if sync_app_import_violations:
            print("Sync App import violations:")
            for item in sorted(sync_app_import_violations):
                print(f"  {item}")
        if foundation_barrel_violations:
            print("Foundation barrel violations:")
            for item in sorted(foundation_barrel_violations):
                print(f"  {item}")
        if feature_entrypoint_violations:
            print("Feature entrypoint violations:")
            for item in sorted(feature_entrypoint_violations):
                print(f"  {item}")
        if app_shell_entrypoint_violations:
            print("App shell entrypoint violations:")
            for item in sorted(app_shell_entrypoint_violations):
                print(f"  {item}")
        if app_runtime_entrypoint_violations:
            print("App runtime entrypoint violations:")
            for item in sorted(app_runtime_entrypoint_violations):
                print(f"  {item}")
        if foundation_entrypoint_violations:
            print("Foundation entrypoint violations:")
            for item in sorted(foundation_entrypoint_violations):
                print(f"  {item}")
        if file_system_import_violations:
            print("File system entrypoint violations:")
            for item in sorted(file_system_import_violations):
                print(f"  {item}")
        raise SystemExit(1)

    print("Structure import boundaries are clean.")


if __name__ == "__main__":
    main()
