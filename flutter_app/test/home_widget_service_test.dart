// Behavior tests for [HomeWidgetService] — the mirror that pushes the latest
// notifications into the `home_widget` shared container.
//
// `home_widget`'s static API is replaced by a [_FakeHomeWidgetClient] that
// records every write, so the tests assert the exact wire contract (keys, JSON
// shape, preview/truncation, unread count) without any platform channel.
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:notifyme/features/notifications/notification_model.dart';
import 'package:notifyme/features/widget/home_widget_service.dart';

class _FakeHomeWidgetClient implements HomeWidgetClient {
  final Map<String, String?> data = <String, String?>{};
  String? appGroupId;
  int setAppGroupCalls = 0;
  int updateCalls = 0;

  @override
  Future<void> setAppGroupId(String groupId) async {
    appGroupId = groupId;
    setAppGroupCalls++;
  }

  @override
  Future<void> saveWidgetData(String key, String? value) async {
    data[key] = value;
  }

  @override
  Future<void> updateWidget({String? iOSName, String? androidName}) async {
    updateCalls++;
  }

  List<dynamic> get items =>
      jsonDecode(data[HomeWidgetService.itemsKey]!) as List<dynamic>;
}

AppNotification _note({
  String id = 'n1',
  String title = 'Build done',
  String message = 'Deploy succeeded',
  String category = 'ci',
  String status = 'success',
  bool read = false,
  String? url,
  DateTime? createdAt,
}) {
  return AppNotification(
    id: id,
    uid: 'u1',
    title: title,
    message: message,
    category: category,
    status: status,
    read: read,
    url: url,
    createdAt: createdAt,
  );
}

