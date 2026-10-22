import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';

import 'rider_repository.dart';

class RiderRegistrationScreen extends StatefulWidget {
  const RiderRegistrationScreen({super.key});

  @override
  State<RiderRegistrationScreen> createState() => _RiderRegistrationScreenState();
}

class _RiderRegistrationScreenState extends State<RiderRegistrationScreen> {
  final _repo = RiderRepository();
  final _picker = ImagePicker();
  final _make = TextEditingController();
  final _color = TextEditingController();
  final _plate = TextEditingController();

  bool _loading = true;
  bool _busy = false;
  String? _uploadingType;
  String? _error;
  Map<String, dynamic>? _rider;
  Map<String, Map<String, dynamic>> _docs = {};

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _make.dispose();
    _color.dispose();
    _plate.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final rider = await _repo.myRider();
      final docs = rider == null ? <String, Map<String, dynamic>>{} : await _repo.myLatestDocuments();
      if (!mounted) return;
      setState(() {
        _rider = rider;
        _docs = docs;
        _loading = false;
        _error = null;
        if (rider != null) {
          _make.text = rider['vehicle_make'] ?? '';
          _color.text = rider['vehicle_color'] ?? '';
          _plate.text = rider['plate_number'] ?? '';
        }
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = 'Could not load your rider account. Check your network.';
      });
    }
  }

  bool get _vehicleValid =>
      _make.text.trim().isNotEmpty && _color.text.trim().isNotEmpty && _plate.text.trim().length >= 4;

  Future<void> _saveVehicle() async {
    if (!_vehicleValid) {
      setState(() => _error = 'Fill in make, color and a valid plate number.');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      if (_rider == null) {
        await _repo.register(make: _make.text.trim(), color: _color.text.trim(), plate: _plate.text.trim().toUpperCase());
      } else {
        await _repo.updateVehicle(make: _make.text.trim(), color: _color.text.trim(), plate: _plate.text.trim().toUpperCase());
      }
      await _load();
    } catch (_) {
      _error = 'Could not save. Try again.';
    }
    if (mounted) setState(() => _busy = false);
  }

  Future<void> _upload(String type) async {
    final source = await showModalBottomSheet<ImageSource>(
      context: context,
      builder: (_) => SafeArea(
        child: Wrap(children: [
          ListTile(
            leading: const Icon(Icons.photo_camera),
            title: const Text('Take a photo'),
            onTap: () => Navigator.pop(context, ImageSource.camera),
          ),
          ListTile(
            leading: const Icon(Icons.photo_library),
            title: const Text('Choose from gallery'),
            onTap: () => Navigator.pop(context, ImageSource.gallery),
          ),
        ]),
      ),
    );
    if (source == null) return;

    final file = await _picker.pickImage(source: source, maxWidth: 1600, imageQuality: 80);
    if (file == null) return;

    setState(() {
      _uploadingType = type;
      _error = null;
    });
    try {
      await _repo.uploadDocument(type, file);
      await _load();
    } catch (_) {
      _error = 'Upload failed. Check your network and try again.';
    }
    if (mounted) setState(() => _uploadingType = null);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Rider account')),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.all(24),
              children: [
                if (_rider != null) _StatusBanner(status: _rider!['status'] as String),
                Text('Vehicle', style: Theme.of(context).textTheme.titleMedium),
                const SizedBox(height: 12),
                TextField(
                  controller: _make,
                  textCapitalization: TextCapitalization.words,
                  decoration: const InputDecoration(labelText: 'Motorbike make and model', border: OutlineInputBorder()),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: _color,
                  textCapitalization: TextCapitalization.words,
                  decoration: const InputDecoration(labelText: 'Color', border: OutlineInputBorder()),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: _plate,
                  textCapitalization: TextCapitalization.characters,
                  decoration: const InputDecoration(labelText: 'Plate number', border: OutlineInputBorder()),
                ),
                if (_error != null) ...[
                  const SizedBox(height: 12),
                  Text(_error!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
                ],
                const SizedBox(height: 16),
                FilledButton(
                  onPressed: _busy ? null : _saveVehicle,
                  child: Text(_rider == null ? 'Register as a rider' : 'Save vehicle details'),
                ),
                if (_rider != null) ...[
                  const SizedBox(height: 32),
                  Text('Documents', style: Theme.of(context).textTheme.titleMedium),
                  const SizedBox(height: 4),
                  const Text('Upload clear photos. All four required documents must be verified before you can go online.'),
                  const SizedBox(height: 12),
                  for (final type in [...requiredDocTypes, ...optionalDocTypes])
                    _DocTile(
                      label: docLabels[type]!,
                      required: requiredDocTypes.contains(type),
                      doc: _docs[type],
                      uploading: _uploadingType == type,
                      onUpload: _uploadingType == null ? () => _upload(type) : null,
                    ),
                ],
              ],
            ),
    );
  }
}

class _StatusBanner extends StatelessWidget {
  const _StatusBanner({required this.status});
  final String status;

  @override
  Widget build(BuildContext context) {
    final (text, color) = switch (status) {
      'approved' => ('Approved. You can ride with OKADA.', Colors.green),
      'rejected' => ('Rejected. Contact support or fix your documents.', Colors.red),
      'suspended' => ('Suspended. Contact support.', Colors.red),
      _ => ('Pending review. Upload all documents and wait for approval.', Colors.orange),
    };
    return Container(
      margin: const EdgeInsets.only(bottom: 20),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: color),
      ),
      child: Text(text),
    );
  }
}

class _DocTile extends StatelessWidget {
  const _DocTile({
    required this.label,
    required this.required,
    required this.doc,
    required this.uploading,
    required this.onUpload,
  });

  final String label;
  final bool required;
  final Map<String, dynamic>? doc;
  final bool uploading;
  final VoidCallback? onUpload;

  @override
  Widget build(BuildContext context) {
    final status = doc?['status'] as String?;
    final (statusText, color) = switch (status) {
      'verified' => ('Verified', Colors.green),
      'rejected' => ('Rejected: upload again', Colors.red),
      'pending' => ('Uploaded, waiting for review', Colors.orange),
      _ => (required ? 'Required' : 'Optional', Colors.grey),
    };
    final note = doc?['notes'] as String?;
    return Card(
      child: ListTile(
        title: Text(label),
        subtitle: Text(
          note != null && note.isNotEmpty && status == 'rejected' ? '$statusText\n$note' : statusText,
          style: TextStyle(color: color),
        ),
        isThreeLine: note != null && note.isNotEmpty && status == 'rejected',
        trailing: uploading
            ? const SizedBox(height: 20, width: 20, child: CircularProgressIndicator(strokeWidth: 2))
            : TextButton(
                onPressed: onUpload,
                child: Text(doc == null ? 'Upload' : 'Replace'),
              ),
      ),
    );
  }
}
