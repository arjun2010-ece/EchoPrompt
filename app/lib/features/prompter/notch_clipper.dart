import 'dart:math' as math;

import 'package:flutter/widgets.dart';

/// Square top edge with a slight outward flare and rounded bottom corners, so
/// the prompt reads as one surface with the hardware notch.
class NotchClipper extends CustomClipper<Path> {
  const NotchClipper();

  static const flare = 8.0;
  static const bottomRadius = 18.0;

  @override
  Path getClip(Size size) {
    const f = flare;
    final r = math.min(bottomRadius, size.height / 2);
    final w = size.width, h = size.height;
    return Path()
      ..moveTo(0, 0)
      ..lineTo(w, 0)
      ..quadraticBezierTo(w - f, 0, w - f, f)
      ..lineTo(w - f, h - r)
      ..quadraticBezierTo(w - f, h, w - f - r, h)
      ..lineTo(f + r, h)
      ..quadraticBezierTo(f, h, f, h - r)
      ..lineTo(f, f)
      ..quadraticBezierTo(f, 0, 0, 0)
      ..close();
  }

  @override
  bool shouldReclip(covariant CustomClipper<Path> old) => false;
}
