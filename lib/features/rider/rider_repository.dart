import 'package:image_picker/image_picker.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../core/config.dart';

/// Document types, matching the `doc_type` enum in the database.
const requiredDocTypes = ['national_id', 'drivers_license', 'vehicle_registration', 'insurance'];
const optionalDocTypes = ['photo'];

const docLabels = {
  'national_id': 'National ID (Ghana Card)',
  'drivers_license': "Driver's license",
  'vehicle_registration': 'Vehicle registration',
  'insurance': 'Insurance',
  'photo': 'Your photo',
};

class RiderRepository {
  String get _uid => supabase.auth.currentUser!.id;

  Future<Map<String, dynamic>?> myRider() =>
      supabase.from('riders').select().eq('id', _uid).maybeSingle();

  Future<void> register({
    required String make,
    required String color,
    required String plate,
  }) =>
      supabase.from('riders').insert({
        'id': _uid,
        'vehicle_make': make,
        'vehicle_color': color,
        'plate_number': plate,
      });

  Future<void> updateVehicle({
    required String make,
    required String color,
    required String plate,
  }) =>
      supabase.from('riders').update({
        'vehicle_make': make,
        'vehicle_color': color,
        'plate_number': plate,
      }).eq('id', _uid);

  /// Latest document per type, keyed by type.
  Future<Map<String, Map<String, dynamic>>> myLatestDocuments() async {
    final rows = await supabase
        .from('rider_documents')
        .select()
        .eq('rider_id', _uid)
        .order('created_at', ascending: false);
    final latest = <String, Map<String, dynamic>>{};
    for (final row in rows) {
      latest.putIfAbsent(row['type'] as String, () => row);
    }
    return latest;
  }

  Future<void> uploadDocument(String type, XFile file) async {
    final bytes = await file.readAsBytes();
    final dot = file.name.lastIndexOf('.');
    final ext = dot == -1 ? 'jpg' : file.name.substring(dot + 1).toLowerCase();
    final path = '$_uid/${type}_${DateTime.now().millisecondsSinceEpoch}.$ext';
    await supabase.storage.from('rider-documents').uploadBinary(
          path,
          bytes,
          fileOptions: FileOptions(contentType: ext == 'png' ? 'image/png' : 'image/jpeg'),
        );
    await supabase.from('rider_documents').insert({
      'rider_id': _uid,
      'type': type,
      'file_path': path,
    });
  }
}
