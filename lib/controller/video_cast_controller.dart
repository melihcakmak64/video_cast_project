import 'dart:convert';
import 'dart:io';

import 'package:ffmpeg_kit_flutter_new_https_gpl/ffmpeg_kit.dart';
import 'package:ffmpeg_kit_flutter_new_https_gpl/ffmpeg_kit_config.dart';
import 'package:ffmpeg_kit_flutter_new_https_gpl/ffprobe_kit.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:screen_share_project/model/video_cast_model.dart';
import 'package:screen_share_project/view/web_page.dart';
import 'package:shelf/shelf.dart' as shelf;
import 'package:shelf/shelf_io.dart' as io;
import 'package:shelf_web_socket/shelf_web_socket.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

final videoCastProvider = NotifierProvider(VideoCastNotifier.new);

class VideoCastNotifier extends Notifier {
  final List _sockets = [];
  HttpServer? _server;

  @override
  VideoCastState build() {
    ref.onDispose(() {
      _server?.close(force: true);
      FFmpegKit.cancel();

      for (final socket in _sockets) {
        try {
          socket.sink.close();
        } catch (_) {}
      }
      _sockets.clear();
    });

    _initServer();

    return VideoCastState();
  }

  // ===========================================================================
  // SERVER INITIALIZATION
  // ===========================================================================

  Future _initServer() async {
    try {
      await _getIpAddress();
      await _startLocalServer();
    } catch (e, st) {
      debugPrint('Server başlatılamadı: $e');
      debugPrint('$st');
      state = state.copyWith(isServing: false);
    }
  }

  Future _getIpAddress() async {
    final interfaces = await NetworkInterface.list(
      type: InternetAddressType.IPv4,
      includeLoopback: false,
    );

    String? fallbackIp;

    for (final interface in interfaces) {
      final name = interface.name.toLowerCase();
      final isWifi =
          name.contains('wlan') ||
          name.contains('wifi') ||
          name.contains('en0');

      for (final address in interface.addresses) {
        if (!address.isLoopback) {
          if (isWifi) {
            state = state.copyWith(localIp: address.address);
            return;
          }
          fallbackIp ??= address.address;
        }
      }
    }

    if (fallbackIp != null) {
      state = state.copyWith(localIp: fallbackIp);
    }
  }

  // ===========================================================================
  // VIDEO PICKER
  // ===========================================================================

  Future pickVideo() async {
    final result = await FilePicker.platform.pickFiles(
      type: FileType.video,
      allowMultiple: false,
      withReadStream: false,
      withData: false,
    );

    if (result == null || result.files.single.path == null) return;

    final path = result.files.single.path!;
    final inputFile = File(path);

    if (!await inputFile.exists()) {
      debugPrint('Video bulunamadı: $path');
      return;
    }

    state = state.copyWith(
      selectedVideoFile: inputFile,
      currentSeconds: 0.0,
      totalSeconds: 0.0,
      isPlaying: true,
    );

    _reloadTvPlayer();

    FFprobeKit.getMediaInformation(inputFile.path)
        .then((session) {
          final info = session.getMediaInformation();
          final totalDuration =
              double.tryParse(info?.getDuration() ?? '') ?? 0.0;

          if (totalDuration > 0) {
            state = state.copyWith(totalSeconds: totalDuration);
            _broadcastCommand(
              jsonEncode({
                'command': 'updateDuration',
                'duration': totalDuration,
              }),
            );
          }
        })
        .catchError((e) {
          debugPrint('FFprobe süre alma hatası: $e');
        });
  }

  // ===========================================================================
  // PLAY / PAUSE / SEEK
  // ===========================================================================

  void togglePlay() {
    final newIsPlaying = !state.isPlaying;
    state = state.copyWith(isPlaying: newIsPlaying);
    _broadcastCommand(jsonEncode({'command': newIsPlaying ? 'play' : 'pause'}));
  }

  void seekTo(double seconds) {
    if (seconds < 0) seconds = 0;
    if (state.totalSeconds > 0 && seconds > state.totalSeconds) {
      seconds = state.totalSeconds;
    }

    state = state.copyWith(currentSeconds: seconds);
    _broadcastCommand(jsonEncode({'command': 'seek', 'seconds': seconds}));
  }

  void _reloadTvPlayer() {
    final timestamp = DateTime.now().millisecondsSinceEpoch;
    _broadcastCommand(
      jsonEncode({
        'command': 'reload',
        'url': '/video?t=$timestamp',
        'duration': state.totalSeconds,
      }),
    );
  }

