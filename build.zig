const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // 1. Translate the C header into a Zig module (deprecating @cImport)
    const translate_c = b.addTranslateC(.{
        .root_source_file = b.path("src/c_api.h"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    const c_mod = translate_c.createModule();

    // 2. Define the main high-level Zig module
    const webcam_module = b.addModule("webcam", .{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = &.{
            .{ .name = "webcamc", .module = c_mod },
        },
    });

    // 3. Create the native platform library backend
    const lib = b.addLibrary(.{
        .linkage = .static,
        .name = "webcam_backend",
        .root_module = b.createModule(.{
            .target = target,
            .optimize = optimize,
        }),
    });
    lib.root_module.link_libc = true;
    
    // Route include paths through the root_module
    lib.root_module.addIncludePath(b.path("src"));

    const os = target.result.os.tag;

    if (os == .windows) {
        // Route source files and system libraries through the root_module
        lib.root_module.addCSourceFile(.{
            .file = b.path("src/win32_capture.c"),
            .flags = &.{ "-std=c99", "-DUNICODE", "-D_UNICODE" },
        });
        lib.root_module.linkSystemLibrary("mf", .{}); // Added to link MFEnumDeviceSources
        lib.root_module.linkSystemLibrary("mfplat", .{});
        lib.root_module.linkSystemLibrary("mfreadwrite", .{});
        lib.root_module.linkSystemLibrary("mfuuid", .{});
        lib.root_module.linkSystemLibrary("ole32", .{});
    } else if (os == .ios or os == .macos) {
        lib.root_module.addCSourceFile(.{
            .file = b.path("src/ios_capture.m"), 
            .flags = &.{"-fobjc-arc"},
        });
        lib.root_module.linkFramework("AVFoundation", .{});
        lib.root_module.linkFramework("CoreMedia", .{});
        lib.root_module.linkFramework("CoreVideo", .{});
        lib.root_module.linkFramework("Foundation", .{});
    }

    // Bind the static library compilation requirements to the Zig module
    webcam_module.linkLibrary(lib);

    // 4. Create an executable artifact for compilation testing
    const test_exe = b.addExecutable(.{
        .name = "webcam-test",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/test.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    
    // Inject the webcam module to the test program
    test_exe.root_module.addImport("webcam", webcam_module);

    // Install the executable to the output directory (bin/webcam-test)
    b.installArtifact(test_exe);

    // Define a "run" step to compile and execute the test runner
    const run_cmd = b.addRunArtifact(test_exe);
    run_cmd.step.dependOn(b.getInstallStep());

    const run_step = b.step("run", "Compile and run the test application");
    run_step.dependOn(&run_cmd.step);
}