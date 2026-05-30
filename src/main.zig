const std = @import("std");

// Import the C module defined in the build script
const c = @import("webcamc");

pub const WebcamError = error{
    FailedToOpen,
    CaptureTimeoutOrFailure,
    BufferTooSmall,
};

pub const Webcam = struct {
    context: *c.WebcamContext,
    width: u32,
    height: u32,

    pub fn init(device_index: u32, width: u32, height: u32) WebcamError!Webcam {
        const context = try (c.webcam_open(@intCast(device_index), @intCast(width), @intCast(height)) orelse WebcamError.FailedToOpen);
        
        return Webcam{
            .context = context,
            .width = width,
            .height = height,
        };
    }

    pub fn deinit(self: *Webcam) void {
        c.webcam_close(self.context);
    }

    pub fn readFrame(self: *Webcam, buffer: []u8) WebcamError!void {
        const expected_bytes = self.width * self.height * 4;
        if (buffer.len < expected_bytes) return WebcamError.BufferTooSmall;

        if (!c.webcam_grab_frame(self.context, buffer.ptr, @intCast(buffer.len))) {
            return WebcamError.CaptureTimeoutOrFailure;
        }

        var i: usize = 0;
        while (i < expected_bytes) : (i += 4) {
            const b = buffer[i + 0];
            const r = buffer[i + 2];
            buffer[i + 0] = r;
            buffer[i + 2] = b;
        }
    }
};