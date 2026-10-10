import importlib.util
import contextlib
import io
import json
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch


SPEC = importlib.util.spec_from_file_location(
    "architecture_dependencies",
    Path(__file__).resolve().parents[1] / "check_architecture_dependencies.py",
)
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)


class ArchitectureDependenciesTest(unittest.TestCase):
    def test_retired_global_dependencies_cannot_return_in_new_adapters(self):
        with tempfile.TemporaryDirectory() as directory:
            lib = Path(directory)
            source = lib / 'adapter.dart'
            for code in (
                'bool debugSkipComicSourceInit = false;',
                'void resetForTesting() {}',
                'static ImageLoader? debugLoadComicImageUnwrapped;',
                'void debugResetSourceImageLoading() {}',
                'Dio Function()? debugCreateDio;',
                'factory LocalManager.forTesting() => manager;',
                'SourceRepositories.forTesting({Dio? client});',
                'static void resetOps() {}',
                'static HistoryManager? cache;',
                'static LocalFavoritesManager? cache = manager;',
                'HistoryManager.cache = next;',
                'LocalFavoritesManager . cache = next;',
                'static set cache(HistoryManager? next) {}',
            ):
                with self.subTest(code=code):
                    source.write_text(code, encoding='utf-8')
                    self.assertEqual(MODULE.retired_dependency_violations(lib), [
                        'Retired global dependency hook: adapter.dart'])

    def test_backup_dependencies_are_instance_owned(self):
        with tempfile.TemporaryDirectory() as directory:
            lib = Path(directory)
            source = lib / 'features/sync/comic_backup.dart'
            source.parent.mkdir(parents=True)
            for code in (
                'static ComicBackupWebDavOps ops = WebDavComicBackupOps();',
                'static Future<void> Function(LocalComic, String)?\nexportComic;',
                'static Future<LocalComic> Function(String)? importComic;',
                'static Future<void> Function(LocalComic)? registerImportedComic;',
            ):
                with self.subTest(code=code):
                    source.write_text(code, encoding='utf-8')
                    self.assertEqual(MODULE.retired_dependency_violations(lib), [
                        'Retired global dependency hook: features/sync/comic_backup.dart'])
            source.write_text('''
                static final instance = ComicBackupManager();
                final Future<void> Function(LocalComic, String) exportComic;
                ComicBackupManager({required this.exportComic});
            ''', encoding='utf-8')
            self.assertEqual(MODULE.retired_dependency_violations(lib), [])

    def test_retirement_gate_keeps_diagnostics_injection_and_examples(self):
        with tempfile.TemporaryDirectory() as directory:
            lib = Path(directory)
            (lib / 'owner.dart').write_text('''
                // resetForTesting was retired.
                const example = "SourceRepositories.forTesting()";
                factory LocalManager.independent({required Database db});
                int get debugActiveLoadCount => active.length;
                String validateForTesting(String input) => validate(input);
                static HistoryManager? get cache => _cache;
                final sameStore = HistoryManager.cache == manager;
            ''', encoding='utf-8')
            self.assertEqual(MODULE.retired_dependency_violations(lib), [])

    def test_command_rejects_retired_hook_with_valid_dependency_inventory(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / 'lib').mkdir()
            (root / 'lib/owner.dart').write_text(
                'void resetForTesting() {}', encoding='utf-8')
            baseline = root / 'baseline.json'
            baseline.write_text(json.dumps(self.classified(business=['owner.dart'])),
                                encoding='utf-8')
            output = io.StringIO()
            with patch.multiple(MODULE, ROOT=root, BASELINE=baseline), \
                    patch('sys.argv', ['check_architecture_dependencies.py']), \
                    contextlib.redirect_stdout(output):
                self.assertTrue(MODULE.main())
            self.assertIn('Retired global dependency hook: owner.dart', output.getvalue())

    def test_image_processing_and_webview_consumers_keep_typed_preferences(self):
        with tempfile.TemporaryDirectory() as directory:
            lib = Path(directory)
            for name, keys in {
                'foundation/image_provider/reader_image.dart': ['enableCustomImageProcessing', 'customImageProcessing'],
                'features/settings/reader.dart': ['enableCustomImageProcessing', 'customImageProcessing'],
                'routing/webview.dart': ['proxy'],
            }.items():
                source = lib / name
                source.parent.mkdir(parents=True, exist_ok=True)
                for key in keys:
                    source.write_text(f"final value = appdata.settings['{key}'];", encoding='utf-8')
                    self.assertEqual(MODULE.application_settings_violations(lib), [
                        f'Use typed application preferences: {name} ({key})'])
                source.write_text('final value = store.read(preference);', encoding='utf-8')
                self.assertEqual(MODULE.application_settings_violations(lib), [])

    def test_discovery_consumers_cannot_restore_literal_setting_reads(self):
        with tempfile.TemporaryDirectory() as directory:
            lib = Path(directory)
            for name, key in [
                ('features/discovery/explore_page.dart', 'explore_pages'),
                ('features/discovery/categories_page.dart', 'categories'),
                ('features/favorites/side_bar.dart', 'favorites'),
                ('features/search/search_page.dart', 'defaultSearchTarget'),
                ('features/search/aggregated_search_page.dart', 'searchSources'),
                ('features/search/search_result_page.dart', 'searchSources'),
            ]:
                source = lib / name
                source.parent.mkdir(parents=True, exist_ok=True)
                source.write_text(f"final value = appdata.settings['{key}'];", encoding='utf-8')
                self.assertIn(f'Use typed application preferences: {name} ({key})',
                              MODULE.application_settings_violations(lib))
                source.write_text('final value = store.read(preference);', encoding='utf-8')
                self.assertEqual(MODULE.application_settings_violations(lib), [])

    def test_discovery_forms_cannot_restore_untyped_constructor_keys(self):
        with tempfile.TemporaryDirectory() as directory:
            lib = Path(directory)
            source = lib / 'features/settings/explore_settings.dart'
            source.parent.mkdir(parents=True)
            for parameter, key in [('settingKey', 'defaultSearchTarget'),
                                   ('settingsIndex', 'searchSources')]:
                source.write_text(f"Form({parameter}: '{key}');", encoding='utf-8')
                self.assertEqual(MODULE.application_settings_violations(lib), [
                    f'Use typed application preferences: features/settings/explore_settings.dart ({key})'])

    def test_typed_discovery_guard_keeps_unmigrated_fields_and_comments(self):
        with tempfile.TemporaryDirectory() as directory:
            lib = Path(directory)
            source = lib / 'features/settings/explore_settings.dart'
            source.parent.mkdir(parents=True)
            source.write_text("""
                // Form(settingsIndex: 'searchSources');
                Form(preference: DiscoveryPreferences.searchSources);
                Form(settingKey: 'enableClock');
            """, encoding='utf-8')
            self.assertEqual(MODULE.application_settings_violations(lib), [])

    def test_display_consumers_cannot_restore_untyped_reads(self):
        with tempfile.TemporaryDirectory() as directory:
            lib = Path(directory)
            for name, keys in {
                'app_shell/main_page.dart': ['initialPage'],
                'app_runtime/init.dart': ['showFavoriteStatusOnTile', 'showHistoryStatusOnTile', 'showUpdateStatusOnTile'],
                'components/layout.dart': ['comicDisplayMode', 'comicTileScale'],
                'features/comic_widgets/comic_tile.dart': ['comicDisplayMode'],
                'features/comic_widgets/comic_list.dart': ['comicListDisplayMode'],
                'features/favorites/favorite_models.dart': ['comicDisplayMode'],
                'features/search/search_result_page.dart': ['autoAddLanguageFilter'],
            }.items():
                source = lib / name
                source.parent.mkdir(parents=True, exist_ok=True)
                for key in keys:
                    source.write_text(f'final value = appdata.settings["{key}"];', encoding='utf-8')
                    self.assertEqual(MODULE.application_settings_violations(lib), [
                        f'Use typed application preferences: {name} ({key})'])
                source.write_text('final value = store.read(preference);', encoding='utf-8')
                self.assertEqual(MODULE.application_settings_violations(lib), [])

    def test_discovery_display_forms_require_typed_preferences(self):
        with tempfile.TemporaryDirectory() as directory:
            lib = Path(directory)
            source = lib / 'features/settings/explore_settings.dart'
            source.parent.mkdir(parents=True)
            for key in ['comicDisplayMode', 'comicTileScale', 'showFavoriteStatusOnTile',
                        'showHistoryStatusOnTile', 'showUpdateStatusOnTile',
                        'autoAddLanguageFilter', 'initialPage', 'comicListDisplayMode',
                        'reverseChapterOrder']:
                source.write_text(f"Form(settingKey: '{key}');", encoding='utf-8')
                self.assertEqual(MODULE.application_settings_violations(lib), [
                    f'Use typed application preferences: features/settings/explore_settings.dart ({key})'])

    def classified(self, *, business=(), ui=(), pending=(), roots=()):
        return {'allowed_feature_edges': [], 'business_entrypoints': list(roots),
                'business_files': list(business), 'ui_files': list(ui),
                'pending_review_files': list(pending)}

    def test_disconnected_new_file_needs_an_explicit_classification(self):
        graph = {'service.dart': set(), 'new_page.dart': set()}
        baseline = self.classified(business=['service.dart'])
        self.assertEqual(MODULE.classification_violations(graph, baseline), [
            'Unclassified library file: new_page.dart'])

    def test_file_inventory_is_mandatory_even_without_business_roots(self):
        self.assertEqual(MODULE.classification_violations({}, {
            'allowed_feature_edges': []}), [
            'Missing file classification: business_files',
            'Missing file classification: ui_files',
            'Missing file classification: pending_review_files'])

    def test_unreferenced_business_file_cannot_import_ui(self):
        graph = {'service.dart': {'adapter.dart'}, 'adapter.dart': {'page.dart'},
                 'page.dart': set()}
        baseline = self.classified(business=['service.dart', 'adapter.dart'],
                                   ui=['page.dart'])
        errors = MODULE.violations(graph, baseline)
        self.assertIn('Business file reaches UI: service.dart -> page.dart', errors)
        self.assertIn('Business file reaches UI: adapter.dart -> page.dart', errors)

    def test_pending_review_is_not_a_business_dependency_exception(self):
        graph = {'service.dart': {'mixed.dart'}, 'mixed.dart': set()}
        baseline = self.classified(business=['service.dart'], pending=['mixed.dart'])
        self.assertEqual(MODULE.violations(graph, baseline), [
            'Business file reaches pending review: service.dart -> mixed.dart'])

    def test_removing_a_root_does_not_disable_its_dependency_cycle_check(self):
        graph = {'service.dart': {'codec.dart'}, 'codec.dart': {'service.dart'}}
        baseline = self.classified(business=graph)
        self.assertEqual(MODULE.violations(graph, baseline), [
            'Business dependency cycle: codec.dart, service.dart'])

    def test_file_inventory_rejects_stale_duplicate_and_conflicting_roles(self):
        graph = {'service.dart': set(), 'page.dart': set()}
        baseline = self.classified(business=['service.dart', 'service.dart', 'gone.dart'],
                                   ui=['service.dart', 'page.dart'])
        self.assertEqual(MODULE.classification_violations(graph, baseline), [
            'Duplicate file classification in business_files: service.dart',
            'Missing classified library file: gone.dart',
            'Conflicting file classification: service.dart (business_files, ui_files)'])

    def test_entrypoint_and_cycle_protection_cannot_be_reclassified_as_ui(self):
        graph = {'api.dart': set(), 'owner.dart': set()}
        baseline = self.classified(ui=graph, roots=['api.dart'])
        baseline['acyclic_business_files'] = ['owner.dart']
        self.assertEqual(MODULE.classification_violations(graph, baseline), [
            'Business protection requires business classification: api.dart',
            'Business protection requires business classification: owner.dart'])

    def test_native_adapters_and_ui_only_cycles_remain_allowed(self):
        graph = {'native.dart': {'codec.dart'}, 'codec.dart': set(),
                 'page.dart': {'route.dart'}, 'route.dart': {'page.dart'}}
        baseline = self.classified(business=['native.dart', 'codec.dart'],
                                   ui=['page.dart', 'route.dart'])
        self.assertEqual(MODULE.classification_violations(graph, baseline), [])
        self.assertEqual(MODULE.violations(graph, baseline), [])

    def test_conditional_export_to_pending_review_is_rejected(self):
        with tempfile.TemporaryDirectory() as directory:
            lib = Path(directory)
            (lib / 'service.dart').write_text(
                "export 'stub.dart' if (dart.library.io) 'mixed.dart';", encoding='utf-8')
            (lib / 'stub.dart').write_text('', encoding='utf-8')
            (lib / 'mixed.dart').write_text('', encoding='utf-8')
            baseline = self.classified(business=['service.dart', 'stub.dart'],
                                       pending=['mixed.dart'])
            self.assertEqual(MODULE.violations(MODULE.graph_for(lib), baseline), [
                'Business file reaches pending review: service.dart -> mixed.dart'])

    def test_command_rejects_a_new_file_even_with_no_imports(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / 'lib').mkdir()
            (root / 'lib/new.dart').write_text('', encoding='utf-8')
            baseline = root / 'baseline.json'
            baseline.write_text(json.dumps(self.classified()), encoding='utf-8')
            output = io.StringIO()
            with patch.multiple(MODULE, ROOT=root, BASELINE=baseline), \
                    patch('sys.argv', ['check_architecture_dependencies.py']), \
                    contextlib.redirect_stdout(output):
                self.assertTrue(MODULE.main())
            self.assertIn('Unclassified library file: new.dart', output.getvalue())

    def test_command_reports_invalid_inventory_without_evaluating_dependencies(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / 'lib').mkdir()
            baseline = root / 'baseline.json'
            data = self.classified()
            data['business_files'] = None
            data['ui_files'] = 'page.dart'
            baseline.write_text(json.dumps(data), encoding='utf-8')
            output = io.StringIO()
            with patch.multiple(MODULE, ROOT=root, BASELINE=baseline), \
                    patch('sys.argv', ['check_architecture_dependencies.py', '--report']), \
                    contextlib.redirect_stdout(output):
                self.assertTrue(MODULE.main())
            self.assertIn('Missing file classification: business_files', output.getvalue())
            self.assertIn('File classification must be a list of paths: ui_files', output.getvalue())

    def test_conditional_directives_and_comments(self):
        text = """
        // import 'fake.dart';
        /* export 'fake2.dart'; */
        import 'stub.dart' if (dart.library.io) 'native.dart';
        export 'a.dart' if (dart.library.html) 'b.dart';
        part 'child.dart';
        part of 'parent.dart';
        """
        self.assertEqual(list(MODULE.directives(text)),
                         ['stub.dart', 'native.dart', 'a.dart', 'b.dart', 'child.dart'])

    def test_relative_package_and_part_resolution(self):
        with tempfile.TemporaryDirectory() as directory:
            lib = Path(directory)
            (lib / 'a.dart').write_text(
                "import 'package:venera_next/b.dart'; part 'c.dart';", encoding='utf-8')
            (lib / 'b.dart').write_text("export 'c.dart';", encoding='utf-8')
            (lib / 'c.dart').write_text("part of 'a.dart';", encoding='utf-8')
            self.assertEqual(MODULE.graph_for(lib), {
                'a.dart': {'b.dart', 'c.dart'}, 'b.dart': {'c.dart'}, 'c.dart': set()})

    def test_directive_text_inside_string_is_not_a_dependency(self):
        self.assertEqual(list(MODULE.directives(
            '''const example = "import 'fake.dart';"; import 'real.dart';''')),
            ['real.dart'])

    def test_transitive_ui_dependency_is_rejected(self):
        graph = {'api.dart': {'barrel.dart'}, 'barrel.dart': {'page.dart'}, 'page.dart': set()}
        baseline = {'allowed_feature_edges': [], 'business_entrypoints': ['api.dart'],
                    'ui_files': ['page.dart']}
        self.assertEqual(MODULE.violations(graph, baseline),
                         ['Business entry point reaches UI: api.dart -> page.dart'])

    def test_new_edge_is_rejected_but_existing_edge_is_allowed(self):
        graph = {'features/a/a.dart': {'features/b/b.dart', 'features/c/c.dart'}}
        self.assertEqual(MODULE.violations(graph, {'allowed_feature_edges': [['a', 'b']]}),
                         ['New feature dependency: a -> c'])

    def test_cycles_group_overlapping_loops(self):
        self.assertEqual(MODULE.cycles({('a', 'b'), ('b', 'a'), ('b', 'c'),
                                        ('c', 'b'), ('d', 'e')}), [['a', 'b', 'c']])

    def test_debug_certificate_field_uses_the_existing_network_preference(self):
        with tempfile.TemporaryDirectory() as directory:
            lib = Path(directory)
            form = lib / 'features/settings/debug.dart'
            form.parent.mkdir(parents=True)
            for code in ["SwitchSetting(settingKey: 'ignoreBadCertificate')",
                         'appdata.settings["ignoreBadCertificate"] = true']:
                form.write_text(code, encoding='utf-8')
                self.assertEqual(MODULE.application_settings_violations(lib), [
                    'Use typed application preferences: features/settings/debug.dart (ignoreBadCertificate)'])
            form.write_text('SwitchSetting.preference(preference: NetworkPreferences.ignoreBadCertificate)', encoding='utf-8')
            self.assertEqual(MODULE.application_settings_violations(lib), [])

    def test_keyword_form_rejects_raw_keys_behind_getters_and_local_variables(self):
        with tempfile.TemporaryDirectory() as directory:
            lib = Path(directory)
            form = lib / 'features/settings/keyword_blocking.dart'
            form.parent.mkdir(parents=True)
            for key in ['blockedWords', 'blockedCommentWords']:
                for code in [f"String get key => '{key}';",
                             f'final key = "{key}"; draft[key] = words;']:
                    form.write_text(code, encoding='utf-8')
                    self.assertEqual(MODULE.application_settings_violations(lib), [
                        f'Use typed application preferences: features/settings/keyword_blocking.dart ({key})'])

    def test_keyword_consumers_reject_raw_keys_in_reads_and_aliases(self):
        for name, key in [
            ('features/comic_widgets/comic_list.dart', 'blockedWords'),
            ('features/comic_widgets/comic_tile.dart', 'blockedWords'),
            ('features/comic_details/comments_page.dart', 'blockedCommentWords'),
            ('features/reader/chapter_comments.dart', 'blockedCommentWords'),
            ('foundation/keyword_settings_store.dart', 'blockedWords'),
        ]:
            with self.subTest(name=name), tempfile.TemporaryDirectory() as directory:
                lib = Path(directory)
                source = lib / name
                source.parent.mkdir(parents=True)
                for code in [f"appdata.settings['{key}']", f"final key = '{key}'; draft[key] = words;"]:
                    source.write_text(code, encoding='utf-8')
                    self.assertEqual(MODULE.application_settings_violations(lib), [
                        f'Use typed application preferences: {name} ({key})'])

    def test_favorite_consumers_reject_raw_keys_in_reads_forms_and_aliases(self):
        for name, key in [
            ('app_runtime/init.dart', 'favoritesDisplayMode'),
            ('app_runtime/headless.dart', 'followUpdatesFolder'),
            ('app_runtime/follow_updates.dart', 'followUpdatesFolder'),
            ('features/favorites/favorites_display.dart', 'favoritesGalleryColumns'),
            ('features/favorites/favorites_manager.dart', 'moveFavoriteAfterRead'),
            ('features/favorites/local_favorites_page.dart', 'onClickFavorite'),
            ('features/favorites/favorite_actions.dart', 'quickFavorite'),
            ('features/settings/local_favorites.dart', 'localFavoritesFirst'),
            ('features/comic_details/actions.dart', 'quickFavorite'),
            ('features/comic_details/favorite.dart', 'autoCloseFavoritePanel'),
            ('features/follow_updates/follow_updates_page.dart', 'followUpdatesFolder'),
            ('features/follow_updates/follow_updates_folder_dialog.dart', 'followUpdatesFolder'),
            ('features/sync/pica_import.dart', 'newFavoriteAddTo'),
        ]:
            with self.subTest(name=name), tempfile.TemporaryDirectory() as directory:
                lib = Path(directory)
                source = lib / name
                source.parent.mkdir(parents=True)
                for code in [f"appdata.settings['{key}']", f"const key = '{key}';",
                             f"SwitchSetting(settingKey: '{key}')"]:
                    source.write_text(code, encoding='utf-8')
                    self.assertEqual(MODULE.application_settings_violations(lib), [
                        f'Use typed application preferences: {name} ({key})'])

    def test_favorite_recovery_can_keep_raw_values_under_canonical_keys(self):
        with tempfile.TemporaryDirectory() as directory:
            lib = Path(directory)
            source = lib / 'features/favorites/favorites_manager.dart'
            source.parent.mkdir(parents=True)
            source.write_text('''
                final previous = appdata.settings[FavoritePreferences.quickFavorite.key];
                draft[FavoritePreferences.followUpdatesFolder.key] = originalRawValue;
            ''', encoding='utf-8')
            self.assertEqual(MODULE.application_settings_violations(lib), [])

    def test_keyword_preferences_own_keys_and_consumers_use_typed_target(self):
        with tempfile.TemporaryDirectory() as directory:
            lib = Path(directory)
            folder = lib / 'features/settings'
            folder.mkdir(parents=True)
            (folder / 'keyword_blocking.dart').write_text(
                "// old 'blockedWords' key\nstore.read(BlockedKeywordList.comics);",
                encoding='utf-8')
            foundation = lib / 'foundation'
            foundation.mkdir()
            (foundation / 'keyword_settings_store.dart').write_text(
                "enum BlockedKeywordList { comics(KeywordPreferences.comics), comments(KeywordPreferences.comments) }",
                encoding='utf-8')
            (foundation / 'application_preferences.dart').write_text(
                "const comics = StringListPreference('blockedWords');",
                encoding='utf-8')
            self.assertEqual(MODULE.application_settings_violations(lib), [])

    def test_enrolled_business_file_cannot_reenter_through_an_adapter(self):
        graph = {'owner.dart': {'codec.dart'}, 'codec.dart': {'task.dart'},
                 'task.dart': {'owner.dart'}}
        baseline = {'allowed_feature_edges': [],
                    'acyclic_business_files': ['owner.dart']}
        self.assertEqual(MODULE.violations(graph, baseline), [
            'Business dependency cycle: codec.dart, owner.dart, task.dart'])
        graph['task.dart'] = {'contract.dart'}
        graph['contract.dart'] = set()
        self.assertEqual(MODULE.violations(graph, baseline), [])

    def test_unrelated_reachable_cycle_does_not_enroll_its_caller(self):
        graph = {'owner.dart': {'first.dart'}, 'first.dart': {'second.dart'},
                 'second.dart': {'first.dart'}}
        baseline = {'allowed_feature_edges': [],
                    'acyclic_business_files': ['owner.dart']}
        self.assertEqual(MODULE.violations(graph, baseline), [])
        graph['owner.dart'].add('owner.dart')
        self.assertEqual(MODULE.violations(graph, baseline), [
            'Business dependency cycle: owner.dart'])

    def test_deleted_cycle_enrollment_is_not_silently_ignored(self):
        self.assertEqual(MODULE.violations({}, {
            'allowed_feature_edges': [], 'acyclic_business_files': ['gone.dart']
        }), ['Missing acyclic business file: gone.dart'])

    def test_business_roots_cannot_reach_unenrolled_cycles(self):
        graph = {'api.dart': {'adapter.dart'}, 'other_api.dart': {'adapter.dart'},
                 'adapter.dart': {'codec.dart'}, 'codec.dart': {'adapter.dart'},
                 'page.dart': {'widget.dart'}, 'widget.dart': {'page.dart'}}
        baseline = {'allowed_feature_edges': [],
                    'business_entrypoints': ['api.dart', 'other_api.dart'],
                    'ui_files': ['page.dart', 'widget.dart']}
        self.assertEqual(MODULE.violations(graph, baseline), [
            'Business dependency cycle: adapter.dart, codec.dart'])
        graph['codec.dart'] = set()
        # The unrelated UI cycle remains outside the business boundary.
        self.assertEqual(MODULE.violations(graph, baseline), [])

    def test_conditional_business_export_cannot_reach_a_self_cycle(self):
        with tempfile.TemporaryDirectory() as directory:
            lib = Path(directory)
            (lib / 'api.dart').write_text(
                "export 'stub.dart' if (dart.library.io) 'native.dart';", encoding='utf-8')
            (lib / 'stub.dart').write_text('', encoding='utf-8')
            (lib / 'native.dart').write_text("import 'native.dart';", encoding='utf-8')
            self.assertEqual(MODULE.violations(MODULE.graph_for(lib), {
                'allowed_feature_edges': [], 'business_entrypoints': ['api.dart']
            }), ['Business dependency cycle: native.dart'])

    def test_missing_business_entrypoint_is_rejected(self):
        self.assertEqual(MODULE.violations({}, {'allowed_feature_edges': [],
                         'business_entrypoints': ['missing.dart']}),
                         ['Missing business entry point: missing.dart'])

    def test_reader_cannot_reintroduce_dynamic_setting_calls(self):
        with tempfile.TemporaryDirectory() as directory:
            lib = Path(directory)
            reader = lib / 'features/reader'
            reader.mkdir(parents=True)
            source = reader / 'view.dart'
            source.write_text("final value = settings.getReaderSetting(id, key, 'mode');")
            self.assertEqual(MODULE.reader_settings_violations(lib),
                             ['Reader must use typed settings: features/reader/view.dart'])
            source.write_text("final value = reader.preferences.readerMode;")
            self.assertEqual(MODULE.reader_settings_violations(lib), [])

    def test_reader_form_writes_use_typed_preferences(self):
        with tempfile.TemporaryDirectory() as directory:
            lib = Path(directory)
            settings = lib / 'features/settings'
            settings.mkdir(parents=True)
            source = settings / 'reader.dart'
            source.write_text("settings.setActiveReaderSetting(id, source, 'key', value);")
            self.assertEqual(MODULE.reader_settings_violations(lib),
                             ['Reader must use typed settings: features/settings/reader.dart'])

    def test_application_gate_only_covers_migrated_preferences(self):
        with tempfile.TemporaryDirectory() as directory:
            lib = Path(directory)
            source = lib / 'main.dart'
            source.write_text("final color = appdata.settings['color']; final extension = appdata.settings['extensionField'];")
            self.assertEqual(MODULE.application_settings_violations(lib),
                             ['Use typed application preferences: main.dart (color)'])
            source.write_text("final color = store.appearance.color; final extension = appdata.settings['extensionField'];")
            self.assertEqual(MODULE.application_settings_violations(lib), [])

    def test_sync_configuration_rejects_raw_implicit_keys(self):
        with tempfile.TemporaryDirectory() as directory:
            lib = Path(directory)
            source = lib / 'features/sync/data_sync_controller.dart'
            source.parent.mkdir(parents=True)
            source.write_text("final mode = appdata.implicitData['webdavSyncMode'];")
            self.assertEqual(len(MODULE.application_settings_violations(lib)), 1)
            source.write_text("final mode = preferences.configuration.mode;")
            self.assertEqual(MODULE.application_settings_violations(lib), [])

    def test_application_behavior_consumers_reject_literal_reads_forms_and_aliases(self):
        for name, key in [
            ('main.dart', 'language'),
            ('foundation/app_locale.dart', 'language'),
            ('app_runtime/application_updates.dart', 'checkUpdateOnStart'),
            ('features/settings/about.dart', 'checkUpdateOnStart'),
            ('features/settings/app.dart', 'language'),
            ('features/settings/app.dart', 'historyRetentionDays'),
            ('features/settings/app_controls.dart', 'historyRetentionDays'),
            ('features/history/history_manager.dart', 'historyRetentionDays'),
        ]:
            with self.subTest(path=name, key=key), tempfile.TemporaryDirectory() as directory:
                lib = Path(directory)
                source = lib / name
                source.parent.mkdir(parents=True, exist_ok=True)
                for text in [f"final value = appdata.settings['{key}'];",
                             f"const key = '{key}'; final value = appdata.settings[key];",
                             f"Widget build() => Field(settingKey: '{key}');"]:
                    source.write_text(text, encoding='utf-8')
                    self.assertEqual(MODULE.application_settings_violations(lib), [
                        f'Use typed application preferences: {name} ({key})'])

    def test_current_sync_composition_rejects_raw_configuration(self):
        with tempfile.TemporaryDirectory() as directory:
            lib = Path(directory)
            source = lib / 'app_runtime/data_sync.dart'
            source.parent.mkdir(parents=True)
            source.write_text("final value = appdata.settings['webdav'];")
            self.assertEqual(MODULE.application_settings_violations(lib),
                             ['Use typed application preferences: app_runtime/data_sync.dart (webdav)'])
            source.write_text("final value = preferences.configuration;")
            self.assertEqual(MODULE.application_settings_violations(lib), [])

    def test_webdav_forms_reject_direct_configuration_reads(self):
        with tempfile.TemporaryDirectory() as directory:
            lib = Path(directory)
            source = lib / 'features/settings/webdav_settings.dart'
            source.parent.mkdir(parents=True)
            source.write_text("final value = appdata.settings['backupWebdavSyncEnabled'];")
            self.assertEqual(len(MODULE.application_settings_violations(lib)), 1)
            source.write_text("final value = BackupConfig.syncEnabled;")
            self.assertEqual(MODULE.application_settings_violations(lib), [])

    def test_headless_cannot_restore_interactive_initialization(self):
        with tempfile.TemporaryDirectory() as directory:
            lib = Path(directory)
            source = lib / 'app_runtime/headless.dart'
            source.parent.mkdir(parents=True)
            source.write_text("import 'init.dart';")
            self.assertEqual(len(MODULE.startup_violations(lib)), 1)
            source.write_text("import 'bootstrap_core.dart'; void run() { DataSync().start(); }")
            self.assertEqual(len(MODULE.startup_violations(lib)), 1)
            source.write_text("BackgroundSync.platform().start();")
            self.assertEqual(len(MODULE.startup_violations(lib)), 1)
            source.write_text("import 'bootstrap_core.dart'; void run() { bootstrapCore(); }")
            self.assertEqual(MODULE.startup_violations(lib), [])

    def test_core_cannot_access_the_interactive_navigation_namespace(self):
        with tempfile.TemporaryDirectory() as directory:
            lib = Path(directory)
            source = lib / 'app_runtime/bootstrap_core.dart'
            source.parent.mkdir(parents=True)
            source.write_text('final context = appNavigation.rootContext;')
            self.assertEqual(MODULE.startup_violations(lib), [
                'Core/headless startup activates interactive behavior: app_runtime/bootstrap_core.dart'])

    def test_headless_cannot_construct_platform_route_bindings(self):
        with tempfile.TemporaryDirectory() as directory:
            lib = Path(directory)
            source = lib / 'app_runtime/headless.dart'
            source.parent.mkdir(parents=True)
            source.write_text('final bindings = createPlatformInteractiveBindings();')
            self.assertEqual(MODULE.startup_violations(lib), [
                'Core/headless startup activates interactive behavior: app_runtime/headless.dart'])


if __name__ == '__main__':
    unittest.main()
