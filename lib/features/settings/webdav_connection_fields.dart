import 'package:flutter/material.dart';
import 'package:venera_next/foundation/translations.dart';

class WebDavConnectionControllers {
  WebDavConnectionControllers({
    required String url,
    required String user,
    required String password,
    required String remotePath,
  }) : url = TextEditingController(text: url),
       user = TextEditingController(text: user),
       password = TextEditingController(text: password),
       remotePath = TextEditingController(text: remotePath);

  final TextEditingController url;
  final TextEditingController user;
  final TextEditingController password;
  final TextEditingController remotePath;

  void dispose() {
    url.dispose();
    user.dispose();
    password.dispose();
    remotePath.dispose();
  }
}

class WebDavConnectionFields extends StatelessWidget {
  const WebDavConnectionFields({
    super.key,
    required this.controllers,
    required this.remotePathHint,
    this.enabled = true,
  });

  final WebDavConnectionControllers controllers;
  final String remotePathHint;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        TextField(
          enabled: enabled,
          decoration: InputDecoration(
            labelText: 'URL',
            hintText: 'A valid WebDav directory URL'.tl,
            border: const OutlineInputBorder(),
          ),
          controller: controllers.url,
        ),
        const SizedBox(height: 12),
        TextField(
          enabled: enabled,
          decoration: InputDecoration(
            labelText: 'Username'.tl,
            border: const OutlineInputBorder(),
          ),
          controller: controllers.user,
        ),
        const SizedBox(height: 12),
        TextField(
          enabled: enabled,
          decoration: InputDecoration(
            labelText: 'Password'.tl,
            border: const OutlineInputBorder(),
          ),
          controller: controllers.password,
          obscureText: true,
        ),
        const SizedBox(height: 12),
        TextField(
          enabled: enabled,
          decoration: InputDecoration(
            labelText: 'Remote Path'.tl,
            hintText: remotePathHint,
            border: const OutlineInputBorder(),
          ),
          controller: controllers.remotePath,
        ),
      ],
    );
  }
}
