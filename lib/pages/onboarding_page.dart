import 'package:common_ui/common_ui.dart';
// ignore_for_file: deprecated_member_use
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:app_icons/app_icons.dart';

import '../l10n/s.dart';
import '../services/deep_link_service.dart';
import '../widgets/common/ambient_background.dart';
import '../widgets/common/floating_logo.dart';
import 'login_page.dart';
import 'network_settings_page/network_settings_page.dart';

class OnboardingPage extends StatefulWidget {
  final VoidCallback onComplete;

  const OnboardingPage({super.key, required this.onComplete});

  @override
  State<OnboardingPage> createState() => _OnboardingPageState();
}

class _OnboardingPageState extends State<OnboardingPage>
    with TickerProviderStateMixin {
  late AnimationController _entryAnimationController;
  final List<Animation<double>> _fadeAnimations = [];
  final List<Animation<Offset>> _slideAnimations = [];

  @override
  void initState() {
    super.initState();
    _setupEntryAnimations();
    // 初始化 Deep Link 服务以处理邮箱链接登录
    WidgetsBinding.instance.addPostFrameCallback((_) {
      DeepLinkService.instance.onEmailLoginSuccess = () {
        if (mounted) widget.onComplete();
      };
      DeepLinkService.instance.initialize(context);
    });
  }

  void _setupEntryAnimations() {
    _entryAnimationController = AnimationController(
      vsync: this,
      duration: const Duration(
        milliseconds: 1500,
      ), // Slightly slower for elegance
    );

    // Staggered animations
    for (int i = 0; i < 5; i++) {
      final start = i * 0.12;
      final end = start + 0.6;

      _fadeAnimations.add(
        Tween<double>(begin: 0.0, end: 1.0).animate(
          CurvedAnimation(
            parent: _entryAnimationController,
            curve: Interval(
              start,
              end > 1.0 ? 1.0 : end,
              curve: Curves.easeOut,
            ),
          ),
        ),
      );

      _slideAnimations.add(
        Tween<Offset>(begin: const Offset(0, 0.15), end: Offset.zero).animate(
          CurvedAnimation(
            parent: _entryAnimationController,
            curve: Interval(
              start,
              end > 1.0 ? 1.0 : end,
              curve: Curves.easeOutCubic,
            ),
          ),
        ),
      );
    }

    _entryAnimationController.forward();
  }

  @override
  void dispose() {
    DeepLinkService.instance.onEmailLoginSuccess = null;
    _entryAnimationController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Stack(
        children: [
          // 1. Ambient Background (Aurora Effect)
          const AmbientBackground(),

          // 2. Content
          SafeArea(
            child: Stack(
              children: [
                _buildNetworkButton(context),
                _buildMainContent(context),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildNetworkButton(BuildContext context) {
    return Positioned(
      top: 16,
      right: 16,
      child: FadeTransition(
        opacity: _fadeAnimations[0],
        child: AmbientIconButton(
          icon: Symbols.network_check_rounded,
          tooltip: context.l10n.onboarding_networkSettings,
          onPressed: () => Navigator.push(
            context,
            InteractionPageRoute(builder: (_) => const NetworkSettingsPage()),
          ),
        ),
      ),
    );
  }

  Widget _buildMainContent(BuildContext context) {
    final theme = Theme.of(context);

    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 40),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Spacer(flex: 3),

            // Logo - Floating without background
            _AnimatedEntry(
              fadeAnimation: _fadeAnimations[0],
              slideAnimation: _slideAnimations[0],
              child: const FloatingLogo(),
            ),

            const SizedBox(height: 48),

            // Title - Clean and Premium
            _AnimatedEntry(
              fadeAnimation: _fadeAnimations[1],
              slideAnimation: _slideAnimations[1],
              child: Text(
                'FluxDO',
                style: theme.textTheme.displayMedium?.copyWith(
                  fontWeight: FontWeight.w900,
                  letterSpacing: -1.5,
                  color: theme.colorScheme.onSurface,
                  height: 1.0,
                ),
              ),
            ),

            const SizedBox(height: 16),

            // Slogan - Elegant Typography
            _AnimatedEntry(
              fadeAnimation: _fadeAnimations[2],
              slideAnimation: _slideAnimations[2],
              child: Text(
                context.l10n.onboarding_slogan,
                textAlign: TextAlign.center,
                style: theme.textTheme.titleMedium?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant.withValues(
                    alpha: 0.8,
                  ),
                  letterSpacing: 2.0,
                  fontWeight: FontWeight.w400,
                  height: 1.5,
                ),
              ),
            ),

            const Spacer(flex: 4),

            // Login Button - Modern Pill Shape
            _AnimatedEntry(
              fadeAnimation: _fadeAnimations[3],
              slideAnimation: _slideAnimations[3],
              child: FilledButton(
                onPressed: () => _navigateToLogin(context),
                style:
                    FilledButton.styleFrom(
                      minimumSize: const Size(double.infinity, 56),
                      shape: RoundedSuperellipseBorder(
                        borderRadius: BorderRadius.circular(28),
                      ),
                      elevation: 0,
                      backgroundColor: theme.colorScheme.primary,
                      foregroundColor: theme.colorScheme.onPrimary,
                    ).copyWith(
                      shadowColor: MaterialStateProperty.all(
                        theme.colorScheme.primary.withValues(alpha: 0.4),
                      ),
                      elevation: MaterialStateProperty.resolveWith((states) {
                        if (states.contains(MaterialState.pressed)) return 2;
                        return 8; // Soft glow shadow
                      }),
                    ),
                child: Text(
                  context.l10n.common_login,
                  style: const TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.w500,
                    letterSpacing: 1.0,
                  ),
                ),
              ),
            ),

            const SizedBox(height: 20),

            // Guest Button - Subtle
            _AnimatedEntry(
              fadeAnimation: _fadeAnimations[4],
              slideAnimation: _slideAnimations[4],
              child: TextButton(
                onPressed: () => _continueAsGuest(context),
                style: TextButton.styleFrom(
                  minimumSize: const Size(double.infinity, 56),
                  shape: RoundedSuperellipseBorder(
                    borderRadius: BorderRadius.circular(28),
                  ),
                  foregroundColor: theme.colorScheme.onSurfaceVariant,
                ),
                child: Text(
                  context.l10n.onboarding_guestAccess,
                  style: const TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w500,
                    letterSpacing: 0.5,
                  ),
                ),
              ),
            ),

            const Spacer(),
          ],
        ),
      ),
    );
  }

  Future<void> _navigateToLogin(BuildContext context) async {
    final result = await Navigator.push<bool>(
      context,
      InteractionPageRoute(builder: (_) => const LoginPage()),
    );

    if (result == true && context.mounted) {
      widget.onComplete();
    }
  }

  void _continueAsGuest(BuildContext context) {
    widget.onComplete();
  }
}

class _AnimatedEntry extends StatelessWidget {
  final Animation<double> fadeAnimation;
  final Animation<Offset> slideAnimation;
  final Widget child;

  const _AnimatedEntry({
    required this.fadeAnimation,
    required this.slideAnimation,
    required this.child,
  });

  @override
  Widget build(BuildContext context) {
    return FadeTransition(
      opacity: fadeAnimation,
      child: SlideTransition(position: slideAnimation, child: child),
    );
  }
}
