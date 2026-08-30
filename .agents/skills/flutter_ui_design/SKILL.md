---
name: flutter_ui_design
description: Guidelines and best practices for creating premium, responsive UI in Flutter
---

# Flutter UI Design Best Practices (2026 Standard)

When designing or modifying the Flutter UI for this project, adhere to the following best practices to ensure a premium, performant, and modern user experience.

## 1. Material 3 (M3) Adoption
*   **Enable M3**: Always ensure `useMaterial3: true` in your `ThemeData`. This utilizes the latest color systems, typography, and shape language.
*   **Semantic Tokens**: Use M3's semantic color tokens (e.g., `colorScheme.primary`, `colorScheme.surfaceVariant`) to ensure seamless transitions between Light and Dark modes. Do not hardcode raw hex colors unless implementing a strict custom branding rule.
*   **Adaptive Layouts**: Do not design exclusively for mobile. Utilize `LayoutBuilder` and adaptive packages so that layouts scale beautifully to foldables, tablets, and desktops.

## 2. Liquid Glass & Glassmorphism
*   **Implementation**: Use Flutter’s built-in `BackdropFilter` with `ImageFilter.blur()` to create elegant frosted-glass effects (Liquid Glass). 
*   **Performance Constraints**: Blurring is computationally expensive. **Do NOT nest multiple glassmorphic elements** or rapidly animate the blur radius, as this causes dropped frames.
*   **Context**: Glassmorphism is only effective against colorful, dynamic, or textured backgrounds. Do not use it over solid flat colors like black or white.

## 3. High-Fidelity Animations
*   **Perceived Performance**: Animations must provide immediate visual feedback for user interactions. Use subtle micro-animations for buttons and cards.
*   **Engine Capabilities**: Leverage the Impeller rendering engine (default on iOS and Android) for jank-free 120fps animations.
*   **Optimization Strategies**:
    *   Use `FadeTransition` instead of the `Opacity` widget when animating opacity.
    *   Wrap highly complex animating subtrees in a `RepaintBoundary` to prevent full widget tree repaints.
    *   Animate `Transform` (for scaling/translating) or Opacity rather than properties that trigger layout passes (like `width` or `height`).
*   **Rive**: For extremely complex, state-driven animations, prefer integrating exported Rive assets to minimize Dart boilerplate and improve performance.

## 4. Typography and Aesthetics
*   **Fonts**: Avoid default fonts if possible. Use curated, modern typography like Inter, Roboto, or Outfit from Google Fonts. 
*   **Hierarchy**: Ensure strong typographic hierarchy. Use `textTheme.headlineLarge` for main page titles and `textTheme.bodyMedium` for standard text.
*   **Vibrancy**: Avoid generic, flat colors. Create visually stunning UIs that feel alive and responsive, emphasizing user engagement.
