//! The Arm M-profile architectures the library models, from Armv6-M to Armv8.1-M Main,
//! with the predicates for the Main Extension, Armv8-M and the DSP extension that gate
//! decode groups and behaviour elsewhere.
/// M-profile architecture variants the library models.
pub const Architecture = enum {
    armv6m,
    armv7m,
    armv7em,
    armv8m_base,
    armv8m_main,
    armv8_1m_main,

    /// Whether the architecture carries the Main Extension.
    pub fn main(self: Architecture) bool {
        return self != .armv6m and self != .armv8m_base;
    }

    /// Whether the architecture is Armv8-M or later.
    pub fn v8(self: Architecture) bool {
        return self == .armv8m_base or self == .armv8m_main or self == .armv8_1m_main;
    }

    /// Whether the architecture carries the DSP extension.
    pub fn dsp(self: Architecture) bool {
        return self == .armv7em or self == .armv8m_main or self == .armv8_1m_main;
    }
};
