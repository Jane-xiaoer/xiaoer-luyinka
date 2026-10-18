// 云端：上传卡上的录音 → 转写 + 切场景 → 拿回结果（server/app.py）。用户设备上不跑任何模型。
import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

class CloudError implements Exception {
  final String message;
  CloudError(this.message);
  @override
  String toString() => message;
}

class Cloud {
  final String base;
  String? token;
  Cloud(this.base, {this.token});

  Map<String, String> get _auth => {'Authorization': 'Bearer ${token ?? ''}'};

  Future<Map<String, dynamic>> _json(http.Response r) async {
    final body = utf8.decode(r.bodyBytes);
    final d = body.isEmpty ? <String, dynamic>{} : jsonDecode(body) as Map<String, dynamic>;
    if (r.statusCode != 200) throw CloudError(d['error']?.toString() ?? '云端出错（${r.statusCode}）');
    return d;
  }

  Future<String> register() async {
    final d = await _json(await http.post(Uri.parse('$base/v1/register')));
    return token = d['token'] as String;
  }

  /// 卡上原文件 → 任务 id。
  Future<String> upload(String name, Uint8List raw, String tz) async {
    final uri = Uri.parse('$base/v1/recordings').replace(queryParameters: {'name': name, 'tz': tz});
    final d = await _json(await http.post(uri, headers: {..._auth, 'Content-Type': 'application/octet-stream'}, body: raw));
    return d['id'] as String;
  }

  /// {status: queued|working|done|error, progress, result?, error?}
  Future<Map<String, dynamic>> job(String id) async =>
      _json(await http.get(Uri.parse('$base/v1/recordings/$id'), headers: _auth));

  Future<Uint8List> audio(String id) async {
    final r = await http.get(Uri.parse('$base/v1/recordings/$id/audio'), headers: _auth);
    if (r.statusCode != 200) throw CloudError('音频还没好');
    return r.bodyBytes;
  }

  Future<String> ask(String question, List<Map<String, dynamic>> scenes) async {
    final d = await _json(await http.post(Uri.parse('$base/v1/ask'),
        headers: {..._auth, 'Content-Type': 'application/json'},
        body: jsonEncode({'question': question, 'scenes': scenes})));
    return d['answer'] as String;
  }
}
