import 'package:clipstack_app/src/storage.dart';
import 'package:flutter_test/flutter_test.dart';

HistoryItem clip(String id, {String? text, String? image, bool incoming = false, int minute = 0}) => HistoryItem(
      id: id,
      kind: image == null ? 'text' : 'image',
      text: text,
      imagePath: image == null ? null : '/history/$id.png',
      fingerprint: image,
      deviceName: 'Pixel 6',
      incoming: incoming,
      at: DateTime(2026, 11, 22, 13, minute),
    );

void main() {
  test('a new clip goes on top', () {
    final (:kept, :dropped) = HistoryItem.add([clip('a', text: 'one')], clip('b', text: 'two'));
    expect(kept.map((h) => h.id), ['b', 'a']);
    expect(dropped, isEmpty);
  });

  test('the same text again moves to the top instead of appearing twice', () {
    final history = [clip('c', text: 'three', minute: 3), clip('b', text: 'two', minute: 2), clip('a', text: 'one', minute: 1)];
    final again = clip('d', text: 'one', incoming: true, minute: 4);
    final (:kept, :dropped) = HistoryItem.add(history, again);
    expect(kept.map((h) => h.id), ['d', 'c', 'b']);
    expect(kept.first.at, again.at, reason: 'the time is the latest one');
    expect(kept.first.incoming, isTrue, reason: 'and so is where it came from');
    expect(dropped.map((h) => h.id), ['a']);
  });

  test('a clip sent back and forth stays one item', () {
    var history = <HistoryItem>[];
    for (var i = 0; i < 20; i++) {
      history = HistoryItem.add(history, clip('$i', text: 'requests', incoming: i.isOdd, minute: i)).kept;
    }
    expect(history, hasLength(1));
    expect(history.single.id, '19');
  });

  test('a saved list full of repeats folds down to the newest of each', () {
    final saved = [
      for (var i = 9; i >= 0; i--) clip('$i', text: i.isEven ? 'requests' : 'other', minute: i),
    ]; // newest first, as stored
    var kept = <HistoryItem>[];
    for (final item in saved.reversed) {
      kept = HistoryItem.add(kept, item).kept;
    }
    expect(kept.map((h) => h.id), ['9', '8']);
  });

  test('the same picture again moves to the top', () {
    final history = [clip('b', text: 'two'), clip('a', image: '1024:77')];
    final (:kept, :dropped) = HistoryItem.add(history, clip('c', image: '1024:77'));
    expect(kept.map((h) => h.id), ['c', 'b']);
    expect(dropped.single.imagePath, '/history/a.png');
  });

  test('different pictures, and pictures saved without a fingerprint, are kept apart', () {
    final old = HistoryItem(
      id: 'old',
      kind: 'image',
      imagePath: '/history/old.png',
      deviceName: 'Mac',
      incoming: true,
      at: DateTime(2026, 11, 21),
    );
    final history = [clip('a', image: '1024:77'), old];
    expect(HistoryItem.add(history, clip('b', image: '1024:78')).kept, hasLength(3));
    final unknown = HistoryItem(
      id: 'new',
      kind: 'image',
      imagePath: '/history/new.png',
      deviceName: 'Mac',
      incoming: true,
      at: DateTime(2026, 11, 22),
    );
    expect(HistoryItem.add([old], unknown).kept, hasLength(2));
  });

  test('text never matches a picture', () {
    final history = [clip('a', image: '5:5')];
    expect(HistoryItem.add(history, clip('b', text: null)).kept, hasLength(2));
  });

  test('the oldest clips fall off past the limit', () {
    final history = [for (var i = 0; i < 3; i++) clip('$i', text: 'clip $i')];
    final (:kept, :dropped) = HistoryItem.add(history, clip('new', text: 'fresh'), limit: 3);
    expect(kept.map((h) => h.id), ['new', '0', '1']);
    expect(dropped.map((h) => h.id), ['2']);
  });

  test('the fingerprint survives saving', () {
    final saved = HistoryItem.fromJson(clip('a', image: '1024:77').toJson());
    expect(saved.fingerprint, '1024:77');
    expect(HistoryItem.fromJson(clip('b', text: 'hi').toJson()).fingerprint, isNull);
  });
}
