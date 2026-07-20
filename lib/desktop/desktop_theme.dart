import 'package:flutter/material.dart';

/// Windows-10-flavoured desktop theme: boxy (2–4 px) corners, flat surfaces,
/// hairline borders, no glossy elevation. Deliberately squarer and denser
/// than the mobile [buildTheme] so it reads as a native desktop app rather
/// than a stretched phone screen.
///
/// The palette stays on the app's indigo brand but leans cooler and flatter.
class DesktopRadii {
  /// 2 dp — inputs, chips, small controls.
  static const double small = 2;

  /// 4 dp — cards, buttons, dialogs, tiles.
  static const double medium = 4;
}

ThemeData buildDesktopTheme({Brightness brightness = Brightness.light}) {
  final isLight = brightness == Brightness.light;
  final scheme = ColorScheme.fromSeed(
    seedColor: const Color(0xFF3949AB), // Indigo 600 — brand
    brightness: brightness,
  ).copyWith(
    // Flatten container tints so cards read as crisp panels, not blobs.
    surface: isLight ? const Color(0xFFF3F3F3) : const Color(0xFF1B1B1F),
  );

  final surfaceBg = isLight ? const Color(0xFFF3F3F3) : const Color(0xFF1B1B1F);
  final panelBg = isLight ? Colors.white : const Color(0xFF242429);
  final border = isLight ? const Color(0xFFDADADA) : const Color(0xFF3A3A40);

  RoundedRectangleBorder box([double r = DesktopRadii.medium]) =>
      RoundedRectangleBorder(borderRadius: BorderRadius.circular(r));

  return ThemeData(
    colorScheme: scheme,
    useMaterial3: true,
    scaffoldBackgroundColor: surfaceBg,
    // Denser than the phone default — desktop users expect tighter rows.
    visualDensity: VisualDensity.compact,
    appBarTheme: AppBarTheme(
      backgroundColor: panelBg,
      foregroundColor: scheme.primary,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      scrolledUnderElevation: 0,
      centerTitle: false,
      titleTextStyle: TextStyle(
        color: scheme.primary,
        fontSize: 17,
        fontWeight: FontWeight.w700,
        letterSpacing: 0.1,
      ),
      iconTheme: IconThemeData(color: scheme.primary, size: 20),
      shape: Border(bottom: BorderSide(color: border, width: 1)),
    ),
    cardTheme: CardThemeData(
      elevation: 0,
      color: panelBg,
      surfaceTintColor: Colors.transparent,
      margin: const EdgeInsets.symmetric(vertical: 4),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(DesktopRadii.medium),
        side: BorderSide(color: border),
      ),
    ),
    dividerTheme: DividerThemeData(color: border, thickness: 1, space: 1),
    inputDecorationTheme: InputDecorationTheme(
      isDense: true,
      filled: true,
      fillColor: panelBg,
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(DesktopRadii.small),
        borderSide: BorderSide(color: border),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(DesktopRadii.small),
        borderSide: BorderSide(color: border),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(DesktopRadii.small),
        borderSide: BorderSide(color: scheme.primary, width: 1.5),
      ),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        elevation: 0,
        minimumSize: const Size.fromHeight(40),
        shape: box(),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        side: BorderSide(color: border),
        shape: box(),
      ),
    ),
    elevatedButtonTheme: ElevatedButtonThemeData(
      style: ElevatedButton.styleFrom(elevation: 0, shape: box()),
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(shape: box()),
    ),
    dialogTheme: DialogThemeData(
      backgroundColor: panelBg,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(DesktopRadii.medium),
        side: BorderSide(color: border),
      ),
    ),
    bottomSheetTheme: BottomSheetThemeData(
      backgroundColor: panelBg,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(
          top: Radius.circular(DesktopRadii.medium),
        ),
      ),
    ),
    snackBarTheme: SnackBarThemeData(
      behavior: SnackBarBehavior.floating,
      shape: box(DesktopRadii.small),
    ),
    listTileTheme: const ListTileThemeData(
      dense: true,
      visualDensity: VisualDensity.compact,
    ),
    navigationRailTheme: NavigationRailThemeData(
      backgroundColor: panelBg,
      indicatorColor: scheme.primary.withValues(alpha: 0.14),
      indicatorShape: box(),
      selectedIconTheme: IconThemeData(color: scheme.primary),
      unselectedIconTheme: IconThemeData(color: scheme.onSurfaceVariant),
      selectedLabelTextStyle: TextStyle(
        color: scheme.primary,
        fontWeight: FontWeight.w600,
        fontSize: 13,
      ),
      unselectedLabelTextStyle: TextStyle(
        color: scheme.onSurfaceVariant,
        fontSize: 13,
      ),
    ),
    floatingActionButtonTheme: FloatingActionButtonThemeData(
      elevation: 1,
      shape: box(),
    ),
    chipTheme: ChipThemeData(shape: box(DesktopRadii.small)),
    segmentedButtonTheme: SegmentedButtonThemeData(
      style: ButtonStyle(shape: WidgetStatePropertyAll(box(DesktopRadii.small))),
    ),
  );
}
