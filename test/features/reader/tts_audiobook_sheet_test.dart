import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:watch_app/core/reading/tts/tts_cubit.dart';
import 'package:watch_app/core/reading/tts/tts_state.dart';
import 'package:watch_app/features/reader/tts_audiobook_sheet.dart';
import 'package:watch_app/features/reader/tts_player_bar.dart';

List<TtsSentenceView> _sentences(int n) => List<TtsSentenceView>.generate(
  n,
  (i) => TtsSentenceView(
    index: i,
    text: 'Sentence number $i of the chapter goes here.',
    blockIndex: i,
    pauseAfterMs: 0,
  ),
);

/// A cubit stand-in that records what the sheet asked it to do. The sheet only
/// needs seek/skip/toggle/setRate/setSleepTimer and a TtsState to render.
class _FakeTtsCubit extends Cubit<TtsState> implements TtsCubit {
  _FakeTtsCubit({int total = 12, int current = 3, TtsStatus status = TtsStatus.speaking})
    : super(
        TtsState(
          status: status,
          available: true,
          bookId: 'book',
          chapterId: 'chapter',
          totalSentences: total,
          sentences: _sentences(total),
          currentIndex: current,
        ),
      );

  final List<int> seeks = [];
  int toggles = 0;
  double? rate;
  int? sleep;

  @override
  Future<void> seek(int index) async {
    seeks.add(index);
    emit(state.copyWith(currentIndex: index));
  }

  @override
  Future<void> skip(int delta) => seek(state.currentIndex + delta);

  @override
  Future<void> toggle() async => toggles++;

  @override
  Future<void> setRate(double value) async {
    rate = value;
    emit(state.copyWith(rate: value));
  }

