import 'dart:math' as math;
import 'dart:ui' show ImageFilter;

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:watch_app/core/reading/tts/tts_cubit.dart';
import 'package:watch_app/core/reading/tts/tts_prefs.dart';
import 'package:watch_app/core/reading/tts/tts_state.dart';
import 'package:watch_app/core/theme/app_colors.dart';


/// Opens the audiobook player over the reader.
///
/// No result and no reason: the player closed because the reader closed it. The
/// gesture that once reported "put the novel on the sentence being read" is
/// gone, and with it the only caller that cared what the sheet closed for.
Future<void> showTtsAudiobookSheet(
  BuildContext context, {
  required TtsCubit cubit,
  required String bookTitle,
  required String Function() chapterTitle,
  required bool Function() canPreviousChapter,
  required bool Function() canNextChapter,
  required VoidCallback onPreviousChapter,
  required VoidCallback onNextChapter,
  String? cover,
  List<String> chapterLabels = const [],
  List<String> chapterTitles = const [],
  int currentChapter = 0,
  ValueChanged<int>? onSelectChapter,
  VoidCallback? onOpenVoiceSettings,
}) {
  return Navigator.of(context).push(
    PageRouteBuilder<void>(
      fullscreenDialog: true,
      transitionDuration: const Duration(milliseconds: 220),
      reverseTransitionDuration: const Duration(milliseconds: 180),
      pageBuilder: (_, _, _) => TtsAudiobookSheet(
        cubit: cubit,
        bookTitle: bookTitle,
        chapterTitle: chapterTitle,
        canPreviousChapter: canPreviousChapter,
        canNextChapter: canNextChapter,
        onPreviousChapter: onPreviousChapter,
        onNextChapter: onNextChapter,
        cover: cover,
        chapterLabels: chapterLabels,
        chapterTitles: chapterTitles,
        currentChapter: currentChapter,
        onSelectChapter: onSelectChapter,
        onOpenVoiceSettings: onOpenVoiceSettings,
      ),
      transitionsBuilder: (_, animation, _, child) {
        final curved = CurvedAnimation(
          parent: animation,
          curve: Curves.easeOutCubic,
        );
        return FadeTransition(
          opacity: curved,
          child: SlideTransition(
            position: Tween<Offset>(
              begin: const Offset(0, 0.04),
              end: Offset.zero,
            ).animate(curved),
            child: child,
          ),
        );
      },
    ),
  );
}


/// Words per minute the engine manages at 1.0x, used for the time-left figure.
///
/// A rough average rather than a measured rate: the real one varies with the
/// voice and the language, and a number that is approximately right is more use
/// than no number at all on a screen where the reader is deciding whether to
/// start a chapter or save it for later.
const double _wordsPerMinuteAt1x = 170;

/// The audiobook player: a segmented ring around the cover, the sentences
/// either side of the one being spoken, and one row of transport.
///
/// The transcript used to be a second page reached by a toggle, which meant the
/// thing you wanted while listening - the words around the one being read - was
/// behind a navigation. It is here instead, and there is no second page.
class TtsAudiobookSheet extends StatefulWidget {
  const TtsAudiobookSheet({
    super.key,
    required this.cubit,
    required this.bookTitle,
    required this.chapterTitle,
    required this.canPreviousChapter,
    required this.canNextChapter,
    required this.onPreviousChapter,
    required this.onNextChapter,
    this.cover,
    this.chapterLabels = const [],
    this.chapterTitles = const [],
    this.currentChapter = 0,
    this.onSelectChapter,
    this.onOpenVoiceSettings,
  });

  final TtsCubit cubit;
  final String bookTitle;

  /// Read on every build, not captured once: auto-advance changes the chapter
  /// while this is open and the title has to follow it.
  final String Function() chapterTitle;

  final bool Function() canPreviousChapter;
  final bool Function() canNextChapter;
  final VoidCallback onPreviousChapter;
  final VoidCallback onNextChapter;
  final String? cover;

  /// Chapter numbers and titles for the chapter sheet. Empty means the sheet is
  /// not offered, rather than offered and blank.
  final List<String> chapterLabels;
  final List<String> chapterTitles;
  final int currentChapter;

  /// Null when there is nothing to pick from, which hides the chapters button
  /// rather than opening a sheet with no rows.
  final ValueChanged<int>? onSelectChapter;

  /// Long-press on the cover. Null removes the long-press.
  final VoidCallback? onOpenVoiceSettings;

  @override
  State<TtsAudiobookSheet> createState() => _TtsAudiobookSheetState();
}

class _TtsAudiobookSheetState extends State<TtsAudiobookSheet> {
  /// Sentence under the finger while the ring is being scrubbed, or null when
  /// it is not. Null is what makes the counter say "Jump to" instead of
  /// "Sentence" - without it the reader cannot tell a preview from a commit.
  int? _scrub;

