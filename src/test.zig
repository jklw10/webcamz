const std = @import("std");
const webcam = @import("webcamz");

pub fn main() !void {
    std.debug.print("Initializing camera device 0...\n", .{});
    
    var camera = webcam.Webcam.init(0, 640, 480) catch |err| {
        std.debug.print("Could not open camera: {any}\n", .{err});
        return;
    };
    defer camera.deinit();

    std.debug.print("Webcam successfully initialized!\n", .{});

    const allocator = std.heap.page_allocator;
    const frame_buffer = try allocator.alloc(u8, 640 * 480 * 4);
    defer allocator.free(frame_buffer);

    std.debug.print("Grabbing a single frame...\n", .{});
    camera.readFrame(frame_buffer) catch |err| {
        std.debug.print("Frame grab failed (expected if no physical camera is connected): {any}\n", .{err});
        return;
    };

    std.debug.print("Successfully captured a frame!\n", .{});
    std.debug.print("RGBA Sample: ({}, {}, {}, {})\n", .{
        frame_buffer[0],
        frame_buffer[1],
        frame_buffer[2],
        frame_buffer[3],
    });
}