  // ===========================================================================
  // WEBSOCKET
  // ===========================================================================

  void _broadcastCommand(String message) {
    _sockets.removeWhere((socket) {
      try {
        socket.sink.add(message);
        return false;
      } catch (_) {
        return true;
      }
    });

    if (_sockets.isEmpty) {
      state = state.copyWith(isTvConnected: false);
    }
  }

  // ===========================================================================
  // HTTP SERVER
  // ===========================================================================

  Future _startLocalServer() async {
    final wsHandler = webSocketHandler((
      WebSocketChannel webSocket,
      String? protocol,
    ) {
      _sockets.add(webSocket);
      state = state.copyWith(isTvConnected: true);

      webSocket.stream.listen(
        (message) {
          try {
            final data = jsonDecode(message);

            if (data['event'] == 'timeupdate') {
              state = state.copyWith(
                currentSeconds: (data['currentTime'] as num).toDouble(),
                totalSeconds: (data['duration'] as num).toDouble(),
                isPlaying: !(data['paused'] as bool),
              );
            } else if (data['event'] == 'seek') {
              seekTo((data['seconds'] as num).toDouble());
            }
          } catch (e) {
            debugPrint('WebSocket mesaj hatası: $e');
          }
        },
        onDone: () => _removeSocket(webSocket),
        onError: (_) => _removeSocket(webSocket),
        cancelOnError: true,
      );
    });

    Future<shelf.Response> handler(shelf.Request request) async {
      if (request.url.path == 'ws') return wsHandler(request);

      if (request.url.path.isEmpty || request.url.path == '/') {
        return shelf.Response.ok(
          watch_page,
          headers: {
            'Content-Type': 'text/html; charset=utf-8',
            'Cache-Control': 'no-cache, no-store, must-revalidate',
          },
        );
      }

      if (request.url.path == 'video') {
        return _handleVideoRequest(request);
      }

      return shelf.Response.notFound('İçerik bulunamadı');
    }

    final server = await io.serve(handler, InternetAddress.anyIPv4, 8080);
    server.autoCompress = false;
    _server = server;

    state = state.copyWith(server: server, isServing: true);
    debugPrint('Server: http://${state.localIp}:8080');
  }

  void _removeSocket(WebSocketChannel socket) {
    _sockets.remove(socket);
    if (_sockets.isEmpty) {
      state = state.copyWith(isTvConnected: false);
    }
  }

  // ===========================================================================
  // ON-THE-FLY HTTP STREAMING
  // ===========================================================================

  Future<shelf.Response> _handleVideoRequest(shelf.Request request) async {
    final inputFile = state.selectedVideoFile;

    if (inputFile == null || !await inputFile.exists()) {
      return shelf.Response.notFound('Video bulunamadı.');
    }

    final startSeconds =
        double.tryParse(request.url.queryParameters['start'] ?? '0') ?? 0.0;

    try {
      final pipePath = await FFmpegKitConfig.registerNewFFmpegPipe();
      if (pipePath == null) {
        return shelf.Response.internalServerError(body: 'Pipe oluşturulamadı.');
      }

      final command = [
        if (startSeconds > 0) ...[
          '-ss',
          startSeconds.toString(),
          '-noaccurate_seek',
        ],
        '-i',
        inputFile.path,
        '-map',
        '0:v:0',
        '-map',
        '0:a:0?',
        '-c:v',
        'copy',
        '-c:a',
        'aac',
        '-ac',
        '2',
        '-copyts',
        '-start_at_zero',
        '-avoid_negative_ts',
        'make_zero',
        '-max_muxing_queue_size',
        '2048',
        '-movflags',
        'frag_keyframe+empty_moov+default_base_moof',
        '-f',
        'mp4',
        '-y',
        pipePath,
      ].join(' ');

      FFmpegKit.executeAsync(command);

      final stream = File(pipePath).openRead();

      return shelf.Response.ok(
        stream,
        headers: {
          'Content-Type': 'video/mp4',
          'Cache-Control': 'no-cache, no-store',
          'Connection': 'keep-alive',
        },
      );
    } catch (e) {
      debugPrint('On-The-Fly Stream Hatası: $e');
      return shelf.Response.internalServerError(body: 'Akış hatası oluştu.');
    }
  }
}