void main() {
  test('sync writes items, unread count, timestamp, and redraws', () async {
    final client = _FakeHomeWidgetClient();
    final service = HomeWidgetService(client: client);
    final at = DateTime.fromMillisecondsSinceEpoch(1700000000000);

    await service.sync([
      _note(
        id: 'a',
        title: 'CI passed',
        message: 'All green',
        read: false,
        url: 'https://ci.example/run/1',
        createdAt: at,
      ),
      _note(id: 'b', message: 'second', read: true),
    ], now: at);

    expect(client.appGroupId, HomeWidgetService.defaultAppGroupId);
    expect(client.updateCalls, 1);
    expect(client.data[HomeWidgetService.unreadKey], '1');
    expect(
      client.data[HomeWidgetService.updatedKey],
      at.millisecondsSinceEpoch.toString(),
    );

    final items = client.items;
    expect(items.length, 2);
    final first = items.first as Map<String, dynamic>;
    expect(first['id'], 'a');
    expect(first['title'], 'CI passed');
    expect(first['body'], 'All green');
    expect(first['status'], 'success');
    expect(first['category'], 'ci');
    expect(first['read'], false);
    expect(first['url'], 'https://ci.example/run/1');
    expect(first['receivedAt'], at.millisecondsSinceEpoch);
  });

  test('url key is omitted when absent and receivedAt is null', () async {
    final client = _FakeHomeWidgetClient();
    final service = HomeWidgetService(client: client);

    await service.sync([_note(url: null, createdAt: null)]);

    final item = client.items.single as Map<String, dynamic>;
    expect(item.containsKey('url'), isFalse);
    expect(item['receivedAt'], isNull);
  });

  test('sync trims to maxItems', () async {
    final client = _FakeHomeWidgetClient();
    final service = HomeWidgetService(client: client, maxItems: 3);

    await service.sync(
      List.generate(10, (i) => _note(id: 'n$i')),
    );

    expect(client.items.length, 3);
  });

  test('long message is collapsed and truncated with an ellipsis', () async {
    final client = _FakeHomeWidgetClient();
    final service = HomeWidgetService(client: client);
    final long = 'word  ${'x' * 200}';

    await service.sync([_note(message: long)]);

    final body = (client.items.single as Map<String, dynamic>)['body'] as String;
    expect(body.length, lessThanOrEqualTo(141)); // 140 chars + ellipsis
    expect(body.endsWith('…'), isTrue);
    expect(body.contains('  '), isFalse); // whitespace collapsed
  });

  test('app group is bound once across repeated syncs', () async {
    final client = _FakeHomeWidgetClient();
    final service = HomeWidgetService(client: client);

    await service.sync([_note()]);
    await service.sync([_note()]);

    expect(client.setAppGroupCalls, 1);
  });

  test('clear empties the items and zeroes the unread count', () async {
    final client = _FakeHomeWidgetClient();
    final service = HomeWidgetService(client: client);

    await service.sync([_note(read: false)]);
    await service.clear();

    expect(client.items, isEmpty);
    expect(client.data[HomeWidgetService.unreadKey], '0');
    expect(client.updateCalls, 2);
  });

  // Degenerate-data contract. The native iOS widget defends against blank
  // fields (title -> "(no title)", empty body suppressed, blank category ->
  // "GENERAL", blank id -> no deep link). These tests pin what the writer
  // actually emits for those cases so the two sides stay in agreement: the
  // writer passes degenerate values through verbatim rather than substituting
  // its own placeholders, leaving the display fallbacks to the renderer.
  test('blank title and id are written through verbatim (no placeholder)',
      () async {
    final client = _FakeHomeWidgetClient();
    final service = HomeWidgetService(client: client);

    await service.sync([_note(id: '', title: '', category: '')]);

    final item = client.items.single as Map<String, dynamic>;
    expect(item['id'], '');
    expect(item['title'], '');
    expect(item['category'], '');
  });

  test('an all-whitespace message collapses to an empty body', () async {
    final client = _FakeHomeWidgetClient();
    final service = HomeWidgetService(client: client);

    await service.sync([_note(message: '   \n\t  ')]);

    final item = client.items.single as Map<String, dynamic>;
    expect(item['body'], ''); // renderer suppresses the empty body line
  });

  test('unknown status strings are passed through unchanged', () async {
    final client = _FakeHomeWidgetClient();
    final service = HomeWidgetService(client: client);

    await service.sync([_note(status: 'totally-bogus')]);

    final item = client.items.single as Map<String, dynamic>;
    // The closed status set lives server-side; the writer never validates, so a
    // bogus value reaches the widget, which maps anything unknown to `info`.
    expect(item['status'], 'totally-bogus');
  });

  test('a blank url is omitted just like a null url', () async {
    final client = _FakeHomeWidgetClient();
    final service = HomeWidgetService(client: client);

    await service.sync([_note(url: '')]);

    final item = client.items.single as Map<String, dynamic>;
    expect(item.containsKey('url'), isFalse);
  });

  test('unread count ignores items beyond maxItems', () async {
    final client = _FakeHomeWidgetClient();
    final service = HomeWidgetService(client: client, maxItems: 2);

    // Five unread notifications, but only the first two are synced.
    await service.sync(
      List.generate(5, (i) => _note(id: 'n$i', read: false)),
    );

    expect(client.items.length, 2);
    expect(client.data[HomeWidgetService.unreadKey], '2');
  });

  test('the serialized items round-trip through JSON', () async {
    final client = _FakeHomeWidgetClient();
    final service = HomeWidgetService(client: client);
    final at = DateTime.fromMillisecondsSinceEpoch(1700000000000);

    await service.sync([_note(id: 'a', createdAt: at)], now: at);

    // The native side decodes this exact string; assert it is valid JSON whose
    // shape matches the documented wire contract.
    final decoded =
        jsonDecode(client.data[HomeWidgetService.itemsKey]!) as List<dynamic>;
    final item = decoded.single as Map<String, dynamic>;
    expect(item.keys, containsAll(<String>['id', 'title', 'body', 'status',
        'category', 'receivedAt', 'read']));
    expect(item['receivedAt'], isA<int>());
    expect(item['read'], isA<bool>());
  });
}