  /// Whether the middle of the ring shows the chapter number instead of the
  /// cover.
  ///
  /// Tapping the cover swaps it for the number, and tapping again brings the
  /// artwork back - a second thing to look at in the same place, for the reader
  /// who is part-way through a chapter and wants to know how far in they are
  /// without opening the chapter sheet.
  bool _showChapterNumber = false;


  /// The sentence being spoken, clamped into the list.
  int get _current {
    final total = widget.cubit.state.totalSentences;
    if (total == 0) return 0;
    return widget.cubit.state.currentIndex.clamp(0, total - 1);
  }



  Future<void> _openChapters() async {
    final select = widget.onSelectChapter;
    if (select == null) return;
    final picked = await showModalBottomSheet<int>(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (sheetContext) => _ChapterSheet(
        labels: widget.chapterLabels,
        titles: widget.chapterTitles,
        current: widget.currentChapter,
        onShuffle: () {
          final total = widget.cubit.state.totalSentences;
          if (total < 2) return;
          final next = math.Random().nextInt(total);
          if (next != _current) widget.cubit.seek(next);
        },
      ),
    );
    if (picked != null) select(picked);
  }

  @override
  Widget build(BuildContext context) {
    // Material, not a ColoredBox: the controls are InkWells, which assert on a
    // missing Material ancestor when they build.
    return Material(
      color: AppColors.bg,
      child: BlocBuilder<TtsCubit, TtsState>(
        bloc: widget.cubit,
        builder: (context, state) {
          final total = state.totalSentences;
          return Stack(
            fit: StackFit.expand,
            children: [
              _BlurredBackdrop(cover: widget.cover),
              SafeArea(
                child: Column(
                    children: [
                      _Header(
                        onClose: () => Navigator.of(context).pop(),
                        chapterLabel: _chapterLabel(widget.currentChapter),
                        chapterTitle: widget.chapterTitle(),
                        bookTitle: widget.bookTitle,
                        onOpenChapters:
                            widget.onSelectChapter == null ? null : _openChapters,
                      ),
Expanded(
                          child: Column(
                            children: [
                              _SentenceRing(
                                  total: total,
                                  index: _scrub ?? _current,
                                  scrubbing: _scrub != null,
                                  playing: state.isSpeaking,
                                  cover: widget.cover,
                                  chapterNumber: _chapterLabel(
                                    widget.currentChapter,
                                  ),
                                  showChapterNumber: _showChapterNumber,
                                  onCoverTap: () => setState(
                                    () => _showChapterNumber =
                                        !_showChapterNumber,
                                  ),
                                  onCoverLongPress:
                                      widget.onOpenVoiceSettings,
                                  onScrubStart: (i) => setState(() => _scrub = i),
                                  onScrubUpdate: (i) {
                                    if (_scrub == i) return;
                                    setState(() => _scrub = i);
                                    HapticFeedback.selectionClick();
                                  },
                                  onScrubEnd: (i) {
                                  setState(() => _scrub = null);
                                  if (i != state.currentIndex) {
                                    widget.cubit.seek(i);
                                  }
                                },
                                // A cancelled scrub is not one the reader
                                // chose - the cover's tap won the arena - so
                                // this puts the ring back and seeks nothing.
                                onScrubCancel: () => setState(() => _scrub = null),
                                ),
                                const SizedBox(height: 12),
_Counter(
                                  index: _scrub ?? _current,
                                  total: total,
                                  sentences: state.sentences,
                                  rate: state.rate,
                                  scrubbing: _scrub != null,
                                ),
                                const SizedBox(height: 18),
                                // Expanded, not Flexible: this Column is bounded
                                // by the sheet, so the transcript can claim
                                // every pixel the ring and the bar leave it -
                                // the old lyrics page had the whole lower half
                                // of the screen and read accordingly.
                                Expanded(
                                  child: _Transcript(
                                    sentences: state.sentences,
                                    current: _current,
                                    onPick: (i) => widget.cubit.seek(i),
                                  ),
                                ),
                            ],
                          ),
                      ),
                      _PlayerBar(
                        canPreviousChapter: widget.canPreviousChapter(),
                        canNextChapter: widget.canNextChapter(),
                        onPreviousChapter: widget.onPreviousChapter,
                        onNextChapter: widget.onNextChapter,
                        onBack: total == 0 ? null : () => widget.cubit.skip(-1),
                        onForward: total == 0 ? null : () => widget.cubit.skip(1),
                        onPlayPause: widget.cubit.toggle,
                        playing: state.isSpeaking,
                        rate: state.rate,
                        sleepMinutes: state.sleepTimerMinutes,
                        onRate: () => widget.cubit.setRate(
                          TtsSpeed.next(state.rate),
                        ),
                        // Long-press rather than a seventh button: the bar is
                        // already seven across on a narrow phone, and the sleep
                        // timer is something a reader sets once and forgets.
                        onSleep: () => widget.cubit.setSleepTimer(
                          _nextSleep(state.sleepTimerMinutes),
                        ),
                        onChapters: widget.onSelectChapter == null
                            ? null
                            : _openChapters,
                      ),
                      const SizedBox(height: 8),
                    ],
                  ),
              ),
            ],
          );
        },
      ),
    );
  }

