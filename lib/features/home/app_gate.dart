import 'package:flutter/material.dart';

import '../../core/config.dart';

/// Loads the signed-in user's profile, asks for a name on first login,
/// then shows the home screen for their role.
class AppGate extends StatefulWidget {
  const AppGate({super.key});

  @override
  State<AppGate> createState() => _AppGateState();
}

class _AppGateState extends State<AppGate> {
  late Future<Map<String, dynamic>> _profile = _load();

  Future<Map<String, dynamic>> _load() => supabase
      .from('profiles')
      .select('id, role, full_name, phone')
      .eq('id', supabase.auth.currentUser!.id)
      .single();

  void _reload() => setState(() => _profile = _load());

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<Map<String, dynamic>>(
      future: _profile,
      builder: (context, snap) {
        if (snap.connectionState != ConnectionState.done) {
          return const Scaffold(body: Center(child: CircularProgressIndicator()));
        }
        if (snap.hasError || snap.data == null) {
          return Scaffold(
            body: Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Text('Could not load your profile.'),
                  TextButton(onPressed: _reload, child: const Text('Retry')),
                  TextButton(onPressed: () => supabase.auth.signOut(), child: const Text('Sign out')),
                ],
              ),
            ),
          );
        }
        final profile = snap.data!;
        final name = (profile['full_name'] as String?)?.trim() ?? '';
        if (name.isEmpty) return _ProfileSetup(onDone: _reload);
        return HomeScreen(profile: profile);
      },
    );
  }
}

class _ProfileSetup extends StatefulWidget {
  const _ProfileSetup({required this.onDone});
  final VoidCallback onDone;

  @override
  State<_ProfileSetup> createState() => _ProfileSetupState();
}

class _ProfileSetupState extends State<_ProfileSetup> {
  final _name = TextEditingController();
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final name = _name.text.trim();
    if (name.length < 2) {
      setState(() => _error = 'Enter your full name.');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await supabase.from('profiles').update({'full_name': name}).eq('id', supabase.auth.currentUser!.id);
      widget.onDone();
    } catch (_) {
      if (mounted) {
        setState(() {
          _busy = false;
          _error = 'Could not save. Try again.';
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text('Welcome', style: Theme.of(context).textTheme.headlineMedium),
              const SizedBox(height: 16),
              TextField(
                controller: _name,
                textCapitalization: TextCapitalization.words,
                decoration: const InputDecoration(labelText: 'Full name', border: OutlineInputBorder()),
              ),
              if (_error != null) ...[
                const SizedBox(height: 8),
                Text(_error!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
              ],
              const SizedBox(height: 16),
              FilledButton(
                onPressed: _busy ? null : _save,
                child: const Text('Continue'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Placeholder shell. Next steps replace the body:
///  customer -> map + request ride, rider -> online toggle + offers.
class HomeScreen extends StatelessWidget {
  const HomeScreen({super.key, required this.profile});
  final Map<String, dynamic> profile;

  @override
  Widget build(BuildContext context) {
    final role = profile['role'] as String;
    return Scaffold(
      appBar: AppBar(
        title: const Text('OKADA'),
        actions: [
          IconButton(
            tooltip: 'Sign out',
            icon: const Icon(Icons.logout),
            onPressed: () => supabase.auth.signOut(),
          ),
        ],
      ),
      body: Center(
        child: Text('Hello ${profile['full_name']} ($role)'),
      ),
    );
  }
}
