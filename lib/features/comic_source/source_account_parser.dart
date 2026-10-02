import 'dart:async';
import 'dart:convert';

import 'package:venera_next/foundation/extensions.dart';
import 'package:venera_next/foundation/js_engine.dart';
import 'package:venera_next/foundation/log.dart';
import 'package:venera_next/foundation/res.dart';

import 'source.dart';

import 'source_parser_context.dart';

class SourceAccountParser {
  const SourceAccountParser(this.context);
  final SourceParserContext context;

  AccountConfig? loadAccountConfig() {
    if (!context.checkExists("account")) {
      return null;
    }

    Future<Res<bool>> Function(String account, String pwd)? login;

    if (context.checkExists("account.login")) {
      login = (account, pwd) async {
        try {
          await JsEngine().runCode("""
          ComicSource.sources.${context.key}.account.login(${jsonEncode(account)},
          ${jsonEncode(pwd)})
        """);
          var source = ComicSource.find(context.key)!;
          source.data["account"] = <String>[account, pwd];
          source.saveData();
          return const Res(true);
        } catch (e, s) {
          Log.error("Network", "$e\n$s");
          return Res.error(e.toString());
        }
      };
    }

    void logout() {
      JsEngine().runCode("ComicSource.sources.${context.key}.account.logout()");
    }

    bool Function(String url, String title)? checkLoginStatus;

    void Function()? onLoginSuccess;

    if (context.checkExists('account.loginWithWebview')) {
      checkLoginStatus = (url, title) {
        return JsEngine().runCode("""
            ComicSource.sources.${context.key}.account.loginWithWebview.checkStatus(
              ${jsonEncode(url)}, ${jsonEncode(title)})
          """);
      };

      if (context.checkExists('account.loginWithWebview.onLoginSuccess')) {
        onLoginSuccess = () {
          JsEngine().runCode("""
            ComicSource.sources.${context.key}.account.loginWithWebview.onLoginSuccess()
          """);
        };
      }
    }

    Future<bool> Function(List<String>)? validateCookies;

    if (context.checkExists('account.loginWithCookies?.validate')) {
      validateCookies = (cookies) async {
        try {
          var res = await JsEngine().runReadCode("""
            ComicSource.sources.${context.key}.account.loginWithCookies.validate(${jsonEncode(cookies)})
          """);
          return res;
        } catch (e, s) {
          Log.error("Network", "$e\n$s");
          return false;
        }
      };
    }

    return AccountConfig(
      login,
      context.getValue("account.loginWithWebview?.url"),
      context.getValue("account.registerWebsite"),
      logout,
      checkLoginStatus,
      onLoginSuccess,
      ListOrNull.from(context.getValue("account.loginWithCookies?.fields")),
      validateCookies,
    );
  }
}
