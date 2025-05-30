// -- Private import --
const sample_iter = @import("sample_iter.zig");

// -- Package --

pub const metadata = @import("metadata.zig");

// -- Types --
pub const Encoder = @import("FlacEncoder.zig");
pub const FrameWriter = @import("FrameWriter.zig");

pub const SampleIter = sample_iter.SampleIter;
pub const MultiChannelIter = sample_iter.MultiChannelIter;
pub const SingleChannelIter = sample_iter.SingleChannelIter;
