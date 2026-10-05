import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;

import '../../core/server_config.dart';

/// A language the translation control can target.
class TranslateLanguage {
  const TranslateLanguage(this.code, this.label);
  final String code;
  final String label;
}

const translateLanguages = <TranslateLanguage>[
  TranslateLanguage('en', 'English'),
  TranslateLanguage('ro', 'Romanian'),
  TranslateLanguage('fr', 'French'),
  TranslateLanguage('de', 'German'),
  TranslateLanguage('es', 'Spanish'),
  TranslateLanguage('it', 'Italian'),
  TranslateLanguage('pt', 'Portuguese'),
  TranslateLanguage('nl', 'Dutch'),
  TranslateLanguage('pl', 'Polish'),
  TranslateLanguage('cs', 'Czech'),
  TranslateLanguage('hu', 'Hungarian'),
  TranslateLanguage('sv', 'Swedish'),
  TranslateLanguage('da', 'Danish'),
  TranslateLanguage('fi', 'Finnish'),
  TranslateLanguage('el', 'Greek'),
  TranslateLanguage('bg', 'Bulgarian'),
  TranslateLanguage('uk', 'Ukrainian'),
  TranslateLanguage('ru', 'Russian'),
  TranslateLanguage('tr', 'Turkish'),
  TranslateLanguage('ar', 'Arabic'),
  TranslateLanguage('he', 'Hebrew'),
  TranslateLanguage('hi', 'Hindi'),
  TranslateLanguage('zh-CN', 'Chinese'),
  TranslateLanguage('ja', 'Japanese'),
  TranslateLanguage('ko', 'Korean'),
];

/// Device language when it is one we can translate into, otherwise English.
String fallbackTranslateLanguage(String languageCode) {
  if (languageCode == 'zh') return 'zh-CN';
  for (final language in translateLanguages) {
    if (language.code == languageCode) return language.code;
  }
  return 'en';
}

String? translateLanguageLabel(String? code) {
  if (code == null || code.isEmpty) return null;
  for (final language in translateLanguages) {
    if (language.code == code) return language.label;
  }
  final head = code.split('-').first;
  for (final language in translateLanguages) {
    if (language.code == head || language.code.startsWith('$head-')) {
      return language.label;
    }
  }
  return null;
}

/// Per-device language words are translated into.
class TranslateLanguageNotifier extends Notifier<String> {
  static const _key = 'translate_lang';

  @override
  String build() {
    final saved = ref.read(sharedPrefsProvider).getString(_key);
    if (saved != null && translateLanguages.any((l) => l.code == saved)) {
      return saved;
    }
    final device =
        WidgetsBinding.instance.platformDispatcher.locale.languageCode;
    return fallbackTranslateLanguage(device);
  }

  Future<void> set(String code) async {
    if (!translateLanguages.any((l) => l.code == code)) return;
    state = code;
    await ref.read(sharedPrefsProvider).setString(_key, code);
  }
}

final translateLanguageProvider =
    NotifierProvider<TranslateLanguageNotifier, String>(
      TranslateLanguageNotifier.new,
    );

class LookupFailure implements Exception {
  LookupFailure(this.message);
  final String message;
}

class Gloss {
  const Gloss({
    required this.language,
    required this.partOfSpeech,
    required this.definition,
  });

  final String language;
  final String partOfSpeech;
  final String definition;
}

class Translation {
  const Translation({required this.text, this.sourceLanguage});

  final String text;

  /// Language code the service detected, when it reports one.
  final String? sourceLanguage;
}

final _wordChar = RegExp(r"[\p{L}\p{M}\p{N}'’\-]", unicode: true);
final _word = RegExp(
  r"[\p{L}\p{M}\p{N}]+(?:['’\-][\p{L}\p{M}\p{N}]+)*",
  unicode: true,
);

