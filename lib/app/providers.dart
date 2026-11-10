import 'dart:convert';
import 'dart:io';

import 'package:camstation/core/cameras/camera.dart';
import 'package:camstation/core/cameras/camera_repository.dart';
import 'package:camstation/core/cameras/stream_sources.dart';
import 'package:camstation/core/engine/engine_config.dart';
import 'package:camstation/core/engine/engine_manager.dart';
import 'package:camstation/media/camera_player.dart';
import 'package:camstation/media/playback_plan.dart';
import 'package:flutter/material.dart' show ThemeMode;
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// App-private support directory; overridden in main() once resolved.
final supportDirProvider = Provider<Directory>(
  (ref) => throw UnimplementedError('override in main()'),
);

final engineProvider = Provider<EngineManager>((ref) {
  final dir = ref.watch(supportDirProvider);
  final e = EngineManager(runtimeDir: Directory('${dir.path}/engine'));
  ref.onDispose(e.dispose);
  return e;
});

final secretStoreProvider = Provider<SecretStore>((ref) => SecureSecretStore());

final cameraStoreProvider = Provider<CameraStore>(
  (ref) =>
      CameraStore(File('${ref.watch(supportDirProvider).path}/cameras.json')),
);

final camerasProvider = AsyncNotifierProvider<CamerasNotifier, List<Camera>>(
  CamerasNotifier.new,
);

class CamerasNotifier extends AsyncNotifier<List<Camera>> {
  CameraStore get _store => ref.read(cameraStoreProvider);
  SecretStore get _secrets => ref.read(secretStoreProvider);

  @override
  Future<List<Camera>> build() => _store.load();

  Camera? byId(String id) {
    for (final c in state.value ?? const <Camera>[]) {
      if (c.id == id) return c;
    }
    return null;
  }

  /// Adds or replaces a camera. [password] null = keep the stored one.
  Future<void> save(Camera cam, {String? password}) async {
    if (password != null) await _secrets.write(cam.id, password);
    final list = [...?state.value];
    final i = list.indexWhere((c) => c.id == cam.id);
    if (i >= 0) {
      list[i] = cam;
    } else {
      list.add(cam);
    }
    await _store.save(list);
    state = AsyncData(list);
    // Open views keep working, now with the new settings.
    await ref.read(streamRegistryProvider).refresh(cam);
  }

  /// Moves a camera in the list (also the grid order). No stream changes.
  Future<void> reorder(int from, int to) async {
    final list = [...?state.value];
    if (from < 0 || from >= list.length) return;
    final cam = list.removeAt(from);
    list.insert(to.clamp(0, list.length), cam);
    await _store.save(list);
    state = AsyncData(list);
  }

  Future<void> remove(String id) async {
    final list = [...?state.value]..removeWhere((c) => c.id == id);
    await _store.save(list);
    await _secrets.delete(id);
    await ref.read(streamRegistryProvider).forget(id);
    state = AsyncData(list);
  }

  Future<String> password(String id) async => (await _secrets.read(id)) ?? '';
}

/// Registers camera streams with the engine on demand.
final streamRegistryProvider = Provider<StreamRegistry>(StreamRegistry.new);

class StreamRegistry {
  StreamRegistry(this.ref);
  final Ref ref;

  EngineManager get _engine => ref.read(engineProvider);

  static String mediaName(Camera c, StreamQuality q) => '${c.id}_${q.name}';
  static String talkName(Camera c) => '${c.id}_talk';

  /// Ensures the viewing stream exists; returns its engine name.
  Future<String> media(Camera cam, StreamQuality q) async {
    final pw = await ref.read(camerasProvider.notifier).password(cam.id);
    final name = mediaName(cam, q);
    await _engine.setStream(name, StreamSources.media(cam, pw, q));
    return name;
  }

  /// Ensures the talk stream exists; null if the camera has no backchannel.
  Future<String?> talk(Camera cam) async {
    final pw = await ref.read(camerasProvider.notifier).password(cam.id);
    final sources = StreamSources.talk(cam, pw);
    if (sources == null) return null;
    final name = talkName(cam);
    await _engine.setStream(name, sources);
    return name;
  }

  /// The camera's settings changed: re-register any of its streams that
  /// are in use with fresh sources (open players reconnect to the same
  /// name), drop the talk stream and cached codecs.
  Future<void> refresh(Camera cam) async {
    final pw = await ref.read(camerasProvider.notifier).password(cam.id);
    for (final q in StreamQuality.values) {
      final name = mediaName(cam, q);
      CameraPlayer.forgetCodecs(name);
      if (_engine.hasStream(name)) {
        try {
          await _engine.setStream(name, StreamSources.media(cam, pw, q));
        } on Object {
          // engine down: re-applied with the new sources on restart anyway
        }
      }
    }
    try {
      await _engine.removeStream(talkName(cam));
    } on Object {
      // not registered
    }
  }

