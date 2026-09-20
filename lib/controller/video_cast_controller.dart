import 'dart:convert';

import 'dart:io';

import 'package:ffmpeg_kit_flutter_new_https_gpl/ffmpeg_kit.dart';
import 'package:ffmpeg_kit_flutter_new_https_gpl/return_code.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:screen_share_project/model/video_cast_model.dart';
import 'package:shelf/shelf.dart' as shelf;
import 'package:shelf/shelf_io.dart' as io;
import 'package:shelf_web_socket/shelf_web_socket.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

final videoCastProvider = NotifierProvider<VideoCastNotifier, VideoCastState>(
  VideoCastNotifier.new,
);

class VideoCastNotifier extends Notifier<VideoCastState> {
  final List<WebSocketChannel> _sockets = [];

  HttpServer? _server;

  File? _streamFile;

  bool _isRemuxing = false;

  @override
  VideoCastState build() {
    ref.onDispose(() {
      _server?.close(force: true);

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
  // SERVER
  // ===========================================================================

  Future<void> _initServer() async {
    try {
      await _getIpAddress();
      await _startLocalServer();
    } catch (e, st) {
      debugPrint('Server başlatılamadı: $e');
      debugPrint('$st');

      state = state.copyWith(isServing: false);
    }
  }

  Future<void> _getIpAddress() async {
    final interfaces = await NetworkInterface.list(
      type: InternetAddressType.IPv4,
      includeLoopback: false,
    );

    // Wi-Fi öncelikli
    for (final interface in interfaces) {
      final name = interface.name.toLowerCase();

      if (name.contains('wlan') ||
          name.contains('wifi') ||
          name.contains('en0')) {
        for (final address in interface.addresses) {
          if (!address.isLoopback) {
            state = state.copyWith(localIp: address.address);

            return;
          }
        }
      }
    }

    // İlk uygun IPv4
    for (final interface in interfaces) {
      for (final address in interface.addresses) {
        if (!address.isLoopback) {
          state = state.copyWith(localIp: address.address);

          return;
        }
      }
    }
  }

  // ===========================================================================
  // VIDEO PICKER
  // ===========================================================================

  Future<void> pickVideo() async {
    final result = await FilePicker.platform.pickFiles(
      type: FileType.video,
      allowMultiple: false,
    );

    if (result == null) {
      return;
    }

    final path = result.files.single.path;

    if (path == null) {
      return;
    }

    final inputFile = File(path);

    if (!await inputFile.exists()) {
      debugPrint('Video bulunamadı: $path');
      return;
    }

    // Önceki stream'i temizle
    _streamFile = null;

    state = state.copyWith(
      selectedVideoFile: inputFile,
      currentSeconds: 0,
      totalSeconds: 0,
      isPlaying: false,
    );

    await _remuxVideo(inputFile);
  }

  // ===========================================================================
  // REMUX
  // ===========================================================================

  Future<void> _remuxVideo(File inputFile) async {
    if (_isRemuxing) {
      return;
    }

    _isRemuxing = true;

    try {
      final tempDirectory = await Directory.systemTemp.createTemp(
        'video_cast_',
      );

      final outputFile = File('${tempDirectory.path}/stream.mp4');

      if (await outputFile.exists()) {
        await outputFile.delete();
      }

      debugPrint(
        'Remux başladı:\n'
        'INPUT: ${inputFile.path}\n'
        'OUTPUT: ${outputFile.path}',
      );

      /*
       * -c copy: Re-encode olmadan doğrudan paketleme yapar.
       * -bsf:a aac_adtstoasc: TS'den MP4'e geçerken AAC başlıklarını düzeltir.
       * -movflags +faststart: MOOV atomunu başa taşır (HTML5 video uyumluluğu için şarttır).
       */
      final command = [
        '-y',
        '-i',
        inputFile.path,
        '-map',
        '0:v:0',
        '-map',
        '0:a:0?',
        '-c',
        'copy',
        '-bsf:a',
        'aac_adtstoasc',
        '-movflags',
        '+faststart',
        '-f',
        'mp4',
        outputFile.path,
      ].join(' ');

      debugPrint('FFmpeg command: $command');

      final session = await FFmpegKit.execute(command);
      final returnCode = await session.getReturnCode();

      if (ReturnCode.isSuccess(returnCode)) {
        debugPrint('Remux başarıyla tamamlandı.');

        if (!await outputFile.exists()) {
          throw Exception('FFmpeg başarılı döndü fakat çıktı dosyası yok.');
        }

        final length = await outputFile.length();

        if (length <= 0) {
          throw Exception('Remux edilen dosya boş.');
        }

        _streamFile = outputFile;

        state = state.copyWith(
          currentSeconds: 0,
          totalSeconds: 0,
          isPlaying: true,
        );

        _reloadTvPlayer();
      } else {
        final logs = await session.getAllLogsAsString();

        debugPrint(
          'FFmpeg remux başarısız.\n'
          'Return code: $returnCode\n'
          'Logs:\n$logs',
        );

        state = state.copyWith(isPlaying: false);
      }
    } catch (e, st) {
      debugPrint('Remux hatası: $e');
      debugPrint('$st');

      state = state.copyWith(isPlaying: false);
    } finally {
      _isRemuxing = false;
    }
  }

  // ===========================================================================
  // PLAY / PAUSE
  // ===========================================================================

  void togglePlay() {
    final newIsPlaying = !state.isPlaying;

    state = state.copyWith(isPlaying: newIsPlaying);

    _broadcastCommand(jsonEncode({'command': newIsPlaying ? 'play' : 'pause'}));
  }

  // ===========================================================================
  // SEEK
  // ===========================================================================

  void seekTo(double seconds) {
    if (seconds < 0) {
      seconds = 0;
    }

    if (state.totalSeconds > 0 && seconds > state.totalSeconds) {
      seconds = state.totalSeconds;
    }

    state = state.copyWith(currentSeconds: seconds);

    _broadcastCommand(jsonEncode({'command': 'seek', 'seconds': seconds}));
  }

  // ===========================================================================
  // PLAYER RELOAD
  // ===========================================================================

  void _reloadTvPlayer() {
    final timestamp = DateTime.now().millisecondsSinceEpoch;

    _broadcastCommand(
      jsonEncode({'command': 'reload', 'url': '/video?t=$timestamp'}),
    );
  }

  // ===========================================================================
  // WEBSOCKET
  // ===========================================================================

  void _broadcastCommand(String message) {
    final deadSockets = <WebSocketChannel>[];

    for (final socket in _sockets) {
      try {
        socket.sink.add(message);
      } catch (_) {
        deadSockets.add(socket);
      }
    }

    if (deadSockets.isNotEmpty) {
      _sockets.removeWhere(deadSockets.contains);
    }

    if (_sockets.isEmpty) {
      state = state.copyWith(isTvConnected: false);
    }
  }

  // ===========================================================================
  // HTTP SERVER
  // ===========================================================================

  Future<void> _startLocalServer() async {
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
            }

            if (data['event'] == 'seek') {
              final seconds = (data['seconds'] as num).toDouble();

              seekTo(seconds);
            }
          } catch (e) {
            debugPrint('WebSocket mesaj hatası: $e');
          }
        },
        onDone: () {
          _sockets.remove(webSocket);

          if (_sockets.isEmpty) {
            state = state.copyWith(isTvConnected: false);
          }
        },
        onError: (_) {
          _sockets.remove(webSocket);

          if (_sockets.isEmpty) {
            state = state.copyWith(isTvConnected: false);
          }
        },
        cancelOnError: true,
      );
    });

    Future<shelf.Response> handler(shelf.Request request) async {
      if (request.url.path == 'ws') {
        return wsHandler(request);
      }

      if (request.url.path.isEmpty || request.url.path == '/') {
        return shelf.Response.ok(
          _getTvPlayerHtml(),
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

    try {
      await _server?.close(force: true);
    } catch (_) {}

    final server = await io.serve(handler, InternetAddress.anyIPv4, 8080);

    server.autoCompress = false;

    _server = server;

    state = state.copyWith(server: server, isServing: true);

    debugPrint('Server: http://${state.localIp}:8080');
  }

  // ===========================================================================
  // VIDEO HTTP REQUEST
  // ===========================================================================

  Future<shelf.Response> _handleVideoRequest(shelf.Request request) async {
    final file = _streamFile;

    if (file == null || !await file.exists()) {
      return shelf.Response.notFound('Remux edilmiş video hazır değil.');
    }

    final fileLength = await file.length();
    final rangeHeader = request.headers['range'];

    if (rangeHeader == null) {
      return shelf.Response.ok(
        file.openRead(),
        headers: {
          'Content-Type': 'video/mp4',
          'Content-Length': fileLength.toString(),
          'Accept-Ranges': 'bytes',
          'Cache-Control': 'no-cache',
        },
      );
    }

    final match = RegExp(r'bytes=(\d*)-(\d*)').firstMatch(rangeHeader);

    if (match == null) {
      return shelf.Response(
        416,
        body: 'Invalid Range',
        headers: {'Content-Range': 'bytes */$fileLength'},
      );
    }

    final startString = match.group(1);
    final endString = match.group(2);

    int start;
    int end;

    if (startString == null || startString.isEmpty) {
      final suffixLength = int.tryParse(endString ?? '');

      if (suffixLength == null || suffixLength <= 0) {
        return shelf.Response(416, body: 'Invalid Range');
      }

      start = fileLength - suffixLength;

      if (start < 0) {
        start = 0;
      }

      end = fileLength - 1;
    } else {
      start = int.tryParse(startString) ?? 0;

      end = endString == null || endString.isEmpty
          ? fileLength - 1
          : int.tryParse(endString) ?? fileLength - 1;
    }

    if (start >= fileLength || start < 0) {
      return shelf.Response(
        416,
        body: 'Range Not Satisfiable',
        headers: {'Content-Range': 'bytes */$fileLength'},
      );
    }

    if (end >= fileLength) {
      end = fileLength - 1;
    }

    if (end < start) {
      return shelf.Response(
        416,
        body: 'Range Not Satisfiable',
        headers: {'Content-Range': 'bytes */$fileLength'},
      );
    }

    final contentLength = end - start + 1;
    final stream = file.openRead(start, end + 1);

    return shelf.Response(
      206,
      body: stream,
      headers: {
        'Content-Type': 'video/mp4',
        'Content-Length': contentLength.toString(),
        'Content-Range': 'bytes $start-$end/$fileLength',
        'Accept-Ranges': 'bytes',
        'Cache-Control': 'no-cache',
      },
    );
  }

  // ===========================================================================
  // HTML PLAYER
  // ===========================================================================

  String _getTvPlayerHtml() {
    return '''
<!DOCTYPE html>
<html lang="tr">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<title>Video Player</title>
<style>
html, body {
  margin: 0;
  padding: 0;
  width: 100%;
  height: 100%;
  background: #000;
  overflow: hidden;
}
body {
  display: flex;
  align-items: center;
  justify-content: center;
}
video {
  width: 100%;
  height: 100%;
  max-width: 100vw;
  max-height: 100vh;
  object-fit: contain;
  background: #000;
}
</style>
</head>
<body>

<video
  id="tvPlayer"
  src="/video"
  autoplay
  controls
  playsinline
  preload="auto">
  Tarayıcınız video oynatmayı desteklemiyor.
</video>

<script>
const video = document.getElementById('tvPlayer');
let ws = null;
let reconnectAttempt = 0;
let reconnectTimer = null;
let isSeekingFromCode = false;

function connect() {
  if (ws && (ws.readyState === WebSocket.OPEN || ws.readyState === WebSocket.CONNECTING)) {
    return;
  }

  const protocol = window.location.protocol === 'https:' ? 'wss://' : 'ws://';
  ws = new WebSocket(protocol + window.location.host + '/ws');

  ws.onopen = () => {
    console.log('WebSocket connected');
    reconnectAttempt = 0;
  };

  ws.onmessage = (event) => {
    try {
      const data = JSON.parse(event.data);

      if (data.command === 'play') {
        video.play().catch(console.error);
        return;
      }

      if (data.command === 'pause') {
        video.pause();
        return;
      }

      if (data.command === 'seek') {
        if (Number.isFinite(data.seconds)) {
          isSeekingFromCode = true;
          video.currentTime = data.seconds;
        }
        return;
      }

      if (data.command === 'reload') {
        video.src = data.url;
        video.load();
        video.play().catch(console.error);
        return;
      }

    } catch (error) {
      console.error('WS parse error:', error);
    }
  };

  ws.onclose = () => {
    reconnectAttempt++;
    const delay = Math.min(reconnectAttempt * 1000, 5000);
    clearTimeout(reconnectTimer);
    reconnectTimer = setTimeout(connect, delay);
  };

  ws.onerror = () => {
    try { ws.close(); } catch (_) {}
  };
}

video.addEventListener('timeupdate', () => {
  if (ws && ws.readyState === WebSocket.OPEN) {
    ws.send(JSON.stringify({
      event: 'timeupdate',
      currentTime: Number.isFinite(video.currentTime) ? video.currentTime : 0,
      duration: Number.isFinite(video.duration) ? video.duration : 0,
      paused: video.paused
    }));
  }
});

video.addEventListener('seeking', () => {
  if (isSeekingFromCode) {
    isSeekingFromCode = false;
    return;
  }

  if (ws && ws.readyState === WebSocket.OPEN && Number.isFinite(video.currentTime)) {
    ws.send(JSON.stringify({
      event: 'seek',
      seconds: video.currentTime
    }));
  }
});

video.addEventListener('error', () => {
  console.error('Video error:', video.error);
});

connect();
</script>
</body>
</html>
''';
  }
}