  String _chapterLabel(int index) {
    if (index >= 0 && index < widget.chapterLabels.length) {
      return widget.chapterLabels[index];
    }
    return 'Chapter ${index + 1}';
  }
}

/// Sleep timer steps. Zero is off, and it is the state it returns to.
const List<int> _kSleepCycle = <int>[0, 15, 30, 60];

int _nextSleep(int current) {
  final at = _kSleepCycle.indexOf(current);
  return _kSleepCycle[(at + 1) % _kSleepCycle.length];
}

/// Close on the left, and the chapter itself as the way into the chapter list.
class _Header extends StatelessWidget {
  const _Header({
    required this.onClose,
    required this.chapterLabel,
    required this.chapterTitle,
    required this.bookTitle,
    this.onOpenChapters,
  });

  final VoidCallback onClose;
  final String chapterLabel;
  final String chapterTitle;
  final String bookTitle;
  final VoidCallback? onOpenChapters;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 6, 16, 6),
      child: Row(
        children: [
          IconButton(
            key: const ValueKey('audiobook-sheet-close'),
            tooltip: 'Close player',
            onPressed: onClose,
            icon: const Icon(Icons.keyboard_arrow_down_rounded, size: 28),
            color: AppColors.textPrimary,
          ),
          const SizedBox(width: 4),
          Expanded(
            child: onOpenChapters == null
                ? _titles()
                : InkWell(
                    key: const ValueKey('audiobook-open-chapters'),
                    onTap: onOpenChapters,
                    borderRadius: BorderRadius.circular(10),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                        vertical: 6,
                        horizontal: 4,
                      ),
                      child: _titles(),
                    ),
                  ),
          ),
        ],
      ),
    );
  }

Widget _titles() => Column(
        crossAxisAlignment: CrossAxisAlignment.center,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            // The chapter's own text, once. Many sources already number it
            // ("CH.1: Nightmare Begins"), so printing the number beside it
            // reads the chapter twice - and where the source numbers it
            // differently from the app's own index, the two disagree on screen.
            chapterTitle,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              color: AppColors.textPrimary,
              fontSize: 15,
              fontWeight: FontWeight.w500,
            ),
          ),
          const SizedBox(height: 2),
          Text(
            bookTitle,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              color: AppColors.textSecondary,
              fontSize: 12,
              fontWeight: FontWeight.w400,
            ),
          ),
        ],
      );
}

/// One arc per sentence, arranged into a ring, with the cover in the middle.
///
/// The ring is the seek control, so it doubles as a map of the chapter: every
/// sentence the chapter has is an arc, the ones already read are lit, the one
/// being spoken is thick and accented, and the rest are barely there. Dragging
/// anywhere on it scrubs by angle.
class _SentenceRing extends StatelessWidget {
  const _SentenceRing({
    required this.total,
    required this.index,
    required this.scrubbing,
    required this.playing,
required this.cover,
    required this.chapterNumber,
    required this.showChapterNumber,
    required this.onCoverTap,
    required this.onCoverLongPress,
    required this.onScrubStart,
    required this.onScrubUpdate,
    required this.onScrubEnd,
    required this.onScrubCancel,
  });

  final int total;
  final int index;
  final bool scrubbing;
  final bool playing;
  final String? cover;

  /// Shown in place of the artwork while [showChapterNumber] is set.
  final String chapterNumber;
  final bool showChapterNumber;

  final VoidCallback onCoverTap;
  final VoidCallback? onCoverLongPress;
  final ValueChanged<int> onScrubStart;
  final ValueChanged<int> onScrubUpdate;
  final ValueChanged<int> onScrubEnd;

  /// A scrub that lost the gesture arena. Puts the ring back without seeking,
  /// because a cancelled scrub is not one the reader asked for.
  final VoidCallback onScrubCancel;

  static const double _stroke = 6;
  static const double _currentStroke = 9;
  static const double _dimOpacity = 0.2;

  /// The sentence whose arc the touch is inside, by angle from twelve o'clock.
  ///
  /// Clamped rather than wrapped at the ends: dragging past the start parks on
  /// the first sentence rather than jumping to the last, which is what an
  /// unbounded angle would do and reads as the ring being broken.
  int _indexAt(Offset local, Size size) {
    if (total <= 1) return 0;
    final centre = Offset(size.width / 2, size.height / 2);
    var angle = math.atan2(local.dy - centre.dy, local.dx - centre.dx) +
        math.pi / 2;
    if (angle < 0) angle += 2 * math.pi;
    return (angle / (2 * math.pi) * total).floor().clamp(0, total - 1);
  }

