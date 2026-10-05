import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/api_client.dart';
import '../../core/server_config.dart';

/// First-run screen on mobile: asks for the server address and verifies it
/// answers on `/api/status` before saving it.
class ServerSetupScreen extends ConsumerStatefulWidget {
  const ServerSetupScreen({super.key});

  @override
  ConsumerState<ServerSetupScreen> createState() => _ServerSetupScreenState();
}

class _ServerSetupScreenState extends ConsumerState<ServerSetupScreen> {
  final _controller = TextEditingController();
  String? _error;
  bool _busy = false;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _connect() async {
    final origin = normalizeServerUrl(_controller.text);
    if (origin == null) {
      setState(() => _error = 'Enter a host like 192.168.1.10:8080 or https://books.example.com');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    final client = ApiClient(baseUrl: origin, token: () => null);
    try {
      final status = await client.status();
      if (status.name != 'dusty-library') {
        setState(() => _error = 'That address does not look like a Dusty Library server.');
        return;
      }
      await ref.read(serverUrlProvider.notifier).set(origin);
    } on NetworkException catch (e) {
      setState(() => _error = 'Could not reach $origin (${e.message}).');
    } on ApiException catch (e) {
      setState(() => _error = 'Server answered ${e.status}: ${e.message}');
    } finally {
      client.close();
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 420),
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Icon(Icons.local_library_outlined, size: 72, color: theme.colorScheme.primary),
                const SizedBox(height: 16),
                Text('Dusty Library', textAlign: TextAlign.center, style: theme.textTheme.headlineMedium),
                const SizedBox(height: 8),
                Text(
                  'Enter the address of your Dusty Library server.',
                  textAlign: TextAlign.center,
                  style: theme.textTheme.bodyMedium,
                ),
                const SizedBox(height: 24),
                TextField(
                  controller: _controller,
                  enabled: !_busy,
                  autofocus: true,
                  keyboardType: TextInputType.url,
                  autocorrect: false,
                  textInputAction: TextInputAction.go,
                  onSubmitted: (_) => _connect(),
                  decoration: InputDecoration(
                    labelText: 'Server IP or domain',
                    hintText: '192.168.1.10:8080',
                    prefixIcon: const Icon(Icons.dns_outlined),
                    errorText: _error,
                    errorMaxLines: 3,
                  ),
                ),
                const SizedBox(height: 16),
                FilledButton.icon(
                  onPressed: _busy ? null : _connect,
                  icon: _busy
                      ? const SizedBox.square(dimension: 18, child: CircularProgressIndicator(strokeWidth: 2))
                      : const Icon(Icons.link),
                  label: const Text('Connect'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
