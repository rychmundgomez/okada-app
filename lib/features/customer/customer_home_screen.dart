import 'package:flutter/material.dart';
import 'package:geocoding/geocoding.dart';
import 'package:geolocator/geolocator.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';

import '../../core/config.dart';

/// Customer: pick a destination on the map, see the fare, request a ride.
class CustomerHomeScreen extends StatefulWidget {
  const CustomerHomeScreen({super.key});

  @override
  State<CustomerHomeScreen> createState() => _CustomerHomeScreenState();
}

class _CustomerHomeScreenState extends State<CustomerHomeScreen> {
  // Fallback if location is denied: Ho, Volta Region.
  static const _ho = LatLng(6.6008, 0.4713);
  static const _avgSpeedKmh = 25.0; // rough average for a motorbike in town
  static const _roadFactor = 1.3; // straight line -> road distance

  GoogleMapController? _map;
  LatLng? _pickup;
  LatLng? _dropoff;
  String _pickupAddress = 'Current location';
  String _dropoffAddress = '';
  Map<String, dynamic>? _fares;
  Map<String, dynamic>? _ride; // active ride, if any
  bool _loading = true;
  bool _busy = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _init();
  }

  Future<void> _init() async {
    try {
      final results = await Future.wait([_locate(), _loadFares(), _loadActiveRide()]);
      final pos = results[0] as LatLng;
      _fares = results[1] as Map<String, dynamic>?;
      _ride = results[2] as Map<String, dynamic>?;
      _pickup = pos;
      _pickupAddress = await _addressFor(pos) ?? 'Current location';
    } catch (_) {
      _error = 'Could not load the map. Check your network and location settings.';
    }
    if (mounted) setState(() => _loading = false);
  }

  Future<LatLng> _locate() async {
    var permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied) {
      permission = await Geolocator.requestPermission();
    }
    final denied = permission == LocationPermission.denied || permission == LocationPermission.deniedForever;
    if (denied || !await Geolocator.isLocationServiceEnabled()) return _ho;
    final p = await Geolocator.getCurrentPosition(
      locationSettings: const LocationSettings(accuracy: LocationAccuracy.high),
    );
    return LatLng(p.latitude, p.longitude);
  }

  Future<Map<String, dynamic>?> _loadFares() =>
      supabase.from('fare_settings').select().eq('id', 1).maybeSingle();

  Future<Map<String, dynamic>?> _loadActiveRide() => supabase
      .from('rides')
      .select()
      .eq('customer_id', supabase.auth.currentUser!.id)
      .inFilter('status', ['requested', 'assigned', 'arriving', 'in_progress'])
      .order('created_at', ascending: false)
      .limit(1)
      .maybeSingle();

  Future<String?> _addressFor(LatLng p) async {
    try {
      final marks = await placemarkFromCoordinates(p.latitude, p.longitude);
      if (marks.isEmpty) return null;
      final m = marks.first;
      final parts = [m.street, m.subLocality, m.locality].where((e) => e != null && e.trim().isNotEmpty);
      return parts.isEmpty ? null : parts.join(', ');
    } catch (_) {
      return null; // geocoding is best effort
    }
  }

  Future<void> _setDropoff(LatLng p) async {
    setState(() {
      _dropoff = p;
      _dropoffAddress = 'Finding address...';
      _error = null;
    });
    final address = await _addressFor(p);
    if (mounted && _dropoff == p) {
      setState(() => _dropoffAddress = address ?? 'Dropped pin');
    }
  }

  double? get _distanceKm {
    if (_pickup == null || _dropoff == null) return null;
    final meters = Geolocator.distanceBetween(
      _pickup!.latitude, _pickup!.longitude, _dropoff!.latitude, _dropoff!.longitude);
    final km = meters / 1000 * _roadFactor;
    return km < 0.1 ? 0.1 : double.parse(km.toStringAsFixed(2));
  }

  double? get _durationMin {
    final km = _distanceKm;
    if (km == null) return null;
    return double.parse((km / _avgSpeedKmh * 60).clamp(1, 600).toStringAsFixed(1));
  }

  /// Same formula the server uses; the server's number is the one that counts.
  double? get _fare {
    final km = _distanceKm, min = _durationMin, f = _fares;
    if (km == null || min == null || f == null) return null;
    num n(String k) => num.parse('${f[k]}');
    final raw = n('base_fare') + n('per_km') * km + n('per_min') * min;
    final fare = raw < n('min_fare') ? n('min_fare') : raw;
    return double.parse(fare.toStringAsFixed(2));
  }

  Future<void> _requestRide() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final ride = await supabase.rpc('request_ride', params: {
        'p_pickup_lat': _pickup!.latitude,
        'p_pickup_lng': _pickup!.longitude,
        'p_pickup_address': _pickupAddress,
        'p_dropoff_lat': _dropoff!.latitude,
        'p_dropoff_lng': _dropoff!.longitude,
        'p_dropoff_address': _dropoffAddress,
        'p_distance_km': _distanceKm,
        'p_duration_min': _durationMin,
      });
      _ride = Map<String, dynamic>.from(ride as Map);
      // First matching attempt. Retry loop and live updates come next.
      await supabase.rpc('dispatch_next_rider', params: {'p_ride_id': _ride!['id']});
      _ride = await _loadActiveRide();
    } catch (e) {
      _error = e.toString().contains('active ride')
          ? 'You already have an active ride.'
          : 'Could not request a ride. Try again.';
    }
    if (mounted) setState(() => _busy = false);
  }

  Future<void> _cancelRide() async {
    setState(() => _busy = true);
    try {
      await supabase.rpc('update_ride_status', params: {
        'p_ride_id': _ride!['id'],
        'p_new_status': 'cancelled',
        'p_cancel_reason': 'Cancelled by customer',
      });
      _ride = null;
      _dropoff = null;
    } catch (_) {
      _error = 'Could not cancel. Try again.';
    }
    if (mounted) setState(() => _busy = false);
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }
    final start = _pickup ?? _ho;
    return Scaffold(
      appBar: AppBar(title: const Text('Request a ride')),
      body: Stack(
        children: [
          GoogleMap(
            initialCameraPosition: CameraPosition(target: start, zoom: 15),
            myLocationEnabled: _pickup != null,
            myLocationButtonEnabled: true,
            zoomControlsEnabled: false,
            onMapCreated: (c) => _map = c,
            onTap: _ride == null ? _setDropoff : null,
            markers: {
              if (_dropoff != null)
                Marker(markerId: const MarkerId('dropoff'), position: _dropoff!),
            },
          ),
          Align(alignment: Alignment.bottomCenter, child: _panel(context)),
        ],
      ),
    );
  }

  Widget _panel(BuildContext context) {
    final theme = Theme.of(context);
    Widget content;

    if (_ride != null) {
      final status = _ride!['status'] as String;
      final label = switch (status) {
        'requested' => 'Looking for a rider...',
        'assigned' => 'A rider accepted your ride',
        'arriving' => 'Your rider is on the way',
        'in_progress' => 'Trip in progress',
        _ => status,
      };
      content = Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(label, style: theme.textTheme.titleMedium),
          Text('To: ${_ride!['dropoff_address'] ?? ''}'),
          Text('Fare: GH₵ ${_ride!['fare_estimate']}'),
          const SizedBox(height: 12),
          if (status == 'requested' || status == 'assigned' || status == 'arriving')
            OutlinedButton(
              onPressed: _busy ? null : _cancelRide,
              child: const Text('Cancel ride'),
            ),
        ],
      );
    } else if (_dropoff == null) {
      content = const Text('Tap the map to choose where you are going.');
    } else {
      final km = _distanceKm!, fare = _fare;
      content = Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text('From: $_pickupAddress'),
          Text('To: $_dropoffAddress'),
          const SizedBox(height: 8),
          Text(
            '${km.toStringAsFixed(1)} km · about ${_durationMin!.round()} min'
            '${fare == null ? '' : ' · GH₵ ${fare.toStringAsFixed(2)}'}',
            style: theme.textTheme.titleMedium,
          ),
          const SizedBox(height: 12),
          FilledButton(
            onPressed: _busy ? null : _requestRide,
            child: _busy
                ? const SizedBox(height: 20, width: 20, child: CircularProgressIndicator(strokeWidth: 2))
                : const Text('Request ride'),
          ),
        ],
      );
    }

    return SafeArea(
      child: Card(
        margin: const EdgeInsets.all(12),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              content,
              if (_error != null) ...[
                const SizedBox(height: 8),
                Text(_error!, style: TextStyle(color: theme.colorScheme.error)),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