  /// True when [local] is on the cover rather than on the ring.
  ///
  /// `onPanDown` fires on pointer-DOWN, before the gesture arena resolves, so
  /// the pan recogniser sees every tap inside the ring - including one aimed at
  /// the cover in the middle of it. It then loses the arena to the cover's
  /// InkWell, and the cancel committed whatever angle the tap pointed at, which
  /// is somewhere around a quarter of the way round the chapter. That is why
  /// tapping the cover moved the reading on: a scrub that started by accident
  /// and was committed by the cancel.
  ///
  /// Measured against the same 0.826 width factor the cover disc is built with.
  /// Almost no slack, because the band of ring left outside the cover is only
  /// about a ninth of the box - a 140px ring leaves twelve pixels of it, and
  /// a few pixels of slack here swallows half the scrub area.
  bool _isOnCover(Offset local, Size size) {
    final centre = Offset(size.width / 2, size.height / 2);
    final coverRadius = size.shortestSide * 0.413 + 1;
    return (local - centre).distance <= coverRadius;
  }

  @override
  Widget build(BuildContext context) {
    final fraction = MediaQuery.sizeOf(context).height;
    final side = math.max(140.0, math.min(240.0, fraction * 0.23));
    return Center(
      child: SizedBox(
        key: const ValueKey('audiobook-ring'),
        width: side,
        height: side,
        child: LayoutBuilder(
          builder: (context, c) {
            final size = Size(c.maxWidth, c.maxHeight);
            return GestureDetector(
              behavior: HitTestBehavior.opaque,
              // Both ignored on the cover, so tapping it only swaps the artwork for the
              // chapter number and never starts a scrub.
              onPanDown: (d) {
                if (_isOnCover(d.localPosition, size)) return;
                onScrubStart(_indexAt(d.localPosition, size));
              },
              onPanUpdate: (d) {
                if (_isOnCover(d.localPosition, size)) return;
                onScrubUpdate(_indexAt(d.localPosition, size));
              },
              // Only ever reached when this pan WON the arena - a loser is sent
              // to onPanCancel instead - so committing here commits something the
              // reader actually chose.
              onPanEnd: (_) => onScrubEnd(index),
              // Cancelled, not committed. A cancel means this gesture lost -
              // to the cover's tap, most often - so whatever angle it had
              // reached is not something the reader chose. Seeking here is what
              // made tapping the cover move the reading on.
              onPanCancel: onScrubCancel,
              child: Stack(
                alignment: Alignment.center,
                children: [
                  Positioned.fill(
                    child: CustomPaint(
                      painter: _RingPainter(
                        total: total,
                        index: index,
                        scrubbing: scrubbing,
                        // Only the live sentence breathes. While scrubbing, a
                        // pulsing arc moves to a target the reader has not
                        // committed to, which draws the eye to the wrong place.
                        pulse: playing && !scrubbing,
                      ),
                    ),
                  ),
_CoverDisc(
                    cover: cover,
                    chapterNumber: chapterNumber,
                    showChapterNumber: showChapterNumber,
                    onTap: onCoverTap,
                    onLongPress: onCoverLongPress,
                  ),
                ],
              ),
            );
          },
        ),
      ),
    );
  }
}

class _CoverDisc extends StatelessWidget {
  const _CoverDisc({
    required this.cover,
    required this.chapterNumber,
    required this.showChapterNumber,
    required this.onTap,
    this.onLongPress,
  });

  final String? cover;
  final String chapterNumber;
  final bool showChapterNumber;
  final VoidCallback onTap;
  final VoidCallback? onLongPress;

