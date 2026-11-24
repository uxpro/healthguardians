import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart';

import 'face_mode.dart';
import 'face_motion.dart';
import 'face_painter.dart';

/// The animated face, full size. Reads the mode and the loudness of the sound every frame.
class FaceView extends StatefulWidget {
  const FaceView({super.key, required this.mode, required this.envelope});

  final FaceMode Function() mode;
  final double Function() envelope;

  @override
  State<FaceView> createState() => _FaceViewState();
}

class _FaceViewState extends State<FaceView> with SingleTickerProviderStateMixin {
  final FaceMotion _motion = FaceMotion();
  late final ValueNotifier<FaceFrame> _frame;
  late final Ticker _ticker;
  Duration _last = Duration.zero;

  @override
  void initState() {
    super.initState();
    _motion.setMode(widget.mode());
    _frame = ValueNotifier(_motion.tick(0, 0));
    _ticker = createTicker(_onTick)..start();
  }

  void _onTick(Duration elapsed) {
    final dt = (elapsed - _last).inMicroseconds / 1e6;
    _last = elapsed;
    _motion.setMode(widget.mode());
    _frame.value = _motion.tick(dt, widget.envelope());
  }

  @override
  void dispose() {
    _ticker.dispose();
    _frame.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return RepaintBoundary(
      child: CustomPaint(painter: FacePainter(_frame), size: Size.infinite),
    );
  }
}
