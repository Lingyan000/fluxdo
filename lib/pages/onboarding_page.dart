// ignore_for_file: deprecated_member_use
import 'package:flutter/material.dart';
import 'package:jovial_svg/jovial_svg.dart';
import 'dart:async';
import 'dart:math' as math;
import '../l10n/s.dart';
import '../services/deep_link_service.dart';
import 'webview_login_page.dart';
import 'network_settings_page/network_settings_page.dart';

class OnboardingPage extends StatefulWidget {
  final VoidCallback onComplete;

  const OnboardingPage({super.key, required this.onComplete});

  @override
  State<OnboardingPage> createState() => _OnboardingPageState();
}

class _OnboardingPageState extends State<OnboardingPage> with TickerProviderStateMixin {
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
      duration: const Duration(milliseconds: 1500), // Slightly slower for elegance
    );

    // Staggered animations
    for (int i = 0; i < 5; i++) {
      final start = i * 0.12;
      final end = start + 0.6;
      
      _fadeAnimations.add(
        Tween<double>(begin: 0.0, end: 1.0).animate(
          CurvedAnimation(
            parent: _entryAnimationController,
            curve: Interval(start, end > 1.0 ? 1.0 : end, curve: Curves.easeOut),
          ),
        ),
      );

      _slideAnimations.add(
        Tween<Offset>(begin: const Offset(0, 0.15), end: Offset.zero).animate(
          CurvedAnimation(
            parent: _entryAnimationController,
            curve: Interval(start, end > 1.0 ? 1.0 : end, curve: Curves.easeOutCubic),
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
          const _AmbientBackground(),
          
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
        child: IconButton(
          icon: const Icon(Icons.network_check_rounded),
          tooltip: context.l10n.onboarding_networkSettings,
          style: IconButton.styleFrom(
            backgroundColor: Theme.of(context).colorScheme.surface.withValues(alpha:0.3),
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
          ),
          onPressed: () => Navigator.push(
            context,
            MaterialPageRoute(builder: (_) => const NetworkSettingsPage()),
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
              child: const _FloatingLogo(),
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
                  color: theme.colorScheme.onSurfaceVariant.withValues(alpha:0.8),
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
                style: FilledButton.styleFrom(
                  minimumSize: const Size(double.infinity, 56),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(28),
                  ),
                  elevation: 0,
                  backgroundColor: theme.colorScheme.primary,
                  foregroundColor: theme.colorScheme.onPrimary,
                ).copyWith(
                  shadowColor: MaterialStateProperty.all(
                    theme.colorScheme.primary.withValues(alpha:0.4),
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
                  shape: RoundedRectangleBorder(
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
      MaterialPageRoute(builder: (_) => const WebViewLoginPage()),
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
      child: SlideTransition(
        position: slideAnimation,
        child: child,
      ),
    );
  }
}

class _FloatingLogo extends StatefulWidget {
  const _FloatingLogo();

  @override
  State<_FloatingLogo> createState() => _FloatingLogoState();
}

class _FloatingLogoState extends State<_FloatingLogo> with SingleTickerProviderStateMixin {
  late AnimationController _controller;
  late Animation<double> _animation;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      duration: const Duration(seconds: 4), // Slower, deeper breath
      vsync: this,
    )..repeat(reverse: true);

    _animation = Tween<double>(begin: -10.0, end: 10.0).animate(
      CurvedAnimation(parent: _controller, curve: Curves.easeInOutSine),
    );
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;

    return AnimatedBuilder(
      animation: _animation,
      builder: (context, child) {
        return Transform.translate(
          offset: Offset(0, _animation.value),
          child: child,
        );
      },
      child: Stack(
        alignment: Alignment.center,
        children: [
          // Glow effect behind logo
          Container(
            width: 100,
            height: 100,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              boxShadow: [
                BoxShadow(
                  color: isDark 
                      ? theme.colorScheme.primary.withValues(alpha:0.3)
                      : theme.colorScheme.primary.withValues(alpha:0.2),
                  blurRadius: 60,
                  spreadRadius: 20,
                ),
              ],
            ),
          ),
          SizedBox(
            width: 120,
            height: 120,
            child: ScalableImageWidget.fromSISource(
              si: ScalableImageSource.fromSvg(
                DefaultAssetBundle.of(context),
                'assets/logo.svg',
                warnF: (_) {},
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _AmbientBackground extends StatefulWidget {
  const _AmbientBackground();

  @override
  State<_AmbientBackground> createState() => _AmbientBackgroundState();
}

class _AmbientBackgroundState extends State<_AmbientBackground> with SingleTickerProviderStateMixin {
  // Simple rotation for the blobs
  late AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 20),
    )..repeat();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    
    // Define ambient colors
    final primary = theme.colorScheme.primary;
    final secondary = theme.colorScheme.secondary;
    final surface = theme.colorScheme.surface;

    return Container(
      color: surface, // Base background
      child: Stack(
        children: [
          // Top Left Blob
          Positioned(
            top: -100,
            left: -100,
            child: _AnimatedBlob(
              color: primary.withValues(alpha:isDark ? 0.15 : 0.08),
              size: 400,
              controller: _controller,
              offset: 0,
            ),
          ),
          
          // Bottom Right Blob
          Positioned(
            bottom: -100,
            right: -100,
            child: _AnimatedBlob(
              color: secondary.withValues(alpha:isDark ? 0.15 : 0.08),
              size: 350,
              controller: _controller,
              offset: math.pi, // Opposite phase
            ),
          ),
          
          // Noise/Texture overlay (Optional - using simple opacity layer for depth)
          if (isDark)
            Positioned.fill(
              child: Container(
                color: Colors.black.withValues(alpha:0.2),
              ),
            ),
        ],
      ),
    );
  }
}

class _AnimatedBlob extends StatelessWidget {
  final Color color;
  final double size;
  final AnimationController controller;
  final double offset;

  const _AnimatedBlob({
    required this.color,
    required this.size,
    required this.controller,
    required this.offset,
  });

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: controller,
      builder: (context, child) {
        // Subtle movement in a circle
        final angle = controller.value * 2 * math.pi + offset;
        final x = 30 * math.cos(angle);
        final y = 30 * math.sin(angle);
        
        return Transform.translate(
          offset: Offset(x, y),
          child: Container(
            width: size,
            height: size,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: color,
              boxShadow: [
                BoxShadow(
                  color: color,
                  blurRadius: 100,
                  spreadRadius: 50,
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}
