import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';

import 'app_state.dart';
import 'domain/sign_in_errors.dart';
import 'features/home/home_page.dart';
import 'features/login/login_page.dart';
import 'features/logs/logs_page.dart';
import 'features/settings/settings_page.dart';

class SignInApp extends StatefulWidget {
  const SignInApp({this.dependencies, super.key});

  final AppDependencies? dependencies;

  @override
  State<SignInApp> createState() => _SignInAppState();
}

class _SignInAppState extends State<SignInApp> with WidgetsBindingObserver {
  late final SignInAppController _controller;
  final _messengerKey = GlobalKey<ScaffoldMessengerState>();
  late final PageController _pageController;
  int _selectedIndex = 0;
  int? _navigationTarget;
  int _navigationRequest = 0;
  bool _wasLoggedIn = false;

  @override
  void initState() {
    super.initState();
    _pageController = PageController(keepPage: false);
    _controller = SignInAppController(
      widget.dependencies ?? AppDependencies.production(),
    );
    _controller.addListener(_handleStateChanged);
    WidgetsBinding.instance.addObserver(this);
    unawaited(_initialize());
  }

  @override
  void dispose() {
    _pageController.dispose();
    WidgetsBinding.instance.removeObserver(this);
    _controller.removeListener(_handleStateChanged);
    _controller.dispose();
    super.dispose();
  }

  Future<void> _initialize() async {
    try {
      await _controller.initialize();
    } catch (_) {
      // The controller exposes a sanitized startup failure on the login page.
    }
  }

