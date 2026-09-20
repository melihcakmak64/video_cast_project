import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:screen_share_project/controller/video_cast_controller.dart';

class VideoCastView extends ConsumerWidget {
  const VideoCastView({Key? key}) : super(key: key);

  String _formatDuration(double seconds) {
    if (seconds.isNaN || seconds.isInfinite) return "00:00:00";
    Duration duration = Duration(seconds: seconds.toInt());
    String twoDigits(int n) => n.toString().padLeft(2, "0");
    String hours = twoDigits(duration.inHours);
    String minutes = twoDigits(duration.inMinutes.remainder(60));
    String secs = twoDigits(duration.inSeconds.remainder(60));
    return "$hours:$minutes:$secs";
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(videoCastProvider);
    final notifier = ref.read(videoCastProvider.notifier);

    return Scaffold(
      appBar: AppBar(
        title: const Text('TV Kumandası & Cast'),
        centerTitle: true,
      ),
      body: Padding(
        padding: const EdgeInsets.all(20.0),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            ElevatedButton.icon(
              onPressed: () async {
                await notifier.pickVideo();
              },
              icon: const Icon(Icons.video_library),
              label: const Text('Galeriden Video Seç'),
              style: ElevatedButton.styleFrom(
                padding: const EdgeInsets.all(15),
                textStyle: const TextStyle(fontSize: 16),
              ),
            ),
            const SizedBox(height: 20),

            // Sunucu ayakta değilse veya IP henüz bulunamadıysa kullanıcıyı
            // sessizce beklemek yerine bilgilendir.
            if (!state.isServing) ...[
              const Padding(
                padding: EdgeInsets.only(bottom: 12.0),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                    SizedBox(width: 10),
                    Text(
                      'Sunucu başlatılıyor / ağ adresi aranıyor...',
                      style: TextStyle(color: Colors.grey, fontSize: 13),
                    ),
                  ],
                ),
              ),
            ],

            if (state.selectedVideoFile != null) ...[
              Card(
                color: Colors.blue.shade50,
                child: Padding(
                  padding: const EdgeInsets.all(12.0),
                  child: Text(
                    'Seçilen Video: ${state.selectedVideoFile!.path.split('/').last}',
                    textAlign: TextAlign.center,
                    style: const TextStyle(fontWeight: FontWeight.bold),
                  ),
                ),
              ),
              const SizedBox(height: 30),

              // TV Bağlantı / Kontrol Paneli
              Card(
                elevation: 4,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Padding(
                  padding: const EdgeInsets.all(16.0),
                  child: Column(
                    children: [
                      Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Icon(
                            Icons.tv,
                            color: state.isTvConnected
                                ? Colors.green
                                : Colors.grey,
                          ),
                          const SizedBox(width: 8),
                          Text(
                            state.isTvConnected
                                ? 'TV Bağlandı (Oynatılıyor)'
                                : 'TV Bağlantısı Bekleniyor...',
                            style: TextStyle(
                              color: state.isTvConnected
                                  ? Colors.green
                                  : Colors.orange,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 20),

                      // Kaçıncı Dakikada Olduğu / Toplam Süre
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Text(
                            _formatDuration(state.currentSeconds),
                            style: const TextStyle(
                              fontSize: 16,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                          Text(
                            _formatDuration(state.totalSeconds),
                            style: const TextStyle(
                              fontSize: 16,
                              color: Colors.grey,
                            ),
                          ),
                        ],
                      ),

                      // Sardırma Çubuğu (Slider)
                      Slider(
                        value: state.currentSeconds.clamp(
                          0.0,
                          state.totalSeconds > 0 ? state.totalSeconds : 1.0,
                        ),
                        max: state.totalSeconds > 0 ? state.totalSeconds : 1.0,
                        onChanged: (value) {
                          notifier.seekTo(value);
                        },
                      ),

                      // Oynat / Duraklat Butonu
                      IconButton(
                        iconSize: 56,
                        icon: Icon(
                          state.isPlaying
                              ? Icons.pause_circle_filled
                              : Icons.play_circle_filled,
                          color: Colors.blue,
                        ),
                        onPressed: () {
                          notifier.togglePlay();
                        },
                      ),
                    ],
                  ),
                ),
              ),

              const SizedBox(height: 20),
              const Text(
                'TV Tarayıcısından Bu Adresi Açın:',
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 14),
              ),
              SelectableText(
                'http://${state.localIp}:8080',
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 22,
                  fontWeight: FontWeight.bold,
                  color: Colors.green,
                ),
              ),
            ] else
              const Text(
                'Lütfen TV\'ye aktarmak için bir video seçin.',
                textAlign: TextAlign.center,
                style: TextStyle(color: Colors.grey),
              ),
          ],
        ),
      ),
    );
  }
}
