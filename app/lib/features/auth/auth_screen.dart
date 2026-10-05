import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/api_client.dart';
import '../../core/server_config.dart';
import '../../core/session.dart';

/// Shows a registration form while the server has no account, and a login form
/// afterwards. The mode is decided by `GET /api/status`.
class AuthScreen extends ConsumerWidget {
  const AuthScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final status = ref.watch(serverStatusProvider);
    final serverUrl = ref.watch(serverUrlProvider);
    final theme = Theme.of(context);

    return Scaffold(
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 420),
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: switch (status) {
              AsyncData(:final value) => _AuthForm(register: !value.registered),
              AsyncError(:final error) => Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.cloud_off, size: 56, color: theme.colorScheme.error),
                  const SizedBox(height: 12),
                  Text('Cannot reach $serverUrl', style: theme.textTheme.titleMedium, textAlign: TextAlign.center),
                  const SizedBox(height: 4),
                  Text(_describe(error), style: theme.textTheme.bodySmall, textAlign: TextAlign.center),
                  const SizedBox(height: 16),
                  Wrap(
                    spacing: 8,
                    children: [
                      FilledButton.icon(
                        onPressed: () => ref.invalidate(serverStatusProvider),
                        icon: const Icon(Icons.refresh),
                        label: const Text('Retry'),
                      ),
                      if (!kIsWeb)
                        OutlinedButton.icon(
                          onPressed: () => ref.read(serverUrlProvider.notifier).clear(),
                          icon: const Icon(Icons.dns_outlined),
                          label: const Text('Change server'),
                        ),
                    ],
                  ),
                ],
              ),
              _ => const Center(child: CircularProgressIndicator()),
            },
          ),
        ),
      ),
    );
  }

  static String _describe(Object e) => switch (e) {
    NetworkException(:final message) => message,
    ApiException(:final message) => message,
    _ => e.toString(),
  };
}

class _AuthForm extends ConsumerStatefulWidget {
  const _AuthForm({required this.register});
  final bool register;

  @override
  ConsumerState<_AuthForm> createState() => _AuthFormState();
}

class _AuthFormState extends ConsumerState<_AuthForm> {
  final _formKey = GlobalKey<FormState>();
  final _user = TextEditingController();
  final _pass = TextEditingController();
  final _confirm = TextEditingController();
  bool _busy = false;
  bool _obscure = true;
  String? _error;

  @override
  void dispose() {
    _user.dispose();
    _pass.dispose();
    _confirm.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    final api = ref.read(apiClientProvider);
    try {
      final result = widget.register
          ? await api.register(_user.text.trim(), _pass.text)
          : await api.login(_user.text.trim(), _pass.text);
      await ref.read(sessionProvider.notifier).signIn(result);
    } on ApiException catch (e) {
      setState(() => _error = e.message);
      if (e.status == 409) ref.invalidate(serverStatusProvider);
    } on NetworkException catch (e) {
      setState(() => _error = 'Network error: ${e.message}');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final serverUrl = ref.watch(serverUrlProvider);
    final register = widget.register;

    return Form(
      key: _formKey,
      child: AutofillGroup(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Icon(Icons.local_library_outlined, size: 72, color: theme.colorScheme.primary),
            const SizedBox(height: 16),
            Text(
              register ? 'Create your account' : 'Welcome back',
              textAlign: TextAlign.center,
              style: theme.textTheme.headlineMedium,
            ),
            const SizedBox(height: 8),
            Text(
              register
                  ? 'This server has no account yet. The account you create here will be the only one.'
                  : 'Sign in to your library.',
              textAlign: TextAlign.center,
              style: theme.textTheme.bodyMedium,
            ),
            const SizedBox(height: 24),
            TextFormField(
              controller: _user,
              enabled: !_busy,
              autofocus: true,
              autofillHints: const [AutofillHints.username],
              textInputAction: TextInputAction.next,
              decoration: const InputDecoration(labelText: 'Username', prefixIcon: Icon(Icons.person_outline)),
              validator: (v) => (v == null || v.trim().length < 2) ? 'At least 2 characters' : null,
            ),
            const SizedBox(height: 12),
            TextFormField(
              controller: _pass,
              enabled: !_busy,
              obscureText: _obscure,
              autofillHints: [register ? AutofillHints.newPassword : AutofillHints.password],
              textInputAction: register ? TextInputAction.next : TextInputAction.done,
              onFieldSubmitted: register ? null : (_) => _submit(),
              decoration: InputDecoration(
                labelText: 'Password',
                prefixIcon: const Icon(Icons.lock_outline),
                suffixIcon: IconButton(
                  icon: Icon(_obscure ? Icons.visibility_off : Icons.visibility),
                  onPressed: () => setState(() => _obscure = !_obscure),
                ),
              ),
              validator: (v) => (v == null || v.length < 6) ? 'At least 6 characters' : null,
            ),
            if (register) ...[
              const SizedBox(height: 12),
              TextFormField(
                controller: _confirm,
                enabled: !_busy,
                obscureText: _obscure,
                textInputAction: TextInputAction.done,
                onFieldSubmitted: (_) => _submit(),
                decoration: const InputDecoration(labelText: 'Confirm password', prefixIcon: Icon(Icons.lock_outline)),
                validator: (v) => v != _pass.text ? 'Passwords do not match' : null,
              ),
            ],
            if (_error != null) ...[
              const SizedBox(height: 12),
              Text(_error!, style: TextStyle(color: theme.colorScheme.error), textAlign: TextAlign.center),
            ],
            const SizedBox(height: 20),
            FilledButton(
              onPressed: _busy ? null : _submit,
              child: _busy
                  ? const SizedBox.square(dimension: 18, child: CircularProgressIndicator(strokeWidth: 2))
                  : Text(register ? 'Register' : 'Sign in'),
            ),
            const SizedBox(height: 16),
            Text(
              serverUrl ?? '',
              textAlign: TextAlign.center,
              style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.outline),
            ),
            if (!kIsWeb)
              TextButton(
                onPressed: _busy ? null : () => ref.read(serverUrlProvider.notifier).clear(),
                child: const Text('Change server'),
              ),
          ],
        ),
      ),
    );
  }
}
