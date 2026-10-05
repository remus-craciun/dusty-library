import 'package:dusty_library/core/server_config.dart';
import 'package:dusty_library/features/reader/word_lookup.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  test('wordAtIndex expands to the word and skips punctuation', () {
    const text = "a well-known don't.";
    expect(wordAtIndex(text, 0), 'a');
    expect(wordAtIndex(text, text.indexOf('known')), 'well-known');
    expect(wordAtIndex(text, text.indexOf("don't") + 3), "don't");
    expect(wordAtIndex(text, text.length - 1), isNull);
    expect(wordAtIndex(text, -1), isNull);
  });

  test('firstWord and normalizeLookupText trim a selection', () {
    expect(firstWord('  old library'), 'old');
    expect(firstWord('...'), isNull);
    expect(normalizeLookupText('  one \n two  '), 'one two');
    expect(normalizeLookupText('x' * 400).length, 300);
  });

  test('charIndexAt picks the glyph under the point', () {
    final rects = [
      const Rect.fromLTWH(0, 0, 10, 10),
      const Rect.fromLTWH(12, 0, 10, 10),
    ];
    expect(charIndexAt(rects, const Offset(4, 4)), 0);
    expect(charIndexAt(rects, const Offset(18, 5)), 1);
    expect(charIndexAt(rects, const Offset(40, 40)), isNull);
  });

  test('fallback language uses the device language when we know it', () {
    expect(fallbackTranslateLanguage('ro'), 'ro');
    expect(fallbackTranslateLanguage('zh'), 'zh-CN');
    expect(fallbackTranslateLanguage('xx'), 'en');
  });

  test(
    'wiktionary parser strips markup and prefers the requested language',
    () {
      final glosses = parseWiktionary({
        'en': [
          {
            'partOfSpeech': 'Noun',
            'language': 'English',
            'definitions': [
              {'definition': ''},
              {'definition': 'A <a href="/wiki/book">book</a> room.'},
            ],
          },
        ],
        'ro': [
          {
            'partOfSpeech': 'Noun',
            'language': 'Romanian',
            'definitions': [
              {'definition': 'A <b>book</b>.'},
            ],
          },
        ],
      }, preferLanguage: 'ro');

      expect(glosses, hasLength(2));
      expect(glosses.first.language, 'Romanian');
      expect(glosses.first.definition, 'A book.');
      expect(glosses.last.definition, 'A book room.');
    },
  );

  test('translation parser reads both response shapes', () {
    final chrome = parseTranslation([
      ['bibliotecă', 'en'],
    ]);
    expect(chrome?.text, 'bibliotecă');
    expect(chrome?.sourceLanguage, 'en');

    final single = parseTranslation([
      [
        ['bonjour', 'hello'],
        ['!', '!'],
      ],
      null,
      'en',
    ]);
    expect(single?.text, 'bonjour!');
    expect(single?.sourceLanguage, 'en');
    expect(parseTranslation([]), isNull);
  });

  testWidgets('lookup sheet shows a definition, then a translation', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(800, 1400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    SharedPreferences.setMockInitialValues({'translate_lang': 'ro'});
    final prefs = await SharedPreferences.getInstance();

    await tester.pumpWidget(
      ProviderScope(
        overrides: [sharedPrefsProvider.overrideWithValue(prefs)],
        child: MaterialApp(
          home: Scaffold(
            body: WordLookupSheet(
              text: 'library',
              meaningFirst: true,
              meanings: (word, prefer) async {
                expect(word, 'library');
                expect(prefer, 'ro');
                return const [
                  Gloss(
                    language: 'English',
                    partOfSpeech: 'noun',
                    definition: 'A collection of books.',
                  ),
                ];
              },
              translations: (text, target) async => Translation(
                text: target == 'fr' ? 'bibliothèque' : 'bibliotecă',
                sourceLanguage: 'en',
              ),
            ),
          ),
        ),
      ),
    );

    await tester.pump();
    await tester.pump();
    expect(find.text('A collection of books.'), findsOneWidget);

    await tester.tap(find.text('Translation'));
    await tester.pump();
    await tester.pump();
    expect(find.text('bibliotecă'), findsOneWidget);
    expect(find.text('Detected English'), findsOneWidget);

    await tester.tap(find.text('Romanian'));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('French').last);
    await tester.tap(find.text('French').last);
    await tester.pump();
    await tester.pump();
    expect(find.text('bibliothèque'), findsOneWidget);
  });
}
