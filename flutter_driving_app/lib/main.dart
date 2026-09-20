// App Root
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'widgets/auth_gate.dart';
//import 'screens/driving_report_screen.dart';
//import 'widgets/trip_summary.dart';
void main() {
  WidgetsFlutterBinding.ensureInitialized();
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