  void _handleStateChanged() {
    if (!mounted) return;
    setState(() {
      if (_wasLoggedIn && !_controller.state.isLoggedIn) {
        _selectedIndex = 0;
        _navigationTarget = null;
        _navigationRequest++;
      }
      _wasLoggedIn = _controller.state.isLoggedIn;
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _controller.refreshGreeting();
      unawaited(_refreshAfterResume());
    }
  }

  Future<void> _refreshAfterResume() async {
    await _perform(_controller.refreshLocalState);
  }

  Future<void> _perform(Future<void> Function() action) async {
    try {
      await action();
    } catch (error) {
      if (!mounted) return;
      final message = error is SignInError
          ? error.userMessage
          : const SignInError(SignInErrorKind.localStorage).userMessage;
      _messengerKey.currentState?.showSnackBar(
        SnackBar(content: Text(message)),
      );
    }
  }

  Future<void> _selectDestination(int index) async {
    if (!_pageController.hasClients) return;
    if (index == _selectedIndex && _navigationTarget == null) {
      return;
    }

    final request = ++_navigationRequest;
    setState(() {
      _selectedIndex = index;
      _navigationTarget = index;
    });

    if (WidgetsBinding
        .instance
        .platformDispatcher
        .accessibilityFeatures
        .disableAnimations) {
      _pageController.jumpToPage(index);
      if (mounted && request == _navigationRequest) {
        setState(() => _navigationTarget = null);
      }
      return;
    }
    await _pageController.animateToPage(
      index,
      duration: const Duration(milliseconds: 320),
      curve: Curves.easeOutCubic,
    );

    if (!mounted || request != _navigationRequest) {
      return;
    }
    setState(() => _navigationTarget = null);
  }

  void _handlePageChanged(int index) {
    if (_navigationTarget != null || index == _selectedIndex) {
      return;
    }
    setState(() => _selectedIndex = index);
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme =
        ColorScheme.fromSeed(
          seedColor: const Color(0xFF1F73E8),
          brightness: Brightness.light,
        ).copyWith(
          primary: const Color(0xFF176FE4),
          secondary: const Color(0xFF2F8AF6),
          surface: Colors.white,
          onSurface: const Color(0xFF10264A),
          onSurfaceVariant: const Color(0xFF66738A),
        );

    return MaterialApp(
      scaffoldMessengerKey: _messengerKey,
      title: '签到助手',
      debugShowCheckedModeBanner: false,
      locale: const Locale('zh', 'CN'),
      supportedLocales: const [Locale('zh', 'CN')],
      localizationsDelegates: GlobalMaterialLocalizations.delegates,
      theme: ThemeData(
        colorScheme: colorScheme,
        scaffoldBackgroundColor: const Color(0xFFF3F9FF),
        useMaterial3: true,
        cardTheme: const CardThemeData(
          color: Colors.white,
          elevation: 0,
          margin: EdgeInsets.zero,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.all(Radius.circular(18)),
          ),
        ),
        navigationBarTheme: NavigationBarThemeData(
          height: 72,
          backgroundColor: Colors.white,
          elevation: 6,
          shadowColor: const Color(0x1A92B9E6),
          indicatorColor: const Color(0xFFDCEBFF),
          labelTextStyle: WidgetStateProperty.resolveWith((states) {
            final selected = states.contains(WidgetState.selected);
            return TextStyle(
              fontSize: 12,
              fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
              color: selected
                  ? const Color(0xFF176FE4)
                  : const Color(0xFF66738A),
            );
          }),
        ),
        inputDecorationTheme: const InputDecorationTheme(
          filled: true,
          fillColor: Color(0xFFF7FAFF),
          border: OutlineInputBorder(
            borderRadius: BorderRadius.all(Radius.circular(18)),
            borderSide: BorderSide(color: Color(0xFFE2ECFA)),
          ),
          enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.all(Radius.circular(18)),
            borderSide: BorderSide(color: Color(0xFFE2ECFA)),
          ),
          focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.all(Radius.circular(18)),
            borderSide: BorderSide(color: Color(0xFF176FE4), width: 1.5),
          ),
        ),
      ),
      home: _controller.state.isInitializing
          ? const Scaffold(body: Center(child: CircularProgressIndicator()))
          : !_controller.state.isLoggedIn
          ? LoginPage(
              onLogin: _controller.login,
              initialError: _controller.state.errorMessage,
            )
          : _buildDashboard(),
    );
  }

  Widget _buildDashboard() {
    return Scaffold(
      body: PageView(
        controller: _pageController,
        onPageChanged: _handlePageChanged,
        physics: _navigationTarget == null
            ? const PageScrollPhysics()
            : const NeverScrollableScrollPhysics(),
        children: _buildPages(),
      ),
      bottomNavigationBar: defaultTargetPlatform == TargetPlatform.iOS
          ? CupertinoTabBar(
              currentIndex: _selectedIndex,
              onTap: _selectDestination,
              activeColor: const Color(0xFF176FE4),
              backgroundColor: Colors.white,
              items: const [
                BottomNavigationBarItem(
                  icon: Icon(CupertinoIcons.house),
                  activeIcon: Icon(CupertinoIcons.house_fill),
                  label: '首页',
                ),
                BottomNavigationBarItem(
                  icon: Icon(CupertinoIcons.doc_text),
                  activeIcon: Icon(CupertinoIcons.doc_text_fill),
                  label: '记录',
                ),
                BottomNavigationBarItem(
                  icon: Icon(CupertinoIcons.settings),
                  label: '设置',
                ),
              ],
            )
          : NavigationBar(
              selectedIndex: _selectedIndex,
              onDestinationSelected: _selectDestination,
              destinations: const [
                NavigationDestination(
                  icon: Icon(Icons.home_outlined),
                  selectedIcon: Icon(Icons.home),
                  label: '首页',
                ),
                NavigationDestination(
                  icon: Icon(Icons.receipt_long_outlined),
                  selectedIcon: Icon(Icons.receipt_long),
                  label: '记录',
                ),
                NavigationDestination(
                  icon: Icon(Icons.settings_outlined),
                  selectedIcon: Icon(Icons.settings),
                  label: '设置',
                ),
              ],
            ),
    );
  }

  List<Widget> _buildPages() => [
    HomePage(
      state: _controller.state,
      onAutoSignChanged: (value) =>
          _perform(() => _controller.setAutomationEnabled(value)),
      onSignIn: () => _perform(_controller.runManualSignIn),
      onConfirm: () => _perform(_controller.confirmUnknown),
    ),
    LogsPage(controller: _controller),
    SettingsPage(controller: _controller),
  ];
}