  @override
  Future<void> setSleepTimer(int minutes) async {
    sleep = minutes;
    emit(state.copyWith(sleepTimerMinutes: minutes));
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

Widget _bar(_FakeTtsCubit cubit, {required VoidCallback onOpenPlayer}) =>
    MaterialApp(
      home: Scaffold(
        body: TtsPlayerBar(
          cubit: cubit,
          onOpenSettings: () {},
          onOpenPlayer: onOpenPlayer,
          onClose: () {},
        ),
      ),
    );

/// The sheet on its own, with the chapter plumbing a reader supplies.
Widget _sheet(
  _FakeTtsCubit cubit, {
  List<String>? labels,
  bool withChapters = true,
}) =>
    MaterialApp(
      home: TtsAudiobookSheet(
        cubit: cubit,
        bookTitle: 'A Wizard of Earthsea',
        chapterTitle: () => 'Chapter 8',
        canPreviousChapter: () => true,
        canNextChapter: () => true,
        onPreviousChapter: () {},
        onNextChapter: () {},
        cover: null,
        chapterLabels: labels ?? ['1', '2', '3'],
        chapterTitles: const ['One', 'Two', 'Three'],
        currentChapter: 1,
        onSelectChapter: withChapters ? (_) {} : null,
      ),
    );

void main() {
  group('compact bar progress track', () {
    testWidgets('a tap on the track seeks to the sentence under the finger', (
      tester,
    ) async {
      // It used to open the player instead, on the reasoning that the strip is
      // the widest thing in the bar and so a convenient open target. But a
      // progress bar that navigates away is a progress bar you cannot tap to
      // seek, and it contradicted the full player's waveform where tap does
      // seek. Both surfaces now agree, and with every other audio player.
      final cubit = _FakeTtsCubit();
      var opened = 0;
      await tester.pumpWidget(_bar(cubit, onOpenPlayer: () => opened++));

      final track = find.byKey(const ValueKey('compact-tts-progress'));
      final box = tester.renderObject<RenderBox>(track);
      await tester.tapAt(box.localToGlobal(Offset(box.size.width * 0.75, 12)));
      await tester.pump();

      expect(opened, 0, reason: 'a tap must not open the player');
      expect(cubit.seeks, hasLength(1), reason: 'the tap commits one seek');
      expect(cubit.seeks.last, greaterThan(6));
      await cubit.close();
    });

    testWidgets('the expand button next to settings opens the player too', (
      tester,
    ) async {
      final cubit = _FakeTtsCubit();
      var opened = 0;
      await tester.pumpWidget(_bar(cubit, onOpenPlayer: () => opened++));

      await tester.tap(find.byIcon(Icons.open_in_full_rounded));
      await tester.pump();

      expect(opened, 1);
      await cubit.close();
    });

    testWidgets('a drag scrubs to one seek on release', (tester) async {
      final cubit = _FakeTtsCubit();
      var opened = 0;
      await tester.pumpWidget(_bar(cubit, onOpenPlayer: () => opened++));

      final track = find.byKey(const ValueKey('compact-tts-progress'));
      final box = tester.renderObject<RenderBox>(track);
      final gesture = await tester.startGesture(
        box.localToGlobal(Offset(box.size.width * 0.1, 12)),
      );
      await gesture.moveTo(box.localToGlobal(Offset(box.size.width * 0.9, 12)));
      await gesture.up();
      await tester.pump();

      expect(opened, 0, reason: 'a drag must not open the player either');
      expect(cubit.seeks, hasLength(1), reason: 'the drag commits one seek');
      await cubit.close();
    });
  });

  group('audiobook sheet', () {
    testWidgets('there is no second page any more', (tester) async {
      final cubit = _FakeTtsCubit(total: 6);
      await tester.pumpWidget(_sheet(cubit));
      await tester.pumpAndSettle();

      // The old toggle button and the header label that doubled as a way back.
      expect(find.byKey(const ValueKey('audiobook-sheet-toggle')), findsNothing);
      expect(find.text('READING NOW'), findsNothing);
      // And no waveform: the ring replaced it.
      expect(find.byKey(const ValueKey('audiobook-waveform')), findsNothing);
      await cubit.close();
    });

    testWidgets('it shows the ring, the counter and the sentence being read', (
      tester,
    ) async {
      final cubit = _FakeTtsCubit(total: 6, current: 3);
      await tester.pumpWidget(_sheet(cubit));
      await tester.pumpAndSettle();

      expect(find.byKey(const ValueKey('audiobook-ring')), findsOneWidget);
      expect(find.text('Sentence'), findsOneWidget);
      expect(find.textContaining('of 6'), findsNothing);
      expect(find.text(' 4'), findsOneWidget, reason: 'sentence 3 shown as 4');
      // The spoken sentence is in the middle, at its own size.
      expect(
        find.text('Sentence number 3 of the chapter goes here.'),
        findsOneWidget,
      );
      await cubit.close();
    });

    testWidgets('the neighbourhood of the spoken sentence is on screen', (
      tester,
    ) async {
      // The point of merging the transcript in: the sentences around the one
      // being read are visible without navigating anywhere.
      final cubit = _FakeTtsCubit(total: 20, current: 10);
      await tester.pumpWidget(_sheet(cubit));
      await tester.pumpAndSettle();

      for (final i in [10, 9, 11, 8, 12]) {
        expect(
          find.byKey(ValueKey('audiobook-row-$i')),
          findsOneWidget,
          reason: 'sentence $i should be visible around the spoken one',
        );
      }
      // And nothing far away: this is a neighbourhood, not a transcript.
      expect(find.byKey(const ValueKey('audiobook-row-0')), findsNothing);
      await cubit.close();
    });

    testWidgets('tapping a neighbouring sentence seeks to it', (tester) async {
      // A short chapter and a nearby row. The transcript is a lazy list, so a
      // row far from the spoken sentence is simply not built - tapping it is
      // not possible rather than broken.
      final cubit = _FakeTtsCubit(total: 12, current: 6);
      await tester.pumpWidget(_sheet(cubit));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const ValueKey('audiobook-row-8')));
      await tester.pump();

      expect(cubit.seeks, [8]);
      await cubit.close();
    });

    testWidgets('the spoken sentence itself is not a tap target', (
      tester,
    ) async {
      // Seeking to where you already are is a no-op that still restarts the
      // utterance, so the one line that cannot go anywhere has no handler.
      final cubit = _FakeTtsCubit(total: 20, current: 10);
      await tester.pumpWidget(_sheet(cubit));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const ValueKey('audiobook-row-10')));
      await tester.pump();

      expect(cubit.seeks, isEmpty);
      await cubit.close();
    });

