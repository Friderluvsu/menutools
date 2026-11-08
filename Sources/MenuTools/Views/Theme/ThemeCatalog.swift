import SwiftUI

/// The themes besides Classic. Minimal: Graphite, Obsidian. Professional: Midnight, Carbon, Neon.
/// Cozy: Dusk. Playful: Cosmos. All dark.
extension AppTheme {
    static let graphite = AppTheme(
        id: .graphite,
        name: "Graphite",
        tagline: "Quiet grey, nothing extra",
        symbol: "circle.lefthalf.filled",
        appearance: .darkAqua,
        accent: Color(hex: 0x9AA8BA),
        usesMaterial: false,
        backdrop: [Color(hex: 0x1C1C1E), Color(hex: 0x161618)],
        cardFill: Color(hex: 0x232326).opacity(0.92),
        cardStroke: Color.white.opacity(0.07),
        controlFill: Color.white.opacity(0.05),
        tileFill: Color.white.opacity(0.04),
        hoverFill: Color.white.opacity(0.07),
        panelStroke: Color.white.opacity(0.14),
        cornerScale: 0.8,
        charts: ChartPalette(
            cpu: Color(hex: 0xD9828C), gpu: Color(hex: 0xA895D9), memory: Color(hex: 0x7FA7D9),
            temperature: Color(hex: 0xD9A066), down: Color(hex: 0x7FA7D9), up: Color(hex: 0xD9828C),
            disk: Color(hex: 0xC9B27A), fan: Color(hex: 0x7CC4B5),
            system: Color(hex: 0xD9828C), user: Color(hex: 0x7FA7D9), performance: Color(hex: 0xA895D9),
            efficiency: Color(hex: 0x7CC4B5), lineWidth: 1.2, fillOpacity: 0.12),
        swatch: [Color(hex: 0x1C1C1E), Color(hex: 0x3A3A3E), Color(hex: 0x9AA8BA)]
    )

    static let obsidian = AppTheme(
        id: .obsidian,
        name: "Obsidian",
        tagline: "True black, hairlines",
        symbol: "circle.fill",
        appearance: .darkAqua,
        accent: Color(hex: 0x4C8DFF),
        title: "menutools",
        titleTracking: 1.2,
        usesMaterial: false,
        backdrop: [Color.black, Color(hex: 0x050505)],
        cardFill: Color(hex: 0x0B0B0C),
        cardStroke: Color.white.opacity(0.11),
        controlFill: Color.white.opacity(0.04),
        tileFill: Color.white.opacity(0.03),
        hoverFill: Color.white.opacity(0.06),
        panelStroke: Color.white.opacity(0.18),
        strokeWidth: 0.5,
        cornerScale: 0.6,
        charts: ChartPalette(
            cpu: Color(hex: 0x4C8DFF), gpu: Color(white: 0.78), memory: Color(white: 0.92),
            temperature: Color(white: 0.7), down: Color(hex: 0x4C8DFF), up: Color(white: 0.85),
            disk: Color(white: 0.75), fan: Color(white: 0.65),
            system: Color(white: 0.9), user: Color(hex: 0x4C8DFF), performance: Color(white: 0.7),
            efficiency: Color(white: 0.5), lineWidth: 1, fillOpacity: 0.08),
        swatch: [Color.black, Color(white: 0.85), Color(hex: 0x4C8DFF)]
    )

