import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher_string.dart';
import 'package:venera_next/components/appbar.dart';
import 'package:venera_next/components/button.dart';
import 'package:venera_next/components/scroll.dart';
import 'package:venera_next/foundation/context.dart';
import 'package:venera_next/foundation/translations.dart';
import 'package:venera_next/foundation/widget_utils.dart';

import 'sponsor_catalog.dart';
import 'sponsors_loader.dart';

const _afdianUrl = "https://ifdian.net/a/cyril";

class _TierStyle {
  const _TierStyle({required this.bold, required this.crown});

  final bool bold;

  final bool crown;
}

const _tierStyles = <int, _TierStyle>{
  200: _TierStyle(bold: true, crown: true),
  80: _TierStyle(bold: true, crown: false),
  30: _TierStyle(bold: false, crown: false),
};

class SponsorsPage extends StatefulWidget {
  const SponsorsPage({super.key, this.loader});

  final SponsorsLoader? loader;

  @override
  State<SponsorsPage> createState() => _SponsorsPageState();
}

class _SponsorsPageState extends State<SponsorsPage> {
  late Future<SponsorCatalog> _sponsors;

  @override
  void initState() {
    super.initState();
    _sponsors = _loadSponsors();
  }

  Future<SponsorCatalog> _loadSponsors() {
    return widget.loader?.call() ?? fetchSponsors();
  }

  void _retry() {
    setState(() {
      _sponsors = _loadSponsors();
    });
  }

  @override
  Widget build(BuildContext context) {
    return SmoothCustomScrollView(
      slivers: [
        SliverAppbar(title: Text("Sponsors".tl)),
        FutureBuilder<SponsorCatalog>(
          future: _sponsors,
          builder: (context, snapshot) {
            if (snapshot.connectionState != ConnectionState.done) {
              return const SliverFillRemaining(
                hasScrollBody: false,
                child: Center(child: CircularProgressIndicator()),
              );
            }
            if (snapshot.hasError) {
              return SliverFillRemaining(
                hasScrollBody: false,
                child: Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text("Failed to load sponsors".tl),
                      const SizedBox(height: 12),
                      Button.text(onPressed: _retry, child: Text("Retry".tl)),
                    ],
                  ),
                ),
              );
            }
            return SliverToBoxAdapter(
              child: _buildContent(
                snapshot.data ??
                    const SponsorCatalog(
                      featured: [],
                      current: [],
                      historical: [],
                    ),
              ),
            );
          },
        ),
      ],
    );
  }

  Widget _buildContent(SponsorCatalog catalog) {
    var children = <Widget>[
      Text(
        "Thanks to all sponsors who support the continuous maintenance of VeneraNext."
            .tl,
        style: const TextStyle(fontSize: 14),
      ).paddingHorizontal(16).paddingTop(8),
    ];

    if (catalog.isEmpty) {
      children.add(Center(child: Text("No sponsors yet".tl).paddingAll(32)));
    } else {
      for (var section in SponsorSection.values) {
        var sponsors = catalog.section(section);
        if (sponsors.isEmpty) {
          continue;
        }
        children.add(_buildSectionHeader(section));
        children.add(_buildSponsorChips(sponsors));
      }
    }

    children.add(
      Center(
        child: Button.filled(
          onPressed: () => launchUrlString(_afdianUrl),
          child: Text("Support on Afdian".tl),
        ).paddingVertical(24),
      ),
    );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: children,
    ).paddingBottom(16);
  }

  Widget _buildSectionHeader(SponsorSection section) {
    var title = switch (section) {
      SponsorSection.featured => "Featured Sponsors",
      SponsorSection.current => "Current Sponsors",
      SponsorSection.historical => "Past Sponsors",
    };
    return Text(
      title.tl,
      style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
    ).paddingHorizontal(16).paddingTop(20).paddingBottom(8);
  }

  Widget _buildSponsorChips(List<Sponsor> sponsors) {
    return LayoutBuilder(
      builder: (context, constraints) {
        return Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (var sponsor in sponsors)
              _buildChip(sponsor, constraints.maxWidth),
          ],
        );
      },
    ).paddingHorizontal(16);
  }

  Widget _buildChip(Sponsor sponsor, double maxWidth) {
    var colorScheme = context.colorScheme;
    var style =
        _tierStyles[sponsor.tier] ??
        const _TierStyle(bold: false, crown: false);
    var detail = sponsor.kind == SponsorKind.oneTime
        ? "One-time".tl
        : "Tier ¥@amount".tlParams({"amount": sponsor.tier.toString()});
    return ConstrainedBox(
      constraints: BoxConstraints(maxWidth: maxWidth),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
        decoration: BoxDecoration(
          color: style.crown
              ? colorScheme.primaryContainer
              : colorScheme.surfaceContainerLow,
          borderRadius: BorderRadius.circular(8),
        ),
        child: Wrap(
          spacing: 8,
          runSpacing: 2,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            if (style.crown) const Text("👑"),
            Text(
              sponsor.name,
              style: TextStyle(
                fontWeight: style.bold ? FontWeight.w700 : FontWeight.normal,
                color: style.crown ? colorScheme.onPrimaryContainer : null,
              ),
            ),
            Text(
              detail,
              style: TextStyle(
                fontSize: 12,
                color: style.crown
                    ? colorScheme.onPrimaryContainer.withValues(alpha: 0.72)
                    : colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
