import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:screen_share_project/view/video_cast_view.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(ProviderScope(
    child: const MaterialApp(
      debugShowCheckedModeBanner: false,
      home: VideoCastView(),
    ),
  ));
}