  @override
  Widget build(BuildContext context) {
    final hasCover = cover != null && cover!.isNotEmpty;
    return FractionallySizedBox(
      widthFactor: 0.826,
      child: AspectRatio(
        aspectRatio: 1,
        child: Material(
          color: AppColors.surface2,
          shape: const CircleBorder(),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            key: const ValueKey('audiobook-cover'),
            onTap: onTap,
            onLongPress: onLongPress,
            child: showChapterNumber
                // Sized to fit either side of the disc, so a three-digit
                // chapter number is not clipped by the circle.
                ? FittedBox(
                    fit: BoxFit.scaleDown,
                    child: Padding(
                      padding: const EdgeInsets.all(18),
                      child: Text(
                        chapterNumber,
                        style: const TextStyle(
                          color: AppColors.textPrimary,
                          fontSize: 56,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                  )
                : hasCover
                ? CachedNetworkImage(
                    imageUrl: cover!,
                    fit: BoxFit.cover,
                    errorWidget: (_, _, _) => const Icon(
                      Icons.menu_book_rounded,
                      size: 64,
                      color: AppColors.textTertiary,
                    ),
                  )
                : const Icon(
                    Icons.menu_book_rounded,
                    size: 64,
                    color: AppColors.textTertiary,
                  ),
          ),
        ),
      ),
    );
  }
}

class _RingPainter extends CustomPainter {
  _RingPainter({
    required this.total,
    required this.index,
    required this.scrubbing,
    required this.pulse,
  });

  final int total;
  final int index;
  final bool scrubbing;
  final bool pulse;

  @override
  void paint(Canvas canvas, Size size) {
    if (total <= 0) return;
    final centre = size.center(Offset.zero);
    final radius = (size.shortestSide / 2) -
        (index == 0 ? _SentenceRing._currentStroke : _SentenceRing._stroke) / 2;
    const sweep = 2 * math.pi;
    // A gap of 30% of each slot, so the ring reads as separate arcs rather than
    // as one thick circle with a highlight on it.
    final slot = sweep / total;
    final arc = slot * 0.7;
    // Breathing is an opacity change, not a geometry one: an arc that grows and
    // shrinks shifts its own neighbours' apparent spacing.
    final currentAlpha = pulse ? 0.5 : 1.0;

    for (var i = 0; i < total; i++) {
      final paint = Paint()
        ..style = PaintingStyle.stroke
        ..strokeCap = StrokeCap.round
        ..strokeWidth = i == index ? _SentenceRing._currentStroke : _SentenceRing._stroke;
      if (i == index) {
        paint.color = AppColors.accent.withValues(alpha: currentAlpha);
      } else {
        paint.color = AppColors.textPrimary.withValues(
          alpha: i < index ? 0.85 : _SentenceRing._dimOpacity,
        );
      }
      canvas.drawArc(
        Rect.fromCircle(center: centre, radius: radius),
        -math.pi / 2 + i * slot,
        arc,
        false,
        paint,
      );
    }

    // The thumb sits on the boundary just after the current arc, so it reads
    // as a position on the ring rather than as one more arc.
    final a = -math.pi / 2 + (index + 0.5) * slot;
    final thumb = centre +
        Offset(math.cos(a) * radius, math.sin(a) * radius);
    canvas.drawCircle(
      thumb,
      7,
      Paint()..color = AppColors.textPrimary,
    );
    canvas.drawCircle(
      thumb,
      7,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 3
        ..color = AppColors.accent,
    );
  }

  @override
  bool shouldRepaint(_RingPainter old) =>
      old.total != total ||
      old.index != index ||
      old.scrubbing != scrubbing ||
      old.pulse != pulse;
}

/// "Sentence 27 of 90", plus how long the rest of the chapter should take.
class _Counter extends StatelessWidget {
  const _Counter({
    required this.index,
    required this.total,
    required this.rate,
    required this.scrubbing,
    required this.sentences,
  });

  final int index;
  final int total;
  final double rate;
  final bool scrubbing;
  final List<TtsSentenceView> sentences;

  /// Words left to read, and the minutes that is at the current speed.
  String? get _remaining {
    if (sentences.isEmpty) return null;
    var words = 0;
    for (var i = index; i < sentences.length; i++) {
      words += sentences[i].text.trim().split(RegExp(r'\s+')).length;
    }
    final minutes = words / (_wordsPerMinuteAt1x * (rate <= 0 ? 1 : rate));
    if (minutes < 1) return '<1 min left';
    return '~${minutes.round()} min left';
  }

  @override
  Widget build(BuildContext context) {
    final remaining = _remaining;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 20),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Text(
            scrubbing ? 'Jump to' : 'Sentence',
            style: TextStyle(
              color: scrubbing ? AppColors.accent : AppColors.textSecondary,
              fontSize: 12,
            ),
          ),
          Text(
            ' ${index + 1}',
            style: const TextStyle(
              color: AppColors.textPrimary,
              fontSize: 14,
              fontWeight: FontWeight.w500,
            ),
          ),
          Text(
            ' / $total',
            style: const TextStyle(
              color: AppColors.textSecondary,
              fontSize: 12,
            ),
          ),
if (remaining != null) ...[
            const SizedBox(width: 10),
            // Flexible, because this Row's other children are text and cannot
            // shrink: on a 360px screen at a large system font a fixed trailing
            // label overflows the row by a fraction of a pixel.
            Flexible(
              child: Text(
                remaining,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  color: AppColors.textSecondary,
                  fontSize: 12,
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}
/// The chapter's whole transcript, with the sentence being spoken held in the
/// middle of the screen.
///
/// This is what the old lyrics page was, and it is deliberately unchanged by
/// the merge. An earlier pass replaced it with five lines either side of the
/// spoken sentence on the theory that reading along only needs the
/// neighbourhood - and that version was worse to read: one line per sentence,
/// no way to see where in the chapter you are, and no way to find a line you
/// half remember without dragging a five-item list.
///
/// The auto-follow is the whole reason it works. A lazily built list has no
/// context for a line it has never laid out, so a sentence near the end of a
/// long chapter cannot simply be measured - there is nothing to measure. So this
/// converges instead: jump to an estimate, which builds the line, then correct
/// using the average height of the lines that are now genuinely on screen, and
/// repeat.
///
/// The correction matters. Estimating from character counts alone assumes a
/// font's average glyph width, and a wider font - a bold face, a large system
/// text scale - makes every guess short and the target lands further and
/// further below the viewport.
class _Transcript extends StatefulWidget {
  const _Transcript({
    required this.sentences,
    required this.current,
    required this.onPick,
  });

  final List<TtsSentenceView> sentences;
  final int current;
  final ValueChanged<int> onPick;

  @override
  State<_Transcript> createState() => _TranscriptState();
}

class _TranscriptState extends State<_Transcript> {
  final _scroll = ScrollController();
  final _keys = <int, GlobalKey>{};
  int _lastRevealed = -1;

  // Shared by the real rows and by [_estimateExtent], so the estimate cannot
  // drift away from the layout it is estimating.
  static const double _rowPadding = 10;
  static const double _gutter = 26;
  static const double _fontIdle = 17;
  static const double _fontActive = 22;
  static const double _lineHeight = 1.45;

  /// How many frames one reveal may spend converging. Generous on purpose: the
  /// first open usually spends the first frame waiting for the list to attach,
  /// and a budget sized for the steady state runs out exactly when the reader
  /// most needs the view to move.
  static const int _maxRevealAttempts = 12;

  /// Space above the first sentence and below the last, as a fraction of the
  /// screen.
  ///
  /// Asymmetric on purpose. This is what lets [Scrollable.ensureVisible] put
  /// the spoken sentence in the middle of the screen: the list needs room
  /// above and below the row to scroll it to the centre. Symmetric at a fifth
  /// each, which is what this used to be, the top of it is dead space on open -
  /// a fifth of the screen of nothing above the first sentence, which is what
  /// a reader sees every time they open the player on a long chapter.
  ///
  /// So the top is barely anything, and the room to centre is spent at the
  /// bottom, where a reader scrolled to the end of a chapter is the only person
  /// who needs it. Sentences near the end centre less precisely than they used
  /// to; that is the trade, and it is the right way round.
  static const double _padTopFraction = 0.03;
  static const double _padBottomFraction = 0.34;

  @override
  void initState() {
    super.initState();
    // Built fresh every time this is opened, and didUpdateWidget does not fire
    // for a widget's own first build. Without this the view opened at the top
    // of the chapter and the reader had to scroll to find the sentence being
    // read.
    _revealCurrent();
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  @override
  void didUpdateWidget(covariant _Transcript old) {
    super.didUpdateWidget(old);
    if (widget.current != _lastRevealed) _revealCurrent();
  }

  void _revealCurrent() {
    final index = widget.current;
    if (index == _lastRevealed) return;
    _lastRevealed = index;
    WidgetsBinding.instance.addPostFrameCallback((_) => _reveal(index));
  }

  /// Puts sentence [index] in the middle of the view.
  void _reveal(int index) {
    if (!mounted) return;
    WidgetsBinding.instance.addPostFrameCallback((_) => _step(index, 0));
  }

  void _step(int index, int attempt) {
    if (!mounted || attempt > _maxRevealAttempts) return;

    // Built, and therefore measurable: hand it to the viewport, which puts it
    // in the middle and finishes the job.
    final ctx = _keys[index]?.currentContext;
    if (ctx != null) {
      Scrollable.ensureVisible(
        ctx,
        alignment: 0.5,
        duration: const Duration(milliseconds: 320),
        curve: Curves.easeOutCubic,
      );
      return;
    }

    // Not built yet, so make it build. Jumping to where the row ought to be
    // lays it out; the next frame can then measure it and correct.
    //
    // Neither "no scroll position yet" nor "already at the target offset" ends
    // the search. Both used to clear the guard and give up, and both are the
    // normal state of affairs on the first frame of a freshly opened
    // transcript: nothing had attached yet, so the reveal was abandoned, the
    // chapter stayed at its top, and the view only started following the voice
    // once the reader had scrolled - which is also what laid out the rows the
    // second attempt needed.
    if (_scroll.hasClients) {
      final position = _scroll.position;
      final average = _measuredAverageExtent() ?? _estimateExtent(index);
      final top = MediaQuery.sizeOf(context).height * _padTopFraction;
      final target = (top + average * index).clamp(
        position.minScrollExtent,
        position.maxScrollExtent,
      );
      if ((target - position.pixels).abs() > 1) _scroll.jumpTo(target);
    }
    WidgetsBinding.instance.addPostFrameCallback(
      (_) => _step(index, attempt + 1),
    );
  }

  /// Average height of the rows currently laid out, or null when nothing has
  /// been built yet.
  double? _measuredAverageExtent() {
    var total = 0.0;
    var count = 0;
    for (final key in _keys.values) {
      final ctx = key.currentContext;
      if (ctx == null) continue;
      final box = ctx.findRenderObject();
      if (box is RenderBox && box.hasSize && box.size.height > 0) {
        total += box.size.height;
        count++;
      }
    }
    return count == 0 ? null : total / count;
  }

  /// First-guess height of a row, from its text. Only a starting point;
  /// [_measuredAverageExtent] replaces it as soon as any real row has laid out.
  double _estimateExtent(int index) {
    final sentences = widget.sentences;
    final text = index < sentences.length ? sentences[index].text.trim() : '';
    final width = MediaQuery.sizeOf(context).width - _gutter * 2;
    final perLine = math.max(8.0, width / (_fontIdle * 0.52));
    final lines = text.isEmpty ? 1 : (text.length / perLine).ceil();
    return lines * _fontIdle * _lineHeight + _rowPadding * 2;
  }

  @override
  Widget build(BuildContext context) {
    final sentences = widget.sentences;
    _keys.removeWhere((i, _) => i >= sentences.length);
    if (sentences.isEmpty) {
      return const Center(
        child: Text(
          'No transcript available yet',
          style: TextStyle(color: AppColors.textSecondary),
        ),
      );
    }
    final viewport = MediaQuery.sizeOf(context).height;
    final top = viewport * _TranscriptState._padTopFraction;
    return ListView.builder(
      key: const ValueKey('audiobook-transcript'),
      controller: _scroll,
      padding: EdgeInsets.only(
        top: top,
        bottom: viewport * _TranscriptState._padBottomFraction,
        left: _gutter,
        right: _gutter,
      ),
      itemCount: sentences.length,
      itemBuilder: (context, i) {
        final active = i == widget.current;
        return GestureDetector(
          key: _keys.putIfAbsent(i, GlobalKey.new),
          behavior: HitTestBehavior.opaque,
          onTap: active ? null : () => widget.onPick(i),
          child: Padding(
            // A second, stable key alongside the measurement key: the
            // GlobalKey moves with the row it is attached to, and a test - or a
            // future gesture aimed at one sentence - needs to name a row by
            // index.
            key: ValueKey('audiobook-row-$i'),
            padding: const EdgeInsets.symmetric(vertical: _rowPadding),
            child: Text(
              sentences[i].text,
              textAlign: TextAlign.center,
              style: TextStyle(
                color: active
                    ? AppColors.textPrimary
                    : AppColors.textPrimary.withValues(alpha: 0.55),
                fontSize: active ? _fontActive : _fontIdle,
                height: _lineHeight,
                fontWeight: active ? FontWeight.w600 : FontWeight.w400,
              ),
            ),
          ),
        );
      },
    );
  }
}

/// The one row of transport, plus the chapter list behind its first button.
class _PlayerBar extends StatelessWidget {
  const _PlayerBar({
    required this.canPreviousChapter,
    required this.canNextChapter,
    required this.onPreviousChapter,
    required this.onNextChapter,
    required this.onBack,
    required this.onForward,
    required this.onPlayPause,
    required this.playing,
    required this.rate,
    required this.sleepMinutes,
    required this.onRate,
    required this.onSleep,
    required this.onChapters,
  });

  final bool canPreviousChapter;
  final bool canNextChapter;
  final VoidCallback onPreviousChapter;
  final VoidCallback onNextChapter;
  final VoidCallback? onBack;
  final VoidCallback? onForward;
  final VoidCallback onPlayPause;
  final bool playing;
  final double rate;
  final int sleepMinutes;
  final VoidCallback onRate;
  final VoidCallback onSleep;
  final VoidCallback? onChapters;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(10, 0, 10, 0),
      child: Row(
        children: [
          _BarButton(
            key: const ValueKey('audiobook-chapters'),
            icon: Icons.list_rounded,
            tooltip: 'Chapters',
            onTap: onChapters,
          ),
          _BarButton(
            key: const ValueKey('audiobook-prev-chapter'),
            icon: Icons.skip_previous_rounded,
            tooltip: 'Previous chapter',
            onTap: canPreviousChapter ? onPreviousChapter : null,
          ),
          _BarButton(
            key: const ValueKey('audiobook-minus-sentence'),
            icon: Icons.chevron_left_rounded,
            tooltip: 'Back one sentence',
            onTap: onBack,
          ),
          Expanded(
            child: Center(
              child: _PlayButton(
                key: const ValueKey('audiobook-play'),
                playing: playing,
                onTap: onPlayPause,
              ),
            ),
          ),
          _BarButton(
            key: const ValueKey('audiobook-plus-sentence'),
            icon: Icons.chevron_right_rounded,
            tooltip: 'Forward one sentence',
            onTap: onForward,
          ),
          _BarButton(
            key: const ValueKey('audiobook-next-chapter'),
            icon: Icons.skip_next_rounded,
            tooltip: 'Next chapter',
            onTap: canNextChapter ? onNextChapter : null,
          ),
          _BarButton(
            key: const ValueKey('audiobook-speed'),
            label: sleepMinutes == 0
                ? '${rate.toStringAsFixed(rate == rate.roundToDouble() ? 0 : 1)}x'
                : '${sleepMinutes}m',
            tooltip: 'Speed· long-press for the sleep timer',
            onTap: onRate,
            onLongPress: onSleep,
          ),
        ],
      ),
    );
  }
}

class _BarButton extends StatelessWidget {
  const _BarButton({
    super.key,
    required this.tooltip,
    this.icon,
    this.label,
    this.onTap,
    this.onLongPress,
  });

  final String tooltip;
  final IconData? icon;
  final String? label;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;

  @override
  Widget build(BuildContext context) {
    final enabled = onTap != null;
    return Expanded(
      child: Tooltip(
        message: tooltip,
        child: InkResponse(
          onTap: onTap,
          onLongPress: onLongPress,
          radius: 22,
          child: SizedBox(
            height: 48,
            child: Center(
              child: label != null
                  ? Text(
                      label!,
                      style: TextStyle(
                        color: enabled
                            ? AppColors.textSecondary
                            : AppColors.textTertiary,
                        fontSize: 13,
                        fontWeight: FontWeight.w500,
                      ),
                    )
                  : Icon(
                      icon,
                      size: 23,
                      color: enabled
                          ? AppColors.textSecondary
                          : AppColors.textTertiary,
                    ),
            ),
          ),
        ),
      ),
    );
  }
}

class _PlayButton extends StatelessWidget {
  const _PlayButton({super.key, required this.playing, required this.onTap});

  final bool playing;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: playing ? 'Pause' : 'Play',
      child: InkResponse(
        radius: 30,
        onTap: onTap,
        child: Container(
          width: 56,
          height: 56,
          decoration: BoxDecoration(color: AppColors.accent, shape: BoxShape.circle),
          child: Icon(
            playing ? Icons.pause_rounded : Icons.play_arrow_rounded,
            size: 30,
            color: Colors.white,
          ),
        ),
      ),
    );
  }
}

class _ChapterSheet extends StatelessWidget {
  const _ChapterSheet({
    required this.labels,
    required this.titles,
    required this.current,
    required this.onShuffle,
  });

  final List<String> labels;
  final List<String> titles;
  final int current;
  final VoidCallback onShuffle;

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Container(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.sizeOf(context).height * 0.7,
        ),
        decoration: BoxDecoration(
          color: AppColors.surface,
          borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 14, 8, 6),
              child: Row(
                children: [
                  const Expanded(
                    child: Text(
                      'Chapters',
                      style: TextStyle(
                        color: AppColors.textPrimary,
                        fontSize: 14,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ),
                  TextButton.icon(
                    key: const ValueKey('audiobook-shuffle'),
                    onPressed: onShuffle,
                    icon: const Icon(Icons.shuffle_rounded, size: 18),
                    label: const Text('Random'),
                    style: TextButton.styleFrom(
                      foregroundColor: AppColors.accent,
                    ),
                  ),
                ],
              ),
            ),
            Flexible(
              child: ListView.builder(
                shrinkWrap: true,
                itemCount: labels.length,
                itemBuilder: (context, i) => InkWell(
                  key: ValueKey('audiobook-chapter-$i'),
                  onTap: () => Navigator.of(context).pop(i),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 16,
                      vertical: 12,
                    ),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        SizedBox(
                          width: 36,
                          child: Text(
                            labels[i],
                            style: TextStyle(
                              color: i == current
                                  ? AppColors.accent
                                  : AppColors.textSecondary,
                              fontSize: 13,
                            ),
                          ),
                        ),
                        Expanded(
                          child: Text(
                            i < titles.length ? titles[i] : '',
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              color: i == current
                                  ? AppColors.accent
                                  : AppColors.textPrimary,
                              fontSize: 14,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// The cover, blurred and dimmed, behind everything.
///
/// In a [RepaintBoundary] so a repaint never re-runs the blur.
class _BlurredBackdrop extends StatelessWidget {
  const _BlurredBackdrop({this.cover});

  final String? cover;

  @override
  Widget build(BuildContext context) {
    return RepaintBoundary(
      child: Stack(
        fit: StackFit.expand,
        children: [
          if (cover != null && cover!.isNotEmpty)
            ImageFiltered(
              imageFilter: ImageFilter.blur(sigmaX: 46, sigmaY: 46),
              child: CachedNetworkImage(
                imageUrl: cover!,
                fit: BoxFit.cover,
                errorWidget: (_, _, _) => const SizedBox.shrink(),
              ),
            ),
          DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [
                  AppColors.bg.withValues(alpha: 0.80),
                  AppColors.bg.withValues(alpha: 0.93),
                  AppColors.bg,
                ],
                stops: const [0, 0.45, 1],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
