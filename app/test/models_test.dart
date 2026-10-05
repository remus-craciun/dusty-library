import 'package:dusty_library/core/server_config.dart';
import 'package:dusty_library/data/models.dart';
import 'package:dusty_library/features/library/library_providers.dart';
import 'package:dusty_library/features/reader/reading_position.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('Book', () {
    Book book({int pages = 0, int page = 0}) => Book(
      id: 1,
      shelfId: 1,
      title: 't',
      author: '',
      filename: 't.pdf',
      sizeBytes: 1,
      pageCount: pages,
      currentPage: page,
      createdAt: DateTime(2026),
    );

    test('progress is 0 when page count is unknown', () {
      expect(book(page: 10).progress, 0);
    });

    test('progress is clamped to 0..1', () {
      expect(book(pages: 100, page: 25).progress, 0.25);
      expect(book(pages: 100, page: 250).progress, 1);
      expect(book(pages: 100, page: 100).isFinished, isTrue);
    });

    test('round-trips through JSON', () {
      final b = Book.fromJson({
        'id': 7,
        'shelf_id': 2,
        'title': 'Dune',
        'author': 'Herbert',
        'filename': 'dune.pdf',
        'size_bytes': 10,
        'page_count': 400,
        'current_page': 40,
        'page_offset': 0.42,
        'progress_updated_at': '2026-10-05T06:00:00Z',
        'last_read_at': null,
        'created_at': '2026-10-01T00:00:00Z',
      });
      expect(Book.fromJson(b.toJson()).toJson(), b.toJson());
      expect(b.author, 'Herbert');
      expect(b.pageOffset, 0.42);
    });

    test('missing page offset reads as the top of the page', () {
      final b = Book.fromJson({
        'id': 1,
        'shelf_id': 1,
        'title': 't',
        'page_count': 10,
        'current_page': 3,
        'created_at': '2026-10-01T00:00:00Z',
      });
      expect(b.pageOffset, 0);
    });
  });

  group('reading position', () {
    test('spot is the fraction down the page under the viewport top', () {
      final spot = readingSpot(
        viewportTop: 250,
        pages: const [PageSpan(0, 200), PageSpan(200, 200)],
      );
      expect(spot.page, 2);
      expect(spot.offset, closeTo(0.25, 0.0001));
    });

    test('the outer 20% of a tap turns, the middle does not', () {
      expect(tapZone(10, 100), TapZone.previous);
      expect(tapZone(20, 100), TapZone.previous);
      expect(tapZone(21, 100), TapZone.center);
      expect(tapZone(79, 100), TapZone.center);
      expect(tapZone(80, 100), TapZone.next);
      expect(tapZone(0, 0), TapZone.center);
    });

    test('focus mode round-trips a spot through the cropped view', () {
      final pages = [
        const FocusPage(viewTop: 0, viewHeight: 1000, cropTop: 100, cropHeight: 400, pageHeight: 800),
      ];
      const spot = ReadingSpot(1, 0.5);
      final scroll = focusScrollOffset(spot: spot, pages: pages);
      final back = focusReadingSpot(scrollTop: scroll, pages: pages);
      expect(back.page, 1);
      expect(back.offset, closeTo(0.5, 0.0001));
    });
  });

  group('ReaderSettings', () {
    test('clamps zoom and falls back to no filter', () {
      final s = ReaderSettings.fromJson({'zoom': 99, 'filter': 'neon'});
      expect(s.zoom, ReaderSettings.maxZoom);
      expect(s.filter, PageFilter.none);
    });
  });

  group('helpers', () {
    test('titleFromFilename strips extension and separators', () {
      expect(titleFromFilename('the_dusty-shelf.pdf'), 'the dusty shelf');
      expect(titleFromFilename('Hyperion.PDF'), 'Hyperion');
      expect(titleFromFilename('nodot'), 'nodot');
    });

    test('normalizeServerUrl accepts hosts, ports and schemes', () {
      expect(normalizeServerUrl('192.168.1.10:8080'), 'http://192.168.1.10:8080');
      expect(normalizeServerUrl('https://books.example.com/'), 'https://books.example.com');
      expect(normalizeServerUrl('http://host:8080/some/path?x=1'), 'http://host:8080');
      expect(normalizeServerUrl(''), isNull);
      expect(normalizeServerUrl('ftp://x'), isNull);
    });
  });
}
