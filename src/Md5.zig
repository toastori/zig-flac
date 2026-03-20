const link_ossl = @import("option").link_ossl;

pub const Ctx = if (link_ossl) extern struct {
    a: c_long,
    b: c_long,
    c: c_long,
    d: c_long,
    nl: c_long,
    nh: c_long,
    data: [16]c_long,
    num: c_uint,

    pub fn update(self: *Ctx, data: []const u8) void {
        _ = MD5_Update(self, @alignCast(@ptrCast(data.ptr)), data.len);
    }

    pub fn final(self: *Ctx, dest: [*]u8) void {
        _ = MD5_Final(dest, self);
    }
} else @import("std").crypto.hash.Md5;

pub inline fn init() Ctx {
    if (link_ossl) {
        var ctx: Ctx = undefined;
        _ = MD5_Init(&ctx);
        return ctx;
    } else {
        return .init(.{});
    }
}

pub extern fn MD5_Init(c: *Ctx) c_int;
pub extern fn MD5_Update(c: *Ctx, data: *const anyopaque, len: usize) c_int;
pub extern fn MD5_Final(dest: [*]u8, c: *Ctx) c_int;