  Future<void> forget(String cameraId) async {
    for (final suffix in ['main', 'sub', 'talk']) {
      CameraPlayer.forgetCodecs('${cameraId}_$suffix');
      try {
        await _engine.removeStream('${cameraId}_$suffix');
      } on Object {
        // engine not running: nothing to remove
      }
    }
  }
}

/// New camera ids double as unguessable stream-name prefixes.
String newCameraId() => randomToken();

// --- Settings ------------------------------------------------------------

/// When the screen must not dim or lock.
enum KeepScreenOn {
  watching('While watching'),
  always('Always'),
  off('Off');

  const KeepScreenOn(this.label);
  final String label;
}

class AppSettings {
  const AppSettings({
    this.defaultQuality = StreamQuality.main,
    this.preference = PlayerPreference.auto,
    this.lastScanTargets = '',
    this.themeMode = ThemeMode.system,
    this.seedColor = 0xFF2E7D6B,
    this.gridColumns = 2,
    this.gridHidden = const {},
    this.gridPaused = const {},
    this.showStreamInfo = false,
    this.keepScreenOn = KeepScreenOn.watching,
  });

  factory AppSettings.fromJson(Map<String, Object?> j) => AppSettings(
    defaultQuality: StreamQuality.values.firstWhere(
      (q) => q.name == j['defaultQuality'],
      orElse: () => StreamQuality.main,
    ),
    preference: PlayerPreference.values.firstWhere(
      (p) => p.name == j['preference'],
      orElse: () => PlayerPreference.auto,
    ),
    lastScanTargets: (j['lastScanTargets'] as String?) ?? '',
    themeMode: ThemeMode.values.firstWhere(
      (m) => m.name == j['themeMode'],
      orElse: () => ThemeMode.system,
    ),
    seedColor: (j['seedColor'] as int?) ?? 0xFF2E7D6B,
    gridColumns: ((j['gridColumns'] as int?) ?? 2).clamp(1, 4),
    gridHidden: {...?(j['gridHidden'] as List?)?.cast<String>()},
    gridPaused: {...?(j['gridPaused'] as List?)?.cast<String>()},
    showStreamInfo: (j['showStreamInfo'] as bool?) ?? false,
    keepScreenOn: KeepScreenOn.values.firstWhere(
      (k) => k.name == j['keepScreenOn'],
      orElse: () => KeepScreenOn.watching,
    ),
  );

  /// Fallback stream for cameras that have never been viewed.
  final StreamQuality defaultQuality;
  final PlayerPreference preference;

  /// Extra subnets/IPs to probe (cameras on other subnets).
  final String lastScanTargets;
  final ThemeMode themeMode;
  final int seedColor;
  final int gridColumns;
  final Set<String> gridHidden;
  final Set<String> gridPaused;

  /// Show the player/codec badge on live video (troubleshooting).
  final bool showStreamInfo;
  final KeepScreenOn keepScreenOn;

  AppSettings copyWith({
    StreamQuality? defaultQuality,
    PlayerPreference? preference,
    String? lastScanTargets,
    ThemeMode? themeMode,
    int? seedColor,
    int? gridColumns,
    Set<String>? gridHidden,
    Set<String>? gridPaused,
    bool? showStreamInfo,
    KeepScreenOn? keepScreenOn,
  }) => AppSettings(
    defaultQuality: defaultQuality ?? this.defaultQuality,
    preference: preference ?? this.preference,
    lastScanTargets: lastScanTargets ?? this.lastScanTargets,
    themeMode: themeMode ?? this.themeMode,
    seedColor: seedColor ?? this.seedColor,
    gridColumns: gridColumns ?? this.gridColumns,
    gridHidden: gridHidden ?? this.gridHidden,
    gridPaused: gridPaused ?? this.gridPaused,
    showStreamInfo: showStreamInfo ?? this.showStreamInfo,
    keepScreenOn: keepScreenOn ?? this.keepScreenOn,
  );

  Map<String, Object?> toJson() => {
    'defaultQuality': defaultQuality.name,
    'preference': preference.name,
    'lastScanTargets': lastScanTargets,
    'themeMode': themeMode.name,
    'seedColor': seedColor,
    'gridColumns': gridColumns,
    'gridHidden': gridHidden.toList(),
    'gridPaused': gridPaused.toList(),
    'showStreamInfo': showStreamInfo,
    'keepScreenOn': keepScreenOn.name,
  };
}

final settingsProvider = NotifierProvider<SettingsNotifier, AppSettings>(
  SettingsNotifier.new,
);

