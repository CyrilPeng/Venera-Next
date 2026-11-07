import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:local_auth/local_auth.dart';
import 'package:venera_next/foundation/translations.dart';
import 'package:venera_next/foundation/harmonyos.dart';

class AuthPage extends StatefulWidget {
  const AuthPage({super.key, this.onSuccessfulAuth});

  final void Function()? onSuccessfulAuth;

  @override
  State<AuthPage> createState() => _AuthPageState();
}

class _AuthPageState extends State<AuthPage> {
  @override
  void initState() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!HarmonyOS.isCurrent &&
          SchedulerBinding.instance.lifecycleState !=
              AppLifecycleState.paused) {
        auth();
      }
    });
    super.initState();
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, result) {
        if (!didPop) {
          SystemNavigator.pop();
        }
      },
      child: Material(
        child: SafeArea(
          child: Center(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(24),
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 480),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(Icons.security, size: 36),
                    const SizedBox(height: 16),
                    Text("Authentication Required".tl),
                    if (HarmonyOS.isCurrent)
                      Padding(
                        padding: const EdgeInsets.only(top: 16),
                        child: Text(
                          'Biometric app lock is not supported in this HarmonyOS experiment. '
                                  'Continue without app authentication, or exit. You can turn off '
                                  'the imported app-lock setting in Settings.'
                              .tl,
                          textAlign: TextAlign.center,
                        ),
                      ),
                    const SizedBox(height: 16),
                    FilledButton(onPressed: auth, child: Text("Continue".tl)),
                    if (HarmonyOS.isCurrent)
                      TextButton(
                        onPressed: SystemNavigator.pop,
                        child: Text("Exit".tl),
                      ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  void auth() async {
    if (HarmonyOS.isCurrent) {
      widget.onSuccessfulAuth?.call();
      return;
    }
    var localAuth = LocalAuthentication();
    var canCheckBiometrics = await localAuth.canCheckBiometrics;
    if (!canCheckBiometrics && !await localAuth.isDeviceSupported()) {
      widget.onSuccessfulAuth?.call();
      return;
    }
    var isAuthorized = await localAuth.authenticate(
      localizedReason: "Please authenticate to continue".tl,
    );
    if (isAuthorized) {
      widget.onSuccessfulAuth?.call();
    }
  }
}
