import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;

// Delete api logic

static const String baseUrl = 'http://10.0.2.2:8000';

bool _isDeleting = false;

Future<void> _deleteAccount(int userId) async {
  // Confirm before deleting
  final confirmed = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      title: const Text('Delete Account'),
      content: const Text(
        'Are you sure you want to delete your account? This cannot be undone.',
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context, false),
          child: const Text('Cancel'),
        ),
        TextButton(
          onPressed: () => Navigator.pop(context, true),
          child: const Text('Delete', style: TextStyle(color: Colors.red)),
        ),
      ],
    ),
  );

  if (confirmed != true) {
    return;
  }

  setState(() => _isDeleting = true);

  try {
    final response = await http.delete(
      Uri.parse('$baseUrl/users/$userId'),
      headers: {'Content-Type': 'application/json'},
    );

    print('Status: ${response.statusCode}, Body: ${response.body}');

    if (response.statusCode == 200 || response.statusCode == 204) {
      if (!mounted) {
        return;
      }
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Account deleted successfully')),
      );
      // Navigate back to signup/login and clear navigation stack
      Navigator.pushAndRemoveUntil(
        context,
        MaterialPageRoute(builder: (context) => const SignupPage()),
        (route) => false,
      );
    } else if (response.statusCode == 404) {
      _showError('Account not found.');
    } else {
      _showError('Failed to delete account. Please try again.');
    }
  } catch (_) {
    _showError('Could not connect to backend.');
  } finally {
    if (mounted) {
      setState(() => _isDeleting = false);
    }
  }
}

void _showError(String message) {
  if (!mounted) {
    return;
  }
  ScaffoldMessenger.of(context).showSnackBar(
    SnackBar(content: Text(message)),
  );
}