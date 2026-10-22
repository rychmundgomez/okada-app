import 'package:flutter/material.dart';

import '../../core/config.dart';
import '../admin/rider_approvals_screen.dart';
import '../customer/customer_home_screen.dart';
import '../rider/rider_registration_screen.dart';

/// Placeholder shell. Next steps replace the body:
///  customer -> map + request ride, rider -> online toggle + offers.
class HomeScreen extends StatelessWidget {
  const HomeScreen({super.key, required this.profile, required this.onRefresh});

  final Map<String, dynamic> profile;

  /// Reloads the profile (role can change after rider registration).
  final VoidCallback onRefresh;

  @override
  Widget build(BuildContext context) {
    final role = profile['role'] as String;

    Future<void> open(Widget screen) async {
      await Navigator.of(context).push(MaterialPageRoute(builder: (_) => screen));
      onRefresh();
    }

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
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text('Hello ${profile['full_name']} ($role)', textAlign: TextAlign.center),
              const SizedBox(height: 24),
              if (role == 'customer' || role == 'rider') ...[
                FilledButton.icon(
                  onPressed: () => open(const CustomerHomeScreen()),
                  icon: const Icon(Icons.local_taxi),
                  label: const Text('Request a ride'),
                ),
                const SizedBox(height: 12),
              ],
              if (role == 'admin')
                FilledButton.icon(
                  onPressed: () => open(const RiderApprovalsScreen()),
                  icon: const Icon(Icons.verified_user),
                  label: const Text('Rider approvals'),
                )
              else
                FilledButton.icon(
                  onPressed: () => open(const RiderRegistrationScreen()),
                  icon: const Icon(Icons.two_wheeler),
                  label: Text(role == 'rider' ? 'My rider account' : 'Become a rider'),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
