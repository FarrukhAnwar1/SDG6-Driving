// App Root
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'widgets/auth/auth_gate.dart';
import 'widgets/voice_feedback/voice_feedback_settings.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  try {
    await voiceFeedbackSettings.load();
  } catch (error) {
    debugPrint('Could not load voice feedback preference: $error');
  }
  SystemChrome.setPreferredOrientations([
    DeviceOrientation.portraitUp,
    DeviceOrientation.portraitDown,
  ]).then((_) {
    runApp(const MyApp());
  });
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Login',
      theme: ThemeData(colorSchemeSeed: Colors.indigo, useMaterial3: true),
      home: const AuthGate(),
      debugShowCheckedModeBanner: false,
    );
  }
}
