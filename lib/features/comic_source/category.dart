import 'dart:math' as math;

import 'package:venera_next/foundation/js_engine.dart';

import 'models.dart';

typedef CategoryDataResolver = CategoryData Function(String key);

CategoryDataResolver? _categoryDataResolver;

void configureCategoryDataResolver(CategoryDataResolver? resolver) {
  _categoryDataResolver = resolver;
}

class CategoryData {
  /// The title is displayed in the tab bar.
  final String title;

  /// 当使用中文语言时, 英文的分类标签将在构建页面时被翻译为中文
  final List<BaseCategoryPart> categories;

  final bool enableRankingPage;

  final String key;

  final List<CategoryButtonData> buttons;

  /// Data class for building category page.
  const CategoryData({
    required this.title,
    required this.categories,
    required this.enableRankingPage,
    required this.key,
    this.buttons = const [],
  });
}

class CategoryButtonData {
  final String label;

  final void Function() onTap;

  const CategoryButtonData({required this.label, required this.onTap});
}

class CategoryItem {
  final String label;

  final PageJumpTarget target;

  const CategoryItem(this.label, this.target);
}

abstract class BaseCategoryPart {
  String get title;

  List<CategoryItem> get categories;

  bool get enableRandom;

  /// Data class for building a part of category page.
  const BaseCategoryPart();
}

class FixedCategoryPart extends BaseCategoryPart {
  @override
  final List<CategoryItem> categories;

  @override
  bool get enableRandom => false;

  @override
  final String title;

  /// A [BaseCategoryPart] that show fixed tags on category page.
  const FixedCategoryPart(this.title, this.categories);
}

class RandomCategoryPart extends BaseCategoryPart {
  final List<CategoryItem> all;

  final int randomNumber;

  @override
  final String title;

  @override
  bool get enableRandom => true;

  List<CategoryItem> _categories() {
    if (randomNumber >= all.length) {
      return all;
    }
    var start = math.Random().nextInt(all.length - randomNumber);
    return all.sublist(start, start + randomNumber);
  }

  @override
  List<CategoryItem> get categories => _categories();

  /// A [BaseCategoryPart] that show a part of random tags on category page.
  const RandomCategoryPart(this.title, this.all, this.randomNumber);
}

class DynamicCategoryPart extends BaseCategoryPart {
  final JSAutoFreeFunction loader;

  final String sourceKey;

  @override
  List<CategoryItem> get categories {
    var data = loader([]);
    if (data is! List) {
      throw "DynamicCategoryPart loader must return a List";
    }
    var res = <CategoryItem>[];
    for (var item in data) {
      if (item is! Map) {
        throw "DynamicCategoryPart loader must return a List of Map";
      }
      var label = item['label'];
      var target = PageJumpTarget.parse(sourceKey, item['target']);
      if (label is! String) {
        throw "Category label must be a String";
      }
      res.add(CategoryItem(label, target));
    }
    return res;
  }

  @override
  bool get enableRandom => false;

  @override
  final String title;

  /// A [BaseCategoryPart] that show dynamic tags on category page.
  const DynamicCategoryPart(this.title, this.loader, this.sourceKey);
}

CategoryData getCategoryDataWithKey(String key) {
  final resolver = _categoryDataResolver;
  if (resolver != null) {
    return resolver(key);
  }
  throw "Category data resolver is not configured";
}
