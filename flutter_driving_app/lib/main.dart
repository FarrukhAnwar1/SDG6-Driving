// App Root
import 'package:flutter/material.dart';
import 'package:flutter_driving_app/login.dart';

void main() {
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Login',
      theme: ThemeData(colorSchemeSeed: Colors.indigo, useMaterial3: true),
      home: const LoginPage(),
      debugShowCheckedModeBanner: false,
    );
  }
}