/// The word containing [index] in [text], or null when [index] is not a word.
String? wordAtIndex(String text, int index) {
  if (index < 0 || index >= text.length) return null;
  if (!_wordChar.hasMatch(text[index])) return null;
  var start = index;
  var end = index + 1;
  while (start > 0 && _wordChar.hasMatch(text[start - 1])) {
    start--;
  }
  while (end < text.length && _wordChar.hasMatch(text[end])) {
    end++;
  }
  final word = text
      .substring(start, end)
      .replaceAll(RegExp(r"^['’\-]+|['’\-]+$"), '');
  return word.isEmpty ? null : word;
}

/// First word in [text], for a definition when the selection is a phrase.
String? firstWord(String text) => _word.firstMatch(text)?.group(0);

/// Collapses whitespace and caps a selection so a lookup stays a short phrase.
String normalizeLookupText(String raw) {
  final text = raw.replaceAll(RegExp(r'\s+'), ' ').trim();
  if (text.length <= 300) return text;
  return text.substring(0, 300).trim();
}

/// Glyph whose box contains [point], preferring the closest center.
int? charIndexAt(List<Rect> rects, Offset point, {double slop = 6}) {
  int? nearest;
  var best = double.infinity;
  for (var i = 0; i < rects.length; i++) {
    if (!rects[i].inflate(slop).contains(point)) continue;
    final distance = (rects[i].center - point).distance;
    if (distance < best) {
      best = distance;
      nearest = i;
    }
  }
  return nearest;
}

String stripMarkup(String html) {
  var text = html.replaceAll(RegExp(r'<[^>]*>'), '');
  text = text
      .replaceAll('&nbsp;', ' ')
      .replaceAll('&amp;', '&')
      .replaceAll('&lt;', '<')
      .replaceAll('&gt;', '>')
      .replaceAll('&quot;', '"')
      .replaceAll('&#39;', "'")
      .replaceAll('&apos;', "'");
  text = text.replaceAllMapped(RegExp(r'&#(\d+);'), (match) {
    final code = int.tryParse(match.group(1)!);
    if (code == null) return match.group(0)!;
    return String.fromCharCode(code);
  });
  return text.replaceAll(RegExp(r'\s+'), ' ').trim();
}

/// Reads a Wiktionary definition response. [preferLanguage] is shown first.
List<Gloss> parseWiktionary(Object? json, {String? preferLanguage}) {
  if (json is! Map) return const [];
  final prefer = preferLanguage?.split('-').first;
  final codes = <String>[];
  if (prefer != null && json.containsKey(prefer)) codes.add(prefer);
  for (final key in json.keys) {
    if (key is String && !codes.contains(key)) codes.add(key);
  }

  final glosses = <Gloss>[];
  for (final code in codes) {
    final entries = json[code];
    if (entries is! List) continue;
    var taken = 0;
    for (final entry in entries) {
      if (taken >= 2 || glosses.length >= 8) break;
      if (entry is! Map) continue;
      final part = entry['partOfSpeech']?.toString() ?? '';
      final language = entry['language']?.toString() ?? code;
      final definitions = entry['definitions'];
      if (definitions is! List) continue;
      for (final definition in definitions) {
        if (taken >= 2 || glosses.length >= 8) break;
        if (definition is! Map) continue;
        final raw = definition['definition'];
        if (raw is! String) continue;
        final text = stripMarkup(raw);
        if (text.isEmpty) continue;
        glosses.add(
          Gloss(language: language, partOfSpeech: part, definition: text),
        );
        taken++;
      }
    }
    if (glosses.length >= 8) break;
  }
  return glosses;
}

/// Reads either the Chrome translate client or the `translate_a/single` shape.
Translation? parseTranslation(Object? json) {
  if (json is! List || json.isEmpty) return null;
  final first = json.first;
  if (first is! List || first.isEmpty) return null;
  if (first.first is String) {
    final text = (first.first as String).trim();
    if (text.isEmpty) return null;
    final source = first.length > 1 && first[1] is String
        ? first[1] as String
        : null;
    return Translation(text: text, sourceLanguage: source);
  }
  final buffer = StringBuffer();
  for (final part in first) {
    if (part is List && part.isNotEmpty && part.first is String) {
      buffer.write(part.first as String);
    }
  }
  final text = buffer.toString().trim();
  if (text.isEmpty) return null;
  final source = json.length > 2 && json[2] is String
      ? json[2] as String
      : null;
  return Translation(text: text, sourceLanguage: source);
}

