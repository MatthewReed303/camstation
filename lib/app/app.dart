import 'dart:async';
import 'dart:io';
import 'dart:ui' show AppExitResponse;

import 'package:camstation/app/providers.dart';
import 'package:camstation/core/discovery/discovered_camera.dart';
import 'package:camstation/core/engine/engine_manager.dart';
import 'package:camstation/core/util/screen_awake.dart';
import 'package:camstation/features/add_camera/add_camera_screen.dart';
import 'package:camstation/features/camera_list/camera_list_screen.dart';
import 'package:camstation/features/camera_settings/camera_settings_screen.dart';
import 'package:camstation/features/discovery/discover_screen.dart';
import 'package:camstation/features/grid/grid_screen.dart';
import 'package:camstation/features/live_view/live_view_screen.dart';
import 'package:camstation/features/settings/settings_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

final _router = GoRouter(
  routes: [
    GoRoute(
      path: '/',
      builder: (_, _) => const CameraListScreen(),
      routes: [
        GoRoute(path: 'discover', builder: (_, _) => const DiscoverScreen()),
        GoRoute(
          path: 'camera/new',
          builder: (_, s) =>
              AddCameraScreen(discovered: s.extra as DiscoveredCamera?),
        ),
        GoRoute(
          path: 'camera/:id/edit',
          builder: (_, s) => AddCameraScreen(cameraId: s.pathParameters['id']),
        ),
        GoRoute(
          path: 'camera/:id/settings',
          builder: (_, s) =>
              CameraSettingsScreen(cameraId: s.pathParameters['id']!),
        ),
        GoRoute(
          path: 'live/:id',
          builder: (_, s) => LiveViewScreen(cameraId: s.pathParameters['id']!),
        ),
        GoRoute(path: 'grid', builder: (_, _) => const GridScreen()),
        GoRoute(
          path: 'settings',
          builder: (_, _) => const SettingsScreen(),
          routes: [
            GoRoute(path: 'log', builder: (_, _) => const EngineLogScreen()),
          ],
        ),
      ],
    ),
  ],
);

class CamStationApp extends ConsumerStatefulWidget {
  const CamStationApp({super.key});

  @override
  ConsumerState<CamStationApp> createState() => _CamStationAppState();
}

class _CamStationAppState extends ConsumerState<CamStationApp> {
  late final AppLifecycleListener _lifecycle;
  // Held in a field: `ref` is unusable in dispose().
  late final EngineManager _engine = ref.read(engineProvider);
  Timer? _stopTimer;

  @override
  void initState() {
    super.initState();
    unawaited(_startEngine());
    _lifecycle = AppLifecycleListener(
      // Android freezes/kills a backgrounded app's child processes anyway
      //: stop the engine after a short grace period and
      // restart it on resume. Players reconnect through their watchdog.
      onHide: () {
        if (!Platform.isAndroid) return;
        _stopTimer?.cancel();
        _stopTimer = Timer(const Duration(seconds: 20), () {
          unawaited(_engine.stop());
        });
      },
      onShow: () {
        _stopTimer?.cancel();
        unawaited(_startEngine());
      },
      onExitRequested: () async {
        await _engine.stop();
        return AppExitResponse.exit;
      },
    );
  }

  Future<void> _startEngine() async {
    try {
      await _engine.ensureStarted();
    } on Object {
      // State is surfaced by EngineBanner via the engine's ValueListenable.
    }
  }

  @override
  void dispose() {
    _stopTimer?.cancel();
    _lifecycle.dispose();
    unawaited(_engine.stop());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final settings = ref.watch(settingsProvider);
    ScreenAwake.apply(settings.keepScreenOn);
    final seed = Color(settings.seedColor);
    return MaterialApp.router(
      title: 'CamStation',
      debugShowCheckedModeBanner: false,
      themeMode: settings.themeMode,
      theme: ThemeData(colorSchemeSeed: seed),
      darkTheme: ThemeData(colorSchemeSeed: seed, brightness: Brightness.dark),
      routerConfig: _router,
    );
  }
}
