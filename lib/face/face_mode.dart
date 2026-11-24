import 'dart:ui' show Color;

/// What the face is doing. Each mode has its own colour, motion and sound.
enum FaceMode { idle, speaking, listening, action }

/// Colours of a mode: [core] fills the geometric shapes, [aura] is the translucent glow layer.
class FacePalette {
  const FacePalette(this.core, this.aura);

  final Color core;
  final Color aura;

  static const idle = FacePalette(Color(0xFF8C929C), Color(0xFFB9C0CB)); // grey
  static const speaking = FacePalette(Color(0xFF1E8CFF), Color(0xFF4FC8FF)); // energetic blue
  static const listening = FacePalette(Color(0xFFA23CFF), Color(0xFFD08CFF)); // energetic purple
  static const action = FacePalette(Color(0xFFD9B44A), Color(0xFFF3DC95)); // calm yellow

  static FacePalette of(FaceMode mode) => switch (mode) {
        FaceMode.idle => idle,
        FaceMode.speaking => speaking,
        FaceMode.listening => listening,
        FaceMode.action => action,
      };

  static FacePalette lerp(FacePalette a, FacePalette b, double t) =>
      FacePalette(Color.lerp(a.core, b.core, t)!, Color.lerp(a.aura, b.aura, t)!);
}
