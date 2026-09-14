import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../domain/sign_in_errors.dart';

class LoginPage extends StatefulWidget {
  const LoginPage({required this.onLogin, this.initialError, super.key});

  final Future<void> Function(String username, String password) onLogin;
  final String? initialError;

  @override
  State<LoginPage> createState() => _LoginPageState();
}

class _LoginPageState extends State<LoginPage> {
  final _formKey = GlobalKey<FormState>();
  final _usernameController = TextEditingController();
  final _passwordController = TextEditingController();
  final _passwordFocusNode = FocusNode();
  bool _obscurePassword = true;
  bool _submitting = false;
  String? _errorMessage;

  @override
  void dispose() {
    _usernameController.dispose();
    _passwordController.dispose();
    _passwordFocusNode.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (_submitting || !_formKey.currentState!.validate()) {
      return;
    }
    setState(() {
      _submitting = true;
      _errorMessage = null;
    });
    try {
      await widget.onLogin(
        _usernameController.text.trim(),
        _passwordController.text,
      );
    } catch (error) {
      if (mounted) {
        setState(
          () => _errorMessage = error is SignInError
              ? error.userMessage
              : const SignInError(SignInErrorKind.localStorage).userMessage,
        );
      }
    } finally {
      if (mounted) {
        setState(() => _submitting = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    const background = Color(0xFFF1F8FF);
    final errorMessage = _errorMessage ?? widget.initialError;
    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: SystemUiOverlayStyle.dark.copyWith(
        statusBarColor: Colors.transparent,
        systemNavigationBarColor: background,
        systemNavigationBarIconBrightness: Brightness.dark,
      ),
      child: Scaffold(
        backgroundColor: background,
        body: SafeArea(
          child: LayoutBuilder(
            builder: (context, constraints) {
              return SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(24, 42, 24, 32),
                child: ConstrainedBox(
                  constraints: BoxConstraints(
                    minHeight: constraints.maxHeight - 74,
                  ),
                  child: Center(
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 460),
                      child: Form(
                        key: _formKey,
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            Center(
                              child: Container(
                                key: const ValueKey('login-brand-icon'),
                                width: 82,
                                height: 82,
                                decoration: BoxDecoration(
                                  color: const Color(0xFF2176ED),
                                  borderRadius: BorderRadius.circular(25),
                                  boxShadow: const [
                                    BoxShadow(
                                      color: Color(0x332176ED),
                                      blurRadius: 22,
                                      offset: Offset(0, 10),
                                    ),
                                  ],
                                ),
                                child: const Icon(
                                  Icons.verified_user_rounded,
                                  size: 48,
                                  color: Colors.white,
                                ),
                              ),
                            ),
                            const SizedBox(height: 24),
                            Text(
                              '签到助手',
                              textAlign: TextAlign.center,
                              style: Theme.of(context).textTheme.displayMedium
                                  ?.copyWith(
                                    color: const Color(0xFF09285D),
                                    fontWeight: FontWeight.w900,
                                    letterSpacing: 1.5,
                                  ),
                            ),
                            const SizedBox(height: 8),
                            Text(
                              '登录后开始管理你的签到计划。',
                              textAlign: TextAlign.center,
                              style: Theme.of(context).textTheme.bodyLarge
                                  ?.copyWith(
                                    color: const Color(0xFF74839A),
                                    height: 1.4,
                                  ),
                            ),
                            const SizedBox(height: 30),
                            Card(
                              key: const ValueKey('login-card'),
                              elevation: 0,
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(30),
                              ),
                              child: Padding(
                                padding: const EdgeInsets.all(22),
                                child: Column(
                                  crossAxisAlignment:
                                      CrossAxisAlignment.stretch,
                                  children: [
                                    Text(
                                      '账号',
                                      style: Theme.of(context)
                                          .textTheme
                                          .titleMedium
                                          ?.copyWith(
                                            color: const Color(0xFF0D2856),
                                            fontWeight: FontWeight.w800,
                                          ),
                                    ),
                                    const SizedBox(height: 9),
                                    TextFormField(
                                      key: const ValueKey('login-username'),
                                      controller: _usernameController,
                                      autofillHints: const [
                                        AutofillHints.username,
                                      ],
                                      textInputAction: TextInputAction.next,
                                      onFieldSubmitted: (_) =>
                                          _passwordFocusNode.requestFocus(),
                                      decoration: const InputDecoration(
                                        hintText: '请输入账号',
                                        prefixIcon: Icon(
                                          Icons.person_outline_rounded,
                                        ),
                                        contentPadding: EdgeInsets.symmetric(
                                          vertical: 19,
                                        ),
                                      ),
                                      validator: (value) =>
                                          value == null || value.trim().isEmpty
                                          ? '请输入账号'
                                          : null,
                                    ),
                                    const SizedBox(height: 18),
                                    Text(
                                      '密码',
                                      style: Theme.of(context)
                                          .textTheme
                                          .titleMedium
                                          ?.copyWith(
                                            color: const Color(0xFF0D2856),
                                            fontWeight: FontWeight.w800,
                                          ),
                                    ),
                                    const SizedBox(height: 9),
                                    TextFormField(
                                      key: const ValueKey('login-password'),
                                      controller: _passwordController,
                                      focusNode: _passwordFocusNode,
                                      autofillHints: const [
                                        AutofillHints.password,
                                      ],
                                      textInputAction: TextInputAction.done,
                                      obscureText: _obscurePassword,
                                      onFieldSubmitted: (_) => _submit(),
                                      decoration: InputDecoration(
                                        hintText: '请输入密码',
                                        prefixIcon: const Icon(
                                          Icons.lock_outline_rounded,
                                        ),
                                        contentPadding:
                                            const EdgeInsets.symmetric(
                                              vertical: 19,
                                            ),
                                        suffixIcon: IconButton(
                                          tooltip: _obscurePassword
                                              ? '显示密码'
                                              : '隐藏密码',
                                          onPressed: () => setState(
                                            () => _obscurePassword =
                                                !_obscurePassword,
                                          ),
                                          icon: Icon(
                                            _obscurePassword
                                                ? Icons.visibility_outlined
                                                : Icons.visibility_off_outlined,
                                          ),
                                        ),
                                      ),
                                      validator: (value) =>
                                          value == null || value.isEmpty
                                          ? '请输入密码'
                                          : null,
                                    ),
                                    if (errorMessage != null) ...[
                                      const SizedBox(height: 12),
                                      Text(
                                        errorMessage,
                                        style: const TextStyle(
                                          color: Color(0xFFB42318),
                                        ),
                                      ),
                                    ],
                                    const SizedBox(height: 24),
                                    SizedBox(
                                      height: 56,
                                      child: FilledButton(
                                        onPressed: _submitting ? null : _submit,
                                        style: FilledButton.styleFrom(
                                          backgroundColor: const Color(
                                            0xFF176FE4,
                                          ),
                                          shape: RoundedRectangleBorder(
                                            borderRadius: BorderRadius.circular(
                                              17,
                                            ),
                                          ),
                                        ),
                                        child: _submitting
                                            ? const SizedBox.square(
                                                dimension: 22,
                                                child:
                                                    CircularProgressIndicator(
                                                      strokeWidth: 2.5,
                                                      color: Colors.white,
                                                    ),
                                              )
                                            : const Text(
                                                '登录',
                                                style: TextStyle(
                                                  fontSize: 18,
                                                  fontWeight: FontWeight.w800,
                                                ),
                                              ),
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              );
            },
          ),
        ),
      ),
    );
  }
}