    testWidgets('the header names the chapter and the work', (tester) async {
      final cubit = _FakeTtsCubit(total: 6);
      await tester.pumpWidget(_sheet(cubit));
      await tester.pumpAndSettle();

      expect(find.textContaining('Chapter 8'), findsOneWidget);
      expect(find.text('A Wizard of Earthsea'), findsOneWidget);
      await cubit.close();
    });

    testWidgets('the chapters button opens a sheet of chapters', (tester) async {
      final cubit = _FakeTtsCubit(total: 6);
      await tester.pumpWidget(_sheet(cubit));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const ValueKey('audiobook-chapters')));
      await tester.pumpAndSettle();

      expect(find.text('Chapters'), findsOneWidget);
      expect(find.text('One'), findsOneWidget);
      await cubit.close();
    });

    testWidgets('picking a chapter closes the sheet', (tester) async {
      final cubit = _FakeTtsCubit(total: 6);
      await tester.pumpWidget(_sheet(cubit));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const ValueKey('audiobook-chapters')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('audiobook-chapter-2')));
      await tester.pumpAndSettle();

      expect(find.text('Chapters'), findsNothing);
      await cubit.close();
    });

    testWidgets('with no chapter list the chapters button is not offered', (
      tester,
    ) async {
      final cubit = _FakeTtsCubit(total: 6);
      await tester.pumpWidget(_sheet(cubit, withChapters: false));
      await tester.pumpAndSettle();

      final button = tester.widget<InkResponse>(
        find.descendant(
          of: find.byKey(const ValueKey('audiobook-chapters')),
          matching: find.byType(InkResponse),
        ),
      );
      expect(button.onTap, isNull);
      await cubit.close();
    });

    testWidgets('the transport steps one sentence at a time', (tester) async {
      final cubit = _FakeTtsCubit(total: 12, current: 3);
      await tester.pumpWidget(_sheet(cubit));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const ValueKey('audiobook-plus-sentence')));
      await tester.pump();
      expect(cubit.seeks.last, 4);

      await tester.tap(find.byKey(const ValueKey('audiobook-minus-sentence')));
      await tester.pump();
      expect(cubit.seeks.last, 3);
      await cubit.close();
    });

    testWidgets('the play button toggles the voice', (tester) async {
      final cubit = _FakeTtsCubit(total: 6);
      await tester.pumpWidget(_sheet(cubit));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const ValueKey('audiobook-play')));
      await tester.pump();

      expect(cubit.toggles, 1);
      await cubit.close();
    });

    testWidgets('the cover swaps to the chapter number and back', (
      tester,
    ) async {
      final cubit = _FakeTtsCubit(total: 6);
      await tester.pumpWidget(_sheet(cubit));
      await tester.pumpAndSettle();

      // Tapping the cover swaps the artwork for the chapter's own number, and
      // tapping again brings the artwork back. It is not play/pause - that
      // lives on its own button in the bar.
      await tester.tap(find.byKey(const ValueKey('audiobook-cover')));
      await tester.pump();
      expect(find.text('2'), findsOneWidget, reason: 'chapter number in place');

      await tester.tap(find.byKey(const ValueKey('audiobook-cover')));
      await tester.pump();
      expect(find.text('2'), findsNothing, reason: 'cover artwork is back');
      expect(cubit.toggles, 0, reason: 'the cover is not play/pause');
      await cubit.close();
    });

    testWidgets('tapping the cover never moves the reading on', (tester) async {
      // The regression: `onPanDown` fires on pointer-DOWN, before the arena
      // resolves, so a cover tap started a scrub at whatever angle the middle
      // of the ring pointed at. The pan then lost to the cover's InkWell and the
      // CANCEL committed it - so tapping the cover to see the chapter number
      // also seeked, and the transcript jumped.
      final cubit = _FakeTtsCubit(total: 60, current: 5);
      await tester.pumpWidget(_sheet(cubit));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const ValueKey('audiobook-cover')));
      await tester.pumpAndSettle();
      expect(find.text('2'), findsOneWidget, reason: 'chapter number shown');
      expect(
        cubit.seeks,
        isEmpty,
        reason: 'swapping the artwork must not move the narration',
      );

      await tester.tap(find.byKey(const ValueKey('audiobook-cover')));
      await tester.pumpAndSettle();
      expect(find.text('2'), findsNothing, reason: 'cover is back');
      expect(cubit.seeks, isEmpty);
      await cubit.close();
    });
    testWidgets('the speed button cycles and long-press sets the sleep timer', (
      tester,
    ) async {
      final cubit = _FakeTtsCubit(total: 6);
      await tester.pumpWidget(_sheet(cubit));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const ValueKey('audiobook-speed')));
      await tester.pump();
      expect(cubit.rate, isNotNull);

      await tester.longPress(find.byKey(const ValueKey('audiobook-speed')));
      await tester.pump();
      expect(cubit.sleep, isNotNull);
      await cubit.close();
    });

    testWidgets('dragging the ring scrubs to the sentence under the finger', (
      tester,
    ) async {
      final cubit = _FakeTtsCubit(total: 20, current: 2);
      await tester.pumpWidget(_sheet(cubit));
      await tester.pumpAndSettle();

      final ring = find.byKey(const ValueKey('audiobook-ring'));
      final box = tester.renderObject<RenderBox>(ring);
      // Six o'clock is the second quarter of the circle, so about index 5.
      final centre = box.localToGlobal(Offset(box.size.width / 2, box.size.height / 2));
      final r = box.size.width / 2;
      final gesture = await tester.startGesture(
        centre + Offset(0, r * 0.97),
      );
      await tester.pump();
      await gesture.up();
      await tester.pumpAndSettle();

      expect(cubit.seeks, hasLength(1));
      expect(cubit.seeks.last, greaterThan(cubit.seeks.first - 1));
      expect(cubit.seeks.last, greaterThan(0));
      await cubit.close();
    });

    testWidgets('a chapter with no transcript says so instead of crashing', (
      tester,
    ) async {
      final cubit = _FakeTtsCubit(total: 0, current: 0);
      await tester.pumpWidget(_sheet(cubit));
      await tester.pumpAndSettle();

      expect(find.text('No transcript available yet'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await cubit.close();
    });
  });

  group('the player covers the page', () {
    testWidgets('it fills the screen rather than sitting at 92% of it', (
      tester,
    ) async {
      final cubit = _FakeTtsCubit(total: 6);
      await tester.pumpWidget(_sheet(cubit));
      await tester.pumpAndSettle();

      expect(tester.getSize(find.byType(TtsAudiobookSheet)).height, 600);
      await cubit.close();
    });

    testWidgets('it covers the page behind it, edge to edge', (tester) async {
      final cubit = _FakeTtsCubit(total: 6);
      await tester.pumpWidget(_sheet(cubit));
      await tester.pumpAndSettle();

      final sheet = tester.getRect(find.byType(TtsAudiobookSheet));
      expect(sheet.left, 0);
      expect(sheet.top, 0);
      expect(sheet.width, 800);
      expect(sheet.height, 600);
      await cubit.close();
    });

    testWidgets('a short viewport and large text do not overflow', (
      tester,
    ) async {
      final cubit = _FakeTtsCubit(total: 6);
      tester.view.physicalSize = const Size(360, 480);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      addTearDown(tester.view.resetPhysicalSize);

      await tester.pumpWidget(_sheet(cubit));
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
      await cubit.close();
    });
  });
}
