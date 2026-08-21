pub const Channel = enum(u8) {
    l_s = 8,
    s_r = 9,
    m_s = 10,
    _, // actual - 1

    pub fn indep(channels: u8) Channel {
        return switch (channels) {
            1...8 => @enumFromInt(channels - 1),
            else => unreachable,
        };
    }

    pub fn get_indep(channel: Channel) u4 {
        return switch (@intFromEnum(channel)) {
            0...7 => |ch| ch + 1,
            else => unreachable,
        };
    }

    pub fn get_int(channel: Channel) u4 {
        return switch (@intFromEnum(channel)) {
            0...10 => |ch| @intCast(ch),
            else => unreachable,
        };
    }
};

pub const SampleVariant = enum {
    normal,
    wide,

    pub fn T(self: SampleVariant) type {
        return switch (self) {
            .normal => i32,
            .wide => i64,
        };
    }

    pub fn UT(self: SampleVariant) type {
        return switch (self) {
            .normal => u32,
            .wide => u64,
        };
    }
};
