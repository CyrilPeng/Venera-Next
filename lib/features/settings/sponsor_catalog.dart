enum SponsorKind { monthly, oneTime }

enum SponsorSection { featured, current, historical }

class Sponsor {
  const Sponsor({required this.name, required this.tier, required this.kind});

  factory Sponsor.fromJson(Object? value) {
    if (value is! Map) {
      throw const FormatException("Sponsor must be an object");
    }
    var name = value["name"];
    var tier = value["tier"];
    var kind = value["kind"] ?? "monthly";
    if (name is! String || name.trim().isEmpty) {
      throw const FormatException("Sponsor name must be a non-empty string");
    }
    if (tier is! int || !const {30, 80, 200}.contains(tier)) {
      throw const FormatException("Sponsor tier is invalid");
    }
    if (kind != "monthly" && kind != "oneTime") {
      throw const FormatException("Sponsor kind is invalid");
    }
    return Sponsor(
      name: name.trim(),
      tier: tier,
      kind: kind == "oneTime" ? SponsorKind.oneTime : SponsorKind.monthly,
    );
  }

  final String name;

  final int tier;

  final SponsorKind kind;
}

class SponsorCatalog {
  const SponsorCatalog({
    required this.featured,
    required this.current,
    required this.historical,
  });

  factory SponsorCatalog.fromJson(Object? value) {
    if (value is! Map) {
      throw const FormatException("Sponsor catalog must be an object");
    }
    var sections = value["sections"];
    if (sections != null) {
      if (sections is! Map) {
        throw const FormatException("Sponsor sections must be an object");
      }
      return SponsorCatalog(
        featured: _parseList(sections["featured"], "featured"),
        current: _parseList(sections["current"], "current"),
        historical: _parseList(sections["historical"], "historical"),
      );
    }

    // Older published data used one flat list. Treat tier 200 as featured and
    // the remaining entries as current until the sectioned payload is loaded.
    var legacy = _parseList(value["sponsors"], "sponsors");
    return SponsorCatalog(
      featured: List.unmodifiable(
        legacy.where((sponsor) => sponsor.tier == 200),
      ),
      current: List.unmodifiable(
        legacy.where((sponsor) => sponsor.tier != 200),
      ),
      historical: const [],
    );
  }

  final List<Sponsor> featured;

  final List<Sponsor> current;

  final List<Sponsor> historical;

  bool get isEmpty => featured.isEmpty && current.isEmpty && historical.isEmpty;

  List<Sponsor> section(SponsorSection section) {
    return switch (section) {
      SponsorSection.featured => featured,
      SponsorSection.current => current,
      SponsorSection.historical => historical,
    };
  }

  static List<Sponsor> _parseList(Object? value, String field) {
    if (value == null) {
      return const [];
    }
    if (value is! List) {
      throw FormatException("Sponsor section $field must be a list");
    }
    return List.unmodifiable(value.map(Sponsor.fromJson));
  }
}
