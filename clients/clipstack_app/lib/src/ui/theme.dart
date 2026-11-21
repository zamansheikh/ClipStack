import 'package:material_ui/material_ui.dart';

/// ClipStack's look, taken from the app icon: a blue → violet → purple
/// gradient on calm, slightly tinted surfaces.
abstract final class Brand {
  static const blue = Color(0xFF8AB4F8);
  static const violet = Color(0xFF7B80F2);
  static const purple = Color(0xFF9763EC);
  static const seed = Color(0xFF6E5BEA);

  static const gradient = LinearGradient(
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
    colors: [Color(0xFF7FA6F6), violet, purple],
  );

  /// The same hues, deepened for dark mode: the bright gradient glares
  /// against a dark page.
  static const darkGradient = LinearGradient(
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
    colors: [Color(0xFF2A3068), Color(0xFF332A6E), Color(0xFF40276F)],
  );

  static const success = Color(0xFF34C759);
  static const warning = Color(0xFFFF9F0A);
}

/// Surface colours used by cards and grouped lists.
extension Surfaces on BuildContext {
  bool get isDark => Theme.of(this).brightness == Brightness.dark;

  /// Gradient for hero cards and the active chip, tuned per theme.
  Gradient get heroGradient => isDark ? Brand.darkGradient : Brand.gradient;

  /// Primary button on a hero card: white on the light gradient, violet on
  /// the dark one.
  Color get heroButton => isDark ? const Color(0xFF8B7BF7) : Colors.white;
  Color get heroButtonText => isDark ? Colors.white : Brand.seed;

  /// Soft coloured glow under hero cards (much fainter in dark mode).
  List<BoxShadow> get heroShadow => [
        BoxShadow(
          color: Brand.violet.withValues(alpha: isDark ? 0.14 : 0.35),
          blurRadius: isDark ? 18 : 24,
          offset: const Offset(0, 10),
        ),
      ];

  /// Hairline that lifts the dark hero card off the page.
  Border? get heroBorder => isDark ? Border.all(color: Colors.white.withValues(alpha: 0.08)) : null;
  Color get cardColor => isDark ? const Color(0xFF1B1B25) : Colors.white;
  Color get cardBorder => isDark ? Colors.white.withValues(alpha: 0.06) : Colors.black.withValues(alpha: 0.05);
  Color get mutedText => Theme.of(this).colorScheme.onSurfaceVariant;
}

ThemeData buildTheme(Brightness brightness) {
  final dark = brightness == Brightness.dark;
  final scheme = ColorScheme.fromSeed(seedColor: Brand.seed, brightness: brightness).copyWith(
    surface: dark ? const Color(0xFF0F0F16) : const Color(0xFFF5F4FA),
  );
  final base = ThemeData(colorScheme: scheme, brightness: brightness);
  final text = base.textTheme;
  return base.copyWith(
    scaffoldBackgroundColor: scheme.surface,
    textTheme: text.copyWith(
      headlineSmall: text.headlineSmall?.copyWith(fontWeight: FontWeight.w700, letterSpacing: -0.4),
      titleLarge: text.titleLarge?.copyWith(fontWeight: FontWeight.w700, letterSpacing: -0.3),
      titleMedium: text.titleMedium?.copyWith(fontWeight: FontWeight.w600),
      titleSmall: text.titleSmall?.copyWith(fontWeight: FontWeight.w600),
    ),
    appBarTheme: AppBarTheme(
      backgroundColor: scheme.surface,
      surfaceTintColor: Colors.transparent,
      scrolledUnderElevation: 0,
      centerTitle: false,
      titleTextStyle: text.titleLarge?.copyWith(fontWeight: FontWeight.w700, color: scheme.onSurface),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        minimumSize: const Size(0, 52),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        textStyle: text.titleSmall?.copyWith(fontWeight: FontWeight.w600),
      ),
    ),
    snackBarTheme: SnackBarThemeData(
      behavior: SnackBarBehavior.floating,
      backgroundColor: dark ? const Color(0xFF2A2A36) : const Color(0xFF1F1F29),
      contentTextStyle: text.bodyMedium?.copyWith(color: Colors.white),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      elevation: 0,
    ),
    bottomSheetTheme: BottomSheetThemeData(
      backgroundColor: dark ? const Color(0xFF17171F) : Colors.white,
      surfaceTintColor: Colors.transparent,
      showDragHandle: true,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(28))),
    ),
    dialogTheme: DialogThemeData(
      backgroundColor: dark ? const Color(0xFF1B1B25) : Colors.white,
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
    ),
    dividerTheme: DividerThemeData(
      color: dark ? Colors.white.withValues(alpha: 0.06) : Colors.black.withValues(alpha: 0.06),
      thickness: 1,
      space: 1,
    ),
    listTileTheme: const ListTileThemeData(contentPadding: EdgeInsets.symmetric(horizontal: 16)),
  );
}
