import 'dart:ui';

import 'package:flutter/material.dart';

import 'services/call_overlay_service.dart';

/// Content of the floating system-overlay window shown while a voice call is
/// live and the app is backgrounded (see [CallOverlayService]). Runs in its
/// own, separate Flutter engine — no Firebase, no app services, nothing from
/// the main isolate is available here, only what this file imports directly.
class CallOverlayBubble extends StatelessWidget {
  const CallOverlayBubble({super.key});

  void _stop() {
    final port = IsolateNameServer.lookupPortByName(CallOverlayService.portName);
    port?.send('stop');
  }

  @override
  Widget build(BuildContext context) {
    const ember = Color(0xFFDE8E69);
    const ink = Color(0xFF1A1714);
    return Material(
      color: Colors.transparent,
      child: Center(
        child: Container(
          width: 84,
          height: 84,
          decoration: BoxDecoration(
            color: const Color(0xFF1B1916),
            shape: BoxShape.circle,
            border: Border.all(color: ember, width: 1.5),
            boxShadow: const [
              BoxShadow(color: Colors.black45, blurRadius: 12),
            ],
          ),
          child: Stack(
            alignment: Alignment.center,
            children: [
              const Icon(Icons.graphic_eq_rounded, color: ember, size: 30),
              Positioned(
                top: 2,
                right: 2,
                child: GestureDetector(
                  onTap: _stop,
                  child: Container(
                    width: 24,
                    height: 24,
                    decoration: const BoxDecoration(
                      color: ember,
                      shape: BoxShape.circle,
                    ),
                    child: const Icon(Icons.stop_rounded,
                        size: 15, color: ink),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
