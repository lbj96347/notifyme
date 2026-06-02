// Unit tests for the shared bookmark URL validator. This predicate is the
// single source of truth behind both the add/edit form validator and the row's
// open handler, so it's worth pinning the accept/reject boundary directly.
import 'package:flutter_test/flutter_test.dart';
import 'package:notifyme/features/bookmarks/models/bookmark_url.dart';

void main() {
  group('isValidBookmarkUrl', () {
    test('accepts http(s) URLs with a host', () {
      expect(isValidBookmarkUrl('https://example.com'), isTrue);
      expect(isValidBookmarkUrl('http://example.com/path?q=1#frag'), isTrue);
      expect(isValidBookmarkUrl('https://sub.example.com:8443/a'), isTrue);
    });

    test('accepts other schemes that carry an authority', () {
      // Validation is scheme-agnostic — it only requires scheme + authority, so
      // the in-app browser has something it can parse and load.
      expect(isValidBookmarkUrl('ftp://files.example.com/x'), isTrue);
    });

    test('trims surrounding whitespace before validating', () {
      expect(isValidBookmarkUrl('  https://example.com  '), isTrue);
    });

    test('rejects null and empty/whitespace input', () {
      expect(isValidBookmarkUrl(null), isFalse);
      expect(isValidBookmarkUrl(''), isFalse);
      expect(isValidBookmarkUrl('   '), isFalse);
    });

    test('rejects a scheme-less bare host', () {
      expect(isValidBookmarkUrl('example.com'), isFalse);
      expect(isValidBookmarkUrl('www.example.com/path'), isFalse);
    });

    test('rejects a scheme without an authority', () {
      expect(isValidBookmarkUrl('mailto:someone@example.com'), isFalse);
      expect(isValidBookmarkUrl('tel:+15551234567'), isFalse);
    });

    test('rejects plain text', () {
      expect(isValidBookmarkUrl('just some words'), isFalse);
    });
  });
}