const _lookupHeaders = {'User-Agent': 'DustyLibrary/0.1 (word lookup)'};
const _lookupTimeout = Duration(seconds: 10);

Future<List<Gloss>> fetchMeanings(String word, String preferLanguage) async {
  final tried = <String>{};
  for (final candidate in [word, word.toLowerCase(), _capitalize(word)]) {
    if (candidate.isEmpty || !tried.add(candidate)) continue;
    try {
      final glosses = await _fetchWiktionary(candidate, preferLanguage);
      if (glosses.isNotEmpty) return glosses;
    } on LookupFailure {
      rethrow;
    } catch (_) {
      throw LookupFailure('Could not look this up. Check your connection.');
    }
  }
  return const [];
}

String _capitalize(String word) {
  if (word.isEmpty) return word;
  return word[0].toUpperCase() + word.substring(1);
}

Future<List<Gloss>> _fetchWiktionary(String word, String preferLanguage) async {
  final uri = Uri.https(
    'en.wiktionary.org',
    '/api/rest_v1/page/definition/${Uri.encodeComponent(word)}',
  );
  final response = await http
      .get(uri, headers: _lookupHeaders)
      .timeout(_lookupTimeout);
  if (response.statusCode == 404) return const [];
  if (response.statusCode != 200) {
    throw LookupFailure('The dictionary is unavailable right now.');
  }
  return parseWiktionary(
    jsonDecode(response.body),
    preferLanguage: preferLanguage,
  );
}

Future<Translation> translateText(String text, String targetLanguage) async {
  final uri = Uri.https('clients5.google.com', '/translate_a/t', {
    'client': 'dict-chrome-ex',
    'sl': 'auto',
    'tl': targetLanguage,
    'q': text,
  });
  final response = await http
      .get(uri, headers: _lookupHeaders)
      .timeout(_lookupTimeout);
  if (response.statusCode == 429) {
    throw LookupFailure('Translation is busy. Try again in a moment.');
  }
  if (response.statusCode != 200) {
    throw LookupFailure('Translation is unavailable right now.');
  }
  final Translation? parsed;
  try {
    parsed = parseTranslation(jsonDecode(response.body));
  } on FormatException {
    throw LookupFailure('Translation is unavailable right now.');
  }
  if (parsed == null) throw LookupFailure('No translation came back.');
  return parsed;
}

typedef MeaningLookup = Future<List<Gloss>> Function(
  String word,
  String preferLanguage,
);
typedef TranslationLookup = Future<Translation> Function(
  String text,
  String targetLanguage,
);

/// Meaning and translation for a selected word or short phrase.
class WordLookupSheet extends ConsumerStatefulWidget {
  const WordLookupSheet({
    super.key,
    required this.text,
    required this.meaningFirst,
    this.meanings,
    this.translations,
  });

  final String text;
  final bool meaningFirst;
  final MeaningLookup? meanings;
  final TranslationLookup? translations;

  @override
  ConsumerState<WordLookupSheet> createState() => _WordLookupSheetState();
}

class _WordLookupSheetState extends ConsumerState<WordLookupSheet> {
  late bool _meaning = widget.meaningFirst;
  List<Gloss>? _glosses;
  String? _glossError;
  bool _glossLoading = false;
  Translation? _translation;
  String? _translationError;
  bool _translationLoading = false;
  int _translationGen = 0;

