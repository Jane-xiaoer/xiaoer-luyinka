// 云端：上传卡上的录音 → 转写 → 拿回逐字稿和播放用的音频 → 叫云端删掉（server/app.py）。云端不留内容。
import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

class CloudError implements Exception {
  final String message;
  final int status;
  CloudError(this.message, [this.status = 0]);
  @override
  String toString() => message;
}

class Cloud {
  String base;
  String? token;
  static Cloud? instance; // App 里只有一个
  void Function(String token)? onToken; // 重新登记后让 App 存下来
  Cloud(this.base, {this.token}) {
    instance = this;
  }

  Map<String, String> get _auth => {'Authorization': 'Bearer ${token ?? ''}'};

  Future<Map<String, dynamic>> _json(http.Response r) async {
    final body = utf8.decode(r.bodyBytes);
    final d = body.isEmpty ? <String, dynamic>{} : jsonDecode(body) as Map<String, dynamic>;
    if (r.statusCode != 200) throw CloudError(d['error']?.toString() ?? '云端出错（${r.statusCode}）', r.statusCode);
    return d;
  }

  Future<String> register() async {
    final d = await _json(await http.post(Uri.parse('$base/v1/register')));
    token = d['token'] as String;
    onToken?.call(token!);
    return token!;
  }

  /// 卡上原文件 → 任务 id。
  Future<String> upload(String name, Uint8List raw, String tz) async {
    final uri = Uri.parse('$base/v1/recordings').replace(queryParameters: {'name': name, 'tz': tz, 'asr': '1'});
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

  /// 取走了：云端把这条全删。
  Future<void> delete(String id) async {
    await http.delete(Uri.parse('$base/v1/recordings/$id'), headers: _auth);
  }

  Future<String> ask(String question, List<Map<String, dynamic>> scenes) async {
    Future<http.Response> post() => http.post(Uri.parse('$base/v1/ask'),
        headers: {..._auth, 'Content-Type': 'application/json'},
        body: jsonEncode({'question': question, 'scenes': scenes}));
    if (token == null) await register();
    var r = await post();
    if (r.statusCode == 401) {
      // 云端不认这个登记（换了服务器 / 数据重置）：重新登记再问一次
      await register();
      r = await post();
    }
    return (await _json(r))['answer'] as String;
  }
}
