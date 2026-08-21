const link_ossl = @import("option").link_ossl;

pub const Md5 = if (link_ossl) extern struct {
    a: c_long,
    b: c_long,
    c: c_long,
    d: c_long,
    nl: c_long,
    nh: c_long,
    data: [16]c_long,
    num: c_uint,

    pub const digest_length = 16;
    pub const Options = struct {};

    pub fn init(options: Options) Md5 {
        _ = options;

        var ctx: Md5 = undefined;
        _ = MD5_Init(&ctx);
        return ctx;
    }

    pub fn update(self: *Md5, data: []const u8) void {
        _ = MD5_Update(self, @alignCast(@ptrCast(data.ptr)), data.len);
    }

    pub fn final(self: *Md5, dest: *[digest_length]u8) void {
        _ = MD5_Final(dest, self);
    }
} else @import("std").crypto.hash.Md5;

pub extern "crypto" fn MD5_Init(c: *Md5) c_int;
pub extern "crypto" fn MD5_Update(c: *Md5, data: *const anyopaque, len: usize) c_int;
pub extern "crypto" fn MD5_Final(dest: [*]u8, c: *Md5) c_int;
