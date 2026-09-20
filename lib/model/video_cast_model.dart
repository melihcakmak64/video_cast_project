import 'dart:io';

class VideoCastState {
  final String localIp;
  final File? selectedVideoFile;
  final HttpServer? server;
  final bool isServing;
  final double currentSeconds;
  final double totalSeconds;
  final bool isPlaying;
  final bool isTvConnected;

  VideoCastState({
    this.localIp = 'Yükleniyor...',
    this.selectedVideoFile,
    this.server,
    this.isServing = false,
    this.currentSeconds = 0.0,
    this.totalSeconds = 0.0,
    this.isPlaying = false,
    this.isTvConnected = false,
  });

  VideoCastState copyWith({
    String? localIp,
    File? selectedVideoFile,
    HttpServer? server,
    bool? isServing,
    double? currentSeconds,
    double? totalSeconds,
    bool? isPlaying,
    bool? isTvConnected,
  }) {
    return VideoCastState(
      localIp: localIp ?? this.localIp,
      selectedVideoFile: selectedVideoFile ?? this.selectedVideoFile,
      server: server ?? this.server,
      isServing: isServing ?? this.isServing,
      currentSeconds: currentSeconds ?? this.currentSeconds,
      totalSeconds: totalSeconds ?? this.totalSeconds,
      isPlaying: isPlaying ?? this.isPlaying,
      isTvConnected: isTvConnected ?? this.isTvConnected,
    );
  }
}