class SettingsNotifier extends Notifier<AppSettings> {
  File get _file => File('${ref.read(supportDirProvider).path}/settings.json');

  @override
  AppSettings build() {
    try {
      if (_file.existsSync()) {
        return AppSettings.fromJson(
          jsonDecode(_file.readAsStringSync()) as Map<String, Object?>,
        );
      }
    } on Object {
      // corrupt settings: fall back to defaults
    }
    // Phones start on SD: the main stream can be 4K.
    return AppSettings(
      defaultQuality: Platform.isAndroid || Platform.isIOS
          ? StreamQuality.sub
          : StreamQuality.main,
    );
  }

  Future<void> update(AppSettings s) async {
    state = s;
    await _file.writeAsString(jsonEncode(s.toJson()));
  }
}

// --- Per-camera "last used" view state -----------------------------------

class ViewState {
  const ViewState({
    this.quality,
    this.muted,
    this.volume,
    this.orientation,
    this.fullscreen,
  });

  factory ViewState.fromJson(Map<String, Object?> j) => ViewState(
    quality: StreamQuality.values
        .where((q) => q.name == j['quality'])
        .firstOrNull,
    muted: j['muted'] as bool?,
    volume: (j['volume'] as num?)?.toDouble(),
    orientation: ViewOrientation.values
        .where((o) => o.name == j['orientation'])
        .firstOrNull,
    fullscreen: j['fullscreen'] as bool?,
  );

  final StreamQuality? quality;
  final bool? muted;
  final double? volume;
  final ViewOrientation? orientation;
  final bool? fullscreen;

  ViewState copyWith({
    StreamQuality? quality,
    bool? muted,
    double? volume,
    ViewOrientation? orientation,
    bool? fullscreen,
  }) => ViewState(
    quality: quality ?? this.quality,
    muted: muted ?? this.muted,
    volume: volume ?? this.volume,
    orientation: orientation ?? this.orientation,
    fullscreen: fullscreen ?? this.fullscreen,
  );

  Map<String, Object?> toJson() => {
    if (quality != null) 'quality': quality!.name,
    if (muted != null) 'muted': muted,
    if (volume != null) 'volume': volume,
    if (orientation != null) 'orientation': orientation!.name,
    if (fullscreen != null) 'fullscreen': fullscreen,
  };
}

/// What each camera was last viewed with, so it reopens the same way.
final viewStateProvider =
    NotifierProvider<ViewStateNotifier, Map<String, ViewState>>(
      ViewStateNotifier.new,
    );

class ViewStateNotifier extends Notifier<Map<String, ViewState>> {
  File get _file =>
      File('${ref.read(supportDirProvider).path}/view_state.json');

  @override
  Map<String, ViewState> build() {
    try {
      if (_file.existsSync()) {
        final j = jsonDecode(_file.readAsStringSync()) as Map<String, Object?>;
        return {
          for (final e in j.entries)
            e.key: ViewState.fromJson(e.value! as Map<String, Object?>),
        };
      }
    } on Object {
      // ignore corrupt state
    }
    return {};
  }

  Future<void> remember(
    String cameraId,
    ViewState Function(ViewState) f,
  ) async {
    final next = {...state, cameraId: f(state[cameraId] ?? const ViewState())};
    state = next;
    await _file.writeAsString(
      jsonEncode({for (final e in next.entries) e.key: e.value.toJson()}),
    );
  }

  /// Quality/sound a camera should open with: its own setting, else what
  /// was used last, else the app default.
  ({
    StreamQuality quality,
    bool muted,
    double volume,
    ViewOrientation orientation,
    bool fullscreen,
  })
  resolve(Camera cam) {
    final last = state[cam.id];
    final fallback = ref.read(settingsProvider).defaultQuality;
    final quality = switch (cam.startQuality) {
      StartQuality.main => StreamQuality.main,
      StartQuality.sub => StreamQuality.sub,
      StartQuality.last => last?.quality ?? fallback,
    };
    final muted = switch (cam.startAudio) {
      StartAudio.on => false,
      StartAudio.muted => true,
      StartAudio.last => last?.muted ?? false,
    };
    final orientation = switch (cam.startOrientation) {
      StartOrientation.auto => ViewOrientation.auto,
      StartOrientation.landscape => ViewOrientation.landscape,
      StartOrientation.portrait => ViewOrientation.portrait,
      StartOrientation.last => last?.orientation ?? ViewOrientation.auto,
    };
    final fullscreen = switch (cam.startFullscreen) {
      StartFullscreen.on => true,
      StartFullscreen.off => false,
      StartFullscreen.last => last?.fullscreen ?? false,
    };
    return (
      quality: quality,
      muted: muted,
      volume: last?.volume ?? 1,
      orientation: orientation,
      fullscreen: fullscreen,
    );
  }
}