    static let midnight = AppTheme(
        id: .midnight,
        name: "Midnight",
        tagline: "Deep navy, calm blue",
        symbol: "moon.stars.fill",
        appearance: .darkAqua,
        accent: Color(hex: 0x6C8EEF),
        usesMaterial: false,
        backdrop: [Color(hex: 0x111A2E), Color(hex: 0x0B1220)],
        texture: .nightSky,
        cardFill: Color(hex: 0x16213A).opacity(0.82),
        cardStroke: Color(hex: 0x6C8EEF).opacity(0.16),
        controlFill: Color(hex: 0x6C8EEF).opacity(0.07),
        tileFill: Color(hex: 0x6C8EEF).opacity(0.06),
        hoverFill: Color(hex: 0x6C8EEF).opacity(0.1),
        panelStroke: Color(hex: 0x6C8EEF).opacity(0.3),
        charts: ChartPalette(
            cpu: Color(hex: 0xF07A8A), gpu: Color(hex: 0xA78BFA), memory: Color(hex: 0x6C8EEF),
            temperature: Color(hex: 0xF5A962), down: Color(hex: 0x5BC0EB), up: Color(hex: 0xF07A8A),
            disk: Color(hex: 0xE9C46A), fan: Color(hex: 0x4FD1C5),
            system: Color(hex: 0xF07A8A), user: Color(hex: 0x6C8EEF), performance: Color(hex: 0xA78BFA),
            efficiency: Color(hex: 0x4FD1C5), lineWidth: 1.4, fillOpacity: 0.16),
        swatch: [Color(hex: 0x111A2E), Color(hex: 0x6C8EEF), Color(hex: 0xF5A962)]
    )

    static let carbon = AppTheme(
        id: .carbon,
        name: "Carbon",
        tagline: "Square, precise, enterprise",
        symbol: "square.grid.3x3.fill",
        appearance: .darkAqua,
        accent: Color(hex: 0x4589FF),
        usesMaterial: false,
        backdrop: [Color(hex: 0x161616), Color(hex: 0x121212)],
        cardFill: Color(hex: 0x1E1E1E),
        cardStroke: Color(hex: 0x393939),
        controlFill: Color(hex: 0x262626),
        tileFill: Color(hex: 0x262626).opacity(0.8),
        hoverFill: Color(hex: 0x353535).opacity(0.7),
        panelStroke: Color(hex: 0x4589FF).opacity(0.45),
        cornerScale: 0,
        charts: ChartPalette(
            cpu: Color(hex: 0xFF7EB6), gpu: Color(hex: 0xBE95FF), memory: Color(hex: 0x4589FF),
            temperature: Color(hex: 0xFF832B), down: Color(hex: 0x33B1FF), up: Color(hex: 0xFA4D56),
            disk: Color(hex: 0xF1C21B), fan: Color(hex: 0x08BDBA),
            system: Color(hex: 0xFA4D56), user: Color(hex: 0x4589FF), performance: Color(hex: 0xBE95FF),
            efficiency: Color(hex: 0x08BDBA), lineWidth: 1.25, fillOpacity: 0.14),
        swatch: [Color(hex: 0x161616), Color(hex: 0x393939), Color(hex: 0x4589FF)]
    )

    static let neon = AppTheme(
        id: .neon,
        name: "Neon",
        tagline: "Night office, soft neon edge",
        symbol: "lightbulb.max.fill",
        appearance: .darkAqua,
        accent: Color(hex: 0x00E1FF),
        titleTracking: 0.8,
        usesMaterial: false,
        backdrop: [Color(hex: 0x0C0D14), Color(hex: 0x0A0A10)],
        texture: .neonEdge,
        cardFill: Color(hex: 0x12131C).opacity(0.92),
        cardStroke: Color(hex: 0x00E1FF).opacity(0.22),
        controlFill: Color(hex: 0x00E1FF).opacity(0.05),
        tileFill: Color.white.opacity(0.035),
        hoverFill: Color(hex: 0x00E1FF).opacity(0.09),
        panelStroke: Color(hex: 0xFF2BD6).opacity(0.45),
        glow: Color(hex: 0x00E1FF).opacity(0.14),
        charts: ChartPalette(
            cpu: Color(hex: 0xFF2BD6), gpu: Color(hex: 0x9D7BFF), memory: Color(hex: 0x00E1FF),
            temperature: Color(hex: 0xFF9F43), down: Color(hex: 0x00E1FF), up: Color(hex: 0xFF2BD6),
            disk: Color(hex: 0xFFE066), fan: Color(hex: 0x3DFFB0),
            system: Color(hex: 0xFF2BD6), user: Color(hex: 0x00E1FF), performance: Color(hex: 0x9D7BFF),
            efficiency: Color(hex: 0x3DFFB0), lineWidth: 1.5, fillOpacity: 0.16),
        swatch: [Color(hex: 0x0C0D14), Color(hex: 0xFF2BD6), Color(hex: 0x00E1FF)]
    )

