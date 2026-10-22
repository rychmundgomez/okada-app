import 'package:flutter/material.dart';

import '../../core/config.dart';
import '../rider/rider_repository.dart';

/// Admin: list riders waiting for approval.
class RiderApprovalsScreen extends StatefulWidget {
  const RiderApprovalsScreen({super.key});

  @override
  State<RiderApprovalsScreen> createState() => _RiderApprovalsScreenState();
}

class _RiderApprovalsScreenState extends State<RiderApprovalsScreen> {
  late Future<List<Map<String, dynamic>>> _riders = _load();

  Future<List<Map<String, dynamic>>> _load() async {
    final rows = await supabase
        .from('riders')
        .select('id, status, vehicle_make, vehicle_color, plate_number, created_at, profiles!riders_id_fkey(full_name, phone)')
        .eq('status', 'pending')
        .order('created_at');
    return List<Map<String, dynamic>>.from(rows);
  }

  Future<void> _open(Map<String, dynamic> rider) async {
    await Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => RiderReviewScreen(rider: rider)),
    );
    setState(() => _riders = _load());
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Rider approvals')),
      body: FutureBuilder<List<Map<String, dynamic>>>(
        future: _riders,
        builder: (context, snap) {
          if (snap.connectionState != ConnectionState.done) {
            return const Center(child: CircularProgressIndicator());
          }
          if (snap.hasError) return const Center(child: Text('Could not load riders.'));
          final riders = snap.data!;
          if (riders.isEmpty) return const Center(child: Text('No riders waiting for approval.'));
          return ListView.separated(
            itemCount: riders.length,
            separatorBuilder: (_, __) => const Divider(height: 1),
            itemBuilder: (_, i) {
              final r = riders[i];
              final p = r['profiles'] as Map<String, dynamic>?;
              return ListTile(
                title: Text(p?['full_name'] ?? 'Unnamed rider'),
                subtitle: Text('${p?['phone'] ?? ''}\n${r['vehicle_make']} · ${r['vehicle_color']} · ${r['plate_number']}'),
                isThreeLine: true,
                trailing: const Icon(Icons.chevron_right),
                onTap: () => _open(r),
              );
            },
          );
        },
      ),
    );
  }
}

/// Admin: review one rider's documents, then approve or reject.
class RiderReviewScreen extends StatefulWidget {
  const RiderReviewScreen({super.key, required this.rider});
  final Map<String, dynamic> rider;

  @override
  State<RiderReviewScreen> createState() => _RiderReviewScreenState();
}

class _RiderReviewScreenState extends State<RiderReviewScreen> {
  late Future<List<_DocView>> _docs = _load();
  bool _busy = false;

  String get _riderId => widget.rider['id'] as String;

  Future<List<_DocView>> _load() async {
    final rows = await supabase
        .from('rider_documents')
        .select()
        .eq('rider_id', _riderId)
        .order('created_at', ascending: false);

    // Latest document per type only.
    final latest = <String, Map<String, dynamic>>{};
    for (final row in rows) {
      latest.putIfAbsent(row['type'] as String, () => row);
    }
    return Future.wait(latest.values.map((doc) async {
      final url = await supabase.storage.from('rider-documents').createSignedUrl(doc['file_path'] as String, 300);
      return _DocView(doc, url);
    }));
  }

  void _toast(String message) =>
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));

  Future<void> _reviewDoc(String docId, String status) async {
    String? notes;
    if (status == 'rejected') {
      notes = await _askNote('Why is this document rejected?');
      if (notes == null) return;
    }
    setState(() => _busy = true);
    try {
      await supabase.rpc('review_document', params: {'p_doc_id': docId, 'p_status': status, 'p_notes': notes});
      setState(() => _docs = _load());
    } catch (e) {
      _toast('Could not update document.');
    }
    if (mounted) setState(() => _busy = false);
  }

  Future<void> _setRiderStatus(String status) async {
    String? notes;
    if (status == 'rejected') {
      notes = await _askNote('Reason for rejecting this rider');
      if (notes == null) return;
    }
    setState(() => _busy = true);
    try {
      await supabase.rpc('set_rider_status', params: {'p_rider_id': _riderId, 'p_status': status, 'p_notes': notes});
      if (mounted) Navigator.of(context).pop();
      return;
    } catch (e) {
      // The database explains e.g. "All 4 required documents must be verified first".
      _toast(e.toString().contains('required documents')
          ? 'Verify all 4 required documents first.'
          : 'Could not update rider.');
    }
    if (mounted) setState(() => _busy = false);
  }

  Future<String?> _askNote(String title) {
    final controller = TextEditingController();
    return showDialog<String>(
      context: context,
      builder: (_) => AlertDialog(
        title: Text(title),
        content: TextField(controller: controller, autofocus: true, maxLines: 2),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(context, controller.text.trim()), child: const Text('Confirm')),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final p = widget.rider['profiles'] as Map<String, dynamic>?;
    return Scaffold(
      appBar: AppBar(title: Text(p?['full_name'] ?? 'Rider')),
      body: FutureBuilder<List<_DocView>>(
        future: _docs,
        builder: (context, snap) {
          if (snap.connectionState != ConnectionState.done) {
            return const Center(child: CircularProgressIndicator());
          }
          if (snap.hasError) return const Center(child: Text('Could not load documents.'));
          final docs = snap.data!;
          return ListView(
            padding: const EdgeInsets.all(16),
            children: [
              Text('${p?['phone'] ?? ''}'),
              Text('${widget.rider['vehicle_make']} · ${widget.rider['vehicle_color']} · ${widget.rider['plate_number']}'),
              const SizedBox(height: 16),
              for (final type in [...requiredDocTypes, ...optionalDocTypes])
                _docCard(type, docs.where((d) => d.doc['type'] == type).firstOrNull),
              const SizedBox(height: 16),
              Row(children: [
                Expanded(
                  child: OutlinedButton(
                    onPressed: _busy ? null : () => _setRiderStatus('rejected'),
                    child: const Text('Reject rider'),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: FilledButton(
                    onPressed: _busy ? null : () => _setRiderStatus('approved'),
                    child: const Text('Approve rider'),
                  ),
                ),
              ]),
            ],
          );
        },
      ),
    );
  }

  Widget _docCard(String type, _DocView? view) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(docLabels[type]!, style: Theme.of(context).textTheme.titleSmall),
            const SizedBox(height: 8),
            if (view == null)
              const Text('Not uploaded yet')
            else ...[
              ClipRRect(
                borderRadius: BorderRadius.circular(8),
                child: Image.network(
                  view.url,
                  height: 200,
                  width: double.infinity,
                  fit: BoxFit.cover,
                  errorBuilder: (_, __, ___) => const SizedBox(height: 80, child: Center(child: Text('Cannot preview file'))),
                ),
              ),
              const SizedBox(height: 8),
              Text('Status: ${view.doc['status']}'),
              Row(children: [
                TextButton(
                  onPressed: _busy ? null : () => _reviewDoc(view.doc['id'] as String, 'verified'),
                  child: const Text('Verify'),
                ),
                TextButton(
                  onPressed: _busy ? null : () => _reviewDoc(view.doc['id'] as String, 'rejected'),
                  child: const Text('Reject'),
                ),
              ]),
            ],
          ],
        ),
      ),
    );
  }
}

class _DocView {
  _DocView(this.doc, this.url);
  final Map<String, dynamic> doc;
  final String url;
}
