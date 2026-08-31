import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:venera_next/components/button.dart';
import 'package:venera_next/components/message.dart';
import 'package:venera_next/components/pop_up_widget.dart';
import 'package:venera_next/features/bangumi/bangumi_models.dart';
import 'package:venera_next/features/bangumi/bangumi_service.dart';
import 'package:venera_next/features/comic_source/comic_source.dart';
import 'package:venera_next/features/history/history.dart';
import 'package:venera_next/foundation/translations.dart';

class BangumiProgressPanel extends StatefulWidget {
  const BangumiProgressPanel({
    super.key,
    this.service,
    required this.sourceKey,
    required this.comicId,
    required this.comicTitle,
    required this.chapters,
    required this.history,
  });

  final BangumiService? service;
  final String sourceKey;
  final String comicId;
  final String comicTitle;
  final ComicChapters? chapters;
  final History? history;

  @override
  State<BangumiProgressPanel> createState() => _BangumiProgressPanelState();
}

class _BangumiProgressPanelState extends State<BangumiProgressPanel> {
  late final TextEditingController _queryController;
  final _progressController = TextEditingController();
  final _ratingController = TextEditingController();
  List<BangumiSubject>? _results;
  BangumiSubject? _selected;
  BangumiProgressMode _mode = BangumiProgressMode.auto;
  BangumiCollectionStatus? _status;
  BangumiCollectionStatus? _loadedStatus;
  String? _loadedProgressText;
  String? _loadedRatingText;
  bool _rebinding = false;
  String? _error;
  bool _loading = false;

  BangumiService get _service => widget.service ?? BangumiService();
  BangumiBinding? get _binding =>
      _service.bindingFor(widget.sourceKey, widget.comicId);

