import 'package:flutter/material.dart';

import '../auth_service.dart';

/// Sign in or create an account with the sample backend.
class SignInScreen extends StatefulWidget {
  const SignInScreen({super.key, required this.auth});

  final AuthService auth;

  @override
  State<SignInScreen> createState() => _SignInScreenState();
}

class _SignInScreenState extends State<SignInScreen> {
  final _email = TextEditingController();
  final _password = TextEditingController();
  String? _error;

  Future<void> _submit(Future<void> Function(String email, String password) action) async {
    setState(() => _error = null);
    try {
      await action(_email.text.trim(), _password.text);
    } catch (_) {
      setState(() => _error = 'That didn\'t work. Check your email and password.');
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: const Text('Welcome')),
        body: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            TextField(controller: _email, decoration: const InputDecoration(labelText: 'Email')),
            TextField(controller: _password, decoration: const InputDecoration(labelText: 'Password'), obscureText: true),
            const SizedBox(height: 16),
            FilledButton(onPressed: () => _submit(widget.auth.signIn), child: const Text('Sign in')),
            TextButton(onPressed: () => _submit(widget.auth.signUp), child: const Text('Create an account')),
            if (_error != null) Text(_error!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
          ],
        ),
      );

  @override
  void dispose() {
    _email.dispose();
    _password.dispose();
    super.dispose();
  }
}
