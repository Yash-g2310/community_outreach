import 'dart:convert';
import 'dart:typed_data';
import 'package:http/http.dart' as http;
import '../constants.dart';
import '../models/profile_model.dart';

class ProfileService {
  final http.Client client;

  ProfileService({http.Client? client}) : client = client ?? http.Client();

  Future<Profile> fetchProfile(String token, {required bool isDriver}) async {
    final endpoint = isDriver
        ? '$kBaseUrl/api/rides/driver/profile/'
        : '$kBaseUrl/api/rides/user/profile/';

    final res = await client.get(
      Uri.parse(endpoint),
      headers: {
        'Authorization': 'Bearer $token',
        'Content-Type': 'application/json',
      },
    );

    if (res.statusCode != 200) {
      throw Exception('Failed to fetch profile: ${res.statusCode}');
    }

    final data = jsonDecode(res.body) as Map<String, dynamic>;
    return Profile.fromApi(data, isDriver: isDriver);
  }

  Future<String?> uploadProfilePicture(
    String token,
    Uint8List bytes,
    String filename,
  ) async {
    final endpoint = '$kBaseUrl/api/rides/user/profile/';
    final req = http.MultipartRequest('PATCH', Uri.parse(endpoint));
    req.headers['Authorization'] = 'Bearer $token';
    req.files.add(
      http.MultipartFile.fromBytes(
        'profile_picture',
        bytes,
        filename: filename,
      ),
    );

    final streamed = await req.send();
    final res = await http.Response.fromStream(streamed);

    if (res.statusCode != 200) {
      throw Exception('Upload failed: ${res.statusCode}');
    }

    final data = jsonDecode(res.body) as Map<String, dynamic>;
    return data['profile_picture_url']?.toString();
  }
}