  @override
  void initState() {
    super.initState();
    _queryController = TextEditingController(text: widget.comicTitle);
    _loadBinding();
    final binding = _binding;
    if (binding != null &&
        binding.collectionStatus == null &&
        _service.isConnected) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        unawaited(_refreshMissingStatus());
      });
    }
  }

  @override
  void dispose() {
    _queryController.dispose();
    _progressController.dispose();
    _ratingController.dispose();
    super.dispose();
  }

  void _loadBinding() {
    final binding = _binding;
    if (binding == null) return;
    _mode = binding.progressMode;
    _status = binding.collectionStatus;
    _loadedStatus = binding.collectionStatus;
    final progressText = _remoteProgress(
      binding,
      _manualField(binding),
    ).toString();
    final ratingText = binding.rating.toString();
    _progressController.text = progressText;
    _ratingController.text = ratingText;
    _loadedProgressText = progressText;
    _loadedRatingText = ratingText;
  }

  @override
  Widget build(BuildContext context) => PopUpWidgetScaffold(
    title: 'Bangumi',
    body: !_service.isConnected
        ? Center(child: Text('Connect Bangumi in Settings first'.tl))
        : SingleChildScrollView(
            padding: const EdgeInsets.all(16),
            child: _binding == null || _rebinding
                ? _buildSearch()
                : _buildBound(_binding!),
          ),
  );

  Widget _buildSearch() => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      TextField(
        key: const Key('bangumi-subject-query'),
        controller: _queryController,
        decoration: InputDecoration(
          labelText: 'Search Bangumi'.tl,
          border: const OutlineInputBorder(),
          suffixIcon: IconButton(
            icon: const Icon(Icons.search),
            onPressed: _loading ? null : _search,
          ),
        ),
        onSubmitted: _loading ? null : (_) => _search(),
      ),
      const SizedBox(height: 12),
      _modePicker(),
      if (_error != null) _errorText(),
      if (_loading)
        const Padding(
          padding: EdgeInsets.all(24),
          child: Center(child: CircularProgressIndicator()),
        ),
      if (_selected != null) ...[
        const SizedBox(height: 12),
        _subjectTile(_selected!),
        const SizedBox(height: 12),
        Button.filled(
          key: const Key('bangumi-bind'),
          onPressed: _loading ? () {} : () => _bind(),
          child: Text('Bind'.tl),
        ),
      ],
      if (_results != null)
        for (final subject in _results!.where((item) => item != _selected))
          ListTile(
            leading: Icon(
              _selected == subject
                  ? Icons.radio_button_checked
                  : Icons.radio_button_off,
            ),
            title: _subjectTile(subject),
            onTap: () => setState(() => _selected = subject),
          ),
    ],
  );

  Widget _buildBound(BangumiBinding binding) {
    final parsedResult = _localParseResult(_mode);
    final parsed = parsedResult?.progress;
    final field = _manualField(binding);
    final autoAmbiguous = _mode == BangumiProgressMode.auto && field == null;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          binding.subjectTitle,
          style: Theme.of(context).textTheme.titleLarge,
        ),
        if (binding.subjectOriginalTitle.isNotEmpty)
          Text(binding.subjectOriginalTitle),
        Text('Subject ID: ${binding.subjectId}'),
        Text(
          '${'Episodes'.tl}: ${binding.lastRemoteEpisode}    ${'Volumes'.tl}: ${binding.lastRemoteVolume}',
        ),
        const SizedBox(height: 12),
        _statusPicker(),
        const SizedBox(height: 12),
        _modePicker(onChanged: _changeMode),
        if (parsed != null)
          Text(
            '${'Current chapter'.tl}: ${parsed.value} (${_fieldName(parsed.field)})',
          )
        else if (_mode == BangumiProgressMode.auto)
          Text('Choose episode or volume before saving progress'.tl),
        if (parsedResult == null)
          Text('Current chapter title is unavailable'.tl),
        if (parsedResult?.failure != null)
          Text(
            'Chapter title cannot be parsed: @reason'.tlParams({
              'reason': _parseFailureName(parsedResult!.failure!),
            }),
          ),
        if (_service.hasPendingProgress(widget.sourceKey, widget.comicId))
          Text('Bangumi progress is waiting to retry'.tl),
        const SizedBox(height: 12),
        TextField(
          key: const Key('bangumi-progress-field'),
          controller: _progressController,
          enabled: !_loading && !autoAmbiguous,
          keyboardType: TextInputType.number,
          inputFormatters: [FilteringTextInputFormatter.digitsOnly],
          decoration: InputDecoration(
            labelText: 'Progress'.tl,
            border: const OutlineInputBorder(),
          ),
        ),
        const SizedBox(height: 12),
        TextField(
          key: const Key('bangumi-rating-field'),
          controller: _ratingController,
          enabled: !_loading,
          keyboardType: TextInputType.number,
          inputFormatters: [FilteringTextInputFormatter.digitsOnly],
          decoration: InputDecoration(
            labelText: 'Rating (0-10)'.tl,
            border: const OutlineInputBorder(),
          ),
        ),
        if (_error != null) _errorText(),
        const SizedBox(height: 12),
        Button.filled(
          key: const Key('bangumi-save'),
          isLoading: _loading,
          onPressed: _loading ? () {} : () => _save(),
          child: Text('Save'.tl),
        ),
        const SizedBox(height: 8),
        Button.outlined(
          key: const Key('bangumi-sync-now'),
          isLoading: _loading,
          onPressed: _loading ? () {} : () => _syncNow(),
          child: Text('Refresh / Sync now'.tl),
        ),
        const SizedBox(height: 8),
        Button.outlined(
          key: const Key('bangumi-rebind'),
          onPressed: _loading
              ? () {}
              : () => setState(() {
                  _rebinding = true;
                  _selected = null;
                  _results = null;
                  _error = null;
                }),
          child: Text('Rebind'.tl),
        ),
        const SizedBox(height: 8),
        Button.outlined(
          key: const Key('bangumi-unbind'),
          onPressed: _loading ? () {} : () => _unbind(),
          child: Text('Unbind'.tl),
        ),
      ],
    );
  }

  Widget _subjectTile(BangumiSubject subject) => Row(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      if (subject.coverUrl.isNotEmpty)
        Image.network(
          subject.coverUrl,
          width: 40,
          height: 56,
          fit: BoxFit.cover,
          errorBuilder: (_, _, _) => const SizedBox(width: 40),
        ),
      if (subject.coverUrl.isNotEmpty) const SizedBox(width: 8),
      Expanded(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(subject.title),
            Text(subject.originalTitle),
            Text(
              '${'Episodes'.tl}: ${subject.totalEpisodes}  ${'Volumes'.tl}: ${subject.totalVolumes}',
            ),
          ],
        ),
      ),
    ],
  );

  Widget _statusPicker() => KeyedSubtree(
    key: const Key('bangumi-status'),
    child: DropdownButtonFormField<BangumiCollectionStatus>(
      key: ValueKey(_status),
      initialValue: _status,
      decoration: InputDecoration(
        labelText: 'Status'.tl,
        border: const OutlineInputBorder(),
      ),
      items: BangumiCollectionStatus.values
          .map(
            (status) => DropdownMenuItem(
              value: status,
              child: Text(_statusName(status)),
            ),
          )
          .toList(),
      onChanged: _loading
          ? null
          : (status) {
              if (status != null) {
                setState(() => _status = status);
              }
            },
    ),
  );

  Widget _modePicker({ValueChanged<BangumiProgressMode>? onChanged}) =>
      KeyedSubtree(
        key: const Key('bangumi-mode'),
        child: DropdownButtonFormField<BangumiProgressMode>(
          key: ValueKey(_mode),
          initialValue: _mode,
          decoration: InputDecoration(
            labelText: 'Sync mode'.tl,
            border: const OutlineInputBorder(),
          ),
          items: BangumiProgressMode.values
              .map(
                (mode) =>
                    DropdownMenuItem(value: mode, child: Text(_modeName(mode))),
              )
              .toList(),
          onChanged: _loading
              ? null
              : (mode) {
                  if (mode != null) {
                    (onChanged ?? (value) => setState(() => _mode = value))(
                      mode,
                    );
                  }
                },
        ),
      );

  Widget _errorText() => Padding(
    padding: const EdgeInsets.only(top: 12),
    child: Text(
      _error!,
      style: TextStyle(color: Theme.of(context).colorScheme.error),
    ),
  );

  Future<void> _search() async {
    if (_loading) return;
    final query = _queryController.text.trim();
    if (query.isEmpty) return;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final results = RegExp(r'^\d+$').hasMatch(query)
          ? [await _service.getSubject(int.parse(query))]
          : await _service.searchSubjects(query);
      if (mounted) {
        setState(() {
          _results = results;
          _selected = results.length == 1 ? results.single : null;
        });
      }
    } catch (error) {
      if (mounted) {
        setState(() => _error = '$error');
      }
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _bind() async {
    final subject = _selected;
    if (subject == null) return;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      await _service.bind(
        sourceKey: widget.sourceKey,
        comicId: widget.comicId,
        subject: subject,
        mode: _mode,
        reliableLocalProgress: _reliableLocalProgress(),
      );
      if (mounted) {
        _rebinding = false;
        _loadBinding();
        setState(() {});
      }
    } catch (error) {
      if (mounted) setState(() => _error = '$error');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _changeMode(BangumiProgressMode mode) async {
    if (_loading) return;
    final old = _mode;
    setState(() {
      _mode = mode;
      _loading = true;
    });
    try {
      await _service.updateMode(widget.sourceKey, widget.comicId, mode);
      if (mounted) {
        _loadBinding();
        setState(() => _error = null);
      }
    } catch (error) {
      if (mounted) {
        setState(() {
          _mode = old;
          _error = '$error';
        });
      }
    } finally {
      if (mounted) {
        setState(() => _loading = false);
      }
    }
  }

  Future<void> _refreshMissingStatus() async {
    final binding = _binding;
    if (!mounted ||
        _loading ||
        binding == null ||
        binding.collectionStatus != null) {
      return;
    }
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final collection = await _service.refresh(
        widget.sourceKey,
        widget.comicId,
      );
      if (!mounted) return;
      if (collection == null) {
        setState(() => _error = 'Bangumi collection no longer exists'.tl);
        return;
      }
      _loadBinding();
      setState(() => _error = null);
    } catch (error) {
      if (mounted) setState(() => _error = '$error');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _save({bool allowDecrease = false}) async {
    final binding = _binding;
    final field = binding == null ? null : _manualField(binding);
    final progressChanged =
        field != null && _progressController.text != _loadedProgressText;
    final ratingChanged = _ratingController.text != _loadedRatingText;
    final statusChanged = _status != _loadedStatus;
    final progress = !progressChanged
        ? null
        : int.tryParse(_progressController.text);
    final rating = !ratingChanged ? null : int.tryParse(_ratingController.text);
    if (binding == null ||
        (progressChanged && (progress == null || progress < 0)) ||
        (ratingChanged && (rating == null || rating < 0 || rating > 10))) {
      setState(
        () => _error =
            'Enter a non-negative progress and a rating from 0 to 10'.tl,
      );
      return;
    }
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      await _service.updateManual(
        sourceKey: widget.sourceKey,
        comicId: widget.comicId,
        field: progressChanged ? field : null,
        progress: progress,
        rating: rating,
        collectionStatus: statusChanged ? _status : null,
        allowDecrease: allowDecrease,
      );
      if (mounted) {
        _loadBinding();
        setState(() {});
      }
    } on BangumiProgressDecreaseRequired {
      if (mounted) {
        showConfirmDialog(
          context: context,
          title: 'Lower Bangumi progress?'.tl,
          content: 'The new progress is lower than Bangumi. Continue?'.tl,
          onConfirm: () => _save(allowDecrease: true),
        );
      }
    } catch (error) {
      if (mounted) setState(() => _error = '$error');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _syncNow() async {
    final binding = _binding;
    if (binding == null) return;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      await _service.retryPending(
        bindingKey: bangumiBindingKey(widget.sourceKey, widget.comicId),
      );
      final collection = await _service.refresh(
        widget.sourceKey,
        widget.comicId,
      );
      if (collection == null) {
        if (mounted) {
          setState(() => _error = 'Bangumi collection no longer exists'.tl);
        }
        return;
      }
      if (mounted) {
        _loadBinding();
        setState(() {});
      }
    } catch (error) {
      if (mounted) setState(() => _error = '$error');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _unbind() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      await _service.unbind(widget.sourceKey, widget.comicId);
      if (mounted) setState(() {});
    } catch (error) {
      if (mounted) setState(() => _error = '$error');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  BangumiProgressField? _manualField(BangumiBinding binding) => switch (_mode) {
    BangumiProgressMode.episode => BangumiProgressField.episode,
    BangumiProgressMode.volume => BangumiProgressField.volume,
    BangumiProgressMode.auto => _localProgress(_mode)?.field,
  };

  BangumiProgress? _reliableLocalProgress() {
    final history = widget.history;
    final maxPage = history?.maxPage;
    if (maxPage == null ||
        maxPage <= 0 ||
        history!.page <= 0 ||
        history.page != maxPage) {
      return null;
    }
    return _localProgress(_mode);
  }

  BangumiProgress? _localProgress(BangumiProgressMode mode) {
    return _localParseResult(mode)?.progress;
  }

  BangumiTitleParseResult? _localParseResult(BangumiProgressMode mode) {
    final history = widget.history;
    final chapters = widget.chapters;
    if (history == null || chapters == null || history.ep < 1) {
      return null;
    }
    var index = history.ep - 1;
    if (chapters.isGrouped) {
      if (history.group == null ||
          history.group! < 1 ||
          history.group! > chapters.groupCount) {
        return null;
      }
      if (history.ep > chapters.getGroupByIndex(history.group! - 1).length) {
        return null;
      }
      for (var group = 0; group < history.group! - 1; group++) {
        index += chapters.getGroupByIndex(group).length;
      }
    }
    if (index < 0 || index >= chapters.length) {
      return null;
    }
    return BangumiTitleProgressParser.parse(
      chapters.titles.elementAt(index),
      mode,
    );
  }

  int _remoteProgress(BangumiBinding binding, BangumiProgressField? field) =>
      field == BangumiProgressField.volume
      ? binding.lastRemoteVolume
      : binding.lastRemoteEpisode;
  String _statusName(BangumiCollectionStatus status) => switch (status) {
    BangumiCollectionStatus.wish => 'Plan to read'.tl,
    BangumiCollectionStatus.reading => 'Currently reading'.tl,
    BangumiCollectionStatus.completed => 'Finished reading'.tl,
    BangumiCollectionStatus.onHold => 'On hold'.tl,
    BangumiCollectionStatus.dropped => 'Dropped'.tl,
  };

  String _modeName(BangumiProgressMode mode) => switch (mode) {
    BangumiProgressMode.auto => 'Auto'.tl,
    BangumiProgressMode.episode => 'Episode'.tl,
    BangumiProgressMode.volume => 'Volume'.tl,
  };
  String _fieldName(BangumiProgressField field) =>
      field == BangumiProgressField.episode ? 'Episode'.tl : 'Volume'.tl;
  String _parseFailureName(BangumiTitleParseFailure failure) =>
      switch (failure) {
        BangumiTitleParseFailure.unknownUnit => 'Unknown chapter unit'.tl,
        BangumiTitleParseFailure.ambiguous => 'Ambiguous chapter title'.tl,
        BangumiTitleParseFailure.decimal => 'Decimal chapter number'.tl,
        BangumiTitleParseFailure.negative => 'Negative chapter number'.tl,
        BangumiTitleParseFailure.noNumber => 'No chapter number'.tl,
      };
}
