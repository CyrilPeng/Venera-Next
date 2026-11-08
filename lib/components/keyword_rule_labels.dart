import 'package:venera_next/foundation/keyword_rule.dart';
import 'package:venera_next/foundation/translations.dart';

extension KeywordModeLabel on KeywordMatchMode {
  String get label => switch (this) {
    KeywordMatchMode.contains => 'Contains text'.tl,
    KeywordMatchMode.wholeWord => 'Whole word'.tl,
    KeywordMatchMode.exactTag => 'Exact tag'.tl,
  };

  String get help => switch (this) {
    KeywordMatchMode.contains =>
      'Matches text anywhere in a title, subtitle or description. Tags must match exactly.'
          .tl,
    KeywordMatchMode.wholeWord =>
      'Spaces, punctuation, dots and underscores separate words. Chinese phrases usually work better with Contains text.'
          .tl,
    KeywordMatchMode.exactTag =>
      'Only matches a complete tag or its name after the namespace. Comics without tags will not match; titles are not checked.'
          .tl,
  };
}

extension KeywordFieldLabel on KeywordMatchField {
  String get label => switch (this) {
    KeywordMatchField.title => 'Title'.tl,
    KeywordMatchField.subtitle => 'Subtitle'.tl,
    KeywordMatchField.description => 'Description'.tl,
    KeywordMatchField.tag => 'Tag'.tl,
    KeywordMatchField.comment => 'Comment'.tl,
  };
}

String keywordRuleSummary(KeywordRule rule) =>
    '${rule.mode.label} · ${rule.caseSensitive ? 'Case sensitive'.tl : 'Ignore case'.tl}';
