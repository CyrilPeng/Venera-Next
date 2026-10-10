import 'dart:async';
import 'dart:convert';

import 'package:venera_next/foundation/extensions.dart';
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
          final source = ComicSource.requireRuntime(
            context.key,
            context.identity,
          );
          await context.runCodeToCompletion<void>("""
          ${context.sourceExpression}.account.login(${jsonEncode(account)},
          ${jsonEncode(pwd)})
        """, consume: (_) {});
          final edit = source.prepareDataEdit(
            (draft) => draft["account"] = <String>[account, pwd],
          );
          try {
            await edit.save();
          } catch (error, stack) {
            throw SourceLoginPersistenceFailure(edit, error, stack);
          }
          return const Res(true);
        } catch (e, s) {
          Log.error("Network", "$e\n$s");
          return context.failureResult(e, s);
        }
      };
    }

    Future<void> logout() async {
      await context.runCodeToCompletion<void>(
        "${context.sourceExpression}.account.logout()",
        consume: (_) {},
      );
    }

    bool Function(String url, String title)? checkLoginStatus;

    Future<void> Function()? onLoginSuccess;

    if (context.checkExists('account.loginWithWebview')) {
      checkLoginStatus = (url, title) {
        return context.consumeSynchronous(
          () => context.runOwnedCode("""
            ${context.sourceExpression}.account.loginWithWebview.checkStatus(
              ${jsonEncode(url)}, ${jsonEncode(title)})
          """),
          (value) => value as bool,
        );
      };

      if (context.checkExists('account.loginWithWebview.onLoginSuccess')) {
        onLoginSuccess = () async {
          await context.runCodeToCompletion<void>("""
            ${context.sourceExpression}.account.loginWithWebview.onLoginSuccess()
          """, consume: (_) {});
        };
      }
    }

    Future<bool> Function(List<String>)? validateCookies;

    if (context.checkExists('account.loginWithCookies?.validate')) {
      validateCookies = (cookies) async {
        try {
          return await context.runReadCodeToCompletion<bool>("""
            ${context.sourceExpression}.account.loginWithCookies.validate(${jsonEncode(cookies)})
          """, consume: (res) => res as bool);
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
