const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const allow_system_deps = b.option(bool, "allow-system-deps", "Allow relying on globally installed SDK/libs") orelse false;
    generateCompileCommandsJson(b.graph.io) catch |err| {
        std.debug.panic("failed to generate compile_commands.json: {s}", .{@errorName(err)});
    };

    validateDependencyLayout(b, target, allow_system_deps);

    const lib_sources: []const []const u8 = &.{
        "src/randyosgui.c",
        "src/layout.c",
        "src/input.c",
        "src/style.c",
        "src/widgets/label.c",
        "src/widgets/button.c",
        "src/widgets/checkbox.c",
        "src/widgets/radio.c",
        "src/widgets/textbox.c",
        "src/widgets/dropdown.c",
        "src/widgets/slider.c",
        "src/widgets/progress.c",
        "src/widgets/groupbox.c",
        "src/widgets/tab.c",
        "src/widgets/tree.c",
        "src/widgets/table.c",
        "src/widgets/field_border.c",
        "src/widgets/status_field.c",
        "src/widgets/sunken_panel.c",
        "src/widgets/vbox.c",
        "src/widgets/hbox.c",
        "src/widgets/separator.c",
        "src/widgets/spinbox.c",
        "src/widgets/combobox.c",
        "src/widgets/textedit.c",
        "src/widgets/listbox.c",
        "src/widgets/menubar.c",
        "src/widgets/toolbar.c",
        "src/widgets/image.c",
        "src/widgets/scroll_area.c",
        "src/widgets/stacked.c",
        "src/widgets/tab_widget.c",
        "src/widgets/accordion.c",
        "src/widgets/tooltip.c",
        "src/widgets/dialog.c",
        "src/widgets/epoch.c",
        "src/platform/platform.c",
        "src/renderer/renderer_vk.c",
        "src/renderer/renderer_vk_swapchain.c",
        "src/renderer/renderer_draw.c",
        "src/renderer/renderer_widgets.c",
    };

    const c_flags: []const []const u8 = &.{
        "-std=c11",
        "-Wall",
        "-Wextra",
        "-Wpedantic",
    };

    // --- Static library ---
    // System libs are NOT linked here; they're added by each consumer so that
    // lld doesn't try to bundle .so stubs into the .a archive.
    const lib_mod = b.createModule(.{
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    lib_mod.addCSourceFiles(.{ .files = lib_sources, .flags = c_flags });
    lib_mod.addIncludePath(b.path("include"));
    lib_mod.addIncludePath(b.path("src"));
    addThirdPartyIncludePaths(lib_mod, b, target);

    const lib = b.addLibrary(.{
        .name = "randyosgui",
        .root_module = lib_mod,
        .linkage = .static,
    });
    b.installArtifact(lib);

    // --- Shared library ---
    // Shared lib IS fully linked, so platform libs go here.
    const shared_mod = b.createModule(.{
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    shared_mod.addCSourceFiles(.{ .files = lib_sources, .flags = c_flags });
    shared_mod.addIncludePath(b.path("include"));
    shared_mod.addIncludePath(b.path("src"));
    addThirdPartyIncludePaths(shared_mod, b, target);
    addPlatformLibs(shared_mod, b, target);

    const shared = b.addLibrary(.{
        .name = "randyosgui",
        .root_module = shared_mod,
        .linkage = .dynamic,
    });
    b.installArtifact(shared);

    installRuntimeDlls(b, target);

    // Install public header
    b.installFile("include/randyosgui.h", "include/randyosgui.h");

    // --- Examples ---
    buildExample(b, "win98-gallery", "examples/win98_gallery/main.c", target, optimize, lib);

    // --- Tests ---
    const test_mod = b.createModule(.{
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    test_mod.addCSourceFiles(.{
        .files = &.{
            "tests/test_randyosgui.c",
            "tests/test_draw_commands.c",
        },
        .flags = c_flags,
    });
    test_mod.addIncludePath(b.path("include"));
    test_mod.addIncludePath(b.path("src"));
    addThirdPartyIncludePaths(test_mod, b, target);
    test_mod.linkLibrary(lib);
    addPlatformLibs(test_mod, b, target);

    const test_exe = b.addExecutable(.{
        .name = "test_randyosgui",
        .root_module = test_mod,
    });

    const run_tests = b.addRunArtifact(test_exe);
    if (target.result.os.tag == .windows) {
        addPathDir(b, run_tests, "third_party/glfw/lib/windows");
        addPathDir(b, run_tests, "third_party/freetype/lib/windows");
    }
    // On headless systems set DISPLAY to a Xvfb instance before running:
    //   Xvfb :99 -screen 0 1024x768x24 & DISPLAY=:99 zig build test
    const test_step = b.step("test", "Run unit tests (needs DISPLAY on headless systems)");
    test_step.dependOn(&run_tests.step);
}

const CompileCommand = struct {
    directory: []const u8,
    command: []const u8,
    file: []const u8,
};

fn generateCompileCommandsJson(io: std.Io) !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const cwd = std.Io.Dir.cwd();
    var cwd_path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const cwd_path_len = try cwd.realPath(io, &cwd_path_buf);
    const cwd_path = try toPosixSlashes(alloc, cwd_path_buf[0..cwd_path_len]);

    var entries = try std.ArrayList(CompileCommand).initCapacity(alloc, 0);
    defer entries.deinit(alloc);

    try appendCommandsForDir(
        io,
        alloc,
        cwd,
        &entries,
        cwd_path,
        "include",
        ".h",
        true,
    );
    try appendCommandsForDir(
        io,
        alloc,
        cwd,
        &entries,
        cwd_path,
        "src",
        ".h",
        true,
    );
    try appendCommandsForDir(
        io,
        alloc,
        cwd,
        &entries,
        cwd_path,
        "src",
        ".c",
        false,
    );
    try appendCommandsForDir(
        io,
        alloc,
        cwd,
        &entries,
        cwd_path,
        "examples",
        ".c",
        false,
    );
    try appendCommandsForDir(
        io,
        alloc,
        cwd,
        &entries,
        cwd_path,
        "tests",
        ".c",
        false,
    );

    std.mem.sort(CompileCommand, entries.items, {}, struct {
        fn lessThan(_: void, a: CompileCommand, b: CompileCommand) bool {
            return std.mem.lessThan(u8, a.file, b.file);
        }
    }.lessThan);

    var file = try cwd.createFile(io, "compile_commands.json", .{ .truncate = true });
    defer file.close(io);

    try writeCompileCommandsJson(io, &file, entries.items);
}

fn writeCompileCommandsJson(io: std.Io, file: *std.Io.File, entries: []const CompileCommand) !void {
    try file.writeStreamingAll(io, "[\n");
    for (entries, 0..) |entry, idx| {
        if (idx > 0) try file.writeStreamingAll(io, ",\n");
        try file.writeStreamingAll(io, "  {\n");
        try file.writeStreamingAll(io, "    \"directory\": ");
        try writeJsonString(io, file, entry.directory);
        try file.writeStreamingAll(io, ",\n");
        try file.writeStreamingAll(io, "    \"command\": ");
        try writeJsonString(io, file, entry.command);
        try file.writeStreamingAll(io, ",\n");
        try file.writeStreamingAll(io, "    \"file\": ");
        try writeJsonString(io, file, entry.file);
        try file.writeStreamingAll(io, "\n  }");
    }
    try file.writeStreamingAll(io, "\n]\n");
}

fn writeJsonString(io: std.Io, file: *std.Io.File, s: []const u8) !void {
    try writeByte(io, file, '"');
    for (s) |c| {
        switch (c) {
            '"' => try file.writeStreamingAll(io, "\\\""),
            '\\' => try file.writeStreamingAll(io, "\\\\"),
            '\n' => try file.writeStreamingAll(io, "\\n"),
            '\r' => try file.writeStreamingAll(io, "\\r"),
            '\t' => try file.writeStreamingAll(io, "\\t"),
            else => try writeByte(io, file, c),
        }
    }
    try writeByte(io, file, '"');
}

fn writeByte(io: std.Io, file: *std.Io.File, c: u8) !void {
    const one = [1]u8{c};
    try file.writeStreamingAll(io, &one);
}

fn appendCommandsForDir(
    io: std.Io,
    alloc: std.mem.Allocator,
    cwd: std.Io.Dir,
    entries: *std.ArrayList(CompileCommand),
    cwd_path: []const u8,
    root_rel: []const u8,
    ext: []const u8,
    is_header: bool,
) !void {
    var dir = cwd.openDir(io, root_rel, .{ .iterate = true }) catch |err| {
        if (err == error.FileNotFound) return;
        return err;
    };
    defer dir.close(io);

    var walker = try dir.walk(alloc);
    defer walker.deinit();

    while (try walker.next(io)) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.basename, ext)) continue;

        const rel_native = try std.fmt.allocPrint(alloc, "{s}/{s}", .{ root_rel, entry.path });
        const rel_path = try toPosixSlashes(alloc, rel_native);
        const command = try buildCompileCommand(alloc, rel_path, is_header);

        try entries.append(alloc, .{
            .directory = cwd_path,
            .command = command,
            .file = rel_path,
        });
    }
}

fn buildCompileCommand(alloc: std.mem.Allocator, rel_path: []const u8, is_header: bool) ![]const u8 {
    var args = try std.ArrayList([]const u8).initCapacity(alloc, 0);
    defer args.deinit(alloc);
    try args.appendSlice(alloc, &.{ "zig", "cc" });
    if (is_header) {
        try args.appendSlice(alloc, &.{ "-x", "c-header" });
    }
    try args.appendSlice(alloc, &.{
        "-std=c11",
        "-Iinclude",
        "-Isrc",
        "-Ithird_party/glfw/include",
        "-Ithird_party/vulkan/include",
        "-Ithird_party/freetype/include",
        "-c",
        rel_path,
    });

    var out = try std.ArrayList(u8).initCapacity(alloc, 0);
    for (args.items, 0..) |arg, idx| {
        if (idx > 0) try out.append(alloc, ' ');
        try appendShellArg(alloc, &out, arg);
    }
    return out.toOwnedSlice(alloc);
}

fn appendShellArg(alloc: std.mem.Allocator, out: *std.ArrayList(u8), arg: []const u8) !void {
    if (std.mem.indexOfAny(u8, arg, " \t\"'\\") == null) {
        try out.appendSlice(alloc, arg);
        return;
    }

    try out.append(alloc, '"');
    for (arg) |c| {
        if (c == '"' or c == '\\') {
            try out.append(alloc, '\\');
        }
        try out.append(alloc, c);
    }
    try out.append(alloc, '"');
}

fn toPosixSlashes(alloc: std.mem.Allocator, path: []const u8) ![]const u8 {
    const out = try alloc.alloc(u8, path.len);
    for (path, 0..) |c, i| {
        out[i] = if (c == '\\') '/' else c;
    }
    return out;
}

fn installIfPresent(b: *std.Build, src_rel: []const u8, dst_rel: []const u8) void {
    if (pathExists(b.graph.io, src_rel)) {
        b.installFile(src_rel, dst_rel);
    }
}

fn installRuntimeDlls(b: *std.Build, target: std.Build.ResolvedTarget) void {
    if (target.result.os.tag != .windows) return;

    installIfPresent(b, "third_party/glfw/lib/windows/glfw3.dll", "bin/glfw3.dll");
    installIfPresent(b, "third_party/freetype/lib/windows/freetype.dll", "bin/freetype.dll");
}

fn ensurePath(b: *std.Build, rel_path: []const u8, what: []const u8) void {
    if (!pathExists(b.graph.io, rel_path)) {
        std.debug.panic(
            "missing {s}: {s}\nRun scripts/fetch_deps.ps1 to populate repo-local third_party dependencies.",
            .{ what, rel_path },
        );
    }
}

fn validateDependencyLayout(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    allow_system_deps: bool,
) void {
    if (allow_system_deps) return;

    switch (target.result.os.tag) {
        .windows => {
            ensurePath(b, "third_party/glfw/include/GLFW/glfw3.h", "GLFW header");
            ensurePath(b, "third_party/vulkan/include/vulkan/vulkan.h", "Vulkan header");
            ensurePath(b, "third_party/vulkan/include/vk_video/vulkan_video_codec_h264std.h", "Vulkan video header");
            ensurePath(b, "third_party/freetype/include/ft2build.h", "FreeType header");

            ensurePath(b, "third_party/glfw/lib/windows/glfw3.lib", "GLFW import library");
            ensurePath(b, "third_party/vulkan/lib/windows/vulkan-1.lib", "Vulkan import library");
            ensurePath(b, "third_party/freetype/lib/windows/freetype.lib", "FreeType import library");
            ensurePath(b, "third_party/glfw/lib/windows/glfw3.dll", "GLFW runtime DLL");
            ensurePath(b, "third_party/freetype/lib/windows/freetype.dll", "FreeType runtime DLL");
        },
        else => {},
    }
}

fn pathExists(io: std.Io, rel_path: []const u8) bool {
    std.Io.Dir.cwd().access(io, rel_path, .{}) catch return false;
    return true;
}

fn addIncludeIfPresent(mod: *std.Build.Module, b: *std.Build, rel_path: []const u8) void {
    if (pathExists(b.graph.io, rel_path)) {
        mod.addIncludePath(b.path(rel_path));
    }
}

fn addLibPathIfPresent(mod: *std.Build.Module, b: *std.Build, rel_path: []const u8) void {
    if (pathExists(b.graph.io, rel_path)) {
        mod.addLibraryPath(b.path(rel_path));
    }
}

fn addThirdPartyIncludePaths(
    mod: *std.Build.Module,
    b: *std.Build,
    target: std.Build.ResolvedTarget,
) void {
    _ = target;

    addIncludeIfPresent(mod, b, "third_party/glfw/include");
    addIncludeIfPresent(mod, b, "third_party/vulkan/include");
    addIncludeIfPresent(mod, b, "third_party/freetype/include");
}

fn addThirdPartyLibraryPaths(
    mod: *std.Build.Module,
    b: *std.Build,
    target: std.Build.ResolvedTarget,
) void {
    addLibPathIfPresent(mod, b, "third_party/glfw/lib");
    addLibPathIfPresent(mod, b, "third_party/vulkan/lib");
    addLibPathIfPresent(mod, b, "third_party/freetype/lib");

    switch (target.result.os.tag) {
        .linux => {
            addLibPathIfPresent(mod, b, "third_party/glfw/lib/linux");
            addLibPathIfPresent(mod, b, "third_party/vulkan/lib/linux");
            addLibPathIfPresent(mod, b, "third_party/freetype/lib/linux");
        },
        .windows => {
            addLibPathIfPresent(mod, b, "third_party/glfw/lib/windows");
            addLibPathIfPresent(mod, b, "third_party/vulkan/lib/windows");
            addLibPathIfPresent(mod, b, "third_party/freetype/lib/windows");
        },
        .macos => {
            addLibPathIfPresent(mod, b, "third_party/glfw/lib/macos");
            addLibPathIfPresent(mod, b, "third_party/vulkan/lib/macos");
            addLibPathIfPresent(mod, b, "third_party/freetype/lib/macos");
        },
        else => {},
    }
}

fn addPlatformLibs(mod: *std.Build.Module, b: *std.Build, target: std.Build.ResolvedTarget) void {
    addThirdPartyLibraryPaths(mod, b, target);

    switch (target.result.os.tag) {
        .linux => {
            mod.linkSystemLibrary("glfw", .{});
            mod.linkSystemLibrary("vulkan", .{});
            mod.linkSystemLibrary("freetype", .{});
        },
        .windows => {
            mod.linkSystemLibrary("glfw3", .{});
            mod.linkSystemLibrary("vulkan-1", .{});
            mod.linkSystemLibrary("freetype", .{});
        },
        .macos => {
            mod.linkSystemLibrary("glfw", .{});
            mod.linkSystemLibrary("freetype", .{});
            mod.linkFramework("Metal", .{});
            mod.linkFramework("QuartzCore", .{});
        },
        else => {},
    }
}

fn buildExample(
    b: *std.Build,
    comptime name: []const u8,
    src: []const u8,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    lib: *std.Build.Step.Compile,
) void {
    const mod = b.createModule(.{
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    mod.addCSourceFiles(.{
        .files = &.{src},
        .flags = &.{"-std=c11"},
    });
    mod.addIncludePath(b.path("include"));
    addThirdPartyIncludePaths(mod, b, target);
    mod.linkLibrary(lib);
    // Examples need the platform libs since they run the real main loop
    addPlatformLibs(mod, b, target);

    const exe = b.addExecutable(.{
        .name = name,
        .root_module = mod,
    });
    b.installArtifact(exe);

    const run = b.addRunArtifact(exe);
    if (target.result.os.tag == .windows) {
        addPathDir(b, run, "third_party/glfw/lib/windows");
        addPathDir(b, run, "third_party/freetype/lib/windows");
    }
    const step = b.step("run-" ++ name, "Run the " ++ name ++ " example");
    step.dependOn(&run.step);
}

/// Replacement for the old `Step.Run.addPathDir`, which no longer exists:
/// prepends `dir` to the child process's PATH environment variable.
fn addPathDir(b: *std.Build, run: *std.Build.Step.Run, dir: []const u8) void {
    const env_map = run.getEnvMap();
    const existing = env_map.get("PATH") orelse "";
    const new_value = if (existing.len == 0)
        dir
    else
        b.fmt("{s}{c}{s}", .{ dir, std.fs.path.delimiter, existing });
    env_map.put("PATH", new_value) catch @panic("OOM");
}