  String get _head => firstWord(widget.text) ?? widget.text;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (_meaning) {
        _loadMeaning();
      } else {
        _loadTranslation();
      }
    });
  }

  Future<void> _loadMeaning() async {
    if (_glosses != null || _glossLoading) return;
    setState(() {
      _glossLoading = true;
      _glossError = null;
    });
    try {
      final prefer = ref.read(translateLanguageProvider);
      final glosses = await (widget.meanings ?? fetchMeanings)(_head, prefer);
      if (!mounted) return;
      setState(() {
        _glosses = glosses;
        _glossLoading = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _glossError = error is LookupFailure
            ? error.message
            : 'Could not look this up. Check your connection.';
        _glossLoading = false;
      });
    }
  }

  Future<void> _loadTranslation() async {
    final gen = ++_translationGen;
    final language = ref.read(translateLanguageProvider);
    setState(() {
      _translationLoading = true;
      _translationError = null;
      _translation = null;
    });
    try {
      final translation = await (widget.translations ?? translateText)(
        widget.text,
        language,
      );
      if (!mounted || gen != _translationGen) return;
      setState(() {
        _translation = translation;
        _translationLoading = false;
      });
    } catch (error) {
      if (!mounted || gen != _translationGen) return;
      setState(() {
        _translationError = error is LookupFailure
            ? error.message
            : 'Could not look this up. Check your connection.';
        _translationLoading = false;
      });
    }
  }

  void _select(bool meaning) {
    setState(() => _meaning = meaning);
    if (meaning) {
      _loadMeaning();
    } else if (_translation == null && !_translationLoading) {
      _loadTranslation();
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final language = ref.watch(translateLanguageProvider);
    final phrase = _head != widget.text;
    return DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.45,
      minChildSize: 0.3,
      maxChildSize: 0.85,
      builder: (context, scroll) {
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 0, 24, 16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(widget.text, style: theme.textTheme.titleLarge),
                  if (_meaning && phrase) ...[
                    const SizedBox(height: 4),
                    Text(
                      'Definition of “$_head”',
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                  const SizedBox(height: 16),
                  SegmentedButton<bool>(
                    segments: const [
                      ButtonSegment(value: true, label: Text('Meaning')),
                      ButtonSegment(value: false, label: Text('Translation')),
                    ],
                    selected: {_meaning},
                    onSelectionChanged: (selected) => _select(selected.first),
                  ),
                ],
              ),
            ),
            Expanded(
              child: ListView(
                controller: scroll,
                padding: const EdgeInsets.fromLTRB(24, 4, 24, 24),
                children: [
                  if (_meaning)
                    _meaningBody(theme)
                  else
                    _translationBody(theme, language),
                ],
              ),
            ),
          ],
        );
      },
    );
  }

  Widget _meaningBody(ThemeData theme) {
    if (_glossLoading) return const Center(child: CircularProgressIndicator());
    if (_glossError != null) return Text(_glossError!);
    final glosses = _glosses;
    if (glosses == null) return const SizedBox.shrink();
    if (glosses.isEmpty) {
      return Text('No definition found for “$_head”.');
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (final gloss in glosses) ...[
          Text(
            [
              gloss.language,
              if (gloss.partOfSpeech.isNotEmpty) gloss.partOfSpeech,
            ].join(' · '),
            style: theme.textTheme.labelLarge?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 4),
          Text(gloss.definition, style: theme.textTheme.bodyLarge),
          const SizedBox(height: 16),
        ],
      ],
    );
  }

  Widget _translationBody(ThemeData theme, String language) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        DropdownButton<String>(
          value: language,
          isExpanded: true,
          items: [
            for (final item in translateLanguages)
              DropdownMenuItem(value: item.code, child: Text(item.label)),
          ],
          onChanged: (code) async {
            if (code == null || code == language) return;
            await ref.read(translateLanguageProvider.notifier).set(code);
            if (mounted) _loadTranslation();
          },
        ),
        const SizedBox(height: 12),
        if (_translationLoading)
          const Center(child: CircularProgressIndicator())
        else if (_translationError != null)
          Text(_translationError!)
        else if (_translation != null) ...[
          Text(_translation!.text, style: theme.textTheme.bodyLarge),
          if (translateLanguageLabel(_translation!.sourceLanguage)
              case final source?) ...[
            const SizedBox(height: 8),
            Text(
              'Detected $source',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ],
      ],
    );
  }
}