    static let dusk = AppTheme(
        id: .dusk,
        name: "Dusk",
        tagline: "Indigo evening, city lights",
        symbol: "building.2.fill",
        appearance: .darkAqua,
        fontDesign: .rounded,
        accent: Color(hex: 0xA9A1E6),
        usesMaterial: false,
        backdrop: [Color(hex: 0x1C1D33), Color(hex: 0x15162A), Color(hex: 0x1E1930)],
        texture: .skyline,
        cardFill: Color(hex: 0x222338).opacity(0.84),
        cardStroke: Color(hex: 0xA9A1E6).opacity(0.16),
        controlFill: Color(hex: 0xA9A1E6).opacity(0.07),
        tileFill: Color(hex: 0xA9A1E6).opacity(0.055),
        hoverFill: Color(hex: 0xA9A1E6).opacity(0.1),
        panelStroke: Color(hex: 0xA9A1E6).opacity(0.28),
        cornerScale: 1.15,
        charts: ChartPalette(
            cpu: Color(hex: 0xF7768E), gpu: Color(hex: 0xBB9AF7), memory: Color(hex: 0x7AA2F7),
            temperature: Color(hex: 0xFF9E64), down: Color(hex: 0x7DCFFF), up: Color(hex: 0xF7768E),
            disk: Color(hex: 0xE0AF68), fan: Color(hex: 0x73DACA),
            system: Color(hex: 0xF7768E), user: Color(hex: 0x7AA2F7), performance: Color(hex: 0xBB9AF7),
            efficiency: Color(hex: 0x73DACA), lineWidth: 1.5, fillOpacity: 0.18),
        swatch: [Color(hex: 0x1C1D33), Color(hex: 0x7AA2F7), Color(hex: 0xA9A1E6)]
    )

    static let cosmos = AppTheme(
        id: .cosmos,
        name: "Cosmos",
        tagline: "Nebulae and ringed planets",
        symbol: "globe.americas.fill",
        appearance: .darkAqua,
        fontDesign: .rounded,
        accent: Color(hex: 0xFFB4E6),
        usesMaterial: false,
        backdrop: [Color(hex: 0x0B0620), Color(hex: 0x150A33), Color(hex: 0x0A0A24)],
        texture: .nebula,
        cardFill: Color(hex: 0x1A1038).opacity(0.62),
        cardStroke: Color(hex: 0xFFB4E6).opacity(0.2),
        controlFill: Color(hex: 0x9C8CFF).opacity(0.08),
        tileFill: Color(hex: 0x9C8CFF).opacity(0.06),
        hoverFill: Color(hex: 0xFFB4E6).opacity(0.1),
        panelStroke: Color(hex: 0x9C8CFF).opacity(0.45),
        cornerScale: 1.25,
        glow: Color(hex: 0x9C8CFF).opacity(0.18),
        charts: ChartPalette(
            cpu: Color(hex: 0xFFB4E6), gpu: Color(hex: 0x9C8CFF), memory: Color(hex: 0x7CC8FF),
            temperature: Color(hex: 0xFFC27A), down: Color(hex: 0x7CC8FF), up: Color(hex: 0xFFB4E6),
            disk: Color(hex: 0xFFE38A), fan: Color(hex: 0x7CFFD4),
            system: Color(hex: 0xFFB4E6), user: Color(hex: 0x7CC8FF), performance: Color(hex: 0x9C8CFF),
            efficiency: Color(hex: 0x7CFFD4), lineWidth: 1.6, fillOpacity: 0.22),
        swatch: [Color(hex: 0x150A33), Color(hex: 0x9C8CFF), Color(hex: 0xFFB4E6)]
    )
}
